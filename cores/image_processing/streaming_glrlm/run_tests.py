#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Predetermined finite line-enumeration oracle and bounded local tools."""
from collections import Counter
from itertools import groupby,product
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
BASELINE='d35ce742b34ffa7afebffe0b9f6705a825f469e1'
PROFILES=[(1,1,1,1,1),(1,7,3,2,3),(7,1,4,2,8),(2,2,2,2,8),
          (3,3,1,1,8),(8,5,8,3,8),(32,24,12,4,8),(128,1,16,4,32),(1,128,16,4,32)]
SOURCES=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f',
         'example/texture64.sv','rtl/streaming_glrlm.sv','sim/tb_streaming_glrlm.sv','run_tests.py']


def matrices(pixels,width,height,pixel_w,gray_w):
    """Whole geometric lines then maximal equal-value groups, no prefix updates."""
    image=[p>>(pixel_w-gray_w) for p in pixels];mat=[];n=width*height
    for dx,dy in [(1,0),(0,1),(1,1),(-1,1)]:
        counts=Counter()
        for y in range(height):
            for x in range(width):
                if 0<=x-dx<width and 0<=y-dy<height:continue
                line=[];cx,cy=x,y
                while 0<=cx<width and 0<=cy<height:
                    line.append(image[cy*width+cx]);cx+=dx;cy+=dy
                for gray,run in groupby(line):counts[gray,sum(1 for _ in run)]+=1
        assert sum(length*count for (gray,length),count in counts.items())==n
        assert 1<=sum(counts.values())<=n
        mat.append(counts)
    return mat


def packed_matrix(mat,width,height,gray_w,tag_w,tag,errors):
    n=width*height;limit=max(width,height);cw=max(1,n.bit_length());lw=max(1,limit.bit_length());out=[]
    for direction in range(4):
        total=0 if errors else sum(mat[direction].values())
        for gray in range(1<<gray_w):
            for length in range(1,limit+1):
                count=0 if errors else mat[direction][gray,length]
                end=int(gray==(1<<gray_w)-1 and length==limit)
                fields=[(errors,2),(tag,tag_w),(int(direction==3 and end),1),(end,1),
                        (direction,2),(gray,gray_w),(length,lw),(total,cw),(count,cw)]
                word=0
                for value,bits in fields:assert 0<=value<1<<bits;word=(word<<bits)|value
                out.append(f'{word:x}\n')
    return ''.join(out)


