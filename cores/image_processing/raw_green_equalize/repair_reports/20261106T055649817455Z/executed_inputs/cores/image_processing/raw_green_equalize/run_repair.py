"""SPDX-License-Identifier: Apache-2.0. Reviewed finite plan only; no retry/network/synthesis."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';IV=BIN/'iverilog.exe';VVP=BIN/'vvp.exe'
SOURCES=['run_repair.py','REPAIR_PLAN.json','run_tests.py','reference_model.py','PRECHECK_PLAN.json','rtl/raw_green_equalize.sv',
         'example/green_bayer_rgb.sv','sim/tb_raw_green_equalize.sv','sim/tb_green_bayer_rgb.sv',
         'files.f','example/files.f',
         '../../signal_processing/dsp_isp_library/infra/window/stream_window.v',
         '../../signal_processing/dsp_isp_library/infra/window/stream_window_padded.v',
         '../../signal_processing/dsp_isp_library/isp/bayer/rtl/bayer_demosaic.sv']
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def execute(name,argv,cwd,env,report,marker=None,expected_counters=None):
    argv=list(map(str,argv));start=time.monotonic();code=None;out=err=b'';cleanup=[];reason=None
    options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
    try:child=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:status='NOT_RUN';err=(repr(exc)+'\n').encode()
    else:
        try:
            out,err=child.communicate(timeout=20);code=child.returncode;status='PASS' if code==0 else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            status='TIMEOUT';out=exc.stdout or b'';err=exc.stderr or b''
            if os.name=='nt':
                kill=[str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F']
                try:
                    result=subprocess.run(kill,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill,returncode=result.returncode,stdout=result.stdout.decode(errors='replace'),stderr=result.stderr.decode(errors='replace')))
                except (OSError,subprocess.TimeoutExpired) as exc:cleanup.append(dict(action='tree_kill',error=repr(exc)))
            else:
                try:os.killpg(child.pid,signal.SIGKILL)
                except OSError as exc:cleanup.append(dict(action='group_kill',error=repr(exc)))
            try:
                if child.poll() is None:child.kill()
            except OSError as exc:cleanup.append(dict(action='parent_kill',error=repr(exc)))
            try:out,err=child.communicate(timeout=2)
            except subprocess.TimeoutExpired as exc:
                out=exc.stdout or out;err=exc.stderr or err;cleanup.append(dict(action='drain',error=repr(exc)))
            except OSError as exc:cleanup.append(dict(action='drain',error=repr(exc)))
            code=child.poll()
    counters=None
    if status=='PASS' and name.startswith('sim_'):
        lines=[line for line in out.splitlines() if marker is not None and line.startswith(marker)]
        if len(lines)!=1 or b'$finish' not in out:
            status='FAIL';reason='unique reviewed completion prefix or $finish absent'
        else:
            try:
                counters={k:int(v) for word in lines[0].decode('ascii').split() if '=' in word for k,v in [word.split('=',1)]}
                if any(counters.get(k)!=v for k,v in expected_counters.items()) or counters.get('holds',0)<=0:
                    status='FAIL';reason='simulation counters disagree with independent frozen-vector oracle'
            except (ValueError,UnicodeError):status='FAIL';reason='malformed simulation counters'
    (report/(name+'.stdout.txt')).write_bytes(out);(report/(name+'.stderr.txt')).write_bytes(err)
    return dict(name=name,argv=argv,cwd=str(cwd),status=status,returncode=code,reason=reason,
        marker=marker.decode() if marker else None,execution_deadline_seconds=20,cleanup_budget_seconds=7,
        cleanup=cleanup,counters=counters,seconds=round(time.monotonic()-start,3),stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())

def main():
    report_root=ROOT/'repair_reports'
    if report_root.exists() and any(p.is_dir() for p in report_root.iterdir()):
        print('Started repair report exists: preserve it; no retry.',file=sys.stderr);return 1
    plan=json.loads((ROOT/'REPAIR_PLAN.json').read_text())
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    report=report_root/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/'.build'/('repair_'+stamp);build.mkdir(parents=True,exist_ok=False)
    hashes={n:sha(ROOT/n) for n in SOURCES};copies={}
    for n in SOURCES:
        src=(ROOT/n).resolve();dst=report/'executed_inputs'/src.relative_to(REPO)
        dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(src.read_bytes())
        copies[n]=dst.relative_to(report).as_posix()
    prior_path=REPO/plan['prior_receipt'];prior=json.loads(prior_path.read_text())
    prior_copy=report/'prior_evidence'/'results.json'
    prior_copy.parent.mkdir();prior_copy.write_bytes(prior_path.read_bytes())
    expected=['compile_9x7_d10_t8','sim_9x7_d10_t8','compile_32x24_d12_t32','sim_32x24_d12_t32','compile_example','sim_example']
    records=[];complete=False;exception=None
    vectors=plan['prior_vectors_sha256'];raw=plan['prior_raw_streams_sha256'];archives=plan['prior_archives_sha256']
    tools_initial={str(p):sha(p) for p in [IV,VVP]}
    prior_evidence=dict(receipt=plan['prior_receipt'],receipt_sha256=plan['prior_receipt_sha256'],
        archived_receipt=prior_copy.relative_to(report).as_posix(),
        status='FAIL',child_attempts=7,passed_children=6,failed_children=1,
        successful_simulations=1,failed_simulations=1,records=prior['records'])
    env=os.environ.copy();env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    def intact():
        return (all(sha(ROOT/n)==h and sha(report/copies[n])==h for n,h in hashes.items()) and
            all(sha(REPO/n)==h for group in [vectors,raw,archives] for n,h in group.items()) and
            sha(prior_path)==plan['prior_receipt_sha256'] and sha(prior_copy)==plan['prior_receipt_sha256'] and
            {str(p):sha(p) for p in [IV,VVP]}==tools_initial)
    def save(status,event):
        result=dict(schema='anscore-b39-raw-green-repair-v1',status=status,event=event,
            source_sha256=hashes,exact_checked_copies=copies,prior_evidence=prior_evidence,
            prior_vectors_sha256=vectors,prior_raw_streams_sha256=raw,prior_archives_sha256=archives,
            expected_checks=expected,records=records,suite_complete=complete,
            oracle_imported=False,preparation_attempts=0,reused_prior_vector_files=20,
            automatic_retry=False,exception=exception,tools=tools_initial,
            all_current_prior_source_vector_raw_tool_hashes_intact=intact(),
            synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
        temp=report/'results.json.tmp'
        with temp.open('w',encoding='utf8',newline='\n') as stream:
            stream.write(json.dumps(result,indent=2)+'\n');stream.flush();os.fsync(stream.fileno())
        temp.replace(report/'results.json')
    save('INCOMPLETE','before_any_child_no_oracle')
    try:
        assert plan['expected_checks']==expected==[c['name'] for c in plan['checks']]
        assert set(plan['source_sha256'])==set(SOURCES)-{'REPAIR_PLAN.json'}
        assert all(hashes[n]==h for n,h in plan['source_sha256'].items())
        assert tools_initial==plan['tool_sha256']==prior['tools']
        assert prior['status']=='FAIL' and prior['suite_complete'] is False and prior['preparation_attempts']==1 and prior['preparation_complete']
        assert [r['name'] for r in prior['records']]==prior['expected_checks'][:7]
        assert [r['status'] for r in prior['records']]==['PASS']*6+['FAIL']
        assert prior['records'][-1]['name']=='sim_9x7_d10_t8' and prior['records'][-1]['returncode']==1
        actual_vectors={str((prior_path.parent/p['name']/n).relative_to(REPO)).replace('\\','/'):h for p in prior['profiles']+[prior['example']] for n,h in p['vectors_sha256'].items()}
        actual_raw={str((prior_path.parent/(r['name']+'.'+kind+'.txt')).relative_to(REPO)).replace('\\','/'):r[kind+'_sha256'] for r in prior['records'] for kind in ['stdout','stderr']}
        actual_archives={str((prior_path.parent/prior['exact_checked_copies'][n]).relative_to(REPO)).replace('\\','/'):h for n,h in prior['source_sha256'].items()}
        assert actual_vectors==vectors and len(vectors)==20 and actual_raw==raw and len(raw)==14 and actual_archives==archives and len(archives)==12
        changed={n for n,h in prior['source_sha256'].items() if sha(ROOT/n)!=h}
        assert changed=={'sim/tb_raw_green_equalize.sv'}
        assert plan['changed_prior_sources']=={n:dict(prior_sha256=prior['source_sha256'][n],current_sha256=hashes[n]) for n in changed}
        assert intact()
        for check in plan['checks']:
            assert intact()
            name=check['name'];argv=[arg.replace('<stamp>',stamp) for arg in check['argv']]
            cwd=Path(check['cwd']);marker=check['marker'].encode() if check['marker'] else None
            result=execute(name,argv,cwd,env,report,marker,check['expected_counters'])
            records.append(result);save('INCOMPLETE','after_'+name);print(name,result['status'],flush=True)
            if result['status']!='PASS':return 1
        complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/'exception.txt').write_text(exception,encoding='utf8');return 1
    finally:
        ok=complete and [r['name'] for r in records]==expected and all(r['status']=='PASS' for r in records)
        status='SOURCE_CHANGED' if not intact() else 'PASS' if ok else next((r['status'] for r in records if r['status']!='PASS'),'INCOMPLETE')
        save(status,'final');print('REPAIR_REPORT',report,'STATUS',status,flush=True)
        if status=='SOURCE_CHANGED':raise RuntimeError('Repair or prior frozen evidence changed')
if __name__=='__main__':sys.exit(main())
