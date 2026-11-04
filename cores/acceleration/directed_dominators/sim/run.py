#!/usr/bin/env python3
"""Fixed finite tests; independent vertex-deletion reachability oracle."""
from collections import deque
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
BASELINE='fcd2beef77f998da54801b91d74ce47946bee17c'
PROFILES=[(1,1),(2,3),(3,8),(7,8),(16,8),(64,32)]

def visit(adj,root,removed=None):
    if root==removed:return set()
    seen={root};todo=deque([root])
    while todo:
        for v in adj[todo.popleft()]:
            if v!=removed and v not in seen:seen.add(v);todo.append(v)
    return seen

def reference(n,edges,root):
    adj=[set() for _ in range(n)]
    for a,b in edges:adj[a].add(b)
    reached=visit(adj,root)
    without=[visit(adj,root,d) for d in range(n)]
    dom=[{d for d in range(n) if v in reached and v not in without[d]} for v in range(n)]
    rows=[]
    for v in range(n):
        strict=dom[v]-{v};parents=[d for d in strict if dom[d]==strict]
        if v in reached:
            assert v in dom[v] and root in dom[v]
            assert len(parents)==int(v!=root)
        else:assert not dom[v] and not parents
        descendants={u for u in range(n) if v in dom[u]}
        rows.append(dict(node=v,root=root,idom=parents[0] if parents else 0,reachable=int(v in reached),
                         idom_valid=int(v in reached and v!=root),depth=len(strict),dom_count=len(dom[v]),
                         subtree_count=len(descendants),reached_count=len(reached),
                         dominators=sum(1<<d for d in dom[v]),dominated=sum(1<<d for d in descendants)))
    # Parent chains must reproduce the deletion-defined dominator set.
    for v in reached:
        chain={v};u=v
        while u!=root:
            u=rows[u]['idom'];assert u not in chain;chain.add(u)
        assert chain==dom[v]
    return rows

