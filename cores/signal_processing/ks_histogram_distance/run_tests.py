#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixed finite normalized-mass CDF oracle and bounded native Icarus checks."""
from bisect import bisect_right
from collections import Counter
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
BASELINE='d35ce742b34ffa7afebffe0b9f6705a825f469e1'
PROFILES=[(1,1,1,1),(2,2,3,3),(3,3,5,8),(8,8,7,8),(16,12,32,8),(32,16,128,32)]
SOURCES=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f',
         'example/distribution32.sv','rtl/ks_histogram_distance.sv','sim/tb_ks_histogram_distance.sv','run_tests.py']


def cdf_distance(records):
    """Normalize each bin first, then independently query the full mass map.

    This does not run a bounded prefix accumulator or product engine. Tiny
    frequency populations are also expanded to raw samples and rank-queried.
    """
    ta=sum(a for key,a,b in records);tb=sum(b for key,a,b in records)
    assert ta>0 and tb>0 and all(records[i][0]<records[i+1][0] for i in range(len(records)-1))
    mass_a={key:Fraction(a,ta) for key,a,b in records}
    mass_b={key:Fraction(b,tb) for key,a,b in records}
    assert sum(mass_a.values())==sum(mass_b.values())==1
    fa=[sum((mass for x,mass in mass_a.items() if x<=key),Fraction(0)) for key,a,b in records]
    fb=[sum((mass for x,mass in mass_b.items() if x<=key),Fraction(0)) for key,a,b in records]
    assert fa[-1]==fb[-1]==1 and all(0<=x<=1 for x in fa+fb)
    diffs=[x-y for x,y in zip(fa,fb)]
    plus=max([Fraction(0),*diffs]);minus=max([Fraction(0),*(-x for x in diffs)])
    distance=max(plus,minus);index=next(i for i,x in enumerate(diffs) if abs(x)==distance)
    sign=(diffs[index]>0)-(diffs[index]<0)
    assert 0<=distance<=1 and distance==max(abs(x) for x in diffs)
    raw_check=ta+tb<=32
    if raw_check:
        aa=sorted(key for key,a,b in records for _ in range(a))
        bb=sorted(key for key,a,b in records for _ in range(b))
        raw=[Fraction(bisect_right(aa,key),len(aa))-Fraction(bisect_right(bb,key),len(bb)) for key,a,b in records]
        assert raw==diffs
    denominator=ta*tb
    scaled=[distance*denominator,plus*denominator,minus*denominator]
    assert all(x.denominator==1 for x in scaled)
    return tuple(int(x) for x in scaled),denominator,index,sign,raw_check,diffs


