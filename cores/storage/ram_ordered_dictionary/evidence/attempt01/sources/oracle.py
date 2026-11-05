"""Independent associative-map oracle; only future approved preparation calls it."""
from __future__ import annotations
import argparse,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def evaluate(commands,capacity):
    store={};answers=[]
    for name,op,key,value,high in commands:
        found=key in store;status=0;kind=0;outkey=outvalue=0
        if op==0:
            if found:outkey,outvalue=key,store[key]
            else:status=1
        elif op==1:
            if not found and len(store)==capacity:status=2;found=False
            else:store[key]=value;outkey,outvalue=key,value
        elif op==2:
            if found:outkey,outvalue=key,store.pop(key)
            else:status=1
        elif op==3:
            candidates=[k for k in sorted(store) if k>=key]
            found=bool(candidates)
            if found:outkey=candidates[0];outvalue=store[outkey]
            else:status=1
        elif op==4:
            rows=[] if key>high else [[1,0,1,k,store[k],len(store)] for k in sorted(store) if key<=k<=high]
            rows.append([2,3 if key>high else 0,0,0,0,len(store)])
            answers.append(dict(name=name,command=[op,key,value,high],responses=rows));continue
        elif op==5:store.clear();found=False
        else:status=4;found=False
        if status:found=False;outkey=outvalue=0
        answers.append(dict(name=name,command=[op,key,value,high],
                            responses=[[kind,status,int(found),outkey,outvalue,len(store)]]))
    return answers
def reset_commands(profile,target):
    maximum=(1<<profile['k_w'])-1;vmax=(1<<profile['v_w'])-1
    if target=='next_offer':
        return [['offered_put',1,0,vmax,0],['old_absent',0,1,0,0],['get_fresh',0,0,0,0],
                ['fresh_range',4,0,0,maximum],['delete_fresh',2,0,0,0],['fresh_clear',5,0,0,0]]
    return [['old_absent',0,1,0,0],['empty_range',4,0,0,maximum],['fresh_put',1,0,vmax,0],
            ['get_fresh',0,0,0,0],['seek_fresh',3,0,0,0],['fresh_range',4,0,0,maximum],
            ['delete_fresh',2,0,0,0],['fresh_clear',5,0,0,0]]
def check_stored():
    # No algorithm rerun: hashes and shape only; preparation computed the oracle once.
    receipt=json.loads((ROOT/'prepared/receipt.json').read_bytes())
    for name,digest in receipt['files_sha256'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
    raw=json.loads((ROOT/'RAW_INPUTS.json').read_bytes())
    for p in raw['profiles']:
        got=json.loads((ROOT/'prepared/fixtures'/p['name']/'main.json').read_bytes())
        assert [x['name'] for x in got]==[x[0] for x in p['commands']]
        assert [x['command'] for x in got]==[x[1:] for x in p['commands']]
    print('PASS STORED HASHES NO_ORACLE_REEXECUTION',flush=True)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check-stored',action='store_true',required=True)
    parser.parse_args();check_stored()
