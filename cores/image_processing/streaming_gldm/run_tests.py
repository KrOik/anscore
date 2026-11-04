#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Predetermined finite clipped-coordinate oracle and bounded native tools."""
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
BASELINE='01b92bf2f8d81fff097f1965de61edf81604ae4f'
PROFILES=[(1,1,1,1,1),(1,7,4,2,3),(7,1,8,3,8),(2,2,2,2,8),
          (3,3,1,1,8),(8,5,8,3,8),(32,24,12,4,8),(128,1,16,4,32),(1,128,16,4,32)]
SOURCES=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f',
         'example/dependence32.sv','rtl/streaming_gldm.sv','sim/tb_streaming_gldm.sv','run_tests.py']
SCOPE=dict(profiles=9,main_frames=2228,largest_pixel_area_simulated=768,maximum_single_axis_extent_simulated=128,
           maximum_128x128_compile='NOT_RUN until recorded successful completion',
           maximum_128x128_numerical='NOT_RUN; excluded by predetermined budget',
           matrix_fixed_before_tools=True,fixture_reduction_after_timeout=False)


def matrix(pixels,w,h,p,g,alpha):
    """Enumerate each clipped 3x3 coordinate set, including its center.

    No padded raster, line history, sliding columns, or streaming recurrence.
    """
    image=[v>>(p-g) for v in pixels];counts=Counter();matched=inside=equal_cutoff=outside_cutoff=0
    for y in range(h):
        for x in range(w):
            center=image[y*w+x]
            points={(xx,yy) for yy in range(max(0,y-1),min(h,y+2)) for xx in range(max(0,x-1),min(w,x+2))}
            dependence=sum(abs(image[yy*w+xx]-center)<=alpha for xx,yy in points)
            assert (x,y) in points and 1<=dependence<=9
            counts[center,dependence]+=1;matched+=dependence-1;inside+=len(points)-1
            for xx,yy in points-{(x,y)}:
                delta=abs(image[yy*w+xx]-center);equal_cutoff+=delta==alpha;outside_cutoff+=delta==alpha+1
    n=w*h;assert sum(counts.values())==n
    assert sum(d*c for (gray,d),c in counts.items())==n+matched
    assert {gray:sum(c for (gg,d),c in counts.items() if gg==gray) for gray in set(image)}==dict(Counter(image))
    degree=2*h*(w-1)+2*w*(h-1)+4*(w-1)*(h-1);assert inside==degree
    if alpha==(1<<g)-1:assert matched==degree
    return counts,matched,equal_cutoff,outside_cutoff


def packed_matrix(counts,n,g,t,alpha,tag,errors):
    cw=max(1,n.bit_length());out=[]
    for gray in range(1<<g):
        for dependence in range(1,10):
            fields=[(errors,2),(tag,t),(int(gray==(1<<g)-1 and dependence==9),1),
                    (int(gray==0 and dependence==1),1),(alpha,g),(gray,g),(dependence,4),
                    (0 if errors else counts[gray,dependence],cw)]
            word=0
            for value,bits in fields:assert 0<=value<1<<bits;word=(word<<bits)|value
            out.append(f'{word:x}\n')
    return ''.join(out)


