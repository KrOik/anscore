#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite maximum-flow / subset-DP cardinality oracles; no hardware tools."""
from collections import deque
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


def maximum_flow(rows,nr):
    # Generic unit-capacity residual network, with one source and one sink.
    nl=len(rows);size=nl+nr+2;sink=size-1
    residual=[[0]*size for _ in range(size)]
    for l,row in enumerate(rows):
        residual[0][l+1]=1
        for r in range(nr):
            if row>>r&1: residual[l+1][nl+1+r]=1
    for r in range(nr): residual[nl+1+r][sink]=1
    flow=0
    while True:
        predecessor=[-1]*size;predecessor[0]=0;queue=deque([0])
        while queue and predecessor[sink]<0:
            v=queue.popleft()
            for u,capacity in enumerate(residual[v]):
                if capacity and predecessor[u]<0: predecessor[u]=v;queue.append(u)
        if predecessor[sink]<0: return flow
        v=sink
        while v:
            u=predecessor[v];residual[u][v]-=1;residual[v][u]+=1;v=u
        flow+=1


def subset_cardinality(rows,nr):
    possible={0}
    for row in rows:
        possible|={mask|(1<<r) for mask in possible for r in range(nr) if row>>r&1 and not mask>>r&1}
    return max(mask.bit_count() for mask in possible)


def vectors(nl,nr,tw):
    rng=random.Random(0x424950+nl*97+nr)
    maxl=(1<<max(1,(nl-1).bit_length()))-1;maxr=(1<<max(1,(nr-1).bit_length()))-1
    tagmask=(1<<tw)-1;small=min(nl,nr)
    bases=[([],[-1]*nl),([(0,0,1)],[0]+[-1]*(nl-1)),
           ([(l,r,1) for l in range(nl) for r in range(nr)],list(range(small))+[-1]*(nl-small)),
           ([(l,0,1) for l in range(nl)],[0]+[-1]*(nl-1)),
           ([(maxl,maxr,1),(0,0,0)],None)]
    if small>=2:
        chain=[(l,l,1) for l in range(small-1)]+[(l,l+1,1) for l in range(small-1)]+[(small-1,0,1)]
        bases.append((chain,list(range(1,small))+[0]+[-1]*(nl-small)))
    exhaustive=0
    if (nl,nr) in [(2,3),(3,3)]:
        for mask in range(1<<(nl*nr)):
            bases.append(([(l,r,1) for l in range(nl) for r in range(nr) if mask>>(l*nr+r)&1],None))
            exhaustive+=1
    for _ in range(36):
        density=rng.choice([.05,.2,.5,.8])
        edges=[(l,r,1) for l in range(nl) for r in range(nr) if rng.random()<density]
        edges+=[(rng.randrange(maxl+1),rng.randrange(maxr+1),int(rng.random()>.3)) for _ in range(6)]
        rng.shuffle(edges);bases.append((edges,None))
    lines=[];graphs=0;dp_checks=0
    for edges,known in bases:
        rows=[0]*nl;bad=0
        for l,r,keep in edges:
            if keep:
                if l>=nl or r>=nr: bad=1
                else: rows[l]|=1<<r
        card=maximum_flow(rows,nr)
        if nr<=8:
            assert subset_cardinality(rows,nr)==card
            dp_checks+=1
        for repeated in [0,1]:
            beats=(list(reversed(edges))+edges[:2]) if repeated else list(edges)
            if not beats: beats=[(0,0,0)]
            tag=(graphs*0x9e3779b1+5)&tagmask
            lines.append(f'{len(beats)} {card} {bad} {tag:x} {repeated}\n')
            lines.extend(f'{l} {r} {keep} {int(i==len(beats)-1)} {tag if i==0 else tag^tagmask:x}\n' for i,(l,r,keep) in enumerate(beats))
            lines.extend(f'{row:x} {known[l] if known is not None else -2}\n' for l,row in enumerate(rows))
            graphs+=1
    return ''.join(lines),graphs,exhaustive,dp_checks


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vvp=os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    report={'date':'2026-11-04','status':['NOT_RUN','HW_UNVERIFIED'],'commands':[],'cases':[],
            'not_run':['synthesis','place_and_route','STA','hardware']};temporary=''
    def run(args,reject=False):
        p=subprocess.run(args,cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        report['commands'].append({'argv':[str(a) for a in args],'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
        if reject:
            if p.returncode==0 or 'bipartite_match_invalid_parameters__see_README' not in p.stderr:
                raise RuntimeError('missing explicit illegal parameter rejection')
        elif p.returncode: raise RuntimeError(p.stdout+p.stderr)
        return p.stdout
    try:
        if not iv or not vvp: raise RuntimeError('NOT_RUN: Icarus/vvp required')
        report['tool']=run([iv,'-V']).splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','bipartite_match','-f','files.f'])
        run([iv,'-g2012','-Wall','-tnull','-s','resource_match8','-f','files.f','examples/resource_match8.sv'])
        with tempfile.TemporaryDirectory(prefix='anscore_bipartite_') as temporary:
            work=Path(temporary)
            for nl,nr,tw in [(1,1,1),(1,32,32),(32,1,1),(2,3,4),(3,3,8),(5,4,8),(8,8,8),(16,7,16),(32,32,32)]:
                content,graphs,exhaustive,dp_checks=vectors(nl,nr,tw)
                vector_path,image=work/'vectors.txt',work/'sim.vvp';vector_path.write_bytes(content.encode())
                run([iv,'-g2012','-Wall','-s','tb_bipartite_match','-o',str(image),f'-Ptb_bipartite_match.LEFT_N={nl}',
                     f'-Ptb_bipartite_match.RIGHT_N={nr}',f'-Ptb_bipartite_match.TAG_W={tw}','-f','files.f','sim/tb_bipartite_match.sv'])
                out=run([vvp,str(image),f'+VECTORS={vector_path.as_posix()}'])
                marker=f'PASS graphs={graphs} tokens={graphs*nl} reset_probes=9'
                if marker not in out: raise RuntimeError('missing completion marker')
                report['cases'].append({'LEFT_N':nl,'RIGHT_N':nr,'TAG_W':tw,'graphs':graphs,'tokens':graphs*nl,
                                        'exhaustive_graphs':exhaustive,'subset_dp_crosschecks':dp_checks,'status':'PASS',
                                        'vectors_sha256':hashlib.sha256(content.encode()).hexdigest(),'output':out.strip()})
                print(nl,nr,tw,marker,flush=True)
        for p,v in [('LEFT_N',0),('LEFT_N',33),('RIGHT_N',0),('RIGHT_N',33),('TAG_W',0),('TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','bipartite_match',f'-Pbipartite_match.{p}={v}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED']
    except (OSError,RuntimeError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=str(exc);raise
    finally:
        for c in report['commands']:
            if temporary:c['argv']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') for a in c['argv']]
        paths=['.gitattributes','files.f','rtl/bipartite_match.sv','examples/resource_match8.sv','sim/run.py','sim/tb_bipartite_match.sv']
        report['source_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}
        (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
