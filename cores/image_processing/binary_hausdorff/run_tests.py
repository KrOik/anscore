#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen complete-composition finite checks; native HDL children <=20 seconds."""
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
BASELINE='83b11ea30d4762c5893cf37a8303b11706321876'
PROFILES=[(1,1,1),(1,7,3),(7,1,8),(2,2,8),(3,3,8),(8,5,8),(16,12,8),(32,1,32),(1,32,32)]
INVALID=[('WIDTH',0),('WIDTH',33),('HEIGHT',0),('HEIGHT',33),('TAG_W',0),('TAG_W',33)]
DEPENDENCIES={
    '../../system/common_scaffold/image/euclidean_distance/euclidean_distance.sv':'9cea7d0c75895d9de8dea10428f9f1f496ab9536fb2dcb5732b5ee3adebe6888',
    '../../system/common_scaffold/image/euclidean_distance/README.md':'5136f4aa1443844c7cd5020e8d5cfc820d7c8aa8d05a7059ec30e7e3e464c6ae'}
SOURCES=['.gitattributes','README.md','SOURCES.md','TEST_PLAN.json','files.f','example/files.f',
    'example/shape16.sv','rtl/binary_hausdorff.sv','sim/tb_binary_hausdorff.sv','run_tests.py']
sha=lambda data:hashlib.sha256(data).hexdigest()


