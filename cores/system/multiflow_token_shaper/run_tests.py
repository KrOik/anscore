#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent clock ledger, per-flow FIFO histories and modular-rank schedule."""
from collections import deque
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
BASELINE='d35ce742b34ffa7afebffe0b9f6705a825f469e1'


def pack(parts):
    word=0
    for value,width in parts:
        assert width>0 and 0<=value<1<<width,(value,width)
        word=(word<<width)|value
    return word


def vectors(f,w,d,t,q):
    rng=random.Random(0x53485052+f*71+w+d+t+q);mask=(1<<w)-1;dm=(1<<d)-1;tm=(1<<t)-1
    iw=max(1,(f-1).bit_length());qw=max(1,(q-1).bit_length())
    buckets=[dict(enabled=0,capacity=0,rate=0,tokens=0) for _ in range(f)]
    queues=[None]*f;histories=[deque() for _ in range(f)];offers=[None]*f
    phase=0;rr=0;out=None;rsp=None;cfg_offer=None;out_age=0;rsp_age=0;sequence=0
    inputs=[];pre=[];post=[];accepted=delivered=cfg_accepted=cfg_completed=0
    cov={k:0 for k in ['ticks','refill_saturations','wide_add_saturations','cfg_commit_tick','cfg_ok',
        'cfg_bad_flow','cfg_bad_values','cfg_stalls','cfg_held','ingress_stalls','egress_held',
        'held_owner_refills','invalid_cost','good_cost','eligible_bypasses','multi_eligible',
        'simultaneous_ingress','refill_and_debit','owner_credit_checks','queue_history_checks']}
    def cfg(flow,enable,cap,rate,initial,kind='normal'):
        return dict(flow=flow,enable=enable,capacity=cap,rate=rate,initial=initial,tag=rng.getrandbits(t),kind=kind)
    plan=deque(cfg(i,1,min(mask,3*(i+2)),min(mask,3*(i+2)),0 if i%2 else min(mask,3*(i+2)),'init') for i in range(f))
    plan.extend([cfg(f,1,mask,mask,0),cfg(0xffffffff,0,0,0,0),
        cfg(0,0,0,0,mask),cfg(f-1,0,0,mask,0),cfg(0,1,0,0,0),
        cfg(0,1,mask,mask,mask//2,'wide'),cfg(f-1,0,0,0,0),
        cfg(f-1,1,min(mask,7),min(mask,7),0)])
    next_config=0;freeze_until=0;traffic_end=6*q+1600
    deadline=24*q+5000+64*f
    for cycle in range(deadline):
        if cfg_offer is None and plan and cycle>=next_config:cfg_offer=plan.popleft()
        for i in range(f):
            if offers[i] is None and cycle<traffic_end and rng.randrange(4)!=0:
                sequence+=1;cap=buckets[i]['capacity']
                cost=rng.choice([0,1,mask,max(1,cap),min(mask,cap+1)])
                offers[i]=dict(cost=cost,data=(sequence*131+rng.getrandbits(d))&dm,tag=rng.getrandbits(t))
        cfg_in=cfg_offer or dict(flow=0,enable=0,capacity=0,rate=0,initial=0,tag=0)
        cr=int(rsp is None and (cfg_in['flow']>=f or queues[cfg_in['flow']] is None))
        cf=bool(cfg_offer is not None and cr)
        ready=[int(buckets[i]['enabled'] and queues[i] is None and
            not (rsp and rsp['cfg']['flow']==i) and not (cf and cfg_in['flow']==i)) for i in range(f)]
        tick=phase==q-1
        rready=bool(rsp and rsp_age>=3 and cycle%7!=0)
        if rsp and rsp['cfg'].get('kind')=='wide':rready=bool(rsp_age>=3 and tick)
        mready=bool(out and out_age>=(q+3 if delivered==0 else 3) and cycle%9 not in (1,2) and cycle>=freeze_until)
        offer_bits=sum((item is not None)<<i for i,item in enumerate(offers))
        inputs.append(pack(((int(cfg_offer is not None),1),(cfg_in['flow'],32),(cfg_in['enable'],1),
            (cfg_in['capacity'],w),(cfg_in['rate'],w),(cfg_in['initial'],w),(cfg_in['tag'],t),(int(rready),1),
            (offer_bits,f),(pack([((item or {}).get('cost',0),w) for item in reversed(offers)]),f*w),
            (pack([((item or {}).get('data',0),d) for item in reversed(offers)]),f*d),
            (pack([((item or {}).get('tag',0),t) for item in reversed(offers)]),f*t),(int(mready),1))))
        pre.append(pack(((cr,1),(int(rsp is not None),1),((rsp or {}).get('status',0),2),
            ((rsp or {}).get('cfg',{}).get('flow',0),32),((rsp or {}).get('cfg',{}).get('tag',0),t),
            (sum(v<<i for i,v in enumerate(ready)),f),(int(out is not None),1),
            ((out or {}).get('flow',0),32),((out or {}).get('bad',0),1),((out or {}).get('cost',0),w),
            ((out or {}).get('data',0),d),((out or {}).get('tag',0),t))))
        # Select by modular rank among independently defined eligible FIFO heads.
        eligible=[i for i,item in enumerate(queues) if item is not None and (item['bad'] or item['cost']<=buckets[i]['tokens'])]
        choice=min(eligible,key=lambda i:(i-rr)%f) if out is None and eligible else None
        cov['multi_eligible']+=out is None and len(eligible)>1
        if choice is not None:
            head=next((i for i in range(f) if (i-rr)%f==0 and queues[i] is not None),None)
            cov['eligible_bypasses']+=head is not None and head not in eligible
        if out:
            i=out['flow'];assert queues[i]=={k:v for k,v in out.items() if k!='flow'}
            assert histories[i] and histories[i][0]==queues[i];cov['queue_history_checks']+=1
            if not out['bad']:assert out['cost']<=buckets[i]['tokens'];cov['owner_credit_checks']+=1
        cov['ticks']+=tick;cov['cfg_stalls']+=cfg_offer is not None and not cr
        cov['cfg_held']+=rsp is not None and not rready;cov['egress_held']+=out is not None and not mready
        cov['ingress_stalls']+=sum(offers[i] is not None and not ready[i] for i in range(f))
        cov['simultaneous_ingress']+=sum(offers[i] is not None and ready[i] for i in range(f))>1
        cov['held_owner_refills']+=bool(tick and out and not mready and buckets[out['flow']]['enabled'])
        # Integer ledger: credit is saturated first, then delivered cost is
        # charged. A successful configuration ACK replaces that ledger value.
        for i,b in enumerate(buckets):
            amount=b['tokens']+(b['rate'] if tick and b['enabled'] else 0)
            cov['refill_saturations']+=amount>b['capacity'];cov['wide_add_saturations']+=amount>mask
            new=min(amount,b['capacity'])
            if out and mready and out['flow']==i and not out['bad']:
                assert new>=out['cost'];new-=out['cost'];cov['refill_and_debit']+=tick
            if rsp and rready and rsp['status']==0 and rsp['cfg']['flow']==i:
                c=rsp['cfg'];b.update(enabled=c['enable'],capacity=c['capacity'],rate=c['rate']);new=c['initial']
                cov['cfg_commit_tick']+=tick
            b['tokens']=new;assert 0<=new<=b['capacity']
        if out and mready:
            i=out['flow'];histories[i].popleft();queues[i]=None;rr=(i+1)%f
            cov['invalid_cost' if out['bad'] else 'good_cost']+=1;delivered+=1;out=None;out_age=0
        elif out:out_age+=1
        elif choice is not None:out=dict(queues[choice],flow=choice);out_age=0
        for i in range(f):
            if offers[i] is not None and ready[i]:
                assert queues[i] is None
                item=dict(offers[i],bad=int(offers[i]['cost']==0 or offers[i]['cost']>buckets[i]['capacity']))
                queues[i]=item;histories[i].append(item);offers[i]=None;accepted+=1
        if rsp and rready:
            cfg_completed+=1
            if rsp['cfg'].get('kind')=='wide' and rsp['status']==0:freeze_until=cycle+2*q+3
            rsp=None;rsp_age=0
        elif rsp:rsp_age+=1
        if cf:
            c=dict(cfg_offer);status=1 if c['flow']>=f else 2 if (c['initial']>c['capacity'] or
                c['rate']>c['capacity'] or c['enable'] and c['capacity']==0) else 0
            rsp=dict(cfg=c,status=status);rsp_age=0;cfg_accepted+=1
            cov[('cfg_ok','cfg_bad_flow','cfg_bad_values')[status]]+=1
            next_config=cycle+(1 if c.get('kind')=='init' else q+11);cfg_offer=None
        phase=(phase+1)%q
        state_parts=[(phase,qw),(rr,iw)]
        for i,b in enumerate(buckets):
            item=queues[i] or {}
            state_parts.extend([(b['enabled'],1),(b['capacity'],w),(b['rate'],w),(b['tokens'],w),
                (int(queues[i] is not None),1),(item.get('cost',0),w),(item.get('data',0),d),(item.get('tag',0),t),(item.get('bad',0),1)])
        post.append(pack(state_parts))
        if cycle>traffic_end and not plan and cfg_offer is None and rsp is None and not any(offers) and not any(queues) and out is None:
            assert accepted==delivered and cfg_accepted==cfg_completed;break
    else:raise AssertionError('finite oracle plan did not drain')
    assert cov['cfg_bad_flow'] and cov['cfg_bad_values'] and cov['cfg_commit_tick'] and cov['wide_add_saturations']
    assert cov['invalid_cost'] and cov['good_cost'] and cov['held_owner_refills'] and cov['ingress_stalls'] and cov['cfg_stalls']
    return inputs,pre,post,dict(cycles=len(inputs),accepted=accepted,delivered=delivered,
        configs=cfg_completed,coverage=cov)


def main():
    report=dict(baseline_commit=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],commands=[],profiles=[],dependencies=[],
        per_process_timeout_seconds=20,not_run=['synthesis','PnR','STA','board','expanded regression'])
    def save():
        (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    save()
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    exe={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ('iverilog','vvp')}
    if not all(exe.values()):raise RuntimeError('NOT_RUN local Icarus required')
    def run(args,cwd=ROOT,reject=False):
        argv=[exe[args[0]],*map(str,args[1:])]
        try:r=subprocess.run(argv,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired:
            report.update(status=['NOT_RUN','HW_UNVERIFIED'],timeout_command=argv,timeout_seconds=20)
            save();raise # No reduced fixture or timeout retry.
        record=dict(command=argv,returncode=r.returncode,stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20)
        report['commands'].append(record)
        if reject:assert r.returncode>0 and 'multiflow_token_shaper_invalid_parameter__see_README' in r.stderr,record
        else:assert r.returncode==0 and not r.stderr,record
        return r.stdout.strip()
    report['tool_version']=run(['iverilog','-V']).splitlines()[0]
    run(['iverilog','-g2012','-Wall','-tnull','-s','multiflow_token_shaper','-f','files.f'])
    run(['iverilog','-g2012','-Wall','-tnull','-s','dma_shape4','-f','example/files.f'])
    with tempfile.TemporaryDirectory(prefix='anscore_multiflow_shaper_') as tmp:
        for f,w,d,t,q in [(1,1,1,1,1),(3,5,7,3,3),(4,12,16,8,7),(4,16,32,8,16),(16,32,64,32,1024)]:
            folder=Path(tmp)/f'f{f}_w{w}_q{q}';folder.mkdir()
            inputs,pre,post,metrics=vectors(f,w,d,t,q);digests={}
            for name,values in [('input.hex',inputs),('pre.hex',pre),('post.hex',post)]:
                data=''.join(f'{v:x}\n' for v in values)
                (folder/name).write_text(data,encoding='ascii',newline='\n');digests[name]=hashlib.sha256(data.encode()).hexdigest()
            params=dict(F=f,W=w,D=d,T=t,Q=q,CYCLES=len(inputs))
            run(['iverilog','-g2012','-Wall','-s','tb',*[f'-Ptb.{k}={v}' for k,v in params.items()],'-o','sim.vvp',
                ROOT/'rtl/multiflow_token_shaper.sv',ROOT/'sim/tb_multiflow_token_shaper.sv'],folder)
            result=run(['vvp','sim.vvp'],folder);first=result.splitlines()[0]
            assert first.startswith('PASS shaper '),result
            observed={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',first)}
            assert observed['accepted']==metrics['accepted'] and observed['delivered']==metrics['delivered']
            assert observed['configs']==metrics['configs'] and observed['cycles']==metrics['cycles']
            report['profiles'].append(dict(flows=f,token_w=w,data_w=d,tag_w=t,quantum=q,
                vectors_sha256=digests,oracle=metrics,observed=observed,result=result));print(first,flush=True)
        for name,value in [('FLOWS',0),('FLOWS',17),('TOKEN_W',0),('TOKEN_W',33),('DATA_W',0),('DATA_W',65),
                ('TAG_W',0),('TAG_W',33),('QUANTUM',0),('QUANTUM',1025)]:
            run(['iverilog','-g2012','-tnull','-s','multiflow_token_shaper',f'-Pmultiflow_token_shaper.{name}={value}','-f','files.f'],reject=True)
    files=[p for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name!='verification.json']
    for p in files:
        data=p.read_bytes();data.decode('utf-8');assert b'\r' not in data,str(p)
    report.update(status=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
        example_status=['LINT_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],invalid_parameter_rejections=10,
        oracle='unbounded per-clock integer ledger, independent per-flow FIFO histories and modular-rank eligible selection; all control/output/credit/queue state checked',
        source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        resource_risk=dict(default='LOW',maximum='MEDIUM',per_flow_state_bits_default=428,per_flow_state_bits_maximum=3632,
            scalar_control_output_bits_default=158,scalar_control_output_bits_maximum=312,physical_resources_measured=False))
    save();print('PASS finite clock-quantized multiflow shaper; HW_UNVERIFIED',flush=True)


if __name__=='__main__':main()
