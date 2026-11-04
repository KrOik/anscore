#!/usr/bin/env python3
"""Frozen finite B14 profiles, flat-list oracle, <=20s checker children."""
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
BASELINE='01b92bf2f8d81fff097f1965de61edf81604ae4f'
PROFILES=[(1,1,1),(3,5,3),(16,8,8),(64,16,8),(256,32,32)]
INVALID=[('BUCKETS',0),('BUCKETS',257),('COUNT_W',0),('COUNT_W',33),('TAG_W',0),('TAG_W',33)]

def operate(masses,command):
    op,lo,hi,value,rank,tag=command;n=len(masses)
    result=dict(op=op,status=0,index=0,sum=0,total=sum(masses),tag=tag)
    if op==0:
        if lo>=n:result['status']=1
        else:result.update(index=lo,sum=masses[lo]);masses[lo]=value
    elif op==1:
        if lo>=n or hi>=n or lo>hi:result['status']=1
        else:result['sum']=sum(masses[lo:hi+1])
    elif op==2:
        if rank>=sum(masses):result['status']=2
        else:
            prefix=0
            for i,mass in enumerate(masses):
                if prefix+mass>rank:result.update(index=i,sum=prefix);break
                prefix+=mass
            else:raise AssertionError('valid flat-list rank not selected')
    else:masses[:]=[0]*n
    result['total']=sum(masses)
    return result

def fixtures(n,w,t):
    sw=w+(n-1).bit_length();maximum=2**w-1;rankmax=2**sw-1;tagmax=2**t-1
    commands=[];shadow=[0]*n
    def add(op,lo=0,hi=0,value=0,rank=0):
        cmd=(op,lo,hi,value,rank,(len(commands)*37+11)&tagmax)
        assert 0<=value<=maximum and 0<=rank<=rankmax
        commands.append(cmd)
        if op==0 and lo<n:shadow[lo]=value
        elif op==3:shadow[:]=[0]*n
    add(3,0xffffffff,0xffffffff,maximum,rankmax)
    add(1,0,n-1,maximum,rankmax);add(2,0xffffffff,0xffffffff,maximum,0)
    add(0,0xffffffff,0,maximum);add(0,n,0,maximum)
    add(1,0,n);add(1,1,0);add(1,0x80000000,0xffffffff)
    # Every bucket at exact maximum, every single/prefix range, both rank boundaries.
    for index in range(n):
        add(0,index,0xffffffff,maximum,rankmax)
        add(1,0,index,maximum,rankmax);add(1,index,index)
        prefix=sum(shadow[:index]);add(2,0xffffffff,0xffffffff,maximum,prefix)
        add(2,rank=prefix+maximum-1)
    add(1,0,n-1);add(2,rank=sum(shadow)-1);add(2,rank=sum(shadow));add(2,rank=rankmax)
    # Zero masses create holes that must never be selected. Decreases repair all ancestors.
    for index in range(1,n,2):add(0,index,value=0)
    for index,mass in enumerate(shadow.copy()):
        if mass:
            prefix=sum(shadow[:index]);add(2,rank=prefix);add(2,rank=prefix+mass-1)
    for index in range(n-1,-1,-1):add(0,index,value=0)
    add(1,0,n-1);add(2,rank=0);add(0,n-1,value=maximum)
    add(2,rank=0);add(2,rank=maximum-1);add(1,n-1,n-1);add(0,n-1,value=maximum)
    add(3,0xffffffff,0xffffffff,maximum,rankmax)
    rng=random.Random(20261400+n+w)
    for i in range(320):
        op=rng.choices([0,1,2,3],[45,30,22,3])[0]
        if op==0:
            index=rng.randrange(n)
            if i%17==0:index=rng.choice([n,0xffffffff,0x80000000])
            val=rng.choice([0,maximum,rng.getrandbits(w)])
            add(0,index,0xffffffff,val,rankmax)
        elif op==1:
            lo,hi=sorted([rng.randrange(n),rng.randrange(n)])
            if i%13==0:lo,hi=rng.choice([(n,0),(0,n),(0xffffffff,0xffffffff),(1,0)])
            add(1,lo,hi,maximum,rankmax)
        elif op==2:
            total=sum(shadow)
            rank=rng.randrange(total) if total else 0
            if i%11==0:rank=rng.choice([total,rankmax])
            add(2,0xffffffff,0xffffffff,maximum,rank)
        else:add(3,0xffffffff,0xffffffff,maximum,rankmax)
    if (n,w)==(1,1):
        choices=[(0,0,0,0,0),(0,0,0,1,0),(1,0,0,0,0),(2,0,0,0,0),(2,0,0,0,1),
                 (3,0,0,0,0),(0,0xffffffff,0,1,0),(1,0,1,0,0),(1,1,0,0,0)]
        for sequence in itertools.product(choices,repeat=3):
            add(3)
            for cmd in sequence:add(*cmd)
    add(3);add(1,0,n-1);add(2,rank=0)
    return commands

