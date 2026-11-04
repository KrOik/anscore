#!/usr/bin/env python3
"""Fixed finite profiles; independent BFS, iterative Kosaraju and Kahn oracles."""
import collections
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
BASELINE='d35ce742b34ffa7afebffe0b9f6705a825f469e1'
PROFILES=[(1,1),(2,3),(3,8),(7,8),(16,8),(64,32)]

def reference(n,edges):
    adj=[set() for _ in range(n)];rev=[set() for _ in range(n)]
    for a,b in edges:adj[a].add(b);rev[b].add(a)
    reach=[]
    for start in range(n):
        seen={start};todo=collections.deque([start])
        while todo:
            for v in adj[todo.popleft()]:
                if v not in seen:seen.add(v);todo.append(v)
        reach.append(seen)
    # Iterative DFS finish order, then reverse-graph floods: no Warshall recurrence.
    seen=set();order=[]
    for start in range(n):
        if start in seen:continue
        seen.add(start);stack=[(start,iter(sorted(adj[start])))]
        while stack:
            u,neighbors=stack[-1]
            v=next(neighbors,None)
            if v is None:order.append(u);stack.pop()
            elif v not in seen:seen.add(v);stack.append((v,iter(sorted(adj[v]))))
    unseen=set(range(n));groups=[]
    for start in reversed(order):
        if start not in unseen:continue
        unseen.remove(start);group={start};todo=[start]
        while todo:
            for v in rev[todo.pop()] & unseen:unseen.remove(v);group.add(v);todo.append(v)
        groups.append(group)
    membership={v:g for g in groups for v in g}
    degree=[len(rev[i]) for i in range(n)];ready=collections.deque(i for i in range(n) if degree[i]==0);removed=0
    while ready:
        u=ready.popleft();removed+=1
        for v in adj[u]:
            degree[v]-=1
            if degree[v]==0:ready.append(v)
    rows=[]
    for i in range(n):
        group=membership[i];assert group=={j for j in range(n) if j in reach[i] and i in reach[j]}
        rows.append(dict(node=i,root=min(group),size=len(group),components=len(groups),
                         forward_count=len(reach[i]),backward_count=sum(i in r for r in reach),
                         reachable=sum(1<<j for j in reach[i]),members=sum(1<<j for j in group),
                         cyclic=int(len(group)>1 or (i,i) in edges),acyclic=int(removed==n)))
    return rows

