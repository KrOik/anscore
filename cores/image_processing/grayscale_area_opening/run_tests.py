#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite image oracle, exact independent work/schedule counts, bounded Icarus."""
from pathlib import Path
import hashlib
import itertools
import json
import os
import random
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='c778301aa12d1b9bf4290b1a982f4c6325713fcd'
PROFILES=[(1,1,1,1),(1,7,3,3),(7,1,3,8),(2,2,2,8),(3,3,1,8),
          (8,5,4,8),(32,32,8,8),(64,64,8,32)]


def opening(image,width,height,area):
    """Descending activation DSU; unresolved members receive first viable level.

    No threshold raster scans, FIFO, visited RAM or component replay algorithm.
    """
    n=len(image);parent=list(range(n));size=[0]*n;pending=[set() for _ in image]
    active=[False]*n;result=[None]*n;work={}
    def find(p):
        while parent[p]!=p:parent[p]=parent[parent[p]];p=parent[p]
        return p
    def union(a,b):
        a=find(a);b=find(b)
        if a==b:return
        if size[a]<size[b]:a,b=b,a
        parent[b]=a;size[a]+=size[b];pending[a].update(pending[b]);pending[b].clear()
    buckets={value:[] for value in set(image)}
    for p,value in enumerate(image):buckets[value].append(p)
    for value in sorted(buckets,reverse=True):
        for p in buckets[value]:active[p]=True;size[p]=1;pending[p].add(p)
        for p in buckets[value]:
            x,y=p%width,p//width
            for q in ([p-1] if x else [])+([p+1] if x+1<width else [])+([p-width] if y else [])+([p+width] if y+1<height else []):
                if active[q]:union(p,q)
        roots={find(p) for p in range(n) if active[p]}
        for r in roots:
            if size[r]>=area:
                for p in pending[r]:assert result[p] is None;result[p]=value
                pending[r].clear()
        if value:
            count=sum(active)
            degree=sum((p%width>0)+(p%width+1<width)+(p//width>0)+(p//width+1<height)
                       for p in range(n) if active[p])
            qualified=sum(size[r] for r in roots if size[r]>=area)
            work[value]=(count,degree,qualified)
    assert all(x is not None and 0<=x<=y for x,y in zip(result,image))
    if area==1:assert result==image
    if area==n:assert result==[min(image)]*n
    return result,work


def vectors(width,height,bits,tag_w):
    n=width*height;hi=(1<<bits)-1;cw=max(1,n.bit_length());rng=random.Random(0x41524541+n*17+bits)
    cases=[]
    def add(image,area=1,sof_bad=None,eol_bad=None):cases.append((list(image),area,sof_bad,eol_bad))
    for a in sorted({1,max(1,n//2),n}):
        add([0]*n,a);add([hi]*n,a)
        add([hi if (p%width+p//width)%2==0 else 0 for p in range(n)],a)
        add([hi if p in (0,n-1) else min(1,hi) for p in range(n)],a)
    add([hi if p%width==0 or p//width==height-1 else 0 for p in range(n)],min(n,3))
    add([min(hi,1+p%3) for p in range(n)],n)
    if (width,height,bits)==(2,2,2):
        for image in itertools.product(range(4),repeat=4):
            for a in (1,2,4):add(image,a)
    if (width,height,bits)==(3,3,1):
        for mask in range(512):
            image=[(mask>>p)&1 for p in range(n)]
            for a in (1,5,9):add(image,a)
    for _ in range(10 if n<100 else 3):
        palette=sorted({0,1,hi,hi//2}) if n<100 else [0,1,hi]
        add([rng.choice(palette) for _ in range(n)],rng.randint(1,n))
    add([hi]*n,0)
    if n+1<1<<cw:add([hi]*n,n+1)
    add([hi]*n,1,0,None);add([hi]*n,1,None,n-1)
    add([hi]*n,0,0,n-1)
    if n>1:add([hi]*n,1,n-1,None);add([hi]*n,1,None,0)
    inputs=[];expected=[];latency=[];scans=pops=writes=0
    cov=dict(valid=0,errors=0,identity=0,full_area=0,changed=0,nonzero_result=0,area_invalid=0,sof_error=0,eol_error=0,occupied_nonzero_levels=0)
    for fi,(image,area,sbad,ebad) in enumerate(cases):
        tag=rng.getrandbits(tag_w);errors=(int(sbad is not None)|int(ebad is not None)<<1|int(not 1<=area<=n)<<2)
        cov['area_invalid']+=not 1<=area<=n;cov['sof_error']+=sbad is not None;cov['eol_error']+=ebad is not None
        if errors:out=[0]*n;delay=2;cov['errors']+=1
        else:
            out,work=opening(image,width,height,area);levels=len(work)
            # Threshold component counts determine the work without emulating an FSM.
            delay=max(image)+3+sum(4*n+7*v+d+2*q for v,d,q in work.values())
            scans+=n*levels;pops+=sum(v for v,d,q in work.values());writes+=sum(q for v,d,q in work.values())
            cov['valid']+=1;cov['identity']+=area==1;cov['full_area']+=area==n
            cov['changed']+=out!=image;cov['nonzero_result']+=any(out);cov['occupied_nonzero_levels']+=levels
            # Algebraic morphology properties independently constrain the fixture oracle.
            again,_=opening(out,width,height,area);assert again==out
        latency.append(f'{delay:x}\n')
        for p,(pixel,value) in enumerate(zip(image,out)):
            sof=int(p==0)^int(p==sbad);eol=int(p%width==width-1)^int(p==ebad)
            offered_area=area if p==0 else rng.getrandbits(cw)
            inputs.append(f'{pixel:x} {offered_area:x} {sof} {eol} {tag if p==0 else rng.getrandbits(tag_w):x}\n')
            flags=(p==0)|int(p%width==width-1)<<1|int(p==n-1)<<2
            packed=value|(flags<<bits)|(tag<<(bits+3))|(errors<<(bits+3+tag_w))
            expected.append(f'{packed:x}\n')
    return ''.join(inputs),''.join(expected),''.join(latency),len(cases),scans,pops,writes,cov


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],checks=[],profiles=[],
                oracle='Descending activation union-find, unresolved-member assignment; exact graph work counts',
                not_run=['synthesis','place_and_route','STA','board','expanded_regression'])
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    exe={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ('iverilog','vvp')}
    temporary=''
    def run(args,reject=False,version=False):
        try:
            r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as exc:
            def decoded(value):return value.decode(errors='replace') if isinstance(value,bytes) else value or ''
            report.setdefault('incomplete_checks',[]).append(dict(command=args,exit_code=None,status='TIMEOUT',
                stdout=decoded(exc.stdout),stderr=decoded(exc.stderr),timeout_seconds=20))
            raise
        okay=(r.returncode!=0 and 'grayscale_area_opening_invalid_parameters' in r.stderr) if reject else r.returncode==0 and (version or not r.stderr.strip())
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',
                                    stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        if not all(exe.values()):raise RuntimeError('Icarus/vvp unavailable')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','grayscale_area_opening','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','area_open32','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_grayscale_area_opening_') as temporary:
            path=Path(temporary)
            for w,h,b,t in PROFILES:
                ins,exp,lat,frames,scans,pops,writes,cov=vectors(w,h,b,t)
                for name,data in [('inputs.txt',ins),('expected.mem',exp),('latency.mem',lat)]:
                    (path/name).write_bytes(data.encode())
                args=['iverilog','-g2012','-Wall','-s','tb_grayscale_area_opening']
                params=dict(WIDTH=w,HEIGHT=h,PIXEL_W=b,TAG_W=t,FRAMES=frames,SCANS=scans,POPS=pops,WRITES=writes)
                args += [f'-Ptb_grayscale_area_opening.{key}={value}' for key,value in params.items()]
                run(args+['-o',str(path/'unit.vvp'),'-f','files.f','sim/tb_grayscale_area_opening.sv'])
                output=run(['vvp',str(path/'unit.vvp'),f'+INPUTS={(path/"inputs.txt").as_posix()}',
                            f'+EXPECTED={(path/"expected.mem").as_posix()}',f'+LATENCY={(path/"latency.mem").as_posix()}'])
                if f'PASS frames={frames} pixels={frames*w*h} outputs={frames*w*h}' not in output:
                    raise RuntimeError('finite TB did not complete')
                report['profiles'].append(dict(**params,pixels=frames*w*h,coverage=cov,result=output,
                    inputs_sha256=hashlib.sha256(ins.encode()).hexdigest(),expected_sha256=hashlib.sha256(exp.encode()).hexdigest(),
                    latency_sha256=hashlib.sha256(lat.encode()).hexdigest()))
                print(output,flush=True)
            for name,value in [('WIDTH',0),('WIDTH',65),('HEIGHT',0),('HEIGHT',65),
                               ('PIXEL_W',0),('PIXEL_W',9),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','grayscale_area_opening',f'-Pgrayscale_area_opening.{name}={value}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=str(exc);raise
    finally:
        for check in report['checks']+report.get('incomplete_checks',[]):
            check['command']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else a for a in check['command']]
        if temporary and 'detail' in report:
            report['detail']=report['detail'].replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>')
        names=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f','example/area_open32.sv',
               'rtl/grayscale_area_opening.sv','sim/tb_grayscale_area_opening.sv','run_tests.py']
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names if (ROOT/name).is_file()}
        report['license_sha256']={name:hashlib.sha256((ROOT.parents[2]/name).read_bytes()).hexdigest() for name in ('LICENSE','NOTICE')}
        report['tools']=exe
        (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
