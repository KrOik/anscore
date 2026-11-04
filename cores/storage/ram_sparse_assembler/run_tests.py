#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Freeze finite semantics before RTL; seal sources before the first HDL tool."""
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
import sys
import tempfile

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES=[(1,1,1),(3,5,3),(17,8,8),(64,8,8),(256,64,32)]
INVALID=[(key,value) for key,upper in [('DEPTH',256),('DATA_W',64),('TAG_W',32)] for value in [0,upper+1]]
RESET_TARGETS=['idle','pending_new_store','duplicate_read_equal','duplicate_read_conflict',
    'duplicate_check_equal','duplicate_check_conflict','held_begin_ack','held_new_put_ack',
    'held_duplicate_ack','held_conflict_ack','held_incomplete_ack','held_not_open_ack',
    'held_already_open_ack','held_zero_length_range_ack','held_bad_op_ack','first_replay_read',
    'first_replay_load','held_first_data','later_replay_read','later_replay_load','held_middle_data','held_final_data']
NOT_RUN=['synthesis','PnR','STA','board','expanded regression']
U64=(1<<64)-1


def sha(data):return hashlib.sha256(data).hexdigest()


def encoded(obj):return (json.dumps(obj,sort_keys=True,indent=2)+'\n').encode()


def pack(fields):
    word=0
    for value,width in fields:
        assert 0<=value<1<<width
        word=word<<width|value
    return word


def fixtures(n,d,t):
    commands=[];mask=(1<<d)-1
    def add(op,length=0,offset=0,data=0):
        assert 0<=length<=U64 and 0<=offset<=U64 and 0<=data<=mask
        tag=(1<<t)-1 if len(commands)%11==0 else (len(commands)*37+11)&((1<<t)-1)
        commands.append((op,length,offset,data,tag))
    add(3);add(4);add(1,offset=U64,data=mask);add(2)
    add(0,0);add(0,n+1)
    for op in [5,6,7]:add(op,U64,U64,mask)
    for bit in range(64):
        add(3);add(0,1<<bit);add(4);add(3)
    add(0,1)
    for bit in range(64):add(1,offset=1<<bit,data=mask)
    add(1,offset=U64,data=mask);add(0,0);add(4);add(3)
    add(0,n);add(2)
    for index in range(n-1,-1,-1):
        value=(index*37+11)&mask
        add(1,offset=index,data=value);add(1,offset=index,data=value)
        add(1,offset=index,data=value^1)
        if index%8==0:add(4,U64,U64,mask)
    add(2);add(4);add(2)
    if n>1:
        add(0,n)
        for index in range(0,n,2):add(1,offset=index,data=(index*13)&mask)
        add(2)
        for index in range(1,n,2):add(1,offset=index,data=(index*13)&mask)
        add(2);add(4)
    for value in [0,mask,1]+[1<<bit for bit in range(d)]:
        add(3);add(0,1);add(1,offset=0,data=value);add(2);add(4)
    for op in [5,6,7]:
        add(0,1);add(op,U64,U64,mask);add(1,offset=0,data=mask);add(2)
    if n==1:
        alphabet=[(0,1,0,0),(0,0,0,0),(1,0,0,0),(1,0,0,1),
                  (1,0,1,1),(2,0,0,0),(3,0,0,0),(4,0,0,0),(7,0,0,0)]
        for stream in itertools.product(alphabet,repeat=3):
            add(3)
            for op,length,offset,value in stream:add(op,length,offset,value)
    rng=random.Random(0xB220A+123*n+d+t)
    for _ in range(600):
        add(rng.choice([0,1,1,1,2,3,4,5,7]),rng.choice([0,1,n,n+1,U64,rng.randrange(n+1)]),
            rng.choice([0,n-1,n,U64,rng.randrange(n+1)]),rng.getrandbits(d))
    add(3);add(4)
    return commands