def fixtures(n):
    frames=[];pairs=list(itertools.product(range(n),repeat=2))
    def simple(edges):return [(a,b,1,1) for a,b in edges]
    def add(root,raw):frames.append((root,raw or [(0xffffffff,0xffffffff,1,0)]))
    forward=simple((i,i+1) for i in range(n-1));backward=simple((i,i-1) for i in range(1,n))
    diamond=simple((a,b) for i in range(0,n,3) for a,b in [(i,i+1),(i,i+2),(i+1,i+3),(i+2,i+3)] if b<n)
    split=simple((i,i^1) for i in range(n) if (i^1)<n)
    if n==64:
        add(n-1,[]);add(n//2,simple(pairs));add(0,forward);add(n-1,backward)
        add(0,diamond);add(n//2,split);add(0xffffffff,[]);add(0,forward+[(n,0,0,1)])
        assert len(frames)==8;return frames
    for root in sorted({0,n//2,n-1}):
        add(root,[]);add(root,simple(pairs));add(root,forward);add(root,backward)
    add(0,simple((0,i) for i in range(n)));add(n-1,simple((i,n-1) for i in range(n)))
    add(0,simple((i,(i+1)%n) for i in range(n)));add(0,diamond);add(n//2,split)
    add(n-1,simple((i,i) for i in range(n))+[(i,i,0,1) for i in range(n)])
    if n>1:
        add(0,forward+[(0,1,0,1)]);add(0,forward+[(0,1,0,1),(0,1,1,1)])
    if n<=3:
        for bits in range(1<<len(pairs)):
            for root in range(n):add(root,simple(p for k,p in enumerate(pairs) if bits>>k&1))
    rng=random.Random(20261313+n)
    for k in range(10):
        edges=[e for e in pairs if rng.randrange(5)<(k%3+1)];root=rng.randrange(n)
        raw=simple(edges);rng.shuffle(raw);add(root,[(n,0xffffffff,1,0)]+raw)
        if k<4:
            replay=simple(edges);rng.shuffle(replay);add(root,replay)
    add(n,[]);add(0xffffffff,[]);add(0,[(n,0,1,1)]);add(n-1,[(0,0xffffffff,0,1)])
    add(0xffffffff,forward+[(0xffffffff,0xffffffff,1,1)])
    return frames

def pack(fields):
    value=0
    for datum,width in fields:
        assert 0<=datum<1<<width,(datum,width)
        value=(value<<width)|datum
    return f'{value:x}'

def vectors(n,t):
    inputs=[];refs=[]
    for index,(root,raw) in enumerate(fixtures(n)):
        edges=set();errors=int(root>=n)<<1;tag=(index*19+7)&((1<<t)-1)
        for k,(a,b,present,keep) in enumerate(raw):
            if keep:
                if a>=n or b>=n:errors|=1
                elif present:edges.add((a,b))
                else:edges.discard((a,b))
            inputs.append(pack([(a,32),(b,32),(root if k==0 else 0xffffffff,32),(present,1),(keep,1),
                                (int(k==len(raw)-1),1),(tag if k==0 else tag^((1<<t)-1),t)]))
        refs.append(dict(errors=errors,tag=tag,root=root,edges=sorted(edges),expected=[] if errors else reference(n,edges,root)))
    return inputs,refs

def verify(path,refs,n,t):
    iw=max(1,(n-1).bit_length());cw=n.bit_length()
    fields=[('keep',1),('last',1),('errors',2),('tag',t),('node',iw),('root',iw),('idom',iw),
            ('reachable',1),('idom_valid',1),('depth',cw),('dom_count',cw),('subtree_count',cw),
            ('reached_count',cw),('dominators',n),('dominated',n)]
    actual=[]
    for line in path.read_text().splitlines():
        bits=int(line,16);row={}
        for key,width in reversed(fields):row[key]=bits&((1<<width)-1);bits>>=width
        assert bits==0;actual.append(row)
    cursor=0;replay={};replays=unreachable=deep=0
    for ref in refs:
        count=1 if ref['errors'] else n;chunk=actual[cursor:cursor+count];cursor+=count;assert len(chunk)==count
        for k,row in enumerate(chunk):
            expected={key:0 for key,width in fields}
            expected.update(keep=int(not ref['errors']),last=int(k==count-1),errors=ref['errors'],tag=ref['tag'])
            if not ref['errors']:expected.update(ref['expected'][k])
            assert row==expected,(ref,k,row,expected)
        if not ref['errors']:
            solution=tuple(tuple(r[key] for key,width in fields if key!='tag') for r in chunk)
            key=(ref['root'],tuple(tuple(e) for e in ref['edges']))
            if key in replay:assert replay[key]==solution;replays+=1
            replay[key]=solution;unreachable+=sum(not r['reachable'] for r in chunk);deep+=sum(r['depth']>1 for r in chunk)
    assert cursor==len(actual)
    return dict(deterministic_replays=replays,unreachable_records=unreachable,depth_above_one_records=deep,
                actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

def main():
    previous=json.loads((ROOT/'verification.json').read_text()) if (ROOT/'verification.json').is_file() else {}
    if any(c.get('status')=='TIMEOUT_NOT_RUN' for c in previous.get('commands',[])):
        raise RuntimeError('Previous timeout is terminal for this fixed check plan; no automatic retry.')
    prior=previous.get('prior_failed_attempts',[])
    if previous.get('commands') and 'UNIT_SIM_PASS' not in previous.get('status',[]):prior=prior+[previous]
    files=sorted(p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json')
    report=dict(baseline_commit=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],prior_failed_attempts=prior,
                source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    def save():(ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(cmd,cwd,negative=False):
        command=[str(x) for x in cmd]
        try:p=subprocess.run(command,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired:
            report['commands'].append(dict(argv=command,returncode=None,status='TIMEOUT_NOT_RUN',timeout_seconds=20));save();raise
        record=dict(argv=command,returncode=p.returncode,stdout=p.stdout,stderr=p.stderr,timeout_seconds=20)
        report['commands'].append(record);save()
        if negative:assert p.returncode>0 and 'directed_dominators_invalid_parameters__see_README' in p.stderr,record
        else:assert p.returncode==0 and not p.stderr,record
        return p.stdout
    run([iv,'-V'],ROOT)
    run([iv,'-g2012','-Wall','-tnull','-s','directed_dominators','-s','dependency_gate16','-f','files.f','examples/dependency_gate16.sv'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_dominators_') as tmp:
        target=Path(tmp)
        for n,t in PROFILES:
            inputs,refs=vectors(n,t);assert len(inputs)<=100001
            data=('\n'.join(inputs)+'\n').encode();(target/'input.hex').write_bytes(data)
            run([iv,'-g2012','-Wall','-s','tb_directed_dominators',f'-Ptb_directed_dominators.N={n}',
                 f'-Ptb_directed_dominators.T={t}','-o','sim.vvp',ROOT/'rtl/directed_dominators.sv',ROOT/'sim/tb_directed_dominators.sv'],target)
            outcount=sum(1 if r['errors'] else n for r in refs)
            output=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',
                        f'+COUNT={len(inputs)}',f'+OUTCOUNT={outcount}'],target)
            cov=re.search(r'PASS dominators records=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) max_latency=(\d+) bound=(\d+) max_passes=(\d+) writes=(\d+)',output);assert cov,output
            assert int(cov[1])==outcount and int(cov[2])>0 and int(cov[3])>0 and int(cov[4])==(24 if n==1 else 28)
            report['profiles'].append(dict(NUM_NODES=n,TAG_W=t,status='PASS',frames=len(refs),input_tokens=len(inputs),
                output_tokens=outcount,bad_frames=sum(bool(r['errors']) for r in refs),reset_probes=int(cov[4]),
                blocked_cycles=int(cov[2]),held_cycles=int(cov[3]),maximum_checked_first_latency=int(cov[5]),
                conservative_first_bound=int(cov[6]),maximum_observed_passes=int(cov[7]),dominator_writes=int(cov[8]),output=output.strip(),
                input_sha256=hashlib.sha256(data).hexdigest(),**verify(target/'actual.hex',refs,n,t)))
            save();print(f'PASS dominators N={n} frames={len(refs)}',flush=True)
        invalid=[('NUM_NODES',0),('NUM_NODES',65),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:run([iv,'-g2012','-tnull','-s','directed_dominators',f'-Pdirected_dominators.{key}={value}','-f','files.f'],ROOT,True)
    for p in files:
        raw=p.read_bytes();raw.decode('utf-8',errors='strict');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
    report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],oracle='Delete each candidate vertex, independent BFS from root, dominator definition; parent chain crosscheck. No RTL predecessor intersection recurrence.',
                  invalid_parameter_rejections=4,frames=sum(p['frames'] for p in report['profiles']),
                  output_tokens=sum(p['output_tokens'] for p in report['profiles']),reset_probes=sum(p['reset_probes'] for p in report['profiles']),
                  not_run=['synthesis','PnR','STA','hardware','expanded regression'])
    save();print(f'PASS dominators profiles={len(report["profiles"])} frames={report["frames"]} commands={len(report["commands"])}')
if __name__=='__main__':main()
