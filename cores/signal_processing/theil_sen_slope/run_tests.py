#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixed finite x-group/Fraction order-statistic oracle; local Icarus only."""
from collections import Counter, defaultdict
from fractions import Fraction
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='c778301aa12d1b9bf4290b1a982f4c6325713fcd'
PROFILES=[(1,2,1),(2,3,3),(3,5,8),(8,6,8),(12,8,8),(16,12,32)]
SOURCES=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f',
         'example/robust_slope8.sv','rtl/theil_sen_slope.sv','sim/tb_theil_sen_slope.sv','run_tests.py']


def central_slopes(records):
    """Group x levels first; Cartesian products make a weighted distribution.

    This has no arrival-order pair walker, insertion positions or multiplier
    schedule. Weighted rank selection also checks the median L1 subgradient.
    """
    groups=defaultdict(list)
    for x,y in records:groups[x].append(y)
    levels=sorted(groups);distribution=Counter()
    for ia,x0 in enumerate(levels):
        for x1 in levels[ia+1:]:
            for y0,y1 in itertools.product(groups[x0],groups[x1]):
                distribution[Fraction(y1-y0,x1-x0)]+=1
    total=sum(distribution.values())
    skipped=sum(len(ys)*(len(ys)-1)//2 for ys in groups.values())
    assert total+skipped==len(records)*(len(records)-1)//2
    if not total:return 0,skipped,Fraction(0),Fraction(0),Fraction(0)
    targets=[(total-1)//2,total//2];central=[];cumulative=0
    for slope,weight in sorted(distribution.items()):
        for index in targets[len(central):]:
            if cumulative<=index<cumulative+weight:central.append(slope)
            else:break
        cumulative+=weight
    assert len(central)==2
    low,high=central;median=(low+high)/2
    below=sum(v for x,v in distribution.items() if x<median)
    above=sum(v for x,v in distribution.items() if x>median)
    assert below<=total//2 and above<=total//2 and low<=median<=high
    if total%2:assert low==high==median
    return total,skipped,low,high,median


def vectors(w,capacity,tag_w):
    rng=random.Random(0x54484549+w*1000+capacity*10+tag_w)
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;smax=hi-lo;frames=[]
    def add(items):frames.append(list(items))
    def kept(points):add((x,y,1) for x,y in points)
    def clip(x):return max(lo,min(hi,x))
    add([(lo,hi,0)]);add([(lo,hi,0),(hi,lo,0)])
    kept([(lo,hi)]);kept([(lo,lo),(lo,hi)])
    for points in [[(lo,lo),(hi,hi)],[(hi,lo),(lo,hi)],[(hi,hi),(lo,lo)],
                   [(lo,0),(hi,0)],[(lo,hi),(hi,lo)]]:kept(points)
    # Two finite slopes: their unreduced mean uses the full sum/denominator
    # guard bits for W>=3; duplicates in x do not create a vertical slope.
    kept([(lo,lo),(hi,hi),(hi,hi-1)])
    kept([(lo,hi),(hi,lo),(hi,lo+1)])
    kept([(lo,lo),(hi,hi),(hi,lo)])
    kept([(hi,lo),(hi,hi),(lo,lo)])
    if w>=3:
        close=[(lo,lo),(hi,hi-1),(hi-1,hi-2)]
        for points in itertools.permutations(close):kept(points)
    base=[(lo+i*smax//(capacity-1),hi if i%2 else lo) for i in range(capacity)]
    kept(base);kept(reversed(base))
    kept([(x,x) for x,y in base]);kept([(x,0) for x,y in base])
    if w>=8:
        kept([(i,-i*i) for i in range(capacity)])
        kept([(i,clip(2*i if i!=capacity//2 else hi)) for i in range(capacity)])
    kept([(lo,lo)]*capacity)
    kept([(lo,lo)]*capacity+[(hi,hi),(hi,lo)])
    kept(base+[(lo,hi),(hi,lo)])
    add([(hi,lo,0)]+[(x,y,1) for x,y in base]+[(lo,hi,0)])
    add([(hi,hi,0),(lo,lo,1),(hi,lo,1),(lo,hi,0)])
    if w<=2:
        choices=list(itertools.product(range(lo,hi+1),repeat=2))
        for length in range(1,5 if w==1 else 4):
            for points in itertools.product(choices,repeat=length):kept(points)
    for index in range(35):
        n=rng.randint(2,min(capacity,6))
        points=[(rng.randint(lo,hi),rng.randint(lo,hi)) for _ in range(n)]
        if index%3==0:points[0]=(lo,points[0][1]);points[-1]=(hi,points[-1][1])
        if index%5==0:rng.shuffle(points)
        kept(points)
    for index in range(20):
        n=rng.randint(1,min(capacity+2,7))
        add((rng.randint(lo,hi),rng.randint(lo,hi),int(rng.randrange(5)!=0)) for _ in range(n))
    cw=capacity.bit_length();pmax=capacity*(capacity-1)//2;pw=max(1,pmax.bit_length())
    nw=2*w+2;dw=2*w+1;d=w+1;rw=2+tag_w+cw+2*pw+1+nw+dw+2*(d+w)
    coverage=dict(valid=0,no_slope=0,overflow=0,both_errors=0,empty=0,
        positive=0,negative=0,zero=0,odd_pairs=0,even_pairs=0,
        separated_medians=0,equal_x_pairs=0,full_pair_population=0,
        rank_distribution_entries=0,retained_members=0)
    inputs=[];expected=[];bounds=[];patterns=set()
    def signed(value,width):assert -(1<<(width-1))<=value<1<<(width-1);return value&((1<<width)-1)
    for fi,frame in enumerate(frames):
        tag=(1<<tag_w)-1 if fi%7==0 else rng.getrandbits(tag_w)
        for i,(x,y,keep) in enumerate(frame):
            inputs.append(f'{signed(x,w):x} {signed(y,w):x} {keep} {int(i==len(frame)-1)} '
                          f'{tag if i==0 else rng.getrandbits(tag_w):x}\n')
        all_kept=[(x,y) for x,y,keep in frame if keep];retained=all_kept[:capacity];n=len(retained)
        pairs,skipped,low,high,median=central_slopes(retained)
        errors=int(pairs==0)|(int(len(all_kept)>capacity)<<1);patterns.add(errors)
        coverage['retained_members']+=n;coverage['empty']+=n==0
        coverage['no_slope']+=bool(errors&1);coverage['overflow']+=bool(errors&2);coverage['both_errors']+=errors==3
        q=n*(n-1)//2
        if errors:
            pairs=skipped=even=0;low=high=median=Fraction(0);delay=1
            med_num=med_den=low_num=low_den=high_num=high_den=0
        else:
            coverage['valid']+=1;coverage['positive']+=median>0;coverage['negative']+=median<0;coverage['zero']+=median==0
            coverage['odd_pairs']+=pairs%2;coverage['even_pairs']+=pairs%2==0
            coverage['separated_medians']+=low!=high;coverage['equal_x_pairs']+=skipped
            coverage['full_pair_population']+=pairs==pmax
            coverage['rank_distribution_entries']+=pairs
            even=int(pairs%2==0);delay=6*q+(2*w+5)*q*(q-1)//2+3*w+8
            med_num,med_den=median.numerator,median.denominator
            low_num,low_den=low.numerator,low.denominator;high_num,high_den=high.numerator,high.denominator
        fields=[(errors,2),(tag,tag_w),(n,cw),(pairs,pw),(skipped,pw),(even,1),
                (signed(med_num,nw),nw),(med_den,dw),(signed(low_num,d),d),(low_den,w),
                (signed(high_num,d),d),(high_den,w)]
        word=0;bits=0
        for value,width in fields:assert 0<=value<1<<width;word=(word<<width)|value;bits+=width
        assert bits==rw
        expected.append(f'{word:0{(rw+3)//4}x}\n');bounds.append(f'{delay:x}\n')
    assert coverage['valid'] and coverage['no_slope'] and coverage['overflow'] and coverage['positive'] and coverage['negative']
    if capacity>2:assert coverage['even_pairs'] and coverage['separated_medians']
    return ''.join(inputs),''.join(expected),''.join(bounds),coverage,sorted(patterns)


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],checks=[],profiles=[],
        oracle='Group by x, Cartesian y products across x levels, Fraction weighted distribution and rank selection with L1 subgradient check',
        dependency_sha256={},not_run=['synthesis','PnR','STA','hardware','expanded_regression'])
    previous=ROOT/'verification.json'
    report['prior_failed_attempts']=[]
    if previous.is_file():
        old=json.loads(previous.read_text(encoding='utf-8'))
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):
            report['prior_failed_attempts'].append({k:old[k] for k in ['status','detail','checks','source_sha256'] if k in old})
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    exe={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ['iverilog','vvp']}
    temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except (OSError,subprocess.TimeoutExpired) as error:
            report['checks'].append(dict(command=args,status='FAIL',detail=str(error),timeout_seconds=20));raise
        okay=(r.returncode>0 and 'theil_sen_slope_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if not reject and args[0]=='iverilog' and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',
                                    stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        if not all(exe.values()):raise RuntimeError('NOT_RUN: native Icarus/vvp unavailable')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','theil_sen_slope','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','robust_slope8','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_theil_sen_') as temporary:
            folder=Path(temporary)
            for w,capacity,tag_w in PROFILES:
                inputs,expected,bounds,coverage,patterns=vectors(w,capacity,tag_w)
                digests={}
                for name,data in [('inputs.txt',inputs),('expected.mem',expected),('bounds.mem',bounds)]:
                    (folder/name).write_bytes(data.encode());digests[name]=hashlib.sha256(data.encode()).hexdigest()
                beats=len(inputs.splitlines());frames=len(expected.splitlines());image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_theil_sen_slope',f'-Ptb_theil_sen_slope.DATA_W={w}',
                    f'-Ptb_theil_sen_slope.MAX_LEN={capacity}',f'-Ptb_theil_sen_slope.TAG_W={tag_w}',
                    f'-Ptb_theil_sen_slope.BEATS={beats}',f'-Ptb_theil_sen_slope.FRAMES={frames}',
                    '-o',str(image),'-f','files.f','sim/tb_theil_sen_slope.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                    f'+EXPECTED={(folder/"expected.mem").as_posix()}',f'+BOUNDS={(folder/"bounds.mem").as_posix()}'])
                match=re.search(r'^PASS frames=(\d+) beats=(\d+) outputs=(\d+) first_checks=(\d+) max_latency=(\d+) held_cycles=(\d+) source_stalls=(\d+) pair_checks=(\d+) reset_probes=(\d+) fresh_checks=(\d+)$',output,re.M)
                if not match:raise RuntimeError('missing complete finite PASS record')
                values=list(map(int,match.groups()));assert values[:4]==[frames,beats,frames,frames]
                resets=15 if capacity==2 else 28
                assert values[8:]==[resets,resets] and values[5]>0 and values[6]>0
                report['profiles'].append(dict(DATA_W=w,MAX_LEN=capacity,TAG_W=tag_w,frames=frames,beats=beats,
                    coverage=coverage,error_patterns=patterns,vectors_sha256=digests,first_checks=values[3],maximum_first_latency=values[4],
                    held_cycles=values[5],source_stalls=values[6],pair_checks=values[7],reset_probes=values[8],fresh_checks=values[9],result=output))
                print(output,flush=True)
            for name,value in [('DATA_W',0),('DATA_W',17),('MAX_LEN',1),('MAX_LEN',13),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','theil_sen_slope',f'-Ptheil_sen_slope.{name}={value}','-f','files.f'],reject=True)
        for name in SOURCES:
            data=(ROOT/name).read_bytes();data.decode('utf-8',errors='strict')
            assert b'\r' not in data and data.endswith(b'\n') and not data.startswith(b'\xef\xbb\xbf'),name
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (AssertionError,RuntimeError,OSError,subprocess.TimeoutExpired) as error:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(error);raise
    finally:
        for check in report['checks']:
            check['command']=[x.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else x for x in check['command']]
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES if (ROOT/name).is_file()}
        report['license_sha256']={name:hashlib.sha256((ROOT.parents[2]/name).read_bytes()).hexdigest() for name in ['LICENSE','NOTICE']}
        report['tools']=exe
        (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
