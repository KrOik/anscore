#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixed finite paired-sample sorted-group oracle and bounded native Icarus."""
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
BASELINE='fcd2beef77f998da54801b91d74ce47946bee17c'
PROFILES=[(1,1,1),(2,3,3),(3,5,8),(8,7,8),(16,16,8),(32,64,32)]
SOURCES=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f',
    'example/paired16.sv','rtl/wilcoxon_signed_rank.sv','sim/tb_wilcoxon_signed_rank.sv','run_tests.py']


def ranked_groups(records):
    """Sort exact differences into magnitude groups and average ordinal ranks.

    No per-target less/equal scan, synchronous replay or RTL rank formula.
    """
    ordered=sorted((abs(x-y),x-y) for x,y in records if x!=y)
    n=len(ordered);assert n
    plus=minus=Fraction(0);tied=groups=0;position=1
    for magnitude,items in itertools.groupby(ordered,key=lambda item:item[0]):
        group=list(items);g=len(group);ordinals=list(range(position,position+g))
        average=Fraction(sum(ordinals),g)
        for _,difference in group:
            if difference>0:plus+=average
            else:minus+=average
        tied+=g if g>1 else 0;groups+=g>1;position+=g
    assert position==n+1 and plus+minus==Fraction(n*(n+1),2)
    assert tied!=1 and 0<=tied<=n
    doubled=[2*plus,2*minus,2*min(plus,minus)]
    assert all(value.denominator==1 for value in doubled)
    return tuple(int(value) for value in doubled),tied,groups,len({magnitude for magnitude,d in ordered})==1


