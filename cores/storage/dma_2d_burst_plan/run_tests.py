#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded byte-enumeration oracle; no network, upstream code or bus model."""
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
BASELINE='e2ccd5380052e92a5430e97b6fdbf0621a17503c'


def pack(parts):
    word=0
    for value,width in parts:
        assert width>0 and 0<=value<1<<width,(value,width)
        word=(word<<width)|value
    return word


def vectors(a,b,m,t):
    rng=random.Random(0x32444d41+a*17+b+m+t)
    limit=1<<a;tag_mask=(1<<t)-1
    inputs=[];outputs=[];latencies=[]
    cov=dict(empty=0,range=0,ok=0,negative_stride=0,zero_stride=0,
        overlapping_rows=0,repeated_rows=0,single_row=0,unaligned=0,
        single_beat=0,partial_head=0,partial_tail=0,boundary_splits=0,
        max_bursts=0,effective_max_bursts=0,exhaustive=0,bytes_enumerated=0,rows_checked=0,
        most_negative_stride=0,most_positive_stride=0,maximum_rows=0,
        maximum_row_bytes=0,high_address=0)
    def add(base,n,rows,stride,exhaustive=False):
        tag=tag_mask if len(inputs)%4==0 else rng.getrandbits(t)
        inputs.append(pack(((base,a),(n,32),(rows,16),(stride&((1<<(a+1))-1),a+1),(tag,t))))
        cov['negative_stride']+=stride<0;cov['zero_stride']+=stride==0
        cov['single_row']+=rows==1;cov['most_negative_stride']+=stride==-limit
        cov['most_positive_stride']+=stride==limit-1;cov['maximum_rows']+=rows==65535
        cov['maximum_row_bytes']+=n==0xffffffff;cov['high_address']+=base>=(1<<(a-1))
        cov['exhaustive']+=exhaustive
        status=0
        if n==0 or rows==0:status=1
        else:
            # Enumerate *all* row starts rather than use the RTL endpoint proof.
            starts=[base+r*stride for r in range(rows)]
            cov['rows_checked']+=rows
            if any(start<0 or start+n>limit for start in starts):status=2
        if status:
            cov['empty' if status==1 else 'range']+=1
            latencies.append(0 if status==1 else 17)
            outputs.append(pack(((status,2),(tag,t),(0,1),(0,a),(0,9),(0,15),
                (0,b),(0,b),(0,16),(0,32),(0,48),(0,1),(0,1),(1,1),(1,1))))
            return
        cov['ok']+=1;latencies.append(18)
        cov['overlapping_rows']+=rows>1 and abs(stride)<n
        cov['repeated_rows']+=rows>1 and stride==0
        flattened=0
        for r,start in enumerate(starts):
            # Actual per-byte addresses independently create occupied aligned
            # beats. Group those beats afterward; do not reuse the RTL's
            # head/capacity/covered arithmetic or its range-extrema shortcut.
            occupied={}
            for address in range(start,start+n):
                aligned=address-address%b
                occupied[aligned]=occupied.get(aligned,0)|(1<<(address%b))
            cov['bytes_enumerated']+=n
            cov['unaligned']+=start%b!=0
            items=list(occupied.items());groups=[];group=[]
            for item in items:
                if group and (len(group)==m or item[0]//4096!=group[0][0]//4096):
                    groups.append(group);group=[]
                group.append(item)
            if group:groups.append(group)
            rowoff=0
            for i,group in enumerate(groups):
                addr=group[0][0];first_mask=group[0][1];last_mask=group[-1][1]
                byte_count=sum(mask.bit_count() for _,mask in group)
                last_row=i==len(groups)-1;last=r==rows-1 and last_row
                cov['single_beat']+=len(group)==1;cov['partial_head']+=first_mask!=(1<<b)-1
                cov['partial_tail']+=last_mask!=(1<<b)-1;cov['max_bursts']+=len(group)==m
                cov['effective_max_bursts']+=len(group)==min(m,4096//b)
                cov['boundary_splits']+=not last_row and (addr+len(group)*b)%4096==0
                outputs.append(pack(((0,2),(tag,t),(1,1),(addr,a),(len(group),9),(byte_count,15),
                    (first_mask,b),(last_mask,b),(r,16),(rowoff,32),(flattened,48),
                    (int(i==0),1),(int(last_row),1),(int(r==0 and i==0),1),(int(last),1))))
                rowoff+=byte_count;flattened+=byte_count
            assert rowoff==n
        assert flattened==n*rows
    # Canonical empties override all irrelevant address and stride inputs.
    add(limit-1,0,65535,-limit);add(limit-1,0xffffffff,0,limit-1)
    add(0,0,0,0);add(0,1,1,-limit);add(limit-1,1,1,limit-1)
    # Reject a later row atomically, even when the first row is valid.
    add(0,1,2,-1);add(limit-2,2,2,1);add(1,1,2,-limit)
    add(limit-1,2,1,0);add(0,0xffffffff,2,limit-1)
    add(limit-1,1,65535,1);add(0,1,65535,-1)
    # The most-positive stride can still be valid when endpoints are exact.
    add(0,1,2,limit-1)
    for start in [0,1,b-1,b,4095,4096,4097,limit-1]:
        if start>=limit:continue
        for length in [1,2,b,b+1,min(m*b+1,8193)]:
            if length>0xffffffff:continue
            add(start,length,1,0)
    for stride in [-2*b-1,-b,-1,0,1,b,2*b+1]:
        add(min(limit//2,8192),2*b+1,4,stride)
    add(1024,1,257,1);add(2048,1,257,-1)
    add(0,1,65535,limit-1);add(limit-1,1,65535,-limit)
    # Local exhaustive byte-lane/length/stride products stay finite.
    for lane,length,rows,stride in itertools.product(range(min(b+1,9)),
            range(1,min(2*b+2,10)),[1,2],[-b,0,b+1]):
        add(limit//2+lane,length,rows,stride,True)
    if a>12:
        add(4093,9,3,-5)
        add(4095,min(2*m*b+3,8197),2,8192)
        add(limit-2*b-1,b+1,2,-b-1)
    # Maximum row counter is fully completed, but byte enumeration is small.
    # Only the default profile carries this finite 65,535-token stress case.
    if a==32:add(0,1,65535,0)
    for number in range(220):
        rows=rng.randrange(1,7);length=rng.randrange(1,min(2*m*b+5,258))
        stride=rng.choice([-2*b-3,-b,-1,0,1,b,2*b+3])
        if number%17==0:base=rng.randrange(min(limit,32))
        elif number%19==0:base=limit-1-rng.randrange(32)
        elif number%13==0:base=(4090+rng.randrange(12))%limit
        else:base=rng.randrange(limit)
        add(base,length,rows,stride)
    assert cov['empty'] and cov['range'] and cov['ok'] and cov['negative_stride']
    assert cov['repeated_rows'] and cov['single_beat'] and cov['effective_max_bursts']
    return inputs,outputs,latencies,cov


def main():
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    exe={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ('iverilog','vvp')}
    if not all(exe.values()):raise RuntimeError('NOT_RUN local Icarus required')
    report=dict(baseline_commit=BASELINE,status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
        example_status=['LINT_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],commands=[],profiles=[],
        dependencies=[],invalid_parameter_rejections=10,per_process_timeout_seconds=20,
        oracle='all-row Python integer range check, per-byte occupied-beat enumeration, then independent grouping by count and page',
        not_run=['synthesis','PnR','STA','board','expanded regression'])
    def run(args,cwd=ROOT,reject=False):
        argv=[exe[args[0]],*map(str,args[1:])]
        r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        record=dict(command=argv,returncode=r.returncode,stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20)
        report['commands'].append(record)
        if reject:
            assert r.returncode>0 and 'dma_2d_burst_plan_invalid_parameter__see_README' in r.stderr,record
        else:assert r.returncode==0 and not r.stderr,record
        return r.stdout.strip()
    report['tool_version']=run(['iverilog','-V']).splitlines()[0]
    run(['iverilog','-g2012','-Wall','-tnull','-s','dma_2d_burst_plan','-f','files.f'])
    run(['iverilog','-g2012','-Wall','-tnull','-s','dma_plan32','-f','example/files.f'])
    with tempfile.TemporaryDirectory(prefix='anscore_dma2d_') as tmp:
        for a,b,m,t in [(12,1,1,1),(16,4,3,3),(32,4,16,8),(48,8,64,16),(64,64,256,32)]:
            folder=Path(tmp)/f'a{a}_b{b}_m{m}';folder.mkdir()
            inputs,outputs,lats,cov=vectors(a,b,m,t);digests={}
            for name,values in [('input.hex',inputs),('golden.hex',outputs),('latency.hex',lats)]:
                data=''.join(f'{v:x}\n' for v in values)
                (folder/name).write_text(data,encoding='ascii',newline='\n');digests[name]=hashlib.sha256(data.encode()).hexdigest()
            params=dict(A=a,B=b,M=m,T=t,INPUTS=len(inputs),OUTPUTS=len(outputs))
            run(['iverilog','-g2012','-Wall','-s','tb',*[f'-Ptb.{k}={v}' for k,v in params.items()],'-o','sim.vvp',
                ROOT/'rtl/dma_2d_burst_plan.sv',ROOT/'sim/tb_dma_2d_burst_plan.sv'],folder)
            result=run(['vvp','sim.vvp'],folder);first=result.splitlines()[0]
            assert first.startswith('PASS dma2d '),result
            metrics={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',first)}
            assert metrics['inputs']==len(inputs) and metrics['outputs']==len(outputs)
            report['profiles'].append(dict(addr_w=a,data_bytes=b,max_burst_beats=m,tag_w=t,
                coverage=cov,vectors_sha256=digests,**metrics,result=result))
            print(first,flush=True)
        for name,value in [('ADDR_W',11),('ADDR_W',65),('DATA_BYTES',0),('DATA_BYTES',3),('DATA_BYTES',128),
                ('MAX_BURST_BEATS',0),('MAX_BURST_BEATS',257),('TAG_W',0),('TAG_W',33),('DATA_BYTES',-1)]:
            run(['iverilog','-g2012','-tnull','-s','dma_2d_burst_plan',f'-Pdma_2d_burst_plan.{name}={value}','-f','files.f'],reject=True)
    names=[f for f in sorted(ROOT.rglob('*')) if f.is_file() and f.name!='verification.json']
    for f in names:
        data=f.read_bytes();data.decode('utf-8');assert b'\r' not in data,str(f)
    report['source_sha256']={f.relative_to(ROOT).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in names}
    report['resource_risk']=dict(default='LOW',maximum='MEDIUM',physical_resources_measured=False,
        preflight_adder_bits_default=50,preflight_adder_bits_maximum=82,
        internal_register_bits_default=429,internal_register_bits_maximum=621,
        output_register_bits_default=175,output_register_bits_maximum=351,
        payload_memory_bits=0,parallel_multipliers=0)
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('PASS finite 2D DMA burst planning; HW_UNVERIFIED',flush=True)


if __name__=='__main__':main()
