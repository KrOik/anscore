#!/usr/bin/env python3
"""Finite maximum-flow checks: independent preflow, cuts and output certificates."""
from __future__ import annotations
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
BASELINE='807d992b6b0e793c08ceba2d44993d21c1dd1583'


def push_relabel(cap,s,t):
    """Independent integer preflow with local discharge/relabel, without paths."""
    n=len(cap);r=[row[:] for row in cap]
    for i in range(n):r[i][i]=0
    height=[0]*n;height[s]=n;excess=[0]*n;current=[0]*n
    for v in range(n):
        if v!=s:
            amount=r[s][v];r[s][v]-=amount;r[v][s]+=amount
            excess[s]-=amount;excess[v]+=amount
    actions=0
    while True:
        u=next((i for i in range(n) if i not in (s,t) and excess[i]>0),None)
        if u is None:break
        while excess[u]:
            actions+=1
            assert actions<2000000,'oracle finite guard'
            if current[u]==n:
                height[u]=1+min(height[v] for v in range(n) if r[u][v]>0)
                current[u]=0
            else:
                v=current[u]
                if r[u][v] and height[u]==height[v]+1:
                    amount=min(excess[u],r[u][v]);r[u][v]-=amount;r[v][u]+=amount
                    excess[u]-=amount;excess[v]+=amount
                else:current[u]+=1
    assert excess[t]==-excess[s]
    return excess[t]


def exhaustive_cut(cap,s,t):
    others=[i for i in range(len(cap)) if i not in (s,t)];best=None
    for mask in range(1<<len(others)):
        side={s}|{v for i,v in enumerate(others) if mask>>i&1}
        cost=sum(cap[u][v] for u in side for v in range(len(cap)) if v not in side)
        if best is None or cost<best:best=cost
    return best


