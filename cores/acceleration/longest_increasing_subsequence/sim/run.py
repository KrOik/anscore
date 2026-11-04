#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite matrix, independent index/value-DAG and exhaustive oracle."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
PROFILES=[(1,1,1),(2,3,3),(4,7,5),(8,16,8),(16,64,8),(32,256,16)]

def dag(a):
    d=[]
    for i,v in enumerate(a):d.append(1+max((d[j] for j in range(i) if a[j]<v),default=0))
    return d,max(d,default=0)

def exhaustive(a):
    best=0
    for mask in range(1<<len(a)):
        sub=[v for i,v in enumerate(a) if mask>>i&1]
        if all(x<y for x,y in zip(sub,sub[1:])):best=max(best,len(sub))
    return best

def fixtures(w,n):
    lo=-(1<<(w-1));hi=(1<<(w-1))-1
    asc=[i-n//2 for i in range(n)]
    cases=[([],{}),([lo],{}),([hi],{}),(asc,{}),(asc[::-1],{}),([0]*n,{}),
           ([lo if i%2==0 else hi for i in range(n)],{}),
           ([hi if i%2==0 else lo for i in range(n)],{}),
           (asc[1:]+asc[:1],{}),(asc,{'masks':True}),([],{'masks':True})]
    if n==3:
        for length in range(4):
            for a in itertools.product(range(lo,hi+1),repeat=length):cases.append((list(a),{}))
    if n==7:
        for length in range(6):
            for a in itertools.product([-1,0,1],repeat=length):cases.append((list(a),{}))
    rng=random.Random(20261616+w+n)
    for i in range(24):
        size=n if i%4==0 else rng.randrange(n+1)
        cases.append(([rng.randint(lo,hi) for _ in range(size)],{'masks':i%5==0}))
    cases.extend([(asc,{'bad_first':True}),(asc,{'extra_first':True}),
                  (asc+[lo],{}),(asc+[hi,lo,hi],{'bad_first':True}),
                  ([],{'bad_first':True})])
    return cases

def packed(fields):
    value=0
    for v,w in fields:
        assert 0<=v<1<<w
        value=(value<<w)|v
    return f'{value:x}'

def vectors(w,n,t):
    cw=n.bit_length();tokens=[];refs=[];exhaustive_checks=0;prefix_checks=0
    for fi,(a,opts) in enumerate(fixtures(w,n)):
        tag=(fi*19+3)&((1<<t)-1);stream=[]
        if opts.get('masks'):stream.append((0,0))
        for k,v in enumerate(a):
            stream.append((v,1))
            if opts.get('masks') and k%2==0:stream.append(((1<<(w-1))-1,0))
        if not stream:stream=[(0,0)]
        if opts.get('extra_first') and len(stream)==1:stream.append((0,0))
        error=0;prefix=[];dp=[];seen_kept=0
        for j,(v,keep) in enumerate(stream):
            first=int(j==0)
            if opts.get('bad_first') and j==0:first=0
            if opts.get('extra_first') and j==len(stream)-1:first=1
            error|=int(first!=int(j==0))
            if keep and seen_kept==n:error|=2
            if keep:seen_kept=min(n,seen_kept+1)
            pos=length=0
            if keep and not error:
                prefix.append(v);dp,length=dag(prefix);pos=dp[-1]-1;prefix_checks+=1
            tokens.append(packed([(v&((1<<w)-1),w),(keep,1),(first,1),(int(j==len(stream)-1),1),
                (tag if j==0 else tag^((1<<t)-1),t),(pos,cw),(length,cw)]))
        _,length=dag(a)
        if len(a)<=7:assert exhaustive(a)==length;exhaustive_checks+=1
        refs.append(dict(samples=a,length=length,tag=tag,error=error))
    return tokens,refs,dict(prefix_dag_checks=prefix_checks,exhaustive_crosschecks=exhaustive_checks)

def verify(path,refs,w,n,t):
    iw=max(1,(n-1).bit_length());cw=n.bit_length()
    fields=[('value',w),('index',iw),('rank',iw),('length',cw),('count',cw),
            ('keep',1),('first',1),('last',1),('tag',t),('errors',2)]
    rows=[]
    for line in path.read_text().splitlines():
        bits=int(line,16);row={}
        for key,width in reversed(fields):row[key]=bits&((1<<width)-1);bits>>=width
        assert bits==0
        if row['value']>>(w-1):row['value']-=1<<w
        rows.append(row)
    cursor=0;witnesses=0;negative=0;nontrivial=0
    for fi,ref in enumerate(refs):
        a=ref['samples'];length=ref['length'];error=ref['error'];tag=ref['tag']
        size=1 if error or not length else length
        out=rows[cursor:cursor+size];cursor+=size;assert len(out)==size
        if error or not length:
            expected={key:0 for key,width in fields};expected.update(first=1,last=1,tag=tag,errors=error)
            assert out==[expected],(fi,out,expected)
        else:
            for rank,row in enumerate(out):
                idx=row['index'];assert 0<=idx<len(a)
                expected=dict(value=a[idx],index=idx,rank=rank,length=length,count=len(a),
                    keep=1,first=int(rank==0),last=int(rank==length-1),tag=tag,errors=0)
                assert row==expected,(fi,rank,row,expected)
            assert all(x['index']<y['index'] and x['value']<y['value'] for x,y in zip(out,out[1:]))
            witnesses+=length;negative+=sum(row['value']<0 for row in out)
            nontrivial+=length<len(a)
    assert cursor==len(rows)
    return dict(output_tokens=len(rows),witness_samples=witnesses,negative_witness_values=negative,
                proper_subsequence_frames=nontrivial,actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

def main():
    report_path=ROOT/'verification.json'
    previous=json.loads(report_path.read_text()) if report_path.exists() else {}
    if any(c.get('status')=='TIMEOUT_NOT_RUN' for c in previous.get('commands',[])):
        raise RuntimeError('Terminal timeout: no retry, no fixture shrink, no limit increase')
    if 'UNIT_SIM_PASS' in previous.get('status',[]):raise RuntimeError('Qualified matrix already passed; no redundant rerun')
    prior=previous.get('prior_failed_attempts',[])
    if previous.get('commands'):prior=prior+[previous]
    files=sorted(p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json')
    report=dict(baseline_commit='83b11ea30d4762c5893cf37a8303b11706321876',
        status=['NOT_RUN','HW_UNVERIFIED'],commands=[],profiles=[],prior_failed_attempts=prior,
        source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    def save():report_path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf8',newline='\n')
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);save();assert iv and vv
    def run(argv,cwd,negative=False,version=False):
        argv=list(map(str,argv))
        try:p=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as exc:
            report['commands'].append(dict(argv=argv,returncode=None,status='TIMEOUT_NOT_RUN',timeout_seconds=20,
                stdout=(exc.stdout or b'').decode(errors='replace') if isinstance(exc.stdout,bytes) else exc.stdout or '',
                stderr=(exc.stderr or b'').decode(errors='replace') if isinstance(exc.stderr,bytes) else exc.stderr or ''))
            save();raise
        good=(p.returncode>0 and 'longest_increasing_subsequence_invalid_parameters__see_README' in p.stderr) if negative else p.returncode==0 and (version or not p.stderr)
        rec=dict(argv=argv,returncode=p.returncode,status='PASS' if good else 'FAIL',stdout=p.stdout,stderr=p.stderr,timeout_seconds=20)
        report['commands'].append(rec);save();assert good,rec
        return p.stdout
    run([iv,'-V'],ROOT,version=True)
    run([iv,'-g2012','-Wall','-tnull','-s','longest_increasing_subsequence','-f','files.f'],ROOT)
    run([iv,'-g2012','-Wall','-tnull','-s','trend64','-f','files.f','example/trend64.sv'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_lis_b16_') as tmp:
        target=Path(tmp)
        for w,n,t in PROFILES:
            tokens,refs,counts=vectors(w,n,t);assert len(tokens)<100001
            data=('\n'.join(tokens)+'\n').encode();(target/'input.hex').write_bytes(data)
            run([iv,'-g2012','-Wall','-s','tb_longest_increasing_subsequence',
                 f'-Ptb_longest_increasing_subsequence.W={w}',f'-Ptb_longest_increasing_subsequence.N={n}',
                 f'-Ptb_longest_increasing_subsequence.T={t}','-o','sim.vvp',
                 ROOT/'rtl/longest_increasing_subsequence.sv',ROOT/'sim/tb_longest_increasing_subsequence.sv'],target)
            stdout=run([vv,'sim.vvp',f'+VECTORS={target/"input.hex"}',f'+ACTUAL={target/"actual.hex"}',
                 f'+SUMMARY={target/"summary.json"}',f'+TOKENS={len(tokens)}',f'+FRAMES={len(refs)}'],target)
            assert f'PASS LIS W={w} N={n} T={t}' in stdout,stdout
            cov=json.loads((target/'summary.json').read_text());checked=verify(target/'actual.hex',refs,w,n,t)
            assert cov['inputs']==len(tokens) and cov['frames']==len(refs) and cov['outputs']==checked['output_tokens']
            assert cov['writes']==counts['prefix_dag_checks'] and cov['held']>0 and cov['blocked']>0
            assert cov['resets']==cov['fresh_recoveries']==(14 if n==1 else 20)
            assert set(ref['error'] for ref in refs)=={0,1,2,3}
            report['profiles'].append(dict(VALUE_W=w,MAX_SAMPLES=n,TAG_W=t,status='PASS',
                input_sha256=hashlib.sha256(data).hexdigest(),bad_frames=sum(bool(r['error']) for r in refs),
                maximum_valid_length=max(r['length'] for r in refs if not r['error']),output=stdout.strip(),**cov,**counts,**checked))
            save();print(f'PASS LIS W={w} N={n} frames={len(refs)}',flush=True)
        for key,value in [('VALUE_W',0),('VALUE_W',33),('MAX_SAMPLES',0),('MAX_SAMPLES',257),('TAG_W',0),('TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','longest_increasing_subsequence',
                 f'-Plongest_increasing_subsequence.{key}={value}','-f','files.f'],ROOT,negative=True)
    for p in files:
        raw=p.read_bytes();raw.decode('utf8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
    totals={key:sum(p[key] for p in report['profiles']) for key in
        ['frames','inputs','outputs','compares','writes','cycles','held','blocked','resets','fresh_recoveries',
         'prefix_dag_checks','exhaustive_crosschecks','witness_samples','negative_witness_values','proper_subsequence_frames']}
    report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],totals=totals,
        invalid_parameter_rejections=6,oracle='Index/value partial-order DAG longest paths; exhaustive small subsequences; optimal witness validation',
        not_run=['synthesis','PnR','STA','board','expanded regression'])
    save();print(f'PASS LIS profiles=6 frames={totals["frames"]} commands={len(report["commands"])}')

if __name__=='__main__':main()
