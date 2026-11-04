#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite NGTDM checks; only Python stdlib and native Icarus, <=20s/child."""
from fractions import Fraction
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
PROFILES=[(1,1,1,1,1),(1,7,4,2,3),(7,1,8,3,8),(2,2,2,2,8),(3,3,1,1,8),
    (8,5,8,3,8),(32,24,12,4,8),(128,1,16,4,32),(1,128,16,4,32)]
SOURCES=['.gitattributes','README.md','SOURCES.md','TEST_PLAN.md','files.f','example/files.f',
    'example/neighborhood32.sv','rtl/streaming_ngtdm.sv','sim/tb_streaming_ngtdm.sv','run_tests.py']
TARGETS=['clear_start','clear_middle','partial_capture','line_read','window','absolute_difference','scale',
    'histogram_read','histogram_write','output_read','held_normal_blocked_source','held_error_blocked_source',
    'initial_row_warmup','bottom_right_window','repeated_bin_update','held_second_bin_blocked_source',
    'malformed_partial_capture','later_line_read']
NEGATIVE=[('WIDTH',0),('WIDTH',129),('HEIGHT',0),('HEIGHT',129),('PIXEL_W',0),('PIXEL_W',17),
    ('GRAY_W',0),('GRAY_W',5),('GRAY_W',3),('TAG_W',0),('TAG_W',33)]
PARAMS=['WIDTH','HEIGHT','PIXEL_W','GRAY_W','TAG_W']
sha=lambda data:hashlib.sha256(data).hexdigest()


def direct_oracle(image,w,h,levels):
    """Direct coordinate sets and exact rational means; no streaming recurrence."""
    counts=[0]*levels;differences=[Fraction(0) for _ in range(levels)]
    work=dict(centers=w*h,updates=0,neighbors=0,fractional=0,nonzero=0)
    neighbor_counts={str(k):0 for k in [0,1,2,3,5,8]}
    for y in range(h):
        for x in range(w):
            neighbors=[image[ny*w+nx] for ny in range(max(0,y-1),min(h,y+2))
                for nx in range(max(0,x-1),min(w,x+2)) if (nx,ny)!=(x,y)]
            k=len(neighbors);neighbor_counts[str(k)]+=1;work['neighbors']+=k
            if not neighbors:continue
            g=image[y*w+x];difference=abs(Fraction(g)-Fraction(sum(neighbors),k))
            counts[g]+=1;differences[g]+=difference;work['updates']+=1
            work['fractional']+=difference.denominator!=1;work['nonzero']+=difference!=0
    scaled=[v*120 for v in differences]
    assert all(v.denominator==1 for v in scaled)
    assert sum(counts)==(w*h if w*h>1 else 0)
    return counts,[int(v) for v in scaled],work,neighbor_counts