def pack(fields):
    value=0
    for datum,width in fields:
        assert 0<=datum<2**width,(datum,width)
        value=value*2**width+datum
    return f'{value:x}'

def prepare(n,w,t):
    sw=w+(n-1).bit_length();commands=fixtures(n,w,t)
    data=('\n'.join(pack([(op,2),(lo,32),(hi,32),(value,w),(rank,sw),(tag,t)])
                     for op,lo,hi,value,rank,tag in commands)+'\n').encode('ascii')
    return commands,data

def verify(path,commands,n,w,t):
    sw=w+(n-1).bit_length();iw=max(1,(n-1).bit_length())
    fields=[('op',2),('status',2),('index',iw),('sum',sw),('total',sw),('tag',t)]
    masses=[0]*n;coverage=collections.Counter();history=hashlib.sha256();checks=0
    lines=path.read_text(encoding='ascii').splitlines();assert len(lines)==len(commands)
    for position,(line,command) in enumerate(zip(lines,commands)):
        words=line.split();assert len(words)==1+2*n
        bits=int(words[0],16);actual={}
        for name,width in reversed(fields):actual[name]=bits%(2**width);bits//=2**width
        assert bits==0
        before=masses.copy();expected=operate(masses,command)
        assert actual==expected,(position,command,actual,expected)
        leaves=[int(x,16) for x in words[1::2]];tree=[int(x,16) for x in words[2::2]]
        assert leaves==masses,(position,'leaf bank',leaves,masses)
        for end,stored in enumerate(tree,1):
            # Definition of this row's interval; direct list sum, no update recurrence.
            interval=end&-end
            assert stored==sum(masses[end-interval:end]),(position,'aggregate interval',end,stored,masses)
            assert stored<2**sw
            checks+=1
        history.update(json.dumps(masses,separators=(',',':')).encode())
        op,lo,hi,value,rank,tag=command
        coverage[f'op_{op}']+=1;coverage[f'status_{expected["status"]}']+=1
        if op==0 and not expected['status']:
            coverage['increases']+=value>before[lo];coverage['decreases']+=value<before[lo]
            coverage['unchanged_sets']+=value==before[lo]
        if op==1 and not expected['status']:
            coverage['single_ranges']+=lo==hi;coverage['full_ranges']+=lo==0 and hi==n-1
            coverage['interior_ranges']+=lo>0 and hi<n-1
        if op==2 and not expected['status']:
            selected=expected['index'];assert masses[selected]>0
            assert expected['sum']<=rank<expected['sum']+masses[selected]
            coverage['rank_zero']+=rank==0;coverage['rank_last']+=rank==sum(masses)-1
            coverage['selected_after_zero_gap']+=selected>0 and any(x==0 for x in masses[:selected])
        coverage['exact_maximum_total']+=sum(masses)==n*(2**w-1)
    assert all(coverage[f'op_{op}']>0 for op in range(4))
    assert all(coverage[f'status_{st}']>0 for st in range(3))
    assert coverage['increases'] and coverage['decreases'] and coverage['unchanged_sets']
    if n>1:assert coverage['selected_after_zero_gap']
    return dict(coverage=coverage,leaf_checks=checks,aggregate_interval_checks=checks,
                flat_history_sha256=history.hexdigest(),actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

def local_hashes():
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name!='verification.json'}

