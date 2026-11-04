#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixed finite tests; independent stability/rejection-impossibility verifier."""
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
PROFILES=[(1,1),(2,3),(3,8),(5,8),(8,16),(32,32)]

def inverse(rows):return [{v:k for k,v in enumerate(row)} for row in rows]

def stable(match,a,b):
    n=len(a)
    if sorted(match)!=list(range(n)):return False
    ar=inverse(a);br=inverse(b);owners={r:p for p,r in enumerate(match)}
    return not any(ar[p][r]<ar[p][match[p]] and br[r][p]<br[r][owners[r]] for p in range(n) for r in range(n))

def all_stable(a,b):
    solutions=[p for p in itertools.permutations(range(len(a))) if stable(p,a,b)]
    assert solutions
    ar=inverse(a);best=tuple(min((m[p] for m in solutions),key=ar[p].get) for p in range(len(a)))
    assert best in solutions
    return best,len(solutions)

def fixtures(n):
    identity=list(range(n));reverse=identity[::-1];cases=[]
    def add(a,b,edits=None):cases.append(([list(r) for r in a],[list(r) for r in b],edits or {}))
    repeated=lambda row:[list(row) for _ in range(n)]
    add(repeated(identity),repeated(identity));add(repeated(identity),repeated(reverse))
    add(repeated(reverse),repeated(identity));add(repeated(reverse),repeated(reverse))
    add([identity[p:]+identity[:p] for p in range(n)],[identity[r:]+identity[:r] for r in range(n)])
    add([identity[p:]+identity[:p] for p in range(n)],[reverse[r:]+reverse[:r] for r in range(n)])
    if n>1:
        a=[[0,1]+identity[2:],[1,0]+identity[2:]]+[[p]+[q for q in identity if q!=p] for p in range(2,n)]
        b=[[1,0]+identity[2:],[0,1]+identity[2:]]+[[r]+[q for q in identity if q!=r] for r in range(2,n)]
        add(a,b);add([[n-1-r for r in row] for row in a[::-1]],[[n-1-p for p in row] for row in b[::-1]])
    if n==2:
        perms=list(itertools.permutations(identity))
        for rows in itertools.product(perms,repeat=4):add(rows[:2],rows[2:])
    if n==3:
        perms=list(itertools.permutations(identity))
        for same in perms:
            for b in itertools.product(perms,repeat=n):add(repeated(same),b)
    rng=random.Random(20261515+n)
    for k in range(20):
        a=[];b=[]
        for p in range(n):row=identity[:];rng.shuffle(row);a.append(row)
        for r in range(n):row=identity[:];rng.shuffle(row);b.append(row)
        add(a,b)
    # Full32-bit bad IDs on both halves, geometry-independent marker errors.
    add(repeated(identity),repeated(identity),{0:{'partner':n}})
    add(repeated(identity),repeated(identity),{2*n*n-1:{'partner':0xffffffff}})
    add(repeated(identity),repeated(identity),{0:{'first':0}})
    add(repeated(identity),repeated(identity),{n*n:{'first':1}})
    add(repeated(identity),repeated(identity),{0:{'last':1},2*n*n-1:{'last':0}})
    if n>1:
        add(repeated(identity),repeated(identity),{1:{'partner':0}})
        add(repeated(identity),repeated(identity),{n*n+1:{'partner':0}})
        add(repeated(identity),repeated(identity),{1:{'partner':0},n*n:{'partner':0xffffffff,'first':1}})
    return cases

def pack(fields):
    value=0
    for v,w in fields:assert 0<=v<1<<w;value=(value<<w)|v
    return f'{value:x}'

def vectors(n,t):
    tokens=[];refs=[]
    for fi,(a,b,edits) in enumerate(fixtures(n)):
        tag=(fi*17+5)&((1<<t)-1);error=0;seen=set()
        for i,v in enumerate([x for row in a+b for x in row]):
            first=int(i==0);last=int(i==2*n*n-1);edit=edits.get(i,{})
            v=edit.get('partner',v);first=edit.get('first',first);last=edit.get('last',last)
            if i%n==0:seen=set()
            if v>=n:error|=1
            elif v in seen:error|=2
            else:seen.add(v)
            if first!=int(i==0) or last!=int(i==2*n*n-1):error|=4
            tokens.append(pack([(v,32),(first,1),(last,1),(tag if i==0 else tag^((1<<t)-1),t)]))
        refs.append(dict(a=a,b=b,error=error,tag=tag))
    return tokens,refs

