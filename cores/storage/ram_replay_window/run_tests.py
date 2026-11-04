#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite qualification; independent sets of received sequence values."""
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
PROFILES=[(1,1,1),(3,3,3),(7,17,8),(16,64,8),(64,256,32)]
INVALID=[(key,value) for key,upper in [('CONTEXTS',64),('WINDOW_BITS',256),('TAG_W',32)] for value in [0,upper+1]]
NOT_RUN=['synthesis','PnR','STA','board','expanded regression']
U64=(1<<64)-1
U32=(1<<32)-1


def sha(data):return hashlib.sha256(data).hexdigest()


def encoded(obj):return (json.dumps(obj,sort_keys=True,indent=2)+'\n').encode()


def pack(fields):
    value=0
    for word,width in fields:
        assert 0<=word<1<<width
        value=value<<width|word
    return value


def fixtures(n,w,t):
    commands=[]
    def add(op,ctx=0,seq=0):
        assert 0<=seq<=U64 and 0<=ctx<=U32
        commands.append((op,ctx,seq,(len(commands)*37+11)&((1<<t)-1)))
    add(3,U32,U64);add(1,0,0)
    for ctx in range(n):
        seq=(ctx<<32)|ctx
        add(0,ctx,seq);add(1,ctx,seq);add(1,ctx,seq+1);add(1,ctx,seq)
    add(3)
    center=4*w+20;add(0,0,center)
    for age in range(w+2,-1,-1):add(0,0,center-age)
    for age in range(w+3):add(1,0,center-age)
    for gap in range(w+2):
        add(2);add(0,0,1000);add(1,0,1000+gap);add(0,0,1000+gap)
        add(1,0,1000);add(0,0,999+gap)
    for bit in range(64):
        value=1<<bit
        add(2);add(0,0,value);add(0,0,value-1);add(1,0,U64)
        add(0,0,U64);add(1,0,value);add(0,0,0);add(1,0,U64)
    add(3)
    for ctx in range(n):add(0,ctx,U64-ctx)
    for ctx in range(n):
        add(2,ctx,U64);add(1,ctx,U64-ctx)
        add(1,(ctx+1)%n,U64-(ctx+1)%n)
    for ctx in sorted({n,n+1,1<<16,1<<31,U32}):
        for op in range(8):add(op,ctx,U64)
    for op in range(4,8):add(op,0,0)
    if n==1:
        alphabet=[(0,0,0),(0,0,1),(1,0,0),(1,0,1),(2,0,0)]
        for stream in itertools.product(alphabet,repeat=3):
            add(3)
            for op,ctx,seq in stream:add(op,ctx,seq)
    rng=random.Random(0xB210A+n*123+w+t)
    for i in range(600):
        op=rng.choice([0,0,0,1,1,2,3,4,7]);ctx=rng.choice([rng.randrange(n),n,U32])
        seq=rng.choice([0,1,w-1,w,w+1,U64,U64-1,rng.getrandbits(64),rng.randrange(4*w+1)])
        add(op,ctx,seq)
    add(3);add(1);add(0,0,U64);add(1,0,U64);add(3,U32,U64)
    return commands


def model(profile):
    n,w,t=profile;table={};outputs=[];timing=[];coverage=collections.Counter()
    commands=fixtures(*profile)
    fields=[('op',3),('status',3),('context',32),('sequence',64),('tag',t),
            ('accepted',1),('marked',1),('active',1),('head',64),('seen',w)]
    for op,ctx,seq,tag in commands:
        status=0;marked=0;reads=0;active=0;head=0;bitmap=0;latency=0
        if op>3:status=7
        elif op==3:table.clear();status=5
        elif ctx>=n:status=6
        elif op==2:table.pop(ctx,None);status=5
        else:
            reads=1;old=table.get(ctx,set())
            if not old:status=0
            else:
                maximum=max(old)
                if seq>maximum:status=1
                elif seq<maximum-w+1:status=4
                elif seq in old:status=3
                else:status=2
            if op==0 and status<3:
                # This oracle stores actual accepted integers, never an aging
                # bitmap or shift. It removes values outside the numeric set.
                chosen=old|{seq};maximum=max(chosen)
                table[ctx]={value for value in chosen if value>=maximum-w+1};marked=1
            selected=table.get(ctx,set());active=int(bool(selected))
            if selected:
                head=max(selected);bitmap=sum(1<<(head-value) for value in selected)
            latency=3 if marked else 2
        accepted=int(op<2 and status<3)
        record=dict(op=op,status=status,context=ctx,sequence=seq,tag=tag,accepted=accepted,
                    marked=marked,active=active,head=head,seen=bitmap)
        live=sum(1<<key for key in table);snapshot=[]
        for key in range(n):
            values=table.get(key,set())
            snapshot.append((max(values)<<w|sum(1<<(max(values)-v) for v in values)) if values else 0)
        outputs.append((record,live,snapshot));timing.append((latency,reads,marked))
        coverage[f'op_{op}']+=1;coverage[f'status_{status}']+=1
        coverage['marked']+=marked;coverage['peek']+=op==1 and ctx<n
        coverage['active_contexts_seen']|=live
        coverage['sequence_top']+=seq==U64;coverage['sequence_zero']+=seq==0
    assert all(coverage[f'op_{op}'] for op in range(8))
    assert all(coverage[f'status_{s}'] for s in range(8) if w>1 or s!=2)
    assert coverage['active_contexts_seen']==(1<<n)-1
    data=('\n'.join(f'{pack([(op,3),(ctx,32),(seq,64),(tag,t)]):x}' for op,ctx,seq,tag in commands)+'\n').encode()
    return dict(commands=commands,outputs=outputs,timing=timing,fields=fields,input_bytes=data,coverage=coverage)


