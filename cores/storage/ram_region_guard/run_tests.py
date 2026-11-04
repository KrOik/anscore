#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Freeze full finite semantics before RTL, then bind all pre-HDL sources."""
from collections import Counter
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
import time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
BASELINE='20e2db4aded8858ff63e132c2399fb416aa48ed0'
PROFILES=[(1,1,1),(8,3,3),(17,5,8),(32,16,8),(64,64,32)]
INVALID=[(key,value) for key,upper in [('ADDR_W',64),('SLOTS',64),('TAG_W',32)] for value in [0,upper+1]]
TARGETS=['idle','pending_set','get_read','get_check','first_check_read','first_check_compare',
    'later_check_read','later_check_compare','held_new_set','held_replacement_set','held_get',
    'held_allow','held_deny_partial','held_deny_permission','held_deny_unmapped','held_delete',
    'held_clear','held_bad_access','held_bad_range','held_bad_slot','held_bad_op','held_status']
NOT_RUN=['synthesis','PnR','STA','board','expanded regression','inherited matrix']
U32=(1<<32)-1;U64=(1<<64)-1;U65=(1<<65)-1


def encoded(obj):return (json.dumps(obj,sort_keys=True,indent=2)+'\n').encode('utf-8')


def sha(raw):return hashlib.sha256(raw).hexdigest()


def pack(items):
    result=0
    for value,width in items:
        assert 0<=value<1<<width
        result=(result<<width)|value
    return result


def fixtures(a,s,t):
    commands=[];limit=1<<a
    def add(op,slot=0,base=0,length=0,perm=0,access=0):
        assert 0<=slot<=U32 and 0<=base<=U64 and 0<=length<=U65
        tag=(1<<t)-1 if len(commands)%11==0 else (37*len(commands)+13)&((1<<t)-1)
        commands.append((op,slot,base,length,perm,access,tag))
    add(4);add(5);add(0,length=1,access=1);add(3);add(2)
    for op in [6,7]:add(op,U32,U64,U65,7,7)
    for bit in range(32):
        slot=1<<bit
        add(1,slot,0,1,7);add(3,slot,U64,U65,7,7);add(2,slot,U64,U65,7,7)
    for bit in range(64):
        base=1<<bit
        add(1,0,base,1,7);add(0,U32,base,1,0,7);add(3);add(2)
    for bit in range(65):
        length=1<<bit
        add(1,0,0,length,7);add(0,U32,0,length,0,1);add(3);add(2)
    for base,length in [(0,0),(U64,0),(0,U65),(U64,U65),(limit-1,2),(U64,1)]:
        add(1,0,base,length,7);add(0,U32,base,length,0,7)
    add(1,0,0,limit,7)
    for base,length in [(0,1),(limit-1,1),(0,limit)]:add(0,U32,base,length,0,7)
    add(0,0,0,0,0,0);add(0,0,0,1,0,0);add(3,0,U64,U65,7,7)
    for perm in range(8):
        add(1,0,0,limit,perm)
        for access in range(8):add(0,U32,0,limit,7,access)
        add(3,0,U64,U65,7,7)
    add(4)
    for slot in range(s-1,-1,-1):add(1,slot,slot%limit,1,1<<(slot%3))
    for slot in range(s):add(3,slot,U64,U65,7,7)
    add(5,U32,U64,U65,7,7);add(0,length=1,access=1)
    add(1,0,0,limit,7);add(0,length=limit,access=7)
    for slot in range(s-1,-1,-1):add(2,slot,U64,U65,7,7)
    add(4);add(1,s-1,0,limit,7);add(0,length=limit,access=7)
    add(1,0,0,1,1)
    add(0,length=2,access=1);add(0,length=1,access=2);add(0,base=limit-1,length=1,access=7)
    add(1,0,0,1,0);add(0,length=1,access=1);add(2);add(0,length=1,access=1)
    if s>1:
        add(4);add(1,0,0,1,1);add(1,1,1,1,1)
        add(0,length=2,access=1);add(0,base=1,length=1,access=1)
        add(1,0,0,limit,0);add(0,base=1,length=1,access=1)
        add(2);add(0,base=1,length=1,access=1)
    add(4);add(1,s-1,limit-1,1,4);add(0,base=limit-1,length=1,access=4)
    add(0,base=0,length=1,access=1);add(3,s-1)
    # Errors on a live entry must leave its old range/permission intact.
    for slot,base,length in [(0,0,0),(s,0,1),(0,limit-1,2),(U32,U64,U65)]:
        add(1,slot,base,length,0);add(3,s-1);add(5)
    if s==1:
        alphabet=[(1,0,0,1,1,0),(1,0,0,limit,7,0),(2,0,0,0,0,0),(3,0,0,0,0,0),
                  (0,0,0,1,0,1),(0,0,0,limit,0,2),(0,0,0,1,0,0),(4,0,0,0,0,0),(7,0,0,0,0,0)]
        for stream in itertools.product(alphabet,repeat=3):
            add(4)
            for item in stream:add(*item)
    rng=random.Random(0xB230A+131*a+17*s+t)
    for _ in range(600):
        add(rng.choice([0,0,0,1,1,2,3,4,5,6,7]),rng.choice([0,s-1,s,U32,1<<31,rng.randrange(s)]),
            rng.choice([0,limit-1,U64,rng.randrange(limit)]),rng.choice([0,1,2,limit,U65,rng.randrange(min(limit,1024)+1)]),
            rng.randrange(8),rng.randrange(8))
    add(4,U32,U64,U65,7,7);add(5,U32,U64,U65,7,7)
    return commands


