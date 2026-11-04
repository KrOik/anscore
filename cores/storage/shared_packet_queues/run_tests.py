#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite deque-of-packets oracle and independent pool ownership snapshots."""
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
BASELINE='807d992b6b0e793c08ceba2d44993d21c1dd1583'


def pack(parts):
    word=0
    for value,width in parts:
        assert width>0 and 0<=value<1<<width,(value,width)
        word=(word<<width)|value
    return word


def vectors(q,c,d,t):
    rng=random.Random(0x51504f4f+q*101+c+d+t)
    queues=[[] for _ in range(q)]
    data_mask=(1<<d)-1;tag_mask=(1<<t)-1;iw=max(1,(c-1).bit_length());cw=c.bit_length()
    inputs=[];outputs=[];latencies=[];snapshots=[]
    coverage=dict(push=0,pop=0,flush=0,query=0,committed_packets=0,popped_packets=0,
        empty=0,bad_queue=0,no_space=0,partial_rollbacks=0,flushed_packets=0,
        masked_tails=0,masked_first=0,exhaustive_sequences=0)
    def used():return sum(len(words) for queue in queues for tag,words in queue)
    def flat(queue):return [(v,tag,int(i==len(words)-1)) for tag,words in queue for i,v in enumerate(words)]
    def add(op=3,queue_id=0,raw=None):
        seq=len(latencies);tag=(tag_mask if seq%4==0 else rng.getrandbits(t))
        raw=list(raw if raw is not None else [(rng.getrandbits(d),rng.randrange(2))])
        raw=raw or [(0,0)]
        if op!=0:raw=raw[:1]
        old_free=c-used();valid=queue_id<q
        for i,(value,keep) in enumerate(raw):
            # First metadata owns PUSH; later op/queue/tag deliberately change.
            in_op=op if i==0 else rng.randrange(4)
            in_q=queue_id if i==0 else (queue_id^255)
            in_tag=tag if i==0 else tag^tag_mask
            last=int(i==len(raw)-1) if op==0 else seq%2
            inputs.append(pack(((in_op,2),(in_q,8),(in_tag,t),(last,1),(keep,1),(value&data_mask,d))))
        kept=[v&data_mask for v,k in raw if k]
        coverage[('push','pop','flush','query')[op]]+=1
        status=0;latency=0;data_result=[]
        if not valid:status=2;coverage['bad_queue']+=1
        elif op==0:
            coverage['masked_first']+=not raw[0][1];coverage['masked_tails']+=not raw[-1][1]
            if not kept:status=1
            elif len(kept)>old_free:
                status=3;latency=2*old_free;coverage['no_space']+=1
                coverage['partial_rollbacks']+=old_free>0
            else:
                queues[queue_id].append((tag,kept));coverage['committed_packets']+=1
                latency=4 if raw[-1][1] else 1
        elif op==1:
            if not queues[queue_id]:status=1
            else:
                packet_tag,words=queues[queue_id].pop(0);latency=1;coverage['popped_packets']+=1
                after_cells=len(flat(queues[queue_id]));after_packets=len(queues[queue_id])
                for i,value in enumerate(words):
                    remaining=len(words)-i-1
                    data_result.append(pack(((op,2),(0,2),(queue_id,8),(tag,t),(1,1),(int(i==0),1),
                        (int(remaining==0),1),(i,iw),(value,d),(packet_tag,t),(old_free+i+1,cw),
                        (after_cells+remaining,cw),(after_packets+int(remaining>0),cw))))
        elif op==2:
            latency=2*len(flat(queues[queue_id]));coverage['flushed_packets']+=len(queues[queue_id]);queues[queue_id]=[]
        coverage['empty']+=status==1
        if data_result:outputs.extend(data_result)
        else:
            outputs.append(pack(((op,2),(status,2),(queue_id,8),(tag,t),(0,1),(1,1),(1,1),(0,iw),
                (0,d),(0,t),(c-used(),cw),(len(flat(queues[queue_id])) if valid else 0,cw),
                (len(queues[queue_id]) if valid else 0,cw))))
        latencies.append(latency)
        snapshots.append(str(c-used())+'\n')
        for queue in queues:
            cells=flat(queue);snapshots.append(f'{len(cells)} {len(queue)}\n')
            snapshots.extend(f'{v:x} {tag:x} {last}\n' for v,tag,last in cells)
    def push(queue_id,words,masked_first=False,masked_tail=False):
        raw=[(v&data_mask,1) for v in words]
        if masked_first:raw.insert(0,(data_mask,0))
        if masked_tail:raw.append((data_mask,0))
        add(0,queue_id,raw)
    def clear_all():
        for i in range(q):add(2,i)
    for i in range(q):add(3,i);add(1,i);add(2,i)
    push(0,[],True,True)
    push(q,[0,1,2],True,True)
    for op in [1,2,3]:add(op,255)
    push(q-1,[data_mask]);push(0,range(c+1),True,True)
    for i in range(q):add(3,i)
    add(1,q-1);clear_all()
    for i in range(c):push(i%q,[i])
    push(0,[0]);add(1,(c-1)%q);push(0,[0,1],masked_tail=True)
    for i in range(q):add(3,i)
    clear_all();push(0,range(c),True,True);add(3,0);add(1,0)
    push(0,range(c+1));add(3,0)
    for i in range(min(q,4)):
        push(i,[data_mask],True,False);push(i,[0],False,True)
    if q>1:add(2,1)
    for i in range(q):add(1,i);add(3,i)
    clear_all()
    alphabet=[(0,0,[(0,1)]),(0,0,[(data_mask,1)]),(1,0,None),(2,0,None),(3,0,None),(0,q,[(0,1)])]
    if c==1:
        for seq in itertools.product(alphabet,repeat=3):
            clear_all();coverage['exhaustive_sequences']+=1
            for op,qi,raw in seq:add(op,qi,raw)
    elif c==3:
        alphabet += [(0,q-1,[(0,1),(1,1)]),(1,q-1,None)]
        for seq in itertools.product(alphabet,repeat=2):
            clear_all();coverage['exhaustive_sequences']+=1
            for op,qi,raw in seq:add(op,qi,raw)
    for number in range(220):
        op=rng.choices(range(4),(5,4,1,1))[0];qi=rng.randrange(q) if number%19 else q
        if op==0:
            length=c+1 if number%31==0 else rng.randrange(min(c+2,9))
            raw=[(rng.getrandbits(d),int(rng.randrange(6)!=0)) for _ in range(length)]
            if number%5==0:raw.insert(0,(data_mask,0))
            if number%7==0:raw.append((0,0))
            add(0,qi,raw)
        else:add(op,qi)
    for i in range(q):add(3,i)
    clear_all();push(q-1,range(c));add(1,q-1)
    return inputs,outputs,latencies,''.join(snapshots),coverage