def frozen(m):return dict(commands=len(m['commands']),input_sha256=sha(m['input_bytes']),oracle_sha256=sha(encoded([m['outputs'],m['timing']])))


def hashes():
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name!='verification.json' and 'history' not in p.relative_to(ROOT).parts}


def verify(path,m,profile):
    actual=[];timing=[];rows=0
    for line in path.read_text(encoding='ascii').splitlines():
        values=line.split()
        if values[0]=='F':
            index,latency,reads,writes=map(int,values[1:]);assert index==len(timing)
            assert (latency,reads,writes)==m['timing'][index],(index,values,m['timing'][index])
            timing.append((latency,reads,writes))
        else:
            assert values[0]=='O';word=int(values[1],16);record={}
            for key,width in reversed(m['fields']):record[key]=word&((1<<width)-1);word>>=width
            assert word==0;snapshot=[int(value,16) for value in values[3:]];rows+=len(snapshot)
            actual.append((record,int(values[2],16),snapshot))
    assert actual==m['outputs'],next(((i,x,y) for i,(x,y) in enumerate(zip(actual,m['outputs'])) if x!=y),('lengths',len(actual),len(m['outputs'])))
    assert timing==m['timing']
    return dict(checked_outputs=len(actual),complete_context_row_checks=rows,exact_latency_checks=len(timing),
                exact_ram_schedule_checks=len(timing),maximum_latency=max(v[0] for v in timing),trace_sha256=sha(path.read_bytes()))