def rights(bits):return {name for bit,name in enumerate(['R','W','X']) if bits&(1<<bit)}


def model(profile):
    a,s,t=profile;limit=1<<a;cw=s.bit_length();rules={};outputs=[];timing=[];coverage=Counter()
    fields=[('op',3),('status',4),('tag',t),('allow',1),('found',1),('slot',32),
            ('base',a),('length',a+1),('perm',3),('count',cw)]
    commands=fixtures(*profile)
    for op,slot,base,length,perm,access,tag in commands:
        status=0;selected=None;latency=reads=writes=0
        valid_range=length>0 and base<limit and base+length<=limit
        if op>5:status=4
        elif op in [1,2,3] and slot>=s:status=5
        elif op in [0,1] and not valid_range:status=6
        elif op==0 and access==0:status=7
        elif op==0:
            request=(base,base+length)
            hits=[key for key,(lo,hi,_) in rules.items() if max(lo,request[0])<min(hi,request[1])]
            selected=min(hits) if hits else None
            last=selected if selected is not None else s-1
            latency=2*(last+1);reads=sum(key<=last for key in rules)
            if selected is None:status=1
            else:
                lo,hi,p=rules[selected]
                if request[0]<lo or request[1]>hi:status=2
                elif not rights(access)<=rights(p):status=3
            if a<=8:
                byte_request=set(range(*request));byte_hits=[key for key,(lo,hi,_) in rules.items() if byte_request&set(range(lo,hi))]
                byte_slot=min(byte_hits) if byte_hits else None;byte_status=1
                if byte_slot is not None:
                    lo,hi,p=rules[byte_slot]
                    byte_status=2 if not byte_request<=set(range(lo,hi)) else (0 if rights(access)<=rights(p) else 3)
                assert (selected,status)==(byte_slot,byte_status);coverage['independent_byte_set_checks']+=1
            coverage['partial_denials']+=status==2;coverage['permission_denials']+=status==3
            coverage['multiple_intersections']+=len(hits)>1
            coverage['later_slot_decisions']+=selected is not None and selected>0
        elif op==1:
            coverage['replacements']+=slot in rules
            rules[slot]=(base,base+length,perm);selected=slot;latency=1;writes=1
        elif op==2:
            if slot in rules:del rules[slot]
            else:status=8
        elif op==3:
            if slot not in rules:status=8
            else:selected=slot;latency=2;reads=1
        elif op==4:rules={}
        record=dict(op=op,status=status,tag=tag,allow=int(op==0 and status==0),found=int(selected is not None),
                    slot=selected if selected is not None else 0,base=0,length=0,perm=0,count=len(rules))
        if selected is not None:
            lo,hi,p=rules[selected];record.update(base=lo,length=hi-lo,perm=p)
        bitmap=sum(1<<key for key in rules);image=[0]*s
        for key,(lo,hi,p) in rules.items():image[key]=pack([(lo,a),(hi-1,a),(p,3)])
        outputs.append((record,len(rules),bitmap,image));timing.append((latency,reads,writes))
        coverage[f'op_{op}']+=1;coverage[f'status_{status}']+=1;coverage['set_writes']+=writes
        coverage['full_space_rules']+=op==1 and status==0 and base==0 and length==limit
    assert all(coverage[f'op_{op}'] for op in range(8)) and all(coverage[f'status_{status}'] for status in range(9))
    assert coverage['full_space_rules'] and coverage['partial_denials'] and coverage['permission_denials']
    assert len(commands)<30001
    raw=('\n'.join(f'{pack([(op,3),(slot,32),(base,64),(length,65),(perm,3),(access,3),(tag,t)]):x}' for op,slot,base,length,perm,access,tag in commands)+'\n').encode()
    return dict(commands=commands,outputs=outputs,timing=timing,fields=fields,input_bytes=raw,coverage=coverage)