def vectors(w,capacity,tag_w):
    rng=random.Random(0x5753524b+w*1000+capacity*7+tag_w)
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;maximum=(1<<w)-1;frames=[]
    def add(rows):frames.append(list(rows))
    def kept(rows):add((x,y,1) for x,y in rows)
    def pair(d):
        assert -maximum<=d<=maximum
        return (hi,hi-d) if d>=0 else (lo,lo-d)
    def differences(ds):kept(pair(d) for d in ds)
    add([(hi,lo,0)]);add([(lo,hi,0),(hi,lo,0)])
    differences([0]);differences([0,0]);differences([maximum]);differences([-maximum])
    differences([maximum,-maximum]);differences([-maximum,maximum])
    differences([0,maximum,0,-maximum,0]);differences([1,-1,1]);differences([-1,1,-1])
    if maximum>=3:
        for ds in [[1,1,-3],[3,-1,-1],[1,-2,3],[0,-2,2,0,3],[-1,2,-3],[1,-1,2,-2]]:
            differences(ds);differences([-d for d in ds]);differences(list(reversed(ds)))
    full=[maximum]*capacity
    differences(full);differences([-d for d in full])
    differences([maximum if i%2==0 else -maximum for i in range(capacity)])
    differences([0]*capacity)
    differences([1+(i%maximum) for i in range(capacity)])
    differences([(-1 if i%2 else 1)*(1+(i%maximum)) for i in range(capacity)])
    differences([0]*capacity+[maximum]);differences(full+[0]);differences(full+[-maximum])
    add([(lo,hi,0)]+[(x,y,1) for x,y in map(pair,full)]+[(hi,lo,0)])
    add([(lo,hi,0),(hi,lo,1),(lo,lo,0),(lo,hi,1),(hi,hi,0)])
    if w<=2:
        choices=list(itertools.product(range(lo,hi+1),repeat=2))
        for length in range(1,4):
            for rows in itertools.product(choices,repeat=length):kept(rows)
    for number in range(35):
        n=rng.randint(1,min(capacity,9));rows=[]
        for j in range(n):
            if number%5==0:rows.append(pair(rng.choice([-maximum,0,maximum])))
            elif number%5==1:rows.append(pair(rng.choice([-1,1])))
            else:rows.append((rng.randint(lo,hi),rng.randint(lo,hi)))
        kept(rows)
    for number in range(20):
        n=rng.randint(1,min(capacity+2,10))
        add((rng.randint(lo,hi),rng.randint(lo,hi),int(rng.randrange(5)!=0)) for _ in range(n))
    cw=max(1,capacity.bit_length());sw=max(1,(capacity*(capacity+1)).bit_length());rw=2+tag_w+6*cw+3*sw
    coverage={key:0 for key in ['valid','no_nonzero','overflow','both_errors','empty','retained_zero_pairs',
        'positive_only','negative_only','mixed_signs','zero_two_sided','half_integer_plus','half_integer_minus',
        'half_integer_statistic','tied_frames','tied_members','tie_groups','all_equal_magnitudes','maximum_magnitude',
        'full_capacity','full_nonzero_capacity','signed_extreme_pairs','rank_queries','pairwise_comparisons']}
    inputs=[];expected=[];latency=[];patterns=set();rows=compares=0
    for fi,frame in enumerate(frames):
        tag=(1<<tag_w)-1 if fi%11==0 else (0 if fi%11==1 else rng.getrandbits(tag_w))
        for i,(x,y,keep) in enumerate(frame):
            assert lo<=x<=hi and lo<=y<=hi
            inputs.append(f'{x&maximum:x} {y&maximum:x} {keep} {int(i==len(frame)-1)} {tag if i==0 else rng.getrandbits(tag_w):x}\n')
        all_kept=[(x,y) for x,y,keep in frame if keep];retained=all_kept[:capacity];count=len(retained)
        positive=sum(x>y for x,y in retained);negative=sum(x<y for x,y in retained);n=positive+negative;zeros=count-n
        errors=int(n==0)|(int(len(all_kept)>capacity)<<1);patterns.add(errors)
        coverage['no_nonzero']+=n==0;coverage['overflow']+=len(all_kept)>capacity
        coverage['both_errors']+=errors==3;coverage['empty']+=count==0;coverage['retained_zero_pairs']+=zeros
        coverage['signed_extreme_pairs']+=sum((x,y) in [(lo,hi),(hi,lo)] for x,y in retained)
        coverage['maximum_magnitude']+=sum(abs(x-y)==maximum for x,y in retained)
        if errors:plus=minus=stat=tied=0;delay=1
        else:
            (plus,minus,stat),tied,groups,all_equal=ranked_groups(retained);delay=2+n*(2*n+3)
            rows+=n;compares+=n*n;coverage['valid']+=1
            coverage['positive_only']+=positive>0 and negative==0;coverage['negative_only']+=negative>0 and positive==0
            coverage['mixed_signs']+=positive>0 and negative>0;coverage['zero_two_sided']+=stat==0
            coverage['half_integer_plus']+=plus%2;coverage['half_integer_minus']+=minus%2;coverage['half_integer_statistic']+=stat%2
            coverage['tied_frames']+=tied>0;coverage['tied_members']+=tied;coverage['tie_groups']+=groups
            coverage['all_equal_magnitudes']+=all_equal;coverage['full_capacity']+=count==capacity
            coverage['full_nonzero_capacity']+=n==capacity;coverage['rank_queries']+=n;coverage['pairwise_comparisons']+=n*n
            assert plus+minus==n*(n+1) and stat==min(plus,minus)
        fields=[(errors,2),(tag,tag_w),(count,cw),(n,cw),(zeros,cw),(positive,cw),(negative,cw),(tied,cw),
            (plus,sw),(minus,sw),(stat,sw)]
        word=bits=0
        for value,width in fields:assert 0<=value<1<<width;word=(word<<width)|value;bits+=width
        assert bits==rw
        expected.append(f'{word:0{(rw+3)//4}x}\n');latency.append(f'{delay:x}\n')
    assert coverage['valid'] and coverage['no_nonzero'] and coverage['overflow'] and coverage['both_errors']
    assert coverage['positive_only'] and coverage['negative_only']
    if capacity>1:assert coverage['mixed_signs'] and coverage['tied_frames'] and coverage['half_integer_statistic']
    return ''.join(inputs),''.join(expected),''.join(latency),rows,compares,coverage,sorted(patterns)


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        dependency_sha256={},oracle='Sorted exact paired differences grouped by magnitude; Fraction average of ordinal positions and sign partition',
        not_run=['synthesis','PnR','STA','hardware','expanded_regression'],timeout_retry_policy='Stop on any 20-second child timeout; no retry, fixture reduction or timeout increase.')
    path=ROOT/'verification.json'
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
    if path.is_file():
        old=json.loads(path.read_text(encoding='utf-8'))
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Prior timeout is terminal; no rerun allowed.')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):
            report['prior_failed_attempts'].append({k:old[k] for k in ['status','detail','checks','profiles','source_sha256'] if k in old})
    save()
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    exe={x:os.environ.get(x.upper()) or shutil.which(x,path=env['PATH']) for x in ['iverilog','vvp']};temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode('utf-8',errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,exit_code=None,status='TIMEOUT',stdout=decode(error.stdout),stderr=decode(error.stderr),timeout_seconds=20))
            report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(r.returncode>0 and 'wilcoxon_signed_rank_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if not reject and args[0]=='iverilog' and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        if not all(exe.values()):raise RuntimeError('NOT_RUN native Icarus/vvp required')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','wilcoxon_signed_rank','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','paired16','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_wilcoxon_') as temporary:
            folder=Path(temporary)
            for w,capacity,tag_w in PROFILES:
                inputs,expected,latency,rows,compares,coverage,patterns=vectors(w,capacity,tag_w);digests={}
                for name,data in [('inputs.txt',inputs),('expected.mem',expected),('latency.mem',latency)]:
                    (folder/name).write_bytes(data.encode());digests[name]=hashlib.sha256(data.encode()).hexdigest()
                beats=len(inputs.splitlines());frames=len(expected.splitlines());image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_wilcoxon_signed_rank',f'-Ptb_wilcoxon_signed_rank.DATA_W={w}',
                    f'-Ptb_wilcoxon_signed_rank.MAX_LEN={capacity}',f'-Ptb_wilcoxon_signed_rank.TAG_W={tag_w}',
                    f'-Ptb_wilcoxon_signed_rank.BEATS={beats}',f'-Ptb_wilcoxon_signed_rank.FRAMES={frames}',
                    f'-Ptb_wilcoxon_signed_rank.ROWS={rows}',f'-Ptb_wilcoxon_signed_rank.COMPARES={compares}',
                    '-o',str(image),'-f','files.f','sim/tb_wilcoxon_signed_rank.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                    f'+EXPECTED={(folder/"expected.mem").as_posix()}',f'+LATENCY={(folder/"latency.mem").as_posix()}'])
                match=re.search(r'^PASS frames=(\d+) beats=(\d+) outputs=(\d+) latency_checks=(\d+) max_latency=(\d+) rank_checks=(\d+) compare_checks=(\d+) held_cycles=(\d+) source_stalls=(\d+) reset_probes=(\d+) fresh_checks=(\d+)$',output,re.M)
                if not match:raise RuntimeError('missing complete finite PASS marker')
                values=list(map(int,match.groups()));assert values[:4]==[frames,beats,frames,frames]
                assert values[5:7]==[rows,compares] and values[9:]==[20,20] and values[7]>0 and values[8]>0
                report['profiles'].append(dict(DATA_W=w,MAX_LEN=capacity,TAG_W=tag_w,frames=frames,beats=beats,
                    coverage=coverage,error_patterns=patterns,vectors_sha256=digests,latency_checks=values[3],maximum_first_latency=values[4],
                    rank_checks=values[5],compare_checks=values[6],held_cycles=values[7],source_stalls=values[8],reset_probes=values[9],fresh_checks=values[10],result=output))
                print(output,flush=True)
            for name,value in [('DATA_W',0),('DATA_W',33),('MAX_LEN',0),('MAX_LEN',65),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','wilcoxon_signed_rank',f'-Pwilcoxon_signed_rank.{name}={value}','-f','files.f'],reject=True)
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
