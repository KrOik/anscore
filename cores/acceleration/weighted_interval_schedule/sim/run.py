#!/usr/bin/env python3
"""Frozen finite matrix: endpoint-event oracle plus exhaustive conflict subsets."""
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
ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
PROFILES=[(1,2,1,1),(3,2,2,3),(7,5,4,8),(16,16,16,8),(17,9,9,16),(64,32,32,32)]

def better(a,b):return a[0]>b[0] or (a[0]==b[0] and a[1]<b[1])

def events(items):
    # Longest feasible path through coordinate events, rather than DP by items.
    ends={};starts={}
    for i,(a,b,w) in enumerate(items):
        ends.setdefault(b,[]).append((a,w,i));starts.setdefault(a,[]).append(i)
    best=(0,0);at_start={}
    for x in sorted(set(starts)|set(ends)):
        for a,w,i in ends.get(x,[]):
            v,m=at_start[a];candidate=(v+w,m|(1<<i))
            if better(candidate,best):best=candidate
        if x in starts:at_start[x]=best
    return best

def subsets(items):
    k=len(items);conflicts=[]
    for i,(a,b,w) in enumerate(items):
        conflicts.append(sum(1<<j for j,(c,d,v) in enumerate(items) if i!=j and a<d and c<b))
    feasible=bytearray(1<<k);feasible[0]=1;sums=[0]*(1<<k);best=(0,0)
    for mask in range(1,1<<k):
        bit=mask&-mask;i=bit.bit_length()-1;rest=mask^bit
        if feasible[rest] and not(rest&conflicts[i]):
            feasible[mask]=1;sums[mask]=sums[rest]+items[i][2]
            candidate=(sums[mask],mask)
            if better(candidate,best):best=candidate
    return best

def fixtures(n,e,w):
    lo=-(1<<(e-1));hi=(1<<(e-1))-1;wm=(1<<w)-1
    frames=[]
    def add(items):frames.append([(a,b,v,1) for a,b,v in items] or [(hi,lo,wm,0)])
    add([]);add([(lo,hi,0)]);add([(lo,hi,wm)])
    add([(lo,hi,wm)]*n);add([(lo,hi,0)]*n)
    add([(lo+i,lo+i+1,wm) for i in range(min(n,hi-lo))])
    add(list(reversed([(lo+i,lo+i+1,wm) for i in range(min(n,hi-lo))])))
    add([(lo,hi,wm if i%2 else 0) for i in range(n)])
    if n>=3 and hi-lo>=3:
        # Weight5 middle loses to two weight4 outside intervals when W>=3.
        add([(lo,lo+2,min(wm,4)),(lo+1,lo+3,min(wm,5)),(lo+2,hi,min(wm,4))])
    add([(lo,hi,wm)]*(n+2));add([(0,0,1)]);add([(hi,lo,1)])
    add([(lo,hi,wm)]*n+[(hi,lo,1),(0,0,0)])
    frames.append([(hi,lo,wm,0),(lo,hi,wm,1),(hi,lo,wm,0)])
    add([(lo,hi,wm if i==n-1 else 0) for i in range(n)])
    if n==3 and e==2:
        domain=[(a,b,v) for a in range(lo,hi+1) for b in range(a+1,hi+1) for v in (0,1)]
        for length in range(4):
            for items in itertools.product(domain,repeat=length):add(items)
    rng=random.Random(20261414+n+e*7+w)
    for j in range(20):
        k=rng.randrange(n+1);items=[]
        for i in range(k):
            a=rng.randint(lo,hi-1);b=rng.randint(a+1,hi)
            items.append((a,b,rng.randrange(wm+1)))
        rng.shuffle(items);add(items)
    if n==64:
        for k in range(1,9):
            add([(rng.randrange(-30,0),rng.randrange(1,31),rng.randrange(wm+1)) for i in range(k)])
    return frames

def pack(fields):
    value=0
    for v,width in fields:value=(value<<width)|(v&((1<<width)-1))
    return f'{value:x}'

def vectors(n,e,w,t):
    tokens=[];refs=[];crosschecks=0
    for j,raw in enumerate(fixtures(n,e,w)):
        items=[];error=0;tag=(j*13+3)&((1<<t)-1)
        for i,(a,b,v,keep) in enumerate(raw):
            if keep:
                if len(items)>=n:error|=1
                if a>=b:error|=2
                items.append((a,b,v))
            tokens.append(pack([(a,e),(b,e),(v,w),(keep,1),(int(i==len(raw)-1),1),(tag if i==0 else tag^((1<<t)-1),t)]))
        optimum=(0,0)
        if not error:
            optimum=events(items)
            if len(items)<=17:assert optimum==subsets(items);crosschecks+=1
        refs.append(dict(items=items,error=error,tag=tag,optimum=optimum))
    return tokens,refs,crosschecks

