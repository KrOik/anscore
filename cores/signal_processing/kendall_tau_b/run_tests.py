#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite Kendall oracle and native Icarus/vvp, <=20 seconds per child."""
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='9716da0847c26f09f4a9b856a84fc330dfb26351'
PROFILES=[(1,2,1),(3,3,3),(8,5,8),(16,17,8),(32,64,32),(32,256,32)]
INVALID=[('DATA_W',0),('DATA_W',33),('MAX_LEN',1),('MAX_LEN',257),('TAG_W',0),('TAG_W',33)]
SOURCES=['.gitattributes','README.md','SOURCES.md','TEST_PLAN.json','files.f','example/files.f',
    'example/association32.sv','rtl/kendall_tau_b.sv','sim/tb_kendall_tau_b.sv','run_tests.py']


def inversions(values):
    """Strict merge-sort inversion count: equality is consumed on the left."""
    if len(values)<2:return list(values),0
    middle=len(values)//2;left,a=inversions(values[:middle]);right,b=inversions(values[middle:])
    merged=[];i=j=0;count=a+b
    while i<len(left) and j<len(right):
        if left[i]<=right[j]:merged.append(left[i]);i+=1
        else:merged.append(right[j]);j+=1;count+=len(left)-i
    return merged+left[i:]+right[j:],count


def algebraic(points):
    """Count inversions after lexicographic sorting, and ties by multiplicity.

    No direct unordered-pair sign classification, RAM scan or shift-add model.
    Equal-x groups sort by y, so they cannot introduce strict inversions.
    """
    choose=lambda n:n*(n-1)//2
    pairs=choose(len(points));ordered=sorted(points)
    _,discordant=inversions([y for x,y in ordered])
    tx_all=sum(choose(n) for n in Counter(x for x,y in points).values())
    ty_all=sum(choose(n) for n in Counter(y for x,y in points).values())
    both=sum(choose(n) for n in Counter(points).values())
    tx=tx_all-both;ty=ty_all-both
    concordant=pairs-discordant-tx_all-ty_all+both
    score=concordant-discordant;radicand=(pairs-tx_all)*(pairs-ty_all)
    assert min(pairs,concordant,discordant,tx,ty,both,radicand)>=0
    assert concordant+discordant+tx+ty+both==pairs and score*score<=radicand
    return (pairs,concordant,discordant,tx,ty,both),score,radicand


def pack(fields):
    word=bits=0
    for value,width in fields:
        assert 0<=value<1<<width,(value,width)
        word=(word<<width)|value;bits+=width
    return word,bits