def directed(source,target,w):
    """Exact2D max-min; tuple min fixes target tie, strict max fixes source tie."""
    best=-1;witness=None;nearest_ties=farthest_ties=0
    for a in source:
        ax,ay=a%w,a//w
        candidates=[((ax-b%w)**2+(ay-b//w)**2,b) for b in target]
        distance,b=min(candidates)
        nearest_ties+=sum(d==distance for d,j in candidates)>1
        if distance>best:best=distance;witness=(a,b);farthest_ties=1
        elif distance==best:farthest_ties+=1
    return (best,*witness),nearest_ties,int(farthest_ties>1)


def oracle(a,b,w):
    aa=[i for i,v in enumerate(a) if v];bb=[i for i,v in enumerate(b) if v]
    if not aa or not bb:return None,{}
    ab,nt0,ft0=directed(aa,bb,w);ba,nt1,ft1=directed(bb,aa,w)
    assert ab[1] in aa and ab[2] in bb and ba[1] in bb and ba[2] in aa
    return (ab,ba),dict(nearest_ties=nt0+nt1,farthest_ties=ft0+ft1,
        ab_larger=int(ab[0]>ba[0]),ba_larger=int(ba[0]>ab[0]),equal_directed=int(ab[0]==ba[0]),
        zero_distance=int(max(ab[0],ba[0])==0),nonzero_distance=int(max(ab[0],ba[0])>0))


def pack(fields):
    word=bits=0
    for value,width in fields:
        assert 0<=value<1<<width,(value,width)
        word=(word<<width)|value;bits+=width
    return word,bits


def fixtures(w,h,t):
    n=w*h;rng=random.Random(0x48415553444f+w*100+h*17+t)
    def mask(indices):return [int(i in indices) for i in range(n)]
    first=mask({0});last=mask({n-1});all_on=[1]*n;center=mask({(h//2)*w+w//2})
    raw=[(all_on,all_on),(first,first),(first,last),(last,first),(all_on,first),(first,all_on),
        ([(x+y)%2 for y in range(h) for x in range(w)],[(x+y+1)%2 for y in range(h) for x in range(w)]),
        (mask({y*w for y in range(h)}),mask({y*w+w-1 for y in range(h)})),
        (mask({0,n-1}),center),(center,mask({i for i in [1,w,n-2] if 0<=i<n})),
        ([int(rng.randrange(3)!=0) for _ in range(n)],[int(rng.randrange(3)!=0) for _ in range(n)]),
        ([int(rng.randrange(5)==0) for _ in range(n)],[int(rng.randrange(5)==0) for _ in range(n)])]
    frames=[]
    for a,b in raw:
        a=list(a);b=list(b)
        if not any(a):a[0]=1
        if not any(b):b[-1]=1
        frames.append((a,b,0))
    for code in range(16):frames.append(([0]*n if code&1 else all_on,[0]*n if code&2 else first,code&12))
    if (w,h)==(2,2):
        for a,b in itertools.product(itertools.product((0,1),repeat=4),repeat=2):frames.append((list(a),list(b),0))
    xw=max(1,(w-1).bit_length());yw=max(1,(h-1).bit_length());cw=max(1,n.bit_length())
    dw=max(1,((w-1)**2+(h-1)**2).bit_length());ow=5+t+2*cw+3*dw+4*xw+4*yw
    inputs=[];expected=[];latencies=[];records=[];coverage=Counter();maps=replays=0
    for fi,(a,b,marker_error) in enumerate(frames):
        tag=(1<<t)-1 if fi%11==0 else (0 if fi%11==1 else rng.getrandbits(t))
        error=int(not any(a))|(int(not any(b))<<1)|marker_error
        for i,(av,bv) in enumerate(zip(a,b)):
            sof=(i==0)^bool(marker_error&4 and i==0)
            eol=(i%w==w-1)^bool(marker_error&8 and i==n-1)
            inputs.append(f'{av} {bv} {int(sof)} {int(eol)} {tag if i==0 else rng.getrandbits(t):x}\n')
        coverage[f'error_{error}']+=1
        if error:
            ab=ba=(0,0,0);symmetric=direction=0;coords=[0]*8;delay=1
        else:
            (ab,ba),stats=oracle(a,b,w);coverage.update(stats);coverage['valid']+=1
            symmetric=max(ab[0],ba[0]);direction=int(ba[0]>ab[0]);delay=4*n*(w+h+3)+2
            coords=[ab[1]%w,ab[1]//w,ab[2]%w,ab[2]//w,ba[1]%w,ba[1]//w,ba[2]%w,ba[2]//w]
            maps+=2*n;replays+=n
        fields=[(error,4),(tag,t),(sum(a),cw),(sum(b),cw),(ab[0],dw),(ba[0],dw),(symmetric,dw),(direction,1)]
        fields+=list(zip(coords,[xw,yw]*4));word,bits=pack(fields);assert bits==ow
        expected.append(f'{word:0{(ow+3)//4}x}\n');latencies.append(f'{delay:x}\n');records.append((word,delay))
    assert all(coverage[f'error_{i}']>0 for i in range(16))
    if n>1:assert all(coverage[k]>0 for k in ['ab_larger','ba_larger','equal_directed','zero_distance','nonzero_distance','farthest_ties'])
    data={'inputs.txt':''.join(inputs),'expected.mem':''.join(expected),'latency.mem':''.join(latencies)}
    return data,records,dict(coverage),maps,replays


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        qualified_commands=28,dependency_sha256=DEPENDENCIES,
        oracle='Brute-force2D point-set max-min squared distances with exact raster witness ties; every child map/nearest feature independently checked',
        compile_only=dict(WIDTH=32,HEIGHT=32,TAG_W=32,numerical_status='NOT_RUN'),
        not_run=['synthesis','PnR','STA','hardware','expanded_regression','maximum_square_numerical'],
        warning_policy='-Wall -Wno-timescale: suppress only inherited dependency time-unit warning; all other positive diagnostics fail',
        timeout_retry_policy='Every HDL compiler/simulator child <=20s; timeout terminal, no retry/shrink/increase.')
    path=ROOT/'verification.json'
    if path.is_file():
        old=json.loads(path.read_text(encoding='utf-8'))
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Prior timeout terminal; no rerun.')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):report['prior_failed_attempts'].append({k:v for k,v in old.items() if k!='prior_failed_attempts'})
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    exe={k:str(suite/'bin'/f'{k}.exe') for k in ['iverilog','vvp']};temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,exit_code=None,status='TIMEOUT',stdout=decode(error.stdout),stderr=decode(error.stderr),timeout_seconds=20))
            report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(r.returncode>0 and 'binary_hausdorff_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if args[0]=='iverilog' and not reject and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    lint=['iverilog','-g2012','-Wall','-Wno-timescale']
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text())
        assert plan['profiles_WIDTH_HEIGHT_TAG_W']==[list(p) for p in PROFILES] and plan['qualified_children']==28
        plans=[]
        for w,h,t in PROFILES:
            data,records,coverage,maps,replays=fixtures(w,h,t)
            hashes={k:sha(v.encode()) for k,v in data.items()};plans.append((w,h,t,data,records,coverage,maps,replays,hashes))
        report['frozen_fixture_plan']=[dict(WIDTH=w,HEIGHT=h,TAG_W=t,frames=len(records),paired_pixels=w*h*len(records),
            map_checks=maps,replay_checks=replays,sha256=hashes) for w,h,t,data,records,coverage,maps,replays,hashes in plans]
        report['fixture_plan_sha256']=sha(json.dumps(report['frozen_fixture_plan'],sort_keys=True).encode())
        report['reset_targets']=plan['reset_targets']
        assert sum(len(r) for w,h,t,d,r,c,m,f,ha in plans)==508
        assert sum(w*h*len(r) for w,h,t,d,r,c,m,f,ha in plans)==10096
        for name in SOURCES:
            b=(ROOT/name).read_bytes();b.decode('utf-8',errors='strict')
            assert b'\r' not in b and b.endswith(b'\n') and not b.startswith(b'\xef\xbb\xbf'),name
        for name,expected in DEPENDENCIES.items():assert sha((ROOT/name).read_bytes())==expected,name
        report['source_sha256']={name:sha((ROOT/name).read_bytes()) for name in SOURCES};save()
        if not all(Path(p).is_file() for p in exe.values()):raise RuntimeError('NOT_RUN missing native Icarus/vvp')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run([*lint,'-tnull','-s','binary_hausdorff','-f','files.f'])
        run([*lint,'-tnull','-s','shape16','-f','example/files.f'])
        run([*lint,'-tnull','-s','binary_hausdorff','-Pbinary_hausdorff.WIDTH=32','-Pbinary_hausdorff.HEIGHT=32',
            '-Pbinary_hausdorff.TAG_W=32','-f','files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_hausdorff_') as temporary:
            folder=Path(temporary)
            for w,h,t,data,records,coverage,maps,replays,hashes in plans:
                for name,value in data.items():(folder/name).write_bytes(value.encode())
                image=folder/'unit.vvp';frames=len(records)
                run([*lint,'-s','tb_binary_hausdorff',f'-Ptb_binary_hausdorff.WIDTH={w}',f'-Ptb_binary_hausdorff.HEIGHT={h}',
                    f'-Ptb_binary_hausdorff.TAG_W={t}',f'-Ptb_binary_hausdorff.FRAMES={frames}','-o',str(image),'-f','files.f','sim/tb_binary_hausdorff.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',f'+EXPECTED={(folder/"expected.mem").as_posix()}',
                    f'+LATENCY={(folder/"latency.mem").as_posix()}',f'+TRACE={(folder/"trace.txt").as_posix()}'])
                marker=re.search(r'^PASS (.+)$',output,re.M)
                if not marker:raise RuntimeError('Missing finite PASS marker')
                values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',marker.group(1))}
                assert values['frames']==values['responses']==values['latency_checks']==frames
                assert values['paired_pixels']==w*h*frames and values['main_maps']==maps and values['main_replays']==replays
                assert values['max_latency']==4*w*h*(w+h+3)+2
                assert values['reset_probes']==values['fresh_checks']==(19 if w*h==1 else 20)
                assert values['held_cycles']>0 and values['source_stalls']>0
                trace=(folder/'trace.txt').read_bytes()
                assert [(int(line.split()[0],16),int(line.split()[1])) for line in trace.decode('ascii').splitlines()]==records
                report['profiles'].append(dict(WIDTH=w,HEIGHT=h,TAG_W=t,frames=frames,paired_pixels=w*h*frames,coverage=coverage,
                    vectors_sha256=hashes,observed_trace_sha256=sha(trace),observed=values,result=output));print(output,flush=True)
            for name,value in INVALID:run(['iverilog','-g2012','-tnull','-s','binary_hausdorff',f'-Pbinary_hausdorff.{name}={value}','-f','files.f'],reject=True)
        assert len(report['checks'])==28
        assert report['source_sha256']=={name:sha((ROOT/name).read_bytes()) for name in SOURCES}
        for name,expected in DEPENDENCIES.items():assert sha((ROOT/name).read_bytes())==expected,name
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'];report['matrix_status']='PASS'
    except subprocess.TimeoutExpired as error:
        report['status']=['NOT_RUN','HW_UNVERIFIED'];report['detail']=str(error)+'; terminal timeout, stopped without retry';raise
    except (AssertionError,RuntimeError,OSError) as error:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(error);raise
    finally:
        if temporary:
            for c in report['checks']:c['command']=[v.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') for v in c['command']]
        report['source_sha256']={name:sha((ROOT/name).read_bytes()) for name in SOURCES if (ROOT/name).is_file()}
        report['license_sha256']={name:sha((ROOT.parents[2]/name).read_bytes()) for name in ['LICENSE','NOTICE']}
        report['tools']=exe;save()


if __name__=='__main__':main()
