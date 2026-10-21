"""Check full goal coverage and evidence paths; never infer acceptance from a test."""
import argparse
import hashlib
import json
from pathlib import Path
import re

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]

def audit(ledger):
    source=(ROOT/'goal.md').read_bytes()
    errors=[];pending=[]
    if ledger['contract_sha256']!=hashlib.sha256(source).hexdigest():
        errors.append('goal.md changed: reconcile full scope before acceptance')
    goal=source.decode('utf-8')
    expected={}
    for section,prefix in [('DSP','DSP'),('ISP','ISP'),('基础设施','INFRA')]:
        body=goal.split('### '+section+'\n',1)[1].split('\n##',1)[0]
        for number,text in re.findall(r'^(\d+)\. (.+)$',body,re.M):
            expected[f'{prefix}-{int(number):02d}']=text
    rows=ledger['requirements']
    if len(rows)!=len(expected) or {r['id'] for r in rows}!=set(expected):
        errors.append('missing, duplicate or extra requirement IDs')
    fields=['specification','implementation','float_model','bit_exact_model',
            'simulation','checker_negative','synthesis','route_timing',
            'board_injection','board_capture','board_reprogram','production','documentation']
    for row in rows:
        rid=row['id']
        if row['requirement']!=expected.get(rid):errors.append(rid+': scope wording changed')
        for field in fields:
            for path in row[field]:
                if not (ROOT/path).is_file(): errors.append(f'{rid}: missing {field} file {path}')
        missing=[f for f in fields if not row[f] and f not in row.get('not_applicable',{})]
        accepted=row['status']=='生产集成验收通过'
        if not accepted or missing or not row.get('configurations'):
            pending.append(dict(id=rid,status=row['status'],missing=missing))
        if accepted and (missing or not row.get('configurations')):
            errors.append(rid+': unsupported acceptance claim')
    for chain in ['DSP','ISP']:
        entry=ledger['integration_chains'][chain]
        if entry['status']!='accepted' or not entry['evidence']:
            pending.append(dict(id=chain+'-CHAIN',status='pending'))
        for path in entry['evidence']:
            if not (ROOT/path).is_file():errors.append('missing chain evidence '+path)
    return dict(tracking_valid=not errors,acceptance_complete=not errors and not pending,
                errors=errors,pending=pending)

def main():
    p=argparse.ArgumentParser();p.add_argument('--acceptance',action='store_true')
    p.add_argument('--output',type=Path)
    a=p.parse_args();ledger=json.loads((HERE/'requirements.json').read_text(encoding='utf-8'))
    result=audit(ledger)
    if a.output:
        with a.output.open('x',encoding='utf-8') as f:json.dump(result,f,ensure_ascii=False,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pending'},ensure_ascii=False))
    print(f'Pending requirements and integration chains: {len(result["pending"])}')
    return int(not result['tracking_valid'] or (a.acceptance and not result['acceptance_complete']))

if __name__=='__main__':raise SystemExit(main())
