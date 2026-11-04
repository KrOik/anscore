#!/usr/bin/env python3
"""Fixed finite B13 matrix. No synthesis; all compiler/simulator children <=20s."""
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
BASELINE='fcd2beef77f998da54801b91d74ce47946bee17c'
PROFILES=[(1,1,1,1),(3,5,7,3),(16,16,8,8),(32,32,32,8),(128,64,64,32)]
INVALID=[('SLOTS',0),('SLOTS',129),('KEY_W',0),('KEY_W',65),
         ('VALUE_W',0),('VALUE_W',65),('TAG_W',0),('TAG_W',33)]

def canonical(key,length,width):
    unit=2**(width-length)
    return (key//unit)*unit

def operate(table,command,slots,width):
    op,key,length,value,tag=command
    result=dict(status=0,found=0,inserted=0,prefix=0,length=0,value=0,count=len(table),tag=tag)
    identity=None
    if op==3:
        table.clear()
    elif op in (1,2) and length>width:
        result['status']=3
    else:
        if op==0:
            # Interval containment + sorting, independent of RTL prefix-bit comparisons.
            candidates=[(plen,base) for base,plen in table if base<=key<base+2**(width-plen)]
            if candidates:
                plen,base=max(candidates)
                identity=(base,plen)
        else:
            candidate=(canonical(key,length,width),length)
            if candidate in table:identity=candidate
        if identity is not None:
            result.update(found=1,prefix=identity[0],length=identity[1],value=table[identity])
        if op==0:
            if identity is None:result['status']=1
        elif op==1:
            if identity is not None:table[identity]=value
            elif len(table)<slots:
                table[(canonical(key,length,width),length)]=value
                result['inserted']=1
            else:result['status']=2
        elif identity is not None:del table[identity]
        else:result['status']=1
    result['count']=len(table)
    return result

def fixtures(s,k,v,t):
    commands=[];mask=2**k-1;vm=2**v-1;tm=2**t-1
    def add(op,key=0,length=0,value=0):
        commands.append((op,key&mask,length,value&vm,(len(commands)*29+7)&tm))
    add(3,mask,0xffffffff,vm);add(0,0,0xffffffff);add(0,mask)
    add(1,0,k+1,vm);add(2,mask,0xffffffff)
    add(1,mask,0,vm);add(1,0,0,0);add(0,mask)
    add(1,mask,0x80000000,vm);add(0,mask);add(2,mask,k+1);add(0,mask)
    # Every legal prefix length, host-bit aliases, full-width and /0 included.
    for length in range(k+1):
        base=canonical(mask//3,length,k)
        add(1,base,length,length);add(1,base+(2**(k-length)-1),length,vm-length)
        add(0,base);add(0,base+(2**(k-length)-1))
        add(2,base+(2**(k-length)-1),length);add(0,base)
    add(3)
    identities=[(0,0)]+[(i,k) for i in range(s-1)]
    for index,(base,length) in enumerate(identities):add(1,base,length,index+1)
    add(1,mask,k,vm);add(0,mask)  # absent full insert; fallback /0
    for index,(base,length) in enumerate(identities):
        add(1,base+(2**(k-length)-1),length,vm-index);add(0,base)
    for base,length in reversed(identities[1::2]):
        add(2,base,length);add(0,base);add(2,base,length)
    for base,length in identities[1::2]:add(1,base,length,0)
    add(2,mask,0);add(0,mask);add(3)
    # Equal final identities in two insertion orders must produce equal decisions.
    selected=[(canonical(mask//3,p,k),p) for p in range(min(k+1,s))]
    for order in (selected,list(reversed(selected))):
        add(3)
        for base,length in order:add(1,base+(2**(k-length)-1),length,length)
        for key in (0,mask//3,mask//2,mask):add(0,key)
    add(3)
    rng=random.Random(20261300+s+k)
    pool=[(canonical(rng.getrandbits(k),p,k),p) for p in range(k+1)]
    for i in range(360):
        op=rng.choices([0,1,2,3],[45,35,18,2])[0]
        base,length=rng.choice(pool)
        key=base+rng.randrange(2**(k-length))
        if i%19==0:length=rng.choice([k+1,0xffffffff,0x80000000])
        if op==0:key=rng.getrandbits(k)
        add(op,key,length,rng.getrandbits(v))
    if (s,k)==(1,1):
        choices=[(0,0,0,0),(0,1,0,0),(1,1,0,0),(1,0,1,1),(1,1,1,1),
                 (2,1,0,0),(2,0,1,0),(2,1,1,0),(1,0,0xffffffff,1)]
        for sequence in itertools.product(choices,repeat=3):
            add(3)
            for cmd in sequence:add(*cmd)
    add(3);add(0,mask,0xffffffff)
    return commands

def pack(fields):
    result=0
    for datum,width in fields:
        assert 0<=datum<2**width,(datum,width)
        result=result*2**width+datum
    return f'{result:x}'

def prepare(s,k,v,t):
    commands=fixtures(s,k,v,t)
    data=('\n'.join(pack([(op,2),(key,k),(length,32),(val,v),(tag,t)])
                     for op,key,length,val,tag in commands)+'\n').encode('ascii')
    return commands,data

def verify(path,commands,s,k,v,t):
    pw=k.bit_length();cw=s.bit_length()
    fields=[('status',2),('found',1),('inserted',1),('prefix',k),('length',pw),('value',v),('count',cw),('tag',t)]
    table={};coverage=collections.Counter();snapshot_hash=hashlib.sha256();physical=0;replay={}
    lines=path.read_text(encoding='ascii').splitlines();assert len(lines)==len(commands)
    for index,(line,command) in enumerate(zip(lines,commands)):
        words=line.split();assert len(words)==s+1
        bits=int(words[0],16);actual={}
        for name,width in reversed(fields):actual[name]=bits%(2**width);bits//=2**width
        assert bits==0
        before=table.copy();expected=operate(table,command,s,k)
        assert actual==expected,(index,command,actual,expected)
        physical_table={}
        for encoded in words[1:]:
            row=int(encoded,16);assert row<2**(1+k+pw+v);physical+=1
            if row>>(k+pw+v):
                value=row%(2**v);length=(row//2**v)%(2**pw);prefix=(row//2**(v+pw))%(2**k)
                assert length<=k and canonical(prefix,length,k)==prefix,(index,prefix,length)
                assert (prefix,length) not in physical_table,('duplicate identity',index,prefix,length)
                physical_table[(prefix,length)]=value
        assert physical_table==table,(index,command,physical_table,table)
        snapshot_hash.update(json.dumps(sorted((a,b,val) for (a,b),val in table.items())).encode())
        op,key,length,val,tag=command
        coverage[f'op_{op}']+=1;coverage[f'status_{expected["status"]}']+=1
        if op in (1,2) and length<=k and key!=canonical(key,length,k):coverage['host_bit_aliases']+=1
        if op==1 and expected['found']:coverage['replacements']+=1
        if op==1 and expected['found'] and len(before)==s:coverage['full_replacements']+=1
        if op==1 and expected['inserted']:coverage['insertions']+=1
        if op==2 and expected['found']:coverage['deletions']+=1
        if op==0 and expected['found']:
            candidates=sum(a<=key<a+2**(k-b) for a,b in table)
            coverage['overlapping_queries']+=candidates>1
            coverage['default_hits']+=expected['length']==0
            coverage['full_width_hits']+=expected['length']==k
        if op==0:
            state=(tuple(sorted((a,b,val) for (a,b),val in table.items())),key)
            result=tuple(actual[x] for x in ('status','found','prefix','length','value','count'))
            if state in replay:assert result==replay[state];coverage['deterministic_replays']+=1
            replay[state]=result
    assert coverage['status_0'] and coverage['status_1'] and coverage['status_2'] and coverage['status_3']
    assert coverage['replacements'] and coverage['full_replacements'] and coverage['deletions']
    if s>1:assert coverage['overlapping_queries']
    return dict(coverage=coverage,physical_slot_checks=physical,
                dictionary_history_sha256=snapshot_hash.hexdigest(),actual_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

def local_hashes():
    return {str(f.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(f.read_bytes()).hexdigest()
            for f in sorted(ROOT.rglob('*')) if f.is_file() and f.name!='verification.json'}

def main():
    old=ROOT/'verification.json'
    if old.exists():
        previous=json.loads(old.read_text(encoding='utf-8'))
        if previous.get('timeout_occurred') or any(c.get('status')=='TIMEOUT_NOT_RUN' for c in previous.get('commands',[])):
            raise RuntimeError('Prior timeout: fixed batch is stopped; no automatic retry permitted')
    report=dict(baseline_commit=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],timeout_occurred=False)
    def save():old.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();initial=local_hashes();report['source_sha256']=initial;save()
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    def run(argv,cwd,negative=False):
        command=[str(x) for x in argv]
        try:p=subprocess.run(command,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            report['timeout_occurred']=True
            report['commands'].append(dict(argv=command,status='TIMEOUT_NOT_RUN',returncode=None,timeout_seconds=20,
                stdout=str(error.stdout or ''),stderr=str(error.stderr or '')));save();raise
        entry=dict(argv=command,returncode=p.returncode,stdout=p.stdout,stderr=p.stderr,timeout_seconds=20)
        report['commands'].append(entry);save()
        if negative:assert p.returncode>0 and 'ram_prefix_table_invalid_parameters__see_README' in p.stderr,entry
        else:assert p.returncode==0 and not p.stderr,entry
        return p.stdout
    try:
        plan=json.loads((ROOT/'TEST_PLAN.json').read_text(encoding='utf-8'))
        assert plan['profiles']==[list(p) for p in PROFILES] and plan['invalid_parameters']==[list(p) for p in INVALID]
        for f in ROOT.rglob('*'):
            if f.is_file():raw=f.read_bytes();raw.decode('utf-8',errors='strict');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),f
        run([iv,'-V'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','ram_prefix_table','-s','address_routes32','-f','examples/files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_prefix_') as tmp:
            target=Path(tmp)
            for s,k,v,t in PROFILES:
                commands,data=prepare(s,k,v,t);assert len(commands)<=30001
                (target/'input.hex').write_bytes(data)
                run([iv,'-g2012','-Wall','-s','tb_ram_prefix_table',f'-Ptb_ram_prefix_table.S={s}',
                     f'-Ptb_ram_prefix_table.K={k}',f'-Ptb_ram_prefix_table.V={v}',f'-Ptb_ram_prefix_table.T={t}',
                     '-o','sim.vvp',ROOT/'rtl/ram_prefix_table.sv',ROOT/'sim/tb_ram_prefix_table.sv'],target)
                output=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',
                            f'+COUNT={len(commands)}',f'+OUTCOUNT={len(commands)}'],target)
                m=re.search(r'PASS prefix responses=(\d+) cycles=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) recovery=(\d+) slots=(\d+) max_latency=(\d+) bound=(\d+)',output)
                assert m,output
                counts=list(map(int,m.groups()))
                assert counts[0]==len(commands) and counts[2]>0 and counts[3]>0 and counts[4]==14
                assert counts[6]==s*len(commands) and counts[7]<=counts[8]==2*s+4
                profile=dict(SLOTS=s,KEY_W=k,VALUE_W=v,TAG_W=t,status='PASS',commands=len(commands),cycles=counts[1],
                    blocked_cycles=counts[2],held_response_cycles=counts[3],immediate_reset_probes=counts[4],
                    fresh_recovery_commands=counts[5],maximum_first_latency=counts[7],conservative_bound=counts[8],
                    input_sha256=hashlib.sha256(data).hexdigest(),output=output.strip(),**verify(target/'actual.hex',commands,s,k,v,t))
                report['profiles'].append(profile);save();print(f'PASS prefix S={s} K={k} commands={len(commands)}',flush=True)
            for key,value in INVALID:
                run([iv,'-g2012','-tnull','-s','ram_prefix_table',f'-Pram_prefix_table.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==local_hashes(),'source changed during qualified checks'
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=len(INVALID),
            total_commands=sum(p['commands'] for p in report['profiles']),total_cycles=sum(p['cycles'] for p in report['profiles']),
            immediate_reset_probes=sum(p['immediate_reset_probes'] for p in report['profiles']),
            fresh_recovery_commands=sum(p['fresh_recovery_commands'] for p in report['profiles']),
            physical_slot_checks=sum(p['physical_slot_checks'] for p in report['profiles']),
            oracle='Canonical interval dictionary; sorted interval containment for LPM; full physical identity/value snapshots after each response',
            not_run=['synthesis','PnR','STA','hardware','expanded regression'])
        save();print(f'PASS prefix profiles={len(PROFILES)} children={len(report["commands"])}',flush=True)
    except BaseException as error:
        report['failure']=repr(error);report['status']=['NOT_RUN','HW_UNVERIFIED'];save()
        history=ROOT/'history';history.mkdir(exist_ok=True)
        suffix=len(list(history.glob('failure_*.json')))+1
        (history/f'failure_{suffix:03d}.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
        raise
if __name__=='__main__':main()
