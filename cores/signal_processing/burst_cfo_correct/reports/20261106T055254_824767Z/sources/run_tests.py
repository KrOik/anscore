"""SPDX-License-Identifier: Apache-2.0. B39 explicit-approval finite evidence runner."""
from pathlib import Path
import datetime, hashlib, json, os, re, signal, subprocess, sys, time, traceback

ROOT = Path(__file__).resolve().parent
BIN = ROOT.parents[2] / 'tools/oss-cad-suite/oss-cad-suite/bin'
SOURCES = ['.gitattributes', 'PRECHECK_PLAN.json', 'run_tests.py', 'reference_model.py',
           'README.md', 'SOURCES.md', 'ERROR_BOUND.md', 'LICENSE', 'files.f', 'example/files.f',
           'rtl/burst_cfo_correct.sv', 'example/burst64_cfo.sv', 'sim/tb_burst_cfo_correct.sv',
           '../repeated_half_sync/example/sync12_phase.sv',
           '../repeated_half_sync/rtl/repeated_half_sync.sv',
           '../dsp_isp_library/infra/fixedpoint/rtl/cplx_mac.sv',
           '../../acceleration/stream_atan2/rtl/stream_atan2.sv',
           '../../acceleration/stream_sincos/rtl/stream_sincos.sv',
           '../../acceleration/stream_sincos/rtl/.gitattributes',
           '../../system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(name, argv, cwd, env, report, marker=None):
    begin = time.monotonic()
    out = err = b''
    record = dict(name=name, argv=list(map(str, argv)), cwd=str(cwd), cleanup=[])
    options = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {'start_new_session': True}
    try:
        child = subprocess.Popen(record['argv'], cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options)
    except OSError as exc:
        record.update(status='NOT_RUN', error=repr(exc))
    else:
        try:
            out, err = child.communicate(timeout=20)
            record.update(status='PASS' if child.returncode == 0 else 'FAIL', returncode=child.returncode)
        except subprocess.TimeoutExpired as exc:
            record.update(status='TIMEOUT')
            out, err = exc.stdout or b'', exc.stderr or b''
            if os.name == 'nt':
                kill = [str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/taskkill.exe'), '/PID', str(child.pid), '/T', '/F']
                try:
                    killed = subprocess.run(kill, capture_output=True, timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
                    record['cleanup'].append(dict(argv=kill, returncode=killed.returncode,
                        stdout=killed.stdout.decode(errors='replace'), stderr=killed.stderr.decode(errors='replace')))
                except (OSError, subprocess.TimeoutExpired) as exc:
                    record['cleanup'].append(dict(error=repr(exc)))
            else:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except OSError as exc:
                    record['cleanup'].append(dict(error=repr(exc)))
            try:
                if child.poll() is None:
                    child.kill()
                out, err = child.communicate(timeout=2)
            except (OSError, subprocess.TimeoutExpired) as exc:
                record['cleanup'].append(dict(drain_error=repr(exc)))
            record['returncode'] = child.poll()
    if record['status'] == 'PASS' and marker is not None and not any(line.startswith(marker) for line in out.splitlines()):
        record.update(status='FAIL_NO_PASS_MARKER', required_marker=marker.decode())
    (report / (name + '.stdout.txt')).write_bytes(out)
    (report / (name + '.stderr.txt')).write_bytes(err)
    record.update(seconds=round(time.monotonic()-begin,4), timeout_seconds=20, cleanup_budget_seconds=7,
        stdout_sha256=hashlib.sha256(out).hexdigest(), stderr_sha256=hashlib.sha256(err).hexdigest())
    return record


def main():
    if sys.argv[1:] != ['--execute-approved-plan']:
        raise SystemExit('Root source/plan review and --execute-approved-plan required')
    report_root = ROOT / 'reports'
    if report_root.exists() and any(report_root.iterdir()):
        raise SystemExit('Existing report entry: explicit root recovery required; no automatic rerun')
    plan = json.loads((ROOT / 'PRECHECK_PLAN.json').read_text())
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    report = report_root / stamp
    report.mkdir(parents=True,exist_ok=False)
    build = ROOT / '.build' / stamp
    build.mkdir(parents=True,exist_ok=False)
    result = dict(schema='anscore-b39-burst-cfo-correct-finite-v1',utc=stamp,status='INCOMPLETE',
        baseline=plan['baseline'],source_sha256={p:sha(ROOT/p) for p in SOURCES},checks=[],profiles=[],
        preparation_attempts=0,preparation_completed_calls=0,preparation_complete=False,
        archive_complete=False,suite_complete=False,automatic_retry=False,expected_checks=plan['expected_checks'],
        phase='SOURCE_ARCHIVE',active_child=None,hardware='HW_UNVERIFIED',synthesis='NOT_RUN',
        pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',rerun_guard='refuse_any_existing_report_entry')

    def persist():
        temporary=report/'results.json.tmp'
        with temporary.open('w',encoding='utf-8',newline='\n') as handle:
            json.dump(result,handle,indent=2)
            handle.write('\n');handle.flush();os.fsync(handle.fileno())
        temporary.replace(report/'results.json')

    persist()
    stopped=False

    def run(name,argv,marker=None):
        nonlocal stopped
        result.update(phase='HDL_CHILD',active_child=name);persist()
        record=execute(name,argv,ROOT,env,report,marker)
        result['checks'].append(record);result['active_child']=None
        stopped=record['status']!='PASS'
        if stopped:result['status']=record['status']
        persist();print(name,record['status'],flush=True)
        return not stopped

    try:
        for p in SOURCES:
            target=report/'sources'/p.replace('../','parent/')
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes((ROOT/p).read_bytes())
        result['archive_complete']=True;persist()
        sys.dont_write_bytecode=True
        from reference_model import prepare
        for index,profile in enumerate(plan['profiles']):
            result['preparation_attempts']+=1
            result.update(phase='NUMERICAL_PREPARATION',active_preparation=index);persist()
            vectors,counts=prepare(profile)
            vector=report/('vectors%d.txt'%index)
            vector.write_text(vectors,encoding='ascii',newline='\n')
            result['profiles'].append(dict(profile,vectors_sha256=sha(vector),expected_vector_counts=counts))
            result['preparation_completed_calls']+=1;result['active_preparation']=None;persist()
        result['preparation_complete']=True;persist()
        iv,vvp=BIN/'iverilog.exe',BIN/'vvp.exe'
        result['tools']={str(p):sha(p) for p in [iv,vvp] if p.is_file()}
        env=dict(os.environ)
        env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
        if not run('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','burst_cfo_correct','-f','files.f']):return 1
        if not run('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','burst64_cfo','-f','example/files.f']):return 1
        for index,profile in enumerate(result['profiles']):
            image=build/('sim%d.vvp'%index)
            params=['-Ptb_burst_cfo_correct.%s=%d'%(k,v) for k,v in
                    zip(('M','T','EX'),(profile['max_samples'],profile['tag_w'],profile['example']))]
            if not run('compile%d'%index,[iv,'-g2012','-Wall','-s','tb_burst_cfo_correct',*params,
                '-o',image,'-f','example/files.f','sim/tb_burst_cfo_correct.sv']):return 1
            profile['artifact']=dict(path=image.relative_to(ROOT).as_posix(),sha256=sha(image),bytes=image.stat().st_size);persist()
            marker=('PASS burst_cfo_correct M=%d T=%d EX=%d '%
                    (profile['max_samples'],profile['tag_w'],profile['example'])).encode()
            if not run('sim%d'%index,[vvp,image,'+vectors='+(report/('vectors%d.txt'%index)).as_posix()],marker):return 1
            line=next(line for line in (report/('sim%d.stdout.txt'%index)).read_text().splitlines() if line.startswith(marker.decode()))
            profile['observed']={key:int(value) for key,value in re.findall(r'(\w+)=(\d+)',line)}
            counts=profile['expected_vector_counts']
            expected=dict(M=profile['max_samples'],T=profile['tag_w'],EX=profile['example'],
                records=counts['records']+385,commands=counts['commands']+24,
                samples=counts['samples']+705,resets=12,faults=1,error_markers=counts['error_markers']+1,
                phase_checks=counts['records']-counts['error_markers']+384,
                coefficient_checks=counts['records']-counts['error_markers']+384,
                exact_checks=counts['records']-counts['error_markers']+384)
            profile['expected_observed']=expected
            if any(profile['observed'].get(k)!=v for k,v in expected.items()):
                result['checks'][-1]['status']='FAIL_COVERAGE'
                stopped=True;result['status']='FAIL_COVERAGE';persist();return 1
            persist()
        result.update(suite_complete=True,status='PASS')
        return 0
    except Exception:
        result.update(status='PREPARATION_OR_RUNNER_FAILED',exception=traceback.format_exc())
        raise
    finally:
        unchanged=all(sha(ROOT/p)==digest for p,digest in result['source_sha256'].items())
        archived=result['archive_complete'] and all(sha(report/'sources'/p.replace('../','parent/'))==digest
                    for p,digest in result['source_sha256'].items())
        vectors=all(sha(report/('vectors%d.txt'%i))==p['vectors_sha256'] for i,p in enumerate(result['profiles']))
        final_expected=json.loads((ROOT/'PRECHECK_PLAN.json').read_text())['expected_checks']
        archived_expected=json.loads((report/'sources/PRECHECK_PLAN.json').read_text())['expected_checks'] if archived else []
        sequence=[check['name'] for check in result['checks']]==final_expected==archived_expected==plan['expected_checks']
        result.update(sources_unchanged=unchanged,archive_unchanged=archived,vectors_unchanged=vectors,
            expected_checks_from_final_plan=final_expected,expected_checks_from_archived_plan=archived_expected,check_sequence_matches=sequence)
        if not(unchanged and archived and vectors):result['status']='SOURCE_CHANGED'
        elif stopped:result['status']=result['checks'][-1]['status']
        if result['status']=='PASS' and not(result['suite_complete'] and result['preparation_complete'] and sequence):result['status']='INCOMPLETE'
        result['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if result['status']=='PASS' else ['RTL_CANDIDATE','HW_UNVERIFIED']
        result['phase']='COMPLETE' if result['status']=='PASS' else 'STOPPED'
        persist();print('Evidence:',report.relative_to(ROOT),flush=True)
        if not(unchanged and archived and vectors):raise RuntimeError('Executed input changed')


if __name__=='__main__':
    sys.exit(main())
