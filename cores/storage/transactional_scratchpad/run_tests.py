#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite matrix; unbounded epoch oracle independent of invalidation RTL."""
import collections
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
REPO=ROOT.parents[2]
PROFILES=[(1,1,1,1),(2,3,5,3),(3,8,8,8),(4,16,32,8),(8,64,32,32)]
INVALID=[(k,v) for k,hi in [('CONTEXTS',8),('DEPTH',64),('DATA_W',32),('TAG_W',32)] for v in [0,hi+1]]

def fixtures(c,n,w,t):
    commands=[];mask=(1<<w)-1
    def add(op,tx=0,addr=0,data=0):commands.append((op,tx,addr,data,(len(commands)*37+11)&((1<<t)-1)))
    add(6,255,0xffffffff,mask)
    add(7,255,0xffffffff,mask);add(1,c,n);add(1,0,n);add(1,0);add(2,0);add(3,0);add(4,0)
    for tx in range(c):
        add(0,tx,0xffffffff,mask);add(0,tx);add(2,tx,tx%n,(tx+1)&mask);add(2,tx,tx%n,mask);add(1,tx,tx%n);add(5,255,tx%n)
    for tx in range(c):add(3,tx,0xffffffff);add(5,255,tx%n)
    add(0)
    for a in range(n):add(2,0,a,(a*17+3)&mask);add(1,0,a)
    add(3)
    for a in range(n):add(5,255,a)
    add(0);add(1,0,0);add(1,0,0);add(4);add(0);add(3);add(4)
    if c>1:
        # Same-value conflict, including failed READ/STAGE and active-BEGIN precedence.
        add(6);add(0);add(1);add(0,1);add(2,1,0,0);add(3,1);add(1);add(2);add(0);add(4)
        # ABA writes still invalidate the original read epoch.
        add(6);add(0);add(1);add(0,1);add(2,1,0,mask);add(3,1);add(0,1);add(2,1,0,0);add(3,1);add(3)
        # Private forward/read-after-stage does not add a read dependency.
        add(6);add(0);add(2,0,0,mask);add(1);add(0,1);add(2,1,0,0);add(3,1);add(3);add(5)
        if n>1:
            # Write skew: one commit invalidates the other's prior read.
            add(6);add(0);add(0,1);add(1,0,0);add(1,1,1);add(2,0,1,mask);add(2,1,0,mask);add(3,0);add(3,1)
            # Disjoint dependencies, staged-write replacement, and neighbor preservation.
            add(6);add(0);add(1,0,0);add(0,1);add(1,1,1);add(2,1,1,mask);add(3,1);add(1,0,0);add(2,0,0,mask);add(3,0);add(5,255,1)
    add(6)
    for tx in range(c):add(0,tx)
    rng=random.Random(20261600+c+n+w)
    for i in range(256):
        op=rng.choices(list(range(8)),[10,25,29,12,8,14,1,1])[0]
        tx=rng.randrange(c) if i%13 else rng.choice([c,255])
        addr=rng.randrange(n) if i%11 else rng.choice([n,0xffffffff,0x80000000])
        add(op,tx,addr,rng.choice([0,mask,rng.getrandbits(w)]))
    if (c,n,w)==(1,1,1):
        alphabet=[(0,0,0,0),(1,0,0,0),(2,0,0,0),(2,0,0,1),(3,0,0,0),(4,0,0,0),(5,255,0,0),(7,255,0xffffffff,1)]
        for sequence in itertools.product(alphabet,repeat=3):
            add(6)
            for args in sequence:add(*args)
    add(6);add(5,255,n-1)
    return commands

