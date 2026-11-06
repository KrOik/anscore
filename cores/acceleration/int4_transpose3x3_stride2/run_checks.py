"""B45 one-shot bounded checks. New standalone runner; no historical imports."""
from pathlib import Path
import datetime, hashlib, json, os, shutil, subprocess, sys, time, traceback
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
BIN = REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN = ROOT/'FINITE_PLAN.json'
SEAL = ROOT/'SOURCE_SEAL.json'
REVIEW = ROOT/'SOURCE_REVIEW.json'
KILL_EXE = Path(os.environ['SystemRoot'])/'System32/taskkill.exe'
GUARD = REPO/'.git/anscore-b45-transpose-once.json'
BASE = 'a0602fb2dac20db7c524297371a19f5f580980df'
PROFILES = {'tiny': (1,1,1,1,1,0), 'rgb': (3,3,7,5,8,0),
            'limits': (16,16,1023,1023,32,0), 'example': (3,3,7,5,8,1)}
SOURCES = ('.gitattributes','.gitignore','LICENSE','README.md','ARCHITECTURE.md','SOURCES.md',
           'manifest.json','files.f','example/files.f','rtl/int4_transpose3x3_stride2.sv',
           'example/rgb_transpose_decoder.sv','model/build_vectors.py','sim/tb_int4_transpose3x3_stride2.sv','run_checks.py',
           '../int4_weight_matvec/rtl/deps/stream_requantize.v',
           '../int4_weight_matvec/rtl/int4_weight_matvec.sv',
           '../int4_subpixel_upsample2x/rtl/int4_subpixel_upsample2x.sv')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def commands(stamp):
    out = ROOT/'reports'/stamp
    iv, vvp = str(BIN/'iverilog.exe'), str(BIN/'vvp.exe')
    specs = []
    def add(name, kind, argv, **extra):
        specs.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(ROOT),
                          hard_seconds=20,tree_kill_seconds=5,drain_seconds=2,**extra))
    model = out/'executed_inputs'/ROOT.relative_to(REPO)/'model/build_vectors.py'
    for label in PROFILES:
        add('prepare_'+label,'PREPARATION',[sys.executable,'-I','-B',model,'--profile',label,'--out',out/(label+'.txt')],profile=label)
    add('syntax_default','HDL',[iv,'-g2012','-Wall','-tnull','-s','int4_transpose3x3_stride2','-f','files.f'])
    maximum = dict(MAX_IN_CHANNELS=16,MAX_OUT_CHANNELS=16,MAX_WIDTH=1023,MAX_HEIGHT=1023,TAG_W=32)
    add('syntax_maximum','HDL',[iv,'-g2012','-Wall','-tnull','-s','int4_transpose3x3_stride2',
        *['-Pint4_transpose3x3_stride2.%s=%d'%(k,v) for k,v in maximum.items()],'-f','files.f'])
    add('syntax_example','HDL',[iv,'-g2012','-Wall','-tnull','-s','rgb_transpose_decoder','-f','example/files.f'])
    for label, values in PROFILES.items():
        image = ROOT/'.work'/stamp/(label+'.vvp')
        add('compile_'+label,'HDL',[iv,'-g2012','-Wall','-s','tb_int4_transpose3x3_stride2',
            *['-Ptb_int4_transpose3x3_stride2.%s=%d'%(k,v) for k,v in zip(('MC','MO','MW','MH','TW','RGB'),values)],
            '-o',image,'-f','example/files.f','sim/tb_int4_transpose3x3_stride2.sv'],profile=label,image=str(image))
        add('simulate_'+label,'HDL',[vvp,image,'+VECTORS='+(out/(label+'.txt')).as_posix()],profile=label,image=str(image))
    return specs


