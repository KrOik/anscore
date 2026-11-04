#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite dictionary/byte-set ownership oracle; all children limited to 20 s."""
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='c778301aa12d1b9bf4290b1a982f4c6325713fcd'


def pack(parts):
    word=0
    for value,width in parts:
        assert width>0 and 0<=value<1<<width,(value,width)
        word=(word<<width)|value
    return word


def vectors(a,s,g,o,t):
    rng=random.Random(0x4c4f434b+a*101+s+g+o+t);limit=1<<a;maximum=(1<<g)-1
    owner_mask=(1<<o)-1;tag_mask=(1<<t)-1;cw=s.bit_length()
    table=[dict(live=False,exclusive=False,owner=0,generation=0,base=0,stop=1) for _ in range(s)]
    inputs=[];outputs=[];lats=[];snapshots=[];history=[]
    cov={k:0 for k in ['acquire','release','replace','snapshot','ok','bad_range','conflict','full','bad_handle',
        'shared_overlap_grants','exclusive_conflicts','multiple_conflicts','adjacent_grants',
        'replace_rollbacks','replace_commits','retirements','stale_rejections','wrong_owner',
        'full_span_grants','full_capacity_replacements','byte_set_comparisons','pair_invariants','all_retired']}
    def overlap(x,y):
        if x['stop']-x['base']<=64 and y['stop']-y['base']<=64:
            cov['byte_set_comparisons']+=1
            return bool(set(range(x['base'],x['stop'])) & set(range(y['base'],y['stop'])))
        return max(x['base'],y['base'])<min(x['stop'],y['stop'])
    def counts():
        live=sum(e['live'] for e in table);retired=sum(not e['live'] and e['generation']==maximum for e in table)
        return live,s-live-retired,retired
    def add(op=3,base=0,length=0,exclusive=0,owner=0,slot=0,generation=0):
        tag=tag_mask if len(inputs)%4==0 else rng.getrandbits(t)
        inputs.append(pack(((op,2),(base,a),(length,a+1),(exclusive,1),(owner,o),(slot,32),(generation,g),(tag,t))))
        cov[('acquire','release','replace','snapshot')[op]]+=1
        status=0;lat=0;geometry=(0,0,0,0,0,0);conflicts=0
        bad_range=length==0 or base+length>limit
        valid_handle=slot<s and generation!=0 and table[slot]['live'] and table[slot]['generation']==generation and table[slot]['owner']==owner
        old=[dict(e) for e in table]
        if op==0 and bad_range:status=1
        elif op in (1,2) and (slot>=s or generation==0):status=4
        elif op in (1,2) and not valid_handle:
            status=4;lat=2
            if slot<s and table[slot]['live']:
                cov['wrong_owner']+=table[slot]['owner']!=owner
                cov['stale_rejections']+=table[slot]['generation']!=generation
        elif op==1:
            lat=2;e=table[slot];geometry=(slot,generation,owner,e['base'],e['stop']-e['base'],int(e['exclusive']))
            e['live']=False;cov['retirements']+=generation==maximum
        elif op==2 and bad_range:status=1;lat=2
        elif op in (0,2):
            lat=2*s+1+(2 if op==2 else 0)
            proposed=dict(base=base,stop=base+length,exclusive=bool(exclusive),owner=owner)
            for i,e in enumerate(table):
                if e['live'] and not (op==2 and i==slot) and (exclusive or e['exclusive']) and overlap(e,proposed):conflicts|=1<<i
            free=[i for i,e in enumerate(table) if not e['live'] and e['generation']<maximum]
            if conflicts:
                status=2;cov['exclusive_conflicts']+=bool(exclusive);cov['multiple_conflicts']+=conflicts.bit_count()>1
            elif op==0 and not free:status=3
            else:
                index=min(free) if op==0 else slot
                nextgen=table[index]['generation']+1 if op==0 else generation
                if op==0:
                    for i,e in enumerate(table):
                        if e['live']:
                            cov['shared_overlap_grants']+=not exclusive and not e['exclusive'] and overlap(e,proposed)
                            cov['adjacent_grants']+=e['stop']==base or base+length==e['base']
                    history.append((index,nextgen,owner))
                else:
                    cov['replace_commits']+=1
                    cov['full_capacity_replacements']+=all(e['live'] for e in old)
                table[index]=dict(proposed,live=True,generation=nextgen)
                geometry=(index,nextgen,owner,base,length,exclusive)
                cov['full_span_grants']+=length==limit
        if op==2 and status and valid_handle:
            assert table==old;cov['replace_rollbacks']+=1
        cov[('ok','bad_range','conflict','full','bad_handle')[status]]+=1
        live,free,retired=counts();cov['all_retired']+=retired==s
        index,epoch,identity,start,size,mode=geometry
        outputs.append(pack(((op,2),(status,3),(tag,t),(index,32),(epoch,g),(identity,o),(start,a),
            (size,a+1),(mode,1),(conflicts,s),(live,cw),(free,cw),(retired,cw))))
        lats.append(lat)
        for i,e in enumerate(table):
            snapshots.append(pack(((int(e['live']),1),(int(e['exclusive']),1),(e['owner'],o),
                (e['generation'],g),(e['base'],a),(e['stop']-1,a))))
            for f in table[i+1:]:
                if e['live'] and f['live']:
                    assert not ((e['exclusive'] or f['exclusive']) and overlap(e,f))
                    cov['pair_invariants']+=1
    def release_all():
        for i,e in enumerate(list(table)):
            if e['live']:add(1,owner=e['owner'],slot=i,generation=e['generation'])
    def replace_at(index,base,length,mode):
        e=table[index];add(2,base,length,mode,e['owner'],index,e['generation'])
    add();add(0,0,0);add(0,limit-1,2);add(0,0,2*limit-1)
    add(1,slot=0xffffffff,generation=maximum);add(2,slot=0,generation=0)
    add(0,8,4,0,owner_mask)
    if s>1:add(0,10,4,0,owner_mask)
    replace_at(0,8,4,1) # Conflicts with another shared owner when present.
    replace_at(0,limit-1,2,1) # Atomic invalid-range rollback.
    add(1,owner=owner_mask^1,slot=0,generation=1)
    add(0,9,1,1,0);add()
    if s>1:
        e=table[1];add(1,owner=e['owner'],slot=1,generation=e['generation'])
    replace_at(0,8,4,1);replace_at(0,24,4,1);replace_at(0,24,4,0)
    add(0,24,4,0,0);add(0,26,1,1,0);add()
    release_all()
    # Exact adjacency, full address range and last address geometry.
    add(0,0,4,1,0);add(0,4,4,1,owner_mask);add(0,3,2,1,0);release_all()
    add(0,0,limit,0,owner_mask);add(0,limit-1,1,0,0);add(0,limit-1,1,1,0);release_all()
    add(0,limit-1,1,1,owner_mask);release_all()
    # Fill all slots with compatible readers, then distinguish conflict from full.
    for _ in range(s):add(0,32,1,0,0)
    add(0,32,1,1,owner_mask);add(0,48,1,1,owner_mask);add()
    if table[0]['live']:
        replace_at(0,48,1,1);replace_at(0,32,1,1);add(0,48,1,1,owner_mask)
    release_all()
    for number in range(240):
        live=[i for i,e in enumerate(table) if e['live']]
        op=rng.choices(range(4),(4,2,4,1))[0]
        if op in (1,2) and live and number%5:
            index=rng.choice(live);e=table[index];identity=e['owner'];epoch=e['generation']
            if number%23==0:identity^=1
        elif history and number%7==0:index,epoch,identity=rng.choice(history)
        else:index=rng.choice([0,s,s-1,0xffffffff]);epoch=rng.getrandbits(g);identity=rng.getrandbits(o)
        base=rng.randrange(64) if number%13 else limit-1-rng.randrange(8)
        length=rng.randrange(1,17) if number%17 else rng.choice([0,limit,2*limit-1])
        add(op,base,length,rng.randrange(2),identity,index,epoch)
    release_all()
    # Small generation profiles fully retire the pool without wrap; large
    # profiles exercise reuse/stale checks but do not claim full exhaustion.
    if g<=4:
        for _ in range(s*maximum+1):
            if not counts()[1]:break
            add(0,0,1,0,0);release_all()
        assert counts()==(0,0,s)
        for index,epoch,identity in history[:min(len(history),12)]:add(1,owner=identity,slot=index,generation=epoch)
        add(0,0,1,1,0)
    add();add(2,limit-1,2,1,0,0xffffffff,0);add()
    assert cov['bad_handle'] and cov['bad_range'] and cov['conflict'] and cov['replace_rollbacks']
    return inputs,outputs,lats,snapshots,cov


