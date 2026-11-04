#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite frozen matrix; sorted interval-complement oracle, no RTL run model."""
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
PROFILES=[(1,1),(3,3),(17,8),(64,8),(256,32)]
INVALID=[('UNITS',0),('UNITS',257),('TAG_W',0),('TAG_W',33)]


def gaps(live,n):
    """Derive geometric complement from sorted disjoint owned intervals."""
    result=[];previous=0
    for base,length in sorted(live.items()):
        assert 0<=previous<=base<base+length<=n
        if previous<base:result.append((previous,base))
        previous=base+length
    if previous<n:result.append((previous,n))
    return result


def operate(live,command,n):
    op,length,base,align,tag=command
    result=dict(op=op,status=0,length=length,base=0,align=align,tag=tag)
    if op>3:result['status']=4
    elif op==3:live.clear()
    elif op==2:pass
    elif length==0 or length>n or (op==0 and align>8) or (op==1 and (base>=n or base+length>n)):
        result['status']=1
    elif op==1:
        if live.get(base)!=length:result['status']=3
        else:del live[base];result['base']=base
    else:
        # Candidate comes from each maximal complementary interval, rather
        # than testing unit occupancy or following the DUT scan recurrence.
        alignment=1<<align
        candidates=[((lo+alignment-1)//alignment)*alignment for lo,hi in gaps(live,n)
                    if ((lo+alignment-1)//alignment)*alignment+length<=hi]
        if not candidates:result['status']=2
        else:result['base']=min(candidates);live[result['base']]=length
    free=gaps(live,n)
    result.update(free=sum(hi-lo for lo,hi in free),gap=max([hi-lo for lo,hi in free],default=0))
    return result


def fixtures(n,t):
    commands=[];live={}
    def add(op,length=0,base=0,align=0):
        command=(op,length,base,align,(37*len(commands)+11)&((1<<t)-1))
        commands.append(command);return operate(live,command,n)
    add(3,0xffffffff,0xffffffff,15)
    for op in range(4,8):add(op,0xffffffff,0xffffffff,15)
    for length in [0,n+1,0xffffffff]:add(0,length,0xffffffff,0)
    add(0,1,0xffffffff,9);add(0,1,0xffffffff,15)
    add(1,0);add(1,1,n);add(1,n,1);add(1,n,0xffffffff);add(1,1,0x80000000)
    add(2,0xffffffff,0xffffffff,15);add(1,1)
    for length in sorted({1,2,3,5,7,max(1,n//2),max(1,n-1),n}):
        if length>n:continue
        add(3);add(0,length,0xffffffff);add(2,0xffffffff,0xffffffff,15);add(0,1)
        if length>1:add(1,length-1,0,15);add(1,length-1,1,15)
        add(1,length,0,15);add(1,length,0,15);add(2)
    for align in range(9):
        add(3);add(0,1);add(0,min(3,n),0xffffffff,align);add(2,0xffffffff,0xffffffff,15)
        for base,length in list(sorted(live.items(),reverse=True)):add(1,length,base,15)
    # Exhaust the exact pool, leave alternating one-unit holes, then coalesce
    # them by exact releases and request the entire original extent.
    add(3)
    for _ in range(n):add(0,1)
    add(0,1)
    for base in range(0,n,2):add(1,1,base,15)
    add(2)
    if n>1:add(0,2)
    for base in range(1,n,2):add(1,1,base,15)
    add(2);add(0,n);add(1,n,0,15);add(2)
    if n>=3:
        # Exact odd size, alignment padding, neighboring ownership and wrong
        # geometry must not round, consume padding, or merge allocations.
        add(3);add(0,1);add(0,1,0,1);add(0,1);add(1,2,0);add(1,1,1,15)
        add(1,1,0,15);add(1,1,2,15);add(0,3);add(1,3,0,15)
    rng=random.Random(20261700+n+t)
    for i in range(256):
        op=rng.choices(list(range(8)),[30,32,18,2,1,1,1,1])[0]
        if op==1 and live and i%3:
            base,length=rng.choice(list(sorted(live.items())))
            if i%11==0:length=max(1,length-1)
            elif i%13==0:base+=1
        else:
            base=rng.choice([0,n-1,n,0xffffffff,0x80000000,rng.randrange(n)])
            length=rng.choice([0,1,2,3,5,7,n,n+1,0xffffffff,rng.randrange(1,n+1)])
        add(op,length,base,rng.choice([0,0,1,2,3,8,9,15]))
    if n==1:
        alphabet=[(0,1,0,0),(0,1,0xffffffff,8),(1,1,0,15),(2,0xffffffff,0xffffffff,15),
                  (4,1,0,0),(0,0,0,0),(3,0xffffffff,0xffffffff,15),(1,1,1,0)]
        for sequence in itertools.product(alphabet,repeat=3):
            add(3)
            for args in sequence:add(*args)
    add(3,0xffffffff,0xffffffff,15);add(0,n,0xffffffff,8);add(2);add(1,n,0,15);add(2)
    return commands


def pack(values):
    result=0
    for value,width in values:
        assert 0<=value<1<<width
        result=(result<<width)|value
    return f'{result:x}'


def vector_bytes(n,t):
    commands=fixtures(n,t)
    data=('\n'.join(pack([(op,3),(length,32),(base,32),(align,4),(tag,t)])
                    for op,length,base,align,tag in commands)+'\n').encode('ascii')
    return commands,data


def verify(path,commands,n,t):
    cw=n.bit_length();fields=[('op',3),('status',3),('length',32),('base',32),('align',4),('tag',t),('free',cw),('gap',cw)]
    lines=path.read_text(encoding='ascii').splitlines();assert len(lines)==len(commands)
    live={};coverage=collections.Counter();metadata_checks=0;exact_nonpower=0;nonzero_allocations=0
    for position,(line,command) in enumerate(zip(lines,commands)):
        expected=operate(live,command,n);parts=line.split();assert len(parts)==n+1
        value=int(parts[0],16);actual={}
        for key,width in reversed(fields):actual[key]=value%2**width;value//=2**width
        assert value==0 and actual==expected,(position,command,actual,expected)
        # An independent interval expansion checks occupied cells AND exact
        # allocation boundaries. Adjacent allocations must remain distinguishable.
        wanted=[0]*n
        for base,length in live.items():
            wanted[base]=(1<<cw)|length
            for unit in range(base+1,base+length):wanted[unit]=1<<cw
        assert [int(x,16) for x in parts[1:]]==wanted,(position,'metadata image',command)
        metadata_checks+=n
        op,status=command[0],expected['status']
        coverage[f'op_{op}']+=1;coverage[f'status_{status}']+=1
        coverage['full']+=expected['free']==0;coverage['empty']+=expected['free']==n
        coverage['fragmented']+=expected['free']>expected['gap']
        if op==0 and status==0:
            length=command[1];exact_nonpower+=bool(length & (length-1));nonzero_allocations+=expected['base']!=0
            assert expected['base']%(1<<command[3])==0
    assert all(coverage[f'op_{op}'] for op in range(8))
    assert all(coverage[f'status_{status}'] for status in range(5))
    assert coverage['full'] and coverage['empty']
    if n>=3:assert coverage['fragmented'] and exact_nonpower and nonzero_allocations
    return dict(metadata_word_checks=metadata_checks,exact_nonpower_allocations=exact_nonpower,
                nonzero_base_allocations=nonzero_allocations,coverage=coverage,
                actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def hashes():
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name!='verification.json'
            and 'history' not in p.relative_to(ROOT).parts}


def main():
    output=ROOT/'verification.json'
    previous=json.loads(output.read_text()) if output.exists() else {}
    if previous.get('timeout_occurred'):raise RuntimeError('Prior timeout is terminal for the frozen batch')
    if previous and 'UNIT_SIM_PASS' in previous.get('status',[]):raise RuntimeError('Completed frozen batch must not be rerun')
    plan=json.loads((ROOT/'TEST_PLAN.json').read_text())
    assert plan['profiles']==[list(p) for p in PROFILES] and plan['invalid_parameters']==[list(p) for p in INVALID]
    assert plan['child_timeout_seconds']==20 and plan['reset_probes_each_profile']==16
    for n,t in PROFILES:
        commands,data=vector_bytes(n,t)
        assert plan['frozen_vectors'][f'{n}/{t}']==dict(commands=len(commands),sha256=hashlib.sha256(data).hexdigest())
    report=dict(baseline_commit=plan['baseline_commit'],status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],
                timeout_occurred=False,remaining_profiles=[list(p) for p in PROFILES],source_sha256=hashes(),
                not_run=plan['not_run'])
    def save():output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();initial=hashes()
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(argv,cwd,negative=False):
        argv=list(map(str,argv))
        try:result=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            report['timeout_occurred']=True
            report['commands'].append(dict(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,
                                           stdout=str(error.stdout or ''),stderr=str(error.stderr or '')))
            save();raise
        row=dict(argv=argv,returncode=result.returncode,stdout=result.stdout,stderr=result.stderr,timeout_seconds=20,
                 status='PASS' if (result.returncode==0)!=negative else 'FAIL')
        report['commands'].append(row);save()
        if negative:
            assert result.returncode>0 and 'extent_pool_allocator_invalid_parameters__see_README' in result.stderr,row
        else:assert result.returncode==0 and not result.stderr,row
        return result.stdout
    def archive_failure():
        history=ROOT/'history';history.mkdir(exist_ok=True)
        destination=history/f'attempt_{len(list(history.glob("attempt_*")))+1:03d}';destination.mkdir()
        (destination/'verification.json').write_bytes(output.read_bytes())
        for relative in initial:
            source=ROOT/relative;target=destination/'tested_source'/relative
            target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(source.read_bytes())
    try:
        for p in ROOT.rglob('*'):
            if p.is_file() and 'history' not in p.relative_to(ROOT).parts:
                raw=p.read_bytes();raw.decode('utf-8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),p
        run([iv,'-g2012','-Wall','-tnull','-s','extent_pool_allocator','-s','extent_pool64','-f','example/files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_b17_extent_') as temporary:
            work=Path(temporary)
            for n,t in PROFILES:
                commands,data=vector_bytes(n,t);(work/'input.hex').write_bytes(data)
                report['current_profile']=dict(UNITS=n,TAG_W=t,input_sha256=hashlib.sha256(data).hexdigest(),main_commands=len(commands));save()
                run([iv,'-g2012','-Wall','-s','tb_extent_pool_allocator',f'-Ptb_extent_pool_allocator.N={n}',
                     f'-Ptb_extent_pool_allocator.T={t}','-o','sim.vvp',ROOT/'rtl/extent_pool_allocator.sv',
                     ROOT/'sim/tb_extent_pool_allocator.sv'],work)
                stdout=run([vv,'sim.vvp',f'+INPUT={work/"input.hex"}',f'+OUTPUT={work/"actual.hex"}',f'+COUNT={len(commands)}'],work)
                match=re.fullmatch(r'PASS extent commands=(\d+) cycles=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) recovery=(\d+) max_latency=(\d+) bound=(\d+) writes=(\d+) scans=(\d+) summaries=(\d+) busy=(\d+) align_skips=(\d+) states=3ff\n.*',stdout,re.S)
                assert match,stdout
                values=list(map(int,match.groups()));assert values[0]==len(commands) and values[4:6]==[16,64]
                assert values[6]<=values[7]==5*n+8 and all(values[k]>0 for k in [2,3,8,9,10])
                names=['main_commands','trace_nonreset_cycles','blocked_source_cycles','held_response_cycles','reset_probes',
                       'recovery_commands','maximum_first_latency','conservative_bound','unit_mutation_writes',
                       'allocation_scan_checks','summary_scan_checks','busy_unit_checks','alignment_skips']
                item=dict(zip(names,values));item.update(UNITS=n,TAG_W=t,status='PASS',input_sha256=hashlib.sha256(data).hexdigest(),
                    output=stdout.strip(),**verify(work/'actual.hex',commands,n,t))
                report['profiles'].append(item);report['remaining_profiles'].pop(0);report.pop('current_profile');save()
                print(f'PASS extent N={n} T={t} commands={len(commands)}',flush=True)
            for key,value in INVALID:
                run([iv,'-g2012','-tnull','-s','extent_pool_allocator',f'-Pextent_pool_allocator.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes(),'source changed during frozen matrix'
        names=['main_commands','trace_nonreset_cycles','blocked_source_cycles','held_response_cycles','reset_probes',
               'recovery_commands','unit_mutation_writes','allocation_scan_checks','summary_scan_checks','busy_unit_checks',
               'alignment_skips','metadata_word_checks','exact_nonpower_allocations','nonzero_base_allocations']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=len(INVALID),
                      totals={key:sum(p[key] for p in report['profiles']) for key in names},
                      counter_scope='Commands/coverage/metadata are main-only; trace cycles/stalls/scans/writes include probe setup, cancellation and fresh recovery.',
                      oracle='Sorted exact live intervals; complementary geometric gaps yield aligned candidate bases. Independent interval expansion verifies busy cells and allocation head lengths; no RTL scan or controller algorithm modeled.')
        save();print(f'PASS extent profiles={len(PROFILES)} children={len(report["commands"])}',flush=True)
    except BaseException as error:
        report['failure']=repr(error);report['status']=['NOT_RUN','HW_UNVERIFIED'];save();archive_failure();raise


if __name__=='__main__':main()