def child(spec, out, env, report, save):
    prefix = out/spec['name']
    stdout_path = prefix.with_suffix('.stdout.raw');stderr_path = prefix.with_suffix('.stderr.raw')
    record_path = prefix.with_suffix('.json')
    rec = dict(spec,status='STARTING',pid=None,exit_code=None,cleanup=[])
    report['children'].append(rec)
    def persist():
        with record_path.open('w',encoding='utf-8',newline='\n') as stream:
            json.dump(rec,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        report['child_records'][record_path.name]=sha(record_path)
        save()
    persist();started=time.monotonic();proc=None
    with stdout_path.open('xb',buffering=0) as output, stderr_path.open('xb',buffering=0) as error:
        try:
            proc=subprocess.Popen(spec['argv'],cwd=ROOT,env=env,stdin=subprocess.DEVNULL,
                                  stdout=output,stderr=error,creationflags=subprocess.CREATE_NO_WINDOW)
            rec.update(pid=proc.pid,status='RUNNING');persist()
            try:
                proc.wait(timeout=max(0.001,20-(time.monotonic()-started)))
                elapsed=time.monotonic()-started
                rec['execution_seconds']=round(elapsed,6)
                rec['status']='TIMEOUT' if elapsed>=20 else ('PASS' if proc.returncode==0 else 'FAIL')
            except subprocess.TimeoutExpired:
                rec['status']='TIMEOUT'
        except Exception:
            rec.update(status='SPAWN_FAILED' if proc is None else 'HARNESS_FAILED',exception=traceback.format_exc())
        finally:
            if proc is not None and proc.poll() is None:
                cleanup=dict(status='STARTING',hard_seconds=5,pid=None,exit_code=None,
                             process_exited=False,output_capture_complete=False)
                rec['cleanup'].append(cleanup)
                helper=None;kill_start=time.monotonic()
                ko_path=prefix.with_suffix('.taskkill.stdout.raw');ke_path=prefix.with_suffix('.taskkill.stderr.raw')
                try:
                    try:persist()
                    except Exception as exc:cleanup['save_error']=repr(exc)
                    assert sha(KILL_EXE)==report['tools_sha256'][str(KILL_EXE)]
                    with ko_path.open('xb',buffering=0) as ko, ke_path.open('xb',buffering=0) as ke:
                        helper=subprocess.Popen([str(KILL_EXE),
                            '/PID',str(proc.pid),'/T','/F'],stdin=subprocess.DEVNULL,stdout=ko,stderr=ke,
                            creationflags=subprocess.CREATE_NO_WINDOW)
                        cleanup.update(pid=helper.pid,status='RUNNING')
                        report['active_helper']=dict(name=spec['name']+'.taskkill',pid=helper.pid,status='RUNNING')
                        try:persist()
                        except Exception as exc:cleanup['pid_save_error']=repr(exc)
                        try:
                            helper.wait(timeout=max(0.001,5-(time.monotonic()-kill_start)))
                            elapsed=time.monotonic()-kill_start
                            cleanup['execution_seconds']=round(elapsed,6)
                            cleanup['status']='TIMEOUT' if elapsed>=5 else ('EXITED' if helper.returncode==0 else 'FAIL')
                        except subprocess.TimeoutExpired:
                            cleanup['status']='TIMEOUT';helper.kill()
                        cleanup['exit_code']=helper.poll()
                        ko.flush();ke.flush();os.fsync(ko.fileno());os.fsync(ke.fileno())
                except Exception as exc:
                    cleanup.update(status='HARNESS_FAILED',exception=repr(exc))
                    if helper is not None and helper.poll() is None:
                        try:helper.kill()
                        except Exception as kill_error:cleanup['helper_kill_error']=repr(kill_error)
                if proc.poll() is None:
                    try:proc.kill();cleanup['direct_parent_kill']='ISSUED'
                    except Exception as exc:cleanup['direct_parent_kill']=repr(exc)
                try:proc.wait(timeout=2)  # Sole post-termination drain interval.
                except subprocess.TimeoutExpired:cleanup['target_termination']='UNCONFIRMED'
                except Exception as exc:cleanup['target_wait_error']=repr(exc)
                # Nonwaiting observation after that sole interval, even if helper kill failed.
                helper_code=helper.poll() if helper is not None else None
                cleanup.update(exit_code=helper_code,process_exited=helper is not None and helper_code is not None)
                for key,path in (('stdout',ko_path),('stderr',ke_path)):
                    if path.is_file():
                        with path.open('ab') as raw:
                            raw.flush();os.fsync(raw.fileno())
                        cleanup[key]=dict(path=path.name,sha256=sha(path),bytes=path.stat().st_size)
                cleanup['output_capture_complete']=cleanup['process_exited'] and all(key in cleanup for key in ('stdout','stderr'))
                if helper is not None and helper_code is None:
                    cleanup['status']='TERMINATION_UNCONFIRMED'
                    report['active_helper']=dict(name=spec['name']+'.taskkill',pid=helper.pid,status='TERMINATION_UNCONFIRMED')
                else:report['active_helper']=None
            output.flush();error.flush();os.fsync(output.fileno());os.fsync(error.fileno())
    code=proc.poll() if proc is not None else None
    rec.update(exit_code=code,seconds=round(time.monotonic()-started,6),
               process_exited=proc is not None and code is not None,
               output_capture_complete=proc is not None and code is not None and all(c['output_capture_complete'] for c in rec['cleanup']))
    for key,path in (('stdout',stdout_path),('stderr',stderr_path)):
        rec[key]=dict(path=path.name,sha256=sha(path),bytes=path.stat().st_size)
    if proc is not None and code is None:rec['status']='TERMINATION_UNCONFIRMED'
    rec['process_evidence_saved']=True
    report['active_child']=None if proc is None or code is not None else spec['name']
    persist()  # Durable PID, exit and raw output before any metadata parsing.
    return rec,persist


def run():
    assert os.name=='nt' and sys.argv[1:]==['--execute-approved-plan']
    plan=json.loads(PLAN.read_bytes());review=json.loads(REVIEW.read_bytes())
    assert plan['baseline_commit']==BASE and plan['schema']=='anscore-b45-transpose-plan-v1'
    assert review['root']=='NO_BLOCKER' and review['peer']=='NO_BLOCKER'
    assert review['execution_gate']=='B45_TRANSPOSE_FINITE_ONCE'
    assert review['plan_sha256']==sha(PLAN) and review['runner_sha256']==sha(Path(__file__))
    assert review['source_seal_sha256']==sha(SEAL)
    assert plan['source_inputs_sha256']==review['source_inputs_sha256']
    assert set(plan['source_inputs_sha256'])==set(SOURCES)
    assert plan['children']==commands('<stamp>')
    assert (plan['preparation_children'],plan['hdl_children'],plan['successful_simulations_if_pass'])==(4,11,4)
    assert plan['planning_numerical_calls']==0 and plan['automatic_retry'] is False
    for name,digest in plan['source_inputs_sha256'].items():assert sha(ROOT/name)==digest
    assert set(plan['tools_sha256'])=={str(Path(sys.executable)),str(BIN/'iverilog.exe'),str(BIN/'vvp.exe'),str(KILL_EXE)}
    for name,digest in plan['tools_sha256'].items():assert sha(Path(name))==digest
    assert not GUARD.exists() and not (ROOT/'reports').exists()
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    with GUARD.open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(dict(schema='anscore-b45-transpose-once-v1',plan_sha256=sha(PLAN),
                       review_sha256=sha(REVIEW),stamp=stamp,automatic_retry=False),stream,indent=2)
        stream.write('\n');stream.flush();os.fsync(stream.fileno())
    out=ROOT/'reports'/stamp;work=ROOT/'.work'/stamp
    out.mkdir(parents=True,exist_ok=False);work.mkdir(parents=True,exist_ok=False)
    report=dict(schema='anscore-b45-transpose-evidence-v1',baseline_commit=BASE,status='INCOMPLETE',
                plan_sha256=sha(PLAN),source_seal_sha256=sha(SEAL),review_sha256=sha(REVIEW),children=[],active_child=None,active_helper=None,
                archive_complete=False,suite_complete=False,automatic_retry=False,planning_numerical_calls=0,
                source_inputs_sha256=plan['source_inputs_sha256'],tools_sha256=plan['tools_sha256'],
                archived_inputs={},profiles={},images={},child_records={},hardware='HW_UNVERIFIED',
                synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN',
                combined_compile='NOT_RUN',inherited_regression='NOT_RUN')
    def save():
        with (out/'results.json').open('w',encoding='utf-8',newline='\n') as stream:
            json.dump(report,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    def invariant():
        assert sha(PLAN)==report['plan_sha256']==sha(out/'plan.json')
        assert sha(SEAL)==report['source_seal_sha256']==sha(out/'source_seal.json')
        assert sha(REVIEW)==report['review_sha256']==sha(out/'review.json')
        for name,digest in report['source_inputs_sha256'].items():
            assert sha(ROOT/name)==digest==sha(ROOT/report['archived_inputs'][name])
        for name,digest in report['tools_sha256'].items():assert sha(Path(name))==digest
        for label,summary in report['profiles'].items():assert sha(out/(label+'.txt'))==summary['sha256']
        for image,digest in report['images'].items():assert sha(ROOT/image)==digest
        for name,digest in report['child_records'].items():assert sha(out/name)==digest
        for rec in report['children']:
            if rec.get('process_evidence_saved'):
                for key in ('stdout','stderr'):assert sha(out/rec[key]['path'])==rec[key]['sha256']
                for cleanup in rec['cleanup']:
                    for key in ('stdout','stderr'):
                        if key in cleanup:assert sha(out/cleanup[key]['path'])==cleanup[key]['sha256']
    save()
    try:
        shutil.copyfile(PLAN,out/'plan.json');shutil.copyfile(SEAL,out/'source_seal.json');shutil.copyfile(REVIEW,out/'review.json')
        for name,digest in report['source_inputs_sha256'].items():
            source=(ROOT/name).resolve();assert source.is_relative_to(REPO)
            target=out/'executed_inputs'/source.relative_to(REPO)
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
            assert sha(target)==digest;report['archived_inputs'][name]=target.relative_to(ROOT).as_posix()
        report['archive_complete']=True;save();invariant()
        env=dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''),PYTHONDONTWRITEBYTECODE='1')
        for spec in commands(stamp):
            invariant();report['active_child']=spec['name'];save()
            image_before=sha(Path(spec['image'])) if spec['name'].startswith('simulate_') else None
            rec,persist=child(spec,out,env,report,save)
            if 'image' in spec and Path(spec['image']).is_file():
                image=Path(spec['image']);digest=sha(image)
                report['images'].setdefault(image.relative_to(ROOT).as_posix(),digest)
                rec.update(image_sha256=digest,image=image.relative_to(ROOT).as_posix())
            if image_before is not None:rec['execution_image_sha256']=image_before
            if rec['status']=='PASS':
                try:
                    if spec['kind']=='PREPARATION':
                        summary=json.loads((out/rec['stdout']['path']).read_bytes())
                        label=spec['profile'];vector=out/(label+'.txt')
                        assert summary['profile']==label and summary['file']==str(vector)
                        assert summary['sha256']==sha(vector) and summary['bytes']==vector.stat().st_size
                        assert summary['cases']==(15 if label=='limits' else 12)
                        assert summary['direct_scatter_evaluations']==(11 if label=='limits' else 8)
                        report['profiles'][label]=summary
                    elif spec['name'].startswith('compile_'):
                        image=Path(spec['image']);assert image.is_file()
                        report['images'][image.relative_to(ROOT).as_posix()]=sha(image)
                        rec.update(image_sha256=sha(image),image=image.relative_to(ROOT).as_posix())
                    elif spec['name'].startswith('simulate_'):
                        image=Path(spec['image']);assert sha(image)==image_before
                        rec.update(image_sha256=image_before,image=image.relative_to(ROOT).as_posix())
                        lines=(out/rec['stdout']['path']).read_text(encoding='utf-8').splitlines()
                        passed=[line for line in lines if line.startswith('PASS profile ')]
                        assert len(passed)==1 and any('$finish' in line for line in lines)
                        label=spec['profile'];cases=report['profiles'][label]['cases']
                        assert 'cases=%d frames=%d resets=4 future=1 '%(cases,cases+4) in passed[0]
                        assert int(passed[0].split('stalls=')[1])>0
                        rec['observed']=passed[0]
                    rec['metadata_validated']=True
                except Exception:
                    rec.update(status='FAIL_METADATA',metadata_exception=traceback.format_exc())
            persist();print(spec['name'],rec['status'],flush=True)
            if rec['status']!='PASS':report['status']='FAIL_STOP';break
        else:report['status']='PASS'
    except Exception:
        report.update(status='HARNESS_FAILED',exception=traceback.format_exc())
    finally:
        try:invariant();unchanged=True
        except Exception:unchanged=False
        exact=[r['name'] for r in report['children']]==[s['name'] for s in commands(stamp)]
        ok=report['status']=='PASS' and exact and unchanged and report['archive_complete'] and report['active_child'] is None and report['active_helper'] is None
        report.update(inputs_unchanged=unchanged,exact_plan_executed=exact,suite_complete=ok,
                      preparation_children=sum(r['kind']=='PREPARATION' for r in report['children']),
                      direct_scatter_evaluations=sum(p['direct_scatter_evaluations'] for p in report['profiles'].values()),
                      hdl_children=sum(r['kind']=='HDL' for r in report['children']),
                      successful_simulations=sum(r['name'].startswith('simulate_') and r['status']=='PASS' for r in report['children']),
                      maturity=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if ok else ['RTL_CANDIDATE','HW_UNVERIFIED'])
        if report['status']=='PASS' and not ok:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
        save();print(out.relative_to(ROOT).as_posix(),flush=True)
    return 0 if report['suite_complete'] else 1


if __name__=='__main__':
    raise SystemExit(run())