def fixtures(w,capacity,tag_w):
    rng=random.Random(0x4b54415542+w*1000+capacity*17+tag_w)
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;mask=(1<<w)-1;frames=[]
    def kept(points):frames.append([(x,y,1) for x,y in points])
    frames.extend([[(hi,lo,0)],[(lo,hi,0),(hi,lo,0)]])
    base=[[(lo,lo)],[(hi,hi)],[(lo,lo),(hi,hi)],[(lo,hi),(hi,lo)],
        [(lo,lo),(lo,hi)],[(lo,lo),(hi,lo)],[(lo,lo),(lo,lo)],
        [(lo,lo),(lo,hi),(hi,lo)],[(lo,lo),(lo,lo),(hi,hi)],
        [(lo,lo),(0,hi),(hi,lo)],[(lo,lo),(lo,hi),(hi,lo),(hi,hi),(lo,lo)]]
    for points in base:
        kept(points);kept(list(reversed(points)));kept([(y,x) for x,y in points])
    # Full-width full-capacity cases, including exact maximal score/radicand.
    assert capacity<=1<<w  # These frozen profiles permit distinct monotone values.
    ascending=[(lo+i,lo+i) for i in range(capacity)]
    descending=[(lo+i,hi-i) for i in range(capacity)]
    constant_x=[(lo,lo+i) for i in range(capacity)]
    constant_y=[(lo+i,hi) for i in range(capacity)]
    constant_both=[(lo,hi)]*capacity
    block_tied=[(lo+i//3,lo+(i//2)%max(1,min(5,1<<w))) for i in range(capacity)]
    for points in [ascending,descending,constant_x,constant_y,constant_both,block_tied]:kept(points)
    frames.append([(hi,lo,0)]+[(x,y,1) for x,y in ascending]+[(lo,hi,0)])
    for points in [ascending,constant_x,constant_y,constant_both]:kept(points+[(hi,lo)])
    frames.append([(lo,lo,1),(hi,lo,0),(hi,hi,1),(lo,hi,0)])
    if w==1:
        choices=list(itertools.product(range(lo,hi+1),repeat=2))
        for length in range(1,6):
            for points in itertools.product(choices,repeat=length):kept(points)
    elif capacity in [3,5]:
        choices=list(itertools.product([lo,0,hi],repeat=2))
        for length in range(1,4):
            for points in itertools.product(choices,repeat=length):kept(points)
    for number in range(35):
        n=rng.randint(1,min(capacity,16));points=[]
        for j in range(n):
            if number%4==0:points.append((rng.choice([lo,hi]),rng.choice([lo,hi])))
            elif number%4==1:points.append((lo,rng.randint(lo,hi)))
            else:points.append((rng.randint(lo,hi),rng.randint(lo,hi)))
        kept(points)
    for number in range(20):
        n=rng.randint(1,min(capacity+2,18))
        frames.append([(rng.randint(lo,hi),rng.randint(lo,hi),int(rng.randrange(5)!=0)) for _ in range(n)])
    cw=max(1,capacity.bit_length());pw=max(1,(capacity*(capacity-1)//2).bit_length())
    ow=4+tag_w+cw+9*pw
    inputs=[];expected=[];latency=[];prefix=[];records=[]
    coverage=Counter();pair_checks=mul_checks=0
    for fi,frame in enumerate(frames):
        tag=(1<<tag_w)-1 if fi%11==0 else (0 if fi%11==1 else rng.getrandbits(tag_w))
        for j,(x,y,keep) in enumerate(frame):
            assert lo<=x<=hi and lo<=y<=hi
            inputs.append(f'{x&mask:x} {y&mask:x} {keep} {int(j==len(frame)-1)} {tag if j==0 else rng.getrandbits(tag_w):x}\n')
        all_points=[(x,y) for x,y,keep in frame if keep];points=all_points[:capacity];count=len(points)
        undefined_x=len({x for x,y in points})<2;undefined_y=len({y for x,y in points})<2
        errors=int(undefined_x)|(int(undefined_y)<<1)|(int(len(all_points)>capacity)<<2)
        classes,score,radicand=algebraic(points);pair_checks+=classes[0]
        coverage[f'error_{errors}']+=1;coverage['empty']+=count==0;coverage['singleton']+=count==1
        coverage['masked_first']+=not frame[0][2];coverage['masked_tail']+=not frame[-1][2]
        coverage['full_capacity']+=count==capacity;coverage['overflow']+=len(all_points)>capacity
        for name,value in zip(['pairs','concordant','discordant','tie_x','tie_y','tie_both'],classes):
            coverage['retained_'+name]+=value
        if errors:public_classes=(0,)*6;public_score=public_radicand=0
        else:
            public_classes=classes;public_score=score;public_radicand=radicand;mul_checks+=pw
            coverage['valid']+=1;coverage['positive']+=score>0;coverage['negative']+=score<0;coverage['zero_score']+=score==0
            coverage['exact_one']+=score>0 and score*score==radicand
            coverage['exact_minus_one']+=score<0 and score*score==radicand
            coverage['tied_valid']+=any(classes[3:]);coverage['max_radicand']+=radicand==(capacity*(capacity-1)//2)**2
        if frame[-1][2] and len(all_points)<=capacity:delay=2*(count-1)+2+(pw if errors==0 else 0)
        else:delay=1+(pw if errors==0 else 0)
        fields=([(errors,3),(tag,tag_w),(count,cw)]+[(n,pw) for n in public_classes]+
            [(public_score&((1<<(pw+1))-1),pw+1),(public_radicand,2*pw)])
        word,bits=pack(fields);assert bits==ow
        preword,_=pack([(n,pw) for n in classes])
        expected.append(f'{word:0{(ow+3)//4}x}\n');prefix.append(f'{preword:0{(6*pw+3)//4}x}\n');latency.append(f'{delay:x}\n')
        records.append((word,delay))
    assert all(coverage[f'error_{i}']>0 for i in range(8))
    assert all(coverage[key]>0 for key in ['empty','singleton','masked_first','masked_tail','full_capacity','valid',
        'positive','negative','exact_one','exact_minus_one','max_radicand','retained_concordant','retained_discordant',
        'retained_tie_x','retained_tie_y','retained_tie_both'])
    if capacity>2:assert coverage['zero_score'] and coverage['tied_valid']
    data={'inputs.txt':''.join(inputs),'expected.mem':''.join(expected),'prefix.mem':''.join(prefix),'latency.mem':''.join(latency)}
    return data,records,dict(coverage),pair_checks,mul_checks


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        dependency_sha256={},qualified_commands=21,
        oracle='Lexicographic sort plus strict y merge-inversions; marginal/joint multiplicity choose2 ties; exact integer score and radicand',
        not_run=['synthesis','PnR','STA','hardware','expanded_regression'],
        timeout_retry_policy='Stop on any 20-second compiler/simulator child timeout; no retry, fixture reduction or timeout increase.')
    path=ROOT/'verification.json'
    if path.is_file():
        old=json.loads(path.read_text(encoding='utf-8'))
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Prior timeout is terminal; no rerun allowed.')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):
            report['prior_failed_attempts'].append({k:v for k,v in old.items() if k!='prior_failed_attempts'})
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    exe={name:str(suite/'bin'/f'{name}.exe') for name in ['iverilog','vvp']};temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode('utf-8',errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,exit_code=None,status='TIMEOUT',stdout=decode(error.stdout),stderr=decode(error.stderr),timeout_seconds=20))
            report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(r.returncode>0 and 'kendall_tau_b_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if not reject and args[0]=='iverilog' and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text(encoding='utf-8'))
        assert plan['profiles_DATA_W_MAX_LEN_TAG_W']==[list(p) for p in PROFILES]
        assert plan['invalid_parameters']==[list(p) for p in INVALID] and plan['qualified_children']==21
        plans=[]
        for w,capacity,tag_w in PROFILES:
            data,records,coverage,pairs,muls=fixtures(w,capacity,tag_w)
            digests={name:hashlib.sha256(value.encode()).hexdigest() for name,value in data.items()}
            plans.append((w,capacity,tag_w,data,records,coverage,pairs,muls,digests))
        report['frozen_fixture_plan']=[dict(DATA_W=w,MAX_LEN=m,TAG_W=t,frames=len(records),beats=len(data['inputs.txt'].splitlines()),
            pair_checks=pairs,multiply_checks=muls,sha256=digests) for w,m,t,data,records,coverage,pairs,muls,digests in plans]
        report['fixture_plan_sha256']=hashlib.sha256(json.dumps(report['frozen_fixture_plan'],sort_keys=True).encode()).hexdigest()
        report['reset_targets']=plan['reset_targets']
        for name in SOURCES:
            raw=(ROOT/name).read_bytes();raw.decode('utf-8',errors='strict')
            assert b'\r' not in raw and raw.endswith(b'\n') and not raw.startswith(b'\xef\xbb\xbf'),name
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES};save()
        if not all(Path(name).is_file() for name in exe.values()):raise RuntimeError('NOT_RUN native Icarus/vvp required')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','kendall_tau_b','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','association32','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_kendall_tau_b_') as temporary:
            folder=Path(temporary)
            for w,capacity,tag_w,data,records,coverage,pairs,muls,digests in plans:
                for name,value in data.items():(folder/name).write_bytes(value.encode())
                frames=len(records);beats=len(data['inputs.txt'].splitlines());image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_kendall_tau_b',f'-Ptb_kendall_tau_b.DATA_W={w}',
                    f'-Ptb_kendall_tau_b.MAX_LEN={capacity}',f'-Ptb_kendall_tau_b.TAG_W={tag_w}',
                    f'-Ptb_kendall_tau_b.FRAMES={frames}',f'-Ptb_kendall_tau_b.BEATS={beats}',
                    f'-Ptb_kendall_tau_b.PAIR_CHECKS={pairs}',f'-Ptb_kendall_tau_b.MUL_CHECKS={muls}',
                    '-o',str(image),'-f','files.f','sim/tb_kendall_tau_b.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                    f'+EXPECTED={(folder/"expected.mem").as_posix()}',f'+PREFIX={(folder/"prefix.mem").as_posix()}',
                    f'+LATENCY={(folder/"latency.mem").as_posix()}',f'+TRACE={(folder/"trace.txt").as_posix()}'])
                match=re.search(r'^PASS frames=(\d+) beats=(\d+) outputs=(\d+) latency_checks=(\d+) max_latency=(\d+) main_pairs=(\d+) main_mul=(\d+) scan_checks=(\d+) multiply_checks=(\d+) held_cycles=(\d+) source_stalls=(\d+) reset_probes=(\d+) fresh_checks=(\d+)$',output,re.M)
                if not match:raise RuntimeError('missing complete finite PASS marker')
                values=list(map(int,match.groups()));assert values[:4]==[frames,beats,frames,frames]
                assert values[5:7]==[pairs,muls] and values[-2:]==[20,20] and values[9]>0 and values[10]>0
                trace=(folder/'trace.txt').read_bytes();lines=trace.decode('ascii').splitlines();assert len(lines)==frames
                assert [(int(line.split()[0],16),int(line.split()[1])) for line in lines]==records
                report['profiles'].append(dict(DATA_W=w,MAX_LEN=capacity,TAG_W=tag_w,frames=frames,beats=beats,
                    coverage=coverage,error_patterns=list(range(8)),vectors_sha256=digests,observed_trace_sha256=hashlib.sha256(trace).hexdigest(),
                    latency_checks=values[3],maximum_first_latency=values[4],main_pair_checks=pairs,main_multiply_checks=muls,
                    scan_checks=values[7],multiply_checks=values[8],held_cycles=values[9],source_stalls=values[10],
                    reset_probes=20,fresh_checks=20,result=output))
                print(output,flush=True)
            for name,value in INVALID:
                run(['iverilog','-g2012','-tnull','-s','kendall_tau_b',f'-Pkendall_tau_b.{name}={value}','-f','files.f'],reject=True)
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
