"""Sealed one-shot finite evidence; every compiler/simulator child hard-limited20s."""
from pathlib import Path
from hashlib import sha256
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
HEX={'states','signs','saddles','resetmask'}
def digest(p):return sha256(p.read_bytes()).hexdigest()
def read(name):return json.loads((ROOT/name).read_text(encoding='utf-8'))
def write(name,obj):(ROOT/name).write_bytes((json.dumps(obj,indent=2)+'\n').encode())
def sources():
    return {p.relative_to(ROOT).as_posix():digest(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and 'failure_archive' not in p.parts and p.name not in ('TEST_PLAN.json','verification.json')}
def matrix_audit(m):
    assert m['timeout_seconds']==20 and m['timeout_terminal'] and m['no_adaptation']
    assert m['stage']=='COMPLETE_FIXTURES_ORACLE_RESETS_SPLITS_BEFORE_ANY_RTL'
    assert digest(ROOT/'prepare_matrix.py')==m['preparation_sha256']
    assert digest(ROOT/'.gitattributes')==m['attribute_sha256']
    for j in m['jobs']:assert digest(ROOT/j['fixture'])==j['fixture_sha256']
    assert len(m['jobs'])==66 and len(m['children'])==143
    assert sum(p['frames'] for p in m['profiles'])==2736
    for p in m['profiles']:
        assert set(p['reset_ids'])|set(map(int,p['excluded']))==set(range(35))
        group=[j for j in m['jobs'] if (j['w'],j['h'],j['g'],j['t'])==(p['w'],p['h'],p['g'],p['t'])]
        assert sum(j['frames'] for j in group)==p['frames']
        assert sorted(rid for j in group for rid in j['reset_ids'])==p['reset_ids']
        if p['w']==64:
            assert all(j['frames']<=2 and len(j['reset_ids'])<=1 for j in group)
def commands(m):
    rows=[['version',['@IVERILOG@','-V'],False],
          ['core_syntax',['@IVERILOG@','-g2012','-Wall','-tnull','-s','grayscale_isocontour','-f','files.f'],False],
          ['example_syntax',['@IVERILOG@','-g2012','-Wall','-tnull','-s','iso_graph16','-f','example/files.f'],False]]
    for j in m['jobs']:
        name=j['name'];args=['@IVERILOG@','-g2012','-Wall','-s','tb_grayscale_isocontour','-o',f'@TEMP@/{name}.vvp']
        for k,v in dict(W=j['w'],H=j['h'],G=j['g'],T=j['t'],NUM_INPUTS=j['inputs'],NUM_OUTPUTS=j['outputs'],
                        NUM_BLOCKS=j['blocks'],CYCLE_LIMIT=j['cycle_limit']).items():
            args+=['-P',f'tb_grayscale_isocontour.{k}={v}']
        args+=['rtl/grayscale_isocontour.sv','sim/tb_grayscale_isocontour.sv']
        rows.extend([[name+'_compile',args,False],
                     [name+'_simulate',['@VVP@',f'@TEMP@/{name}.vvp','+FIXTURE='+str(ROOT/j['fixture'])],False]])
    for name,w,h,g,t in m['negatives']:
        args=['@IVERILOG@','-g2012','-tnull','-s','grayscale_isocontour']
        for k,v in dict(WIDTH=w,HEIGHT=h,PIXEL_W=g,TAG_W=t).items():args+=['-P',f'grayscale_isocontour.{k}={v}']
        rows.append(['reject_'+name,args+['rtl/grayscale_isocontour.sv'],True])
    assert [r[0] for r in rows]==m['children']
    return rows
def marker(record,j):
    lines=[x for x in record['stdout'].splitlines() if x.startswith('PASS ')]
    assert len(lines)==1,'exactly one PASS marker'
    ob={k:int(v,16 if k in HEX else 10) for k,v in re.findall(r'(\w+)=([0-9a-f]+)',lines[0])}
    assert (ob['W'],ob['H'],ob['G'],ob['T'])==(j['w'],j['h'],j['g'],j['t'])
    assert ob['frames']==j['frames'] and ob['queued']==max(0,j['frames']-1)
    assert ob['resets']==ob['fresh']==len(j['reset_ids'])
    assert ob['latencies']==j['frames']+len(j['reset_ids'])
    assert ob['records']==j['main_records']+j['fresh_records']
    assert ob['resetmask']==sum(1<<i for i in j['reset_ids'])
    assert ob['cycles']<=j['cycle_limit']
    observations=[x for x in record['stdout'].splitlines() if x.startswith('OBS ')]
    assert [int(re.search(r'id=(\d+)',x)[1]) for x in observations]==j['reset_ids']
    return ob
def audit():
    m=read('MATRIX.json');p=read('TEST_PLAN.json');r=read('verification.json');matrix_audit(m)
    assert p['source_sha256']==sources()==r['source_sha256']
    assert p['commands']==commands(m)
    assert r['matrix_sha256']==p['matrix_sha256']==digest(ROOT/'MATRIX.json')
    assert r['plan_sha256']==digest(ROOT/'TEST_PLAN.json')
    assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout'] and r['not_run']==[]
    assert [v['name'] for v in r['records']]==m['children']
    for rec,cmd in zip(r['records'],p['commands']):
        assert rec['status']=='PASS' and rec['timeout_seconds']==20 and rec['elapsed_seconds']<20
        assert (rec['exit_code']!=0)==cmd[2]
        if rec['name']!='version' and not cmd[2]:assert rec['stderr']==''
    for j in m['jobs']:
        rec=next(x for x in r['records'] if x['name']==j['name']+'_simulate')
        assert marker(rec,j)==next(x['observed'] for x in r['jobs'] if x['name']==j['name'])
    for profile in m['profiles']:
        observations=[j['observed'] for j in r['jobs'] if (j['w'],j['h'],j['g'],j['t'])==
                      (profile['w'],profile['h'],profile['g'],profile['t'])]
        states=signs=saddles=resets=0
        for ob in observations:
            states|=ob['states'];signs|=ob['signs'];saddles|=ob['saddles'];resets|=ob['resetmask']
        assert states==(32767 if profile['w']>1 and profile['h']>1 else (1<<0)|(1<<1)|(1<<13)|(1<<14))
        assert resets==sum(1<<i for i in profile['reset_ids'])
        expected_signs=sum(1<<i for i in range(16) if profile['main_certificates'].get('sign_'+str(i),0))
        assert signs&expected_signs==expected_signs
        if profile['w']>1 and profile['h']>1:
            saddle_codes={'positive_a_high':0,'negative_a_low':1,'negative_a_high':2,
                          'positive_a_low':3,'zero_a_high':4,'zero_a_low':5}
            expected_saddles=sum(1<<code for label,code in saddle_codes.items()
                                 if profile['main_certificates'].get('saddle_'+label,0))
            assert saddles&expected_saddles==expected_saddles
            if profile['g']==1:assert saddles==48
        else:assert signs==saddles==0
    for rel in p['source_sha256']:
        b=(ROOT/rel).read_bytes();b.decode('utf-8');assert b'\r' not in b and not b.startswith(b'\xef\xbb\xbf')
    print('OFFLINE_AUDIT_PASS',len(r['records']),'children',len(p['source_sha256']),'frozen sources')
def archive(receipt):
    attempt=1
    while (ROOT/'failure_archive'/f'attempt_{attempt:02d}').exists():attempt+=1
    target=ROOT/'failure_archive'/f'attempt_{attempt:02d}'
    assert not target.exists(),'never overwrite evidence'
    target.mkdir(parents=True)
    for f in sorted(ROOT.rglob('*')):
        if f.is_file() and 'failure_archive' not in f.parts:
            dest=target/f.relative_to(ROOT);dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(f.read_bytes())
    (target/'receipt.json').write_bytes((json.dumps(receipt,indent=2)+'\n').encode())
    (target/'NOT_RUN.json').write_bytes((json.dumps(receipt['not_run'],indent=2)+'\n').encode())
def validate_repair():
    """Only the root-reviewed timescale repair; unchanged original evidence/stimuli."""
    prior=ROOT/'failure_archive'/'attempt_01';e=read('repair_01/repair.json')
    actual={p.relative_to(prior).as_posix():digest(p) for p in sorted(prior.rglob('*')) if p.is_file()}
    assert actual==e['original_archive_sha256'],'original complete archive must remain immutable'
    old=json.loads((prior/'receipt.json').read_text(encoding='utf-8'))
    assert old['status']=='FAIL' and not old['terminal_timeout']
    assert digest(ROOT/'verification.json')==digest(prior/'verification.json')==digest(prior/'receipt.json')==e['original_receipt_sha256']
    old_plan=json.loads((prior/'TEST_PLAN.json').read_text(encoding='utf-8'))
    assert digest(prior/'TEST_PLAN.json')==old['plan_sha256']==e['original_plan_sha256']
    assert digest(ROOT/'MATRIX.json')==digest(prior/'MATRIX.json')==e['original_matrix_sha256']
    allowed={'example/iso_graph16.sv','run_tests.py','README.md'}
    assert set(e['authorized_source_sha256'])==allowed
    for rel,h in old_plan['source_sha256'].items():
        assert digest(prior/rel)==h
        if rel not in allowed:assert digest(ROOT/rel)==h,'outside exact repair scope: '+rel
        else:assert digest(ROOT/rel)==e['authorized_source_sha256'][rel]
    assert set(sources())==set(old_plan['source_sha256'])|{'repair_01/repair.patch','repair_01/repair.json'}
    assert digest(ROOT/'repair_01/repair.patch')==e['diff_sha256']
    m=read('MATRIX.json');matrix_audit(m)
    assert commands(m)==old_plan['commands'],'all143 exact commands,20s limits and stimuli remain unchanged'
    return dict(archive='failure_archive/attempt_01',original_receipt_sha256=e['original_receipt_sha256'],
                original_plan_sha256=e['original_plan_sha256'],scope=sorted(allowed),diff_sha256=e['diff_sha256'])
def repair_reseal():
    assert read('TEST_PLAN.json')['stage']=='ALL_SOURCES_BEFORE_FIRST_HDL','repair seal is one-shot'
    repair=validate_repair();m=read('MATRIX.json')
    write('TEST_PLAN.json',dict(baseline=m['baseline'],stage='ROOT_AUTHORIZED_ORDINARY_FAIL_REPAIR_BEFORE_HDL',
                               matrix_sha256=digest(ROOT/'MATRIX.json'),timeout_seconds=20,
                               source_sha256=sources(),commands=commands(m),repair=repair))
    print('REPAIR_SOURCE_FROZEN',digest(ROOT/'TEST_PLAN.json'),len(sources()),'sources')
def run(repair_authorized=False):
    if (ROOT/'verification.json').exists():
        assert repair_authorized,'existing receipt blocks automatic reruns; explicit root execution authorization required'
        repair=validate_repair()
        assert read('TEST_PLAN.json').get('repair')==repair
    else:assert not repair_authorized,'repair requires the exact original ordinary failure'
    m=read('MATRIX.json');p=read('TEST_PLAN.json');matrix_audit(m)
    assert p['source_sha256']==sources() and p['commands']==commands(m)
    tool=REPO/'tools/oss-cad-suite/oss-cad-suite/bin/iverilog.exe'
    compiler=str(tool) if tool.is_file() else shutil.which('iverilog')
    vvp=str(tool.with_name('vvp.exe')) if tool.is_file() else shutil.which('vvp')
    if not compiler or not vvp:raise SystemExit('missing Icarus/vvp; NOT_RUN')
    receipt=dict(baseline=m['baseline'],status='RUNNING',hardware='HW_UNVERIFIED',matrix_sha256=digest(ROOT/'MATRIX.json'),
                 plan_sha256=digest(ROOT/'TEST_PLAN.json'),source_sha256=p['source_sha256'],records=[],jobs=[],
                 terminal_timeout=False,not_run=m['children'].copy(),repair=p.get('repair'))
    env=os.environ.copy();binary=Path(compiler).parent
    env['PATH']=str(binary)+os.pathsep+str(binary.parent/'lib')+os.pathsep+env.get('PATH','')
    with tempfile.TemporaryDirectory(prefix='anscore_b24_isocontour_') as temporary:
        substitutions={'@IVERILOG@':compiler,'@VVP@':vvp,'@TEMP@':temporary}
        for name,template,negative in p['commands']:
            argv=[]
            for word in template:
                for key,value in substitutions.items():word=word.replace(key,value)
                argv.append(word)
            start=time.monotonic();rec=dict(name=name,argv=argv,timeout_seconds=20)
            try:
                proc=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=20)
                rec.update(exit_code=proc.returncode,stdout=proc.stdout,stderr=proc.stderr,elapsed_seconds=round(time.monotonic()-start,3))
                good=(proc.returncode!=0 and 'grayscale_isocontour_invalid_parameters__see_README' in proc.stderr) if negative else proc.returncode==0
                if name!='version' and not negative:good=good and proc.stderr==''
                rec['status']='PASS' if good else 'FAIL'
                if good and name.endswith('_simulate'):
                    job=next(j for j in m['jobs'] if name==j['name']+'_simulate')
                    receipt['jobs'].append(dict(job,observed=marker(rec,job)))
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
                raise SystemExit('terminal child failure; complete archive+NOT_RUN preserved; root scope required')
        receipt['status']='UNIT_SIM_PASS'
        keys=['frames','queued','resets','fresh','records','owner_records','source_holds','output_holds','reads','multiplies','decisions','latencies']
        receipt['totals']={k:sum(j['observed'][k] for j in receipt['jobs']) for k in keys}
        write('verification.json',receipt)
    audit()
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--freeze-source',action='store_true');parser.add_argument('--run',action='store_true');parser.add_argument('--audit',action='store_true');parser.add_argument('--repair-reseal',action='store_true');parser.add_argument('--repair',action='store_true')
    args=parser.parse_args()
    if sum((args.freeze_source,args.run,args.audit,args.repair_reseal))!=1:parser.error('choose exactly one operation')
    if args.repair and not args.run:parser.error('--repair is valid only with an explicitly authorized --run')
    if args.freeze_source:
        if (ROOT/'TEST_PLAN.json').exists() or (ROOT/'verification.json').exists():raise SystemExit('source plan already frozen')
        m=read('MATRIX.json');matrix_audit(m)
        write('TEST_PLAN.json',dict(baseline=m['baseline'],stage='ALL_SOURCES_BEFORE_FIRST_HDL',matrix_sha256=digest(ROOT/'MATRIX.json'),
                                   timeout_seconds=20,source_sha256=sources(),commands=commands(m)))
        print('SOURCE_FROZEN',digest(ROOT/'TEST_PLAN.json'),len(sources()),'sources')
    elif args.repair_reseal:repair_reseal()
    elif args.run:run(args.repair)
    else:audit()
