#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixed finite checks; all-pairs and simple-path/cycle independent oracles."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
PROFILES=[(1,1,1),(2,2,3),(3,4,5),(5,8,8),(8,8,8),(32,16,32)]

def floyd(graph,n,source):
    d=[[None]*n for _ in range(n)]
    for i in range(n):d[i][i]=0
    for (u,v),w in graph.items():d[u][v]=w if d[u][v] is None else min(d[u][v],w)
    for k in range(n):
        for i in range(n):
            if d[i][k] is not None:
                for j in range(n):
                    if d[k][j] is not None:
                        trial=d[i][k]+d[k][j]
                        if d[i][j] is None or trial<d[i][j]:d[i][j]=trial
    neg={v for v in range(n) if any(d[source][k] is not None and d[k][k]<0 and d[k][v] is not None for k in range(n))}
    return [(int(d[source][v] is not None),int(v in neg),0 if d[source][v] is None or v in neg else d[source][v]) for v in range(n)]

def paths_cycles(graph,n,source):
    neighbors={u:[(v,w) for (a,v),w in graph.items() if a==u] for u in range(n)}
    best=[None]*n
    def visit(u,seen,cost):
        if best[u] is None or cost<best[u]:best[u]=cost
        for v,w in neighbors[u]:
            if v not in seen:visit(v,seen|{v},cost+w)
    visit(source,{source},0)
    def reachable(start):
        done={start};todo=[start]
        while todo:
            for v,w in neighbors[todo.pop()]:
                if v not in done:done.add(v);todo.append(v)
        return done
    source_reach=reachable(source);negative=set();cycle_count=0
    for length in range(1,n+1):
        for cycle in itertools.permutations(range(n),length):
            if cycle[0]!=min(cycle):continue
            edges=list(zip(cycle,cycle[1:]+cycle[:1]))
            if all(edge in graph for edge in edges) and sum(graph[e] for e in edges)<0:
                cycle_count+=1
                if cycle[0] in source_reach:negative.update(reachable(cycle[0]))
    rows=[(int(v in source_reach),int(v in negative),0 if v not in source_reach or v in negative else best[v]) for v in range(n)]
    return rows,cycle_count

