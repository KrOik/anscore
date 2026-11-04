#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen offline discrete-Frechet matrix; each HDL child has a terminal20s cap."""
from collections import Counter, deque
import hashlib
import heapq
import itertools
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='c4be2839103480e23976f16f8a41d06fd93057c8'
PROFILES=[(2,1,1),(2,5,3),(4,4,8),(8,8,8),(12,16,8),(24,32,32)]
INVALID=[('COORD_W',1),('COORD_W',25),('MAX_POINTS',0),('MAX_POINTS',33),('TAG_W',0),('TAG_W',33)]
SOURCES=['.gitattributes','README.md','SOURCES.md','TEST_PLAN.json','files.f','example/files.f',
    'example/trajectory_match.sv','rtl/polyline_frechet.sv','sim/tb_polyline_frechet.sv','run_tests.py']
sha=lambda b:hashlib.sha256(b).hexdigest()


def reachable(dist,threshold):
    """Independent threshold graph search, with no numeric DP recurrence."""
    a,b=len(dist),len(dist[0]);seen=set();queue=deque()
    if dist[0][0]<=threshold:queue.append((0,0));seen.add((0,0))
    while queue:
        i,j=queue.popleft()
        for ni,nj in [(i+1,j),(i,j+1),(i+1,j+1)]:
            if ni<a and nj<b and (ni,nj) not in seen and dist[ni][nj]<=threshold:
                seen.add((ni,nj));queue.append((ni,nj))
    return (a-1,b-1) in seen


def oracle(a,b):
    """Heap minimax graph search; threshold BFS independently certifies the optimum."""
    na,nb=len(a),len(b)
    dist=[[(ax-bx)**2+(ay-by)**2 for bx,by in b] for ax,ay in a]
    score={};queue=[(dist[0][0],0,0)]
    while queue:
        value,i,j=heapq.heappop(queue)
        if (i,j) in score:continue
        score[i,j]=value
        for ni,nj in [(i+1,j),(i,j+1),(i+1,j+1)]:
            if ni<na and nj<nb and (ni,nj) not in score:
                heapq.heappush(queue,(max(value,dist[ni][nj]),ni,nj))
    result=score[na-1,nb-1]
    assert reachable(dist,result)
    smaller=[v for row in dist for v in row if v<result]
    assert not smaller or not reachable(dist,max(smaller))
    predecessor={};ties=0;directions=Counter()
    for i in range(na):
        for j in range(nb):
            candidates=[]
            if i and j:candidates.append((score[i-1,j-1],1))
            if i:candidates.append((score[i-1,j],2))
            if j:candidates.append((score[i,j-1],3))
            direction=min(candidates)[1] if candidates else 0
            if candidates:ties+=sum(v==min(candidates)[0] for v,d in candidates)>1
            predecessor[i,j]=direction;directions[str(direction)]+=1
    path=[];i,j=na-1,nb-1
    while True:
        path.append((i,j))
        if (i,j)==(0,0):break
        direction=predecessor[i,j]
        if direction==1:i-=1;j-=1
        elif direction==2:i-=1
        else:j-=1
    assert max(dist[i][j] for i,j in path)==result
    assert max(na,nb)<=len(path)<=na+nb-1
    return result,path,score,predecessor,dict(tied_predecessors=ties,**{f'direction_{d}':v for d,v in directions.items()})


def pack(fields):
    word=bits=0
    for v,w in fields:
        assert 0<=v<1<<w,(v,w)
        word=(word<<w)|v;bits+=w
    return word,bits