def operate(memory,epochs,contexts,command,c,n):
    op,tx,address,data,tag=command
    result=dict(op=op,status=0,context=tx,address=address,tag=tag,data=0,written=0,active=0,conflict=0)
    def conflicted(ctx):return any(epochs[a]!=epoch for a,(value,epoch) in ctx['reads'].items())
    if op==7:result['status']=1
    elif op==6:
        memory[:]=[0]*n;epochs[:]=[0]*n;contexts[:]=[None]*c
    elif op!=5 and tx>=c:result['status']=2
    else:
        ctx=None if op==5 else contexts[tx]
        if ctx is not None:result.update(active=1,conflict=int(conflicted(ctx)))
        if op in (1,2,5) and address>=n:result['status']=3
        elif op==5:result['data']=memory[address]
        elif op==0:
            if ctx is not None:result['status']=5
            else:contexts[tx]={'reads':{},'writes':{}};result['active']=1
        elif ctx is None:result['status']=4
        elif op==4 or (op==3 and conflicted(ctx)):
            contexts[tx]=None;result.update(active=0,conflict=0,status=6 if op==3 else 0)
        elif conflicted(ctx):result['status']=6
        elif op==1:
            if address in ctx['writes']:result['data']=ctx['writes'][address]
            else:
                if address not in ctx['reads']:ctx['reads'][address]=(memory[address],epochs[address])
                result['data']=ctx['reads'][address][0]
        elif op==2:ctx['writes'][address]=data
        else:
            # Any successful transaction can serialize at this point: every
            # external value it read still equals the committed image.
            assert all(memory[a]==value and epochs[a]==epoch for a,(value,epoch) in ctx['reads'].items())
            for a,value in ctx['writes'].items():memory[a]=value;epochs[a]+=1
            result['written']=len(ctx['writes']);contexts[tx]=None;result['active']=0
    return result

def pack(fields):
    result=0
    for value,width in fields:assert 0<=value<1<<width;result=(result<<width)|value
    return f'{result:x}'

def verify(path,commands,c,n,w,t):
    cw=max(1,n.bit_length());fields=[('op',3),('status',3),('context',8),('address',32),('tag',t),('data',w),('written',cw),('active',1),('conflict',1)]
    memory=[0]*n;epochs=[0]*n;contexts=[None]*c;coverage=collections.Counter();slotchecks=logchecks=serial=0
    lines=path.read_text(encoding='ascii').splitlines();assert len(lines)==len(commands)
    for position,(line,command) in enumerate(zip(lines,commands)):
        expected=operate(memory,epochs,contexts,command,c,n);parts=line.split();assert len(parts)==1+n+c*(3+4*n)
        raw=int(parts[0],16);actual={}
        for key,width in reversed(fields):actual[key]=raw%2**width;raw//=2**width
        assert raw==0 and actual==expected,(position,command,actual,expected)
        stored=[int(x,16) for x in parts[1:]];assert stored[:n]==memory,(position,'committed image');cursor=n;slotchecks+=n
        for tx,ctx in enumerate(contexts):
            conflict=bool(ctx) and any(epochs[a]!=epoch for a,(value,epoch) in ctx['reads'].items())
            want=[int(ctx is not None),int(conflict),len(ctx['writes']) if ctx else 0]
            for a in range(n):
                reads={} if ctx is None else ctx['reads'];writes={} if ctx is None else ctx['writes']
                want.extend([int(a in reads),int(a in writes),reads.get(a,(0,0))[0],writes.get(a,0)])
                logchecks+=1
            assert stored[cursor:cursor+len(want)]==want,(position,'transaction log',tx)
            cursor+=len(want)
        assert cursor==len(stored)
        coverage[f'op_{command[0]}']+=1;coverage[f'status_{expected["status"]}']+=1
        if command[0]==3 and expected['status']==0:serial+=1;coverage['empty_commit']+=expected['written']==0;coverage['full_commit']+=expected['written']==n
    assert all(coverage[f'op_{x}'] for x in range(8))
    assert all(coverage[f'status_{x}'] for x in range(6))
    if c>1:assert coverage['status_6']
    assert coverage['empty_commit'] and coverage['full_commit']
    return dict(committed_word_checks=slotchecks,transaction_word_checks=logchecks,serial_commit_certificates=serial,coverage=coverage,actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

def hashes():return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name!='verification.json' and 'history' not in p.relative_to(ROOT).parts}

