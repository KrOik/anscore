#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite exact Fraction oracle; <=20 seconds per native HDL child."""
from collections import Counter
from fractions import Fraction
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='83b11ea30d4762c5893cf37a8303b11706321876'
PROFILES=[(1,2,1),(3,3,3),(8,4,8),(12,5,8),(16,6,32),(16,2,32)]
INVALID=[('DATA_W',0),('DATA_W',17),('MAX_LEN',1),('MAX_LEN',7),('TAG_W',0),('TAG_W',33)]
SOURCES=['.gitattributes','README.md','SOURCES.md','TEST_PLAN.json','files.f','example/files.f',
    'example/interpolate4.sv','rtl/rational_polynomial_interpolate.sv',
    'sim/tb_rational_polynomial_interpolate.sv','run_tests.py']
RESET_TARGETS=['idle','masked_first_active','partial_retained','FINALIZE','PAIR_A_den','PAIR_B_den',
    'PAIR_FACTOR_den','MUL_den_first','MUL_den_middle','MUL_den_last','PAIR_NEXT_den','DEN_FINISH',
    'TERM_READ','TERM_SETUP','Q_READ','Q_FACTOR_identity','MUL_query_zero_first','Q_NEXT','PAIR_A_num',
    'TERM_ADD','COMMIT','held_valid_blocked_source','overflow_collection',
    'held_duplicate_overflow_blocked_source','held_empty_blocked_source',
    'held_duplicate_blocked_source','held_overflow_blocked_source']


def exact_value(points,query):
    """Solve a Vandermonde linear system with exact rational row elimination.

    This recovers monomial coefficients, then uses Horner evaluation. It does
    not reproduce the RTL's cofactor products or serial multiplication schedule.
    """
    n=len(points)
    rows=[[Fraction(x)**k for k in range(n)]+[Fraction(y)] for x,y in points]
    for col in range(n):
        pivot=next(row for row in range(col,n) if rows[row][col])
        rows[col],rows[pivot]=rows[pivot],rows[col]
        divisor=rows[col][col];rows[col]=[v/divisor for v in rows[col]]
        for row in range(n):
            if row!=col:
                multiplier=rows[row][col]
                rows[row]=[a-multiplier*b for a,b in zip(rows[row],rows[col])]
    value=Fraction(0)
    for row in reversed(rows):value=value*query+row[-1]
    xs=sorted(x for x,y in points);denominator=1
    for right in range(n):
        for left in range(right):denominator*=xs[right]-xs[left]
    numerator=value*denominator
    assert numerator.denominator==1 and denominator>0
    # Independent interpolation constraints on the recovered coefficients.
    for x,y in points:
        assert sum(rows[k][-1]*x**k for k in range(n))==y
    return int(numerator),denominator,value


def pack(fields):
    word=bits=0
    for value,width in fields:
        assert 0<=value<1<<width,(value,width)
        word=(word<<width)|value;bits+=width
    return word,bits


