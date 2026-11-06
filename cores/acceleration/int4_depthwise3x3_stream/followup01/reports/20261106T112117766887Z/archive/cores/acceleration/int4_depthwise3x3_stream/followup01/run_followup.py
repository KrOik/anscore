"""Independent bounded EOF-check followup. No model/preparation/old runner imports."""
from pathlib import Path
import datetime, hashlib, json, os, re, shutil, subprocess, sys, time
HERE=Path(__file__).resolve().parent
ROOT=HERE.parent
REPO=ROOT.parents[2]
PLAN=HERE/'PLAN.json'
GATE=HERE/'SOURCE_REVIEW.json'
GUARD=REPO/'.git/anscore-b44-depthwise-followup01-once.json'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path):return json.loads(path.read_bytes())
def save(path,data):
    with path.open('w',encoding='utf-8',newline='\n') as handle:
        json.dump(data,handle,indent=2);handle.write('\n');handle.flush();os.fsync(handle.fileno())

def main():
    plan,gate=read(PLAN),read(GATE)
    assert gate['plan_sha256']==sha(PLAN) and gate['root']=='NO_BLOCKER' and gate['peer']=='NO_BLOCKER_A'
    assert gate['execution_gate']=='B44_DEPTHWISE_FOLLOWUP01_ONCE'
    assert plan['numerical_preparations']==0 and len(plan['checks'])==10 and plan['automatic_retry'] is False
    for name,digest in plan['sources'].items():assert sha(ROOT/name)==digest, name
    for name,digest in plan['tools'].items():assert sha(Path(name))==digest, name
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    with GUARD.open('x',encoding='utf-8') as guard:
        json.dump(dict(plan_sha256=sha(PLAN),gate_sha256=sha(GATE),stamp=stamp),guard,indent=2)
        guard.flush();os.fsync(guard.fileno())
    out=HERE/'reports'/stamp
    out.mkdir(parents=True,exist_ok=False)
    (ROOT/'.work'/('followup01_'+stamp)).mkdir(parents=True,exist_ok=False)
    report=dict(schema='anscore-b44-depthwise-followup01-v1',status='INCOMPLETE',checks=[],
        plan_sha256=sha(PLAN),gate_sha256=sha(GATE),sources=plan['sources'],tools=plan['tools'],
        archived_sources={},active_child=None,automatic_retry=False,numerical_preparations=0,suite_complete=False)
    def record():save(out/'results.json',report)
    def invariant():
        assert sha(PLAN)==report['plan_sha256']==sha(out/'plan.json')
        assert sha(GATE)==report['gate_sha256']==sha(out/'gate.json')
        for name,digest in report['sources'].items():assert sha(ROOT/name)==digest==sha(ROOT/report['archived_sources'][name])
        for name,digest in report['tools'].items():assert sha(Path(name))==digest
        for item in report['checks']:
            if 'image_sha256' in item:assert sha(ROOT/item['image'])==item['image_sha256']
            if item.get('process_evidence_saved'):
                for stream in ('stdout','stderr'):assert sha(out/(item['name']+'.'+stream+'.raw'))==item[stream+'_sha256']
    record()
    try:
        shutil.copyfile(PLAN,out/'plan.json');shutil.copyfile(GATE,out/'gate.json')
        for name in plan['sources']:
            source=(ROOT/name).resolve();target=out/'archive'/source.relative_to(REPO)
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
            report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
        record()
        env=dict(os.environ,PATH=os.pathsep.join(plan['path_prefix']+[os.environ.get('PATH','')]),PYTHONDONTWRITEBYTECODE='1')
        for spec in plan['checks']:
            invariant()
            argv=[value.replace('<stamp>',stamp) for value in spec['argv']]
            rec=dict(spec,argv=argv,status='STARTING',cleanup=[],returncode=None)
            report['checks'].append(rec);report['active_child']=spec['name'];record()
            started=time.monotonic();proc=None
            with (out/(spec['name']+'.stdout.raw')).open('xb') as stdout, (out/(spec['name']+'.stderr.raw')).open('xb') as stderr:
                try:
                    proc=subprocess.Popen(argv,cwd=ROOT,env=env,stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,creationflags=subprocess.CREATE_NO_WINDOW)
                    rec.update(pid=proc.pid,status='RUNNING');record()
                    try:
                        proc.wait(timeout=max(0,20-(time.monotonic()-started)))
                        rec['status']='PASS' if proc.returncode==0 else 'FAIL'
                    except subprocess.TimeoutExpired:rec['status']='TIMEOUT'
                except Exception as exc:rec.update(status='HARNESS_FAILURE',exception=repr(exc))
                finally:
                    if proc is not None and proc.poll() is None:
                        cleanup=dict(target_pid=proc.pid,status='STARTED');rec['cleanup'].append(cleanup)
                        kill_started=time.monotonic();helper=None
                        try:
                            record()
                        except Exception as exc:cleanup['record_exception']=repr(exc)
                        try:
                            with (out/(spec['name']+'.cleanup.stdout.raw')).open('xb') as ko, (out/(spec['name']+'.cleanup.stderr.raw')).open('xb') as ke:
                                helper=subprocess.Popen([plan['taskkill'],'/PID',str(proc.pid),'/T','/F'],stdin=subprocess.DEVNULL,stdout=ko,stderr=ke,creationflags=subprocess.CREATE_NO_WINDOW)
                                cleanup['helper_pid']=helper.pid
                                try:record()
                                except Exception as exc:cleanup['helper_record_exception']=repr(exc)
                                try:helper.wait(timeout=max(0,5-(time.monotonic()-kill_started)))
                                except subprocess.TimeoutExpired:cleanup['helper_timeout']=True;helper.kill()
                                ko.flush();ke.flush();os.fsync(ko.fileno());os.fsync(ke.fileno())
                        except Exception as exc:cleanup['helper_exception']=repr(exc)
                        if helper is not None:
                            cleanup['helper_returncode']=helper.poll()
                            cleanup['active_helper']=helper.pid if helper.poll() is None else None
                        if proc.poll() is None:
                            try:proc.kill()
                            except OSError as exc:cleanup['fallback_kill_exception']=repr(exc)
                        try:proc.wait(timeout=2)
                        except subprocess.TimeoutExpired:cleanup['target_survived']=True
                    stdout.flush();stderr.flush();os.fsync(stdout.fileno());os.fsync(stderr.fileno())
            rec.update(returncode=None if proc is None else proc.poll(),seconds=round(time.monotonic()-started,6))
            rec['process_exited']=proc is not None and rec['returncode'] is not None
            rec['output_capture_complete']=rec['process_exited']
            report['active_child']=None if proc is None or rec['process_exited'] else dict(name=spec['name'],pid=proc.pid)
            for stream in ('stdout','stderr'):rec[stream+'_sha256']=sha(out/(spec['name']+'.'+stream+'.raw'))
            rec['process_evidence_saved']=True;record()
            if '-o' in argv:
                image=Path(argv[argv.index('-o')+1])
                if image.is_file():rec.update(image=image.relative_to(ROOT).as_posix(),image_sha256=sha(image))
            elif Path(argv[0]).stem.lower()=='vvp':rec['executed_image_sha256']=sha(Path(argv[1]))
            if rec['status']=='PASS' and spec['marker']:
                raw=(out/(spec['name']+'.stdout.raw')).read_bytes()
                lines=[line for line in raw.splitlines() if line.startswith(spec['marker'].encode())]
                if len(lines)!=1 or b'$finish' not in raw:rec['status']='FAIL_MARKER'
                else:
                    rec['observed']={key.decode():int(value) for key,value in re.findall(rb'(\w+)=(\d+)',lines[0])}
                    if not all(rec['observed'].get(k)==v for k,v in spec['expected_runtime'].items()):rec['status']='FAIL_COVERAGE'
            record();print(spec['name'],rec['status'],flush=True)
            if rec['status']!='PASS':report['status']='FAIL_STOP';break
        else:report['status']='PASS'
        invariant()
        report['suite_complete']=report['status']=='PASS' and len(report['checks'])==10
    except Exception as exc:
        report.update(status='HARNESS_FAILURE',exception=repr(exc));raise
    finally:
        record();print(out.relative_to(ROOT).as_posix(),flush=True)
    return 0 if report['suite_complete'] else 1

if __name__=='__main__':
    if sys.argv[1:]!=['--execute']:raise SystemExit('Explicit reviewed --execute only')
    raise SystemExit(main())