def main():
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    exe={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ('iverilog','vvp')}
    if not all(exe.values()):raise RuntimeError('NOT_RUN local Icarus required')
    report=dict(baseline_commit=BASELINE,status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
        example_status=['LINT_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],commands=[],profiles=[],
        invalid_parameter_rejections=8,dependencies=[],per_process_timeout_seconds=20,
        oracle='independent deque-of-packets model, post-handshake credit snapshots and full shared-pool ownership partition',
        not_run=['synthesis','PnR','STA','board','expanded regression'])
    def run(args,cwd=ROOT,reject=False):
        argv=[exe[args[0]],*map(str,args[1:])]
        r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        report['commands'].append(dict(command=argv,returncode=r.returncode,stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if reject:
            assert r.returncode>0 and 'shared_packet_queues_invalid_parameter__see_README' in r.stderr,report['commands'][-1]
        else:assert r.returncode==0 and not r.stderr,report['commands'][-1]
        return r.stdout.strip()
    report['tool_version']=run(['iverilog','-V']).splitlines()[0]
    run(['iverilog','-g2012','-Wall','-tnull','-s','shared_packet_queues','-f','files.f'])
    run(['iverilog','-g2012','-Wall','-tnull','-s','packet_pool4','-f','example/files.f'])
    with tempfile.TemporaryDirectory(prefix='anscore_packet_queues_') as tmp:
        for q,c,d,t in [(1,1,1,1),(3,3,5,3),(2,8,8,8),(4,64,32,8),(16,256,64,32)]:
            folder=Path(tmp)/f'q{q}_c{c}';folder.mkdir()
            inputs,outputs,lats,snaps,coverage=vectors(q,c,d,t);digests={}
            for name,values in [('input.hex',inputs),('golden.hex',outputs),('latency.hex',lats)]:
                text=''.join(f'{v:x}\n' for v in values);(folder/name).write_text(text,encoding='ascii',newline='\n');digests[name]=hashlib.sha256(text.encode()).hexdigest()
            (folder/'snapshots.txt').write_text(snaps,encoding='ascii',newline='\n');digests['snapshots.txt']=hashlib.sha256(snaps.encode()).hexdigest()
            params=dict(Q=q,C=c,D=d,T=t,INPUTS=len(inputs),OUTPUTS=len(outputs),COMMANDS=len(lats))
            run(['iverilog','-g2012','-Wall','-s','tb',*[f'-Ptb.{k}={v}' for k,v in params.items()],'-o','sim.vvp',
                 ROOT/'rtl/shared_packet_queues.sv',ROOT/'sim/tb_shared_packet_queues.sv'],folder)
            result=run(['vvp','sim.vvp'],folder);first=result.splitlines()[0]
            assert first.startswith('PASS packets '),result
            metrics={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',first)}
            assert metrics['commands']==len(lats) and metrics['inputs']==len(inputs) and metrics['outputs']==len(outputs)
            report['profiles'].append(dict(queues=q,cells=c,data_w=d,tag_w=t,coverage=coverage,vectors_sha256=digests,**metrics,result=result))
            print(first,flush=True)
        for name,value in [('QUEUES',0),('QUEUES',17),('CELLS',0),('CELLS',257),('DATA_W',0),('DATA_W',65),('TAG_W',0),('TAG_W',33)]:
            run(['iverilog','-g2012','-tnull','-s','shared_packet_queues',f'-Pshared_packet_queues.{name}={value}','-f','files.f'],reject=True)
    names=[x for x in sorted(ROOT.rglob('*')) if x.is_file() and x.name!='verification.json']
    for f in names:
        b=f.read_bytes();b.decode('utf-8');assert b'\r' not in b,str(f)
    report['source_sha256']={x.relative_to(ROOT).as_posix():hashlib.sha256(x.read_bytes()).hexdigest() for x in names}
    report['resource_risk']=dict(default='LOW',maximum='MEDIUM',cell_storage_bits_default=3008,cell_storage_bits_maximum=26880,
        queue_metadata_bits_default=104,queue_metadata_bits_maximum=544,physical_resources_measured=False)
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('PASS finite shared packet queues; HW_UNVERIFIED',flush=True)


if __name__=='__main__':main()
