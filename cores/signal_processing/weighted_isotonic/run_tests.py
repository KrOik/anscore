#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite weighted-isotonic tests using exact max-min and KKT oracles."""
from fractions import Fraction
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='807d992b6b0e793c08ceba2d44993d21c1dd1583'
PROFILES=[(1,1,1,1),(2,2,4,3),(4,3,5,8),(8,8,7,8),(16,8,16,8),(24,16,64,32)]


def exact_fit(values,weights):
    """Direct min-max characterization, without pooling, a stack or DUT state."""
    n=len(values);s=[0];t=[0]
    for x,w in zip(values,weights):s.append(s[-1]+x*w);t.append(t[-1]+w)
    means={(a,b):Fraction(s[b+1]-s[a],t[b+1]-t[a]) for a in range(n) for b in range(a,n)}
    fitted=[max(min(means[a,b] for b in range(i,n)) for a in range(i+1)) for i in range(n)]
    assert all(fitted[i]<=fitted[i+1] for i in range(n-1))
    residual=Fraction(0)
    for i,(x,w,y) in enumerate(zip(values,weights,fitted)):
        residual+=w*(y-x)
        assert residual<=0
        if i==n-1 or fitted[i]<fitted[i+1]:assert residual==0
    # Enumerating contiguous partitions supplies another small-domain check.
    if n<=5:
        best_loss=None;best_fitted=None
        for mask in range(1<<(n-1)):
            edges=[0]+[i+1 for i in range(n-1) if mask>>i&1]+[n]
            level=[means[a,b-1] for a,b in zip(edges,edges[1:])]
            if any(a>b for a,b in zip(level,level[1:])):continue
            candidate=[level[j] for j,(a,b) in enumerate(zip(edges,edges[1:])) for _ in range(a,b)]
            loss=sum((w*(y-x)**2 for x,w,y in zip(values,weights,candidate)),Fraction(0))
            if best_loss is None or loss<best_loss:best_loss,best_fitted=loss,candidate
        assert best_fitted==fitted
    blocks=[];start=0
    while start<n:
        end=start+1
        while end<n and fitted[end]==fitted[start]:end+=1
        num=s[end]-s[start];den=t[end]-t[start]
        assert Fraction(num,den)==fitted[start]
        blocks.append((num,den,start,end-start));start=end
    assert all(Fraction(a[0],a[1])<Fraction(b[0],b[1]) for a,b in zip(blocks,blocks[1:]))
    return blocks