def fixtures(w,capacity,tag_w):
    rng=random.Random(0x504f4c59494e54+w*1000+capacity*17+tag_w)
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;mask=(1<<w)-1;frames=[]
    def add(points,q,kind='directed'):frames.append(([(x,y,1) for x,y in points],q,kind))
    frames.extend([([(hi,lo,0)],lo,'empty'), ([(lo,hi,0),(hi,lo,0)],hi,'empty')])
    for y in [lo,0,hi]:
        for q in [lo,0,hi]:add([(lo,y)],q,'singleton')
    for points in [[(lo,lo),(hi,hi)],[(hi,lo),(lo,hi)],[(lo,lo),(lo,hi)],[(lo,hi),(lo,hi)]]:
        for q in [lo,0,hi]:add(points,q)
    if w>=3:
        assert exact_value([(0,0),(2,1)],1)[:2]==(1,2)
        add([(0,0),(2,1)],1,'known_half')
    if w>=4 and capacity>=3:
        assert exact_value([(0,0),(1,1),(2,4)],3)[:2]==(18,2)
        add([(0,0),(1,1),(2,4)],3,'known_quadratic')
    # Deliberately nonuniform, unsorted signed coordinates where domain permits.
    choices={2:[lo,hi],3:[lo,-1,hi],4:[lo,-3,0,hi],5:[lo,-7,-1,3,hi],6:[lo,-7,-1,0,9,hi]}
    xs=choices[capacity];assert len(set(xs))==capacity
    full=list(zip(xs,[lo if i%2==0 else hi for i in range(capacity)]))
    for points in [full,list(reversed(full)),[(x,x) for x in xs],[(x,hi) for x in xs]]:
        for q in sorted(set([lo,0,hi]+xs)):add(points,q,'full')
    small=full[:min(4,capacity)]
    for points in itertools.permutations(small):
        for q in sorted(set([lo,0,hi])):add(points,q,'permutation')
    for q in xs:add(full,q,'node_match')
    frames.append(([(hi,lo,0)]+[(x,y,1) for x,y in full]+[(lo,hi,0)],0,'masked_boundaries'))
    frames.append(([(lo,hi,0),(lo,lo,1),(hi,lo,0),(hi,hi,1),(lo,lo,0)],hi,'masks'))
    add(full+[(xs[0],hi)],lo,'overflow_excess_duplicate_only')
    add([(xs[0],lo)]*capacity+[(xs[-1],hi)],hi,'duplicate_overflow')
    add([(xs[0],lo),(xs[0],hi)],0,'duplicate')
    add([(xs[0],lo)]+[(xs[-1],hi)]*capacity,0,'prefix_duplicate_overflow')
    # Explicit polynomial orders, only when y and q are representable.
    for degree in range(1,capacity):
        points=[(x,x**degree) for x in range(capacity)]
        if all(lo<=x<=hi and lo<=y<=hi for x,y in points):
            for q in [lo,hi,0]:add(list(reversed(points)),q,'degree_'+str(degree))
    if w==1:
        options=list(itertools.product(range(lo,hi+1),repeat=2))
        for n in range(1,4):
            for points in itertools.product(options,repeat=n):
                for q in range(lo,hi+1):add(points,q,'exhaustive_w1_len1_3')
    elif w==3:
        options=list(itertools.product([lo,0,hi],repeat=2))
        for n in range(1,3):
            for points in itertools.product(options,repeat=n):
                for q in [lo,0,hi]:add(points,q,'exhaustive_w3_len1_2')
    for number in range(40):
        n=rng.randint(1,capacity);coordinates=rng.sample(range(lo,hi+1),n)
        points=[(x,rng.choice([lo,hi]) if number%4==0 else rng.randint(lo,hi)) for x in coordinates]
        if number%7==0 and n>1:points[-1]=(points[0][0],points[-1][1])
        q=points[number%n][0] if number%3==0 else rng.randint(lo,hi)
        add(points,q,'seeded')
    for number in range(20):
        frame=[(rng.randint(lo,hi),rng.randint(lo,hi),int(rng.randrange(5)!=0))
            for _ in range(rng.randint(1,capacity+2))]
        frames.append((frame,rng.randint(lo,hi),'seeded_masks'))
    cw=max(1,capacity.bit_length());pmax=capacity*(capacity-1)//2
    db=max(1,w*pmax);nb=w*(pmax+1)+(capacity-1).bit_length()+1
    ow=3+tag_w+cw+w+nb+db
    inputs=[];expected=[];latency=[];records=[];coverage=Counter();pair_factors=query_factors=mul_steps=0
    permutations={}
    for fi,(frame,q,kind) in enumerate(frames):
        tag=(1<<tag_w)-1 if fi%11==0 else (0 if fi%11==1 else rng.getrandbits(tag_w))
        for j,(x,y,keep) in enumerate(frame):
            assert lo<=x<=hi and lo<=y<=hi and lo<=q<=hi
            beat_q=q if j==0 else rng.randint(lo,hi);beat_tag=tag if j==0 else rng.getrandbits(tag_w)
            inputs.append(f'{x&mask:x} {y&mask:x} {beat_q&mask:x} {keep} {int(j==len(frame)-1)} {beat_tag:x}\n')
        all_points=[(x,y) for x,y,keep in frame if keep];points=all_points[:capacity];n=len(points);p=n*(n-1)//2
        errors=int(n==0)|(int(len(set(x for x,y in points))<n)<<1)|(int(len(all_points)>capacity)<<2)
        numerator=denominator=0;pair_factors+=p
        coverage['kind_'+kind]+=1;coverage['error_'+str(errors)]+=1
        for name,condition in [('empty',n==0),('singleton',n==1),('masked_first',not frame[0][2]),
            ('masked_tail',not frame[-1][2]),('full_capacity',n==capacity),('overflow',len(all_points)>capacity)]:
            coverage[name]+=condition
        if errors==0:
            numerator,denominator,value=exact_value(points,q)
            pair_factors+=n*p;query_factors+=n*n
            for name,condition in [('valid',True),('positive',numerator>0),('negative',numerator<0),('zero',numerator==0),
                ('fractional',value.denominator>1),('unreduced',denominator>value.denominator),
                ('node_match',q in [x for x,y in points]),('extrapolation',q<min(x for x,y in points) or q>max(x for x,y in points)),
                ('unsorted',any(points[i][0]>points[i+1][0] for i in range(n-1))),
                ('nonuniform',n>=3 and len({b-a for a,b in zip(sorted(x for x,y in points),sorted(x for x,y in points)[1:])})>1)]:
                coverage[name]+=condition
            key=(tuple(sorted(points)),q)
            if kind=='permutation':
                assert permutations.setdefault(key,(numerator,denominator))==(numerator,denominator)
            assert -(1<<(nb-1))<=numerator<1<<(nb-1) and denominator<1<<db
        delay=1 if n==0 else (2+p*(w+4) if errors else 3+p*(w+4)+n*(3+n*(w+3)+p*(w+4)))
        fields=[(errors,3),(tag,tag_w),(n,cw),(q&mask,w),(numerator&((1<<nb)-1),nb),(denominator,db)]
        word,bits=pack(fields);assert bits==ow
        expected.append(f'{word:0{(ow+3)//4}x}\n');latency.append(f'{delay:x}\n');records.append((word,delay))
    mul_steps=w*(pair_factors+query_factors)
    assert all(coverage['error_'+str(i)] for i in [0,1,2,4,6])
    assert not any(coverage['error_'+str(i)] for i in [3,5,7])
    assert all(coverage[key] for key in ['valid','negative','zero','node_match','masked_first','masked_tail'])
    if w>1:assert coverage['positive'] and coverage['fractional'] and coverage['extrapolation'] and coverage['unreduced']
    if capacity>2:assert coverage['nonuniform'] and coverage['unsorted']
    data={'inputs.txt':''.join(inputs),'expected.mem':''.join(expected),'latency.mem':''.join(latency)}
    return data,records,dict(coverage),pair_factors,query_factors,mul_steps


