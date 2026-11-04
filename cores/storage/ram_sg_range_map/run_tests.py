#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite SG-map qualification with interval-intersection oracle."""
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
PROFILES=[(1,1,1,1),(3,3,5,3),(7,16,8,8),(16,32,16,8),(32,64,32,32)]
INVALID=[(key,v) for key,upper in [('MAX_SEGS',32),('ADDR_W',64),('LEN_W',32),('TAG_W',32)] for v in [0,upper+1]]
NOT_RUN=['synthesis','PnR','STA','board','expanded regression']
U64=(1<<64)-1


def sha(data):return hashlib.sha256(data).hexdigest()


def pack(fields):
    word=0
    for value,width in fields:
        assert 0<=value<1<<width
        word=word<<width|value
    return word


def fixtures(n,a,l,t):
    operations=[];am=(1<<a)-1;lm=(1<<l)-1
    def query(offset,length):operations.append((1,offset,length,[]))
    def other(op):operations.append((op,U64,U64,[]))
    def load(table,bad_first=False,masked=False,repeat_first=False,tail=False):
        entries=[]
        if masked:entries.append((am,lm,0,int(not bad_first),0))
        for i,(base,length) in enumerate(table):
            entries.append((base,length,1,int((i==0 and not masked and not bad_first) or (i==1 and repeat_first)),0))
        if tail:entries.append((am,lm,0,int(repeat_first),0))
        if not entries:entries.append((am,lm,0,int(not bad_first),0))
        last=list(entries[-1]);last[-1]=1;entries[-1]=tuple(last)
        operations.append((0,U64,U64,entries))
    query(0,1);query(U64,0);other(3);other(2)
    full=[]
    for i in range(n):
        base=(i*3)&am;length=min(lm,1+i%5,am-base+1)
        if i%5==1 and i!=n-1:length=0
        full.append((base,length))
    load(full,masked=True,tail=True);total=sum(length for _,length in full)
    query(0,total);query(max(0,total-1),1)
    if n<=3:
        for offset in range(total+2):
            for length in range(total+2):query(offset,length)
    for errors in range(1,8):
        if errors&1 and l==1:continue
        table=[(am,2)] if errors&1 else [(0,1)]
        if errors&4:table+= [(0,1)]*n
        load(table,bad_first=bool(errors&2));query(0,total)
    load(full,repeat_first=True,masked=True,tail=True);query(0,total)
    for bit in range(a):
        load([(1<<bit,1)]);query(0,1)
    for bit in range(l):
        length=1<<bit
        load([(0,length)])  # Wide LEN/small ADDR includes rejected ranges.
        query(max(0,length-1),1);query(0,length)
    maximum=min(lm,am+1)
    tables=[full,[(am,0)]*n,[(0,maximum)]*n,[],[(am,1)]*n]
    for table in tables:
        load(table,masked=True,tail=True);total=sum(length for _,length in table)
        for offset in sorted({0,max(0,total-1),total,total+1,1<<63,U64}):
            for length in sorted({0,1,total,max(1,total//2),U64}):query(offset,length)
        query(0,total);other(3);query(0,total)
    if n==1:
        for length in range(3):
            for table in itertools.product([(0,0),(0,1),(am,1)],repeat=length):
                load(table);query(0,1);query(U64,0)
    rng=random.Random(20262000+n+a+l+t)
    known=[(0,1)];load(known)
    for i in range(96):
        if i%5==0:
            known=[]
            for _ in range(rng.randrange(n+1)):
                base=rng.getrandbits(a);limit=min(lm,am-base+1)
                length=rng.choice([0,1,limit,rng.randrange(limit+1)])
                known.append((base,length))
            load(known,masked=i%2==0,tail=True)
        total=sum(length for _,length in known)
        offset=rng.choice([0,total,max(0,total-1),U64,rng.randrange(total+2)])
        length=rng.choice([0,1,total,U64,rng.randrange(total+2)])
        query(offset,length)
        if i%13==0:load([(0,1)],bad_first=True);query(0,total)
    load(full);query(0,sum(length for _,length in full));other(2);query(0,1);query(U64,0)
    return operations


def model(profile):
    n,a,l,t=profile;iw=max(1,(n-1).bit_length());cw=n.bit_length();tw=l+(n-1).bit_length()
    commands=[];entries=[];outputs=[];metadata=[];fragment_gaps=[];active=[];coverage=collections.Counter();byte_checks=0
    for index,(op,offset,length,tokens) in enumerate(fixtures(*profile)):
        tag=(index*37+11)&((1<<t)-1);commands.append((op,offset,length,tag));entries.extend(tokens)
        status=0;errors=0;chunks=[];latency=0;first_reads=0
        if op==0:
            replacement=[]
            for pos,(base,size,keep,first,last) in enumerate(tokens):
                assert last==int(pos==len(tokens)-1)
                if first!=int(pos==0):errors|=2
                if keep:
                    if size and base+size-1>=(1<<a):errors|=1
                    if len(replacement)==n:errors|=4
                    else:replacement.append((base,size))
            if errors:status=4
            else:active=replacement
            latency=1
            coverage[f'load_errors_{errors}']+=1
        elif op==1:
            total=sum(size for _,size in active)
            if length==0:status=1
            elif offset+length>total:status=2
            else:
                # Intersect the requested absolute logical interval with every
                # independently constructed segment prefix interval. No cursor
                # subtraction, controller or RAM-read schedule is simulated.
                prefix=0
                for segment,(base,size) in enumerate(active):
                    lo=max(offset,prefix);hi=min(offset+length,prefix+size)
                    if lo<hi:chunks.append((base+lo-prefix,hi-lo,lo,segment))
                    prefix+=size
                assert chunks and sum(c[1] for c in chunks)==length
                latency=2*(chunks[0][3]+1);first_reads=chunks[0][3]+1
                if total<=128:
                    byte_map=[(base+j,seg) for seg,(base,size) in enumerate(active) for j in range(size)]
                    from_chunks=[(base+j,seg) for base,size,_,seg in chunks for j in range(size)]
                    assert from_chunks==byte_map[offset:offset+length];byte_checks+=length
                coverage['multi_fragment']+=len(chunks)>1
                coverage['nonzero_offset']+=offset>0
                coverage['last_byte']+=offset+length==total
        elif op==2:active=[]
        else:status=3
        total=sum(size for _,size in active);snapshot=[base<<l|size for base,size in active]
        records=[]
        for ordinal,(address,size,logical,segment) in enumerate(chunks):
            records.append(dict(op=op,status=0,errors=0,keep=1,first=int(ordinal==0),last=int(ordinal==len(chunks)-1),
                tag=tag,addr=address,bytes=size,offset=logical,total=total,segment=segment,segments=len(active)))
        if not chunks:records=[dict(op=op,status=status,errors=errors,keep=0,first=1,last=1,tag=tag,addr=0,bytes=0,offset=0,total=total,segment=0,segments=len(active))]
        for record in records:outputs.append((record,snapshot))
        fragment_gaps.extend(2*(right[3]-left[3]) for left,right in zip(chunks,chunks[1:]))
        metadata.append(dict(latency=latency,first_reads=first_reads))
        coverage[f'op_{op}']+=1;coverage[f'status_{status}']+=1
        coverage['full_maps']+=len(active)==n;coverage['empty_maps']+=not active
        coverage['zero_segments']+=sum(size==0 for _,size in active)
        coverage['masked_entries']+=sum(not token[2] for token in tokens)
    fields=[('op',2),('status',3),('errors',3),('keep',1),('first',1),('last',1),('tag',t),('addr',a),('bytes',l),('offset',tw),('total',tw),('segment',iw),('segments',cw)]
    cb=('\n'.join(f'{pack([(op,2),(off,64),(size,64),(tag,t)]):x}' for op,off,size,tag in commands)+'\n').encode()
    eb=('\n'.join(f'{pack([(base,a),(size,l),(keep,1),(first,1),(last,1)]):x}' for base,size,keep,first,last in entries)+'\n').encode()
    return dict(commands=commands,entries=entries,outputs=outputs,metadata=metadata,fragment_gaps=fragment_gaps,fields=fields,command_bytes=cb,entry_bytes=eb,
                coverage=coverage,small_byte_mapping_checks=byte_checks)


def frozen(m):return dict(commands=len(m['commands']),entries=len(m['entries']),outputs=len(m['outputs']),fragment_gaps=len(m['fragment_gaps']),command_sha256=sha(m['command_bytes']),entry_sha256=sha(m['entry_bytes']))


def verify(path,m,profile):
    n,a,l,t=profile;actual=[];timing=[];gaps=[];row_checks=0
    for line in path.read_text(encoding='ascii').splitlines():
        parts=line.split()
        if parts[0]=='F':
            index,latency,reads=map(int,parts[1:]);assert index==len(timing)
            assert dict(latency=latency,first_reads=reads)==m['metadata'][index],(index,'exact latency',parts,m['metadata'][index])
            assert latency<=2*n;timing.append(latency)
        elif parts[0]=='G':
            index,latency=map(int,parts[1:]);assert index==len(gaps)
            assert latency==m['fragment_gaps'][index],(index,'fragment latency',latency,m['fragment_gaps'][index])
            gaps.append(latency)
        else:
            assert parts[0]=='O';word=int(parts[1],16);decoded={}
            for key,width in reversed(m['fields']):decoded[key]=word&((1<<width)-1);word>>=width
            assert word==0
            image=[int(value,16) for value in parts[2:]];row_checks+=len(image);actual.append((decoded,image))
    assert actual==m['outputs'],next(((i,x,y) for i,(x,y) in enumerate(zip(actual,m['outputs'])) if x!=y),('lengths',len(actual),len(m['outputs'])))
    assert len(timing)==len(m['commands']) and gaps==m['fragment_gaps']
    c=m['coverage'];assert all(c[f'op_{op}'] for op in range(4)) and all(c[f'status_{s}'] for s in range(5))
    assert all(c[k] for k in ['full_maps','empty_maps','zero_segments','masked_entries','last_byte'])
    if n>1:assert c['multi_fragment'] and c['nonzero_offset']
    possible=[0,2,4,6] if l==1 else range(8)
    assert all(c[f'load_errors_{e}'] for e in possible)
    return dict(checked_outputs=len(actual),active_map_row_checks=row_checks,exact_latency_checks=len(timing),fragment_gap_checks=len(gaps),
                maximum_first_latency=max(timing),small_byte_mapping_checks=m['small_byte_mapping_checks'],coverage=c,trace_sha256=sha(path.read_bytes()))


def hashes():return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name!='verification.json' and 'history' not in p.relative_to(ROOT).parts}


def main():
    plan_path=ROOT/'TEST_PLAN.json';receipt=ROOT/'verification.json';models=[(p,model(p)) for p in PROFILES]
    if sys.argv[1:]==['--freeze']:
        assert not plan_path.exists() and not receipt.exists()
        plan=dict(baseline_commit='ff2aadf8ebdc8e5475b7022cd68d47e496b9f593',frozen_before_first_hdl_tool=True,
            profile_fields=['MAX_SEGS','ADDR_W','LEN_W','TAG_W'],profiles=PROFILES,invalid_parameters=INVALID,
            child_timeout_seconds=20,qualified_child_records=19,reset_probes_each_profile=16,fresh_commands_each_probe=4,
            frozen_vectors={'/'.join(map(str,p)):frozen(m) for p,m in models},not_run=NOT_RUN,
            checks=['independent segment-prefix interval intersection oracle and small full byte-map crosscheck','all response fields and all active RAM rows',
                'atomic invalid replacement retains exact old map','zero segments and empty map, unsigned64 query overflow, physical address top/range',
                'actual next frozen command and actual next LOAD entry held independently until handshake','held ACK and each query fragment',
                'exact first-valid latency from command or accepted LOAD tail and exact subsequent fragment availability gaps','all seven states; sixteen immediate reset boundaries with full four-command fresh recovery',
                'eight named invalid-static rejections and offline default example'],pre_hdl_source_sha256=hashes())
        plan_path.write_text(json.dumps(plan,indent=2)+'\n',encoding='utf-8',newline='\n');print('FROZEN',sha(plan_path.read_bytes()));return
    assert not sys.argv[1:]
    prior=json.loads(receipt.read_text()) if receipt.exists() else {}
    if prior.get('timeout_occurred'):raise RuntimeError('Terminal timeout; retry, fixture shrink and larger limit forbidden')
    if 'UNIT_SIM_PASS' in prior.get('status',[]):raise RuntimeError('Successful frozen matrix cannot be rerun')
    plan=json.loads(plan_path.read_text());assert plan['profiles']==list(map(list,PROFILES)) and plan['invalid_parameters']==list(map(list,INVALID))
    assert plan['child_timeout_seconds']==20 and plan['qualified_child_records']==19
    assert all(plan['frozen_vectors']['/'.join(map(str,p))]==frozen(m) for p,m in models)
    initial=hashes();report=dict(baseline_commit=plan['baseline_commit'],status=['NOT_RUN','HW_UNVERIFIED'],source_sha256=initial,
        profiles=[],commands=[],remaining_profiles=PROFILES.copy(),timeout_occurred=False,not_run=NOT_RUN)
    def save():receipt.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save();suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')]);iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    temporary=tempfile.TemporaryDirectory(prefix='anscore_b20_sgmap_');work=Path(temporary.name)
    def run(argv,cwd,negative=False):
        argv=list(map(str,argv))
        try:r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            report['timeout_occurred']=True;decode=lambda v:v.decode(errors='replace') if isinstance(v,bytes) else v or ''
            report['commands'].append(dict(argv=argv,status='TIMEOUT_NOT_RUN',timeout_seconds=20,stdout=decode(error.stdout),stderr=decode(error.stderr)));save();raise
        good=(r.returncode>0 and 'ram_sg_range_map_invalid_parameters__see_README' in r.stderr) if negative else r.returncode==0 and not r.stderr
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
            raw=(ROOT/name).read_bytes();raw.decode('utf-8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
        run([iv,'-g2012','-Wall','-tnull','-s','ram_sg_range_map','-s','sg_map16','-f','example/files.f'],ROOT)
        for p,m in models:
            n,a,l,t=p;(work/'commands.hex').write_bytes(m['command_bytes']);(work/'entries.hex').write_bytes(m['entry_bytes']);report['current_profile']=list(p);save()
            run([iv,'-g2012','-Wall','-s','tb_ram_sg_range_map',f'-Ptb_ram_sg_range_map.N={n}',f'-Ptb_ram_sg_range_map.A={a}',
                f'-Ptb_ram_sg_range_map.L={l}',f'-Ptb_ram_sg_range_map.T={t}','-o','sim.vvp',ROOT/'rtl/ram_sg_range_map.sv',ROOT/'sim/tb_ram_sg_range_map.sv'],work)
            stdout=run([vv,'sim.vvp',f'+COMMANDS={work/"commands.hex"}',f'+ENTRIES={work/"entries.hex"}',f'+OUTPUT={work/"actual.txt"}',
                f'+CMDS={len(m["commands"])}',f'+ENTS={len(m["entries"])}',f'+OUTS={len(m["outputs"])}'],work)
            match=re.fullmatch(r'PASS sgmap commands=(\d+) entries=(\d+) outputs=(\d+) first_checks=(\d+) cycles=(\d+) command_holds=(\d+) entry_holds=(\d+) output_holds=(\d+) reads=(\d+) writes=(\d+) resets=(\d+) recovery=(\d+) max_latency=(\d+) states=7f\n.*',stdout,re.S)
            assert match,stdout;values=list(map(int,match.groups()));assert values[:4]==[len(m['commands']),len(m['entries']),len(m['outputs']),len(m['commands'])]
            assert values[10:12]==[16,64] and all(values[k]>0 for k in [4,5,6,7,8,9])
            names=['accepted_commands','accepted_entries','output_tokens','first_valid_checks','trace_nonreset_cycles','command_hold_checks','entry_hold_checks','output_hold_checks','ram_reads','ram_writes','reset_probes','fresh_recovery_commands','observed_maximum_first_latency']
            item=dict(zip(names,values));item.update(dict(zip(plan['profile_fields'],p)),status='PASS',**frozen(m),**verify(work/'actual.txt',m,p));item['output']=stdout.strip()
            report['profiles'].append(item);report['remaining_profiles'].pop(0);report.pop('current_profile');save();print(f'PASS sgmap N={n} commands={len(m["commands"])}',flush=True)
        for key,value in INVALID:run([iv,'-g2012','-tnull','-s','ram_sg_range_map',f'-Pram_sg_range_map.{key}={value}','-f','files.f'],ROOT,True)
        assert initial==hashes(),'source changed during frozen matrix';assert len(report['commands'])==19
        keys=['accepted_commands','accepted_entries','output_tokens','first_valid_checks','trace_nonreset_cycles','command_hold_checks','entry_hold_checks','output_hold_checks','ram_reads','ram_writes','reset_probes','fresh_recovery_commands','checked_outputs','active_map_row_checks','exact_latency_checks','fragment_gap_checks','small_byte_mapping_checks']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],invalid_parameter_rejections=8,totals={key:sum(p[key] for p in report['profiles']) for key in keys},
            oracle='Unbounded prefix-interval intersection, ordered original segment indices and separate byte-map crosschecks for small maps. Valid replacement publishes an immutable logical list; invalid replacement retains old list. All physical active rows checked against that list.',
            counter_scope='Main accept/output/latency/map/byte checks are main-only. Trace cycles, holds and RAM access counters include all nonreset main/probe/fresh activity.')
        save();print('PASS sgmap profiles=5 children=19',flush=True)
    except BaseException as error:
        report.update(status=['NOT_RUN','HW_UNVERIFIED'],failure=repr(error));save();archive();raise
    finally:temporary.cleanup()


if __name__=='__main__':main()