def vectors(w,ww,capacity,tag_w):
    rng=random.Random(0x50415641+w*1000+ww*100+capacity)
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;wm=(1<<ww)-1
    frames=[]
    def add(items):frames.append(list(items))
    def kept(items):add((x,weight,1) for x,weight in items)
    add([(lo,0,0)])
    add([(hi,0,0),(lo,wm,0),(0,0,0)])
    kept([(lo,1)]);kept([(hi,wm)]);kept([(0,0)])
    kept([(lo,wm)]*capacity);kept([(hi,wm)]*capacity);kept([(0,1)]*capacity)
    asc=[lo+(hi-lo)*i//max(1,capacity-1) for i in range(capacity)]
    kept((x,1+i%wm) for i,x in enumerate(asc))
    kept((x,wm-i%wm) for i,x in enumerate(reversed(asc)))
    kept([(hi,1),(lo,wm),(hi,wm),(lo,1)])
    kept([(0,1),(-1,wm),(0,wm),(-1,1)])
    if w>=2:
        kept([(1,1),(0,wm),(1,1),(0,max(1,wm-1))])
        kept([(1,1),(0,max(1,wm-1)),(1,1),(0,wm)])
    kept([(0,wm),(-1,1),(0,max(1,wm-1)),(-1,1)])
    kept([(0,max(1,wm-1)),(-1,1),(0,wm),(-1,1)])
    add([(lo,wm,0)]+[(x,wm,1) for x in asc]+[(hi,0,0),(hi,0,0)])
    kept([(hi,1)]*(capacity+2))
    kept([(lo,wm)]*capacity+[(hi,0),(lo,1)])
    kept([(lo,0)]+[(hi,1)]*capacity)
    add([(hi,1,1),(lo,0,0),(lo,wm,1),(hi,0,0)])
    if w<=2:
        choices=list(itertools.product(range(lo,hi+1),range(1,wm+1)))
        for length in range(1,4):
            for seq in itertools.product(choices,repeat=length):kept(seq)
    for k in range(55):
        length=rng.randint(1,min(capacity,16))
        items=[(rng.randint(lo,hi),rng.randint(1,wm)) for _ in range(length)]
        if k%5==0:items.sort()
        if k%5==1:items.sort(reverse=True)
        if k%5==2:
            x=rng.randint(lo,hi);items=[(x,weight) for _,weight in items]
        kept(items)
    for k in range(35):
        length=rng.randint(1,min(capacity+3,18))
        add((rng.randint(lo,hi),rng.randint(0,wm),int(rng.randrange(5)!=0)) for _ in range(length))
    l=(capacity-1).bit_length();cw=max(1,capacity.bit_length());sw=w+ww+1+l;tw=ww+l
    rw=3+tag_w+2+5*cw+tw+sw
    inputs=[];expected=[]
    coverage=dict(valid_frames=0,error_frames=0,empty=0,over_capacity=0,zero_weight=0,
                  multiple_errors=0,zero_weight_in_excess=0,blocks=0,merged_samples=0,
                  multi_block_frames=0,negative_blocks=0,zero_blocks=0,positive_blocks=0,
                  unreduced_means=0,kkt_checks=0,partition_crosschecks=0)
    patterns=set()
    for fi,frame in enumerate(frames):
        tag=0 if fi%13==0 else ((1<<tag_w)-1 if fi%13==1 else rng.getrandbits(tag_w))
        for i,(x,weight,keep) in enumerate(frame):
            inputs.append(f'{x&((1<<w)-1):x} {weight:x} {keep} {int(i==len(frame)-1)} '
                          f'{tag if i==0 else rng.getrandbits(tag_w):x}\n')
        all_kept=[(x,weight) for x,weight,keep in frame if keep];retained=all_kept[:capacity]
        count=len(retained)
        bits=[count==0,len(all_kept)>capacity,any(weight==0 for _,weight in all_kept)]
        errors=sum(int(b)<<i for i,b in enumerate(bits));patterns.add(errors)
        for key,bit in zip(['empty','over_capacity','zero_weight'],bits):coverage[key]+=int(bit)
        coverage['multiple_errors']+=errors.bit_count()>1
        coverage['zero_weight_in_excess']+=any(weight==0 for _,weight in all_kept[capacity:])
        if errors:
            coverage['error_frames']+=1;blocks=[(0,0,0,0)]
        else:
            coverage['valid_frames']+=1
            blocks=exact_fit([x for x,_ in retained],[weight for _,weight in retained])
            coverage['blocks']+=len(blocks);coverage['merged_samples']+=count-len(blocks)
            coverage['multi_block_frames']+=len(blocks)>1;coverage['kkt_checks']+=count
            coverage['partition_crosschecks']+=count<=5
        for index,(num,den,start,length) in enumerate(blocks):
            keep=int(errors==0);last=int(index==len(blocks)-1)
            if keep:
                coverage['negative_blocks']+=num<0;coverage['zero_blocks']+=num==0;coverage['positive_blocks']+=num>0
                from math import gcd
                coverage['unreduced_means']+=gcd(abs(num),den)>1
            assert -(1<<(sw-1))<=num<(1<<(sw-1)) and 0<=den<1<<tw
            fields=[(num&((1<<sw)-1),sw),(den,tw),(start,cw),(length,cw),(count,cw),
                    (len(blocks) if keep else 0,cw),(index,cw),(keep,1),(last,1),(tag,tag_w),(errors,3)]
            packed=shift=0
            for value,width in fields:
                assert 0<=value<1<<width
                packed|=value<<shift;shift+=width
            assert shift==rw
            expected.append(f'{packed:0{(rw+3)//4}x}\n')
    return ''.join(inputs),''.join(expected),len(frames),coverage,sorted(patterns)


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],checks=[],profiles=[],dependencies=[],
                oracle='Fraction max_a min_b weighted interval means, KKT prefix conditions, small contiguous-partition loss enumeration',
                not_run=['synthesis','place_and_route','STA','hardware','expanded_regression'])
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    executables={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ['iverilog','vvp']}
    temporary=''
    def run(args,reject=False):
        result=subprocess.run([executables[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=15)
        okay=(result.returncode!=0 and 'weighted_isotonic_invalid_parameters' in result.stderr) if reject else result.returncode==0 and not result.stderr.strip()
        report['checks'].append(dict(command=args,exit_code=result.returncode,status='PASS' if okay else 'FAIL',
                                    stdout=result.stdout.strip(),stderr=result.stderr.strip(),timeout_seconds=15))
        if not okay:raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()
    try:
        if not all(executables.values()):raise RuntimeError('Icarus/vvp unavailable: NOT_RUN')
        report['tool']=run(['iverilog','-V']).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','weighted_isotonic','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','monotone_calibration16','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_weighted_isotonic_') as temporary:
            path=Path(temporary)
            for w,ww,capacity,tag_w in PROFILES:
                inputs,expected,frames,coverage,patterns=vectors(w,ww,capacity,tag_w)
                beats=len(inputs.splitlines());tokens=len(expected.splitlines())
                (path/'inputs.txt').write_bytes(inputs.encode());(path/'expected.mem').write_bytes(expected.encode())
                exe=path/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_weighted_isotonic',f'-Ptb_weighted_isotonic.DATA_W={w}',
                     f'-Ptb_weighted_isotonic.WEIGHT_W={ww}',f'-Ptb_weighted_isotonic.MAX_LEN={capacity}',
                     f'-Ptb_weighted_isotonic.TAG_W={tag_w}',f'-Ptb_weighted_isotonic.BEATS={beats}',
                     f'-Ptb_weighted_isotonic.TOKENS={tokens}',f'-Ptb_weighted_isotonic.FRAMES={frames}',
                     '-o',str(exe),'-f','files.f','sim/tb_weighted_isotonic.sv'])
                output=run(['vvp',str(exe),f'+INPUTS={(path/"inputs.txt").as_posix()}',f'+EXPECTED={(path/"expected.mem").as_posix()}'])
                if f'PASS frames={frames} beats={beats} tokens={tokens} outputs={tokens}' not in output:
                    raise RuntimeError('finite simulation did not complete')
                report['profiles'].append(dict(DATA_W=w,WEIGHT_W=ww,MAX_LEN=capacity,TAG_W=tag_w,frames=frames,
                    beats=beats,tokens=tokens,coverage=coverage,error_patterns=patterns,
                    inputs_sha256=hashlib.sha256(inputs.encode()).hexdigest(),expected_sha256=hashlib.sha256(expected.encode()).hexdigest(),result=output))
                print(output,flush=True)
            for parameter,value in [('DATA_W',0),('DATA_W',25),('WEIGHT_W',0),('WEIGHT_W',17),
                                    ('MAX_LEN',0),('MAX_LEN',65),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','weighted_isotonic',f'-Pweighted_isotonic.{parameter}={value}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=str(exc);raise
    finally:
        for check in report['checks']:
            check['command']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else a for a in check['command']]
        names=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f','example/monotone_calibration16.sv',
               'rtl/weighted_isotonic.sv','sim/tb_weighted_isotonic.sv','run_tests.py']
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names if (ROOT/name).is_file()}
        report['license_sha256']={name:hashlib.sha256((ROOT.parents[2]/name).read_bytes()).hexdigest() for name in ['LICENSE','NOTICE']}
        report['tools']=executables
        (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
