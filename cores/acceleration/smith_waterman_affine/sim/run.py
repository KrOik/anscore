#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite full-matrix/all-gap-length oracle checks of local alignment RTL."""
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


def oracle(a,b,match,mismatch,opening,extension):
    # Explicitly enumerate all possible gap lengths, without rolling E/F states.
    h=[[0]*(len(b)+1) for _ in range(len(a)+1)];best=(0,0,0)
    for i in range(1,len(a)+1):
        for j in range(1,len(b)+1):
            horizontal=max(h[i][j-k]-opening-(k-1)*extension for k in range(1,j+1))
            vertical=max(h[i-k][j]-opening-(k-1)*extension for k in range(1,i+1))
            value=max(0,h[i-1][j-1]+(match if a[i-1]==b[j-1] else -mismatch),horizontal,vertical)
            h[i][j]=value
            if value>best[0]:best=(value,i,j)
    return best


def fixtures(cw,limit):
    mask=(1<<cw)-1;rng=random.Random(0x535741+cw*101+limit)
    cases=[([],[]),([0],[]),([],[1]),([0],[1]),([0],[0]),
           ([mask]*limit,[mask]*limit),([0]*limit,[1]*limit),
           ([i&mask for i in range(limit)],[i&mask for i in range(limit)]),
           ([0,1,0,1][:limit],[1,0,1,0][:limit]),
           ([0]*(limit+1),[0]),([0],[0]*(limit+1)),([0]*(limit+2),[0]*(limit+2))]
    q=min(4,limit//3);gap=min(q+1,limit-2*q)
    if q>=2:cases.append(([1]*q+[0]*gap+[1]*q,[1]*(2*q)))
    if limit==3 and cw==1:
        sequences=[list(s) for n in range(4) for s in itertools.product(range(2),repeat=n)]
        cases.extend((a,b) for a in sequences for b in sequences)
    for _ in range(30):
        na=rng.randrange(min(limit,12)+1);nb=rng.randrange(min(limit,12)+1)
        cases.append(([rng.randrange(min(1<<cw,4)) for _ in range(na)],
                      [rng.randrange(min(1<<cw,4)) for _ in range(nb)]))
    return cases


def vectors(cw,limit,match,mismatch,opening,extension,tw):
    lines=[];cases=fixtures(cw,limit);errors=0;cells=0
    for index,(a,b) in enumerate(cases):
        error=int(len(a)>limit)+2*int(len(b)>limit);errors+=bool(error)
        result=(0,0,0) if error else oracle(a,b,match,mismatch,opening,extension)
        if not error:cells+=len(a)*len(b)
        # Masked first and interior tokens test metadata ownership and capacity.
        ar=[(v,1) for v in a];br=[(v,1) for v in b]
        if index%3==0:ar.insert(0,(0,0))
        if index%4==0:br.insert(len(br)//2,(0,0))
        ar=ar or [(0,0)];br=br or [(0,0)]
        tag=(index*0x9e3779b1+7)&((1<<tw)-1)
        lines.append(f'{len(ar)} {len(br)} {result[0]} {result[1]} {result[2]} {min(len(a),limit)} {min(len(b),limit)} {error} {tag:x}\n')
        lines.extend(f'{v:x} {keep} {int(i==len(ar)-1)} {tag if i==0 else tag^((1<<tw)-1):x}\n' for i,(v,keep) in enumerate(ar))
        lines.extend(f'{v:x} {keep} {int(i==len(br)-1)}\n' for i,(v,keep) in enumerate(br))
    return ''.join(lines),len(cases),errors,cells


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vv=os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    report={'date':'2026-11-04','status':['NOT_RUN','HW_UNVERIFIED'],'commands':[],'cases':[],
            'not_run':['synthesis','place_and_route','STA','hardware']};temporary=''
    def run(args,reject=False):
        p=subprocess.run(args,cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        report['commands'].append({'argv':[str(a) for a in args],'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
        if reject:
            if p.returncode==0 or 'smith_waterman_affine_invalid_parameters__see_README' not in p.stderr:raise RuntimeError('invalid parameters not explicitly rejected')
        elif p.returncode:raise RuntimeError(p.stdout+p.stderr)
        return p.stdout
    try:
        if not iv or not vv:raise RuntimeError('NOT_RUN: Icarus/vvp required')
        report['tool']=run([iv,'-V']).splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','smith_waterman_affine','-f','files.f'])
        run([iv,'-g2012','-Wall','-tnull','-s','local_align32','-f','files.f','examples/local_align32.sv'])
        with tempfile.TemporaryDirectory(prefix='anscore_sw_affine_') as temporary:
            work=Path(temporary)
            for cw,n,mt,mm,go,ge,tw in [(1,1,1,255,255,255,1),(1,3,2,1,2,1,3),(2,5,3,0,1,1,8),
                                      (8,16,2,3,3,1,8),(8,32,2,1,3,1,8),(4,9,7,9,5,2,8),
                                      (8,64,1,0,255,255,16),(16,256,255,255,255,1,32)]:
                content,count,errors,cells=vectors(cw,n,mt,mm,go,ge,tw)
                vector_path,image=work/'vectors.txt',work/'sim.vvp';vector_path.write_bytes(content.encode())
                params=dict(CHAR_W=cw,MAX_LEN=n,MATCH_SCORE=mt,MISMATCH_PENALTY=mm,GAP_OPEN=go,GAP_EXTEND=ge,TAG_W=tw)
                args=[iv,'-g2012','-Wall','-s','tb_smith_waterman_affine','-o',str(image)]
                args += [f'-Ptb_smith_waterman_affine.{p}={v}' for p,v in params.items()]
                run(args+['-f','files.f','sim/tb_smith_waterman_affine.sv'])
                output=run([vv,str(image),f'+VECTORS={vector_path.as_posix()}'])
                marker=f'PASS pairs={count} reset_probes=8'
                if marker not in output:raise RuntimeError('missing completion marker')
                report['cases'].append({**params,'pairs':count,'error_pairs':errors,'oracle_cells':cells,'status':'PASS',
                                        'vectors_sha256':hashlib.sha256(content.encode()).hexdigest(),'output':output.strip()})
                print(params,marker,flush=True)
        for p,v in [('CHAR_W',0),('CHAR_W',17),('MAX_LEN',0),('MAX_LEN',257),('MATCH_SCORE',0),('MATCH_SCORE',256),
                    ('MISMATCH_PENALTY',-1),('MISMATCH_PENALTY',256),('GAP_OPEN',0),('GAP_OPEN',256),
                    ('GAP_EXTEND',0),('GAP_EXTEND',4),('TAG_W',0),('TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','smith_waterman_affine',f'-Psmith_waterman_affine.{p}={v}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED']
    except (OSError,RuntimeError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=str(exc);raise
    finally:
        for c in report['commands']:
            if temporary:c['argv']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') for a in c['argv']]
        paths=['.gitattributes','files.f','rtl/smith_waterman_affine.sv','examples/local_align32.sv','sim/run.py','sim/tb_smith_waterman_affine.sv']
        report['source_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}
        (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
