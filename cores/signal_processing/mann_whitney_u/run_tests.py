#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite pooled-average-rank oracle, exact Fraction rounding and Icarus checks."""
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
BASELINE='e2ccd5380052e92a5430e97b6fdbf0621a17503c'
DEPENDENCY='../dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv'
PROFILES=[(1,1,0,1),(2,4,0,3),(3,5,1,8),(8,7,8,8),(16,32,16,8),(32,128,24,32)]


def pooled_ranks(records):
    """Combined average ranks, without comparing every A/B sample pair."""
    ordered=sorted(records);ra=Fraction(0);i=0
    while i<len(ordered):
        end=i+1
        while end<len(ordered) and ordered[end][0]==ordered[i][0]:end+=1
        rank=Fraction(i+1+end,2)
        ra+=rank*sum(group==0 for value,group in ordered[i:end]);i=end
    na=sum(group==0 for value,group in records);nb=len(records)-na
    ua=ra-Fraction(na*(na+1),2)
    rb=Fraction(len(records)*(len(records)+1),2)-ra
    ub=rb-Fraction(nb*(nb+1),2)
    assert ua+ub==na*nb and (2*ua).denominator==1
    u2=int(2*ua);pairs=na*nb
    ca=Counter(value for value,group in records if group==0)
    cb=Counter(value for value,group in records if group==1)
    ties=sum(amount*cb[value] for value,amount in ca.items())
    assert (u2-ties)%2==0
    wins=(u2-ties)//2;losses=pairs-wins-ties
    assert min(wins,losses,ties)>=0 and wins+losses+ties==pairs and 0<=u2<=2*pairs
    return na,nb,pairs,wins,losses,ties,u2