def main():
    output_file=ROOT/'verification.json'
    previous=json.loads(output_file.read_text(encoding='utf-8')) if output_file.exists() else {}
    if previous.get('timeout_occurred') or any(c.get('status')=='TIMEOUT_NOT_RUN' for c in previous.get('commands',[])):
        raise RuntimeError('Prior timeout is terminal for this fixed batch; no retry permitted')
    report=dict(baseline_commit=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],timeout_occurred=False)
    def save():output_file.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();initial=local_hashes();report['source_sha256']=initial;save()
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(argv,cwd,negative=False):
        command=[str(x) for x in argv]
        try:process=subprocess.run(command,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            report['timeout_occurred']=True
            report['commands'].append(dict(argv=command,returncode=None,status='TIMEOUT_NOT_RUN',timeout_seconds=20,
                stdout=str(error.stdout or ''),stderr=str(error.stderr or '')));save();raise
        record=dict(argv=command,returncode=process.returncode,stdout=process.stdout,stderr=process.stderr,timeout_seconds=20)
        report['commands'].append(record);save()
        if negative:assert process.returncode>0 and 'ram_fenwick_index_invalid_parameters__see_README' in process.stderr,record
        else:assert process.returncode==0 and not process.stderr,record
        return process.stdout
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text(encoding='utf-8'))
        assert plan['profiles']==[list(p) for p in PROFILES] and plan['invalid_parameters']==[list(p) for p in INVALID]
        for p in ROOT.rglob('*'):
            if p.is_file():
                raw=p.read_bytes();raw.decode('utf-8',errors='strict');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),p
        run([iv,'-V'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','ram_fenwick_index','-s','mass_index64','-f','example/files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_fenwick_') as tmp:
            target=Path(tmp)
            for n,w,t in PROFILES:
                commands,data=prepare(n,w,t);assert len(commands)<=30001
                (target/'input.hex').write_bytes(data)
                run([iv,'-g2012','-Wall','-s','tb_ram_fenwick_index',f'-Ptb_ram_fenwick_index.N={n}',
                     f'-Ptb_ram_fenwick_index.W={w}',f'-Ptb_ram_fenwick_index.T={t}','-o','sim.vvp',
                     ROOT/'rtl/ram_fenwick_index.sv',ROOT/'sim/tb_ram_fenwick_index.sv'],target)
                text=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',
                          f'+COUNT={len(commands)}',f'+OUTCOUNT={len(commands)}'],target)
                m=re.search(r'PASS fenwick responses=(\d+) cycles=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) recovery=(\d+) slots=(\d+) max_latency=(\d+) bound=(\d+) updates=(\d+) prefixes=(\d+) selects=(\d+) skips=(\d+)',text)
                assert m,text
                c=list(map(int,m.groups()));nw=max(1,n.bit_length())
                assert c[0]==len(commands) and c[2]>0 and c[3]>0 and c[4]==(19 if n==1 else 20)
                assert c[6]==n*len(commands) and c[7]<=c[8]==max(n+1,6*nw+8)
                profile=dict(BUCKETS=n,COUNT_W=w,TAG_W=t,status='PASS',main_commands=len(commands),
                    trace_nonreset_cycles=c[1],source_blocked_cycles=c[2],held_response_cycles=c[3],reset_probes=c[4],
                    recovery_setup_commands=c[5],maximum_first_latency=c[7],conservative_bound=c[8],
                    aggregate_writes=c[9],prefix_reads=c[10],select_reads=c[11],select_out_of_range_skips=c[12],
                    input_sha256=hashlib.sha256(data).hexdigest(),output=text.strip(),**verify(target/'actual.hex',commands,n,w,t))
                report['profiles'].append(profile);save();print(f'PASS fenwick N={n} W={w} commands={len(commands)}',flush=True)
            for key,value in INVALID:
                run([iv,'-g2012','-tnull','-s','ram_fenwick_index',f'-Pram_fenwick_index.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==local_hashes(),'sources changed during fixed matrix'
        totals=['main_commands','trace_nonreset_cycles','source_blocked_cycles','held_response_cycles','reset_probes',
                'recovery_setup_commands','leaf_checks','aggregate_interval_checks']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=len(INVALID),
            totals={name:sum(p[name] for p in report['profiles']) for name in totals},
            counter_scope='Responses, leaf/aggregate checks and coverage are main-only. Cycles/stalls/read/write counters include all non-reset probe/setup/recovery/main activity.',
            oracle='Flat Python mass list; direct slice sums, linear weighted-rank scan; every leaf and aggregate interval checked after every main response.',
            not_run=['synthesis','PnR','STA','hardware','expanded regression'])
        save();print(f'PASS fenwick profiles={len(PROFILES)} children={len(report["commands"])}',flush=True)
    except BaseException as error:
        report['failure']=repr(error);report['status']=['NOT_RUN','HW_UNVERIFIED'];save()
        history=ROOT/'history';history.mkdir(exist_ok=True)
        number=len(list(history.glob('failure_*.json')))+1
        (history/f'failure_{number:03d}.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
        raise
if __name__=='__main__':main()
