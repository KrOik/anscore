#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen keyed event tests with an independent dictionary/minimum oracle."""
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
PROFILES=[(1,1,1,1,1),(3,3,4,5,3),(7,8,16,16,8),(16,16,32,32,8),(128,32,64,64,32)]
INVALID=[(name,value) for name,upper in [('SLOTS',128),('ID_W',32),('TIME_W',64),('DATA_W',64),('TAG_W',32)] for value in [0,upper+1]]


def operate(events,command,n):
    op,key,deadline,data,cutoff,tag=command
    result=dict(op=op,status=0,found=0,replaced=0,due=0,id=0,deadline=0,data=0,tag=tag)
    if op>4:result['status']=5
    elif op==4:events.clear()
    elif op==0:
        if key not in events and len(events)==n:result['status']=3
        else:
            result.update(found=1,replaced=int(key in events),id=key,deadline=deadline,data=data)
            events[key]=(deadline,data)
    elif op==1:
        if key not in events:result['status']=2
        else:
            old_deadline,old_data=events.pop(key)
            result.update(found=1,id=key,deadline=old_deadline,data=old_data)
    elif not events:result['status']=1
    else:
        selected=min(events,key=lambda event_id:(events[event_id][0],event_id))
        old_deadline,old_data=events[selected];due=int(old_deadline<=cutoff)
        result.update(found=1,due=due,id=selected,deadline=old_deadline,data=old_data)
        if op==3:
            if due:del events[selected]
            else:result['status']=4
    result.update(live=len(events),free=n-len(events))
    return result


