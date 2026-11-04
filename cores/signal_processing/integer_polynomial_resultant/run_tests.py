#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite exact resultant oracle; native HDL children limited to20s."""
from collections import Counter
from fractions import Fraction
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import random
import re
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='c4be2839103480e23976f16f8a41d06fd93057c8'
PROFILES=[(1,1,1),(3,1,3),(4,2,8),(8,2,8),(8,3,8),(16,3,32)]
INVALID=[('DATA_W',0),('DATA_W',17),('MAX_DEG',0),('MAX_DEG',4),('TAG_W',0),('TAG_W',33)]
SOURCES=['.gitattributes','README.md','SOURCES.md','TEST_PLAN.json','files.f','example/files.f',
    'example/resultant_quadratic.sv','rtl/integer_polynomial_resultant.sv',
    'sim/tb_integer_polynomial_resultant.sv','run_tests.py']
RESET_TARGETS=['idle','partial_collection','saturated_overlength_collection','FINALIZE','INITIALIZE',
    'TERM_START','FACTOR_READ_present','FACTOR_SETUP_present','MUL_first','MUL_middle','MUL_last',
    'FACTOR_NEXT','TERM_ADD','NEXT_PERM_swap','NEXT_PERM_carry','NEXT_PERM_terminal','COMMIT',
    'held_nonzero','held_common_root','held_bad_degree','held_short_length','held_zero_lead',
    'structural_zero_factor','negative_factor','odd_heap_index','even_heap_index',
    'held_saturated_long_length','held_constant_constant','held_dimension_one']


def resultant(a,b):
    """Exact Euclidean polynomial remainder recursion in Q[x], ascending order.

    Res(f,g)=(-1)^(m*n)*lc(g)^(m-degree(r))*Res(g,r), r=f mod g.
    This does not construct a Sylvester matrix or enumerate permutations.
    """
    f=list(map(Fraction,a));g=list(map(Fraction,b));m=len(f)-1;n=len(g)-1
    assert f[-1] and g[-1]
    if n==0:return g[0]**m
    remainder=f[:]
    while len(remainder)>=len(g):
        scale=remainder[-1]/g[-1];shift=len(remainder)-len(g)
        for j,value in enumerate(g):remainder[j+shift]-=scale*value
        while remainder and remainder[-1]==0:remainder.pop()
    if not remainder:return Fraction(0)
    return (-1)**(m*n)*g[-1]**(m-len(remainder)+1)*resultant(g,remainder)


def elimination_crosscheck(a,b):
    """Secondary rational Gaussian elimination of Sylvester rows, no term sum."""
    m=len(a)-1;n=len(b)-1;size=m+n;matrix=[]
    for coefficients,degree,rows in [(a,m,n),(b,n,m)]:
        for shift in range(rows):matrix.append([Fraction(0)]*shift+list(map(Fraction,reversed(coefficients)))+[Fraction(0)]*(size-shift-degree-1))
    determinant=Fraction(1)
    for col in range(size):
        pivot=next((i for i in range(col,size) if matrix[i][col]),None)
        if pivot is None:return Fraction(0)
        if pivot!=col:matrix[col],matrix[pivot]=matrix[pivot],matrix[col];determinant=-determinant
        divisor=matrix[col][col];determinant*=divisor
        for row in range(col+1,size):
            multiplier=matrix[row][col]/divisor
            for j in range(col+1,size):matrix[row][j]-=multiplier*matrix[col][j]
    return determinant


def pack(fields):
    word=bits=0
    for value,width in fields:
        assert 0<=value<1<<width,(value,width)
        word=(word<<width)|value;bits+=width
    return word,bits


