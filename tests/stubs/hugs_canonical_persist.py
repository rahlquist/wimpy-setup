#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv
if os.environ.get('HUGS_PERSIST_STUB_FAIL') == '1':
    print('persistence failed', file=sys.stderr)
    raise SystemExit(2)
payload = json.load(open(args[args.index('--payload') + 1], encoding='utf-8'))
log = os.environ.get('HUGS_STUB_LOG')
if log:
    rows = [(f"/api/hugs/models/{payload['model_id']}", payload['model'])]
    rows += [(f"/api/hugs/models/{payload['model_id']}/assets", a) for a in payload.get('assets', [])]
    if payload.get('smoke') is not None:
        rows.append((f"/api/hugs/models/{payload['model_id']}/smoke", payload['smoke']))
    with open(log, 'a', encoding='utf-8') as f:
        for path, body in rows:
            f.write(json.dumps({'method': 'POST', 'path': path, 'body': body}) + '\n')
print('stub persistence ok')