def main():
    report=dict(baseline_commit=BASELINE,status=['NOT_RUN'],commands=[],profiles=[],dependencies=[],
        per_process_timeout_seconds=20,not_run=['synthesis','PnR','STA','board','expanded regression'])
    def save():
        (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save() # A failing/missing-tool rerun cannot leave an earlier PASS report.
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    exe={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ('iverilog','vvp')}
    if not all(exe.values()):raise RuntimeError('NOT_RUN local Icarus required')
    def run(args,cwd=ROOT,reject=False):
        argv=[exe[args[0]],*map(str,args[1:])]
        r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        record=dict(command=argv,returncode=r.returncode,stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20)
        report['commands'].append(record)
        if reject:assert r.returncode>0 and 'range_lock_manager_invalid_parameter__see_README' in r.stderr,record
        else:assert r.returncode==0 and not r.stderr,record
        return r.stdout.strip()
    report['tool_version']=run(['iverilog','-V']).splitlines()[0]
    run(['iverilog','-g2012','-Wall','-tnull','-s','range_lock_manager','-f','files.f'])
    run(['iverilog','-g2012','-Wall','-tnull','-s','dma_hazards8','-f','example/files.f'])
    with tempfile.TemporaryDirectory(prefix='anscore_range_lock_') as tmp:
        for a,s,g,o,t in [(8,1,1,1,1),(12,3,2,3,3),(24,5,4,5,5),(32,8,8,8,8),(64,32,32,32,32)]:
            folder=Path(tmp)/f'a{a}_s{s}';folder.mkdir()
            inputs,outputs,lats,snaps,cov=vectors(a,s,g,o,t);digests={}
            for name,values in [('input.hex',inputs),('golden.hex',outputs),('latency.hex',lats),('table.hex',snaps)]:
                data=''.join(f'{v:x}\n' for v in values)
                (folder/name).write_text(data,encoding='ascii',newline='\n');digests[name]=hashlib.sha256(data.encode()).hexdigest()
            params=dict(A=a,S=s,G=g,O=o,T=t,COMMANDS=len(inputs))
            run(['iverilog','-g2012','-Wall','-s','tb',*[f'-Ptb.{k}={v}' for k,v in params.items()],'-o','sim.vvp',
                ROOT/'rtl/range_lock_manager.sv',ROOT/'sim/tb_range_lock_manager.sv'],folder)
            result=run(['vvp','sim.vvp'],folder);first=result.splitlines()[0]
            assert first.startswith('PASS locks '),result
            metrics={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',first)}
            assert metrics['commands']==len(inputs)
            report['profiles'].append(dict(addr_w=a,slots=s,generation_w=g,owner_w=o,tag_w=t,
                coverage=cov,vectors_sha256=digests,**metrics,result=result));print(first,flush=True)
        for name,value in [('ADDR_W',7),('ADDR_W',65),('SLOTS',0),('SLOTS',33),('GEN_W',0),('GEN_W',33),
                ('OWNER_W',0),('OWNER_W',33),('TAG_W',0),('TAG_W',33)]:
            run(['iverilog','-g2012','-tnull','-s','range_lock_manager',f'-Prange_lock_manager.{name}={value}','-f','files.f'],reject=True)
    names=[f for f in sorted(ROOT.rglob('*')) if f.is_file() and f.name!='verification.json']
    for f in names:
        data=f.read_bytes();data.decode('utf-8');assert b'\r' not in data,str(f)
    report['source_sha256']={f.relative_to(ROOT).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in names}
    report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
        example_status=['LINT_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],invalid_parameter_rejections=10,
        oracle='independent live dictionaries, byte-set intersections for short ranges / half-open integer intersections for long ones; complete pre/post-commit table snapshots',
        resource_risk=dict(default='LOW',maximum='MEDIUM',table_bits_default=656,table_bits_maximum=6208,physical_resources_measured=False))
    save();print('PASS finite shared/exclusive range locks; HW_UNVERIFIED',flush=True)


if __name__=='__main__':main()