def fixtures(n,k,tw,d,t):
    commands=[];events={};km=(1<<k)-1;tm=(1<<tw)-1;dm=(1<<d)-1
    def add(op,key=0,deadline=0,data=0,cutoff=0):
        command=(op,key,deadline,data,cutoff,(len(commands)*37+11)&((1<<t)-1))
        commands.append(command);return operate(events,command,n)
    add(4,km,tm,dm,tm);add(2,km,tm,dm,tm);add(3,km,tm,dm,tm);add(1,km,tm,dm,tm)
    for op in range(5,8):add(op,km,tm,dm,tm)
    add(0,km,tm,dm,tm);add(2,0,0,0,tm-1);add(3,0,0,0,tm-1);add(2,0,0,0,tm)
    add(0,km,0,0,tm);add(2,0,tm,dm,0);add(3,0,tm,dm,0);add(1,km,tm,dm,tm)
    # Reverse insertion order and payload extrema must not affect ID tie break.
    add(4)
    for key in range(n-1,-1,-1):add(0,key,1,(key*13)&dm,tm)
    add(2,km,tm,dm,1);add(0,n-1,0,dm,tm);add(2,km,tm,dm,0)
    add(0,km,tm,dm,0)  # absent ID while full
    add(0,n-1,tm,0,tm);add(2,km,tm,dm,0)
    add(1,n//2,tm,dm,tm);add(1,n//2,tm,dm,tm);add(0,km,tm,dm,0)
    add(2,0,0,0,0);add(2,0,0,0,tm)
    while events:add(3,km,tm,dm,tm)
    add(3,km,tm,dm,tm)
    if n>=3:
        add(0,km,1<<(tw-1),dm,0);add(0,0,0,0,tm);add(0,km-1,tm,1,0)
        add(2,0,0,0,0);add(3,0,0,0,0);add(2,0,0,0,0)
        add(0,km,tm,dm^1,0);add(2,0,0,0,tm-1)
        add(1,km-1,0,0,0);add(2,0,0,0,tm);add(3,0,0,0,tm)
        # Reuse a lower physical free slot with a larger ID at the same time.
        add(4);add(0,0,1,0);add(0,2,1,dm);add(1,0);add(0,km,1,dm);add(2,0,0,0,1)
    # Fill/update/cancel/refill/drain every declared slot at each profile.
    add(4)
    for key in range(n):add(0,key,(tm-key)% (tm+1),(dm^key)&dm,0)
    for key in range(n-1,-1,-1):add(0,key,key%(tm+1),(key*29)&dm,tm)
    add(0,km,tm,dm,tm)
    for key in range(0,n,2):add(1,key,tm,dm,tm)
    for key in range(0,n,2):add(0,key,tm,dm,0)
    while events:add(3,0,0,0,tm)
    rng=random.Random(20261800+n+k+tw+d+t)
    for i in range(256):
        op=rng.choices(list(range(8)),[35,22,18,22,1,1,1,1])[0]
        key=rng.choice(list(events)) if events and i%3 else rng.choice([0,km,rng.getrandbits(k)])
        deadline=rng.choice([0,1,tm,1<<(tw-1),(1<<(tw-1))-1,rng.getrandbits(tw)])
        data=rng.choice([0,dm,rng.getrandbits(d)])
        cutoff=rng.choice([0,1,tm,1<<(tw-1),max(0,deadline-1),deadline,rng.getrandbits(tw)])
        add(op,key,deadline,data,cutoff)
    if (n,k,tw,d,t)==(1,1,1,1,1):
        alphabet=[(0,0,0,1,1),(0,1,1,0,0),(1,0,1,1,1),(2,1,1,1,0),
                  (3,1,1,1,0),(3,0,0,0,1),(4,1,1,1,1),(5,1,1,1,1)]
        for sequence in itertools.product(alphabet,repeat=3):
            add(4,km,tm,dm,tm)
            for args in sequence:add(*args)
    add(4,km,tm,dm,tm);add(0,km,tm,dm,0);add(3,0,0,0,tm-1);add(3,0,0,0,tm);add(2,km,tm,dm,tm)
    return commands


def pack(fields):
    result=0
    for value,width in fields:
        assert 0<=value<1<<width
        result=(result<<width)|value
    return f'{result:x}'


def vector_bytes(profile):
    n,k,tw,d,t=profile;commands=fixtures(*profile)
    data=('\n'.join(pack([(op,3),(key,k),(deadline,tw),(payload,d),(cutoff,tw),(tag,t)])
                    for op,key,deadline,payload,cutoff,tag in commands)+'\n').encode('ascii')
    return commands,data


def verify(path,commands,profile):
    n,k,tw,d,t=profile;cw=n.bit_length();record_width=k+tw+d
    fields=[('op',3),('status',3),('found',1),('replaced',1),('due',1),('id',k),
            ('deadline',tw),('data',d),('tag',t),('live',cw),('free',cw)]
    lines=path.read_text(encoding='ascii').splitlines();assert len(lines)==len(commands)
    events={};coverage=collections.Counter();slot_checks=0
    for position,(line,command) in enumerate(zip(lines,commands)):
        before=dict(events);expected=operate(events,command,n);parts=line.split();assert len(parts)==n+1
        raw=int(parts[0],16);actual={}
        for key,width in reversed(fields):actual[key]=raw%2**width;raw//=2**width
        assert raw==0 and actual==expected,(position,command,actual,expected)
        decoded={}
        for field in parts[1:]:
            value=int(field,16);assert value<1<<(record_width+1)
            if not value>>record_width:assert value==0;continue
            payload=value&((1<<d)-1);deadline=(value>>d)&((1<<tw)-1);key=(value>>(d+tw))&((1<<k)-1)
            assert key not in decoded,(position,'duplicate event identity',key)
            decoded[key]=(deadline,payload)
        assert decoded==events,(position,'logical RAM map',decoded,events)
        slot_checks+=n
        op,key,deadline,payload,cutoff,tag=command;status=expected['status']
        coverage[f'op_{op}']+=1;coverage[f'status_{status}']+=1
        coverage['full']+=expected['live']==n;coverage['empty']+=not expected['live']
        if op==0 and status==0 and key in before:
            coverage['replace']+=1;coverage['replace_full']+=len(before)==n
            coverage['replace_earlier']+=deadline<before[key][0];coverage['replace_later']+=deadline>before[key][0]
        if op in (2,3) and expected['found']:
            first_deadline=min(v[0] for v in before.values())
            coverage['id_tie_break']+=sum(v[0]==first_deadline for v in before.values())>1
            coverage['deadline_equality']+=cutoff==first_deadline
            coverage['cutoff_before']+=cutoff<first_deadline
            coverage['cutoff_after']+=cutoff>first_deadline
            coverage['high_bit_time']+=bool(expected['deadline']&(1<<(tw-1)))
        if op==1 and status==0:
            coverage['cancel_earliest']+=key==min(before,key=lambda ident:(before[ident][0],ident))
    assert all(coverage[f'op_{op}'] for op in range(8)) and all(coverage[f'status_{status}'] for status in range(6))
    assert all(coverage[name] for name in ['full','empty','replace_full','replace_earlier','replace_later','deadline_equality','cutoff_before','cancel_earliest','high_bit_time'])
    if n>1:assert coverage['id_tie_break'] and coverage['cutoff_after']
    return dict(slot_image_checks=slot_checks,coverage=coverage,actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def hashes():
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name!='verification.json'
            and 'history' not in p.relative_to(ROOT).parts}


def main():
    output=ROOT/'verification.json';previous=json.loads(output.read_text()) if output.exists() else {}
    if previous.get('timeout_occurred'):raise RuntimeError('Terminal timeout; frozen matrix cannot be retried')
    if 'UNIT_SIM_PASS' in previous.get('status',[]):raise RuntimeError('Qualified fixed matrix must not be rerun')
    plan=json.loads((ROOT/'TEST_PLAN.json').read_text())
    assert plan['profiles']==[list(p) for p in PROFILES] and plan['invalid_parameters']==[list(p) for p in INVALID]
    assert plan['child_timeout_seconds']==20 and plan['reset_probes_each_profile']==20
    plans=[]
    for profile in PROFILES:
        commands,data=vector_bytes(profile);key='/'.join(map(str,profile))
        assert plan['frozen_vectors'][key]==dict(commands=len(commands),sha256=hashlib.sha256(data).hexdigest())
        plans.append((profile,commands,data))
    report=dict(baseline_commit=plan['baseline_commit'],status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],
                source_sha256=hashes(),remaining_profiles=[list(p) for p in PROFILES],timeout_occurred=False,not_run=plan['not_run'])
    def save():output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();initial=hashes();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(argv,cwd,negative=False):
        argv=list(map(str,argv))
        try:result=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            report['timeout_occurred']=True
            decode=lambda value:value.decode(errors='replace') if isinstance(value,bytes) else value or ''
            report['commands'].append(dict(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=decode(error.stdout),stderr=decode(error.stderr)))
            save();raise
        good=(result.returncode>0 and 'ram_deadline_scheduler_invalid_parameters__see_README' in result.stderr) if negative else result.returncode==0 and not result.stderr
        report['commands'].append(dict(argv=argv,returncode=result.returncode,status='PASS' if good else 'FAIL',timeout_seconds=20,stdout=result.stdout,stderr=result.stderr));save()
        assert good,report['commands'][-1]
        return result.stdout
    def archive():
        history=ROOT/'history';history.mkdir(exist_ok=True)
        destination=history/f'attempt_{len(list(history.glob("attempt_*")))+1:03d}';destination.mkdir()
        (destination/'verification.json').write_bytes(output.read_bytes())
        for name in initial:
            target=destination/'tested_source'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/name).read_bytes())
    try:
        for p in ROOT.rglob('*'):
            if p.is_file() and 'history' not in p.relative_to(ROOT).parts:
                raw=p.read_bytes();raw.decode('utf-8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),p
        run([iv,'-g2012','-Wall','-tnull','-s','ram_deadline_scheduler','-s','deadline16','-f','example/files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_b18_deadline_') as temporary:
            work=Path(temporary)
            for profile,commands,data in plans:
                n,k,tw,d,t=profile;(work/'input.hex').write_bytes(data)
                report['current_profile']=dict(zip(plan['profile_fields'],profile));report['current_profile'].update(main_commands=len(commands),input_sha256=hashlib.sha256(data).hexdigest());save()
                run([iv,'-g2012','-Wall','-s','tb_ram_deadline_scheduler',f'-Ptb_ram_deadline_scheduler.N={n}',
                     f'-Ptb_ram_deadline_scheduler.K={k}',f'-Ptb_ram_deadline_scheduler.TW={tw}',
                     f'-Ptb_ram_deadline_scheduler.D={d}',f'-Ptb_ram_deadline_scheduler.T={t}',
                     '-o','sim.vvp',ROOT/'rtl/ram_deadline_scheduler.sv',ROOT/'sim/tb_ram_deadline_scheduler.sv'],work)
                stdout=run([vv,'sim.vvp',f'+INPUT={work/"input.hex"}',f'+OUTPUT={work/"actual.hex"}',f'+COUNT={len(commands)}'],work)
                match=re.fullmatch(r'PASS deadline commands=(\d+) accepted=(\d+) cycles=(\d+) blocked=(\d+) held=(\d+) source_holds=(\d+) resets=(\d+) recovery=(\d+) latency_checks=(\d+) max_latency=(\d+) bound=(\d+) reads=(\d+) writes=(\d+) clears=(\d+) states=7f\n.*',stdout,re.S)
                assert match,stdout
                values=list(map(int,match.groups()))
                assert values[0]==values[1]==values[8]==len(commands) and values[6:8]==[20,80]
                assert values[9]<=values[10]==2*n+2 and all(values[j]>0 for j in [3,4,5,11,12,13])
                names=['main_commands','accepted_main','trace_nonreset_cycles','blocked_source_cycles','held_response_cycles',
                       'source_hold_checks','reset_probes','recovery_commands','exact_latency_checks','maximum_first_latency',
                       'conservative_bound','row_reads','row_mutation_writes','row_initialization_writes']
                item=dict(zip(names,values));item.update(dict(zip(plan['profile_fields'],profile)))
                item.update(status='PASS',input_sha256=hashlib.sha256(data).hexdigest(),output=stdout.strip(),**verify(work/'actual.hex',commands,profile))
                report['profiles'].append(item);report['remaining_profiles'].pop(0);report.pop('current_profile');save()
                print(f'PASS deadline N={n} TIME_W={tw} commands={len(commands)}',flush=True)
            for key,value in INVALID:
                run([iv,'-g2012','-tnull','-s','ram_deadline_scheduler',f'-Pram_deadline_scheduler.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes(),'source changed during frozen matrix'
        assert len(report['commands'])==plan['qualified_child_records']==21
        names=['main_commands','accepted_main','trace_nonreset_cycles','blocked_source_cycles','held_response_cycles','source_hold_checks',
               'reset_probes','recovery_commands','exact_latency_checks','row_reads','row_mutation_writes','row_initialization_writes','slot_image_checks']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=len(INVALID),
                      totals={key:sum(p[key] for p in report['profiles']) for key in names},
                      counter_scope='Main commands/accepts/latencies/coverage/map checks are main-only. Trace cycles/stalls/RAM access counts include all nonreset setup/probe/fresh/main activity. Source-hold checks are main-only.',
                      oracle='Python unique-ID dictionary and minimum by (absolute unsigned deadline,ID). All physical live rows independently decode into a duplicate-free logical map; no serial scan/free-slot/controller model.')
        save();print(f'PASS deadline profiles=5 children={len(report["commands"])}',flush=True)
    except BaseException as error:
        report['status']=['NOT_RUN','HW_UNVERIFIED'];report['failure']=repr(error);save();archive();raise


if __name__=='__main__':main()
