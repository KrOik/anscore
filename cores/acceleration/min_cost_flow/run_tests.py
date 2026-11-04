"""One source-bound finite matrix. Every HDL child has a hard 20-second limit."""
import argparse
import ast
from hashlib import sha256
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
def read(rel):return json.loads((ROOT/rel).read_text(encoding='utf-8'))
def digest(p):return sha256(p.read_bytes()).hexdigest()
def write(rel,data):(ROOT/rel).write_text(json.dumps(data,sort_keys=True,indent=2)+'\n',encoding='utf-8',newline='\n')
def sources():
    return {p.relative_to(ROOT).as_posix():digest(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in {'SOURCE_FREEZE.json','verification.json'}
            and 'failure_archive' not in p.relative_to(ROOT).parts}
def jobs(plan):
    result=[]
    for p in plan['profiles']:
        for kind,items in [('main',p['main']),('reset',p['resets'])]:
            for i,x in enumerate(items):result.append(dict(name=p['name']+' '+kind+' '+str(i),profile=p,kind=kind,fixture=x['fixture'],sha256=x['sha256']))
    return result
def commands(plan):
    out=[['version',['iverilog','-V']],['core syntax',['iverilog','-g2012','-Wall','-tnull','-s','min_cost_flow','-f','files.f']],
         ['example syntax',['iverilog','-g2012','-Wall','-tnull','-s','priced_flow8','-f','example/files.f']]]
    alljobs=jobs(plan)
    for p in plan['profiles']:
        name=p['name'];args=['iverilog','-g2012','-Wall','-s','tb_min_cost_flow','-o','{TMP}/'+name+'.vvp']
        args += ['-Ptb_min_cost_flow.'+k+'='+str(p[k]) for k in ['N','M','C','W','T']]
        args += ['rtl/min_cost_flow.sv','sim/tb_min_cost_flow.sv'];out.append([name+' compile TB',args])
        for j in alljobs:
            if j['profile']['name']==name:out.append([j['name'],['vvp','{TMP}/'+name+'.vvp','+INPUT={TMP}/'+j['name'].replace(' ','_')+'.txt']])
    for p,v in plan['rejections']:
        out.append([f'reject {p}={v}',['iverilog','-g2012','-Wall','-tnull','-s','min_cost_flow','-Pmin_cost_flow.'+p+'='+str(v),'-f','files.f']])
    assert [x[0] for x in out]==plan['children']
    return out
def matrix_audit(plan):
    assert plan['timeout_seconds']==20 and plan['frozen_before_any_rtl']
    assert digest(ROOT/'prepare_matrix.py')==plan['preparation_sha256']
    for job in jobs(plan):
        assert digest(ROOT/job['fixture'])==job['sha256']
    assert len(commands(plan))==232
    for p in ROOT.glob('*.py'):ast.parse(p.read_text(encoding='utf-8'))
def header(case,next_case=None):
    e=case.get('expected',dict(flow=0,cost=0))
    out=[' '.join(map(str,case['command']+[len(case['rows']),case.get('error',0),e['flow'],e['cost'],case.get('outputs',1),case.get('latency_bound',1000000)]))]
    out.append(' '.join(map(str,[int(next_case is not None)]+(next_case['command'] if next_case else [0,0,0,0]))))
    out+=[' '.join(map(str,r)) for r in case['rows']]
    return out
def materialize(job,tmp):
    data=read(job['fixture']);out=[];expected=[]
    if job['kind']=='main':
        cases=data['cases'];out.append('0 '+str(len(cases)));expected=cases
        for i,c in enumerate(cases):out+=header(c,cases[i+1] if i+1<len(cases) else None)
    else:
        targets=data['targets'];out.append('1 '+str(len(targets)))
        for x in targets:
            out.append(str(x['id']));out+=header(x['owner'],x['fresh']);out+=header(x['fresh']);expected.append(x['fresh'])
    (tmp/(job['name'].replace(' ','_')+'.txt')).write_text('\n'.join(out)+'\n',encoding='ascii',newline='\n')
    return expected
def load_certificate():
    spec=importlib.util.spec_from_file_location('local_mcf_oracle',ROOT/'prepare_matrix.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    return m.certificate
def parse_sim(stdout,job,expected,certificate):
    lines=[x.strip() for x in stdout.splitlines() if x.strip()];results={};latencies={};cancels=[];summary=None
    for line in lines:
        if line.startswith('RESULT '):
            a=list(map(int,line.split()[1:]));assert a[0] not in results;results[a[0]]=a[1:]
        elif line.startswith('LATENCY '):
            _,i,v=line.split();assert int(i) not in latencies;latencies[int(i)]=int(v)
        elif line.startswith('CANCEL '):cancels.append(int(line.split()[1]))
        elif line.startswith('PASS '):
            assert summary is None;summary={k:int(v) for k,v in (x.split('=') for x in line.split()[1:])}
        elif re.fullmatch(r'sim/tb_min_cost_flow\.sv:\d+: \$finish called at \d+ \(1ps\)',line):pass
        else:raise AssertionError('Unexpected simulator output: '+line)
    assert summary is not None and summary['frames']==len(expected)
    assert set(results)==set(latencies)==set(range(len(expected)))
    profile=job['profile'];certificates=0
    for i,c in enumerate(expected):
        assert 0<=latencies[i]<=c['latency_bound']
        if c['error']:assert results[i]==[]
        else:
            actual=certificate(profile['N'],c['edges'],*c['command'][:3],results[i]);certificates+=1
            assert actual==(c['expected']['flow'],c['expected']['cost'])
    if job['kind']=='reset':
        assert cancels==[x['id'] for x in read(job['fixture'])['targets']]
        assert summary['resets']==len(expected) and summary['queued']==0
    else:assert not cancels and summary['resets']==0 and summary['queued']==len(expected)-1
    return dict(summary,certificates=certificates,max_latency=max(latencies.values()),latencies=latencies)
def archive(receipt,tmp):
    dest=ROOT/'failure_archive'/'attempt_01';assert not dest.exists()
    dest.mkdir(parents=True)
    rels=list(sources())+['SOURCE_FREEZE.json','verification.json']
    for rel in rels:
        q=dest/rel;q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes((ROOT/rel).read_bytes())
    write_path=dest/'NOT_RUN.json';write_path.write_text(json.dumps(receipt['not_run'],indent=2)+'\n',encoding='utf-8',newline='\n')
    for p in tmp.glob('*.vvp'):
        (dest/'artifacts').mkdir(exist_ok=True);shutil.copyfile(p,dest/'artifacts'/p.name)
    manifest={p.relative_to(dest).as_posix():digest(p) for p in sorted(dest.rglob('*')) if p.is_file()}
    (dest/'archive.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n',encoding='utf-8',newline='\n')
def run():
    assert not (ROOT/'verification.json').exists(),'existing receipt forbids retries'
    plan=read('TEST_PLAN.json');seal=read('SOURCE_FREEZE.json');matrix_audit(plan)
    assert seal['source_sha256']==sources() and seal['commands']==commands(plan)
    binary=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';env=os.environ.copy()
    env['PATH']=str(binary)+os.pathsep+str(binary.parent/'lib')+os.pathsep+env.get('PATH','')
    assert (binary/'iverilog.exe').is_file() and (binary/'vvp.exe').is_file()
    receipt=dict(status='RUNNING',hardware='HW_UNVERIFIED',plan_sha256=digest(ROOT/'TEST_PLAN.json'),source_freeze_sha256=digest(ROOT/'SOURCE_FREEZE.json'),source_sha256=sources(),records=[],simulations=[],not_run=plan['children'].copy(),terminal_timeout=False)
    certificate=load_certificate();byname={x['name']:x for x in jobs(plan)}
    with tempfile.TemporaryDirectory(prefix='anscore_b24_min_cost_flow_') as temporary:
        tmp=Path(temporary)
        for name,args in seal['commands']:
            expected=materialize(byname[name],tmp) if name in byname else None
            argv=[str(binary/(args[0]+'.exe'))]+[x.replace('{TMP}',str(tmp)) for x in args[1:]]
            record=dict(name=name,argv=argv,timeout_seconds=20);start=time.monotonic()
            try:
                child=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
                record.update(exit_code=child.returncode,stdout=child.stdout,stderr=child.stderr,elapsed_seconds=round(time.monotonic()-start,6))
                if name.startswith('reject '):
                    assert child.returncode!=0 and 'min_cost_flow_illegal_parameters' in child.stderr
                    record['status']='EXPECTED_REJECT'
                else:
                    assert child.returncode==0 and not child.stderr,(child.returncode,child.stderr)
                    if expected is not None:receipt['simulations'].append(dict(name=name,**parse_sim(child.stdout,byname[name],expected,certificate)))
                    record['status']='PASS'
            except subprocess.TimeoutExpired as e:
                record.update(status='TIMEOUT',stdout=(e.stdout or b'').decode('utf-8',errors='replace') if isinstance(e.stdout,bytes) else (e.stdout or ''),stderr=(e.stderr or b'').decode('utf-8',errors='replace') if isinstance(e.stderr,bytes) else (e.stderr or ''),elapsed_seconds=round(time.monotonic()-start,6));receipt['terminal_timeout']=True
            except Exception as e:
                record['status']='FAIL';record['error']=type(e).__name__+': '+str(e)
            receipt['records'].append(record);receipt['not_run'].pop(0);write('verification.json',receipt)
            print(name,record['status'],record.get('elapsed_seconds'),flush=True)
            if record['status'] in ('FAIL','TIMEOUT'):
                receipt['status']=record['status'];write('verification.json',receipt);archive(receipt,tmp);return
        receipt['status']='UNIT_SIM_PASS';write('verification.json',receipt)
    audit()
def audit():
    plan=read('TEST_PLAN.json');seal=read('SOURCE_FREEZE.json');r=read('verification.json');matrix_audit(plan)
    assert seal['source_sha256']==sources()==r['source_sha256']
    assert r['plan_sha256']==digest(ROOT/'TEST_PLAN.json') and r['source_freeze_sha256']==digest(ROOT/'SOURCE_FREEZE.json')
    assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout'] and not r['not_run']
    assert len(r['records'])==232 and [x['name'] for x in r['records']]==plan['children']
    assert all(x['status'] in ('PASS','EXPECTED_REJECT') and x['timeout_seconds']==20 and x['elapsed_seconds']<20 for x in r['records'])
    assert sum(x['frames'] for x in r['simulations'])==1775+317
    assert sum(x['resets'] for x in r['simulations'])==317
    print('OFFLINE_AUDIT_PASS 232 children; 1775 main + 317 reset/fresh; source closure unchanged')
if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--freeze-source',action='store_true');ap.add_argument('--run',action='store_true');ap.add_argument('--audit',action='store_true');args=ap.parse_args()
    assert sum((args.freeze_source,args.run,args.audit))==1
    if args.freeze_source:
        assert not (ROOT/'SOURCE_FREEZE.json').exists() and not (ROOT/'verification.json').exists()
        plan=read('TEST_PLAN.json');matrix_audit(plan)
        write('SOURCE_FREEZE.json',dict(before_first_hdl=True,plan_sha256=digest(ROOT/'TEST_PLAN.json'),source_sha256=sources(),commands=commands(plan),timeout_seconds=20))
        print('SOURCE_FROZEN',digest(ROOT/'SOURCE_FREEZE.json'),len(sources()))
    elif args.run:run()
    else:audit()