def fixtures(w,d,tag_w):
    rng=random.Random(0x52534c54414e54+w*1000+d*17+tag_w)
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;mask=(1<<w)-1;frames=[]
    def add(a,b,kind='directed',da=None,db=None,length=None):
        da=len(a)-1 if da is None else da;db=len(b)-1 if db is None else db
        length=max(da,db)+1 if length is None else length;assert length>=1
        beats=[(a[i] if i<len(a) else rng.randint(lo,hi),b[i] if i<len(b) else rng.randint(lo,hi)) for i in range(length)]
        frames.append((beats,da,db,kind))
    add([0,-1],[-1,-1],'known_linear_one')
    assert resultant([0,-1],[-1,-1])==1
    small=[lo,hi] if w==1 else [-1,0,1]
    polynomials=[list(values) for degree in [0,1] for values in itertools.product(small,repeat=degree+1)]
    for a,b in itertools.product(polynomials,repeat=2):add(a,b,'exhaustive_small_degree0_1')
    for da in range(d+1):
        for db in range(d+1):
            if da==db==3:continue
            add([lo if i%2==0 else hi for i in range(da)]+[lo],
                [hi if i%2==0 else lo for i in range(db)]+[lo],'all_degree_pairs_extrema')
            add([0]*da+[-1],[lo]+[0]*(db-1)+[-1] if db else [lo],'sparse_degree_pairs')
    if d>=2:
        quadratics=[[a,b,1] for a,b in itertools.product([-1,0,1],repeat=2)]
        for a,b in itertools.product(quadratics,repeat=2):add(a,b,'monic_quadratic_grid')
        assert resultant([1,0,1],[-1,0,1])==4
        add([1,0,1],[-1,0,1],'known_quadratic_four')
        add([-1,0,1],[1,-2,1],'shared_root_quadratic')
    if d==3:
        cubics=[([1,0,0,1],[-1,0,0,1]),([-1,0,0,1],[1,0,0,1]),
            ([-1,1,-1,1],[-1,0,0,1]),([lo,hi,lo,hi],[hi,lo,hi,lo]),
            ([0,0,0,lo],[hi,0,0,hi]),([lo,0,hi,1],[hi,1,0,lo])]
        for _ in range(2):cubics.append(([rng.randint(lo,hi) for _ in range(3)]+[lo],
            [rng.randint(lo,hi) for _ in range(3)]+[hi]))
        assert len(cubics)==8 and resultant(*cubics[0])==-8 and resultant(*cubics[1])==8
        for a,b in cubics:add(a,b,'frozen_cubic_pair')
    for degree in range(d+1):
        add([-1]*degree+[0],[-1],'zero_lead_a');add([-1],[-1]*degree+[0],'zero_lead_b')
    add([0],[0],'zero_constants')
    add([-1],[-1],'bad_degree',da=7,db=7,length=1)
    add([0],[0],'bad_degree_precedence',da=7,db=0,length=d+4)
    add([-1],[-1],'short_length',da=1,db=1,length=1)
    add([-1,-1],[-1,-1],'long_length',length=d+5)
    add([0,-1],[-1,-1],'long_zero_lead_precedence',da=0,db=0,length=3)
    for number in range(24):
        da=rng.randrange(min(d,2)+1);db=rng.randrange(min(d,2)+1)
        a=[rng.randint(lo,hi) for _ in range(da+1)];b=[rng.randint(lo,hi) for _ in range(db+1)]
        a[-1]=rng.choice([lo,hi]) if hi else lo;b[-1]=rng.choice([lo,hi]) if hi else lo
        add(a,b,'seeded_degree_at_most2')
    cw=max(1,(d+2).bit_length());nb=2*d*w+(math.factorial(2*d)-1).bit_length()+1;ow=9+tag_w+cw+nb
    inputs=[];expected=[];bounds=[];records=[];coverage=Counter();terms=factors=0
    for fi,(beats,da,db,kind) in enumerate(frames):
        tag=(1<<tag_w)-1 if fi%11==0 else (0 if fi%11==1 else rng.getrandbits(tag_w))
        for i,(a,b) in enumerate(beats):
            assert lo<=a<=hi and lo<=b<=hi
            beat_da=da if i==0 else rng.getrandbits(3);beat_db=db if i==0 else rng.getrandbits(3)
            inputs.append(f'{a&mask:x} {b&mask:x} {beat_da:x} {beat_db:x} {int(i==len(beats)-1)} {tag if i==0 else tag^((1<<tag_w)-1):x}\n')
        count=min(len(beats),d+2);value=0
        if da>d or db>d:status=1
        elif len(beats)!=max(da,db)+1:status=2
        elif beats[da][0]==0 or beats[db][1]==0:status=3
        else:
            status=0;a=[beats[i][0] for i in range(da+1)];b=[beats[i][1] for i in range(db+1)]
            exact=resultant(a,b);assert exact.denominator==1 and exact==elimination_crosscheck(a,b)
            assert exact==(-1)**(da*db)*resultant(b,a);value=int(exact)
            assert -(1<<(nb-1))<=value<1<<(nb-1)
            size=da+db
            if size:terms+=math.factorial(size);factors+=size*math.factorial(size)
            for name,condition in [('valid',True),('positive',value>0),('negative',value<0),('common_root',value==0),
                ('constant_constant',size==0),('dimension_one',size==1),('nontrivial_dimension',size>=3)]:coverage[name]+=condition
            coverage[f'degrees_{da}_{db}']+=1
        coverage['kind_'+kind]+=1;coverage['status_'+str(status)]+=1
        coverage['count_saturated']+=len(beats)>=d+2
        size=da+db
        bound=1 if status or size==0 else 3+math.factorial(size)*(size*(w+3)+size+2)
        word,bits=pack([(status,2),(int(status==0 and value==0),1),(tag,tag_w),(count,cw),(da,3),(db,3),(value&((1<<nb)-1),nb)])
        assert bits==ow
        expected.append(f'{word:0{(ow+3)//4}x}\n');bounds.append(f'{bound:x}\n');records.append((word,bound))
    assert all(coverage['status_'+str(i)] for i in range(4))
    assert all(coverage[key] for key in ['positive','negative','common_root','constant_constant','dimension_one','count_saturated'])
    assert all(coverage[f'degrees_{a}_{b}'] for a in range(d+1) for b in range(d+1))
    if d==3:assert coverage['kind_frozen_cubic_pair']==8
    data={'inputs.txt':''.join(inputs),'expected.mem':''.join(expected),'bounds.mem':''.join(bounds)}
    return data,records,dict(coverage),terms,factors,w*factors