def fixtures(n,w):
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;cases=[]
    def add(edges,source=0,**opts):cases.append((list(edges),source,opts))
    edge=lambda u,v,c,p=1:(u,v,c,p,1)
    add([]);add([],n-1)
    add([edge(i,i+1,lo) for i in range(n-1)])
    add([edge(i,i+1,hi) for i in range(n-1)])
    add([edge(i,i-1,lo) for i in range(n-1,0,-1)],n-1)
    add([edge(0,0,lo)]);add([edge(0,0,hi)])
    add([edge(i,(i+1)%n,0) for i in range(n)])
    add([edge(i,i+1,0) for i in range(n-1)]+[edge(n-1,n-1,-1)])
    # Late negative selfloop, descending edges propagate one new flag/pass.
    add([edge(i,i+1,0) for i in range(n-1)]+[edge(i,i-1,0) for i in range(1,n)]+[edge(n-1,n-1,-1)],worst=True)
    if n>1:
        add([edge(i,i+1,-1) for i in range(n-2)]+[edge(n-1,n-1,-1)])
        add([edge(0,1,0),edge(1,1,-1)]+([edge(0,n-1,hi)] if n>2 else []))
        add([edge(i,(i+1 if i<n-1 else 1),lo) for i in range(1,n)])
    target=n-1
    add([edge(0,target,lo),edge(0,target,hi)])
    add([edge(0,target,lo),edge(0,target,hi,0)])
    add([edge(0,target,lo),edge(0,target,hi,0),edge(0,target,-1)],masks=True)
    if n==2:
        for choices in itertools.product([None,-1,0,1],repeat=4):
            add([edge(i//2,i%2,v) for i,v in enumerate(choices) if v is not None])
    rng=random.Random(20261717+n+w)
    for k in range(8):
        updates=[edge(u,v,rng.randint(lo,hi)) for u in range(n) for v in range(n) if rng.randrange(5)==0]
        for j in range(8):updates.append(edge(rng.randrange(n),rng.randrange(n),rng.randint(lo,hi),int(j%3!=0)))
        rng.shuffle(updates);add(updates,rng.randrange(n),masks=k%2==0)
    for code in range(8):
        updates=[edge(0,n-1,0)]
        if code&2:updates.append(edge(0xffffffff,0,-1,0))
        add(updates,0xffffffff if code&1 else 0,bad_first=bool(code&4))
    add([edge(0,target,0)],extra_first=True)
    return cases

def pack(fields):
    word=0
    for value,width in fields:
        assert 0<=value<1<<width
        word=(word<<width)|value
    return f'{word:x}'

def vectors(n,w,t):
    tokens=[];refs=[];enum_checks=negative_cycles=0
    for fi,(updates,source,opts) in enumerate(fixtures(n,w)):
        stream=list(updates)
        if opts.get('masks'):stream=[(0xffffffff,0xffffffff,-(1<<(w-1)),1,0)]+stream+[(0xffffffff,0xffffffff,0,0,0)]
        if not stream:stream=[(0xffffffff,0xffffffff,0,0,0)]
        if opts.get('extra_first'):stream.append((0xffffffff,0xffffffff,0,0,0))
        graph={};error=int(source>=n);tag=(fi*0x10203+19)&((1<<t)-1)
        for j,(u,v,cost,present,keep) in enumerate(stream):
            first=int(j==0)
            if opts.get('bad_first') and j==0:first=0
            if opts.get('extra_first') and j==len(stream)-1:first=1
            if first!=int(j==0):error|=4
            if keep:
                if u>=n or v>=n:error|=2
                elif present:graph[u,v]=cost
                else:graph.pop((u,v),None)
            tokens.append(pack([(u,32),(v,32),(source if j==0 else 0xffffffff,32),
                (cost&((1<<w)-1),w),(present,1),(keep,1),(first,1),(int(j==len(stream)-1),1),
                (tag if j==0 else tag^((1<<t)-1),t)]))
        expected=None
        if not error:
            expected=floyd(graph,n,source)
            if n<=5:
                other,cycles=paths_cycles(graph,n,source);assert expected==other,(n,fi,graph,expected,other)
                enum_checks+=1;negative_cycles+=cycles
        refs.append(dict(graph=graph,source=source,tag=tag,error=error,expected=expected,worst=opts.get('worst',False)))
    assert set(r['error'] for r in refs)==set(range(8))
    return tokens,refs,dict(enumeration_crosschecks=enum_checks,enumerated_negative_cycles=negative_cycles)

def verify(path,meta_path,refs,n,w,t):
    iw=max(1,(n-1).bit_length());dw=w+(n-1).bit_length()+1
    fields=[('vertex',iw),('source',iw),('distance',dw),('reachable',1),('negative_infinite',1),
        ('has_negative_cycle',1),('keep',1),('first',1),('last',1),('tag',t),('errors',3)]
    actual=[]
    for line in path.read_text().splitlines():
        bits=int(line,16);row={}
        for key,width in reversed(fields):row[key]=bits&((1<<width)-1);bits>>=width
        assert bits==0
        if row['distance']>>(dw-1):row['distance']-=1<<dw
        actual.append(row)
    meta=[tuple(map(int,line.split())) for line in meta_path.read_text().splitlines()];assert len(meta)==len(refs)
    cursor=0;finite=unreachable=neginf=negative_finite=positive_finite=cycle_frames=unaffected=0;worst_checks=0
    for fi,ref in enumerate(refs):
        outsize=1 if ref['error'] else n;rows=actual[cursor:cursor+outsize];cursor+=outsize;assert len(rows)==outsize
        if ref['error']:
            expected={k:0 for k,width in fields};expected.update(first=1,last=1,tag=ref['tag'],errors=ref['error'])
            assert rows==[expected],(fi,rows,expected)
            assert meta[fi]==(0,0,1)
        else:
            has_cycle=int(any(v[1] for v in ref['expected']));cycle_frames+=has_cycle
            for vertex,(reach,negative,distance) in enumerate(ref['expected']):
                expected=dict(vertex=vertex,source=ref['source'],distance=distance,reachable=reach,
                    negative_infinite=negative,has_negative_cycle=has_cycle,keep=1,first=int(vertex==0),
                    last=int(vertex==n-1),tag=ref['tag'],errors=0)
                assert rows[vertex]==expected,(fi,vertex,rows[vertex],expected)
                unreachable+=not reach;neginf+=negative;finite+=reach and not negative
                negative_finite+=reach and not negative and distance<0
                positive_finite+=reach and not negative and distance>0
                unaffected+=has_cycle and reach and not negative
            k,p,latency=meta[fi]
            assert 1<=k<=n and 0<=p<=n-1 and latency==n+k*(n*(2*n+3)+1)+p*(2*n*n+1)+2
            if ref['worst']:
                assert k==n and p==n-1,(n,k,p)
                worst_checks+=1
    assert cursor==len(actual) and worst_checks==1
    return dict(output_tokens=len(actual),finite_vertices=finite,unreachable_vertices=unreachable,negative_infinite_vertices=neginf,
        negative_finite_distances=negative_finite,positive_finite_distances=positive_finite,
        reachable_negative_cycle_frames=cycle_frames,unaffected_finite_with_global_cycle=unaffected,worst_bound_checks=worst_checks,
        actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),timing_sha256=hashlib.sha256(meta_path.read_bytes()).hexdigest())

def main():
    path=ROOT/'verification.json';previous=json.loads(path.read_text()) if path.exists() else {}
    if any(c.get('status')=='TIMEOUT_NOT_RUN' for c in previous.get('commands',[])):raise RuntimeError('Terminal timeout; no retry')
    if 'UNIT_SIM_PASS' in previous.get('status',[]):raise RuntimeError('Qualified matrix already passed; no redundant rerun')
    prior=previous.get('prior_failed_attempts',[])
    if previous.get('commands'):prior=prior+[previous]
    files=sorted(p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json')
    report=dict(baseline='c4be2839103480e23976f16f8a41d06fd93057c8',status=['NOT_RUN','HW_UNVERIFIED'],commands=[],profiles=[],
        prior_failed_attempts=prior,source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    def save():path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf8',newline='\n')
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);save();assert iv and vv
    plan=json.loads((ROOT/'TEST_PLAN.json').read_text());assert plan['profiles']==[list(x) for x in PROFILES]
    # Deterministic plans and all oracle crosschecks are frozen before the first HDL process.
    plans=[]
    for n,w,t in PROFILES:
        tokens,refs,counts=vectors(n,w,t);assert len(tokens)<100001
        data=('\n'.join(tokens)+'\n').encode();plans.append((n,w,t,tokens,refs,counts,data))
    report['frozen_inputs']=[dict(NUM_NODES=n,WEIGHT_W=w,TAG_W=t,frames=len(refs),tokens=len(tokens),sha256=hashlib.sha256(data).hexdigest()) for n,w,t,tokens,refs,counts,data in plans];save()
    def run(argv,cwd,negative=False,version=False):
        argv=list(map(str,argv))
        try:p=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as exc:
            decode=lambda v:v.decode(errors='replace') if isinstance(v,bytes) else v or ''
            report['commands'].append(dict(argv=argv,returncode=None,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=decode(exc.stdout),stderr=decode(exc.stderr)));save();raise
        good=(p.returncode>0 and 'signed_sssp_invalid_parameters__see_README' in p.stderr) if negative else p.returncode==0 and (version or not p.stderr)
        rec=dict(argv=argv,returncode=p.returncode,status='PASS' if good else 'FAIL',stdout=p.stdout,stderr=p.stderr,timeout_seconds=20)
        report['commands'].append(rec);save();assert good,rec;return p.stdout
    run([iv,'-V'],ROOT,version=True)
    run([iv,'-g2012','-Wall','-tnull','-s','signed_sssp','-f','files.f'],ROOT)
    run([iv,'-g2012','-Wall','-tnull','-s','signed_routes8','-f','files.f','example/signed_routes8.sv'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_signed_sssp_b17_') as tmp:
        folder=Path(tmp)
        for n,w,t,tokens,refs,counts,data in plans:
            (folder/'input.hex').write_bytes(data)
            run([iv,'-g2012','-Wall','-s','tb_signed_sssp',f'-Ptb_signed_sssp.N={n}',f'-Ptb_signed_sssp.W={w}',
                f'-Ptb_signed_sssp.T={t}','-o','sim.vvp',ROOT/'rtl/signed_sssp.sv',ROOT/'sim/tb_signed_sssp.sv'],folder)
            output=run([vv,'sim.vvp',f'+INPUT={folder/"input.hex"}',f'+OUTPUT={folder/"actual.hex"}',
                f'+SUMMARY={folder/"summary.json"}',f'+META={folder/"timing.txt"}',f'+TOKENS={len(tokens)}',f'+FRAMES={len(refs)}'],folder)
            assert f'PASS signed_sssp N={n} W={w} T={t}' in output,output
            cov=json.loads((folder/'summary.json').read_text());checked=verify(folder/'actual.hex',folder/'timing.txt',refs,n,w,t)
            assert cov['inputs']==len(tokens) and cov['frames']==len(refs)==cov['latency_checks'] and cov['outputs']==checked['output_tokens']
            assert cov['resets']==cov['fresh_checks']==(16 if n==1 else 23) and cov['held']>0 and cov['blocked']>0
            report['profiles'].append(dict(NUM_NODES=n,WEIGHT_W=w,TAG_W=t,status='PASS',
                bad_frames=sum(bool(r['error']) for r in refs),input_sha256=hashlib.sha256(data).hexdigest(),output=output.strip(),**cov,**counts,**checked))
            save();print(f'PASS signed_sssp N={n} frames={len(refs)}',flush=True)
        for key,value in [('NUM_NODES',0),('NUM_NODES',33),('WEIGHT_W',0),('WEIGHT_W',17),('TAG_W',0),('TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','signed_sssp',f'-Psigned_sssp.{key}={value}','-f','files.f'],ROOT,negative=True)
    for p in files:
        b=p.read_bytes();b.decode('utf8');assert b'\r' not in b and not b.startswith(b'\xef\xbb\xbf')
        assert hashlib.sha256(b).hexdigest()==report['source_sha256'][p.relative_to(ROOT).as_posix()]
    totals={k:sum(p[k] for p in report['profiles']) for k in ['frames','inputs','outputs','relaxations','propagations','cycles','held','blocked',
        'resets','fresh_checks','latency_checks','enumeration_crosschecks','enumerated_negative_cycles','finite_vertices','unreachable_vertices',
        'negative_infinite_vertices','negative_finite_distances','positive_finite_distances','reachable_negative_cycle_frames','unaffected_finite_with_global_cycle','worst_bound_checks']}
    report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],totals=totals,invalid_parameter_rejections=6,
        oracle='All-pairs Floyd-Warshall signed integer distances + negative diagonal reach; independent small simple-path/simple-cycle enumeration',
        not_run=['synthesis','PnR','STA','board','expanded regression'])
    save();print(f'PASS signed_sssp profiles=6 frames={totals["frames"]} records={len(report["commands"])}')

if __name__=='__main__':main()