def verify(actual_path,event_path,refs,n,t):
    iw=max(1,(n-1).bit_length());cw=n.bit_length();pw=(n*n).bit_length()
    fields=[('keep',1),('first',1),('last',1),('proposer',iw),('receiver',iw),('a_rank',iw),('b_rank',iw),('count',cw),('proposals',pw),('tag',t),('errors',3)]
    actual=[]
    for line in actual_path.read_text().splitlines():
        bits=int(line,16);row={}
        for k,w in reversed(fields):row[k]=bits&((1<<w)-1);bits>>=w
        assert bits==0;actual.append(row)
    events=[[] for _ in refs]
    for line in event_path.read_text().splitlines():
        frame,p,r,free,accepted,incumbent=map(int,line.split());assert 0<=frame<len(refs)
        events[frame].append((p,r,free,accepted,incumbent))
    cursor=0;rejections=proposals=exhaustive=multi=0;max_stable_count=0
    for fi,ref in enumerate(refs):
        a,b,error,tag=ref['a'],ref['b'],ref['error'],ref['tag'];outcount=1 if error else n
        rows=actual[cursor:cursor+outcount];cursor+=outcount;assert len(rows)==outcount
        if error:
            expected={k:0 for k,w in fields};expected.update(first=1,last=1,tag=tag,errors=error)
            assert rows==[expected] and not events[fi];continue
        ar=inverse(a);br=inverse(b);rejected=set();offered=set();free_receivers=set();s=0
        for p,r,free,accepted,inc in events[fi]:
            assert 0<=p<n and 0<=r<n and (p,r) not in offered
            offered.add((p,r));s+=p+1
            if free:
                assert accepted and r not in free_receivers;free_receivers.add(r)
            else:
                assert 0<=inc<n and p!=inc
                loser,winner=(inc,p) if accepted else (p,inc)
                assert br[r][winner]<br[r][loser]
                # Induction certificate, independent of any mate/free state model:
                # winner cannot have any better partner in a stable matching.
                assert all((winner,rr) in rejected for rr in a[winner][:ar[winner][r]])
                assert (loser,r) not in rejected;rejected.add((loser,r))
        count=len(events[fi]);assert len(free_receivers)==n and count==n+len(rejected) and count<=n*n
        match=tuple(row['receiver'] for row in rows);assert stable(match,a,b),(fi,match)
        for p,r in enumerate(match):
            assert (p,r) not in rejected and all((p,rr) in rejected for rr in a[p][:ar[p][r]])
            expected=dict(keep=1,first=int(p==0),last=int(p==n-1),proposer=p,receiver=r,a_rank=ar[p][r],b_rank=br[r][p],count=n,proposals=count,tag=tag,errors=0)
            assert rows[p]==expected,(fi,p,rows[p],expected)
        if n<=5:
            expected,solutions=all_stable(a,b);assert match==expected;exhaustive+=1;multi+=solutions>1;max_stable_count=max(max_stable_count,solutions)
        proposals+=count;rejections+=len(rejected)
    assert cursor==len(actual)
    return dict(proposals=proposals,certified_rejections=rejections,exhaustive_stable_set_crosschecks=exhaustive,multiple_stable_frames=multi,
                maximum_enumerated_stable_count=max_stable_count,actual_sha256=hashlib.sha256(actual_path.read_bytes()).hexdigest(),event_sha256=hashlib.sha256(event_path.read_bytes()).hexdigest())