def vectors(k,f,capacity,tag_w):
    rng=random.Random(0x4b534344+k*1000+f*100+capacity+tag_w)
    lo=-(1<<(k-1));hi=(1<<(k-1))-1;maximum=(1<<f)-1;frames=[]
    def add(rows):frames.append(list(rows))
    def kept(rows):add((key,a,b,1) for key,a,b in rows)
    add([(hi,maximum,maximum,0)]);add([(hi,1,0,0),(lo,0,1,0)])
    kept([(lo,0,0)]);kept([(hi,0,maximum)]);kept([(lo,maximum,0)])
    kept([(hi,maximum,maximum)])
    kept([(lo,maximum,0),(hi,0,maximum)])
    kept([(lo,0,maximum),(hi,maximum,0)])
    kept([(lo,0,0),(hi,maximum,maximum)])
    kept([(lo,maximum,maximum),(hi,0,0)])
    kept([(lo,maximum,maximum),(lo,0,0)])
    kept([(hi,maximum,maximum),(lo,0,0)])
    if capacity>=3 and k>=2 and f>=2:
        for a,b in [(1,0),(0,1)]:
            kept([(lo,a,b),(lo+1,2*b,2*a),(hi,a,b)])
        kept([(lo,2,1),(lo+1,0,0),(hi,2,1)])
        kept([(lo,0,0),(lo+1,1,0),(hi,0,1)])
    keys=list(range(lo,lo+capacity))
    full=[(key,maximum,maximum) for key in keys]
    kept(full)
    kept([(key,maximum if i<capacity//2 else 0,maximum if i>=capacity//2 else 0) for i,key in enumerate(keys)])
    kept([(key,maximum if i>=capacity//2 else 0,maximum if i<capacity//2 else 0) for i,key in enumerate(keys)])
    kept([(key,maximum if i%2==0 else 0,maximum if i%2 else 0) for i,key in enumerate(keys)])
    kept([(key,0,0) for key in keys])
    kept([(key,0,maximum) for key in keys]+[(hi,maximum,0)])
    kept(full+[(hi,maximum,maximum)])
    kept(full+[(keys[-1],0,0)])
    add([(hi,maximum,0,0)]+[(key,a,b,1) for key,a,b in full]+[(lo,0,maximum,0)])
    add([(hi,0,1,0),(lo,maximum,0,1),(lo,1,1,0),(hi,0,maximum,1),(lo,1,1,0)])
    if k<=2 and f<=2:
        choices=list(itertools.product(range(lo,hi+1),range(maximum+1),range(maximum+1)))
        for length in range(1,4 if k==1 else 3):
            for rows in itertools.product(choices,repeat=length):kept(rows)
    for number in range(35):
        n=rng.randint(1,min(capacity,8,1<<k))
        ordered=sorted(rng.sample(range(lo,hi+1),n))
        counts=[(rng.randint(0,maximum),rng.randint(0,maximum)) for _ in ordered]
        if number%3==0:counts[0]=(maximum,counts[0][1]);counts[-1]=(counts[-1][0],maximum)
        kept([(key,a,b) for key,(a,b) in zip(ordered,counts)])
    for number in range(20):
        n=rng.randint(1,min(capacity+2,9))
        add((rng.randint(lo,hi),rng.randint(0,maximum),rng.randint(0,maximum),int(rng.randrange(5)!=0)) for _ in range(n))
    cw=max(1,capacity.bit_length());tw=max(1,(capacity*maximum).bit_length());dw=2*tw
    rw=6+tag_w+2*cw+10*tw+k
    cov=dict(valid=0,empty=0,missing_a=0,missing_b=0,order_error=0,overflow=0,multiple_errors=0,
        positive_direction=0,negative_direction=0,zero_distance=0,distance_one=0,
        both_directional_extrema=0,opposite_sign_max_ties=0,zero_frequency_bins=0,
        witness_after_first_bin=0,full_capacity=0,maximum_both_totals=0,raw_sample_crosschecks=0,
        cdf_queries=0,retained_bins=0)
    inputs=[];expected=[];latencies=[];patterns=set();rows_checked=0
    for fi,frame in enumerate(frames):
        tag=(1<<tag_w)-1 if fi%11==0 else (0 if fi%11==1 else rng.getrandbits(tag_w))
        for i,(key,a,b,keep) in enumerate(frame):
            assert lo<=key<=hi and 0<=a<=maximum and 0<=b<=maximum
            inputs.append(f'{key&((1<<k)-1):x} {a:x} {b:x} {keep} {int(i==len(frame)-1)} '
                          f'{tag if i==0 else rng.getrandbits(tag_w):x}\n')
        all_kept=[(key,a,b) for key,a,b,keep in frame if keep];retained=all_kept[:capacity];n=len(retained)
        ta=sum(a for key,a,b in retained);tb=sum(b for key,a,b in retained)
        order=any(x[0]>=y[0] for x,y in zip(all_kept,all_kept[1:]))
        bits=[ta==0,tb==0,order,len(all_kept)>capacity]
        errors=sum(int(b)<<i for i,b in enumerate(bits));patterns.add(errors)
        cov['retained_bins']+=n;cov['empty']+=n==0;cov['zero_frequency_bins']+=sum(a==b==0 for key,a,b in retained)
        for name,bit in zip(['missing_a','missing_b','order_error','overflow'],bits):cov[name]+=int(bit)
        cov['multiple_errors']+=errors.bit_count()>1
        if errors:num=den=plus=minus=witness=index=direction=0;delay=1
        else:
            (num,plus,minus),den,index,direction,raw,diffs=cdf_distance(retained)
            witness=retained[index][0];delay=tw+2+n*(2*tw+4);rows_checked+=n
            cov['valid']+=1;cov['positive_direction']+=direction==1;cov['negative_direction']+=direction==-1
            cov['zero_distance']+=num==0;cov['distance_one']+=num==den
            cov['both_directional_extrema']+=plus>0 and minus>0
            cov['opposite_sign_max_ties']+=plus==minus and plus>0
            cov['witness_after_first_bin']+=index>0;cov['full_capacity']+=n==capacity
            cov['maximum_both_totals']+=ta==tb==capacity*maximum
            cov['raw_sample_crosschecks']+=raw;cov['cdf_queries']+=n
        fields=[(errors,4),(tag,tag_w),(n,cw),(ta,tw),(tb,tw),(num,dw),(den,dw),(plus,dw),(minus,dw),
                (witness&((1<<k)-1),k),(index,cw),(direction&3,2)]
        word=bits_used=0
        for value,width in fields:assert 0<=value<1<<width;word=(word<<width)|value;bits_used+=width
        assert bits_used==rw
        expected.append(f'{word:0{(rw+3)//4}x}\n');latencies.append(f'{delay:x}\n')
    assert cov['valid'] and cov['missing_a'] and cov['missing_b'] and cov['order_error'] and cov['overflow']
    if capacity>1:assert cov['positive_direction'] and cov['negative_direction'] and cov['distance_one']
    if capacity>=3:assert cov['opposite_sign_max_ties'] and cov['witness_after_first_bin']
    return ''.join(inputs),''.join(expected),''.join(latencies),rows_checked,cov,sorted(patterns)


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        dependency_sha256={},oracle='Normalized Fraction mass maps queried at each key; tiny populations independently expanded and bisect-ranked',
        not_run=['synthesis','PnR','STA','hardware','expanded_regression'],timeout_retry_policy='Stop on any 20-second child timeout; no automatic retry, fixture reduction or timeout increase.')
    path=ROOT/'verification.json'
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
    if path.is_file():
        old=json.loads(path.read_text(encoding='utf-8'))
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):
            report['prior_failed_attempts'].append({k:old[k] for k in ['status','detail','checks','source_sha256'] if k in old})
    save() # Remove any old PASS before discovering tools or running a child.
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    exe={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ['iverilog','vvp']}
    temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode('utf-8',errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,exit_code=None,status='TIMEOUT',stdout=decode(error.stdout),stderr=decode(error.stderr),timeout_seconds=20))
            report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(r.returncode>0 and 'ks_histogram_distance_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if not reject and args[0]=='iverilog' and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',
                                    stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        if not all(exe.values()):raise RuntimeError('NOT_RUN native Icarus/vvp required')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','ks_histogram_distance','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','distribution32','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_ks_histogram_') as temporary:
            folder=Path(temporary)
            for k,f,capacity,tag_w in PROFILES:
                inputs,expected,latency,rows,coverage,patterns=vectors(k,f,capacity,tag_w)
                digests={}
                for name,data in [('inputs.txt',inputs),('expected.mem',expected),('latency.mem',latency)]:
                    (folder/name).write_bytes(data.encode());digests[name]=hashlib.sha256(data.encode()).hexdigest()
                beats=len(inputs.splitlines());frames=len(expected.splitlines());products=coverage['valid']+2*rows;image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_ks_histogram_distance',f'-Ptb_ks_histogram_distance.KEY_W={k}',
                    f'-Ptb_ks_histogram_distance.FREQ_W={f}',f'-Ptb_ks_histogram_distance.MAX_BINS={capacity}',
                    f'-Ptb_ks_histogram_distance.TAG_W={tag_w}',f'-Ptb_ks_histogram_distance.BEATS={beats}',
                    f'-Ptb_ks_histogram_distance.FRAMES={frames}',f'-Ptb_ks_histogram_distance.ROWS={rows}',
                    f'-Ptb_ks_histogram_distance.PRODUCTS={products}','-o',str(image),'-f','files.f','sim/tb_ks_histogram_distance.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                    f'+EXPECTED={(folder/"expected.mem").as_posix()}',f'+LATENCY={(folder/"latency.mem").as_posix()}'])
                match=re.search(r'^PASS frames=(\d+) beats=(\d+) outputs=(\d+) latency_checks=(\d+) max_latency=(\d+) row_checks=(\d+) multiply_checks=(\d+) held_cycles=(\d+) source_stalls=(\d+) reset_probes=(\d+) fresh_checks=(\d+)$',output,re.M)
                if not match:raise RuntimeError('missing complete finite PASS marker')
                values=list(map(int,match.groups()));assert values[:4]==[frames,beats,frames,frames]
                assert values[5:7]==[rows,products] and values[9:]==[18,18] and values[7]>0 and values[8]>0
                report['profiles'].append(dict(KEY_W=k,FREQ_W=f,MAX_BINS=capacity,TAG_W=tag_w,frames=frames,beats=beats,
                    coverage=coverage,error_patterns=patterns,vectors_sha256=digests,latency_checks=values[3],maximum_first_latency=values[4],
                    row_checks=values[5],multiply_checks=values[6],held_cycles=values[7],source_stalls=values[8],
                    reset_probes=values[9],fresh_checks=values[10],result=output));print(output,flush=True)
            for name,value in [('KEY_W',0),('KEY_W',33),('FREQ_W',0),('FREQ_W',17),('MAX_BINS',0),('MAX_BINS',129),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','ks_histogram_distance',f'-Pks_histogram_distance.{name}={value}','-f','files.f'],reject=True)
        for name in SOURCES:
            data=(ROOT/name).read_bytes();data.decode('utf-8',errors='strict')
            assert b'\r' not in data and data.endswith(b'\n') and not data.startswith(b'\xef\xbb\xbf'),name
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'];report['matrix_status']='PASS'
    except subprocess.TimeoutExpired as error:
        report['status']=['NOT_RUN','HW_UNVERIFIED'];report['detail']=str(error)+'; stopped without retry';raise
    except (AssertionError,RuntimeError,OSError) as error:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(error);raise
    finally:
        for check in report['checks']:
            check['command']=[x.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else x for x in check['command']]
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES if (ROOT/name).is_file()}
        report['license_sha256']={name:hashlib.sha256((ROOT.parents[2]/name).read_bytes()).hexdigest() for name in ['LICENSE','NOTICE']}
        report['tools']=exe;save()


if __name__=='__main__':main()
