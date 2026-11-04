#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite independent interval-set oracle; bounded local Icarus processes only."""
import hashlib
from bisect import bisect_left
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
BASELINE="99b5c8c1b3530775bb9dca0e5b4d1df07a014f68"


def vectors(m,t):
    units=1<<m;rng=random.Random(0x42554444+m*101+t)
    live={};starts=[];lines=[]
    coverage=dict(allocate=0,release=0,clear=0,query=0,no_space=0,
                  fragmentation_failures=0,bad_request=0,not_allocated=0,reset=0)
    def free_block(a,o):
        # Nonoverlapping live intervals are ordered only by geometric start.
        # The last interval starting before the candidate end is the only
        # possible predecessor overlap. This avoids a quadratic host scan.
        i=bisect_left(starts,a+(1<<o))
        return i==0 or starts[i-1]+(1<<live[starts[i-1]])<=a
    def add(op=3,o=0,b=0,reset=False):
        nonlocal starts
        status=rb=0;tag=rng.getrandbits(t)
        if reset:
            live.clear();coverage['reset']+=1
        else:
            coverage[('allocate','release','clear','query')[op]]+=1
            if op in (0,1) and (o>m or (op==1 and (b>=units or b% (1<<o)))):
                status=2;coverage['bad_request']+=1
            elif op==0:
                # Enumerate address-aligned geometric intervals; no tree, split,
                # sibling, summary or traversal representation is used.
                candidates=[a for a in range(0,units,1<<o) if free_block(a,o)]
                if candidates:rb=candidates[0];live[rb]=o
                else:
                    status=1;coverage['no_space']+=1
                    if units-sum(1<<v for v in live.values()) >= 1<<o:
                        coverage['fragmentation_failures']+=1
            elif op==1:
                if live.get(b)!=o:status=3;coverage['not_allocated']+=1
                else:rb=b;del live[b]
            elif op==2:live.clear()
        starts=sorted(live)
        free=units-sum(1<<o for o in live.values())
        avail=[o for o in range(m+1) if any(free_block(a,o) for a in range(0,units,1<<o))]
        occ=head=0
        for a,o2 in live.items():
            occ|=((1<<(1<<o2))-1)<<a;head|=1<<a
        lines.append(f'{int(reset)} {op} {o} {b:x} {tag:x} {status} {rb:x} {free} '
                     f'{int(bool(avail))} {max(avail) if avail else 0} {occ:x} {head:x}\n')
    add(reset=True);add();add(0,m);add(0,0);add(1,m,units)
    add(1,15,0);add(1,0,0xffffffff)
    if m: add(1,m,1);add(1,m-1,0)
    add(1,m,0);add(1,m,0);add(2,15,0xffffffff)
    # Fill with minimum blocks, leave nonadjacent holes, and force a
    # fragmented failure before full coalescing permits a root allocation.
    for _ in range(units):add(0,0)
    add(0,0)
    for a in range(0,units,2):add(1,0,a)
    if m:add(0,1)
    for a in range(1,units,2):add(1,0,a)
    add(0,m);add(1,m,0);add(3,15,0xffffffff)
    if m<=1:
        alphabet=[(0,0,0),(1,0,0),(0,m+1,0),(1,m,units),(3,15,0xffffffff),(2,15,0xffffffff)]
        if m:alphabet += [(0,1,0),(1,0,1)]
        for seq in itertools.product(alphabet,repeat=3):
            add(reset=True)
            for cmd in seq:add(*cmd)
    # Every legal release base/order is tried both against an empty pool and
    # against a single full-pool allocation. Interior and wrong-size frees
    # must preserve ownership even though their geometry is legal.
    add(2)
    for order in range(m+1):
        for a in range(0,units,1<<order):add(1,order,a)
    add(0,m)
    for order in range(m):
        for a in range(0,units,1<<order):add(1,order,a)
    add(1,m,0)
    for i in range(420):
        k=rng.randrange(10)
        if k<4:add(0,rng.randrange(m+2))
        elif k<7 and live:
            a=rng.choice(sorted(live));o=live[a]
            if k==6:o=(o+1)%(m+2)
            add(1,o,a)
        elif k==7:add(1,rng.randrange(m+2),rng.randrange(units+2))
        elif k==8:add(3,15,rng.getrandbits(32))
        else:add(2,15,rng.getrandbits(32))
        if i in (87,209,331):add(reset=True)
    add(2);add(0,m);add(1,m,0);add()
    return ''.join(lines),coverage