def fixtures(profile):
    w,h,p,g,t=profile;n=w*h;levels=1<<g;maximum=levels-1
    rng=random.Random(0x4e4754444d+sum(v*(i+17) for i,v in enumerate(profile)))
    patterns=[
        [0]*n,[maximum]*n,[1]*n,[maximum//2]*n,
        [(x+y)%2*maximum for y in range(h) for x in range(w)],
        [(x+y+1)%2*maximum for y in range(h) for x in range(w)],
        [x%levels for y in range(h) for x in range(w)],
        [y%levels for y in range(h) for x in range(w)],
        [(x+3*y)%levels for y in range(h) for x in range(w)],
        [maximum if i==0 else 0 for i in range(n)],
        [maximum if i==n-1 else 0 for i in range(n)],
        [0 if i==0 else maximum for i in range(n)],
        [maximum if i==(h//2)*w+w//2 else 0 for i in range(n)],
        [(x%2)*maximum for y in range(h) for x in range(w)],
        [rng.randrange(levels) for _ in range(n)],[rng.randrange(levels) for _ in range(n)]]
    frames=[(a,0) for a in patterns]
    frames.extend((patterns[4+i],i+1) for i in range(4))
    if (w,h,g)==(2,2,2):frames.extend((list(a),0) for a in itertools.product(range(4),repeat=4))
    if (w,h,g)==(3,3,1):frames.extend((list(a),0) for a in itertools.product(range(2),repeat=9))
    inputs=[];expected=[];coverage=dict(good=0,sof_error=0,eol_error=0,combined_error=0)
    total_work={k:0 for k in ['centers','updates','neighbors','fractional','nonzero']}
    total_neighbor_counts={str(k):0 for k in [0,1,2,3,5,8]}
    delay=7*w+12+4*(h>=2)*(1+(w>=2))-2*(n==1)
    count_checks=sum_checks=0
    for fi,(image,bad) in enumerate(frames):
        counts,sums,work,neighbors=direct_oracle(image,w,h,levels)
        for k,v in work.items():total_work[k]+=v
        for k,v in neighbors.items():total_neighbor_counts[k]+=v
        error=0;tag=(1<<t)-1 if fi%11==0 else (0 if fi%11==1 else rng.getrandbits(t))
        for i,gray in enumerate(image):
            sof=i==0;eol=i%w==w-1
            if bad in [1,3] and i==0:sof=not sof
            if bad in [2,3] and i==0:eol=not eol
            if bad==4 and i==n-1:sof=not sof;eol=not eol
            error|=int(sof!=(i==0))|(int(eol!=(i%w==w-1))<<1)
            pixel=(gray<<(p-g))|rng.getrandbits(p-g)
            inputs.append(f'{pixel:x} {int(sof)} {int(eol)} {tag if i==0 else rng.getrandbits(t):x}\n')
        coverage['good']+=error==0;coverage['sof_error']+=bool(error&1)
        coverage['eol_error']+=bool(error&2);coverage['combined_error']+=error==3
        for gray,(count,difference) in enumerate(zip(counts,sums)):
            expected.append(f'{gray} {0 if error else count} {0 if error else difference} {error} {tag:x} {delay}\n')
            count_checks+=1;sum_checks+=1
    assert all(coverage.values())
    reset_ids=[i for i in range(18) if not ((i==1 and levels<4) or (n==1 and i in [2,7,8,14,16]))]
    stats=dict(frames=len(frames),pixels=len(frames)*n,outputs=len(frames)*levels,
        latency_checks=len(frames),maximum_first_latency=delay,work=total_work,neighbor_counts=total_neighbor_counts,
        count_checks=count_checks,scaled_rational_checks=sum_checks,coverage=coverage,reset_ids=reset_ids)
    return ''.join(inputs),''.join(expected),stats


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        frozen_profiles=PROFILES,reset_targets=TARGETS,qualified_commands=33,dependency_sha256={},
        oracle='Direct clipped coordinate sets, exact Python Fraction neighborhood means; dense counts and 120-scaled differences',
        compile_only=dict(WIDTH=128,HEIGHT=128,PIXEL_W=16,GRAY_W=4,TAG_W=32,numerical_status='NOT_RUN'),
        not_run=['synthesis','PnR','STA','hardware','expanded_regression','maximum_square_numerical'],
        timeout_retry_policy='Every compiler/simulator child <=20s; timeout terminal, no retry/shrink/increase.')
    path=ROOT/'verification.json'
    if path.is_file():
        old=json.loads(path.read_text(encoding='utf-8'))
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Prior timeout is terminal; no rerun.')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):
            report['prior_failed_attempts'].append({k:old[k] for k in ['checks','source_sha256','detail','fixture_plan_sha256'] if k in old})
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy();env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    exe={k:str(suite/'bin'/f'{k}.exe') for k in ['iverilog','vvp']};temporary=''
    def run(args,reject=False,version=False):
        try:result=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,exit_code=None,status='TIMEOUT',stdout=decode(error.stdout),
                stderr=decode(error.stderr),timeout_seconds=20))
            report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(result.returncode>0 and 'streaming_ngtdm_invalid_parameters' in result.stderr) if reject else result.returncode==0 and not result.stderr
        if args[0]=='iverilog' and not version and not reject:okay=okay and not result.stdout
        report['checks'].append(dict(command=args,exit_code=result.returncode,status='PASS' if okay else 'FAIL',
            stdout=result.stdout.strip(),stderr=result.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()
    try:
        plans=[]
        for profile in PROFILES:
            inputs,expected,stats=fixtures(profile)
            hashes={name:sha(data.encode()) for name,data in [('inputs.txt',inputs),('expected.txt',expected)]}
            plans.append((profile,inputs,expected,stats,hashes))
        report['frozen_fixture_plan']=[dict(parameters=dict(zip(PARAMS,p)),**s,sha256=h) for p,i,e,s,h in plans]
        report['fixture_plan_sha256']=sha(json.dumps(report['frozen_fixture_plan'],sort_keys=True).encode())
        assert sum(s['frames'] for p,i,e,s,h in plans)==948
        assert sum(s['pixels'] for p,i,e,s,h in plans)==27472
        assert sum(s['outputs'] for p,i,e,s,h in plans)==3568
        for name in SOURCES:
            data=(ROOT/name).read_bytes();data.decode('utf-8',errors='strict')
            assert data.endswith(b'\n') and b'\r' not in data and not data.startswith(b'\xef\xbb\xbf'),name
        report['source_sha256']={name:sha((ROOT/name).read_bytes()) for name in SOURCES};save()
        if not all(Path(p).is_file() for p in exe.values()):raise RuntimeError('NOT_RUN missing native Icarus/vvp')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','streaming_ngtdm','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','neighborhood32','-f','example/files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','streaming_ngtdm',
            *[f'-Pstreaming_ngtdm.{k}={v}' for k,v in report['compile_only'].items() if isinstance(v,int)],'-f','files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_ngtdm_') as temporary:
            folder=Path(temporary)
            for profile,inputs,expected,stats,hashes in plans:
                (folder/'inputs.txt').write_bytes(inputs.encode());(folder/'expected.txt').write_bytes(expected.encode())
                image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_streaming_ngtdm',
                    *[f'-Ptb_streaming_ngtdm.{k}={v}' for k,v in zip(PARAMS,profile)],
                    f'-Ptb_streaming_ngtdm.FRAMES={stats["frames"]}','-o',str(image),'-f','files.f','sim/tb_streaming_ngtdm.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',f'+EXPECTED={(folder/"expected.txt").as_posix()}'])
                marker=re.search(r'^PASS (.+)$',output,re.M)
                if not marker:raise RuntimeError('Missing finite PASS marker')
                values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',marker.group(1))}
                for key in ['frames','pixels','outputs','latency_checks']:assert values[key]==stats[key],key
                assert values['max_latency']==stats['maximum_first_latency']
                for key,value in stats['work'].items():assert values[key]==value,key
                assert values['reset_probes']==values['fresh_checks']==len(stats['reset_ids'])
                assert values['held_cycles']>0 and values['source_stalls']>0
                report['profiles'].append(dict(parameters=dict(zip(PARAMS,profile)),**stats,
                    vectors_sha256=hashes,observed=values,result=output));print(output,flush=True)
            for index,(name,value) in enumerate(NEGATIVE):
                args=['iverilog','-g2012','-tnull','-s','streaming_ngtdm',f'-Pstreaming_ngtdm.{name}={value}']
                if index==8:args.append('-Pstreaming_ngtdm.PIXEL_W=2')
                run([*args,'-f','files.f'],reject=True)
        assert len(report['checks'])==33
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'];report['matrix_status']='PASS'
    except subprocess.TimeoutExpired as error:
        report['status']=['NOT_RUN','HW_UNVERIFIED'];report['detail']=str(error)+'; terminal timeout, stopped without retry';raise
    except (AssertionError,RuntimeError,OSError) as error:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(error);raise
    finally:
        for check in report['checks']:
            if temporary:check['command']=[v.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') for v in check['command']]
        report['source_sha256']={name:sha((ROOT/name).read_bytes()) for name in SOURCES if (ROOT/name).is_file()}
        report['license_sha256']={name:sha((ROOT.parents[2]/name).read_bytes()) for name in ['LICENSE','NOTICE']}
        report['tools']=exe;save()


if __name__=='__main__':main()
