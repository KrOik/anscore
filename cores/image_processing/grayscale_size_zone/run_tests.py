#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixed finite whole-image union oracle and individually bounded local tools."""
from collections import Counter
from itertools import product
from pathlib import Path
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='fcd2beef77f998da54801b91d74ce47946bee17c'
# Immutable test scope selected before the first compiler/simulator invocation.
PROFILES=[(1,1,1,1,4,1),(1,7,4,2,8,3),(7,1,8,3,4,8),(2,2,2,2,8,8),
          (3,3,1,1,4,8),(8,5,8,2,4,8),(16,12,12,3,8,8),(32,1,16,3,8,32),(1,32,16,3,4,32)]
SOURCES=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f',
         'example/zone_texture16.sv','rtl/grayscale_size_zone.sv','sim/tb_grayscale_size_zone.sv','run_tests.py']
SCOPE=dict(profiles=9,main_frames=948,largest_pixel_area_simulated=192,maximum_single_axis_extent_simulated=32,
           maximum_32x32_compile='PASS only after recorded successful tool completion',
           maximum_32x32_numerical='NOT_RUN; excluded by predetermined budget',
           matrix_fixed_before_tools=True,fixture_reduction_after_timeout=False)


def zones(pixels,w,h,p,g,connectivity):
    """Union all equal-gray undirected edges, then frequency-count root sizes.

    This has no FIFO, visited bitmap, seed traversal or hardware state schedule.
    """
    image=[v>>(p-g) for v in pixels];n=w*h;parent=list(range(n));mass=[1]*n
    def find(v):
        while parent[v]!=v:parent[v]=parent[parent[v]];v=parent[v]
        return v
    offsets=[(1,0),(0,1)]+([(1,1),(-1,1)] if connectivity==8 else [])
    degree=0
    for y in range(h):
        for x in range(w):
            a=y*w+x
            for dx,dy in offsets:
                xx,yy=x+dx,y+dy
                if 0<=xx<w and 0<=yy<h:
                    degree+=2;b=yy*w+xx
                    if image[a]==image[b]:
                        aa,bb=find(a),find(b)
                        if aa!=bb:
                            if mass[aa]<mass[bb]:aa,bb=bb,aa
                            parent[bb]=aa;mass[aa]+=mass[bb]
    counts=Counter((image[i],mass[i]) for i in range(n) if find(i)==i)
    assert sum(size*count for (gray,size),count in counts.items())==n
    assert 1<=sum(counts.values())<=n
    assert {gray:sum(size*count for (gg,size),count in counts.items() if gg==gray) for gray in set(image)}==dict(Counter(image))
    formula=2*h*(w-1)+2*w*(h-1)+(4*(w-1)*(h-1) if connectivity==8 else 0)
    assert degree==formula
    return counts,degree


def packed_matrix(counts,n,g,t,tag,errors):
    cw=max(1,n.bit_length());total=0 if errors else sum(counts.values());out=[]
    for gray in range(1<<g):
        for size in range(1,n+1):
            fields=[(errors,2),(tag,t),(int(gray==(1<<g)-1 and size==n),1),
                    (int(gray==0 and size==1),1),(gray,g),(size,cw),(total,cw),
                    (0 if errors else counts[gray,size],cw)]
            word=0
            for value,bits in fields:assert 0<=value<1<<bits;word=(word<<bits)|value
            out.append(f'{word:x}\n')
    return ''.join(out)