def main():
    previous=json.loads((ROOT/'verification.json').read_text()) if (ROOT/'verification.json').exists() else {}
    if any(c.get('status')=='TIMEOUT_NOT_RUN' for c in previous.get('commands',[])):raise RuntimeError('Terminal timeout; no retry')
    prior=previous.get('prior_failed_attempts',[])
    if previous.get('commands') and 'UNIT_SIM_PASS' not in previous.get('status',[]):prior=prior+[previous]
    files=sorted(p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json')
    report=dict(baseline_commit='9716da0847c26f09f4a9b856a84fc330dfb26351',status=['NOT_RUN','HW_UNVERIFIED'],commands=[],profiles=[],prior_failed_attempts=prior,
                source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    def save():(ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8',newline='\n')
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);save();assert iv and vv
    def run(args,cwd,negative=False):
        argv=list(map(str,args))
        try:p=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as exc:
            report['commands'].append(dict(argv=argv,returncode=None,status='TIMEOUT_NOT_RUN',timeout_seconds=20));save();raise
        record=dict(argv=argv,returncode=p.returncode,stdout=p.stdout,stderr=p.stderr,timeout_seconds=20);report['commands'].append(record);save()
        if negative:assert p.returncode>0 and 'stable_preference_match_invalid_parameters__see_README' in p.stderr,record
        else:assert p.returncode==0 and not p.stderr,record
        return p.stdout
    run([iv,'-g2012','-Wall','-tnull','-s','stable_preference_match','-s','preferences8','-f','example/files.f'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_stable_') as temp:
        target=Path(temp)
        for n,t in PROFILES:
            tokens,refs=vectors(n,t);assert len(tokens)<=150001
            data=('\n'.join(tokens)+'\n').encode();(target/'input.hex').write_bytes(data)
            run([iv,'-g2012','-Wall','-s','tb_stable_preference_match',f'-Ptb_stable_preference_match.N={n}',f'-Ptb_stable_preference_match.T={t}','-o','sim.vvp',ROOT/'rtl/stable_preference_match.sv',ROOT/'sim/tb_stable_preference_match.sv'],target)
            outcount=sum(1 if r['error'] else n for r in refs)
            output=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',f'+EVENTS={target/"events.txt"}',f'+COUNT={len(tokens)}',f'+OUTCOUNT={outcount}'],target)
            cov=re.search(r'PASS stable records=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) max_latency=(\d+) proposals=(\d+)',output);assert cov,output
            checked=verify(target/'actual.hex',target/'events.txt',refs,n,t)
            assert int(cov[1])==outcount and int(cov[2])>0 and int(cov[3])>0 and int(cov[4])==(14 if n==1 else 20) and int(cov[6])==checked['proposals']
            report['profiles'].append(dict(N=n,TAG_W=t,status='PASS',frames=len(refs),input_tokens=len(tokens),output_tokens=outcount,bad_frames=sum(bool(r['error']) for r in refs),
                reset_probes=int(cov[4]),blocked_cycles=int(cov[2]),held_cycles=int(cov[3]),maximum_first_latency=int(cov[5]),output=output.strip(),input_sha256=hashlib.sha256(data).hexdigest(),**checked))
            save();print(f'PASS stable N={n} frames={len(refs)}',flush=True)
        for key,value in [('N',0),('N',33),('TAG_W',0),('TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','stable_preference_match',f'-Pstable_preference_match.{key}={value}','-f','files.f'],ROOT,True)
    for p in files:
        raw=p.read_bytes();raw.decode('utf8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
    report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=4,
                  frames=sum(p['frames'] for p in report['profiles']),input_tokens=sum(p['input_tokens'] for p in report['profiles']),output_tokens=sum(p['output_tokens'] for p in report['profiles']),
                  reset_probes=sum(p['reset_probes'] for p in report['profiles']),proposals=sum(p['proposals'] for p in report['profiles']),certified_rejections=sum(p['certified_rejections'] for p in report['profiles']),
                  exhaustive_stable_set_crosschecks=sum(p['exhaustive_stable_set_crosschecks'] for p in report['profiles']),
                  oracle='Direct bijection/stability; rejection-impossibility induction proves all better partners impossible in any stable matching; small all-bijection stable-set enumeration',not_run=['synthesis','PnR','STA','hardware','expanded regression'])
    save();print(f'PASS stable profiles={len(report["profiles"])} frames={report["frames"]} commands={len(report["commands"])}')
if __name__=='__main__':main()
