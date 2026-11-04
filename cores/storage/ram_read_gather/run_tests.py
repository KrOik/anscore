#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite gather tests; address-dictionary oracle, not a RAM scan model."""
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
PROFILES=[(1,1,1,1),(3,5,5,3),(7,16,16,8),(16,32,32,8),(32,64,64,32)]
INVALID=[(key,value) for key,upper in [('MAX_ITEMS',32),('ADDR_W',64),('DATA_W',64),('TAG_W',32)] for value in [0,upper+1]]
NOT_RUN=['synthesis','PnR','STA','board','expanded regression']


def sha(raw):return hashlib.sha256(raw).hexdigest()


def pack(fields):
    result=0
    for value,width in fields:
        assert 0<=value<1<<width
        result=result<<width|value
    return result


def unpack(value,fields):
    result={}
    for key,width in reversed(fields):result[key]=value&((1<<width)-1);value>>=width
    assert value==0
    return result


def fixtures(n,a,d,t):
    frames=[];am=(1<<a)-1;tm=(1<<t)-1
    def add(addresses,masked=False,bad_first=False,repeated_first=False,tail_mask=False):
        tag=(len(frames)*29+7)&tm
        tokens=[]
        if masked:tokens.append((am,tag,0,int(not bad_first),0))
        for i,address in enumerate(addresses):
            tokens.append((address&am,(tag+i*3)&tm,1,int((i==0 and not masked and not bad_first) or (i==1 and repeated_first)),0))
        if tail_mask:tokens.append((am,tm,0,int(repeated_first),0))
        if not tokens:tokens.append((am,tag,0,int(not bad_first),0))
        last=list(tokens[-1]);last[-1]=1;tokens[-1]=tuple(last);frames.append(tokens)
    add([]);add([],bad_first=True);add([],masked=True,tail_mask=True,repeated_first=True)
    add([0]);add([am]);add([am],masked=True,tail_mask=True)
    add([0],bad_first=True);add([0,am],repeated_first=True)
    add(list(range(n)));add(list(range(n-1,-1,-1)))
    add([am]*n);add([am]*(n+1));add([0]*(n+3),bad_first=True,repeated_first=True,tail_mask=True)
    add([am,0,am][:n],masked=True,tail_mask=True)
    # All words in a small address alphabet, including every equality pattern
    # to length four and intentional overcapacity on the smallest profile.
    for length in range(1,min(n+1,4)+1):
        for addresses in itertools.product(range(min(3,am+1)),repeat=length):add(addresses)
    for bit in range(a):add([0,1<<bit,am,1<<bit][:n])
    rng=random.Random(20261900+n+a+d+t)
    for i in range(96):
        length=rng.choice([0,1,n,max(1,n-1),n+1,rng.randrange(n+2)])
        pool=[0,am,1<<(a-1),rng.getrandbits(a)]
        addresses=[rng.choice(pool) if i%3 else rng.getrandbits(a) for _ in range(length)]
        add(addresses,masked=i%4==0,bad_first=i%11==0,repeated_first=i%13==0,tail_mask=i%5==0)
    # Same address on successive frames must be physically read again; the
    # memory values deliberately depend on the frame, including error changes.
    for _ in range(6):add([am]*n)
    return frames