def vectors(w,h,p,g,c,t):
    n=w*h;hi=(1<<p)-1;levels=1<<g;shift=p-g
    rng=random.Random(0x5a4f4e45+w*17+h*31+p*7+g+c);frames=[]
    def add(image,sbad=None,ebad=None):frames.append((list(image),sbad,ebad))
    def pattern(fn):return [(fn(x,y)%levels)<<shift for y in range(h) for x in range(w)]
    add([0]*n);add([hi]*n)
    for fn in [lambda x,y:(x+y)%2,lambda x,y:x,lambda x,y:y,
               lambda x,y:int(x==y)*(levels-1),lambda x,y:int(x==0 or y==0)*(levels-1),
               lambda x,y:int(x==w-1 and y==h-1)*(levels-1),lambda x,y:x//2+y//2]:add(pattern(fn))
    add([((i%levels)<<shift)|((i*7)&((1<<shift)-1)) for i in range(n)])
    add([((i//3)%levels)<<shift for i in range(n)])
    add(pattern(lambda x,y:int(x==w//2 or y==h//2)*(levels-1)))
    for _ in range(4):add([rng.randrange(1<<p) for _ in range(n)])
    assert len(frames)==16
    add([hi]*n,0,None);add([hi]*n,None,0);add([hi]*n,0,0)
    if n>1:add([hi]*n,n-1,None)
    else:add([hi]*n,None,n-1)
    if (w,h,p,g,c)==(2,2,2,2,8):
        for image in product(range(4),repeat=4):add(image)
    if (w,h,p,g,c)==(3,3,1,1,4):
        for mask in range(512):add([(mask>>i)&1 for i in range(n)])
    assert len(frames)==(276 if (w,h)==(2,2) else 532 if (w,h)==(3,3) else 20)
    ins=[];out=[];latencies=[];total_zones=0
    coverage=dict(valid=0,error=0,sof_error=0,eol_error=0,both_marker_errors=0,
                  input_zones=0,nonzero_bins=0,constant=0,singleton_zones=0,full_frame_zones=0)
    for index,(image,sbad,ebad) in enumerate(frames):
        tag=(1<<t)-1 if index%5==0 else rng.getrandbits(t)
        errors=int(sbad is not None)|int(ebad is not None)<<1;mat,degree=zones(image,w,h,p,g,c)
        nz=sum(mat.values());total_zones+=nz if not errors else 0
        coverage['valid']+=not errors;coverage['error']+=bool(errors)
        coverage['sof_error']+=sbad is not None;coverage['eol_error']+=ebad is not None
        coverage['both_marker_errors']+=errors==3;coverage['input_zones']+=nz;coverage['nonzero_bins']+=len(mat)
        coverage['constant']+=nz==1;coverage['singleton_zones']+=sum(v for (gray,size),v in mat.items() if size==1)
        coverage['full_frame_zones']+=sum(v for (gray,size),v in mat.items() if size==n)
        for i,pixel in enumerate(image):
            ins.append(f'{pixel:x} {int(i==0)^int(i==sbad)} {int(i%w==w-1)^int(i==ebad)} {tag if i==0 else rng.getrandbits(t):x}\n')
        out.append(packed_matrix(mat,n,g,t,tag,errors))
        latencies.append(1 if errors else (c+4)*n+2*degree+3*nz+1)
    fresh=packed_matrix(zones([hi]+[0]*(n-1),w,h,p,g,c)[0],n,g,t,5&((1<<t)-1),0)
    return ''.join(ins),''.join(out),fresh,''.join(f'{v:x}\n' for v in latencies),len(frames),total_zones,coverage,max(latencies)


def main():
    target=ROOT/'verification.json';history=[]
    if target.is_file():
        previous=json.loads(target.read_bytes());history=previous.get('prior_failed_attempts',[])
        if any(c.get('status')=='TIMEOUT' for c in previous.get('incomplete_checks',[])):
            raise SystemExit('Previous child timed out; bounded policy forbids retries.')
        if 'FAILED_OR_NOT_RUN' in previous.get('status',[]):
            history.append({k:previous[k] for k in ('status','detail','checks','incomplete_checks','source_sha256') if k in previous})
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],checks=[],profiles=[],incomplete_checks=[],
                prior_failed_attempts=history,simulation_scope=SCOPE,
                oracle='Whole-image undirected equal-gray edge union, root-size frequency aggregation; independent grid-degree counts',
                dependency_sha256={},not_run=['synthesis','PnR','STA','board','expanded_regression','32x32 numerical simulation'])
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    exe={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ('iverilog','vvp')}
    report['tools']=exe;temporary=''
    def save():
        report['source_sha256']={f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in SOURCES if (ROOT/f).is_file()}
        report['license_sha256']={f:hashlib.sha256((ROOT.parents[2]/f).read_bytes()).hexdigest() for f in ('LICENSE','NOTICE')}
        target.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    def clean(args):return [x.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else x for x in args]
    def run(args,reject=False,version=False):
        pending=dict(command=clean(args),status='NOT_RUN',detail='Child not yet completed',timeout_seconds=20)
        report['incomplete_checks'].append(pending);save()
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except (OSError,subprocess.TimeoutExpired) as exc:
            pending.update(status='TIMEOUT' if isinstance(exc,subprocess.TimeoutExpired) else 'NOT_RUN',detail=repr(exc));save();raise
        report['incomplete_checks'].remove(pending)
        okay=(r.returncode>0 and 'grayscale_size_zone_invalid_parameters' in r.stderr) if reject else r.returncode==0 and (version or not r.stderr.strip())
        report['checks'].append(dict(command=clean(args),exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20));save()
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    save()
    try:
        if not all(exe.values()):raise RuntimeError('Local tools unavailable')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','grayscale_size_zone','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','zone_texture16','-f','example/files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','grayscale_size_zone','-Pgrayscale_size_zone.WIDTH=32',
             '-Pgrayscale_size_zone.HEIGHT=32','-Pgrayscale_size_zone.PIXEL_W=16','-Pgrayscale_size_zone.GRAY_W=3','-Pgrayscale_size_zone.TAG_W=32','-f','files.f'])
        report['simulation_scope']={**SCOPE,'maximum_32x32_compile':'PASS'}
        with tempfile.TemporaryDirectory(prefix='anscore_grayscale_size_zone_') as temporary:
            folder=Path(temporary)
            for w,h,p,g,c,t in PROFILES:
                ins,expected,fresh,latency,frames,nz,cov,maximum_latency=vectors(w,h,p,g,c,t);digests={}
                for name,data in [('inputs.txt',ins),('expected.mem',expected),('fresh.mem',fresh),('latency.mem',latency)]:
                    (folder/name).write_bytes(data.encode());digests[name]=hashlib.sha256(data.encode()).hexdigest()
                params=dict(WIDTH=w,HEIGHT=h,PIXEL_W=p,GRAY_W=g,CONNECTIVITY=c,TAG_W=t,FRAMES=frames,VALID_FRAMES=cov['valid'],ZONES=nz)
                run(['iverilog','-g2012','-Wall','-s','tb_grayscale_size_zone']+[f'-Ptb_grayscale_size_zone.{k}={v}' for k,v in params.items()]+
                    ['-o',str(folder/'unit.vvp'),'-f','files.f','sim/tb_grayscale_size_zone.sv'])
                result=run(['vvp',str(folder/'unit.vvp'),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                            f'+EXPECTED={(folder/"expected.mem").as_posix()}',f'+FRESH={(folder/"fresh.mem").as_posix()}',f'+LATENCY={(folder/"latency.mem").as_posix()}'])
                values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',result.splitlines()[0])}
                assert values['frames']==frames and values['pixels']==frames*w*h and values['outputs']==frames*(1<<g)*w*h
                assert values['first_checks']==frames and values['zone_checks']==nz and values['held_cycles'] and values['source_stalls']
                assert values['reset_probes']==values['fresh_checks']==(12 if w*h==1 else 20)
                report['profiles'].append(dict(**params,coverage=cov,maximum_checked_first_latency=maximum_latency,result=result,vectors_sha256=digests,service=values));save();print(result,flush=True)
            negatives=[{'WIDTH':0},{'WIDTH':33},{'HEIGHT':0},{'HEIGHT':33},{'PIXEL_W':0},{'PIXEL_W':17},
                       {'GRAY_W':0},{'GRAY_W':4},{'PIXEL_W':2,'GRAY_W':3},{'CONNECTIVITY':6},{'TAG_W':0},{'TAG_W':33}]
            for parameters in negatives:
                run(['iverilog','-g2012','-tnull','-s','grayscale_size_zone']+[f'-Pgrayscale_size_zone.{k}={v}' for k,v in parameters.items()]+['-f','files.f'],reject=True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (AssertionError,RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(exc);raise
    finally:save()


if __name__=='__main__':main()
