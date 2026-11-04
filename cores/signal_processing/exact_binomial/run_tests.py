#!/usr/bin/env python3
"""Original finite qualification; no network, synthesis or inherited tools."""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode=True
from prepare_matrix import PROFILES,NEGATIVES,coefficient,matrix,oracle,reset_rows,schedule

ROOT=Path(__file__).resolve().parent
MARKER='exact_binomial_invalid_parameters__see_README'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write_json(path,x):path.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8',newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix():sha(p) for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.name not in ['SOURCE_FREEZE.json','verification.json']
            and 'failure_archive' not in p.relative_to(ROOT).parts}


def main_rows(relative):
    return [tuple([*(int(x,16) for x in s.split()[:4]),int(s.split()[4])])
            for s in (ROOT/relative).read_text(encoding='utf-8').splitlines()]


def reset_fixture(relative):
    rows=[]
    for s in (ROOT/relative).read_text(encoding='utf-8').splitlines():
        q=s.split();rows.append(tuple(int(x,10 if i in [0,5,10] else 16) for i,x in enumerate(q)))
    return rows


def check_matrix():
    p=json.loads((ROOT/'MATRIX_FREEZE.json').read_bytes())
    assert p['stage']=='COMPLETE_FINITE_MATRIX_BEFORE_ORIGINAL_HDL' and p['timeout_seconds']==20
    assert p['preparation_sha256']==sha(ROOT/'prepare_matrix.py') and p['attribute_sha256']==sha(ROOT/'.gitattributes')
    assert [(q['n'],q['t']) for q in p['profiles']]==PROFILES and p['negatives']==[list(q) for q in NEGATIVES]
    for profile in p['profiles']:
        limit,t=profile['n'],profile['t'];rows=[];stats=Counter()
        for group in profile['groups']:
            assert sha(ROOT/group['path'])==group['sha256'];block=main_rows(group['path'])
            assert len(block)==group['frames'] and len(rows)==group['first'];rows+=block
            assert sum(schedule(limit,row[0],row[1])[0] for row in block)==group['compute_cycles']
        assert [row[:2] for row in rows]==matrix(limit)
        for i,(n,k,tag,v,e) in enumerate(rows):
            assert (v,e)==oracle(limit,n,k)
            assert tag==[0,(1<<t)-1,1<<(t-1),i*37+3][i%4]&((1<<t)-1)
            latency,cells,half=schedule(limit,n,k)
            stats['frames']+=1;stats['errors']+=e;stats['extended_zero']+=n<=limit and k>n
            stats['n0_k0']+=n==0 and k==0;stats['cells']+=cells;stats['compute_cycles']+=latency
            stats['max_latency']=max(stats['max_latency'],latency);stats['max_value']=max(stats['max_value'],v)
        assert dict(stats)==profile['statistics']
        assert sha(ROOT/profile['reset_fixture'])==profile['reset_sha256']
        assert reset_fixture(profile['reset_fixture'])==reset_rows(limit,t)
    return p


def child_commands(plan):
    iv,vvp='@IVERILOG@','@VVP@'
    children=[('version',[iv,'-V'],False),
              ('core_syntax',[iv,'-g2012','-Wall','-tnull','-s','exact_binomial','-f','files.f'],False),
              ('example_syntax',[iv,'-g2012','-Wall','-tnull','-s','subset_count_pair','-f','example/files.f'],False)]
    for p in plan['profiles']:
        name=p['name'];binary='@TEMP@/'+name+'.vvp'
        budget=max([g['conservative_cycle_estimate'] for g in p['groups']]+[p['reset_conservative_cycle_estimate']])
        children.append((name+'_compile',[iv,'-g2012','-Wall','-s','tb_exact_binomial','-o',binary,
                         '-P',f'tb_exact_binomial.MAX_N={p["n"]}','-P',f'tb_exact_binomial.TAG_W={p["t"]}',
                         '-P',f'tb_exact_binomial.CYCLE_LIMIT={budget}',
                         'rtl/exact_binomial.sv','sim/tb_exact_binomial.sv'],False))
        for g in p['groups']:
            children.append((g['name']+'_simulate',[vvp,binary,'+MODE=main','+FIXTURE=@ROOT@/'+g['path'],
                             '+TRACE=@TEMP@/'+g['name']+'.trace'],False))
        children.append((name+'_reset_simulate',[vvp,binary,'+MODE=reset','+FIXTURE=@ROOT@/'+p['reset_fixture'],
                         '+TRACE=@TEMP@/'+name+'_reset.trace'],False))
    for name,n,t in plan['negatives']:
        children.append(('reject_'+name,[iv,'-g2012','-tnull','-s','exact_binomial',
                         '-P',f'exact_binomial.MAX_N={n}','-P',f'exact_binomial.TAG_W={t}',
                         'rtl/exact_binomial.sv'],True))
    assert [c[0] for c in children]==plan['children'] and len(children)==80
    return children