def oracle(profile):
    n,a,d,t=profile;iw=max(1,(n-1).bit_length());cw=n.bit_length();frames=fixtures(*profile)
    tokens=[];requests=[];outputs=[];meta=[];coverage=collections.Counter();dm=(1<<d)-1
    for fi,frame in enumerate(frames):
        tokens.extend(frame);addresses=[x[0] for x in frame if x[2]]
        first_error=not frame[0][3] or any(x[3] for x in frame[1:]);overflow=len(addresses)>n
        status=(int(first_error)<<1)|(int(overflow)<<2)
        tag=frame[0][1];mapping={};ordered_unique=[];comparisons=0
        if not status and addresses:
            # The oracle's actual data/error model is an insertion-ordered
            # address dictionary. It does not simulate a prefix scan or RAM.
            for address in addresses:
                if address not in mapping:
                    error=int((address+fi)%5==0)
                    value=((address*0x9e3779b97f4a7c15)^(fi*0xd1b54a32d192ed03)^dm)&dm
                    mapping[address]=(0 if error else value,error)
                    ordered_unique.append(address);requests.append((address,value,error))
            unique=len(mapping)
            # Separate operation-count certificate for declared serial timing.
            first_positions={}
            for i,address in enumerate(addresses):
                comparisons+=i if address not in first_positions else first_positions[address]+1
                first_positions.setdefault(address,i)
            for index,address in enumerate(addresses):
                value,error=mapping[address]
                outputs.append(dict(status=0,keep=1,error=error,first=int(index==0),last=int(index==len(addresses)-1),
                                    addr=address,data=value,tag=tag,index=index,count=len(addresses),unique=unique))
            coverage['valid']+=1;coverage['duplicate_frames']+=len(mapping)<len(addresses)
            coverage['read_errors']+=sum(err for _,err in mapping.values())
            coverage['unique_reads']+=unique;coverage['reused_items']+=len(addresses)-unique
            coverage['all_unique']+=unique==len(addresses);coverage['capacity']+=len(addresses)==n
            rows=[(address<<(d+1))|(mapping[address][1]<<d)|mapping[address][0] for address in addresses]
            base=2+3*len(addresses)+2*comparisons+2*unique
        else:
            if not status:status=1
            outputs.append(dict(status=status,keep=0,error=0,first=1,last=1,addr=0,data=0,tag=tag,index=0,count=0,unique=0))
            rows=[];unique=0;base=1;comparisons=0
        coverage[f'status_{status}']+=1
        coverage['masked_tokens']+=sum(not x[2] for x in frame)
        meta.append(dict(status=status,rows=rows,comparisons=comparisons,unique=unique,base_latency=base))
    fields=[('status',3),('keep',1),('error',1),('first',1),('last',1),('addr',a),('data',d),('tag',t),('index',iw),('count',cw),('unique',cw)]
    vector=('\n'.join(f'{pack([(addr,a),(tag,t),(keep,1),(first,1),(last,1)]):x}' for addr,tag,keep,first,last in tokens)+'\n').encode()
    request=('\n'.join(f'{pack([(addr,a),(error,1),(value,d)]):x}' for addr,value,error in requests)+'\n').encode()
    return dict(frames=frames,tokens=tokens,requests=requests,outputs=outputs,meta=meta,fields=fields,
                vector=vector,request=request,coverage=coverage)


def verify(path,model,profile):
    n,a,d,t=profile;actual=[];metadata=[];rows_checked=0;max_internal=0;waits=0
    for line in path.read_text(encoding='ascii').splitlines():
        parts=line.split()
        if parts[0]=='O':actual.append(unpack(int(parts[1],16),model['fields']))
        else:
            assert parts[0]=='F'
            fi,latency,waiting,comparisons,unique=map(int,parts[1:6]);assert fi==len(metadata)
            expected=model['meta'][fi];rows=list(map(lambda x:int(x,16),parts[6:]))
            assert rows==expected['rows'],(fi,'packed rows',rows,expected['rows'])
            assert comparisons==expected['comparisons'] and unique==expected['unique'],(fi,'work counts')
            assert latency==expected['base_latency']+waiting,(fi,'exact first valid',latency,expected,waiting)
            assert latency-waiting<=n*n+4*n+2
            metadata.append((latency,waiting));rows_checked+=len(rows);max_internal=max(max_internal,latency-waiting);waits+=waiting
    assert actual==model['outputs'],next(((i,a,b) for i,(a,b) in enumerate(zip(actual,model['outputs'])) if a!=b),('length',len(actual),len(model['outputs'])))
    assert len(metadata)==len(model['frames'])
    coverage=model['coverage'];assert all(coverage[f'status_{s}'] for s in [0,1,2,4,6])
    assert coverage['read_errors'] and coverage['all_unique'] and coverage['capacity'] and coverage['masked_tokens']
    if n>1:assert coverage['duplicate_frames'] and coverage['reused_items']
    return dict(checked_outputs=len(actual),exact_latency_checks=len(metadata),packed_row_checks=rows_checked,
                maximum_internal_first_latency=max_internal,external_wait_cycles=waits,coverage=coverage,trace_sha256=sha(path.read_bytes()))


def hashes():
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name!='verification.json' and 'history' not in p.relative_to(ROOT).parts}


