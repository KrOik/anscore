#!/usr/bin/env python3
"""Finite exact-cost frontier and exhaustive-subset oracles for budget selection."""
from __future__ import annotations
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
BASELINE='99b5c8c1b3530775bb9dca0e5b4d1df07a014f68'


def fixtures(m,cap,cw,vw):
    cmax=(1<<cw)-1;vmax=(1<<vw)-1;frames=[]
    def add(items=(),capacity=None,masked=False):
        raw=[(min(cmax,c),min(vmax,v),k) if len(item)==3 else (min(cmax,c),min(vmax,v),1)
             for item in items for c,v,*rest in [item] for k in [rest[0] if rest else 1]]
        if masked:raw.insert(0,(cmax,vmax,0))
        frames.append((raw,cap if capacity is None else capacity))
    add(capacity=0);add();add([(cmax,vmax,0)]*3)
    add([(0,1)],0);add([(0,0)],0);add([(cmax,vmax)],0);add([(cmax,vmax)])
    add([(0,vmax)]*m);add([(0,0)]*m)
    add([(1,1)]*m,min(cap,m//2));add([(cmax,vmax)]*m)
    add([(0,vmax)]*(m+1));add([(0,vmax)]*(m+1),cap+1)
    add([(0,1)],0xffffffff);add(capacity=cap+1)
    add([(0,1),(cmax,1)],masked=True)
    add([(2,3),(1,3)],min(cap,2));add([(1,1)]*min(m,4),min(cap,1))
    add([(3,5),(2,4),(2,4)],min(cap,4))
    add([(0,1)]*m+[(cmax,vmax,0)]*3,capacity=0,masked=True)
    if m==4 and cap==3 and cw==1 and vw==1:
        options=list(itertools.product((0,1),repeat=2))
        for length in range(4):
            for items in itertools.product(options,repeat=length):
                for capacity in range(4):add(items,capacity)
    rng=random.Random(20261108+m*41+cap*3+cw*17+vw)
    for number in range(24):
        length=rng.randrange(m+3);raw=[]
        for i in range(length):
            c=rng.choice((0,1,cmax,min(cmax,cap+1),rng.randrange(cmax+1)))
            v=rng.choice((0,1,vmax,rng.randrange(vmax+1)))
            raw.append((c,v,int(rng.randrange(5)!=0)))
        add(raw,rng.randrange(cap+1),masked=number%5==0)
    return frames


def exact_frontier(items,capacity):
    # States describe exact consumed cost, not best results for each budget.
    # Snapshot stages also avoid depending on an in-place descending loop.
    states={0:(0,0)};transitions=0
    for index,(cost,value) in enumerate(items):
        following=states.copy()
        for used,(total,mask) in states.items():
            transitions+=1;new_cost=used+cost
            if new_cost>capacity:continue
            candidate=(total+value,mask|(1<<index))
            prior=following.get(new_cost)
            if prior is None or candidate[0]>prior[0] or (candidate[0]==prior[0] and candidate[1]<prior[1]):
                following[new_cost]=candidate
        states=following
    cost,(value,mask)=min(states.items(),key=lambda pair:(-pair[1][0],pair[0],pair[1][1]))
    return value,cost,mask,transitions


def brute_force(items,capacity):
    best=(0,0,0)
    for mask in range(1<<len(items)):
        cost=sum(c for i,(c,v) in enumerate(items) if mask>>i&1)
        if cost>capacity:continue
        value=sum(v for i,(c,v) in enumerate(items) if mask>>i&1)
        if (-value,cost,mask)<(-best[0],best[1],best[2]):best=(value,cost,mask)
    return best


def pack(parts):
    result=0
    for value,width in parts:
        assert width>0 and 0<=value<(1<<width),(value,width)
        result=(result<<width)|value
    return result


def vectors(m,cap,cw,vw,tw):
    iw=max(1,(m-1).bit_length());countw=m.bit_length();bw=max(1,cap.bit_length());sw=vw+(m-1).bit_length()
    inputs=[];outputs=[];latencies=[];frames=fixtures(m,cap,cw,vw)
    metrics={'frames':len(frames),'normal_frames':0,'empty_frames':0,'error_frames':0,'overflow_frames':0,
        'bad_capacity_frames':0,'brute_force_crosschecks':0,'frontier_transitions':0,'maximum_value':0,'dp_cells':0}
    for number,(raw,capacity) in enumerate(frames):
        kept=[(c,v) for c,v,k in raw if k];error=int(len(kept)>m)|(int(capacity>cap)<<1)
        tag=((1<<tw)-1 if number%4==0 else number*17+3)&((1<<tw)-1)
        raw=raw or [(0,0,0)]
        for i,(cost,value,keep) in enumerate(raw):
            inputs.append(pack(((tag if i==0 else tag^((1<<tw)-1),tw),
                (capacity if i==0 else capacity^0xffffffff,32),(int(i==len(raw)-1),1),(keep,1),(value,vw),(cost,cw))))
        metrics['error_frames']+=bool(error);metrics['overflow_frames']+=bool(error&1);metrics['bad_capacity_frames']+=bool(error&2)
        if error or not kept:
            metrics['empty_frames']+=not error
            latencies.append(0)
            outputs.append(pack(((tag,tw),(capacity,32),(error,2),(0,bw),(0,sw),(0,countw),
                (1,1),(1,1),(0,1),(0,1),(0,iw),(0,vw),(0,cw))))
        else:
            metrics['normal_frames']+=1
            value,cost,mask,transitions=exact_frontier(kept,capacity)
            if len(kept)<=10:
                assert (value,cost,mask)==brute_force(kept,capacity)
                metrics['brute_force_crosschecks']+=1
            metrics['frontier_transitions']+=transitions;metrics['maximum_value']=max(metrics['maximum_value'],value)
            cells=sum(capacity-c+1 for c,v in kept if c<=capacity)
            metrics['dp_cells']+=cells
            latencies.append(capacity+2*len(kept)+3*cells+4)
            for i,(item_cost,item_value) in enumerate(kept):
                outputs.append(pack(((tag,tw),(capacity,32),(0,2),(cost,bw),(value,sw),(len(kept),countw),
                    (int(i==len(kept)-1),1),(int(i==0),1),(1,1),((mask>>i)&1,1),(i,iw),(item_value,vw),(item_cost,cw))))
    metrics['input_beats']=len(inputs);metrics['output_tokens']=len(outputs);metrics['maximum_valid_latency']=max(latencies)
    return inputs,outputs,latencies,metrics


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vv=os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    if not iv or not vv:raise RuntimeError('NOT_RUN: Icarus unavailable')
    commands=[];cases=[]
    def run(argv,cwd,negative=False,version=False):
        r=subprocess.run([str(a) for a in argv],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        rec={'argv':[str(a) for a in argv],'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'timeout_seconds':20};commands.append(rec)
        if negative:assert r.returncode>0 and 'budget_knapsack_invalid_parameters__see_README' in r.stdout+r.stderr,rec
        else:assert r.returncode==0 and (version or not r.stderr),rec
        return r.stdout
    version=run([iv,'-V'],ROOT,version=True).splitlines()[0]
    with tempfile.TemporaryDirectory(prefix='anscore_knapsack_') as tmp:
        temp=Path(tmp);rtl=ROOT/'rtl/budget_knapsack.sv';tb=ROOT/'sim/tb_budget_knapsack.sv'
        run([iv,'-g2012','-Wall','-tnull','-s','budget_knapsack','-s','select16','-f','files.f','examples/select16.sv'],ROOT)
        for m,cap,cw,vw,tw in [(1,0,1,1,1),(1,3,2,2,1),(4,3,1,1,3),(5,7,4,5,8),
                              (16,63,8,16,8),(17,31,6,9,16),(2,255,1,1,1),(64,255,16,24,32)]:
            folder=temp/f'm{m}_c{cap}_w{cw}_v{vw}_t{tw}';folder.mkdir()
            inputs,outputs,latencies,metrics=vectors(m,cap,cw,vw,tw)
            digests={}
            for filename,values in [('input.hex',inputs),('golden.hex',outputs),('latency.hex',latencies)]:
                text=''.join(f'{value:x}\n' for value in values);(folder/filename).write_text(text,encoding='ascii',newline='\n')
                digests[filename]=hashlib.sha256(text.encode('ascii')).hexdigest()
            parameters={'MAX_ITEMS':m,'MAX_CAPACITY':cap,'COST_W':cw,'VALUE_W':vw,'TAG_W':tw,
                        'INPUTS':len(inputs),'OUTPUTS':len(outputs),'FRAMES':len(latencies)}
            run([iv,'-g2012','-Wall','-s','tb',*[f'-Ptb.{k}={v}' for k,v in parameters.items()],'-o','sim.vvp',rtl,tb],folder)
            output=run([vv,'sim.vvp'],folder)
            assert f"frames={metrics['frames']} outputs={len(outputs)}" in output and 'reset_probes=12' in output,output
            cases.append({k:parameters[k] for k in ['MAX_ITEMS','MAX_CAPACITY','COST_W','VALUE_W','TAG_W']}|
                         metrics|{'status':'PASS','vectors_sha256':digests,'output':output.strip()})
        invalid=[('MAX_ITEMS',0),('MAX_ITEMS',65),('MAX_CAPACITY',-1),('MAX_CAPACITY',256),
                 ('COST_W',0),('COST_W',17),('VALUE_W',0),('VALUE_W',25),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','budget_knapsack',f'-Pbudget_knapsack.{key}={value}','-f','files.f'],ROOT,negative=True)
    names=['.gitattributes','files.f','rtl/budget_knapsack.sv','examples/select16.sv','sim/run.py','sim/tb_budget_knapsack.sv']
    for name in names:assert b'\r' not in (ROOT/name).read_bytes(),name
    report={'baseline_commit':BASELINE,'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],'tool':version,
        'commands':commands,'cases':cases,'invalid_parameter_rejections':len(invalid),
        'frames':sum(c['frames'] for c in cases),'output_tokens':sum(c['output_tokens'] for c in cases),
        'brute_force_crosschecks':sum(c['brute_force_crosschecks'] for c in cases),
        'oracle':'exact-cost frontier snapshots plus exhaustive subsets for K<=10; exact full selection bitmap and behavioral latency',
        'source_sha256':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names},
        'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f"PASS knapsack profiles={len(cases)} frames={report['frames']} outputs={report['output_tokens']} commands={len(commands)}")


if __name__=='__main__':main()