def frozen_plans():
    plans=[]
    for w,m,t in PROFILES:
        data,records,coverage,pairs,queries,muls=fixtures(w,m,t)
        digests={name:hashlib.sha256(value.encode()).hexdigest() for name,value in data.items()}
        frozen=dict(DATA_W=w,MAX_LEN=m,TAG_W=t,frames=len(records),beats=len(data['inputs.txt'].splitlines()),
            pair_factors=pairs,query_factors=queries,multiply_steps=muls,sha256=digests)
        plans.append((w,m,t,data,records,coverage,pairs,queries,muls,digests,frozen))
    return plans


def main():
    plans=frozen_plans();frozen=[p[-1] for p in plans]
    if sys.argv[1:]==['--freeze']:
        plan=dict(baseline=BASELINE,profiles_DATA_W_MAX_LEN_TAG_W=PROFILES,invalid_parameters=INVALID,
            qualified_children=21,timeout_seconds=20,timeout_terminal=True,frozen_fixture_plan=frozen,
            reset_targets=RESET_TARGETS,reset_probes_per_profile=27,
            reset_aliases='DATA_W=1: denominator multiplier first/middle/last are the same single step; all 27 targets still executed.',
            fixture_scope='W1 complete x/y Cartesian length1..3 at both queries; W3 x/y in {min,0,max}, length1..2 at all three queries; directed full/permuted/nonuniform/degree/overflow/mask;40 seeded+20 masked frames/profile.',
            forbidden=['synthesis','PnR','STA','hardware','expanded_regression'])
        (ROOT/'TEST_PLAN.json').write_bytes((json.dumps(plan,indent=2)+'\n').encode())
        print(json.dumps(frozen,indent=2));return
    assert not sys.argv[1:]
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        dependency_sha256={},qualified_commands=21,
        oracle='Fraction Vandermonde Gaussian elimination plus Horner; sorted positive pair-gap denominator; exact interpolation constraints and permutation encoding invariance.',
        not_run=['synthesis','PnR','STA','hardware','expanded_regression'],
        timeout_retry_policy='Stop on any 20-second compiler/simulator child timeout; no retry, fixture reduction or timeout increase.')
    path=ROOT/'verification.json'
    if path.is_file():
        old=json.loads(path.read_text(encoding='utf-8'))
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Prior timeout is terminal; no rerun allowed.')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):
            report['prior_failed_attempts'].append({k:v for k,v in old.items() if k!='prior_failed_attempts'})
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    exe={name:str(suite/'bin'/f'{name}.exe') for name in ['iverilog','vvp']};temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode('utf-8',errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,exit_code=None,status='TIMEOUT',stdout=decode(error.stdout),stderr=decode(error.stderr),timeout_seconds=20))
            report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(r.returncode>0 and 'rational_polynomial_interpolate_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if not reject and args[0]=='iverilog' and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text(encoding='utf-8'))
        assert plan['profiles_DATA_W_MAX_LEN_TAG_W']==[list(p) for p in PROFILES]
        assert plan['invalid_parameters']==[list(p) for p in INVALID] and plan['qualified_children']==21
        assert plan['frozen_fixture_plan']==frozen and plan['reset_targets']==RESET_TARGETS
        report['frozen_fixture_plan']=frozen
        report['fixture_plan_sha256']=hashlib.sha256(json.dumps(frozen,sort_keys=True).encode()).hexdigest()
        report['reset_targets']=RESET_TARGETS
        for name in SOURCES:
            raw=(ROOT/name).read_bytes();raw.decode('utf-8',errors='strict')
            assert b'\r' not in raw and raw.endswith(b'\n') and not raw.startswith(b'\xef\xbb\xbf'),name
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES};save()
        if not all(Path(name).is_file() for name in exe.values()):raise RuntimeError('NOT_RUN native Icarus/vvp required')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','rational_polynomial_interpolate','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','interpolate4','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_rational_poly_') as temporary:
            folder=Path(temporary)
            for w,m,t,data,records,coverage,pairs,queries,muls,digests,unused in plans:
                for name,value in data.items():(folder/name).write_bytes(value.encode())
                frames=len(records);beats=len(data['inputs.txt'].splitlines());image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_rational_polynomial_interpolate',f'-Ptb_rational_polynomial_interpolate.DATA_W={w}',
                    f'-Ptb_rational_polynomial_interpolate.MAX_LEN={m}',f'-Ptb_rational_polynomial_interpolate.TAG_W={t}',
                    f'-Ptb_rational_polynomial_interpolate.FRAMES={frames}',f'-Ptb_rational_polynomial_interpolate.BEATS={beats}',
                    f'-Ptb_rational_polynomial_interpolate.PAIR_FACTORS={pairs}',f'-Ptb_rational_polynomial_interpolate.QUERY_FACTORS={queries}',
                    f'-Ptb_rational_polynomial_interpolate.MUL_STEPS={muls}',
                    '-o',str(image),'-f','files.f','sim/tb_rational_polynomial_interpolate.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                    f'+EXPECTED={(folder/"expected.mem").as_posix()}',f'+LATENCY={(folder/"latency.mem").as_posix()}',f'+TRACE={(folder/"trace.txt").as_posix()}'])
                match=re.search(r'^PASS frames=(\d+) beats=(\d+) outputs=(\d+) latency_checks=(\d+) max_latency=(\d+) pair_factors=(\d+) query_factors=(\d+) mul_steps=(\d+) read_checks=(\d+) multiply_checks=(\d+) held_cycles=(\d+) source_stalls=(\d+) ii1_checks=(\d+) reset_probes=(\d+) fresh_checks=(\d+)$',output,re.M)
                if not match:raise RuntimeError('missing complete finite PASS marker')
                values=list(map(int,match.groups()));assert values[:4]==[frames,beats,frames,frames]
                assert values[5:8]==[pairs,queries,muls] and values[-2:]==[27,27]
                assert values[10]>0 and values[11]>0 and values[12]==beats-frames
                trace=(folder/'trace.txt').read_bytes();lines=trace.decode('ascii').splitlines();assert len(lines)==frames
                assert [(int(line.split()[0],16),int(line.split()[1])) for line in lines]==records
                report['profiles'].append(dict(DATA_W=w,MAX_LEN=m,TAG_W=t,frames=frames,beats=beats,coverage=coverage,
                    reachable_error_patterns=[0,1,2,4,6],unreachable_error_patterns=[3,5,7],vectors_sha256=digests,
                    observed_trace_sha256=hashlib.sha256(trace).hexdigest(),latency_checks=values[3],maximum_first_latency=values[4],
                    main_pair_factors=pairs,main_query_factors=queries,main_multiply_steps=muls,read_checks=values[8],
                    multiply_checks=values[9],held_cycles=values[10],source_stalls=values[11],ii1_checks=values[12],
                    reset_probes=27,fresh_checks=27,result=output))
                print(output,flush=True)
            for name,value in INVALID:
                run(['iverilog','-g2012','-tnull','-s','rational_polynomial_interpolate',f'-Prational_polynomial_interpolate.{name}={value}','-f','files.f'],reject=True)
        assert len(report['checks'])==21
        assert report['source_sha256']=={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES}
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