def frozen(m):return dict(commands=len(m['commands']),outputs=len(m['outputs']),input_sha256=sha(m['input_bytes']),
    oracle_sha256=sha(encoded([m['outputs'],m['timing']])),byte_set_checks=m['coverage']['independent_byte_set_checks'])


def hashes(include_seal=True):
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.name!='verification.json' and (include_seal or p.name!='SOURCE_FREEZE.json')
            and 'history' not in p.relative_to(ROOT).parts}


def verify(path,m):
    actual=[];timing=[];rows=0
    for line in path.read_text(encoding='ascii').splitlines():
        item=line.split()
        if item[0]=='F':
            index,latency,reads,writes=map(int,item[1:]);assert index==len(timing)
            assert (latency,reads,writes)==m['timing'][index],(index,item,m['timing'][index]);timing.append((latency,reads,writes))
        else:
            assert item[0]=='O';word=int(item[1],16);record={}
            for key,width in reversed(m['fields']):record[key]=word&((1<<width)-1);word>>=width
            assert word==0;image=[int(value,16) for value in item[4:]];rows+=len(image)
            actual.append((record,int(item[2]),int(item[3],16),image))
    assert actual==m['outputs'],next(((i,x,y) for i,(x,y) in enumerate(zip(actual,m['outputs'])) if x!=y),('lengths',len(actual),len(m['outputs'])))
    assert timing==m['timing']
    return dict(checked_outputs=len(actual),complete_owned_row_checks=rows,exact_latency_checks=len(timing),
                exact_ram_schedule_checks=len(timing),trace_sha256=sha(path.read_bytes()))