def model(profile):
    n,d,t=profile;aw=max(1,(n-1).bit_length());cw=n.bit_length()
    length=0;content={};outputs=[];timing=[];gaps=[];coverage=collections.Counter()
    commands=fixtures(*profile)
    fields=[('op',3),('status',3),('tag',t),('keep',1),('first',1),('last',1),
            ('index',aw),('data',d),('total',cw),('filled',cw)]
    def image():return (length,len(content),sum(1<<key for key in content),[content.get(key,0) for key in range(n)])
    for op,size,offset,data,tag in commands:
        status=0;latency=0;reads=0;writes=0;committed=False
        if op>4:status=7
        elif op==0:
            if length:status=5
            elif size==0 or size>n:status=6
            else:length=size;content={}
        elif op==1:
            if not length:status=4
            elif offset>=length:status=6
            elif offset in content:
                status=1 if content[offset]==data else 2;latency=2;reads=1
            else:content[offset]=data;latency=1;writes=1
        elif op==2:
            if not length:status=4
            elif len(content)!=length:status=3
            else:committed=True;latency=2;reads=1
        elif op==3:length=0;content={}
        snapshot=image()
        if committed:
            # Functional model publishes a sorted complete dictionary. It has
            # no RAM read pipeline, output controller or indexed storage array.
            assert set(content)==set(range(length))
            for index in sorted(content):
                record=dict(op=op,status=0,tag=tag,keep=1,first=int(index==0),last=int(index==length-1),
                            index=index,data=content[index],total=length,filled=len(content))
                outputs.append((record,*snapshot))
            gaps.extend([(2,1)]*(length-1));coverage['committed_words']+=length
            coverage['full_depth_commit']+=length==n
            length=0;content={}
        else:
            record=dict(op=op,status=status,tag=tag,keep=0,first=1,last=1,index=0,data=0,total=length,filled=len(content))
            outputs.append((record,*snapshot))
        timing.append((latency,reads,writes));coverage[f'op_{op}']+=1;coverage[f'status_{status}']+=1
        coverage['new_puts']+=writes;coverage['duplicate_checks']+=op==1 and status in [1,2]
    assert all(coverage[f'op_{op}'] for op in range(8)) and all(coverage[f'status_{s}'] for s in range(8))
    assert coverage['full_depth_commit'] and coverage['duplicate_checks'] and len(commands)<30001
    vector=('\n'.join(f'{pack([(op,3),(size,64),(offset,64),(data,d),(tag,t)]):x}' for op,size,offset,data,tag in commands)+'\n').encode()
    return dict(commands=commands,outputs=outputs,timing=timing,gaps=gaps,fields=fields,input_bytes=vector,coverage=coverage)


def frozen(m):return dict(commands=len(m['commands']),outputs=len(m['outputs']),fragment_gaps=len(m['gaps']),
    input_sha256=sha(m['input_bytes']),oracle_sha256=sha(encoded([m['outputs'],m['timing'],m['gaps']])))


def hashes(include_seal=True):
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.name!='verification.json' and (include_seal or p.name!='SOURCE_FREEZE.json')
            and 'history' not in p.relative_to(ROOT).parts}


def verify(path,m,profile):
    actual=[];timing=[];gaps=[];rows=0
    for line in path.read_text(encoding='ascii').splitlines():
        fields=line.split()
        if fields[0]=='F':
            index,latency,reads,writes=map(int,fields[1:]);assert index==len(timing)
            assert (latency,reads,writes)==m['timing'][index],(index,fields,m['timing'][index]);timing.append((latency,reads,writes))
        elif fields[0]=='G':
            index,latency,reads=map(int,fields[1:]);assert index==len(gaps)
            assert (latency,reads)==m['gaps'][index],(index,fields,m['gaps'][index]);gaps.append((latency,reads))
        else:
            assert fields[0]=='O';word=int(fields[1],16);record={}
            for key,width in reversed(m['fields']):record[key]=word&((1<<width)-1);word>>=width
            assert word==0;image=[int(value,16) for value in fields[5:]];rows+=len(image)
            actual.append((record,int(fields[2]),int(fields[3]),int(fields[4],16),image))
    assert actual==m['outputs'],next(((i,x,y) for i,(x,y) in enumerate(zip(actual,m['outputs'])) if x!=y),('lengths',len(actual),len(m['outputs'])))
    assert timing==m['timing'] and gaps==m['gaps']
    return dict(checked_outputs=len(actual),complete_payload_row_checks=rows,exact_latency_checks=len(timing),
                exact_first_ram_schedule_checks=len(timing),exact_fragment_gap_checks=len(gaps),trace_sha256=sha(path.read_bytes()))


