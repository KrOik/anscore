"""SPDX-License-Identifier: Apache-2.0. Explicit repair01, reuses frozen vectors; no oracle import."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';IV=BIN/'iverilog.exe';VVP=BIN/'vvp.exe'
OLD_STAMP='20261106T073318044463Z';OLD=ROOT/'reports'/OLD_STAMP
OLD_RECEIPT_SHA='13d2e76588797d43a0d100ed108d761ca3169ef9aec7a922be8aefe7cf34f323'
OLD_PLAN_SHA='2e922b88e0ee903b4301027a420bdfcb503492d1a565474d6b5d889ba4dfe3fd'
FAILED=ROOT/'.build'/OLD_STAMP/'core_t1.vvp'
FAILED_SHA='6cca25e54e804626620567151e37f6fb9c98b8df51550aa77d53035dfdcebbc3'
PLAN=ROOT/'REPAIR01_PLAN.json'
INPUTS=['.gitattributes','rtl/rgba_porter_duff.sv','rtl/rgba_pair_premultiply.sv',
    'example/dual_indexed_porter_duff.sv','sim/tb_rgba_porter_duff.sv','sim/tb_dual_indexed_porter_duff.sv',
    'reference_model.py','run_tests.py','files.f','example/files.f','README.md','ARCHITECTURE.md','SOURCES.md',
    'references.json','LICENSE','../indexed_texture_sampler/rtl/indexed_texture_sampler.sv','PRECHECK_PLAN.json','run_repair01.py']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf8',newline='\n')
def original():
    assert sha(OLD/'results.json')==OLD_RECEIPT_SHA and sha(ROOT/'PRECHECK_PLAN.json')==OLD_PLAN_SHA and sha(FAILED)==FAILED_SHA
    receipt=json.loads((OLD/'results.json').read_text());plan=json.loads((ROOT/'PRECHECK_PLAN.json').read_text())
    assert receipt['status']=='FAIL' and len(receipt['records'])==5
    assert [r['status'] for r in receipt['records']]==['PASS']*4+['FAIL']
    assert receipt['preparation_complete'] and receipt['oracle_import_attempts']==receipt['preparation_attempts']==1
    assert receipt['arithmetic_audit']==dict(quantizer_totals=130051,alpha_mode_pairs=851968,extrema_checks=3407872,premultiply_pairs=65536)
    assert all(sha(OLD/receipt['exact_checked_copies'][n])==h for n,h in receipt['source_sha256'].items())
    assert all(sha(OLD/p['name']/n)==h for p in receipt['profiles'] for n,h in p['vectors_sha256'].items())
    return receipt,plan
def freeze():
    assert not any((ROOT/'reports').glob('repair01_*'))
    receipt,old_plan=original();checks=old_plan['checks'][2:3]+old_plan['checks'][3:]
    assert len(checks)==9
    write(PLAN,dict(schema='anscore-b41-rgba-repair01-plan-v1',baseline=old_plan['baseline'],
        status='SOURCE_REVIEW_PENDING_NOT_RUN',authorization='B NO_BLOCKER and explicit root authorization of exact repair plan required',
        repair='Only core coefficient process always @* to always_comb for guaranteed time0 evaluation; no TB/golden/oracle changes',
        original_receipt=str(OLD/'results.json'),original_receipt_sha256=OLD_RECEIPT_SHA,original_plan_sha256=OLD_PLAN_SHA,
        failed_image=str(FAILED),failed_image_sha256=FAILED_SHA,original_children=5,original_pass=4,original_fail=1,
        oracle_imports=0,oracle_preparations=0,repair_planning_python_calls=1,automatic_retry=False,fail_stop=True,
        execution_deadline_seconds=20,tree_kill_seconds=5,drain_seconds=2,
        expected_checks=[c['name'] for c in checks],checks=checks,profiles=receipt['profiles'],
        reused_arithmetic_audit=receipt['arithmetic_audit'],
        reused_vector_sha256={str(OLD/p['name']/n):h for p in receipt['profiles'] for n,h in p['vectors_sha256'].items()},
        source_sha256={n:sha(ROOT/n) for n in INPUTS},tool_sha256={str(p):sha(p) for p in [IV,VVP]},
        scope='One max-closure syntax plus four compile/sim pairs; all original20 vectors reused, no oracle import/preparation or old core syntax variants'))
    print('Frozen repair01 source-only plan',sha(PLAN),'children',len(checks),flush=True)

def execute(c,stamp,env,report):
    argv=[a.replace('<stamp>',stamp) for a in c['argv']];cwd=c['cwd'].replace('<stamp>',stamp)
    start=time.monotonic();code=None;out=err=b'';cleanup=[];reason=None
    options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
    try:child=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:status='NOT_RUN';err=(repr(exc)+'\n').encode()
    else:
        try:out,err=child.communicate(timeout=20);code=child.returncode;status='PASS' if code==0 else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            status='TIMEOUT';out=exc.stdout or b'';err=exc.stderr or b''
            if os.name=='nt':
                kill=[str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F']
                try:
                    k=subprocess.run(kill,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill,returncode=k.returncode,stdout=k.stdout.decode(errors='replace'),stderr=k.stderr.decode(errors='replace')))
                except (OSError,subprocess.TimeoutExpired) as exc:cleanup.append(dict(action='tree_kill',error=repr(exc)))
            else:
                try:os.killpg(child.pid,signal.SIGKILL)
                except OSError as exc:cleanup.append(dict(action='group_kill',error=repr(exc)))
            try:
                if child.poll() is None:child.kill()
            except OSError as exc:cleanup.append(dict(action='parent_kill',error=repr(exc)))
            try:out,err=child.communicate(timeout=2)
            except subprocess.TimeoutExpired as exc:out=exc.stdout or out;err=exc.stderr or err;cleanup.append(dict(action='drain',error=repr(exc)))
            except OSError as exc:cleanup.append(dict(action='drain',error=repr(exc)))
            code=child.poll()
    counters=None
    if status=='PASS' and c['marker']:
        lines=[l for l in out.decode(errors='replace').splitlines() if l.startswith(c['marker'])]
        try:
            assert len(lines)==1 and b'$finish' in out
            counters={k:int(v) for word in lines[0].split() if '=' in word for k,v in [word.split('=',1)]}
            assert all(counters.get(k)==v for k,v in c['expected_counters'].items()) and counters['holds']>0 and counters['gaps']>0
        except (AssertionError,ValueError,KeyError):status='FAIL';reason='Completion/counters disagree with frozen repair plan'
    name=c['name'];(report/(name+'.stdout.txt')).write_bytes(out);(report/(name+'.stderr.txt')).write_bytes(err)
    return dict(name=name,argv=argv,cwd=cwd,status=status,returncode=code,reason=reason,counters=counters,
        execution_deadline_seconds=20,tree_kill_seconds=5,drain_seconds=2,cleanup=cleanup,seconds=round(time.monotonic()-start,3),
        stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())

def main():
    assert not any((ROOT/'reports').glob('repair01_*')),'Existing repair01 evidence blocks another execution'
    old,old_plan=original();plan=json.loads(PLAN.read_text());stamp='repair01_'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    report=ROOT/'reports'/stamp;report.mkdir();(ROOT/'.build'/stamp).mkdir()
    names=INPUTS+['REPAIR01_PLAN.json'];hashes={n:sha(ROOT/n) for n in names};copies={}
    for n in names:
        source=(ROOT/n).resolve();a=report/'executed_inputs'/source.relative_to(REPO);a.parent.mkdir(parents=True,exist_ok=True)
        a.write_bytes(source.read_bytes());copies[n]=a.relative_to(report).as_posix()
    records=[];vectors_copied=False;complete=False;exception=None
    tools={str(p):sha(p) for p in [IV,VVP]};env=os.environ.copy();env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    def checkpoint(status,event,**extra):
        value=dict(schema='anscore-b41-rgba-repair01-finite-v1',status=status,event=event,source_sha256=hashes,exact_checked_copies=copies,
            tools=tools,profiles=old['profiles'],arithmetic_audit=old['arithmetic_audit'],arithmetic_audit_reused_from=str(OLD/'results.json'),
            original_receipt=str(OLD/'results.json'),original_receipt_sha256=OLD_RECEIPT_SHA,original_plan_sha256=OLD_PLAN_SHA,
            original_children=5,original_pass=4,original_fail=1,failed_image=str(FAILED),failed_image_sha256=FAILED_SHA,
            oracle_import_attempts=0,preparation_attempts=0,vector_copy_complete=vectors_copied,suite_complete=complete,
            repair_planning_python_calls=1,expected_checks=plan['expected_checks'],records=records,automatic_retry=False,fail_stop=True,
            exception=exception,synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED',**extra)
        tmp=report/'results.json.tmp'
        with tmp.open('w',encoding='utf8',newline='\n') as f:f.write(json.dumps(value,indent=2)+'\n');f.flush();os.fsync(f.fileno())
        tmp.replace(report/'results.json')
    checkpoint('INCOMPLETE','before_vector_copy')
    try:
        assert set(plan['source_sha256'])==set(INPUTS) and all(hashes[n]==h for n,h in plan['source_sha256'].items())
        assert tools==plan['tool_sha256'] and plan['profiles']==old['profiles']
        assert plan['checks']==old_plan['checks'][2:3]+old_plan['checks'][3:]
        assert plan['reused_arithmetic_audit']==old['arithmetic_audit']
        assert plan['reused_vector_sha256']=={str(OLD/p['name']/n):h for p in old['profiles'] for n,h in p['vectors_sha256'].items()}
        for p in old['profiles']:
            dest=report/p['name'];dest.mkdir()
            for n,h in p['vectors_sha256'].items():
                source=OLD/p['name']/n;assert sha(source)==h;(dest/n).write_bytes(source.read_bytes());assert sha(dest/n)==h
        vectors_copied=True;checkpoint('INCOMPLETE','after_vector_copy')
        for c in plan['checks']:
            original()
            assert all(sha(ROOT/n)==h and sha(report/copies[n])==h for n,h in hashes.items())
            assert all(sha(report/p['name']/n)==h for p in old['profiles'] for n,h in p['vectors_sha256'].items())
            assert {str(p):sha(p) for p in [IV,VVP]}==tools
            r=execute(c,stamp,env,report);records.append(r);checkpoint('INCOMPLETE','after_'+c['name']);print(c['name'],r['status'],flush=True)
            if r['status']!='PASS':return 1
        complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/'exception.txt').write_text(exception,encoding='utf8');return 1
    finally:
        sources_ok=all(sha(ROOT/n)==h for n,h in hashes.items());archives_ok=all(sha(report/copies[n])==h for n,h in hashes.items())
        vectors_ok=vectors_copied and all(sha(report/p['name']/n)==h for p in old['profiles'] for n,h in p['vectors_sha256'].items())
        tools_ok={str(p):sha(p) for p in [IV,VVP]}==tools
        try:original();original_ok=True
        except Exception:original_ok=False
        intact=sources_ok and archives_ok and vectors_ok and tools_ok and original_ok
        ok=complete and [r['name'] for r in records]==plan['expected_checks'] and all(r['status']=='PASS' for r in records)
        status='SOURCE_CHANGED' if not intact else 'PASS' if ok else next((r['status'] for r in records if r['status']!='PASS'),'INCOMPLETE')
        checkpoint(status,'final',sources_unchanged=sources_ok,archives_unchanged=archives_ok,vectors_unchanged=vectors_ok,tools_unchanged=tools_ok,original_evidence_unchanged=original_ok)
        print('REPORT',report,'STATUS',status,flush=True)
        if not intact:raise RuntimeError('Frozen original/repair evidence changed')

if __name__=='__main__':
    if sys.argv[1:]==['--freeze']:freeze()
    elif sys.argv[1:]==['--run']:sys.exit(main())
    else:raise SystemExit('Use --freeze then explicit B/root authorization before --run')