def main():
    action=sys.argv[1:];plan_path=ROOT/'TEST_PLAN.json';seal_path=ROOT/'SOURCE_FREEZE.json';receipt=ROOT/'verification.json'
    assert action in [[],['--freeze'],['--seal-source']]
    if receipt.exists():raise RuntimeError('No automatic retry or reseal: preserve evidence and obtain root authorization; any timeout is terminal')
    models=[(p,model(p)) for p in PROFILES]
    children=['version','combined core/default wrapper syntax']+[f'A{a}/S{s}/T{t}: {mode}' for a,s,t in PROFILES for mode in ['compile','simulation']]+[f'reject {key}={value}' for key,value in INVALID]
    if action==['--freeze']:
        assert not plan_path.exists() and not seal_path.exists() and not list(ROOT.rglob('*.sv')) and not list(ROOT.rglob('*.v'))
        plan=dict(baseline_commit=BASELINE,frozen_before_rtl_implementation=True,profile_fields=['ADDR_W','SLOTS','TAG_W'],profiles=PROFILES,
            invalid_parameters=INVALID,child_timeout_seconds=20,children=children,planned_child_records=18,reset_targets=TARGETS,
            singleton_aliases={'later_check_read':'first_check_read','later_check_compare':'first_check_compare'},
            fresh_recovery_commands_each_probe=20,frozen_vectors={'/'.join(map(str,p)):frozen(m) for p,m in models},not_run=NOT_RUN,
            semantics={'ops':['CHECK','SET','DELETE','GET','CLEAR','STATUS','BAD_OP','BAD_OP'],
                'statuses':['OK','DENY_UNMAPPED','DENY_PARTIAL','DENY_PERMISSION','BAD_OP','BAD_SLOT','BAD_RANGE','BAD_ACCESS','NOT_FOUND'],
                'range':'unsigned64 base, unsigned65 positive byte count; full66 sum <=2^ADDR_W and base<2^ADDR_W, checked before narrowing',
                'priority':'lowest live slot intersecting ANY requested byte decides; require whole range containment before R/W/X permission-set inclusion; no cross-rule union',
                'errors':'bad op first; SET slot before range; CHECK range before zero access; zero-permission rule legal; ignored fields unrestricted',
                'ownership':'one command until held single ACK retires; SET/DELETE/CLEAR mutate before valid; reset immediately gates interfaces then clears live/count; unreset RAM/read data hidden',
                'descriptors':'SET/GET and every intersecting CHECK return found1 plus exact rule/slot even on partial or permission denial; all other descriptors and allow are canonical zero',
                'clocks':'SET1, liveGET2, CHECK at intersecting slot i2*(i+1) else2*S; all others0; actual owned read count plus SET-only write count'} ,
            checks=['independent unbounded half-open dictionary/permission sets plus actual byte-set oracle for A<=8',
                'every output bit, count/live bitmap and all owned rows after each response; invariants and registered read values every active edge',
                'all64 base/all65 length/all32 slot bits, whole-space and final byte, all permission pairs, errors and ignored fields',
                'full live table, replacement, overlapping and adjacent priority rules, partial denial, no permission stitching, singleton729 triples,600 deterministic commands',
                'actual next frozen command remains held through real acceptance; every output stalled and stable',
                'every exact first-valid and owned RAM R/W schedule; all5 states and22 immediate reset contexts with20-command fresh policy recovery'])
        plan_path.write_bytes(encoded(plan));print('FROZEN_BEFORE_RTL',sha(plan_path.read_bytes()));return
    plan=json.loads(plan_path.read_text());assert plan['profiles']==list(map(list,PROFILES)) and plan['invalid_parameters']==list(map(list,INVALID))
    assert plan['reset_targets']==TARGETS and plan['children']==children and plan['child_timeout_seconds']==20
    assert all(plan['frozen_vectors']['/'.join(map(str,p))]==frozen(m) for p,m in models)
    if action==['--seal-source']:
        assert not seal_path.exists()
        seal_path.write_bytes(encoded(dict(before_first_hdl_tool=True,test_plan_sha256=sha(plan_path.read_bytes()),source_sha256=hashes(False))))
        print('SOURCE_SEALED',sha(seal_path.read_bytes()));return
    seal=json.loads(seal_path.read_text());assert seal['before_first_hdl_tool'] and seal['test_plan_sha256']==sha(plan_path.read_bytes()) and seal['source_sha256']==hashes(False)
    initial=hashes();report=dict(baseline_commit=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],test_plan_sha256=sha(plan_path.read_bytes()),
        source_freeze_sha256=sha(seal_path.read_bytes()),source_sha256=initial,timeout_occurred=False,profiles=[],not_run=NOT_RUN,
        commands=[dict(name=name,status='NOT_RUN') for name in children]);index=0
    def save():receipt.write_bytes(encoded(report))
    save();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ)
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')]);iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH'])
    temporary=tempfile.TemporaryDirectory(prefix='anscore_b23_region_');work=Path(temporary.name)
    def child(argv,cwd,negative=False):
        nonlocal index
        position=index;index+=1;argv=list(map(str,argv));start=time.perf_counter()
        try:r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else x or ''
            report['commands'][position].update(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=decode(error.stdout),stderr=decode(error.stderr),elapsed_seconds=time.perf_counter()-start)
            report['timeout_occurred']=True;save();raise
        good=(r.returncode>0 and 'ram_region_guard_invalid_parameters__see_README' in r.stderr) if negative else r.returncode==0 and not r.stderr
        report['commands'][position].update(argv=argv,status=('EXPECTED_REJECT' if negative else 'PASS') if good else 'FAIL',returncode=r.returncode,
            timeout_seconds=20,elapsed_seconds=time.perf_counter()-start,stdout=r.stdout,stderr=r.stderr);save();assert good,report['commands'][position]
        return r.stdout
    try:
        assert iv and vv
        for name in initial:
            raw=(ROOT/name).read_bytes();raw.decode('utf-8','strict');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
        child([iv,'-V'],ROOT)
        child([iv,'-g2012','-Wall','-tnull','-s','ram_region_guard','-s','region_policy16','-f','example/files.f'],ROOT)
        for p,m in models:
            a,s,t=p;(work/'input.hex').write_bytes(m['input_bytes']);report['current_profile']=p;save()
            child([iv,'-g2012','-Wall','-s','tb_ram_region_guard',f'-Ptb_ram_region_guard.A={a}',f'-Ptb_ram_region_guard.S={s}',
                f'-Ptb_ram_region_guard.T={t}','-o','sim.vvp',ROOT/'rtl/ram_region_guard.sv',ROOT/'sim/tb_ram_region_guard.sv'],work)
            stdout=child([vv,'sim.vvp',f'+INPUT={work/"input.hex"}',f'+OUTPUT={work/"actual.txt"}',f'+COUNT={len(m["commands"])}'],work)
            match=re.fullmatch(r'PASS region commands=(\d+) outputs=(\d+) first_checks=(\d+) cycles=(\d+) command_holds=(\d+) output_holds=(\d+) reads=(\d+) writes=(\d+) resets=(\d+) recovery=(\d+) max_latency=(\d+) states=1f\n.*',stdout,re.S)
            assert match,stdout;values=list(map(int,match.groups()))
            assert values[:3]==[len(m['commands'])]*3 and values[8:11]==[22,440,2*s] and all(values[i]>0 for i in range(3,8))
            names=['accepted_commands','output_tokens','first_valid_checks','nonreset_cycles','command_hold_checks','output_hold_checks',
                   'ram_reads','ram_writes','reset_probes','fresh_recovery_commands','observed_maximum_latency']
            item=dict(zip(names,values));item.update(dict(zip(plan['profile_fields'],p)),status='PASS',**frozen(m),**verify(work/'actual.txt',m),coverage=m['coverage']);item['output']=stdout.strip()
            report['profiles'].append(item);report.pop('current_profile');save();print(f'PASS region A={a} S={s} commands={len(m["commands"])}',flush=True)
        for key,value in INVALID:child([iv,'-g2012','-tnull','-s','ram_region_guard',f'-Pram_region_guard.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes() and index==18
        keys=['accepted_commands','output_tokens','first_valid_checks','nonreset_cycles','command_hold_checks','output_hold_checks','ram_reads',
              'ram_writes','reset_probes','fresh_recovery_commands','checked_outputs','complete_owned_row_checks','exact_latency_checks','exact_ram_schedule_checks','byte_set_checks']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],totals={key:sum(x[key] for x in report['profiles']) for key in keys},
            oracle='Plain dictionary of half-open integer ranges and R/W/X sets. The minimum intersecting slot controls whole-range containment and permission inclusion; small addresses are independently expanded into actual byte sets. No hardware pipeline is modeled.',
            counter_scope='Output/image/latency/RAM schedule checks and byte-set comparisons are main-only; cycles/holds/RAM activity include main, reset setup and fresh recovery.')
        save();print('PASS region profiles=5 children=18',flush=True)
    except BaseException as error:
        report['failure']=repr(error);save()
        originals={name:dict(sha256=sha((ROOT/name).read_bytes()),text=(ROOT/name).read_text(encoding='utf-8')) for name in [*initial,'verification.json']}
        artifacts={name:dict(sha256=sha((work/name).read_bytes()),text=(work/name).read_text(encoding='ascii')) for name in ['input.hex','actual.txt'] if (work/name).exists()}
        history=ROOT/'history';history.mkdir(exist_ok=True);dest=history/'attempt_001.json';assert not dest.exists()
        dest.write_bytes(encoded(dict(original_files=originals,artifacts=artifacts,terminal_timeout=report['timeout_occurred'],root_authorization_required_before_any_same_matrix_repair=True)))
        raise
    finally:temporary.cleanup()


if __name__=='__main__':main()
