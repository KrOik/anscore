"""One immutable source-bound finite matrix, hard 20 seconds per HDL child."""
import argparse
import ast
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
def digest(p): return sha256(p.read_bytes()).hexdigest()
def read(rel): return json.loads((ROOT/rel).read_text(encoding='utf-8'))
def write(rel,value): (ROOT/rel).write_text(json.dumps(value,sort_keys=True,indent=2)+'\n',encoding='utf-8',newline='\n')
def sources():
    return {p.relative_to(ROOT).as_posix():digest(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in {'SOURCE_FREEZE.json','verification.json'}
            and 'failure_archive' not in p.relative_to(ROOT).parts}
def jobs(plan):
    return {z['name']:dict(profile=p,kind=k,entry=z)
            for p in plan['profiles'] for k in ['main','resets'] for z in p[k]}
def matrix_audit(plan):
    assert plan['frozen_before_rtl'] and plan['timeout_seconds']==20 and plan['timeout_terminal']
    assert digest(ROOT/'prepare_matrix.py')==plan['preparation_sha256']
    assert len(plan['children'])==301 and len({c['name'] for c in plan['children']})==301
    assert all(c['timeout_seconds']==20 for c in plan['children'])
    for job in jobs(plan).values():
        z=job['entry']
        for ext in ['json','text']: assert digest(ROOT/z[ext])==z[ext+'_sha256']
    for p in ROOT.glob('*.py'): ast.parse(p.read_text(encoding='utf-8'))
    tb=(ROOT/'sim/tb_directed_minimum_arborescence.sv').read_text()
    assert tb.count('$finish;')==1
    return next(i for i,s in enumerate(tb.splitlines(),1) if '$finish;' in s)
def witness(frame,n,indices):
    assert len(indices)==n-1
    vertices=[v for v in range(n) if v!=frame['root']]
    parent={};total=0
    for v,i in zip(vertices,indices):
        assert 0<=i<len(frame['kept_edges'])
        u,w,c=frame['kept_edges'][i];assert w==v and 0<=u<n and u!=v
        parent[v]=u;total+=c
    for v in vertices:
        seen=set();u=v
        while u!=frame['root']:
            assert u not in seen;seen.add(u);u=parent[u]
    assert total==frame['total']
def parse_sim(stdout,job,finish_line):
    fixture=read(job['entry']['json'])
    expected=fixture['frames'] if job['kind']=='main' else [fixture['fresh']]
    results={};latencies={};cancels=[];summary=None
    lines=stdout.splitlines()
    finish_pattern=r'sim/tb_directed_minimum_arborescence\.sv:'+str(finish_line)+r': \$finish called at \d+ \(1ps\)'
    assert len(lines)>=2 and re.fullmatch(finish_pattern,lines[-1])
    assert lines[-2].startswith('PASS ')
    for pos,line in enumerate(lines[:-1]):
        if line.startswith('RESULT '):
            values=list(map(int,line.split()[1:]));i=values[0];assert i not in results;results[i]=values[1:]
        elif line.startswith('LATENCY '):
            _,i,cycles=line.split();i=int(i);assert i not in latencies;latencies[i]=int(cycles)
        elif line.startswith('CANCEL '): cancels.append(list(map(int,line.split()[1:])))
        elif line.startswith('PASS '):
            assert summary is None and pos==len(lines)-2
            summary={k:int(v) for k,v in (x.split('=') for x in line.split()[1:])}
        else: raise AssertionError('unexpected simulator output: '+line)
    assert summary is not None
    assert set(results)==set(latencies)==set(range(len(expected)))
    certificates=0
    for i,f in enumerate(expected):
        assert results[i][:2]==[f['feasible'],f['total']]
        assert 0<=latencies[i]<=f['latency_bound']
        if f['feasible']:
            witness(f,job['profile']['N'],results[i][2:]);certificates+=1
        else: assert len(results[i])==2
    if job['kind']=='main':
        assert not cancels and summary['resets']==0 and summary['queued']==len(expected)-1
    else:
        assert len(cancels)==1 and cancels[0][0]==fixture['target'] and cancels[0][2]==fixture['owner_retired_prefix']
        target,state,_=cancels[0]
        mapping={47:0,48:5,49:12,50:12,51:1,52:23,53:23,54:35,55:40,
                 56:45,57:45,58:45,59:46,60:46,61:46,63:0,64:1}
        if target<=46: assert state==target
        elif target==62: assert state!=0
        else: assert state==mapping[target]
        assert summary['resets']==1 and summary['queued']==0
    assert summary['frames']==len(expected)
    return dict(summary,optimal_witness_certificates=certificates,max_first_valid=max(latencies.values()),latencies=latencies)
def archive(receipt,tmp):
    dest=ROOT/'failure_archive/attempt_01';assert not dest.exists();dest.mkdir(parents=True)
    for rel in list(receipt['source_sha256'])+['SOURCE_FREEZE.json','verification.json']:
        p=dest/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/rel).read_bytes())
    (dest/'NOT_RUN.json').write_bytes((json.dumps(receipt['not_run'],indent=2)+'\n').encode())
    # Temporary simulator assemblies stay outside Git. Their bytes and hashes
    # remain available locally for review without committing generated artifacts.
    artifacts=REPO/'.git/anscore-b25-root-failed-artifacts';artifacts.mkdir(exist_ok=False)
    info={}
    for p in tmp.glob('*.vvp'):
        shutil.copyfile(p,artifacts/p.name);info[p.name]=dict(sha256=digest(p),bytes=p.stat().st_size)
    (dest/'LOCAL_ARTIFACTS.json').write_bytes(enc(dict(location=str(artifacts),files=info)))
    manifest={p.relative_to(dest).as_posix():digest(p) for p in sorted(dest.rglob('*')) if p.is_file()}
    (dest/'archive.json').write_bytes(enc(manifest))