def vectors(w,capacity,frac,tag_w):
    rng=random.Random(0x4d575531+w*1000+capacity*10+frac)
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;frames=[]
    def add(items):frames.append(list(items))
    def kept(items):add((x,group,1) for x,group in items)
    add([(lo,0,0)]);add([(hi,1,0),(lo,0,0),(0,1,0)])
    kept([(lo,0)]);kept([(hi,1)])
    kept([(0,0),(0,1)])
    kept([(hi,0),(lo,1)]);kept([(lo,0),(hi,1)])
    kept([(0,0),(0,1),(lo,1)]);kept([(0,0),(0,1),(hi,1)])
    if w>=2:
        kept([(1,0),(0,1),(0,1),(0,1),(1,1)])
        kept([(0,0),(1,1),(1,1),(1,1),(0,1)])
    for group in (0,1):kept([(lo,group)]*capacity)
    half=capacity//2
    base=[(hi,0)]*half+[(lo,1)]*(capacity-half)
    kept(base);kept(reversed(base));kept([(x,1-g) for x,g in base])
    kept([(0,i%2) for i in range(capacity)])
    kept([(lo if i%3 else hi,i%2) for i in range(capacity)])
    add([(hi,1,0)]+[(x,g,1) for x,g in base]+[(lo,0,0),(hi,1,0)])
    kept([(hi,i%2) for i in range(capacity+2)])
    kept([(lo,0)]*capacity+[(hi,1),(0,1)])
    add([(lo,1,0),(hi,0,1),(hi,1,0),(lo,1,1),(0,0,0)])
    if w<=2:
        choices=list(itertools.product(range(lo,hi+1),range(2)))
        for length in range(1,5 if w==2 else 4):
            for seq in itertools.product(choices,repeat=length):kept(seq)
    for k in range(55):
        length=rng.randint(1,min(capacity,16));samples=[]
        for i in range(length):
            x=rng.choice([lo,hi,-1,0]) if k%2 else rng.randint(lo,hi)
            samples.append((x,rng.randrange(2)))
        if length>=2:samples[0]=(samples[0][0],0);samples[-1]=(samples[-1][0],1)
        if k%3==0:rng.shuffle(samples)
        kept(samples)
    for k in range(35):
        length=rng.randint(1,min(capacity+3,18))
        add((rng.randint(lo,hi),rng.randrange(2),int(rng.randrange(5)!=0)) for _ in range(length))
    cw=max(1,capacity.bit_length());pw=max(1,(2*(capacity*capacity//4)).bit_length())
    r_width=frac+2;rw=3+tag_w+r_width+3*cw+5*pw;dn=pw+1+frac
    coverage=dict(valid=0,empty=0,missing_a=0,missing_b=0,over_capacity=0,multiple_errors=0,
        positive_effect=0,negative_effect=0,zero_effect=0,all_cross_ties=0,
        positive_half_toward_even=0,negative_half_toward_even=0,
        positive_half_away_even=0,negative_half_away_even=0,
        exact_positive_one=0,exact_negative_one=0,rank_oracle_members=0)
    inputs=[];expected=[];latencies=[];scans=0;patterns=set()
    for fi,frame in enumerate(frames):
        tag=0 if fi%13==0 else ((1<<tag_w)-1 if fi%13==1 else rng.getrandbits(tag_w))
        for i,(x,group,keep) in enumerate(frame):
            inputs.append(f'{x&((1<<w)-1):x} {group} {keep} {int(i==len(frame)-1)} '
                          f'{tag if i==0 else rng.getrandbits(tag_w):x}\n')
        all_kept=[(x,g) for x,g,keep in frame if keep];retained=all_kept[:capacity]
        n=len(retained);scans+=n*(n-1)//2
        na,nb,pairs,wins,losses,ties,u2=pooled_ranks(retained)
        coverage['rank_oracle_members']+=n
        bits=[na==0,nb==0,len(all_kept)>capacity]
        errors=sum(int(b)<<i for i,b in enumerate(bits));patterns.add(errors)
        coverage['empty']+=n==0
        for key,bit in zip(['missing_a','missing_b','over_capacity'],bits):coverage[key]+=int(bit)
        coverage['multiple_errors']+=errors.bit_count()>1
        if errors:code=pairs=wins=losses=ties=u2=0
        else:
            coverage['valid']+=1
            effect=Fraction(u2-pairs,pairs);scaled=effect*(1<<frac)
            code=round(scaled)
            assert abs(Fraction(code)-scaled)<=Fraction(1,2) and -(1<<frac)<=code<=1<<frac
            coverage['positive_effect']+=effect>0;coverage['negative_effect']+=effect<0;coverage['zero_effect']+=effect==0
            coverage['all_cross_ties']+=ties==pairs
            coverage['exact_positive_one']+=effect==1;coverage['exact_negative_one']+=effect==-1
            if scaled.denominator==2:
                direction='away' if abs(code)>abs(scaled) else 'toward'
                sign='negative' if effect<0 else 'positive'
                coverage[f'{sign}_half_{direction}_even']+=1
        processed_tail=bool(frame[-1][2] and len(all_kept)<=capacity)
        if processed_tail:
            delay=2*(n-1)+(2 if errors else dn+4)
        else:delay=1 if errors else dn+3
        latencies.append(f'{delay:x}\n')
        fields=[(u2,pw),(ties,pw),(losses,pw),(wins,pw),(pairs,pw),(n,cw),(na,cw),(nb,cw),
                (code&((1<<r_width)-1),r_width),(tag,tag_w),(errors,3)]
        packed=shift=0
        for value,width in fields:
            assert 0<=value<1<<width
            packed|=value<<shift;shift+=width
        assert shift==rw
        expected.append(f'{packed:0{(rw+3)//4}x}\n')
    return ''.join(inputs),''.join(expected),''.join(latencies),scans,coverage,sorted(patterns)


def allowed_diagnostics(stderr):
    if not stderr.strip():return True
    lines=[x.strip() for x in stderr.strip().splitlines()]
    header=['warning: Some design elements have no explicit time unit and/or',
            ': time precision. This may cause confusing timing results.',': Affected design elements are:']
    return lines[:3]==header and len(lines)==5 and all(re.fullmatch(
        r':\s+-- module fp_div_(iter|pipe) declared here: \.\./dsp_isp_library/infra/fixedpoint/rtl/recip_div\.sv:\d+',x)
        for x in lines[3:])


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],checks=[],profiles=[],
        oracle='Pooled average ranks and group rank sums; cross-ties from by-value group histograms; Fraction final RNE',
        not_run=['synthesis','place_and_route','STA','hardware','expanded_regression'],
        known_diagnostic='Only unchanged recip_div.sv missing-timescale warnings permitted.')
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    executables={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ['iverilog','vvp']}
    temporary=''
    def run(args,reject=False,version=False):
        r=subprocess.run([executables[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=15)
        okay=(r.returncode!=0 and 'mann_whitney_u_invalid_parameters' in r.stderr) if reject else r.returncode==0 and (version or allowed_diagnostics(r.stderr))
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',
                                    stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=15))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        if not all(executables.values()):raise RuntimeError('Icarus/vvp unavailable: NOT_RUN')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','mann_whitney_u','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','two_sample32','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_mann_whitney_u_') as temporary:
            path=Path(temporary)
            for w,capacity,frac,tag_w in PROFILES:
                inputs,expected,latency,scans,coverage,patterns=vectors(w,capacity,frac,tag_w)
                beats=len(inputs.splitlines());frames=len(expected.splitlines())
                for name,data in [('inputs.txt',inputs),('expected.mem',expected),('latency.mem',latency)]:
                    (path/name).write_bytes(data.encode())
                exe=path/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_mann_whitney_u',f'-Ptb_mann_whitney_u.DATA_W={w}',
                    f'-Ptb_mann_whitney_u.MAX_LEN={capacity}',f'-Ptb_mann_whitney_u.FRAC={frac}',
                    f'-Ptb_mann_whitney_u.TAG_W={tag_w}',f'-Ptb_mann_whitney_u.BEATS={beats}',
                    f'-Ptb_mann_whitney_u.FRAMES={frames}',f'-Ptb_mann_whitney_u.SCANS={scans}',
                    '-o',str(exe),'-f','files.f','sim/tb_mann_whitney_u.sv'])
                output=run(['vvp',str(exe),f'+INPUTS={(path/"inputs.txt").as_posix()}',
                    f'+EXPECTED={(path/"expected.mem").as_posix()}',f'+LATENCY={(path/"latency.mem").as_posix()}'])
                if f'PASS frames={frames} beats={beats} outputs={frames} scan_checks={scans}' not in output:
                    raise RuntimeError('finite simulation did not complete')
                report['profiles'].append(dict(DATA_W=w,MAX_LEN=capacity,FRAC=frac,TAG_W=tag_w,
                    frames=frames,beats=beats,scan_checks=scans,coverage=coverage,error_patterns=patterns,
                    inputs_sha256=hashlib.sha256(inputs.encode()).hexdigest(),expected_sha256=hashlib.sha256(expected.encode()).hexdigest(),
                    latency_sha256=hashlib.sha256(latency.encode()).hexdigest(),result=output))
                print(output,flush=True)
            for name,value in [('DATA_W',0),('DATA_W',33),('MAX_LEN',0),('MAX_LEN',129),
                               ('FRAC',-1),('FRAC',25),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','mann_whitney_u',f'-Pmann_whitney_u.{name}={value}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=str(exc);raise
    finally:
        for check in report['checks']:
            check['command']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else a for a in check['command']]
        names=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f','example/two_sample32.sv',
               'rtl/mann_whitney_u.sv','sim/tb_mann_whitney_u.sv','run_tests.py']
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names if (ROOT/name).is_file()}
        report['dependency_sha256']={DEPENDENCY:hashlib.sha256((ROOT/DEPENDENCY).read_bytes()).hexdigest()}
        report['license_sha256']={name:hashlib.sha256((ROOT.parents[2]/name).read_bytes()).hexdigest() for name in ['LICENSE','NOTICE']}
        report['tools']=executables
        (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
