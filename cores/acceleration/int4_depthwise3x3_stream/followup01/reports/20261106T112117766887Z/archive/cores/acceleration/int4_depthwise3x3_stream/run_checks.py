"""B44 finite runner; archive first, durable child record before parsing."""
from pathlib import Path
import datetime, hashlib, json, os, re, shutil, signal, subprocess, sys, time, traceback
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
BIN = REPO / 'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN = ROOT / 'FINITE_PLAN.json'
GATE = ROOT / 'SOURCE_REVIEW.json'
GUARD = REPO / '.git/anscore-b44-depthwise-once.json'
PROFILES = [(1,3,3,1,False),(3,7,5,8,False),(16,3,3,32,False),(1,1024,3,8,False),(3,5,4,8,True)]
SOURCES = ['rtl/int4_depthwise3x3_stream.v','example/rgb_depthwise_filter.v',
 'sim/tb_depthwise.sv','reference_model.py','run_checks.py','files.f','example/files.f',
 '.gitattributes','.gitignore','README.md','ARCHITECTURE.md','SOURCES.md','LICENSE','manifest.json',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v',
 '../int4_weight_matvec/rtl/deps/stream_requantize.v']

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def label(profile):
    c,w,h,t,rgb = profile
    return 'rgb' if rgb else 'c%d_w%d_h%d_t%d' % (c,w,h,t)

def commands(stamp):
    out = ROOT / 'reports' / stamp
    iv, vvp = str(BIN/'iverilog.exe'), str(BIN/'vvp.exe')
    checks = []
    def add(name, argv, kind='HDL', marker=None):
        checks.append(dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT),kind=kind,marker=marker,
                           timeout_seconds=20,tree_kill_seconds=5,drain_seconds=2))
    archived_model = out / 'executed_inputs' / ROOT.relative_to(REPO) / 'reference_model.py'
    for p in PROFILES:
        c,w,h,t,rgb = p
        add('prepare_'+label(p),[sys.executable,'-I','-B',archived_model,'--channels',c,'--width',w,
             '--height',h,'--tag',t,*(['--rgb'] if rgb else []),'--output',out/(label(p)+'.txt')],
             'PREPARATION','PASS prepare_depthwise ')
    add('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','int4_depthwise3x3_stream','-f','files.f'])
    add('syntax_maximum',[iv,'-g2012','-Wall','-tnull','-s','int4_depthwise3x3_stream',
         '-Pint4_depthwise3x3_stream.MAX_CHANNELS=16','-Pint4_depthwise3x3_stream.MAX_WIDTH=1024',
         '-Pint4_depthwise3x3_stream.MAX_HEIGHT=1024','-Pint4_depthwise3x3_stream.TAG_W=32','-f','files.f'])
    add('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','rgb_depthwise_filter','-f','example/files.f'])
    for p in PROFILES:
        c,w,h,t,rgb = p
        image = ROOT / '.work' / stamp / (label(p)+'.vvp')
        add('compile_'+label(p),[iv,'-g2012','-Wall','-s','tb_depthwise',
             '-Ptb_depthwise.C=%d'%c,'-Ptb_depthwise.W=%d'%w,'-Ptb_depthwise.H=%d'%h,
             '-Ptb_depthwise.T=%d'%t,'-Ptb_depthwise.RGB=%d'%rgb,
             '-o',image,'-f','example/files.f','sim/tb_depthwise.sv'])
        add('sim_'+label(p),[vvp,image,'+vectors='+(out/(label(p)+'.txt')).as_posix()],
             marker='PASS depthwise C=%d W=%d H=%d T=%d RGB=%d '%(c,w,h,t,rgb))
    return checks

def freeze():
    if PLAN.exists() or (ROOT/'reports').exists():
        raise RuntimeError('existing plan/evidence: no automatic replanning')
    plan = dict(schema='anscore-b44-depthwise-plan-v1',baseline_commit='09de72c578b3099d4e867c739118faa7607f663d',
        expected_preparations=5,expected_hdl_children=13,successful_simulations_if_pass=5,
        automatic_retry=False,fail_stop=True,planning_numerical_calls=0,
        executable_sources={name:sha(ROOT/name) for name in SOURCES},
        tools={str(p):sha(p) for p in [BIN/'iverilog.exe',BIN/'vvp.exe',Path(sys.executable)]},
        profiles=[dict(label=label(p),parameters=dict(channels=p[0],width=p[1],height=p[2],tag=p[3],rgb=p[4])) for p in PROFILES],
        checks=commands('<stamp>'),guard=str(GUARD),
        scope='Five archived independent tensor preparations; three syntax and five compile/sim pairs. No inherited execution/import, synthesis/PnR/STA/board/PPA.')
    PLAN.write_bytes((json.dumps(plan,indent=2)+'\n').encode())
    print('FROZEN',sha(PLAN))

