#!/usr/bin/env python3
"""Frozen B15 finite matrix; content-keyed oracle, <=20-second children."""
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
PROFILES=[(1,1,1,1,1),(3,3,5,2,3),(8,4,8,3,8),(16,4,32,8,8),(32,16,32,16,32)]
INVALID=[(k,v) for k,hi in [('SLOTS',32),('WORDS',16),('DATA_W',32),('REF_W',16),('TAG_W',32)] for v in [0,hi+1]]

def fixtures(n,b,w,r,t):
    maximum=(1<<w)-1;commands=[];tagmask=(1<<t)-1
    def block(i):return tuple(((i>>(j*w))&maximum) for j in range(b))
    def add(op,handle=0,data=None):
        commands.append((op,handle,(len(commands)*37+11)&tagmask,tuple(data or [0]*b)))
    add(3,0xffffffff,[maximum]*b)
    for h in list(range(n))+[n,0x80000000,0xffffffff]:add(1,h);add(2,h)
    for i in range(n):add(0,0xffffffff,block(i))
    for i in range(n):add(1,i)
    add(0,0x80000000,block(0)) # exact duplicate while physically full
    add(0,0xffffffff,block(n)) # absent, FULL when representable
    for j in range(b):
        v=list(block(0));v[j]^=1;add(0,0xffffffff,v)
    for i in [0,n//2,n-1]:
        add(2,i);add(2,i);add(0,0xffffffff,block(n+i+1));add(1,i)
    add(3)
    add(0,data=[maximum]*b)
    if r<=8:
        for _ in range((1<<r)-1):add(0,data=[maximum]*b)
        add(1,0)
        for _ in range((1<<r)-1):add(2,0)
        add(2,0);add(1,0)
    add(3)
    rng=random.Random(20261500+n+b+w+r)
    for i in range(256):
        op=rng.choices([0,1,2,3],[48,24,25,3])[0]
        h=rng.choice(list(range(n))+[n,0xffffffff,0x80000000])
        data=rng.choice([block(rng.randrange(n+2)),tuple([0]*b),tuple([maximum]*b),tuple(rng.getrandbits(w) for _ in range(b))])
        add(op,h,data)
    if (n,b,w,r)==(1,1,1,1):
        choices=[(0,0,(0,)),(0,0,(1,)),(1,0,(0,)),(2,0,(0,)),(3,0,(0,)),(1,0xffffffff,(0,)),(2,1,(0,))]
        for sequence in itertools.product(choices,repeat=3):
            add(3)
            for op,h,data in sequence:add(op,h,data)
    add(3);add(1,0)
    return commands

def pack(fields):
    value=0
    for datum,width in fields:
        assert 0<=datum<1<<width,(datum,width)
        value=(value<<width)|datum
    return f'{value:x}'

def operate(objects,command,n,b,r):
    op,h,tag,data=command;status=0;target=0;refs=0;shared=0;keep=0;words=[0]
    if op==0:
        if data in objects:
            handle,count=objects[data]
            if count==(1<<r)-1:status=3
            else:target=handle;refs=count+1;shared=1;objects[data]=(handle,refs)
        elif len(objects)==n:status=4
        else:
            target=min(set(range(n))-{x[0] for x in objects.values()});refs=1;objects[data]=(target,1)
    elif op in (1,2):
        if h>=n:status=1
        else:
            found=next(((key,count) for key,(handle,count) in objects.items() if handle==h),None)
            if found is None:status=2
            else:
                key,count=found;target=h;refs=count
                if op==1:keep=1;words=key
                else:
                    refs=count-1
                    if refs:objects[key]=(h,refs)
                    else:del objects[key]
    else:objects.clear()
    tokens=[]
    for j,datum in enumerate(words):
        tokens.append(dict(op=op,status=status,handle=target,tag=tag,refs=refs,count=len(objects),shared=shared,
                           keep=keep,first=int(j==0),last=int(j==len(words)-1),index=j,data=datum))
    return tokens

def verify(path,commands,n,b,w,r,t):
    iw=max(1,(b-1).bit_length());cw=max(1,n.bit_length())
    fields=[('op',2),('status',3),('handle',32),('tag',t),('refs',r),('count',cw),('shared',1),('keep',1),('first',1),('last',1),('index',iw),('data',w)]
    objects={};coverage=collections.Counter();lines=iter(path.read_text(encoding='ascii').splitlines());tokens=0;checks=0
    for position,command in enumerate(commands):
        expected_tokens=operate(objects,command,n,b,r)
        coverage[f'op_{command[0]}']+=1;coverage[f'status_{expected_tokens[0]["status"]}']+=1
        if expected_tokens[0]['shared']:coverage['duplicate_shared']+=1
        if expected_tokens[0]['count']==n:coverage['at_capacity']+=1
        live={h:(data,count) for data,(h,count) in objects.items()}
        for expected in expected_tokens:
            line=next(lines);parts=line.split();assert len(parts)==1+n*(b+1),(position,len(parts))
            raw=int(parts[0],16);actual={}
            for key,width in reversed(fields):actual[key]=raw%2**width;raw//=2**width
            assert raw==0 and actual==expected,(position,command,actual,expected)
            bank=list(map(lambda x:int(x,16),parts[1:]))
            for h in range(n):
                data,count=live.get(h,(tuple([0]*b),0));row=bank[h*(b+1):(h+1)*(b+1)]
                assert row==[count,*data],(position,'physical live block',h,row,count,data)
                checks+=1
            tokens+=1
    assert next(lines,None) is None
    assert all(coverage[f'op_{op}'] for op in range(4))
    assert coverage['status_0'] and coverage['status_1'] and coverage['status_2'] and coverage['at_capacity']
    if r<=8:assert coverage['status_3']
    if n>1:assert coverage['status_4'] and coverage['duplicate_shared']
    return dict(response_tokens=tokens,physical_slot_checks=checks,coverage=coverage,actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

def hashes():
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name!='verification.json' and 'history' not in p.relative_to(ROOT).parts}

def main():
    output=ROOT/'verification.json';previous=json.loads(output.read_text(encoding='utf-8')) if output.exists() else {}
    if previous.get('timeout_occurred'):raise RuntimeError('Prior timeout is terminal: no retry for this batch')
    if previous:
        history=ROOT/'history';history.mkdir(exist_ok=True)
        old=json.dumps(previous,indent=2)+'\n';(history/(hashlib.sha256(old.encode()).hexdigest()+'.json')).write_text(old,encoding='utf-8',newline='\n')
    report=dict(baseline_commit='9716da0847c26f09f4a9b856a84fc330dfb26351',status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],timeout_occurred=False,
        fixed_profiles=PROFILES,remaining_profiles=[list(p) for p in PROFILES],invalid_parameter_cases=INVALID,not_run=['synthesis','PnR','STA','hardware','expanded regression'])
    def save():output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    initial=hashes();report['source_sha256']=initial;save()
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(argv,cwd,negative=False):
        argv=list(map(str,argv))
        try:p=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as e:
            report['timeout_occurred']=True;report['commands'].append(dict(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=str(e.stdout or ''),stderr=str(e.stderr or '')));save();raise
        row=dict(argv=argv,returncode=p.returncode,stdout=p.stdout,stderr=p.stderr,timeout_seconds=20,status='PASS' if (p.returncode==0)!=negative else 'FAIL')
        report['commands'].append(row);save()
        if negative:assert p.returncode>0 and 'block_intern_store_invalid_parameters__see_README' in p.stderr,row
        else:assert p.returncode==0 and not p.stderr,row
        return p.stdout
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text());assert plan['profiles']==[list(p) for p in PROFILES] and plan['invalid_parameters']==[list(p) for p in INVALID]
        for p in ROOT.rglob('*'):
            if p.is_file():raw=p.read_bytes();raw.decode('utf-8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),p
        run([iv,'-V'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','block_intern_store','-s','block_store16','-f','example/files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_block_intern_') as tmp:
            target=Path(tmp)
            for n,b,w,r,t in PROFILES:
                commands=fixtures(n,b,w,r,t);assert len(commands)<=10000
                data=('\n'.join(pack([(op,2),(h,32),(tag,t)]+[(v,w) for v in block]) for op,h,tag,block in commands)+'\n').encode('ascii')
                (target/'input.hex').write_bytes(data)
                run([iv,'-g2012','-Wall','-s','tb_block_intern_store',f'-Ptb_block_intern_store.N={n}',f'-Ptb_block_intern_store.B={b}',f'-Ptb_block_intern_store.W={w}',f'-Ptb_block_intern_store.R={r}',f'-Ptb_block_intern_store.T={t}','-o','sim.vvp',ROOT/'rtl/block_intern_store.sv',ROOT/'sim/tb_block_intern_store.sv'],target)
                text=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',f'+COUNT={len(commands)}'],target)
                match=re.search(r'PASS intern commands=(\d+) cycles=(\d+) blocked=(\d+) data_blocked=(\d+) held=(\d+) resets=(\d+) recovery=(\d+) max_latency=(\d+) bound=(\d+) comparisons=(\d+) copies=(\d+)',text);assert match,text
                values=list(map(int,match.groups()));assert values[0]==len(commands) and all(values[j]>0 for j in [2,3,4,5,6,9,10])
                assert values[5]==((18 if b==1 else 20)-(r==1)) and values[7]<=values[8]==n*(2+2*b)+2*b+8
                item=dict(zip(['main_commands','trace_nonreset_cycles','source_blocked_cycles','data_blocked_cycles','held_response_cycles','reset_probes','recovery_commands','maximum_first_latency','conservative_bound','word_comparisons','payload_word_writes'],values))
                item.update(SLOTS=n,WORDS=b,DATA_W=w,REF_W=r,TAG_W=t,status='PASS',input_sha256=hashlib.sha256(data).hexdigest(),output=text.strip(),**verify(target/'actual.hex',commands,n,b,w,r,t))
                report['profiles'].append(item);report['remaining_profiles'].pop(0);save();print(f'PASS intern N={n} B={b} W={w} R={r} commands={len(commands)}',flush=True)
            for key,value in INVALID:run([iv,'-g2012','-tnull','-s','block_intern_store',f'-Pblock_intern_store.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes(),'source changed during frozen matrix'
        names=['main_commands','trace_nonreset_cycles','source_blocked_cycles','data_blocked_cycles','held_response_cycles','reset_probes','recovery_commands','response_tokens','physical_slot_checks','word_comparisons','payload_word_writes']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=len(INVALID),totals={key:sum(p[key] for p in report['profiles']) for key in names},
            counter_scope='Responses/snapshots/coverage main-only. Cycles/stalls/comparison/copy counters include nonreset probe/setup/recovery/main activity.',oracle='Python dictionary keyed by complete immutable block, reference counts and lowest unused handle; no RAM read/copy/probe schedule modeled.')
        save();print(f'PASS intern profiles={len(PROFILES)} children={len(report["commands"])}',flush=True)
    except BaseException as error:
        report['failure']=repr(error);report['status']=['NOT_RUN','HW_UNVERIFIED'];save();raise

if __name__=='__main__':main()