def vectors(w,h,p,g,t):
    n=w*h;hi=(1<<p)-1;levels=1<<g;shift=p-g;rng=random.Random(0x52554e53+w*17+h*31+p*7+g)
    frames=[]
    def add(image,sbad=None,ebad=None):frames.append((list(image),sbad,ebad))
    def pattern(fn):return [(fn(x,y)%levels)<<shift for y in range(h) for x in range(w)]
    add([0]*n);add([hi]*n)
    for fn in [lambda x,y:x+y,lambda x,y:x,lambda x,y:y,lambda x,y:int(x==y),
               lambda x,y:int(x+y==w-1),lambda x,y:x//2+y//2]:add(pattern(fn))
    add([((i%levels)<<shift)|((i*7)&((1<<shift)-1)) for i in range(n)])
    add([((i//3)%levels)<<shift for i in range(n)])
    for _ in range(3):add([rng.randrange(1<<p) for _ in range(n)])
    add([hi]*n,0,None);add([hi]*n,None,n-1);add([hi]*n,0,n-1)
    if n>1:add([hi]*n,n-1,None);add([hi]*n,None,0)
    if max(w,h)==128:
        # Fixed before the first tool run: small boundary-profile matrix.
        frames=[([0]*n,None,None),([hi]*n,None,None),
                (pattern(lambda x,y:(x+y)//3),None,None),([hi]*n,0,n-1)]
    if (w,h,p,g)==(2,2,2,2):
        for image in product(range(4),repeat=4):add(image)
    if (w,h,p,g)==(3,3,1,1):
        for mask in range(512):add([(mask>>i)&1 for i in range(n)])
    ins=[];out=[];extensions=0
    coverage=dict(valid=0,error=0,sof_error=0,eol_error=0,all_constant=0,nonzero_bins=0,runs=0)
    for index,(image,sbad,ebad) in enumerate(frames):
        tag=(1<<t)-1 if index%5==0 else rng.getrandbits(t);errors=int(sbad is not None)|int(ebad is not None)<<1
        mat=matrices(image,w,h,p,g);runs=sum(sum(c.values()) for c in mat);extensions+=4*n-runs
        coverage['valid']+=not errors;coverage['error']+=bool(errors);coverage['sof_error']+=sbad is not None;coverage['eol_error']+=ebad is not None
        coverage['all_constant']+=len(set(v>>shift for v in image))==1
        coverage['nonzero_bins']+=sum(len(c) for c in mat);coverage['runs']+=runs
        for i,pixel in enumerate(image):
            ins.append(f'{pixel:x} {int(i==0)^int(i==sbad)} {int(i%w==w-1)^int(i==ebad)} {tag if i==0 else rng.getrandbits(t):x}\n')
        out.append(packed_matrix(mat,w,h,g,t,tag,errors))
    fresh_image=[hi]+[0]*(n-1);fresh=packed_matrix(matrices(fresh_image,w,h,p,g),w,h,g,t,5&((1<<t)-1),0)
    return ''.join(ins),''.join(out),fresh,len(frames),extensions,coverage


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],checks=[],profiles=[],incomplete_checks=[],
                oracle='Geometric line starts, whole-line extraction and itertools.groupby maximal runs',
                not_run=['synthesis','PnR','STA','board','expanded_regression','128x128 numerical simulation'])
    report['prior_failed_attempts']=[]
    if (ROOT/'verification.json').is_file():
        previous=json.loads((ROOT/'verification.json').read_text())
        report['prior_failed_attempts']=previous.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in previous.get('status',[]):
            report['prior_failed_attempts'].append({k:previous[k] for k in ['status','detail','checks','incomplete_checks','source_sha256'] if k in previous})
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    exe={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ('iverilog','vvp')};temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except (OSError,subprocess.TimeoutExpired) as exc:
            report['incomplete_checks'].append(dict(command=args,status='TIMEOUT' if isinstance(exc,subprocess.TimeoutExpired) else 'NOT_RUN',detail=str(exc),timeout_seconds=20));raise
        okay=(r.returncode>0 and 'streaming_glrlm_invalid_parameters' in r.stderr) if reject else r.returncode==0 and (version or not r.stderr.strip())
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        if not all(exe.values()):raise RuntimeError('Local tools unavailable')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','streaming_glrlm','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','texture64','-f','example/files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','streaming_glrlm','-Pstreaming_glrlm.WIDTH=128',
             '-Pstreaming_glrlm.HEIGHT=128','-Pstreaming_glrlm.PIXEL_W=16','-Pstreaming_glrlm.GRAY_W=4','-Pstreaming_glrlm.TAG_W=32','-f','files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_streaming_glrlm_') as temporary:
            folder=Path(temporary)
            for w,h,p,g,t in PROFILES:
                ins,expected,fresh,frames,extensions,cov=vectors(w,h,p,g,t)
                digests={}
                for name,data in [('inputs.txt',ins),('expected.mem',expected),('fresh.mem',fresh)]:
                    (folder/name).write_bytes(data.encode());digests[name]=hashlib.sha256(data.encode()).hexdigest()
                params=dict(WIDTH=w,HEIGHT=h,PIXEL_W=p,GRAY_W=g,TAG_W=t,FRAMES=frames,EXTENSIONS=extensions)
                args=['iverilog','-g2012','-Wall','-s','tb_streaming_glrlm']+[f'-Ptb_streaming_glrlm.{k}={v}' for k,v in params.items()]
                run(args+['-o',str(folder/'unit.vvp'),'-f','files.f','sim/tb_streaming_glrlm.sv'])
                result=run(['vvp',str(folder/'unit.vvp'),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                            f'+EXPECTED={(folder/"expected.mem").as_posix()}',f'+FRESH={(folder/"fresh.mem").as_posix()}'])
                values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',result.splitlines()[0])}
                assert values['frames']==frames and values['pixels']==frames*w*h and values['outputs']==frames*4*(1<<g)*max(w,h)
                assert values['extensions']==extensions and values['first_checks']==frames and values['held_cycles'] and values['source_stalls']
                assert values['reset_probes']==values['fresh_checks']==(9 if w*h==1 else 10)
                report['profiles'].append(dict(**params,coverage=cov,result=result,vectors_sha256=digests,service=values));print(result,flush=True)
            negatives=[{'WIDTH':0},{'WIDTH':129},{'HEIGHT':0},{'HEIGHT':129},{'PIXEL_W':0},{'PIXEL_W':17},
                       {'GRAY_W':0},{'GRAY_W':5},{'PIXEL_W':2,'GRAY_W':3},{'TAG_W':0},{'TAG_W':33}]
            for parameters in negatives:
                run(['iverilog','-g2012','-tnull','-s','streaming_glrlm']+[f'-Pstreaming_glrlm.{k}={v}' for k,v in parameters.items()]+['-f','files.f'],reject=True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (AssertionError,RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(exc);raise
    finally:
        for check in report['checks']+report['incomplete_checks']:
            check['command']=[x.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else x for x in check['command']]
        report['source_sha256']={f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in SOURCES if (ROOT/f).is_file()}
        report['license_sha256']={f:hashlib.sha256((ROOT.parents[2]/f).read_bytes()).hexdigest() for f in ('LICENSE','NOTICE')}
        report['tools']=exe;(ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