def main():
    output=ROOT/'verification.json';previous=json.loads(output.read_text(encoding='utf-8')) if output.exists() else {}
    if previous.get('timeout_occurred'):raise RuntimeError('Prior timeout is terminal for the frozen batch')
    if previous:
        history=ROOT/'history';history.mkdir(exist_ok=True);raw=json.dumps(previous,indent=2)+'\n';(history/(hashlib.sha256(raw.encode()).hexdigest()+'.json')).write_text(raw,encoding='utf-8',newline='\n')
    report=dict(baseline_commit='83b11ea30d4762c5893cf37a8303b11706321876',status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],timeout_occurred=False,remaining_profiles=[list(p) for p in PROFILES],source_sha256=hashes(),not_run=['synthesis','PnR','STA','hardware','expanded regression'])
    def save():output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();initial=hashes();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')]);iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(argv,cwd,negative=False):
        argv=list(map(str,argv))
        try:p=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as e:
            report['timeout_occurred']=True;report['commands'].append(dict(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=str(e.stdout or ''),stderr=str(e.stderr or '')));save();raise
        row=dict(argv=argv,returncode=p.returncode,stdout=p.stdout,stderr=p.stderr,timeout_seconds=20,status='PASS' if (p.returncode==0)!=negative else 'FAIL');report['commands'].append(row);save()
        if negative:assert p.returncode>0 and 'transactional_scratchpad_invalid_parameters__see_README' in p.stderr,row
        else:assert p.returncode==0 and not p.stderr,row
        return p.stdout
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text());assert plan['profiles']==[list(p) for p in PROFILES] and plan['invalid_parameters']==[list(p) for p in INVALID]
        for p in ROOT.rglob('*'):
            if p.is_file():raw=p.read_bytes();raw.decode('utf-8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),p
        run([iv,'-V'],ROOT);run([iv,'-g2012','-Wall','-tnull','-s','transactional_scratchpad','-s','transaction_bank4','-f','example/files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_txn_') as temp:
            target=Path(temp)
            for c,n,w,t in PROFILES:
                commands=fixtures(c,n,w,t);assert len(commands)<=10000
                data=('\n'.join(pack([(op,3),(tx,8),(addr,32),(value,w),(tag,t)]) for op,tx,addr,value,tag in commands)+'\n').encode('ascii');(target/'input.hex').write_bytes(data)
                run([iv,'-g2012','-Wall','-s','tb_transactional_scratchpad',f'-Ptb_transactional_scratchpad.C={c}',f'-Ptb_transactional_scratchpad.N={n}',f'-Ptb_transactional_scratchpad.W={w}',f'-Ptb_transactional_scratchpad.T={t}','-o','sim.vvp',ROOT/'rtl/transactional_scratchpad.sv',ROOT/'sim/tb_transactional_scratchpad.sv'],target)
                text=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',f'+COUNT={len(commands)}'],target)
                match=re.search(r'PASS txn commands=(\d+) cycles=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) recovery=(\d+) max_latency=(\d+) bound=(\d+) applications=(\d+) invalidations=(\d+)',text);assert match,text
                values=list(map(int,match.groups()));assert values[0]==len(commands) and all(values[j]>0 for j in [2,3,4,5,8])
                assert values[4]==(19 if c==n==1 else 22) and values[6]<=values[7]==max(c*n+1,n*(3+2*c)+3)
                item=dict(zip(['main_commands','trace_nonreset_cycles','source_blocked_cycles','held_response_cycles','reset_probes','recovery_commands','maximum_first_latency','conservative_bound','word_applications','context_invalidations'],values))
                item.update(CONTEXTS=c,DEPTH=n,DATA_W=w,TAG_W=t,status='PASS',input_sha256=hashlib.sha256(data).hexdigest(),output=text.strip(),**verify(target/'actual.hex',commands,c,n,w,t));report['profiles'].append(item);report['remaining_profiles'].pop(0);save();print(f'PASS txn C={c} N={n} W={w} commands={len(commands)}',flush=True)
            for key,value in INVALID:run([iv,'-g2012','-tnull','-s','transactional_scratchpad',f'-Ptransactional_scratchpad.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes(),'source changed during fixed matrix'
        names=['main_commands','trace_nonreset_cycles','source_blocked_cycles','held_response_cycles','reset_probes','recovery_commands','committed_word_checks','transaction_word_checks','serial_commit_certificates','word_applications','context_invalidations']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=len(INVALID),totals={key:sum(p[key] for p in report['profiles']) for key in names},counter_scope='Commands/snapshots/epoch certificates/coverage are main-only; cycles/stalls/applications/invalidation counters include all nonreset probe/setup/recovery/main activity.',oracle='Unbounded Python address epochs with read epoch/value and private-write dictionaries; successful commit validates all external reads then applies writes as one serial event, no RTL invalidation scan modeled.');save();print(f'PASS txn profiles={len(PROFILES)} children={len(report["commands"])}',flush=True)
    except BaseException as e:report['failure']=repr(e);report['status']=['NOT_RUN','HW_UNVERIFIED'];save();raise

if __name__=='__main__':main()
