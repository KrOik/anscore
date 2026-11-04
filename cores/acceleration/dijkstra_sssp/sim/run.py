#!/usr/bin/env python3
"""Bounded deterministic Dijkstra checks with independent Bellman-Ford oracle."""
from __future__ import annotations
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
BASELINE='f19addd5fec59ec6affee05af7195ca1758d40dc'


def fixtures(n,w):
    maximum=(1<<w)-1;frames=[]
    def add(edges=(),source=0,parents=None,masked=False,replay=False):
        frames.append({'edges':[tuple(e) if len(e)==4 else (*e,1) for e in edges],
                       'source':source,'parents':parents or {},'masked':masked,'replay':replay})
    add();add(source=n-1);add([(0xffffffff,0xffffffff,maximum,0)],masked=True)
    forward=[(i,i+1,maximum) for i in range(n-1)]
    backward=[(i+1,i,maximum) for i in range(n-1)]
    add(forward,parents={i:i-1 for i in range(1,n)})
    add(backward,n-1,parents={i:i+1 for i in range(n-1)})
    add([(u,v,0) for u in range(n) for v in range(n)],n//2,
        parents={i:n//2 for i in range(n) if i!=n//2})
    add([(u,v,maximum) for u in range(n) for v in range(n)],n//2,
        parents={i:n//2 for i in range(n) if i!=n//2})
    add([(u,v,(u+v)%2) for u in range(n//2) for v in range(n//2)],source=n-1)
    parallel=[(0,min(1,n-1),maximum),(0,min(1,n-1),0),(0,min(1,n-1),maximum)]
    add(parallel);add(list(reversed(parallel)),masked=True,replay=True)
    add([(n,0,0),(0,n,maximum),(0xffffffff,0,0)]+forward,masked=True)
    add(forward+[(0xffffffff,0xffffffff,maximum,0)])
    add(forward,source=n);add(forward,source=0xffffffff)
    add([(n,n,0)]+forward,source=0xffffffff,masked=True)
    if n>=3:
        add([(0,1,maximum),(0,2,0),(2,1,0)],parents={1:2,2:0})
        add([(0,1,0),(1,2,0),(2,0,0),(2,1,maximum)],source=2,parents={0:2,1:0})
    if n>=4:
        add([(0,1,1),(0,2,1),(1,3,1),(2,3,1)],parents={1:0,2:0,3:1})
    if n==3 and w==1:
        arcs=[(u,v) for u in range(n) for v in range(n) if u!=v]
        for number,values in enumerate(itertools.product((None,0,1),repeat=len(arcs))):
            add([(u,v,value) for (u,v),value in zip(arcs,values) if value is not None],source=number%n)
    rng=random.Random(20261107+n*41+w*19)
    for number in range(24):
        edges=[]
        for u in range(n):
            for v in range(n):
                if rng.random()<(number%4+1)/8:
                    edges.append((u,v,rng.choice((0,1,maximum,rng.randrange(maximum+1)))))
        rng.shuffle(edges);source=rng.randrange(n)
        add(edges,source,masked=number%3==0)
        if number%6==0:
            duplicate=edges+edges[:min(5,len(edges))];rng.shuffle(duplicate)
            add(duplicate,source,masked=number%2==0,replay=True)
    return frames


def oracle(frame,n):
    graph={};error=int(frame['source']>=n)<<1
    for u,v,w,keep in frame['edges']:
        if not keep:continue
        if u>=n or v>=n:error|=1;continue
        graph[u,v]=min(graph.get((u,v),w),w)
    distance=[None]*n;work=0
    if frame['source']<n:
        distance[frame['source']]=0
        # Synchronous Bellman-Ford passes; no priority or visited/settlement set.
        for _ in range(n-1):
            following=distance.copy()
            for (u,v),weight in graph.items():
                work+=1
                if distance[u] is not None:
                    candidate=distance[u]+weight
                    if following[v] is None or candidate<following[v]:following[v]=candidate
            if following==distance:break
            distance=following
    cross=False
    if n<=5:
        # Separate all-pairs min-plus oracle also checks every small fixture.
        all_pairs=[[0 if u==v else None for v in range(n)] for u in range(n)]
        for (u,v),weight in graph.items():
            if all_pairs[u][v] is None or weight<all_pairs[u][v]:all_pairs[u][v]=weight
        for k in range(n):
            for u in range(n):
                for v in range(n):
                    if all_pairs[u][k] is not None and all_pairs[k][v] is not None:
                        candidate=all_pairs[u][k]+all_pairs[k][v]
                        if all_pairs[u][v] is None or candidate<all_pairs[u][v]:all_pairs[u][v]=candidate
        assert distance==(all_pairs[frame['source']] if frame['source']<n else [None]*n)
        cross=True
    return graph,distance,error,work,cross


def vectors(n,w,tagw):
    frames=fixtures(n,w);lines=[str(len(frames))];metrics={'graphs':len(frames),'tokens':len(frames)*n,
        'input_beats':0,'error_graphs':0,'bad_source_graphs':0,'replay_graphs':0,
        'bellman_ford_edge_checks':0,'all_pairs_crosschecks':0,'maximum_distance':0}
    for number,frame in enumerate(frames):
        graph,distance,error,work,cross=oracle(frame,n)
        metrics['error_graphs']+=bool(error);metrics['bad_source_graphs']+=bool(error&2)
        metrics['replay_graphs']+=frame['replay'];metrics['bellman_ford_edge_checks']+=work
        metrics['all_pairs_crosschecks']+=cross
        metrics['maximum_distance']=max(metrics['maximum_distance'],max((d for d in distance if d is not None),default=0))
        tag=((1<<tagw)-1 if number%3==0 else number*17)&((1<<tagw)-1)
        raw=list(frame['edges'])
        if frame['masked']:raw.insert(0,(0xffffffff,0xffffffff,(1<<w)-1,0))
        if not raw:raw=[(0,0,0,0)]
        metrics['input_beats']+=len(raw)
        lines.append(f"{len(raw)} {frame['source']:x} {tag:x} {error} {int(frame['replay'])}")
        for index,(u,v,weight,keep) in enumerate(raw):
            beat_source=frame['source'] if index==0 else frame['source']^0xffffffff
            beat_tag=tag if index==0 else tag^((1<<tagw)-1)
            lines.append(f'{u:x} {v:x} {weight:x} {keep} {int(index==len(raw)-1)} {beat_source:x} {beat_tag:x}')
        for u in range(n):
            for v in range(n):lines.append(f'{int((u,v) in graph)} {graph.get((u,v),0):x}')
        for v,d in enumerate(distance):
            parent=0 if d is None or v==frame['source'] else frame['parents'].get(v,0xffffffff)
            lines.append(f'{int(d is not None)} {d or 0:x} {parent:x}')
    return '\n'.join(lines)+'\n',metrics


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vv=os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    if not iv or not vv:raise RuntimeError('NOT_RUN: Icarus unavailable')
    commands=[];cases=[]
    def run(argv,cwd,negative=False,version=False):
        r=subprocess.run([str(a) for a in argv],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        rec={'argv':[str(a) for a in argv],'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'timeout_seconds':20}
        commands.append(rec)
        if negative:assert r.returncode>0 and 'dijkstra_sssp_invalid_parameters__see_README' in r.stdout+r.stderr,rec
        else:assert r.returncode==0 and (version or not r.stderr),rec
        return r.stdout
    version=run([iv,'-V'],ROOT,version=True).splitlines()[0]
    with tempfile.TemporaryDirectory(prefix='anscore_dijkstra_') as tmp:
        temp=Path(tmp);rtl=ROOT/'rtl/dijkstra_sssp.sv';tb=ROOT/'sim/tb_dijkstra_sssp.sv'
        run([iv,'-g2012','-Wall','-tnull','-s','dijkstra_sssp','-s','routes16','-f','files.f','examples/routes16.sv'],ROOT)
        for n,w,tagw in [(1,1,1),(2,3,1),(3,1,3),(5,4,8),(16,16,8),(31,12,16),(64,24,32)]:
            folder=temp/f'n{n}_w{w}_t{tagw}';folder.mkdir()
            text,metrics=vectors(n,w,tagw)
            (folder/'vectors.txt').write_text(text,encoding='ascii',newline='\n')
            run([iv,'-g2012','-Wall','-s','tb',f'-Ptb.NUM_NODES={n}',f'-Ptb.WEIGHT_W={w}',f'-Ptb.TAG_W={tagw}',
                 '-o','sim.vvp',rtl,tb],folder)
            output=run([vv,'sim.vvp'],folder)
            assert f"graphs={metrics['graphs']} tokens={metrics['tokens']} reset_probes=11" in output,output
            cases.append({'NUM_NODES':n,'WEIGHT_W':w,'TAG_W':tagw,**metrics,'status':'PASS',
                          'vectors_sha256':hashlib.sha256(text.encode('ascii')).hexdigest(),'output':output.strip()})
        for key,value in [('NUM_NODES',0),('NUM_NODES',65),('WEIGHT_W',0),('WEIGHT_W',25),('TAG_W',0),('TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','dijkstra_sssp',f'-Pdijkstra_sssp.{key}={value}','-f','files.f'],ROOT,negative=True)
    names=['.gitattributes','files.f','rtl/dijkstra_sssp.sv','examples/routes16.sv','sim/run.py','sim/tb_dijkstra_sssp.sv']
    for name in names:assert b'\r' not in (ROOT/name).read_bytes(),name
    report={'baseline_commit':BASELINE,'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],'tool':version,
        'commands':commands,'cases':cases,'invalid_parameter_rejections':6,
        'graphs':sum(c['graphs'] for c in cases),'tokens':sum(c['tokens'] for c in cases),
        'all_pairs_crosschecks':sum(c['all_pairs_crosschecks'] for c in cases),
        'oracle':'synchronous Bellman-Ford; independent all-pairs min-plus for N<=5; RTL predecessor-tree certificates and hand-derived ties',
        'source_sha256':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names},
        'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f"PASS dijkstra profiles={len(cases)} graphs={report['graphs']} tokens={report['tokens']} commands={len(commands)}")


if __name__=='__main__':main()
