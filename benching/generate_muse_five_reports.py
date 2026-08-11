#!/usr/bin/env python3
import sqlite3, json, pathlib, csv
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

DB = pathlib.Path('/home/rahlquist/wimpy-setup/benching/bench.db')
OUT = pathlib.Path('/home/rahlquist/wimpy-setup/benching')
models = [
    'Qwen3-30B-A3B-Q4_K_M.gguf',
    'Qwen_Qwen3-30B-A3B-Instruct-2507-Q5_K_M.gguf',
    'Qwen3-30B-A3B-Instruct-2507-UD-Q5_K_XL.gguf',
    'Ornith-1.0-35B-UD-Q4_K_XL.gguf',
    'Muse-Glimmer-30B-UD-Q6_K_XL.gguf',
    'Muse-Glimmer-30B-UD-Q2_K_XL.gguf',
]
# Four prior comparison models plus yesterday's Muse Q6 and today's Muse Q2 result.
labels = {
    'Qwen3-30B-A3B-Q4_K_M.gguf': 'Qwen3 30B A3B Q4_K_M',
    'Qwen_Qwen3-30B-A3B-Instruct-2507-Q5_K_M.gguf': 'Qwen3 30B A3B Q5_K_M',
    'Qwen3-30B-A3B-Instruct-2507-UD-Q5_K_XL.gguf': 'Qwen3 30B A3B UD-Q5_K_XL',
    'Ornith-1.0-35B-UD-Q4_K_XL.gguf': 'Ornith 35B UD-Q4_K_XL',
    'Muse-Glimmer-30B-UD-Q6_K_XL.gguf': 'Muse Glimmer 30B UD-Q6_K_XL',
    'Muse-Glimmer-30B-UD-Q2_K_XL.gguf': 'Muse Glimmer 30B UD-Q2_K_XL',
}
metrics = ['pp512', 'tg128', 'pp512@d4096', 'tg128@d4096']
conn = sqlite3.connect(DB)
q = '''select b.test_name,b.avg_ts,b.stddev_ts,b.gpu_info,b.date_run
       from benchmark_runs b join models m on m.id=b.model_id
       where m.filename=? and b.date_run=(select max(b2.date_run) from benchmark_runs b2 where b2.model_id=b.model_id)
       and b.test_name in ('pp512','tg128','pp512@d4096','tg128@d4096')'''
data = {}
for model in models:
    data[model] = {}
    for test, avg, std, gpu, date in conn.execute(q, (model,)):
        data[model][test] = {'avg': avg, 'std': std, 'gpu': gpu, 'date': date}
missing = {m: [x for x in metrics if x not in data[m]] for m in models}
if any(missing.values()):
    raise SystemExit(f'Missing benchmark data: {missing}')
# CSV, ordered per metric descending.
with open(OUT/'muse-glimmer-five-model-comparison.csv','w',newline='') as f:
    w=csv.writer(f); w.writerow(['metric','model','tokens_per_second','stddev','backend','date_run'])
    for metric in metrics:
        for model in sorted(models,key=lambda m:data[m][metric]['avg'],reverse=True):
            r=data[model][metric]; w.writerow([metric,labels[model],r['avg'],r['std'],r['gpu'],r['date']])
# Markdown report with tables independently ordered by value.
with open(OUT/'muse-glimmer-five-model-comparison.md','w') as f:
    f.write('# Muse Glimmer comparison — five-model benchmark\n\n')
    f.write('Generated from the local llama-bench SQLite database. Each metric is ordered highest to lowest.\n\n')
    f.write('Today’s addition: **Muse Glimmer 30B UD-Q2_K_XL on NVIDIA RTX 5060 Ti**.\n\n')
    for metric in metrics:
        f.write(f'## {metric}\n\n| Rank | Model | tok/s | ± stddev | Backend |\n|---:|---|---:|---:|---|\n')
        for rank,model in enumerate(sorted(models,key=lambda m:data[m][metric]['avg'],reverse=True),1):
            r=data[model][metric]
            backend='CUDA / RTX 5060 Ti' if 'NVIDIA' in r['gpu'] else 'ROCm / R9700'
            f.write(f'| {rank} | {labels[model]} | {r["avg"]:.2f} | {r["std"]:.2f} | {backend} |\n')
        f.write('\n')
    f.write('## Method\n\n')
    f.write('- `pp512`: prompt processing\n- `tg128`: token generation\n- `@d4096`: 4096-token KV-cache context\n- Three repetitions, maximum GPU offload, llama.cpp `llama-bench`\n')
# One combined figure, panels sorted independently.
plt.style.use('seaborn-v0_8-darkgrid')
fig, axes = plt.subplots(2,2,figsize=(18,12),constrained_layout=True)
colors = ['#4c78a8','#f58518','#54a24b','#e45756','#b279a2']
for ax,metric in zip(axes.flat,metrics):
    ordered=sorted(models,key=lambda m:data[m][metric]['avg'],reverse=True)
    vals=[data[m][metric]['avg'] for m in ordered]
    errs=[data[m][metric]['std'] for m in ordered]
    bars=ax.bar(range(len(ordered)),vals,yerr=errs,capsize=4,color=colors[:len(ordered)])
    ax.set_title(metric,fontsize=15,fontweight='bold')
    ax.set_ylabel('tokens/s')
    ax.set_xticks(range(len(ordered)),[labels[m] for m in ordered],rotation=32,ha='right',fontsize=9)
    for b,v in zip(bars,vals): ax.text(b.get_x()+b.get_width()/2,b.get_height(),f'{v:.1f}',ha='center',va='bottom',fontsize=9)
fig.suptitle('llama.cpp Muse Glimmer comparison — five models, ordered by value',fontsize=19,fontweight='bold')
fig.savefig(OUT/'muse-glimmer-five-model-comparison.png',dpi=180)
# Individual graphs too.
for metric in metrics:
    ordered=sorted(models,key=lambda m:data[m][metric]['avg'],reverse=True)
    fig,ax=plt.subplots(figsize=(14,7),constrained_layout=True)
    vals=[data[m][metric]['avg'] for m in ordered]; errs=[data[m][metric]['std'] for m in ordered]
    bars=ax.bar(range(len(ordered)),vals,yerr=errs,capsize=5,color=colors[:len(ordered)])
    ax.set_title(f'{metric} — ordered highest to lowest',fontsize=17,fontweight='bold'); ax.set_ylabel('tokens/s')
    ax.set_xticks(range(len(ordered)),[labels[m] for m in ordered],rotation=28,ha='right')
    for b,v in zip(bars,vals): ax.text(b.get_x()+b.get_width()/2,b.get_height(),f'{v:.2f}',ha='center',va='bottom')
    fig.savefig(OUT/f'muse-glimmer-{metric.replace("@","-")}.png',dpi=180); plt.close(fig)
plt.close('all')
print(json.dumps({'models':[labels[m] for m in models],'files':[str(OUT/x) for x in ['muse-glimmer-five-model-comparison.md','muse-glimmer-five-model-comparison.csv','muse-glimmer-five-model-comparison.png']+[f'muse-glimmer-{m.replace("@","-")}.png' for m in metrics]]},indent=2))