def main():
    suite=ROOT.parents[2]/'tools'/'oss-cad-suite'/'oss-cad-suite'
    env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    executables={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ('iverilog','vvp')}
    if not all(executables.values()):raise SystemExit('NOT_RUN: local Icarus/vvp missing')
    report=dict(baseline=BASELINE,status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
                oracle='independent live interval set plus aligned geometric free-space enumeration',
                example_status=['LINT_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],
                per_process_timeout_seconds=20,profiles=[],commands=[],invalid_parameter_rejections=4,
                dependencies=[],not_run=['synthesis','PnR','STA','board','expanded regression'])
    def run(args,reject=False):
        cmd=[executables[args[0]],*map(str,args[1:])]
        r=subprocess.run(cmd,cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        report['commands'].append(dict(command=cmd,returncode=r.returncode,stdout=r.stdout.strip(),
                                       stderr=r.stderr.strip(),timeout_seconds=20))
        if reject:
            if r.returncode==0 or 'buddy_pool_allocator_invalid_parameter' not in r.stderr:
                raise RuntimeError('illegal parameter was not explicitly rejected: '+str(args))
        elif r.returncode or r.stderr.strip():
            raise RuntimeError(str(args)+'\n'+r.stdout+r.stderr)
        return r.stdout.strip()
    report['tool_version']=run(['iverilog','-V']).splitlines()[0]
    run(['iverilog','-g2012','-Wall','-tnull','-s','buddy_pool_allocator','-f','files.f'])
    run(['iverilog','-g2012','-Wall','-tnull','-s','pool64_example','-f','example/files.f'])
    with tempfile.TemporaryDirectory(prefix='anscore_buddy_') as tmp:
        tmp=Path(tmp)
        for m,t in [(0,1),(1,3),(3,8),(6,8),(10,32)]:
            data,coverage=vectors(m,t);vp=tmp/f'vectors_{m}.txt';vp.write_text(data,newline='\n')
            exe=tmp/f'profile_{m}.vvp'
            run(['iverilog','-g2012','-Wall','-s','tb_buddy_pool_allocator',
                 f'-Ptb_buddy_pool_allocator.M={m}',f'-Ptb_buddy_pool_allocator.T={t}',
                 '-o',exe,'sim/tb_buddy_pool_allocator.sv','rtl/buddy_pool_allocator.sv'])
            out=run(['vvp',exe,f'+vectors={vp}'])
            first=out.splitlines()[0]
            if not first.startswith('PASS buddy '):raise RuntimeError(out)
            metrics={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',first)}
            report['profiles'].append(dict(max_order=m,tag_w=t,coverage=coverage,
                vectors_sha256=hashlib.sha256(data.encode()).hexdigest(),**metrics,result=out))
            print(first,flush=True)
        for parameter,value in [('MAX_ORDER',-1),('MAX_ORDER',11),('TAG_W',0),('TAG_W',33)]:
            run(['iverilog','-g2012','-tnull','-s','buddy_pool_allocator',
                 f'-Pbuddy_pool_allocator.{parameter}={value}','-f','files.f'],True)
    source_paths=[x for x in sorted(ROOT.rglob('*')) if x.is_file() and x.name!='verification.json']
    for path in source_paths:
        if b'\r' in path.read_bytes():raise RuntimeError('non-LF package file '+str(path))
    report['source_sha256']={x.relative_to(ROOT).as_posix():hashlib.sha256(x.read_bytes()).hexdigest() for x in source_paths}
    report['resource_risk']=dict(default='LOW',maximum='MEDIUM',metadata_bits_default=635,metadata_bits_maximum=12282,
                                 physical_resources_measured=False)
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',newline='\n')
    print('PASS finite buddy pool checks; HW_UNVERIFIED',flush=True)


if __name__=='__main__':main()