def child(spec, env, out, report, save):
    started = time.monotonic()
    rec = dict(spec, cleanup=[],status='STARTING',returncode=None)
    (report['preparations'] if spec['kind']=='PREPARATION' else report['checks']).append(rec)
    save()
    proc = None
    with (out/(spec['name']+'.stdout.txt')).open('xb') as output, (out/(spec['name']+'.stderr.txt')).open('xb') as error:
        try:
            proc = subprocess.Popen(spec['argv'],cwd=ROOT,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=error,
                   **({'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}))
            rec.update(pid=proc.pid,status='RUNNING');save()
            try:
                proc.wait(timeout=max(0.001,20-(time.monotonic()-started)))
                rec['status']='PASS' if proc.returncode==0 else 'FAIL'
            except subprocess.TimeoutExpired:
                rec['status']='TIMEOUT'
        except Exception as exc:
            rec.update(status='HARNESS_FAILURE',exception=repr(exc))
        finally:
            if proc is not None and proc.poll() is None:
                cleanup=dict(status='STARTED');rec['cleanup'].append(cleanup)
                try:
                    try:
                        save()
                    except Exception as exc:
                        cleanup['record_exception']=repr(exc)
                    if os.name=='nt':
                        kill_started=time.monotonic()
                        with (out/(spec['name']+'.cleanup.stdout.txt')).open('xb') as ko, (out/(spec['name']+'.cleanup.stderr.txt')).open('xb') as ke:
                            helper=subprocess.Popen([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),
                                '/PID',str(proc.pid),'/T','/F'],stdin=subprocess.DEVNULL,stdout=ko,stderr=ke,creationflags=subprocess.CREATE_NO_WINDOW)
                            cleanup['helper_pid']=helper.pid
                            try:
                                helper.wait(timeout=max(0.001,5-(time.monotonic()-kill_started)))
                            except subprocess.TimeoutExpired:
                                cleanup['helper_timeout']=True;helper.kill()
                            cleanup['helper_returncode']=helper.poll()
                    else:
                        os.killpg(proc.pid,signal.SIGKILL)
                except Exception as exc:
                    cleanup['exception']=repr(exc)
                if proc.poll() is None:
                    try:
                        proc.kill()  # Nonwaiting fallback before the sole drain.
                    except OSError as exc:
                        cleanup['fallback_kill_error']=repr(exc)
                try:
                    proc.wait(timeout=2)  # Sole target exit/drain interval.
                except subprocess.TimeoutExpired:
                    cleanup['target_still_running']=True
            output.flush();error.flush();os.fsync(output.fileno());os.fsync(error.fileno())
    rec.update(returncode=None if proc is None else proc.poll(),seconds=round(time.monotonic()-started,4))
    rec['process_exited']=proc is not None and rec['returncode'] is not None
    rec['output_capture_complete']=rec['process_exited']
    stdout=(out/(spec['name']+'.stdout.txt')).read_bytes()
    stderr=(out/(spec['name']+'.stderr.txt')).read_bytes()
    for name,raw in [('stdout',stdout),('stderr',stderr)]:
        rec[name+'_sha256']=hashlib.sha256(raw).hexdigest()
    report['active_child']=None if proc is None or rec['process_exited'] else spec['name']
    rec['process_evidence_saved']=True
    save()  # Persist PID/exit/raw/time before marker or image metadata parsing.
    if rec['status']=='PASS' and spec['marker']:
        if sum(line.startswith(spec['marker'].encode()) for line in stdout.splitlines())!=1:
            rec['status']='FAIL_MARKER'
        elif spec['name'].startswith('sim_') and b'$finish' not in stdout:
            rec['status']='FAIL_FINISH'
    if '-o' in spec['argv']:
        image=Path(spec['argv'][spec['argv'].index('-o')+1])
        if image.is_file():
            rec.update(image=image.relative_to(ROOT).as_posix(),image_sha256=sha(image))
    return rec

def run():
    plan=json.loads(PLAN.read_bytes())
    gate=json.loads(GATE.read_bytes())
    assert gate['plan_sha256']==sha(PLAN) and gate['root']=='NO_BLOCKER' and gate['peer']=='NO_BLOCKER_A'
    assert gate['execution_gate']=='B44_DEPTHWISE_ONCE_01'
    assert set(plan['executable_sources'])==set(SOURCES) and plan['checks']==commands('<stamp>')
    assert all(sha(ROOT/n)==digest for n,digest in plan['executable_sources'].items())
    assert all(sha(Path(n))==digest for n,digest in plan['tools'].items())
    if (ROOT/'reports').exists():
        raise RuntimeError('existing evidence; separately reviewed followup required')
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    with GUARD.open('x',encoding='utf-8') as guard:
        json.dump(dict(plan_sha256=sha(PLAN),gate_sha256=sha(GATE),stamp=stamp),guard,indent=2)
    out=ROOT/'reports'/stamp
    out.mkdir(parents=True,exist_ok=False)
    (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report=dict(schema='anscore-b44-depthwise-evidence-v1',status='INCOMPLETE',baseline_commit=plan['baseline_commit'],
        plan_sha256=sha(PLAN),gate_sha256=sha(GATE),source_sha256={},archived_sources={},tools=plan['tools'],
        preparations=[],checks=[],profiles=[],active_child=None,archive_complete=False,suite_complete=False,
        planning_numerical_calls=0,numerical_preparation_attempts=0,numerical_preparation_calls=0,
        automatic_retry=False,hardware='HW_UNVERIFIED',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN')
    def save():
        temp=out/'results.json.tmp'
        with temp.open('w',encoding='utf-8',newline='\n') as handle:
            json.dump(report,handle,indent=2);handle.write('\n');handle.flush();os.fsync(handle.fileno())
        temp.replace(out/'results.json')
    def invariant():
        assert sha(PLAN)==report['plan_sha256']==sha(out/'plan.json')
        assert sha(GATE)==report['gate_sha256']==sha(out/'gate.json')
        assert all(sha(ROOT/n)==digest==sha(ROOT/report['archived_sources'][n]) for n,digest in report['source_sha256'].items())
        assert all(sha(Path(n))==digest for n,digest in report['tools'].items())
        assert all(sha(out/p['vector'])==p['vector_sha256'] and sha(out/p['summary'])==p['summary_sha256'] for p in report['profiles'])
        assert all(sha(ROOT/c['image'])==c['image_sha256'] for c in report['checks'] if 'image' in c)
        assert all(sha(out/(c['name']+'.'+stream+'.txt'))==c[stream+'_sha256'] for c in report['preparations']+report['checks'] if c.get('process_evidence_saved') for stream in ('stdout','stderr'))
    save()
    try:
        shutil.copyfile(PLAN,out/'plan.json');shutil.copyfile(GATE,out/'gate.json')
        for name in SOURCES:
            original=(ROOT/name).resolve()
            target=out/'executed_inputs'/original.relative_to(REPO)
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(original,target)
            report['source_sha256'][name]=sha(target)
            report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
        report['archive_complete']=True;save()
        env=dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''),PYTHONDONTWRITEBYTECODE='1')
        for spec in commands(stamp):
            invariant();report['active_child']=spec['name']
            if spec['kind']=='PREPARATION':
                report['numerical_preparation_attempts']+=1
            save()
            image_digest=sha(Path(spec['argv'][1])) if Path(spec['argv'][0]).stem.lower()=='vvp' else None
            rec=child(spec,env,out,report,save)
            if image_digest:
                rec['execution_image_sha256']=image_digest
            save()
            if rec['status']=='PASS' and spec['kind']=='PREPARATION':
                report['numerical_preparation_calls']+=1;save()
                label_name=spec['name'][len('prepare_'):]
                vector=out/(label_name+'.txt');summary=vector.with_suffix('.summary.json')
                data=json.loads(summary.read_bytes())
                profile=next(p for p in plan['profiles'] if p['label']==label_name)
                assert data['parameters']==profile['parameters'] and data['vector_sha256']==sha(vector)
                assert data['model_sha256']==plan['executable_sources']['reference_model.py'] and data['historical_imports']==0
                report['profiles'].append(dict(label=label_name,**data,vector=vector.name,summary=summary.name,summary_sha256=sha(summary)))
            elif rec['status']=='PASS' and spec['name'].startswith('sim_'):
                line=next(line for line in (out/(spec['name']+'.stdout.txt')).read_text().splitlines() if line.startswith(spec['marker']))
                rec['observed']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
                profile=next(p for p in report['profiles'] if spec['name']=='sim_'+p['label'])
                if not all(rec['observed'].get(k)==v for k,v in profile['expected_runtime'].items()) or rec['observed'].get('resets')!=4 or rec['observed'].get('preoffers')!=24:
                    rec.update(status='FAIL_COVERAGE',expected_runtime=profile['expected_runtime'])
            save();print(spec['name'],rec['status'],flush=True)
            if rec['status']!='PASS':
                report['status']=rec['status'];break
        else:
            report['status']='PASS'
    except Exception:
        report.update(status='RUNNER_FAILED',exception=traceback.format_exc())
        raise
    finally:
        try:
            invariant();unchanged=True
        except Exception:
            unchanged=False
        sequence=[c['name'] for c in report['preparations']+report['checks']]==[c['name'] for c in commands(stamp)]
        ok=report['status']=='PASS' and sequence and unchanged and report['archive_complete']
        if report['status']=='PASS' and not ok:
            report['status']='INPUT_CHANGED_OR_INCOMPLETE'
        report.update(inputs_unchanged=unchanged,check_sequence_matches=sequence,suite_complete=ok,
            maturity=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if ok else ['RTL_CANDIDATE','HW_UNVERIFIED'])
        save();print(out.relative_to(ROOT).as_posix(),flush=True)
    return 0 if report['suite_complete'] else 1

if __name__=='__main__':
    if sys.argv[1:]==['--freeze-plan']:
        freeze()
    elif sys.argv[1:]==['--execute-approved-plan']:
        raise SystemExit(run())
    else:
        raise SystemExit('Use --freeze-plan or independently reviewed --execute-approved-plan')