def vectors(w,h,p,g,t):
    n=w*h;hi=(1<<p)-1;levels=1<<g;shift=p-g
    rng=random.Random(0x474c444d+w*17+h*31+p*7+g);frames=[]
    def add(image,alpha=0,sbad=None,ebad=None):frames.append((list(image),alpha,sbad,ebad))
    def pattern(fn):return [(fn(x,y)%levels)<<shift for y in range(h) for x in range(w)]
    add([0]*n);add([hi]*n)
    add(pattern(lambda x,y:(x+y)%2),0);add(pattern(lambda x,y:(x+y)%2),levels-1)
    add(pattern(lambda x,y:x),1);add(pattern(lambda x,y:y),1)
    add(pattern(lambda x,y:int(x==y)*(levels-1)))
    add(pattern(lambda x,y:int(x==w-1 and y==h-1)*(levels-1)))
    add(pattern(lambda x,y:x//2+y//2))
    add([((i%levels)<<shift)|((i*7)&((1<<shift)-1)) for i in range(n)],1)
    add([((i//3)%levels)<<shift for i in range(n)],min(2,levels-1))
    add(pattern(lambda x,y:int(x==w//2 or y==h//2)*(levels-1)),levels-1)
    for alpha in (0,1,levels-1,(levels-1)//2):add([rng.randrange(1<<p) for _ in range(n)],alpha)
    assert len(frames)==16
    add([hi]*n,0,0,None);add([hi]*n,levels-1,None,0);add([hi]*n,1,0,0)
    if n>1:add([hi]*n,levels-1,n-1,None)
    else:add([hi]*n,levels-1,None,n-1)
    if (w,h,p,g)==(2,2,2,2):
        for image in product(range(4),repeat=4):
            for alpha in range(4):add(image,alpha)
    if (w,h,p,g)==(3,3,1,1):
        for mask in range(512):
            for alpha in range(2):add([(mask>>i)&1 for i in range(n)],alpha)
    assert len(frames)==(1044 if (w,h) in ((2,2),(3,3)) else 20)
    ins=[];out=[];latencies=[];per_frame_matches=[];total_matches=0
    coverage=dict(valid=0,error=0,sof_error=0,eol_error=0,both_marker_errors=0,
                  alpha_zero=0,alpha_maximum=0,nonzero_bins=0,cutoff_equal_neighbors=0,cutoff_plus_one_neighbors=0,
                  input_dependent_neighbors=0,singleton_dependence_centers=0,maximum_dependence_centers=0)
    tail=5*w+12+2*int(h>=2)*(1+int(w>=2))
    for fi,(image,alpha,sbad,ebad) in enumerate(frames):
        tag=(1<<t)-1 if fi%5==0 else rng.getrandbits(t);errors=int(sbad is not None)|int(ebad is not None)<<1
        mat,matched,equal,outside=matrix(image,w,h,p,g,alpha);total_matches+=matched
        coverage['valid']+=not errors;coverage['error']+=bool(errors);coverage['sof_error']+=sbad is not None;coverage['eol_error']+=ebad is not None
        coverage['both_marker_errors']+=errors==3;coverage['alpha_zero']+=alpha==0;coverage['alpha_maximum']+=alpha==levels-1
        coverage['nonzero_bins']+=len(mat);coverage['cutoff_equal_neighbors']+=equal;coverage['cutoff_plus_one_neighbors']+=outside
        coverage['input_dependent_neighbors']+=matched
        coverage['singleton_dependence_centers']+=sum(c for (gray,d),c in mat.items() if d==1)
        coverage['maximum_dependence_centers']+=sum(c for (gray,d),c in mat.items() if d==9)
        for i,pixel in enumerate(image):
            ins.append(f'{pixel:x} {alpha if i==0 else rng.randrange(levels):x} {int(i==0)^int(i==sbad)} {int(i%w==w-1)^int(i==ebad)} {tag if i==0 else rng.getrandbits(t):x}\n')
        out.append(packed_matrix(mat,n,g,t,alpha,tag,errors));latencies.append(f'{tail:x}\n');per_frame_matches.append(f'{matched:x}\n')
    fresh_alpha=levels-2;fresh_image=[hi]+[0]*(n-1)
    fresh=packed_matrix(matrix(fresh_image,w,h,p,g,fresh_alpha)[0],n,g,t,fresh_alpha,5&((1<<t)-1),0)
    return ''.join(ins),''.join(out),fresh,''.join(latencies),''.join(per_frame_matches),len(frames),total_matches,coverage,tail


def main():
    target=ROOT/'verification.json';history=[]
    if target.is_file():
        previous=json.loads(target.read_bytes());history=previous.get('prior_failed_attempts',[])
        if any(c.get('status')=='TIMEOUT' for c in previous.get('incomplete_checks',[])):
            raise SystemExit('Previous child timed out; bounded policy forbids retries.')
        if 'FAILED_OR_NOT_RUN' in previous.get('status',[]):
            history.append({k:previous[k] for k in ('status','detail','checks','incomplete_checks','source_sha256') if k in previous})
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],checks=[],profiles=[],incomplete_checks=[],prior_failed_attempts=history,
        simulation_scope=SCOPE,oracle='Direct clipped-coordinate neighbor sets per center, exact unsigned integer difference cutoff; no line/window recurrence',
        dependency_sha256={},not_run=['synthesis','PnR','STA','board','expanded_regression','128x128 numerical simulation'])
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    exe={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ('iverilog','vvp')};report['tools']=exe;temporary=''
    def save():
        report['source_sha256']={f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in SOURCES if (ROOT/f).is_file()}
        report['license_sha256']={f:hashlib.sha256((ROOT.parents[2]/f).read_bytes()).hexdigest() for f in ('LICENSE','NOTICE')}
        target.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    def clean(args):return [x.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else x for x in args]
    def run(args,reject=False,version=False):
        pending=dict(command=clean(args),status='NOT_RUN',detail='Child not yet completed',timeout_seconds=20);report['incomplete_checks'].append(pending);save()
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except (OSError,subprocess.TimeoutExpired) as exc:
            pending.update(status='TIMEOUT' if isinstance(exc,subprocess.TimeoutExpired) else 'NOT_RUN',detail=repr(exc));save();raise
        report['incomplete_checks'].remove(pending)
        okay=(r.returncode>0 and 'streaming_gldm_invalid_parameters' in r.stderr) if reject else r.returncode==0 and (version or not r.stderr.strip())
        report['checks'].append(dict(command=clean(args),exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20));save()
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    save()
    try:
        if not all(exe.values()):raise RuntimeError('Local tools unavailable')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','streaming_gldm','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','dependence32','-f','example/files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','streaming_gldm','-Pstreaming_gldm.WIDTH=128','-Pstreaming_gldm.HEIGHT=128',
             '-Pstreaming_gldm.PIXEL_W=16','-Pstreaming_gldm.GRAY_W=4','-Pstreaming_gldm.TAG_W=32','-f','files.f'])
        report['simulation_scope']={**SCOPE,'maximum_128x128_compile':'PASS'}
        with tempfile.TemporaryDirectory(prefix='anscore_streaming_gldm_') as temporary:
            folder=Path(temporary)
            for w,h,p,g,t in PROFILES:
                ins,expected,fresh,latency,matched,frames,matches,cov,tail=vectors(w,h,p,g,t);digests={}
                for name,data in [('inputs.txt',ins),('expected.mem',expected),('fresh.mem',fresh),('latency.mem',latency),('matches.mem',matched)]:
                    (folder/name).write_bytes(data.encode());digests[name]=hashlib.sha256(data.encode()).hexdigest()
                params=dict(WIDTH=w,HEIGHT=h,PIXEL_W=p,GRAY_W=g,TAG_W=t,FRAMES=frames,MATCHES=matches)
                run(['iverilog','-g2012','-Wall','-s','tb_streaming_gldm']+[f'-Ptb_streaming_gldm.{k}={v}' for k,v in params.items()]+
                    ['-o',str(folder/'unit.vvp'),'-f','files.f','sim/tb_streaming_gldm.sv'])
                result=run(['vvp',str(folder/'unit.vvp'),f'+INPUTS={(folder/"inputs.txt").as_posix()}',f'+EXPECTED={(folder/"expected.mem").as_posix()}',
                    f'+FRESH={(folder/"fresh.mem").as_posix()}',f'+LATENCY={(folder/"latency.mem").as_posix()}',f'+MATCHES={(folder/"matches.mem").as_posix()}'])
                values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',result.splitlines()[0])}
                assert values['frames']==frames and values['pixels']==frames*w*h and values['outputs']==frames*9*(1<<g)
                assert values['first_checks']==frames and values['match_checks']==matches and values['held_cycles'] and values['source_stalls']
                assert values['reset_probes']==values['fresh_checks']==(13 if w*h==1 else 15)
                report['profiles'].append(dict(**params,coverage=cov,exact_tail=tail,result=result,vectors_sha256=digests,service=values));save();print(result,flush=True)
            negatives=[{'WIDTH':0},{'WIDTH':129},{'HEIGHT':0},{'HEIGHT':129},{'PIXEL_W':0},{'PIXEL_W':17},
                       {'GRAY_W':0},{'GRAY_W':5},{'PIXEL_W':2,'GRAY_W':3},{'TAG_W':0},{'TAG_W':33}]
            for parameters in negatives:
                run(['iverilog','-g2012','-tnull','-s','streaming_gldm']+[f'-Pstreaming_gldm.{k}={v}' for k,v in parameters.items()]+['-f','files.f'],reject=True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (AssertionError,RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(exc);raise
    finally:save()


if __name__=='__main__':main()