def verify(path,refs,n,e,w,t):
    iw=max(1,(n-1).bit_length());cw=n.bit_length();sw=w+(n-1).bit_length()
    fields=[('keep',1),('first',1),('last',1),('index',iw),('start',e),('end',e),('weight',w),
            ('selected',1),('count',cw),('total',sw),('selection',n),('tag',t),('error',2)]
    actual=[]
    for line in path.read_text().splitlines():
        bits=int(line,16);row={}
        for key,width in reversed(fields):row[key]=bits&((1<<width)-1);bits>>=width
        assert bits==0;actual.append(row)
    cursor=0;commits=reads=0
    for ref in refs:
        items=ref['items'];k=len(items);error=ref['error'];out=k if k and not error else 1
        if k and not error:commits+=k;reads+=k*k
        for i in range(out):
            expected={key:0 for key,width in fields};expected.update(first=int(i==0),last=int(i==out-1),tag=ref['tag'],error=error)
            if k and not error:
                a,b,v=items[i];total,mask=ref['optimum']
                expected.update(keep=1,index=i,start=a&((1<<e)-1),end=b&((1<<e)-1),weight=v,
                                selected=(mask>>i)&1,count=k,total=total,selection=mask)
            assert cursor<len(actual) and actual[cursor]==expected,(ref,i,actual[cursor] if cursor<len(actual) else None,expected)
            cursor+=1
    assert cursor==len(actual)
    return dict(expected_commits=commits,expected_reads_per_scan_kind=reads,actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

def main():
    previous=json.loads((ROOT/'verification.json').read_text()) if (ROOT/'verification.json').exists() else {}
    if any(c.get('status')=='TIMEOUT_NOT_RUN' for c in previous.get('commands',[])):
        raise RuntimeError('Terminal timeout for fixed plan; no retry allowed')
    prior=previous.get('prior_failed_attempts',[])
    if previous.get('commands') and 'UNIT_SIM_PASS' not in previous.get('status',[]):prior=prior+[previous]
    files=sorted(p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json')
    report=dict(baseline_commit='01b92bf2f8d81fff097f1965de61edf81604ae4f',status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],prior_failed_attempts=prior,
                source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    def save():(ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(args,cwd,negative=False):
        command=[str(a) for a in args]
        try:p=subprocess.run(command,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired:
            report['commands'].append(dict(argv=command,returncode=None,status='TIMEOUT_NOT_RUN',timeout_seconds=20));save();raise
        record=dict(argv=command,returncode=p.returncode,stdout=p.stdout,stderr=p.stderr,timeout_seconds=20)
        report['commands'].append(record);save()
        if negative:assert p.returncode>0 and 'weighted_interval_schedule_invalid_parameters__see_README' in p.stderr,record
        else:assert p.returncode==0 and not p.stderr,record
        return p.stdout
    run([iv,'-g2012','-Wall','-tnull','-s','weighted_interval_schedule','-s','schedule16','-f','files.f','examples/schedule16.sv'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_interval_') as tmp:
        target=Path(tmp)
        for n,e,w,t in PROFILES:
            tokens,refs,crosschecks=vectors(n,e,w,t);assert len(tokens)<=25001
            data=('\n'.join(tokens)+'\n').encode();(target/'input.hex').write_bytes(data)
            run([iv,'-g2012','-Wall','-s','tb_weighted_interval_schedule',f'-Ptb_weighted_interval_schedule.N={n}',f'-Ptb_weighted_interval_schedule.E={e}',
                 f'-Ptb_weighted_interval_schedule.W={w}',f'-Ptb_weighted_interval_schedule.T={t}','-o','sim.vvp',ROOT/'rtl/weighted_interval_schedule.sv',ROOT/'sim/tb_weighted_interval_schedule.sv'],target)
            outcount=sum(len(r['items']) if r['items'] and not r['error'] else 1 for r in refs)
            output=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',f'+COUNT={len(tokens)}',f'+OUTCOUNT={outcount}'],target)
            cov=re.search(r'PASS interval records=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) max_latency=(\d+) work=(\d+) select_reads=(\d+) pred_reads=(\d+)',output);assert cov,output
            assert int(cov[1])==outcount and int(cov[2])>0 and int(cov[3])>0 and int(cov[4])==(14 if n==1 else 18)
            checked=verify(target/'actual.hex',refs,n,e,w,t)
            assert int(cov[6])==checked['expected_commits'] and int(cov[7])==int(cov[8])==checked['expected_reads_per_scan_kind']
            report['profiles'].append(dict(MAX_ITEMS=n,ENDPOINT_W=e,WEIGHT_W=w,TAG_W=t,status='PASS',frames=len(refs),input_tokens=len(tokens),output_tokens=outcount,
                bad_frames=sum(bool(r['error']) for r in refs),subset_crosschecks=crosschecks,reset_probes=int(cov[4]),blocked_cycles=int(cov[2]),held_cycles=int(cov[3]),
                max_first_latency=int(cov[5]),output=output.strip(),input_sha256=hashlib.sha256(data).hexdigest(),**checked))
            save();print(f'PASS interval N={n} frames={len(refs)}',flush=True)
        invalid=[('MAX_ITEMS',0),('MAX_ITEMS',65),('ENDPOINT_W',1),('ENDPOINT_W',33),('WEIGHT_W',0),('WEIGHT_W',33),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:run([iv,'-g2012','-tnull','-s','weighted_interval_schedule',f'-Pweighted_interval_schedule.{key}={value}','-f','files.f'],ROOT,True)
    for p in files:
        raw=p.read_bytes();raw.decode('utf-8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
    report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=8,
                  frames=sum(p['frames'] for p in report['profiles']),input_tokens=sum(p['input_tokens'] for p in report['profiles']),
                  output_tokens=sum(p['output_tokens'] for p in report['profiles']),subset_crosschecks=sum(p['subset_crosschecks'] for p in report['profiles']),
                  reset_probes=sum(p['reset_probes'] for p in report['profiles']),oracle='Independent endpoint-event sweep and exhaustive conflict-subset enumeration at K<=17',
                  not_run=['synthesis','PnR','STA','hardware','expanded regression'])
    save();print(f'PASS interval profiles={len(report["profiles"])} frames={report["frames"]} commands={len(report["commands"])}')
if __name__=='__main__':main()