def frozen_plans():
    plans=[]
    for w,d,t in PROFILES:
        data,records,coverage,terms,factors,muls=fixtures(w,d,t)
        digests={name:hashlib.sha256(value.encode()).hexdigest() for name,value in data.items()}
        frozen=dict(DATA_W=w,MAX_DEG=d,TAG_W=t,frames=len(records),beats=len(data['inputs.txt'].splitlines()),
            determinant_terms=terms,coefficient_factors=factors,multiply_steps=muls,sha256=digests)
        plans.append((w,d,t,data,records,coverage,terms,factors,muls,digests,frozen))
    return plans


def main():
    plans=frozen_plans();frozen=[p[-1] for p in plans]
    if sys.argv[1:]==['--freeze']:
        plan=dict(baseline=BASELINE,profiles_DATA_W_MAX_DEG_TAG_W=PROFILES,invalid_parameters=INVALID,
            qualified_children=21,timeout_seconds=20,timeout_terminal=True,frozen_fixture_plan=frozen,
            reset_targets=RESET_TARGETS,reset_probes_per_profile=29,
            reset_aliases=['W1 multiplier first/middle/last alias one step.',
                'MAX_DEG1 has no structural off-band zeros: target22 uses a present zero coefficient.',
                'MAX_DEG1 dimension<=2 has no even nonterminal Heap index: target25 uses terminal index2.'],
            queued_source='After29reset/fresh pairs, one held linear result is retired with a preoffered constant/constant frame; acceptance and exact second result checked.',
            fixture_scope='Complete degree0/1 coefficient Cartesian over {-1,0,1} (W1: {-1,0}); monic quadratic {-1,0,1} grids when D>=2; all degree pairs signedextrema/sparse; exactly8 cubic/cubic pairs whenD3;24seeded degree<=2;allstatuses and length saturation.',
            forbidden=['synthesis','PnR','STA','hardware','expanded_regression'])
        (ROOT/'TEST_PLAN.json').write_bytes((json.dumps(plan,indent=2)+'\n').encode());print(json.dumps(frozen,indent=2));return
    assert not sys.argv[1:]
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        dependency_sha256={},qualified_commands=21,
        oracle='Fraction polynomial Euclidean remainder resultant recursion; Gaussian Sylvester elimination crosscheck; swap-sign identity. No permutation/Heap/shift-add model.',
        not_run=['synthesis','PnR','STA','hardware','expanded_regression'],
        timeout_retry_policy='Stop on any20-second compiler/simulator child timeout; no retry, fixture reduction or timeout increase.')
    path=ROOT/'verification.json'
    if path.is_file():
        old=json.loads(path.read_text(encoding='utf-8'))
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Prior timeout is terminal; no rerun allowed.')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):report['prior_failed_attempts'].append({k:v for k,v in old.items() if k!='prior_failed_attempts'})
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
        okay=(r.returncode>0 and 'integer_polynomial_resultant_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if not reject and args[0]=='iverilog' and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text(encoding='utf-8'))
        assert plan['profiles_DATA_W_MAX_DEG_TAG_W']==[list(p) for p in PROFILES]
        assert plan['invalid_parameters']==[list(p) for p in INVALID] and plan['qualified_children']==21
        assert plan['frozen_fixture_plan']==frozen and plan['reset_targets']==RESET_TARGETS
        report['frozen_fixture_plan']=frozen
        report['fixture_plan_sha256']=hashlib.sha256(json.dumps(frozen,sort_keys=True).encode()).hexdigest();report['reset_targets']=RESET_TARGETS
        for name in SOURCES:
            raw=(ROOT/name).read_bytes();raw.decode('utf-8',errors='strict')
            assert b'\r' not in raw and raw.endswith(b'\n') and not raw.startswith(b'\xef\xbb\xbf'),name
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES};save()
        if not all(Path(name).is_file() for name in exe.values()):raise RuntimeError('NOT_RUN native Icarus/vvp required')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','integer_polynomial_resultant','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','resultant_quadratic','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_resultant_') as temporary:
            folder=Path(temporary)
            for w,d,t,data,records,coverage,terms,factors,muls,digests,unused in plans:
                for name,value in data.items():(folder/name).write_bytes(value.encode())
                frames=len(records);beats=len(data['inputs.txt'].splitlines());image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_integer_polynomial_resultant',f'-Ptb_integer_polynomial_resultant.DATA_W={w}',
                    f'-Ptb_integer_polynomial_resultant.MAX_DEG={d}',f'-Ptb_integer_polynomial_resultant.TAG_W={t}',
                    f'-Ptb_integer_polynomial_resultant.FRAMES={frames}',f'-Ptb_integer_polynomial_resultant.BEATS={beats}',
                    f'-Ptb_integer_polynomial_resultant.TERMS={terms}',f'-Ptb_integer_polynomial_resultant.FACTORS={factors}',
                    f'-Ptb_integer_polynomial_resultant.MUL_STEPS={muls}',
                    '-o',str(image),'-f','files.f','sim/tb_integer_polynomial_resultant.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                    f'+EXPECTED={(folder/"expected.mem").as_posix()}',f'+BOUNDS={(folder/"bounds.mem").as_posix()}',f'+TRACE={(folder/"trace.txt").as_posix()}'])
                match=re.search(r'^PASS frames=(\d+) beats=(\d+) outputs=(\d+) bounds=(\d+) max_latency=(\d+) terms=(\d+) factors=(\d+) mul_steps=(\d+) read_checks=(\d+) multiply_checks=(\d+) held_cycles=(\d+) source_stalls=(\d+) ii1_checks=(\d+) reset_probes=(\d+) fresh_checks=(\d+) queued_checks=(\d+)$',output,re.M)
                if not match:raise RuntimeError('missing complete finite PASS marker')
                values=list(map(int,match.groups()));assert values[:4]==[frames,beats,frames,frames]
                assert values[5:8]==[terms,factors,muls] and values[-3:]==[29,29,1]
                assert values[10]>0 and values[11]>0 and values[12]==beats-frames
                trace=(folder/'trace.txt').read_bytes();lines=trace.decode('ascii').splitlines();assert len(lines)==frames
                observed=[(int(line.split()[0],16),int(line.split()[1])) for line in lines]
                assert all(word==want and 1<=delay<=bound for (word,delay),(want,bound) in zip(observed,records))
                report['profiles'].append(dict(DATA_W=w,MAX_DEG=d,TAG_W=t,frames=frames,beats=beats,coverage=coverage,
                    vectors_sha256=digests,observed_trace_sha256=hashlib.sha256(trace).hexdigest(),bound_checks=values[3],maximum_first_latency=values[4],
                    main_determinant_terms=terms,main_coefficient_factors=factors,main_multiply_steps=muls,read_checks=values[8],
                    multiply_checks=values[9],held_cycles=values[10],source_stalls=values[11],ii1_checks=values[12],
                    reset_probes=29,fresh_checks=29,queued_checks=1,result=output))
                print(output,flush=True)
            for name,value in INVALID:
                run(['iverilog','-g2012','-tnull','-s','integer_polynomial_resultant',f'-Pinteger_polynomial_resultant.{name}={value}','-f','files.f'],reject=True)
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
        report['not_run_children']=21-len(report['checks'])
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES if (ROOT/name).is_file()}
        report['license_sha256']={name:hashlib.sha256((ROOT.parents[2]/name).read_bytes()).hexdigest() for name in ['LICENSE','NOTICE']}
        report['tools']=exe;save()


if __name__=='__main__':main()