def fixtures(n,w):
    maximum=(1<<w)-1;s=0;t=n-1
    # Each raw record is (from,to,capacity,keep); final assignment wins per pair.
    def included(edges):return [(u,v,c,1) for u,v,c in edges]
    frames=[]
    def add(edges,source=s,sink=t,masked=False):
        raw=included(edges)
        if masked:raw=[(0xffffffff,n+17,maximum,0)]+raw+[(n+7,0xffffffff,maximum,0)]
        if not raw:raw=[(n,n,maximum,0)]
        frames.append((raw,source,sink))
    add([]);add([(s,t,maximum)]);add([(s,t,0)])
    add([(i,i+1,maximum) for i in range(n-1)],masked=True)
    star=[(s,i,maximum) for i in range(1,n)]+[(i,t,maximum) for i in range(1,n-1)]
    add(star);add(star+[(v,u,c) for u,v,c in star])
    add([(i,i,maximum) for i in range(n)],masked=True)
    add([(s,t,maximum),(s,t,0)]);add([(s,t,0),(s,t,maximum)],masked=True)
    add([(t,s,maximum)]);add([(i,(i+1)%n,maximum) for i in range(n)])
    if n>=6:add([(0,1,1),(0,2,1),(1,3,1),(1,4,1),(2,3,1),(3,t,1),(4,t,1)])
    if n==2 and w==1:
        for data in itertools.product(range(2),repeat=4):
            add([(i//2,i%2,c) for i,c in enumerate(data)],source=t,sink=s,masked=True)
    if n==3:
        pairs=[(i,j) for i in range(n) for j in range(n) if i!=j]
        for data in itertools.product(range(2 if w==1 else 3),repeat=6):
            add([(u,v,c) for (u,v),c in zip(pairs,data)],masked=sum(data)%3==0)
    rng=random.Random(20261109+n*131+w)
    for i in range(22):
        source=rng.randrange(n);sink=rng.randrange(n-1);sink+=sink>=source
        edges=[(rng.randrange(n),rng.randrange(n),rng.randrange(maximum+1))
               for j in range(rng.randrange(min(n*n,48)+1))]
        add(edges,source,sink,True)
        if i<4:
            # Preserve last assignments, shuffle the equivalent final graph.
            final={(u,v):c for u,v,c in edges};replay=[(u,v,c) for (u,v),c in final.items()]
            rng.shuffle(replay);add(replay,source,sink)
    add([(n,0,maximum)]);add([(0,n,maximum)],masked=True)
    add([],n,t);add([],s,n);add([],s,s)
    add([(0xffffffff,n,maximum)],0xffffffff,0xffffffff)
    add([(s,t,maximum),(n,0,0)],n,n)
    return frames


def pack(fields):
    value=0
    for datum,width in fields:
        assert 0<=datum<1<<width,(datum,width)
        value=(value<<width)|datum
    return f'{value:x}'


def vectors(n,w,t):
    nw=max(1,(n-1).bit_length());fw=w+(n-1).bit_length()
    inputs=[];expected=[];bounds=[];references=[];crosschecks=0
    for index,(raw,source,sink) in enumerate(fixtures(n,w)):
        cap=[[0]*n for i in range(n)];error=(int(source>=n or sink>=n)<<1)|(int(source==sink)<<2)
        tag=(index*29+7)&((1<<t)-1)
        for j,(u,v,c,keep) in enumerate(raw):
            if keep:
                if u>=n or v>=n:error|=1
                else:cap[u][v]=c
            inputs.append(pack([(u,32),(v,32),(source if j==0 else 0xffffffff,32),
                                (sink if j==0 else 0xffffffff,32),(c,w),(keep,1),
                                (int(j==len(raw)-1),1),(tag if j==0 else tag^((1<<t)-1),t)]))
        value=0 if error else push_relabel(cap,source,sink)
        if not error and n<=8:
            assert value==exhaustive_cut(cap,source,sink);crosschecks+=1
        count=1 if error else n*n
        for q in range(count):
            u,v=divmod(q,n)
            expected.append(pack([(int(not error),1),(int(q==0),1),(int(q==count-1),1),
                                  (u if not error else 0,nw),(v if not error else 0,nw),
                                  (cap[u][v] if not error else 0,w),(value,fw),(error,3),
                                  (source,32),(sink,32),(tag,t)]))
        bounds.append('0' if error else f'{(value+1)*(2*n*n+n+2)+6*value*(n-1)+1:x}')
        references.append({'capacity':cap,'source':source,'sink':sink,'error':error,'value':value,'tokens':count})
    return inputs,expected,bounds,references,crosschecks


def certificates(path,references):
    actual=[tuple(int(x,16) for x in line.split()) for line in path.read_text().splitlines()]
    cursor=0;replays={};replay_checks=0;maximum_value=0
    for ref in references:
        chunk=actual[cursor:cursor+ref['tokens']];cursor+=ref['tokens'];assert len(chunk)==ref['tokens']
        if ref['error']:
            assert chunk==[(0,0)];continue
        cap=ref['capacity'];n=len(cap);s=ref['source'];t=ref['sink'];value=ref['value']
        flow=[[chunk[u*n+v][0] for v in range(n)] for u in range(n)]
        cut=chunk[0][1];assert 0<=cut<1<<n and all(x[1]==cut for x in chunk)
        for u in range(n):
            for v in range(n):
                assert 0<=flow[u][v]<=cap[u][v]
                assert flow[u][v]==0 or flow[v][u]==0
                if u==v:assert flow[u][v]==0
            balance=sum(flow[u])-sum(flow[v][u] for v in range(n))
            assert balance==(value if u==s else -value if u==t else 0)
        side={u for u in range(n) if cut>>u&1};assert s in side and t not in side
        assert sum(cap[u][v] for u in side for v in range(n) if v not in side)==value
        # Independently reconstruct residual reachability from the published flow.
        reached={s}
        while True:
            new=reached|{v for u in reached for v in range(n) if cap[u][v]-flow[u][v]+flow[v][u]>0}
            if new==reached:break
            reached=new
        assert reached==side
        key=(tuple(tuple(row) for row in cap),s,t)
        solution=(tuple(tuple(row) for row in flow),cut)
        if key in replays:assert replays[key]==solution;replay_checks+=1
        replays[key]=solution;maximum_value=max(maximum_value,value)
    assert cursor==len(actual)
    return {'certificate_frames':len(references),'deterministic_replays':replay_checks,
            'maximum_flow':maximum_value,'actual_results_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vv=os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    if not iv or not vv:raise RuntimeError('NOT_RUN: Icarus unavailable')
    commands=[];profiles=[]
    def run(command,cwd,negative=False):
        p=subprocess.run([str(x) for x in command],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        record={'argv':[str(x) for x in command],'returncode':p.returncode,'stdout':p.stdout,
                'stderr':p.stderr,'timeout_seconds':20};commands.append(record)
        if negative:assert p.returncode>0 and 'maxflow_mincut_invalid_parameters__see_README' in p.stderr,record
        else:assert p.returncode==0 and not p.stderr,record
        return p.stdout
    run([iv,'-V'],ROOT)
    run([iv,'-g2012','-Wall','-tnull','-s','maxflow_mincut','-s','flow8','-f','files.f','examples/flow8.sv'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_maxflow_') as tmp:
        target=Path(tmp)
        for n,w,t in [(2,1,1),(3,1,3),(3,2,8),(5,4,8),(8,16,8),(16,8,16),(32,24,32)]:
            ins,outs,bounds,refs,crosschecks=vectors(n,w,t)
            vectors_hash={}
            for name,rows in [('input.hex',ins),('expected.hex',outs),('bounds.hex',bounds)]:
                data=('\n'.join(rows)+'\n').encode('ascii');(target/name).write_bytes(data)
                vectors_hash[name]=hashlib.sha256(data).hexdigest()
            run([iv,'-g2012','-Wall','-s','tb',f'-Ptb.N={n}',f'-Ptb.W={w}',f'-Ptb.T={t}',
                 f'-Ptb.INPUTS={len(ins)}',f'-Ptb.OUTPUTS={len(outs)}',f'-Ptb.FRAMES={len(refs)}',
                 '-o','sim.vvp',ROOT/'rtl/maxflow_mincut.sv',ROOT/'sim/tb_maxflow_mincut.sv'],target)
            output=run([vv,'sim.vvp'],target);assert 'PASS maxflow' in output,output
            coverage=re.search(r'source_stalls=(\d+) held=(\d+) reset_probes=(\d+)',output);assert coverage
            assert int(coverage[1])>0 and int(coverage[2])>=3*len(outs) and int(coverage[3])==14
            profile={'NUM_NODES':n,'CAP_W':w,'TAG_W':t,'frames':len(refs),'input_tokens':len(ins),
                     'output_tokens':len(outs),'error_frames':sum(bool(r['error']) for r in refs),
                     'exhaustive_cut_crosschecks':crosschecks,'source_stalls':int(coverage[1]),
                     'held_cycles':int(coverage[2]),'reset_probes':int(coverage[3]),'status':'PASS',
                     'vectors_sha256':vectors_hash,'output':output.strip(),**certificates(target/'actual.txt',refs)}
            profiles.append(profile);print(f'PASS profile N={n} W={w} frames={len(refs)}',flush=True)
        invalid=[('NUM_NODES',1),('NUM_NODES',33),('CAP_W',0),('CAP_W',25),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','maxflow_mincut',f'-Pmaxflow_mincut.{key}={value}','-f','files.f'],ROOT,True)
    files=['.gitattributes','files.f','rtl/maxflow_mincut.sv','examples/flow8.sv','sim/tb_maxflow_mincut.sv','sim/run.py']
    for f in files:
        raw=(ROOT/f).read_bytes();raw.decode('utf-8',errors='strict');assert b'\r' not in raw
    report={'baseline_commit':BASELINE,'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
            'oracle':'independent push-relabel preflow; exhaustive cuts at N<=8; complete primal/cut/residual certificates',
            'profiles':profiles,'commands':commands,'invalid_parameter_rejections':len(invalid),
            'frames':sum(x['frames'] for x in profiles),'output_tokens':sum(x['output_tokens'] for x in profiles),
            'exhaustive_cut_crosschecks':sum(x['exhaustive_cut_crosschecks'] for x in profiles),
            'source_sha256':{f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in files},
            'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f'PASS maxflow profiles={len(profiles)} frames={report["frames"]} outputs={report["output_tokens"]} commands={len(commands)}')


if __name__=='__main__':main()
