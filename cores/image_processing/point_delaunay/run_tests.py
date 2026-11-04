"""Finite immutable matrix, 20-second terminal children, and offline receipt audit."""
from pathlib import Path
from hashlib import sha256
import argparse
import json
import os
import shutil
import subprocess
import tempfile
import time
import re

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
HEX={'states','jobs','circles','resetmask'}

def digest(p):return sha256(p.read_bytes()).hexdigest()
def read(name):return json.loads((ROOT/name).read_text(encoding='utf-8'))
def write(name,value):(ROOT/name).write_bytes((json.dumps(value,indent=2)+'\n').encode())
def sources():
    return {p.relative_to(ROOT).as_posix():digest(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and 'failure_archive' not in p.parts and
            p.name not in ('TEST_PLAN.json','verification.json')}

def matrix_audit(m):
    assert m['timeout_seconds']==20 and m['timeout_terminal'] and m['no_adaptation']
    assert digest(ROOT/'prepare_matrix.py')==m['preparation_sha256']
    assert digest(ROOT/'.gitattributes')==m['attribute_sha256']
    for j in m['jobs']:
        assert digest(ROOT/j['fixture'])==j['fixture_sha256']
        assert digest(ROOT/j['resets'])==j['resets_sha256']

def commands(m):
    rows=[['version',['@IVERILOG@','-V'],False],
          ['core_syntax',['@IVERILOG@','-g2012','-Wall','-tnull','-s','point_delaunay','-f','files.f'],False],
          ['example_syntax',['@IVERILOG@','-g2012','-Wall','-tnull','-s','feature_mesh8','-f','example/files.f'],False]]
    bounds={p['name']:p['tail_bound'] for p in m['profiles']}
    for j in m['jobs']:
        name=j['name'];profile=f"c{j['c']}_n{j['n']}_t{j['t']}"
        args=['@IVERILOG@','-g2012','-Wall','-s','tb_point_delaunay','-o',f'@TEMP@/{name}.vvp']
        for k,v in dict(C=j['c'],N=j['n'],T=j['t'],NUM_INPUTS=j['inputs'],NUM_OUTPUTS=j['outputs'],
                        CYCLE_LIMIT=j['cycle_limit'],TAIL_BOUND=bounds[profile]).items():
            args+=['-P',f'tb_point_delaunay.{k}={v}']
        args+=['rtl/point_delaunay.sv','sim/tb_point_delaunay.sv']
        rows += [[name+'_compile',args,False],
                 [name+'_simulate',['@VVP@',f'@TEMP@/{name}.vvp',
                  '+FIXTURE='+str(ROOT/j['fixture']),'+RESETS='+str(ROOT/j['resets'])],False]]
    for name,c,n,t in m['negatives']:
        args=['@IVERILOG@','-g2012','-tnull','-s','point_delaunay']
        for k,v in dict(COORD_W=c,MAX_POINTS=n,TAG_W=t).items():args+=['-P',f'point_delaunay.{k}={v}']
        args+=['rtl/point_delaunay.sv'];rows.append(['reject_'+name,args,True])
    assert [r[0] for r in rows]==m['children']
    return rows

def marker(record,j):
    lines=[s for s in record['stdout'].splitlines() if s.startswith('PASS ')]
    assert len(lines)==1,'exactly one PASS marker'
    ob={k:int(v,16 if k in HEX else 10) for k,v in re.findall(r'(\w+)=([0-9a-f]+)',lines[0])}
    assert (ob['C'],ob['N'],ob['T'])==(j['c'],j['n'],j['t'])
    assert ob['frames']==j['frames'] and ob['queued']==max(0,j['frames']-1)
    assert ob['resets']==ob['fresh']==len(j['reset_ids'])
    assert ob['records']==j['outputs'] and ob['latencies']==j['frames']+len(j['reset_ids'])
    assert ob['resetmask']==sum(1<<i for i in j['reset_ids'])
    observations=[s for s in record['stdout'].splitlines() if s.startswith('OBS ')]
    assert [int(re.search(r'id=(\d+)',s)[1]) for s in observations]==j['reset_ids']
    assert ob['cycles']<=j['cycle_limit']
    return ob

def audit():
    m=read('MATRIX.json');p=read('TEST_PLAN.json');r=read('verification.json')
    matrix_audit(m)
    assert p['source_sha256']==sources()==r['source_sha256']
    assert p['commands']==commands(m)
    assert r['matrix_sha256']==p['matrix_sha256']==digest(ROOT/'MATRIX.json')
    assert r['plan_sha256']==digest(ROOT/'TEST_PLAN.json')
    assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout'] and r['not_run']==[]
    assert [v['name'] for v in r['records']]==m['children']
    for rec,cmd in zip(r['records'],p['commands']):
        assert rec['status']=='PASS' and rec['timeout_seconds']==20 and rec['elapsed_seconds']<20
        assert (rec['exit_code']!=0)==cmd[2]
    for j in m['jobs']:
        rec=next(x for x in r['records'] if x['name']==j['name']+'_simulate')
        assert marker(rec,j)==next(x['observed'] for x in r['jobs'] if x['name']==j['name'])
    for profile in m['profiles']:
        group=[x['observed'] for x in r['jobs'] if x['c']==profile['c'] and x['n']==profile['n'] and x['t']==profile['t']]
        states=jobs=circles=resets=0
        for ob in group:states|=ob['states'];jobs|=ob['jobs'];circles|=ob['circles'];resets|=ob['resetmask']
        expected_states=sum(1<<i for i in range(27) if i in profile['reset_ids'])
        assert states==expected_states,(profile['name'],'state union',states,expected_states)
        assert resets==sum(1<<i for i in profile['reset_ids'])
        if profile['n']>=4:assert jobs==32767 and circles==31
        else:assert jobs==circles==0
        assert sum(x['frames'] for x in group)==profile['frames']
    for rel in p['source_sha256']:
        b=(ROOT/rel).read_bytes();b.decode('utf-8');assert b'\r' not in b and not b.startswith(b'\xef\xbb\xbf')
    print('OFFLINE_AUDIT_PASS',len(r['records']),'children',len(p['source_sha256']),'frozen sources')

def archive(receipt):
    attempt=1
    while (ROOT/'failure_archive'/f'attempt_{attempt:02d}').exists():attempt+=1
    target=ROOT/'failure_archive'/f'attempt_{attempt:02d}'
    target.mkdir(parents=True)
    for f in sorted(ROOT.rglob('*')):
        if f.is_file() and 'failure_archive' not in f.parts:
            dest=target/f.relative_to(ROOT);dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(f.read_bytes())
    (target/'receipt.json').write_bytes((json.dumps(receipt,indent=2)+'\n').encode())
    (target/'NOT_RUN.json').write_bytes((json.dumps(receipt['not_run'],indent=2)+'\n').encode())

def repair_reseal():
    old=read('verification.json');prior=ROOT/'failure_archive'/'attempt_01'
    assert old['status']=='FAIL' and not old['terminal_timeout'],'only ordinary non-timeout failure'
    assert digest(ROOT/'verification.json')==digest(prior/'verification.json')==digest(prior/'receipt.json')
    old_plan=json.loads((prior/'TEST_PLAN.json').read_text(encoding='utf-8'))
    assert digest(prior/'TEST_PLAN.json')==old['plan_sha256']
    evidence=read('repair_01/repair.json')
    for rel,h in evidence['original_archive_sha256'].items():assert digest(prior/rel)==h
    allowed={'sim/tb_point_delaunay.sv','run_tests.py','README.md'}
    for rel,h in old_plan['source_sha256'].items():
        assert digest(prior/rel)==h
        if rel not in allowed:assert digest(ROOT/rel)==h,'outside authorized repair: '+rel
    assert set(sources())-set(old_plan['source_sha256'])=={'repair_01/repair.patch','repair_01/repair.json'}
    assert digest(ROOT/'repair_01/repair.patch')==evidence['diff_sha256']
    m=read('MATRIX.json');matrix_audit(m);assert commands(m)==old_plan['commands']
    repair=dict(original_receipt_sha256=digest(prior/'verification.json'),original_plan_sha256=digest(prior/'TEST_PLAN.json'),
                archive='failure_archive/attempt_01',scope=sorted(allowed),diff_sha256=evidence['diff_sha256'])
    write('TEST_PLAN.json',dict(baseline=m['baseline'],stage='ROOT_AUTHORIZED_ORDINARY_FAIL_REPAIR_BEFORE_HDL',
                               matrix_sha256=digest(ROOT/'MATRIX.json'),timeout_seconds=20,source_sha256=sources(),commands=commands(m),repair=repair))
    print('REPAIR_SOURCE_FROZEN',digest(ROOT/'TEST_PLAN.json'))

def run():
    m=read('MATRIX.json');p=read('TEST_PLAN.json');matrix_audit(m)
    assert p['source_sha256']==sources() and p['commands']==commands(m)
    if (ROOT/'verification.json').exists():
        old=read('verification.json');repair=p.get('repair',{})
        assert old['status']=='FAIL' and not old['terminal_timeout'],'PASS/TIMEOUT receipts are immutable'
        assert repair.get('original_receipt_sha256')==digest(ROOT/'verification.json')
        assert digest(ROOT/repair['archive']/'verification.json')==repair['original_receipt_sha256']
    tool=REPO/'tools/oss-cad-suite/oss-cad-suite/bin/iverilog.exe'
    compiler=str(tool) if tool.is_file() else shutil.which('iverilog')
    vvp=str(tool.with_name('vvp.exe')) if tool.is_file() else shutil.which('vvp')
    if not compiler or not vvp:raise SystemExit('missing Icarus/vvp; NOT_RUN')
    receipt=dict(baseline=m['baseline'],status='RUNNING',hardware='HW_UNVERIFIED',matrix_sha256=digest(ROOT/'MATRIX.json'),
                 plan_sha256=digest(ROOT/'TEST_PLAN.json'),source_sha256=p['source_sha256'],records=[],jobs=[],
                 terminal_timeout=False,not_run=m['children'].copy(),repair=p.get('repair'))
    env=os.environ.copy();binary=Path(compiler).parent
    env['PATH']=str(binary)+os.pathsep+str(binary.parent/'lib')+os.pathsep+env.get('PATH','')
    with tempfile.TemporaryDirectory(prefix='anscore_b23_delaunay_') as temporary:
        substitutions={'@IVERILOG@':compiler,'@VVP@':vvp,'@TEMP@':temporary}
        for name,template,negative in p['commands']:
            argv=[]
            for word in template:
                for key,value in substitutions.items():word=word.replace(key,value)
                argv.append(word)
            start=time.monotonic();rec=dict(name=name,argv=argv,timeout_seconds=20)
            try:
                proc=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=20)
                rec.update(exit_code=proc.returncode,stdout=proc.stdout,stderr=proc.stderr,
                           elapsed_seconds=round(time.monotonic()-start,3))
                good=(proc.returncode!=0 and 'point_delaunay_invalid_parameters__see_README' in proc.stderr) if negative else proc.returncode==0
                rec['status']='PASS' if good else 'FAIL'
                if good and name.endswith('_simulate'):
                    job=next(x for x in m['jobs'] if name==x['name']+'_simulate')
                    observed=marker(rec,job);receipt['jobs'].append(dict(job,observed=observed))
            except subprocess.TimeoutExpired as error:
                def decode(x):return x.decode('utf-8','replace') if isinstance(x,bytes) else (x or '')
                rec.update(exit_code=None,stdout=decode(error.stdout),stderr=decode(error.stderr),elapsed_seconds=round(time.monotonic()-start,3),status='TIMEOUT')
                receipt['terminal_timeout']=True
            except Exception as error:
                rec.update(status='FAIL',exception=str(error),elapsed_seconds=round(time.monotonic()-start,3))
            receipt['records'].append(rec);receipt['not_run'].remove(name)
            print(name,rec['status'],rec['elapsed_seconds'],flush=True)
            if rec['status']!='PASS':
                receipt['status']=rec['status'];write('verification.json',receipt);archive(receipt)
                raise SystemExit('terminal child failure; complete archive preserved; root scope required')
        receipt['status']='UNIT_SIM_PASS'
        keys=['frames','queued','resets','fresh','records','source_holds','output_holds','reads','multiplies','orientations','incircles','latencies']
        receipt['totals']={k:sum(j['observed'][k] for j in receipt['jobs']) for k in keys}
        write('verification.json',receipt)
    audit()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--freeze-source',action='store_true');parser.add_argument('--run',action='store_true');parser.add_argument('--audit',action='store_true');parser.add_argument('--repair-reseal',action='store_true')
    args=parser.parse_args()
    if sum((args.freeze_source,args.run,args.audit,args.repair_reseal))!=1:parser.error('choose exactly one operation')
    if args.freeze_source:
        if (ROOT/'TEST_PLAN.json').exists() or (ROOT/'verification.json').exists():raise SystemExit('source plan already frozen')
        m=read('MATRIX.json');matrix_audit(m)
        write('TEST_PLAN.json',dict(baseline=m['baseline'],stage='ALL_SOURCES_BEFORE_FIRST_HDL',matrix_sha256=digest(ROOT/'MATRIX.json'),timeout_seconds=20,
                                    source_sha256=sources(),commands=commands(m)))
        print('SOURCE_FROZEN',digest(ROOT/'TEST_PLAN.json'))
    elif args.repair_reseal:repair_reseal()
    elif args.run:run()
    else:audit()