def main():
    action=sys.argv[1:];plan_path=ROOT/'TEST_PLAN.json';seal_path=ROOT/'SOURCE_FREEZE.json';receipt=ROOT/'verification.json'
    prior=json.loads(receipt.read_text()) if receipt.exists() else {}
    if prior.get('timeout_occurred'):raise RuntimeError('Terminal timeout: no retries, fixture shrink or larger limit')
    if 'UNIT_SIM_PASS' in prior.get('status',[]):raise RuntimeError('Successful frozen matrix cannot be rerun or resealed')
    models=[(p,model(p)) for p in PROFILES]
    if action==['--freeze']:
        assert not plan_path.exists() and not seal_path.exists() and not receipt.exists()
        plan=dict(baseline_commit='1fcf2f92dbf763e3251bd2994a7b9fd940c43694',frozen_before_rtl_implementation=True,
            profile_fields=['DEPTH','DATA_W','TAG_W'],profiles=PROFILES,invalid_parameters=INVALID,child_timeout_seconds=20,
            qualified_child_records=18,reset_targets=RESET_TARGETS,singleton_aliases={'later_replay_read':'first_replay_read',
                'later_replay_load':'first_replay_load','held_middle_data':'held_first_data','held_final_data':'held_first_data'},
            fresh_words_each_probe='min(DEPTH,3)',fresh_commands_each_probe='min(DEPTH,3)+9',
            frozen_vectors={'/'.join(map(str,p)):frozen(m) for p,m in models},not_run=NOT_RUN,
            checks=['independent immutable-first-write sparse dictionary and sorted complete publication, no RTL pipeline',
                'all public fields, complete owned payload RAM and valid/length/unique-count after every output',
                'full64 length/offset validation, all data bits, all statuses, same/different duplicates, incomplete preservation',
                'real next frozen command held through actual handshake; every ACK/data token held',
                'exact first-valid and RAM R/W schedule, exact next-valid gaps and read count',
                'all eight states and22 immediate reset contexts followed by complete two-object fresh recovery',
                'full-depth maximum reverse writes and ordered replay, six invalid-static rejections, offline default wrapper'])
        plan_path.write_bytes(encoded(plan));print('FROZEN_BEFORE_RTL',sha(plan_path.read_bytes()));return
    assert action in [[],['--seal-source']]
    plan=json.loads(plan_path.read_text());assert plan['profiles']==list(map(list,PROFILES)) and plan['invalid_parameters']==list(map(list,INVALID))
    assert plan['reset_targets']==RESET_TARGETS and plan['child_timeout_seconds']==20 and plan['qualified_child_records']==18
    assert all(plan['frozen_vectors']['/'.join(map(str,p))]==frozen(m) for p,m in models)
    if action==['--seal-source']:
        if seal_path.exists():assert receipt.exists() and prior.get('failure') and (ROOT/'history').exists()
        seal=dict(test_plan_sha256=sha(plan_path.read_bytes()),before_first_hdl_tool=not receipt.exists(),
                  qualification_attempt=1+len(list((ROOT/'history').glob('attempt_*'))),source_sha256=hashes(False))
        seal_path.write_bytes(encoded(seal));print('SOURCE_SEALED',sha(seal_path.read_bytes()));return
    seal=json.loads(seal_path.read_text());assert seal['test_plan_sha256']==sha(plan_path.read_bytes()) and seal['source_sha256']==hashes(False)
    initial=hashes();report=dict(baseline_commit=plan['baseline_commit'],status=['NOT_RUN','HW_UNVERIFIED'],source_sha256=initial,
        test_plan_sha256=sha(plan_path.read_bytes()),source_freeze_sha256=sha(seal_path.read_bytes()),profiles=[],commands=[],
        remaining_profiles=PROFILES.copy(),timeout_occurred=False,not_run=NOT_RUN)
    def save():receipt.write_bytes(encoded(report))
    save();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')]);iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    temporary=tempfile.TemporaryDirectory(prefix='anscore_b22_sparse_');work=Path(temporary.name)
    def run(argv,cwd,negative=False):
        argv=list(map(str,argv))
        try:r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            report['timeout_occurred']=True;decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else x or ''
            report['commands'].append(dict(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=decode(error.stdout),stderr=decode(error.stderr)));save();raise
        good=(r.returncode>0 and 'ram_sparse_assembler_invalid_parameters__see_README' in r.stderr) if negative else r.returncode==0 and not r.stderr
        report['commands'].append(dict(argv=argv,status='PASS' if good else 'FAIL',returncode=r.returncode,timeout_seconds=20,stdout=r.stdout,stderr=r.stderr));save();assert good,report['commands'][-1]
        return r.stdout
    def archive():
        history=ROOT/'history';history.mkdir(exist_ok=True);dest=history/f'attempt_{len(list(history.glob("attempt_*")))+1:03d}';dest.mkdir()
        (dest/'verification.json').write_bytes(receipt.read_bytes())
        for name in initial:
            target=dest/'tested_source'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/name).read_bytes())
        artifacts=dest/'artifacts';artifacts.mkdir()
        for name in ['input.hex','actual.txt']:
            if (work/name).exists():shutil.copyfile(work/name,artifacts/name)
    try:
        for name in initial:
            raw=(ROOT/name).read_bytes();raw.decode('utf-8','strict');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
        run([iv,'-V'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','ram_sparse_assembler','-s','sparse_object64','-f','example/files.f'],ROOT)
        for p,m in models:
            n,d,t=p;(work/'input.hex').write_bytes(m['input_bytes']);report['current_profile']=list(p);save()
            run([iv,'-g2012','-Wall','-s','tb_ram_sparse_assembler',f'-Ptb_ram_sparse_assembler.N={n}',
                f'-Ptb_ram_sparse_assembler.D={d}',f'-Ptb_ram_sparse_assembler.T={t}','-o','sim.vvp',ROOT/'rtl/ram_sparse_assembler.sv',ROOT/'sim/tb_ram_sparse_assembler.sv'],work)
            stdout=run([vv,'sim.vvp',f'+INPUT={work/"input.hex"}',f'+OUTPUT={work/"actual.txt"}',f'+COUNT={len(m["commands"])}',f'+OUTS={len(m["outputs"])}'],work)
            match=re.fullmatch(r'PASS sparse commands=(\d+) outputs=(\d+) first_checks=(\d+) cycles=(\d+) command_holds=(\d+) output_holds=(\d+) reads=(\d+) writes=(\d+) resets=(\d+) recovery=(\d+) max_latency=(\d+) states=ff\n.*',stdout,re.S)
            assert match,stdout;values=list(map(int,match.groups()));assert values[:3]==[len(m['commands']),len(m['outputs']),len(m['commands'])]
            assert values[8:11]==[22,22*(min(n,3)+9),2] and all(values[i]>0 for i in range(3,8))
            names=['accepted_commands','output_tokens','first_valid_checks','trace_nonreset_cycles','command_hold_checks','output_hold_checks',
                   'ram_reads','ram_writes','reset_probes','fresh_recovery_commands','observed_maximum_latency']
            item=dict(zip(names,values));item.update(dict(zip(plan['profile_fields'],p)),status='PASS',**frozen(m),**verify(work/'actual.txt',m,p),coverage=m['coverage']);item['output']=stdout.strip()
            report['profiles'].append(item);report['remaining_profiles'].pop(0);report.pop('current_profile');save();print(f'PASS sparse N={n} D={d} commands={len(m["commands"])}',flush=True)
        for key,value in INVALID:run([iv,'-g2012','-tnull','-s','ram_sparse_assembler',f'-Pram_sparse_assembler.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes() and len(report['commands'])==18
        keys=['accepted_commands','output_tokens','first_valid_checks','trace_nonreset_cycles','command_hold_checks','output_hold_checks',
              'ram_reads','ram_writes','reset_probes','fresh_recovery_commands','checked_outputs','complete_payload_row_checks',
              'exact_latency_checks','exact_first_ram_schedule_checks','exact_fragment_gap_checks']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=6,
            totals={key:sum(p[key] for p in report['profiles']) for key in keys},
            oracle='One independent sparse dictionary retains the first accepted value at each numeric offset. Complete publication sorts its keys; no payload read pipeline, validity bitmap mutation or output state machine is modeled.',
            counter_scope='Main responses/images/latencies/RAM-schedule checks are main-only; cycles, holds and RAM totals include all nonreset main/probe/fresh activity.')
        save();print('PASS sparse profiles=5 children=18',flush=True)
    except BaseException as error:
        report.update(status=['NOT_RUN','HW_UNVERIFIED'],failure=repr(error));save();archive();raise
    finally:temporary.cleanup()


if __name__=='__main__':main()