def fixtures(w,m,t):
    rng=random.Random(0x46524543484554+w*13+m*29+t);lo=-(1<<(w-1));hi=(1<<(w-1))-1
    p=(-1,0);q=(0,0);r=(1,0);corners=[(lo,lo),(hi,hi),(lo,hi),(hi,lo)]
    raw=[([p],[p]),([p],[q]),([corners[0]],[corners[1]]),([corners[1]],[corners[0]]),
        ([corners[2]],[corners[3]]),([q]*m,[q]*m),([corners[0]]*m,[corners[1]]*m),
        ([(lo if k%2==0 else hi,hi if k%3==0 else lo) for k in range(m)],
         [(hi if k%2==0 else lo,lo if k%3==0 else hi) for k in range(m)])]
    if m>=3:
        raw += [([p,q,r],[p,q,r]),([p,q,r],[r,q,p]),([p,q,r],[p,r]),([p,r],[p,q,r]),
            ([p,p,r],[p,r,r]),([p,q,p],[p,r,p]),([p,r,p],[q,p,q]),
            ([p,q,r,p],[p,r,q,p]) if m>=4 else ([p,q,r],[p,r,q])]
    # Exactly the nine reachable combinations of empty/good/overflow per list.
    options=[[],[q],[p]*(m+1)]
    raw += [(a,b) for a in options for b in options]
    for k in range(12):
        na=rng.randrange(1,m+1);nb=rng.randrange(1,m+1)
        domain=[corners[0],corners[1],p,q,r,(0,1),(1,-1)]
        raw.append(([rng.choice(domain) for _ in range(na)],[rng.choice(domain) for _ in range(nb)]))
    if (w,m)==(4,4):
        grid=[(-1,-1),(-1,1),(1,-1),(1,1)]
        curves=list(itertools.product(grid,repeat=2))
        raw += [(list(a),list(b)) for a in curves for b in curves]
        line=[[(v,0) for v in seq] for n in [1,2,3] for seq in itertools.product([-1,0],repeat=n)]
        raw += [(a,b) for a in line for b in line]
    iw=max(1,(m-1).bit_length());cw=max(1,m.bit_length());dw=2*w+1
    output_width=4+t+2*cw+dw+3+2*iw+4*w
    lines=[];records=[];coverage=Counter();frames=[];expected_ii=0;input_beats=total_cells=0
    for fi,(a,b) in enumerate(raw):
        error=int(not a)|(int(not b)<<1)|(int(len(a)>m)<<2)|(int(len(b)>m)<<3)
        aa=a[:m];bb=b[:m];na,nb=len(aa),len(bb)
        coverage[f'error_{error}']+=1
        tag=(1<<t)-1 if fi%7==0 else (0 if fi%7==1 else rng.getrandbits(t))
        beats=[]
        if fi%2==0:beats.append((0,lo,hi,0,hi,lo))
        if fi%4==0:
            for k in range(max(len(a),len(b))):
                if k<len(a):beats.append((1,*a[k],0,hi,lo))
                if k<len(b):beats.append((0,lo,hi,1,*b[k]))
        else:
            for k in range(max(len(a),len(b))):
                beats.append((int(k<len(a)),*(a[k] if k<len(a) else corners[0]),
                    int(k<len(b)),*(b[k] if k<len(b) else corners[1])))
        if not beats or fi%5==0:beats.append((0,hi,lo,0,lo,hi))
        assert len(beats)<=4*m+10
        if error:result=0;path=[(0,0)];scores={};predecessor={};latency=1
        else:
            result,path,scores,predecessor,stats=oracle(aa,bb);coverage.update(stats)
            total_cells+=na*nb;latency=3+na*nb*(2*w+4)
            coverage['valid']+=1;coverage['zero_distance' if result==0 else 'nonzero_distance']+=1
            coverage['unequal_length']+=na!=nb;coverage['repeated_points']+=len(set(aa))<na or len(set(bb))<nb
            hausdorff=max(max(min((ax-bx)**2+(ay-by)**2 for bx,by in bb) for ax,ay in aa),
                max(min((ax-bx)**2+(ay-by)**2 for ax,ay in aa) for bx,by in bb))
            assert result>=hausdorff
            coverage['order_sensitive_gap']+=result>hausdorff
            coverage['path_diagonal']+=any(a0-a1==1 and b0-b1==1 for (a0,b0),(a1,b1) in zip(path,path[1:]))
            coverage['path_up']+=any(a0-a1==1 and b0==b1 for (a0,b0),(a1,b1) in zip(path,path[1:]))
            coverage['path_left']+=any(a0==a1 and b0-b1==1 for (a0,b0),(a1,b1) in zip(path,path[1:]))
        lines.append(f'{len(beats)} {na} {nb} {error} {tag:x} {result:x} {latency} {len(path)} {len(scores)}\n')
        for k,beat in enumerate(beats):
            lines.append(' '.join(map(str,beat))+f' {int(k==len(beats)-1)} {tag if k==0 else rng.getrandbits(t):x}\n')
            if k and not(fi%3==0 and k%2==1):expected_ii+=1
        for i in range(na):
            for j in range(nb):
                if not error:lines.append(f'{scores[i,j]:x} {predecessor[i,j]}\n')
        words=[]
        for k,(i,j) in enumerate(path):
            ax,ay=(0,0) if error else aa[i];bx,by=(0,0) if error else bb[j]
            fields=[(error,4),(tag,t),(na,cw),(nb,cw),(result,dw),(int(k==0),1),(int(k==len(path)-1),1),
                (int(bool(error)),1),(i,iw),(j,iw)]
            fields += [(v&((1<<w)-1),w) for v in [ax,ay,bx,by]]
            word,bits=pack(fields);assert bits==output_width
            lines.append(f'{word:x}\n');words.append(word);records.append((word,latency if k==0 else -1))
        input_beats+=len(beats)
        frames.append(dict(beats=len(beats),count_a=na,count_b=nb,error=error,latency=latency,outputs=len(path),cells=len(scores)))
    assert set(int(k[6:]) for k in coverage if k.startswith('error_'))=={0,1,2,3,4,6,8,9,12}
    if m>=3:assert all(coverage[k]>0 for k in ['order_sensitive_gap','unequal_length','path_diagonal','path_up','path_left','tied_predecessors'])
    data=''.join(lines)
    return data,records,dict(coverage),frames,dict(frames=len(raw),beats=input_beats,outputs=len(records),
        cells=total_cells,multiply_steps=2*w*total_cells,ii1_checks=expected_ii,reset_probes=19 if m==1 else 20)


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        qualified_commands=21,dependency_sha256={},
        oracle='Heap-based minimax graph search with independent threshold-BFS lower/upper certificate; canonical predecessor and complete reverse path',
        not_run=['synthesis','PnR','STA','hardware','expanded_regression'],
        timeout_retry_policy='Every HDL child <=20s; timeout terminal, no retry/shrink/increase.')
    path=ROOT/'verification.json'
    if path.is_file():
        old=json.loads(path.read_text())
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Prior timeout terminal; no rerun.')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):report['prior_failed_attempts'].append({k:v for k,v in old.items() if k!='prior_failed_attempts'})
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    exe={k:str(suite/'bin'/f'{k}.exe') for k in ['iverilog','vvp']};temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,exit_code=None,status='TIMEOUT',stdout=decode(error.stdout),stderr=decode(error.stderr),timeout_seconds=20))
            report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(r.returncode>0 and 'polyline_frechet_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if args[0]=='iverilog' and not reject and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    lint=['iverilog','-g2012','-Wall']
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text())
        assert plan['profiles_COORD_W_MAX_POINTS_TAG_W']==[list(p) for p in PROFILES] and plan['qualified_children']==21
        plans=[]
        for w,m,t in PROFILES:
            data,records,coverage,frames,totals=fixtures(w,m,t)
            plans.append((w,m,t,data,records,coverage,frames,totals))
        report['frozen_fixture_plan']=[dict(COORD_W=w,MAX_POINTS=m,TAG_W=t,sha256=sha(d.encode()),**totals)
            for w,m,t,d,r,c,f,totals in plans]
        assert [p['sha256'] for p in report['frozen_fixture_plan']]==plan['fixture_sha256']
        report['fixture_plan_sha256']=sha(json.dumps(report['frozen_fixture_plan'],sort_keys=True).encode())
        assert plan['expected_main_totals']==dict(Counter({})+sum((Counter(totals) for *_,totals in plans),Counter()))
        report['reset_targets']=plan['reset_targets']
        for name in SOURCES:
            b=(ROOT/name).read_bytes();b.decode('utf-8',errors='strict')
            assert b'\r' not in b and b.endswith(b'\n') and not b.startswith(b'\xef\xbb\xbf'),name
        report['source_sha256']={name:sha((ROOT/name).read_bytes()) for name in SOURCES};save()
        if not all(Path(p).is_file() for p in exe.values()):raise RuntimeError('NOT_RUN missing native Icarus/vvp')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run([*lint,'-tnull','-s','polyline_frechet','-f','files.f'])
        run([*lint,'-tnull','-s','trajectory_match','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_frechet_') as temporary:
            folder=Path(temporary)
            for w,m,t,data,records,coverage,frames,totals in plans:
                (folder/'cases.txt').write_bytes(data.encode());image=folder/'unit.vvp'
                run([*lint,'-s','tb_polyline_frechet',f'-Ptb_polyline_frechet.COORD_W={w}',
                    f'-Ptb_polyline_frechet.MAX_POINTS={m}',f'-Ptb_polyline_frechet.TAG_W={t}',
                    f'-Ptb_polyline_frechet.FRAMES={len(frames)}','-o',str(image),'-f','files.f','sim/tb_polyline_frechet.sv'])
                output=run(['vvp',str(image),f'+CASES={(folder/"cases.txt").as_posix()}',f'+TRACE={(folder/"trace.txt").as_posix()}'])
                marker=re.search(r'^PASS (.+)$',output,re.M)
                if not marker:raise RuntimeError('Missing finite PASS marker')
                values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',marker.group(1))}
                for name in ['frames','beats','outputs','cells','multiply_steps','ii1_checks','reset_probes']:
                    assert values[name]==totals[name],(name,values,totals)
                assert values['read_checks']==values['predecessor_checks']==values['cells']
                assert values['trace_checks']==values['outputs']-sum(f['error']!=0 for f in frames)
                assert values['latency_checks']==len(frames) and values['fresh_checks']==values['reset_probes']
                assert values['state_mask']==2047 and values['held_cycles']>0 and values['source_stalls']==(9 if m==1 else 12)
                trace=(folder/'trace.txt').read_bytes()
                assert [(int(s.split()[0],16),int(s.split()[1])) for s in trace.decode('ascii').splitlines()]==records
                report['profiles'].append(dict(COORD_W=w,MAX_POINTS=m,TAG_W=t,coverage=coverage,planned=totals,
                    frame_plan=frames,observed_trace_sha256=sha(trace),observed=values,result=output));print(output,flush=True)
            for name,value in INVALID:run(['iverilog','-g2012','-tnull','-s','polyline_frechet',f'-Ppolyline_frechet.{name}={value}','-f','files.f'],reject=True)
        assert len(report['checks'])==21
        assert report['source_sha256']=={name:sha((ROOT/name).read_bytes()) for name in SOURCES}
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'];report['matrix_status']='PASS'
    except subprocess.TimeoutExpired as error:
        report['status']=['NOT_RUN','HW_UNVERIFIED'];report['detail']=str(error)+'; terminal timeout, stopped without retry';raise
    except (AssertionError,RuntimeError,OSError) as error:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(error);raise
    finally:
        if temporary:
            for check in report['checks']:check['command']=[v.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') for v in check['command']]
        report['source_sha256']={name:sha((ROOT/name).read_bytes()) for name in SOURCES if (ROOT/name).is_file()}
        report['license_sha256']={name:sha((ROOT.parents[2]/name).read_bytes()) for name in ['LICENSE','NOTICE']}
        report['tools']=exe;save()


if __name__=='__main__':main()
