#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded deterministic Prim-oracle comparison of the composed RTL."""
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]


def vectors(n,cap,ww,etw,gtw):
    rng=random.Random(0x4d5346+n+cap)
    maxid=(1<<max(1,(n-1).bit_length()))-1
    low,high=-(1<<(ww-1)),(1<<(ww-1))-1
    etmask,gtmask=(1<<etw)-1,(1<<gtw)-1
    graphs=[[],[(0,0,low,1,1)],[(0,n-1,low,2,1)],
            [(i,i+1,low if i%2 else high,i&etmask,1) for i in range(n-1)],
            [(i,i+1,low,i&etmask,1) for i in range(n-1)],
            [(i,i+1,high,i&etmask,1) for i in range(n-1)],
            [(i,j,0,(i+j)&etmask,1) for i in range(n) for j in range(i+1,n)],
            [(n-1,0,high,i&etmask,1) for i in range(cap+4)],
            [(maxid,0,-1,0,1),(0,maxid,1,1,0),(0,0,0,0,0)]]
    for _ in range(75):
        graphs.append([(rng.randrange(maxid+1),rng.randrange(maxid+1),
                        rng.choice([low,high,0,-1,1,rng.randrange(low,high+1)]),
                        rng.getrandbits(etw),int(rng.random()>.15))
                       for _ in range(rng.randrange(2*cap+5))])
    lines=[];tokens=0
    for gi,graph in enumerate(graphs):
        kept=[];bad=over=0
        for u,v,w,t,keep in graph:
            if keep and (u>=n or v>=n): bad=1
            if keep and u<n and v<n and u!=v:
                if len(kept)<cap: kept.append((w,min(u,v),max(u,v),t))
                else: over=1
        # Independent Prim cut expansion: no priority heap or disjoint sets.
        visited=set();forest=[];components=0
        for start in range(n):
            if start in visited: continue
            components+=1;visited.add(start)
            while True:
                crossing=[e for e in kept if (e[1] in visited) != (e[2] in visited)]
                if not crossing: break
                edge=min(crossing);forest.append(edge);visited.update(edge[1:3])
        forest.sort()
        gt=(gi*17+5)&gtmask
        beats=graph or [(0,0,0,0,0)]
        lines.append(f"{len(beats)} {len(forest)} {sum(e[0] for e in forest)} {len(forest)} {components} {bad} {over} {gt:x}\n")
        for i,(u,v,w,t,keep) in enumerate(beats):
            lines.append(f"{u} {v} {w} {t:x} {keep} {int(i==len(beats)-1)} {gt if i==0 else (gt^gtmask):x}\n")
        lines.extend(f"{u} {v} {w} {t:x}\n" for w,u,v,t in forest)
        tokens+=len(forest)+1
    return ''.join(lines),len(graphs),tokens


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy();env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vvp=os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    report={'date':'2026-11-04','status':['NOT_RUN','HW_UNVERIFIED'],'commands':[],'cases':[],
            'not_run':['synthesis','place_and_route','STA','hardware']}
    temporary=''
    def run(args,reject=False):
        result=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=20)
        report['commands'].append({'argv':[str(a) for a in args],'returncode':result.returncode,
                                   'stdout':result.stdout,'stderr':result.stderr,'expected_failure':reject})
        if reject:
            if result.returncode==0 or 'kruskal_msf_invalid_parameters__see_README' not in result.stderr:
                raise RuntimeError('invalid parameters not explicitly rejected')
        elif result.returncode: raise RuntimeError(result.stdout+result.stderr)
        return result.stdout
    try:
        if not iv or not vvp: raise RuntimeError('NOT_RUN: Icarus and vvp required')
        report['tool']=run([iv,'-V']).splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','kruskal_msf','-f','files.f'])
        run([iv,'-g2012','-Wall','-tnull','-s','graph16_forest','-f','files.f','examples/graph16_forest.sv'])
        with tempfile.TemporaryDirectory(prefix='anscore_msf_') as temporary:
            work=Path(temporary)
            for n,cap,ww,etw,gtw in [(1,1,2,1,1),(3,1,8,4,4),(5,9,8,8,8),(16,32,16,8,8),(32,64,24,32,32)]:
                content,count,tokens=vectors(n,cap,ww,etw,gtw)
                vector_path,image=work/'vectors.txt',work/'sim.vvp'
                vector_path.write_bytes(content.encode())
                args=[iv,'-g2012','-Wall','-s','tb_kruskal_msf','-o',str(image)]
                for p,v in [('NUM_NODES',n),('MAX_EDGES',cap),('WEIGHT_W',ww),('EDGE_TAG_W',etw),('GRAPH_TAG_W',gtw)]:
                    args.append(f'-Ptb_kruskal_msf.{p}={v}')
                run(args+['-f','files.f','sim/tb_kruskal_msf.sv'])
                output=run([vvp,str(image),f'+VECTORS={vector_path.as_posix()}'])
                marker=f'PASS graphs={count} tokens={tokens} reset_cases={7 if n>1 else 2}'
                if marker not in output: raise RuntimeError('missing completion: '+output)
                report['cases'].append({'NUM_NODES':n,'MAX_EDGES':cap,'WEIGHT_W':ww,'EDGE_TAG_W':etw,'GRAPH_TAG_W':gtw,
                                        'graphs':count,'tokens':tokens,'status':'PASS','output':output.strip(),
                                        'vectors_sha256':hashlib.sha256(content.encode()).hexdigest()})
                print(n,cap,ww,marker,flush=True)
        run([iv,'-g2012','-Wall','-tnull','-s','kruskal_msf','-Pkruskal_msf.NUM_NODES=256',
             '-Pkruskal_msf.MAX_EDGES=1024','-Pkruskal_msf.WEIGHT_W=24','-Pkruskal_msf.EDGE_TAG_W=32',
             '-Pkruskal_msf.GRAPH_TAG_W=32','-f','files.f'])
        for p,v in [('NUM_NODES',0),('NUM_NODES',257),('MAX_EDGES',0),('MAX_EDGES',1025),
                    ('WEIGHT_W',1),('WEIGHT_W',25),('EDGE_TAG_W',0),('EDGE_TAG_W',33),('GRAPH_TAG_W',0),('GRAPH_TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','kruskal_msf',f'-Pkruskal_msf.{p}={v}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (OSError,RuntimeError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=str(exc)
        raise
    finally:
        for c in report['commands']:
            if temporary: c['argv']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') for a in c['argv']]
        paths=['.gitattributes','files.f','rtl/kruskal_msf.sv','examples/graph16_forest.sv',
               'sim/run.py','sim/tb_kruskal_msf.sv','../binary_heap_queue/rtl/binary_heap_queue.sv',
               '../disjoint_set_union/rtl/disjoint_set_union.sv']
        report['source_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}
        (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__': main()