def freeze_source():
    assert not (ROOT/'SOURCE_FREEZE.json').exists() and not (ROOT/'verification.json').exists()
    plan=check_matrix();content=sources()
    for name in content:
        b=(ROOT/name).read_bytes();b.decode('utf-8');assert b'\r' not in b and not b.startswith(b'\xef\xbb\xbf'),name
    write_json(ROOT/'SOURCE_FREEZE.json',dict(baseline=plan['baseline'],stage='BEFORE_FIRST_COMPILER',
               matrix_sha256=sha(ROOT/'MATRIX_FREEZE.json'),source_sha256=content,
               timeout_seconds=20,children=plan['children'],commands=child_commands(plan)))
    print('SOURCE_FROZEN',sha(ROOT/'SOURCE_FREEZE.json'),'sources',len(content))


def check_probe(limit,target,v):
    state,row,j,k,held,alias=v
    expected_alias=(limit==1 and (1<=target<=15 or 21<=target<=24)) or (limit==2 and target in [22,23])
    assert alias==int(expected_alias)
    if limit==1 and expected_alias:assert state==8 and held>=3;return
    if target==0:assert state==0
    elif target==1:assert state==1 and j==0
    elif target==2:assert state==1 and j==k
    elif target==3:assert state==2 and row==1
    elif target<=6:assert state==target-1 and row==1 and j==1
    elif target<=9:assert state==target-4 and row==limit and j==k
    elif target<=12:assert state==target-7 and row==limit and j==1
    elif target==13:assert state==6
    elif target==14:assert state==7
    elif target<=20:assert state==8 and held>=3
    elif target==21:assert state==2 and row==k+1
    elif target==22:assert state==1 and j==(k if limit==2 else k//2)
    elif target==23:assert state==5 and ((row==limit and j==1) if limit==2 else row>=3 and j>=2)
    elif target==24:assert state==8 and held==0
    else:raise AssertionError(('target',target))


def validate_trace(profile,group,kind,path):
    limit=profile['n'];rows=main_rows(group['path']) if kind=='main' else [r[6:11] for r in reset_fixture(profile['reset_fixture'])]
    contexts={};outputs=set();probes=set();coverage=Counter()
    for line in path.read_text(encoding='ascii').splitlines():
        words=line.split();event=words[0];idx=int(words[1])
        if event=='X':
            assert kind=='reset' and idx not in probes and 0<=idx<25
            v=list(map(int,words[2:]));check_probe(limit,idx,v);probes.add(idx)
            coverage['reset_boundary_certificates']+=1;coverage['reset_aliases']+=v[-1];continue
        assert 0<=idx<len(rows);n,k,tag,value,error=rows[idx];latency,cells,work_k=schedule(limit,n,k);compute=bool(cells)
        if idx not in contexts:contexts[idx]=dict(inits=0,cells=0,row=1,j=1)
        c=contexts[idx]
        if event=='I':
            j=int(words[2]);v=int(words[3],16)
            assert compute and j==c['inits'] and j<=work_k and v==int(j==0)
            c['inits']+=1;coverage['initialization_certificates']+=1
        elif event=='U':
            row,j=map(int,words[2:4]);current,previous,total=(int(x,16) for x in words[4:7])
            assert compute and c['inits']==work_k+1 and (row,j)==(c['row'],c['j'])
            assert (current,previous,total)==(coefficient(row-1,j),coefficient(row-1,j-1),coefficient(row,j))
            assert total==current+previous and total<(1<<limit)
            c['cells']+=1;coverage['update_certificates']+=1
            if j==1:c['row']+=1;c['j']=min(c['row'],work_k)
            else:c['j']-=1
        elif event=='O':
            assert idx not in outputs
            got=tuple([*(int(x,16) for x in words[2:6]),int(words[6])]);assert got==rows[idx]
            olat,ocells,oinits,oreads,orowsets,ok=map(int,words[7:13])
            assert (olat,ocells,oinits,oreads,orowsets,ok)==(latency,cells,work_k+1 if compute else 0,2*cells+1 if compute else 0,n if compute else 0,work_k)
            assert c['cells']==cells and c['inits']==oinits
            if compute:
                assert c['row']==n+1 and [int(x,16) for x in words[13:]]==[coefficient(n,j) for j in range(work_k+1)]
                coverage['final_row_certificates']+=work_k+1
            else:assert len(words)==13
            outputs.add(idx);coverage['latency_certificates']+=1;coverage['scheduled_reads']+=oreads
        else:raise AssertionError(('trace event',event))
    assert outputs==set(range(len(rows)))
    assert probes==(set(range(25)) if kind=='reset' else set())
    return dict(coverage),sha(path)


def check_result(profile,group,kind,observed,certificates):
    frames=group['frames'] if kind=='main' else 25
    assert observed['mode']==kind and observed['N']==profile['n'] and observed['TAG']==profile['t']
    assert observed['frames']==observed['latency_checks']==certificates['latency_certificates']==frames
    assert observed['queued']==(frames-1 if kind=='main' else 0)
    assert observed['resets']==observed['fresh']==(0 if kind=='main' else 25)
    assert observed['output_holds']>=3*frames and observed['source_holds']>=observed['queued']
    assert observed['cells']==certificates.get('update_certificates',0)
    assert observed['inits']==certificates.get('initialization_certificates',0)
    assert observed['reads']==certificates['scheduled_reads'] and observed['ram_checks']>=observed['reads']
    assert observed['shadow_checks']==certificates.get('final_row_certificates',0)
    assert observed['max_latency']<=profile['latency_bound']
    budget=group['conservative_cycle_estimate'] if kind=='main' else profile['reset_conservative_cycle_estimate']
    assert observed['cycles']<=budget
    if kind=='reset':
        assert certificates['reset_boundary_certificates']==25 and certificates['reset_aliases']==len(profile['reset_alias_targets'])


def audit():
    plan=check_matrix();freeze=json.loads((ROOT/'SOURCE_FREEZE.json').read_bytes());r=json.loads((ROOT/'verification.json').read_bytes())
    assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout']
    assert freeze['matrix_sha256']==r['matrix_sha256']==sha(ROOT/'MATRIX_FREEZE.json')
    assert r['source_freeze_sha256']==sha(ROOT/'SOURCE_FREEZE.json') and freeze['source_sha256']==r['source_sha256']==sources()
    assert freeze['commands']==[list(c) for c in child_commands(plan)]
    assert [c['name'] for c in r['records']]==plan['children'] and len(r['records'])==80
    assert all(c['status']=='PASS' and c['timeout_seconds']==20 and c['elapsed_seconds']<20.5 for c in r['records'])
    assert len(r['results'])==67 and len(r['profiles'])==6
    for item in r['results']:
        p=next(p for p in plan['profiles'] if p['name']==item['profile'])
        g=next((g for g in p['groups'] if g['name']==item['group']),None)
        check_result(p,g,item['kind'],item['observed'],item['certificates'])
    for p,summary in zip(plan['profiles'],r['profiles']):
        assert summary['name']==p['name'] and summary['main_frames']==p['statistics']['frames']
        assert summary['states']==(257 if p['n']==1 else 511) and summary['errors']==3
        assert summary['maximum_latency']==p['latency_bound'] and summary['resets']==summary['fresh']==25
    for name in sources():
        raw=(ROOT/name).read_bytes();raw.decode('utf-8');assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf')
    print('OFFLINE_AUDIT_PASS',sha(ROOT/'MATRIX_FREEZE.json'),sha(ROOT/'SOURCE_FREEZE.json'),sha(ROOT/'verification.json'))


def run():
    plan=check_matrix();freeze=json.loads((ROOT/'SOURCE_FREEZE.json').read_bytes())
    assert freeze['matrix_sha256']==sha(ROOT/'MATRIX_FREEZE.json') and freeze['source_sha256']==sources()
    assert freeze['commands']==[list(c) for c in child_commands(plan)]
    assert not (ROOT/'verification.json').exists(),'never overwrite any qualification receipt'
    toolbin=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
    iv,vvp=toolbin/'iverilog.exe',toolbin/'vvp.exe';assert iv.is_file() and vvp.is_file()
    env=dict(os.environ);env['PATH']=str(toolbin)+os.pathsep+str(toolbin.parent/'lib')+os.pathsep+env.get('PATH','')
    receipt=dict(baseline=plan['baseline'],status='IN_PROGRESS',hardware='HW_UNVERIFIED',
                 matrix_sha256=sha(ROOT/'MATRIX_FREEZE.json'),source_freeze_sha256=sha(ROOT/'SOURCE_FREEZE.json'),
                 source_sha256=sources(),records=[],results=[],profiles=[],terminal_timeout=False)
    def save():write_json(ROOT/'verification.json',receipt)
    def child(name,argv,reject):
        assert name==plan['children'][len(receipt['records'])]
        start=time.monotonic();record=dict(name=name,argv=argv,timeout_seconds=20)
        try:
            result=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=20)
            good=(result.returncode!=0 and MARKER in result.stdout+result.stderr) if reject else result.returncode==0
            record.update(exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr,status='PASS' if good else 'FAIL')
        except subprocess.TimeoutExpired as exc:
            decode=lambda x:x.decode('utf-8','replace') if isinstance(x,bytes) else x or ''
            record.update(exit_code=None,stdout=decode(exc.stdout),stderr=decode(exc.stderr),status='TIMEOUT');receipt['terminal_timeout']=True
        record['elapsed_seconds']=round(time.monotonic()-start,3);receipt['records'].append(record);save()
        print(name,record['status'],record['elapsed_seconds'],flush=True)
        if record['status']!='PASS':raise RuntimeError(name+' '+record['status'])
        return record
    temp_root=Path(tempfile.gettempdir()).resolve();tmp=Path(tempfile.mkdtemp(prefix='anscore_b23_binomial_',dir=temp_root)).resolve()
    assert tmp.parent==temp_root and tmp.name.startswith('anscore_b23_binomial_')
    replacements={'@IVERILOG@':str(iv),'@VVP@':str(vvp),'@ROOT@':ROOT.as_posix(),'@TEMP@':tmp.as_posix()}
    try:
        for name,template,reject in child_commands(plan):
            argv=[]
            for argument in template:
                for token,value in replacements.items():argument=argument.replace(token,value)
                argv.append(argument)
            result=child(name,argv,reject)
            if name.endswith('_simulate'):
                p=next(p for p in plan['profiles'] if name.startswith(p['name']+'_'))
                kind='reset' if name==p['name']+'_reset_simulate' else 'main'
                group=next((g for g in p['groups'] if name==g['name']+'_simulate'),None)
                summaries=[s for s in result['stdout'].splitlines() if s.startswith('PASS mode=')];assert len(summaries)==1
                words=dict(re.findall(r'(\w+)=([^ ]+)',summaries[0]))
                observed={k:(v if k=='mode' else int(v,16 if k in ['states','errors'] else 10)) for k,v in words.items()}
                trace=tmp/((group['name'] if kind=='main' else p['name']+'_reset')+'.trace')
                certificates,trace_sha=validate_trace(p,group,kind,trace);check_result(p,group,kind,observed,certificates)
                receipt['results'].append(dict(profile=p['name'],group=group['name'] if group else None,kind=kind,
                                               observed=observed,certificates=certificates,trace_sha256=trace_sha));save()
        for p in plan['profiles']:
            items=[i for i in receipt['results'] if i['profile']==p['name']];states=0;errors=0
            for item in items:states|=item['observed']['states'];errors|=item['observed']['errors']
            receipt['profiles'].append(dict(name=p['name'],n=p['n'],t=p['t'],
                 main_frames=sum(i['observed']['frames'] for i in items if i['kind']=='main'),
                 resets=sum(i['observed']['resets'] for i in items),fresh=sum(i['observed']['fresh'] for i in items),
                 states=states,errors=errors,maximum_latency=max(i['observed']['max_latency'] for i in items)))
        receipt['totals']={k:sum(i['observed'][k] for i in receipt['results'])
                           for k in ['frames','queued','resets','fresh','cells','inits','reads','ram_checks','shadow_checks',
                                     'source_holds','output_holds','latency_checks']}
        receipt['totals']['main_frames']=sum(p['main_frames'] for p in receipt['profiles'])
        assert sources()==freeze['source_sha256'];receipt['status']='UNIT_SIM_PASS';save();audit()
        print('QUALIFIED',sha(ROOT/'verification.json'),receipt['totals'])
    except Exception as exc:
        receipt['status']='TIMEOUT_NOT_RUN' if receipt['terminal_timeout'] else 'FAIL';receipt['error']=str(exc)
        receipt['records'] += [dict(name=n,status='NOT_RUN') for n in plan['children'][len(receipt['records']):]];save()
        index=0
        while (ROOT/'failure_archive'/f'attempt_{index:02d}').exists():index+=1
        archive=ROOT/'failure_archive'/f'attempt_{index:02d}';archive.mkdir(parents=True)
        for name in [*freeze['source_sha256'],'SOURCE_FREEZE.json','verification.json']:
            destination=archive/name;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,destination)
        for trace in tmp.glob('*.trace'):shutil.copyfile(trace,archive/trace.name)
        (archive/'NOT_RUN.txt').write_text('\n'.join(r['name'] for r in receipt['records'] if r['status']=='NOT_RUN')+'\n',encoding='utf-8',newline='\n')
        print('PRESERVED_FAILURE',archive,sha(ROOT/'verification.json'),flush=True);raise
    finally:
        assert tmp.parent==temp_root and tmp.name.startswith('anscore_b23_binomial_');shutil.rmtree(tmp)


if __name__=='__main__':
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--freeze-source',action='store_true');group.add_argument('--run',action='store_true');group.add_argument('--audit',action='store_true')
    args=parser.parse_args()
    if args.freeze_source:freeze_source()
    elif args.run:run()
    else:audit()
