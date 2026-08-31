#!/usr/bin/env python3
"""One-at-a-time AMD VRAM backfill for the live Llama Hugs config."""
import argparse, json, os, re, shlex, signal, subprocess, time, urllib.request
from pathlib import Path

def vram_bytes():
    vals=[]
    for p in Path('/sys/class/drm').glob('card*/device/mem_info_vram_used'):
        try: vals.append(int(p.read_text().strip()))
        except (OSError, ValueError): pass
    return max(vals, default=0)

def post(base,path,obj):
    req=urllib.request.Request(base.rstrip('/')+path,data=json.dumps(obj).encode(),method='POST',headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=15) as r: return r.status

def healthy(url):
    try:
        with urllib.request.urlopen(url,timeout=1) as r: return r.status==200
    except Exception: return False

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--config',default='/opt/llama-hugs/config.yaml'); ap.add_argument('--api',default='http://127.0.0.1:8080'); ap.add_argument('--state',default='/home/rahlquist/llama-hugs/amd-vram-backfill.jsonl'); ap.add_argument('--model'); ap.add_argument('--timeout',type=int,default=180); ap.add_argument('--context',type=int,default=65536); a=ap.parse_args()
    import yaml
    models=yaml.safe_load(Path(a.config).read_text()).get('models',{})
    selected=[(mid,e) for mid,e in models.items() if 'ROCm0' in e.get('cmd','')]
    if a.model: selected=[x for x in selected if x[0]==a.model]
    state=Path(a.state); state.parent.mkdir(parents=True,exist_ok=True); done={}
    if state.exists():
        for line in state.read_text().splitlines():
            try:
                x=json.loads(line); done[x['model_id']]=x
            except Exception: pass
    for mid,entry in selected:
        if done.get(mid,{}).get('status')=='success' and done[mid].get('persisted'): continue
        raw=entry.get('cmd',''); m=re.search(r'--model\s+(\S+)',raw) or re.search(r'(?:^|\s)-m\s+(\S+)',raw)
        if not m: result={'model_id':mid,'status':'skipped','error':'no model path'}; state.open('a').write(json.dumps(result)+'\n'); continue
        path=Path(m.group(1))
        if not path.is_file(): result={'model_id':mid,'status':'skipped','error':f'missing model file: {path}'}; state.open('a').write(json.dumps(result)+'\n'); continue
        port=19000+os.getpid()%500; before=vram_bytes(); peak=before; after=before; proc=None; success=False; err=''; log=state.with_suffix('.'+mid.removeprefix('hugs-')+'.log')
        try:
            cmd=raw.replace('${PORT}',str(port)).replace('\\n',' ')
            cmd=' '.join(line.strip() for line in cmd.splitlines())
            parts=shlex.split(cmd)
            if '--host' in parts:
                parts[parts.index('--host')+1]='127.0.0.1'
            else:
                parts += ['--host','127.0.0.1']
            if '--port' in parts: parts[parts.index('--port')+1]=str(port)
            else: parts += ['--port',str(port)]
            proc=subprocess.Popen(parts,stdout=log.open('w'),stderr=subprocess.STDOUT,start_new_session=True)
            end=time.time()+a.timeout
            while time.time()<end:
                peak=max(peak,vram_bytes())
                if healthy(f'http://127.0.0.1:{port}/health'): success=True; break
                if proc.poll() is not None: break
                time.sleep(1)
            if success:
                req=urllib.request.Request(f'http://127.0.0.1:{port}/completion',data=b'{"prompt":"Say OK","n_predict":8}',headers={'Content-Type':'application/json'})
                with urllib.request.urlopen(req,timeout=60) as r: success=r.status==200 and bool(r.read())
            peak=max(peak,vram_bytes()); after=vram_bytes()
            if not success: err='health or generation failed'
        except Exception as e: err=str(e)
        finally:
            if proc and proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try: proc.wait(15)
                except subprocess.TimeoutExpired: os.killpg(proc.pid,signal.SIGKILL)
            for _ in range(20):
                after=vram_bytes(); time.sleep(.5)
                if after <= before*1.05+64*1024*1024: break
        result={'model_id':mid,'status':'success' if success else 'failed','gpu_backend':'ROCm0','context_size':a.context,'before':before,'peak':peak,'after':after,'error':err,'model_path':str(path),'disk_size_bytes':path.stat().st_size}
        if success:
            model={'display_name':mid.removeprefix('hugs-'),'source_repo':'','gguf_path':str(path),'gpu_backend':'ROCm','is_cuda_variant':0,'context_size':a.context,'capabilities_json':'{}','status':'active','notes':'AMD VRAM backfill'}
            asset={'asset_type':'gguf','asset_name':path.name,'local_path':str(path),'local_filename':path.name,'disk_size_bytes':path.stat().st_size,'vram_required_bytes':peak,'system_ram_required_bytes':0,'load_target':'vram','offload_supported':1,'purpose':'primary GGUF weights','measurement_source':'AMD VRAM backfill'}
            smoke={'gpu_backend':'ROCm0','context_size':a.context,'gpu_vram_before_bytes':before,'gpu_vram_peak_bytes':peak,'gpu_vram_after_bytes':after,'success':1,'error':'','notes':'Dedicated AMD VRAM backfill runner'}
            try: post(a.api,f'/api/hugs/models/{mid}',model); post(a.api,f'/api/hugs/models/{mid}/assets',asset); post(a.api,f'/api/hugs/models/{mid}/smoke',smoke); result['persisted']=True
            except Exception as e: result['persisted']=False; result['error']='persistence: '+str(e)
        state.open('a').write(json.dumps(result)+'\n'); print(json.dumps(result),flush=True)
if __name__=='__main__': main()