def frozen_entry(model):
    return dict(frames=len(model['frames']),tokens=len(model['tokens']),requests=len(model['requests']),outputs=len(model['outputs']),
                input_sha256=sha(model['vector']),request_sha256=sha(model['request']))


def main():
    plan_path=ROOT/'TEST_PLAN.json';output=ROOT/'verification.json'
    models=[(p,oracle(p)) for p in PROFILES]
    if sys.argv[1:]==['--freeze']:
        assert not plan_path.exists() and not output.exists()
        plan=dict(baseline_commit='897cf84f5861f5fada3c1a5d64127e64cdb9af92',frozen_before_first_hdl_tool=True,
                  profile_fields=['MAX_ITEMS','ADDR_W','DATA_W','TAG_W'],profiles=PROFILES,invalid_parameters=INVALID,
                  child_timeout_seconds=20,qualified_child_records=19,reset_probes_each_profile=16,recovery_frames_each_probe=2,
                  reset_semantics='Observe low boundary, assert before another active edge; both DUT and outstanding read peer cancel together. Every probe followed by two complete same-address fresh frames with distinct successful/error data and exact replay/RAM/unique-read checks.',
                  frozen_vectors={'/'.join(map(str,p)):frozen_entry(m) for p,m in models},not_run=NOT_RUN,
                  checks=['independent insertion-ordered address dictionary oracle','all fields and ordered unique requests','every computed packed RAM row',
                          'FIRST errors/overflow/masked framing/empty and every status','all request/source/response/output hold channels',
                          'actual next frozen main token preoffered and retained until acceptance','same-edge offered response held through p_ready low',
                          'exact LAST-to-first-valid internal work plus observed external wait cycles','all thirteen reachable states (SCAN states excluded at MAX_ITEMS=1)',
                          'sixteen immediate resets and thirty-two full fresh frames per profile','eight named invalid static elaborations','offline default example'],
                  pre_hdl_source_sha256=hashes())
        plan_path.write_text(json.dumps(plan,indent=2)+'\n',encoding='utf-8',newline='\n');print('FROZEN',sha(plan_path.read_bytes()));return
    assert not sys.argv[1:]
    previous=json.loads(output.read_text()) if output.exists() else {}
    if previous.get('timeout_occurred'):raise RuntimeError('Terminal timeout: no retry, fixture shrink or larger limit')
    if 'UNIT_SIM_PASS' in previous.get('status',[]):raise RuntimeError('Successful frozen matrix must not be rerun')
    plan=json.loads(plan_path.read_text());assert plan['profiles']==list(map(list,PROFILES)) and plan['invalid_parameters']==list(map(list,INVALID))
    assert plan['child_timeout_seconds']==20 and plan['qualified_child_records']==19
    assert all(plan['frozen_vectors']['/'.join(map(str,p))]==frozen_entry(m) for p,m in models)
    initial=hashes();report=dict(baseline_commit=plan['baseline_commit'],status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],
        source_sha256=initial,remaining_profiles=PROFILES.copy(),timeout_occurred=False,not_run=NOT_RUN)
    def save():output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(argv,cwd,negative=False):
        argv=list(map(str,argv))
        try:r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            report['timeout_occurred']=True
            decode=lambda v:v.decode(errors='replace') if isinstance(v,bytes) else v or ''
            report['commands'].append(dict(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=decode(error.stdout),stderr=decode(error.stderr)));save();raise
        good=(r.returncode>0 and 'ram_read_gather_invalid_parameters__see_README' in r.stderr) if negative else r.returncode==0 and not r.stderr
        report['commands'].append(dict(argv=argv,returncode=r.returncode,status='PASS' if good else 'FAIL',timeout_seconds=20,stdout=r.stdout,stderr=r.stderr));save()
        assert good,report['commands'][-1]
        return r.stdout
    def archive():
        history=ROOT/'history';history.mkdir(exist_ok=True);dest=history/f'attempt_{len(list(history.glob("attempt_*")))+1:03d}';dest.mkdir()
        (dest/'verification.json').write_bytes(output.read_bytes())
        for name in initial:
            target=dest/'tested_source'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/name).read_bytes())
    try:
        for name in initial:
            raw=(ROOT/name).read_bytes();raw.decode('utf-8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
        run([iv,'-g2012','-Wall','-tnull','-s','ram_read_gather','-s','gather16','-f','example/files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_b19_gather_') as temp:
            work=Path(temp)
            for p,model in models:
                n,a,d,t=p;(work/'input.hex').write_bytes(model['vector']);(work/'requests.hex').write_bytes(model['request'])
                report['current_profile']=list(p);save()
                run([iv,'-g2012','-Wall','-s','tb_ram_read_gather',f'-Ptb_ram_read_gather.N={n}',f'-Ptb_ram_read_gather.A={a}',
                     f'-Ptb_ram_read_gather.D={d}',f'-Ptb_ram_read_gather.T={t}','-o','sim.vvp',ROOT/'rtl/ram_read_gather.sv',ROOT/'sim/tb_ram_read_gather.sv'],work)
                stdout=run([vv,'sim.vvp',f'+INPUT={work/"input.hex"}',f'+REQUESTS={work/"requests.hex"}',f'+OUTPUT={work/"actual.txt"}',
                    f'+TOKENS={len(model["tokens"])}',f'+READS={len(model["requests"])}',f'+OUTPUTS={len(model["outputs"])}',f'+FRAMES={len(model["frames"])}'],work)
                match=re.fullmatch(r'PASS gather tokens=(\d+) outputs=(\d+) reads=(\d+) frames=(\d+) cycles=(\d+) source_holds=(\d+) request_holds=(\d+) response_holds=(\d+) output_holds=(\d+) resets=(\d+) recovery=(\d+) scans=(\d+) ram_reads=(\d+) ram_writes=(\d+) requests=(\d+) responses=(\d+) max_latency=(\d+) states=([0-9a-f]+)\n.*',stdout,re.S)
                assert match,stdout;values=list(map(int,match.groups()[:-1]));assert values[:4]==[len(model['tokens']),len(model['outputs']),len(model['requests']),len(model['frames'])]
                assert values[9:11]==[16,32] and all(values[i]>0 for i in [4,5,6,7,8,12,13,14,15])
                names=['accepted_tokens','output_tokens','unique_main_reads','main_frames','trace_nonreset_cycles','source_hold_checks','request_hold_checks',
                       'response_hold_checks','output_hold_checks','reset_probes','fresh_recovery_frames','prefix_comparisons','ram_reads','ram_writes','external_requests','external_responses','maximum_first_latency_with_waits']
                item=dict(zip(names,values));item.update(dict(zip(plan['profile_fields'],p)),status='PASS',**frozen_entry(model),**verify(work/'actual.txt',model,p))
                item['output']=stdout.strip();report['profiles'].append(item);report['remaining_profiles'].pop(0);report.pop('current_profile');save()
                print(f'PASS gather N={n} frames={len(model["frames"])}',flush=True)
            for key,value in INVALID:run([iv,'-g2012','-tnull','-s','ram_read_gather',f'-Pram_read_gather.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes(),'source changed during qualification'
        assert len(report['commands'])==19
        total_keys=['accepted_tokens','output_tokens','unique_main_reads','main_frames','trace_nonreset_cycles','source_hold_checks','request_hold_checks',
                    'response_hold_checks','output_hold_checks','reset_probes','fresh_recovery_frames','prefix_comparisons','ram_reads','ram_writes',
                    'external_requests','external_responses','checked_outputs','exact_latency_checks','packed_row_checks','external_wait_cycles']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=8,
                      totals={key:sum(p[key] for p in report['profiles']) for key in total_keys},
                      counter_scope='Main tokens/outputs/unique reads/latencies/map checks and coverage are main-only. Trace cycles, holds, prefix/RAM and all external request/response counts include setup/probe/fresh/main activity. Reset-canceled outstanding requests can exceed responses.',
                      oracle='Insertion-ordered Python address dictionary keyed by raw unsigned address; data/error response chosen per frame and address. Ordered outputs reuse dictionary values, not the RTL RAM schedule. Separate first-position count certificate validates exact internal latency and comparison work.')
        save();print('PASS gather profiles=5 children=19',flush=True)
    except BaseException as error:
        report['failure']=repr(error);report['status']=['NOT_RUN','HW_UNVERIFIED'];save();archive();raise


if __name__=='__main__':main()