def main():
    plan_path=ROOT/'TEST_PLAN.json';receipt=ROOT/'verification.json';models=[(p,model(p)) for p in PROFILES]
    if sys.argv[1:]==['--freeze']:
        assert not plan_path.exists() and not receipt.exists()
        plan=dict(baseline_commit='ed4eda4fe213da6f6fec793ef911daaabfeba2cc',frozen_before_first_hdl_tool=True,
            profile_fields=['CONTEXTS','WINDOW_BITS','TAG_W'],profiles=PROFILES,invalid_parameters=INVALID,
            child_timeout_seconds=20,qualified_child_records=18,reset_probes_each_profile=16,fresh_commands_each_probe=6,
            frozen_vectors={'/'.join(map(str,p)):frozen(m) for p,m in models},not_run=NOT_RUN,
            checks=['independent unbounded integer-set oracle, no bitmap shifts or RTL controller',
                'every public response field and complete valid context RAM images after every command',
                'all64 sequence bits including unsigned top; W1/nonpower/max, every shift distance through W+1',
                'all statuses/ops, context isolation, nonmutating PEEK, clear/reuse and full32 context before narrowing',
                'real next frozen command held through actual handshake; every result held under backpressure',
                'exact first-valid edge and exact synchronous RAM read/write counts',
                'all five states and sixteen immediate reset boundaries with complete six-command fresh recovery',
                'six named invalid-static rejections and complete offline default wrapper'],pre_hdl_source_sha256=hashes())
        plan_path.write_bytes(encoded(plan));print('FROZEN',sha(plan_path.read_bytes()));return
    assert not sys.argv[1:]
    prior=json.loads(receipt.read_text()) if receipt.exists() else {}
    if prior.get('timeout_occurred'):raise RuntimeError('Terminal timeout; no retry, fixture shrink or larger limit')
    if 'UNIT_SIM_PASS' in prior.get('status',[]):raise RuntimeError('Successful frozen matrix must not be rerun')
    plan=json.loads(plan_path.read_text());assert plan['profiles']==list(map(list,PROFILES)) and plan['invalid_parameters']==list(map(list,INVALID))
    assert plan['child_timeout_seconds']==20 and plan['qualified_child_records']==18
    assert all(plan['frozen_vectors']['/'.join(map(str,p))]==frozen(m) for p,m in models)
    initial=hashes();report=dict(baseline_commit=plan['baseline_commit'],status=['NOT_RUN','HW_UNVERIFIED'],
        source_sha256=initial,profiles=[],commands=[],remaining_profiles=PROFILES.copy(),timeout_occurred=False,not_run=NOT_RUN)
    def save():receipt.write_bytes(encoded(report))
    save();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')]);iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    temporary=tempfile.TemporaryDirectory(prefix='anscore_b21_replay_');work=Path(temporary.name)
    def run(argv,cwd,negative=False):
        argv=list(map(str,argv))
        try:r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            report['timeout_occurred']=True;decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else x or ''
            report['commands'].append(dict(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=decode(error.stdout),stderr=decode(error.stderr)));save();raise
        good=(r.returncode>0 and 'ram_replay_window_invalid_parameters__see_README' in r.stderr) if negative else r.returncode==0 and not r.stderr
        report['commands'].append(dict(argv=argv,status='PASS' if good else 'FAIL',returncode=r.returncode,timeout_seconds=20,stdout=r.stdout,stderr=r.stderr));save();assert good,report['commands'][-1]
        return r.stdout
    def archive():
        history=ROOT/'history';history.mkdir(exist_ok=True);dest=history/f'attempt_{len(list(history.glob("attempt_*")))+1:03d}';dest.mkdir()
        (dest/'verification.json').write_bytes(receipt.read_bytes())
        for name in initial:
            target=dest/'tested_source'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/name).read_bytes())
        shutil.copytree(work,dest/'artifacts')
    try:
        for name in initial:
            raw=(ROOT/name).read_bytes();raw.decode('utf-8','strict');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
        run([iv,'-V'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','ram_replay_window','-s','sequence_contexts16','-f','example/files.f'],ROOT)
        for p,m in models:
            n,w,t=p;(work/'input.hex').write_bytes(m['input_bytes']);report['current_profile']=list(p);save()
            run([iv,'-g2012','-Wall','-s','tb_ram_replay_window',f'-Ptb_ram_replay_window.N={n}',
                f'-Ptb_ram_replay_window.W={w}',f'-Ptb_ram_replay_window.T={t}','-o','sim.vvp',ROOT/'rtl/ram_replay_window.sv',ROOT/'sim/tb_ram_replay_window.sv'],work)
            stdout=run([vv,'sim.vvp',f'+INPUT={work/"input.hex"}',f'+OUTPUT={work/"actual.txt"}',f'+COUNT={len(m["commands"])}'],work)
            match=re.fullmatch(r'PASS replay commands=(\d+) outputs=(\d+) first_checks=(\d+) cycles=(\d+) command_holds=(\d+) output_holds=(\d+) reads=(\d+) writes=(\d+) resets=(\d+) recovery=(\d+) max_latency=(\d+) states=1f\n.*',stdout,re.S)
            assert match,stdout;values=list(map(int,match.groups()));assert values[:3]==[len(m['commands'])]*3
            assert values[8:11]==[16,96,3] and all(values[i]>0 for i in range(3,8))
            names=['accepted_commands','output_tokens','first_valid_checks','trace_nonreset_cycles','command_hold_checks',
                   'output_hold_checks','ram_reads','ram_writes','reset_probes','fresh_recovery_commands','observed_maximum_latency']
            item=dict(zip(names,values));item.update(dict(zip(plan['profile_fields'],p)),status='PASS',**frozen(m),**verify(work/'actual.txt',m,p),coverage=m['coverage']);item['output']=stdout.strip()
            report['profiles'].append(item);report['remaining_profiles'].pop(0);report.pop('current_profile');save();print(f'PASS replay N={n} W={w} commands={len(m["commands"])}',flush=True)
        for key,value in INVALID:run([iv,'-g2012','-tnull','-s','ram_replay_window',f'-Pram_replay_window.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes() and len(report['commands'])==18
        keys=['accepted_commands','output_tokens','first_valid_checks','trace_nonreset_cycles','command_hold_checks','output_hold_checks',
              'ram_reads','ram_writes','reset_probes','fresh_recovery_commands','checked_outputs','complete_context_row_checks','exact_latency_checks','exact_ram_schedule_checks']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=6,
            totals={key:sum(p[key] for p in report['profiles']) for key in keys},
            oracle='Per-context sets of actual unsigned64 integers. Classify with maximum, numeric interval and membership; retain only values at least max-W+1. Returned RAM bitmaps are reconstructed from those integers without aging shifts.',
            counter_scope='Main responses/context images/latencies/schedule checks are main-only; cycles, holds and RAM access totals include all nonreset main/probe/fresh activity.')
        save();print('PASS replay profiles=5 children=18',flush=True)
    except BaseException as error:
        report.update(status=['NOT_RUN','HW_UNVERIFIED'],failure=repr(error));save();archive();raise
    finally:temporary.cleanup()


if __name__=='__main__':main()