def fixtures(n):
    frames=[];pairs=list(itertools.product(range(n),repeat=2))
    def add(raw):frames.append(raw or [(0xffffffff,0xffffffff,1,0)])
    def simple(edges):return [(a,b,1,1) for a,b in edges]
    chain=simple((i,i+1) for i in range(n-1))
    add([]);add(simple(pairs));add(chain);add(simple((0,i) for i in range(1,n)))
    add(simple((i,(i+1)%n) for i in range(n)))
    add(simple((i,j) for i in range(n) for j in range(n) if i//3==j//3))
    add(simple((i,i) for i in range(n)));add(simple((i,i) for i in range(n))+[(i,i,0,1) for i in range(n)])
    if n>1:
        add(chain+[(0,1,0,1)]);add(chain+[(0,1,0,1),(0,1,1,1)])
        add(simple((i,j) for i in range(n) for j in range(n) if i//2==j//2)+chain)
    if n<=3:
        for bits in range(1<<len(pairs)):add(simple(p for k,p in enumerate(pairs) if bits>>k&1))
    rng=random.Random(20261212+n)
    for k in range(10):
        edges=[e for e in pairs if rng.randrange(5)<(k%3+1)]
        raw=simple(edges);rng.shuffle(raw);add([(n,0xffffffff,1,0)]+raw)
        if k<4:
            replay=simple(edges);rng.shuffle(replay);add(replay)
    add([(n,0,1,1)]);add([(0,0xffffffff,0,1)]);add(chain+[(0xffffffff,0xffffffff,1,1)])
    return frames

def pack(fields):
    value=0
    for datum,width in fields:
        assert 0<=datum<1<<width,(datum,width)
        value=(value<<width)|datum
    return f'{value:x}'

def vectors(n,t):
    inputs=[];refs=[]
    for index,raw in enumerate(fixtures(n)):
        edges=set();bad=False;tag=(index*19+7)&((1<<t)-1)
        for k,(a,b,present,keep) in enumerate(raw):
            if keep:
                if a>=n or b>=n:bad=True
                elif present:edges.add((a,b))
                else:edges.discard((a,b))
            inputs.append(pack([(a,32),(b,32),(present,1),(keep,1),(int(k==len(raw)-1),1),
                                (tag if k==0 else tag^((1<<t)-1),t)]))
        refs.append({'bad':bad,'tag':tag,'edges':sorted(edges),'expected':[] if bad else reference(n,edges)})
    return inputs,refs

def verify(path,refs,n,t):
    iw=max(1,(n-1).bit_length());cw=n.bit_length()
    fields=[('keep',1),('last',1),('error',1),('tag',t),('node',iw),('root',iw),('size',cw),
            ('components',cw),('forward_count',cw),('backward_count',cw),('reachable',n),('members',n),('cyclic',1),('acyclic',1)]
    actual=[]
    for line in path.read_text().splitlines():
        bits=int(line,16);row={}
        for key,width in reversed(fields):row[key]=bits&((1<<width)-1);bits>>=width
        assert bits==0;actual.append(row)
    cursor=0;replay={};replays=0;cyclic_nodes=0;dag_frames=0
    for ref in refs:
        count=1 if ref['bad'] else n;chunk=actual[cursor:cursor+count];cursor+=count;assert len(chunk)==count
        for k,row in enumerate(chunk):
            expected={key:0 for key,width in fields}
            expected.update(keep=int(not ref['bad']),last=int(k==count-1),error=int(ref['bad']),tag=ref['tag'])
            if not ref['bad']:expected.update(ref['expected'][k])
            assert row==expected,(ref,k,row,expected)
        if not ref['bad']:
            solution=tuple(tuple(r[key] for key,width in fields if key!='tag') for r in chunk)
            key=tuple(tuple(e) for e in ref['edges'])
            if key in replay:assert replay[key]==solution;replays+=1
            replay[key]=solution;cyclic_nodes+=sum(r['cyclic'] for r in chunk);dag_frames+=chunk[0]['acyclic']
    assert cursor==len(actual)
    return {'deterministic_replays':replays,'cyclic_nodes_checked':cyclic_nodes,'dag_frames':dag_frames,
            'actual_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}

def main():
    report={'baseline_commit':BASELINE,'status':['NOT_RUN','HW_UNVERIFIED'],'profiles':[],'commands':[]}
    def save():
        (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save()
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(cmd,cwd,negative=False):
        command=[str(x) for x in cmd]
        try:p=subprocess.run(command,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired:
            report['commands'].append({'argv':command,'returncode':None,'status':'TIMEOUT_NOT_RUN','timeout_seconds':20});save();raise
        record={'argv':command,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'timeout_seconds':20}
        report['commands'].append(record);save()
        if negative:assert p.returncode>0 and 'directed_reachability_invalid_parameters__see_README' in p.stderr,record
        else:assert p.returncode==0 and not p.stderr,record
        return p.stdout
    run([iv,'-V'],ROOT)
    run([iv,'-g2012','-Wall','-tnull','-s','directed_reachability','-s','directed_routes16','-f','files.f','examples/directed_routes16.sv'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_reach_') as tmp:
        target=Path(tmp)
        for n,t in PROFILES:
            inputs,refs=vectors(n,t);assert len(inputs)<=100001
            data=('\n'.join(inputs)+'\n').encode();(target/'input.hex').write_bytes(data)
            run([iv,'-g2012','-Wall','-s','tb_directed_reachability',f'-Ptb_directed_reachability.N={n}',
                 f'-Ptb_directed_reachability.T={t}','-o','sim.vvp',ROOT/'rtl/directed_reachability.sv',ROOT/'sim/tb_directed_reachability.sv'],target)
            outcount=sum(1 if r['bad'] else n for r in refs)
            output=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',
                        f'+COUNT={len(inputs)}',f'+OUTCOUNT={outcount}'],target)
            cov=re.search(r'PASS reach records=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) max_latency=(\d+) bound=(\d+)',output);assert cov,output
            assert int(cov[1])==outcount and int(cov[2])>0 and int(cov[3])>0 and int(cov[4])==(19 if n==1 else 21)
            report['profiles'].append({'NUM_NODES':n,'TAG_W':t,'status':'PASS','frames':len(refs),'input_tokens':len(inputs),
                 'output_tokens':outcount,'bad_frames':sum(r['bad'] for r in refs),'reset_probes':int(cov[4]),
                 'blocked_cycles':int(cov[2]),'held_cycles':int(cov[3]),'maximum_checked_first_latency':int(cov[5]),
                 'conservative_first_bound':int(cov[6]),'output':output.strip(),
                 'input_sha256':hashlib.sha256(data).hexdigest(),**verify(target/'actual.hex',refs,n,t)})
            save();print(f'PASS reach N={n} frames={len(refs)}',flush=True)
        invalid=[('NUM_NODES',0),('NUM_NODES',65),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','directed_reachability',f'-Pdirected_reachability.{key}={value}','-f','files.f'],ROOT,True)
    files=['.gitattributes','files.f','rtl/directed_reachability.sv','examples/directed_routes16.sv','sim/tb_directed_reachability.sv','sim/run.py']
    for f in files:
        raw=(ROOT/f).read_bytes();raw.decode('utf-8',errors='strict');assert b'\r' not in raw
    report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
                  oracle='BFS reach sets; iterative Kosaraju SCC; independent Kahn DAG predicate; no RTL Warshall recurrence',
                  invalid_parameter_rejections=len(invalid),frames=sum(p['frames'] for p in report['profiles']),
                  output_tokens=sum(p['output_tokens'] for p in report['profiles']),reset_probes=sum(p['reset_probes'] for p in report['profiles']),
                  source_sha256={f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in files},
                  not_run=['synthesis','PnR','STA','hardware','expanded regression'])
    save();print(f'PASS reach profiles={len(report["profiles"])} frames={report["frames"]} commands={len(report["commands"])}')
if __name__=='__main__':main()