def enc(value): return (json.dumps(value,sort_keys=True,indent=2)+'\n').encode()
def run():
    assert not (ROOT/'verification.json').exists(),'receipt exists; no automatic rerun'
    plan=read('TEST_PLAN.json');seal=read('SOURCE_FREEZE.json');finish_line=matrix_audit(plan)
    assert seal['before_first_hdl'] and seal['source_sha256']==sources() and seal['commands']==plan['children']
    binary=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';env=os.environ.copy()
    env['PATH']=str(binary)+os.pathsep+str(binary.parent/'lib')+os.pathsep+env.get('PATH','')
    assert (binary/'iverilog.exe').is_file() and (binary/'vvp.exe').is_file()
    receipt=dict(status='RUNNING',hardware='HW_UNVERIFIED',plan_sha256=digest(ROOT/'TEST_PLAN.json'),
                 source_freeze_sha256=digest(ROOT/'SOURCE_FREEZE.json'),source_sha256=sources(),
                 records=[],simulations=[],not_run=[x['name'] for x in plan['children']],terminal_timeout=False)
    byname=jobs(plan)
    with tempfile.TemporaryDirectory(prefix='anscore_b25_directed_arborescence_') as temporary:
        tmp=Path(temporary)
        for command in plan['children']:
            assert sources()==seal['source_sha256']
            name=command['name'];args=command['argv']
            argv=[str(binary/(args[0]+'.exe'))]+[s.replace('{TMP}',str(tmp)) for s in args[1:]]
            record=dict(name=name,argv=argv,timeout_seconds=20);start=time.monotonic()
            try:
                child=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
                record.update(exit_code=child.returncode,stdout=child.stdout,stderr=child.stderr,elapsed_seconds=round(time.monotonic()-start,6))
                if command['expected']=='EXPECTED_REJECT':
                    assert child.returncode!=0 and 'DIRECTED_MINIMUM_ARBORESCENCE_INVALID_PARAMETERS' in child.stderr
                    record['status']='EXPECTED_REJECT'
                else:
                    assert child.returncode==0 and not child.stderr,(child.returncode,child.stderr)
                    if name in byname: receipt['simulations'].append(dict(name=name,**parse_sim(child.stdout,byname[name],finish_line)))
                    else: assert not child.stdout
                    record['status']='PASS'
            except subprocess.TimeoutExpired as exc:
                cv=lambda s:s.decode('utf-8',errors='replace') if isinstance(s,bytes) else (s or '')
                record.update(status='TIMEOUT',stdout=cv(exc.stdout),stderr=cv(exc.stderr),elapsed_seconds=round(time.monotonic()-start,6));receipt['terminal_timeout']=True
            except Exception as exc:
                record.update(status='FAIL',error=type(exc).__name__+': '+str(exc))
            receipt['records'].append(record);receipt['not_run'].pop(0);write('verification.json',receipt)
            print(name,record['status'],record.get('elapsed_seconds'),flush=True)
            if record['status'] in ['FAIL','TIMEOUT']:
                receipt['status']=record['status'];write('verification.json',receipt);archive(receipt,tmp);return
        receipt['status']='UNIT_SIM_PASS';write('verification.json',receipt)
    audit()
def audit():
    plan=read('TEST_PLAN.json');seal=read('SOURCE_FREEZE.json');r=read('verification.json');matrix_audit(plan)
    assert r['source_sha256']==seal['source_sha256']==sources()
    assert r['plan_sha256']==digest(ROOT/'TEST_PLAN.json') and r['source_freeze_sha256']==digest(ROOT/'SOURCE_FREEZE.json')
    assert r['status']=='UNIT_SIM_PASS' and not r['not_run'] and not r['terminal_timeout']
    assert [x['name'] for x in r['records']]==[x['name'] for x in plan['children']]
    assert all(x['timeout_seconds']==20 and x['elapsed_seconds']<20 and x['status'] in ['PASS','EXPECTED_REJECT'] for x in r['records'])
    assert sum(x['frames'] for x in r['simulations'])==884+250
    assert sum(x['resets'] for x in r['simulations'])==250
    assert sum(x['queued'] for x in r['simulations'])==848
    print('OFFLINE_AUDIT_PASS 301 children; 884 main + 250 reset/fresh; unchanged source closure')
if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--freeze-source',action='store_true');ap.add_argument('--run',action='store_true');ap.add_argument('--audit',action='store_true');a=ap.parse_args()
    assert sum([a.freeze_source,a.run,a.audit])==1
    if a.freeze_source:
        assert not (ROOT/'SOURCE_FREEZE.json').exists() and not (ROOT/'verification.json').exists()
        plan=read('TEST_PLAN.json');matrix_audit(plan)
        write('SOURCE_FREEZE.json',dict(before_first_hdl=True,plan_sha256=digest(ROOT/'TEST_PLAN.json'),source_sha256=sources(),commands=plan['children'],timeout_seconds=20))
        print('SOURCE_FROZEN',digest(ROOT/'SOURCE_FREEZE.json'),len(sources()))
    elif a.run: run()
    else: audit()
