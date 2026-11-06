"""SPDX-License-Identifier: Apache-2.0. Explicit one-repair plan; no oracle import/preparation."""
from pathlib import Path
import datetime,hashlib,json,os,re,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
OLD=ROOT/'reports/20261106T063315_715768Z'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(check,argv,cwd,env,report):
    begin=time.monotonic();out=err=b'';record=dict(name=check['name'],argv=argv,cwd=str(cwd),cleanup=[])
    options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
    try:child=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:record.update(status='NOT_RUN',error=repr(exc))
    else:
        try:
            out,err=child.communicate(timeout=20)
            record.update(status='PASS' if child.returncode==0 else 'FAIL',returncode=child.returncode)
        except subprocess.TimeoutExpired as exc:
            record.update(status='TIMEOUT');out,err=exc.stdout or b'',exc.stderr or b''
            if os.name=='nt':
                kill=[str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F']
                try:
                    killed=subprocess.run(kill,capture_output=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
                    record['cleanup'].append(dict(argv=kill,returncode=killed.returncode,stdout=killed.stdout.decode(errors='replace'),stderr=killed.stderr.decode(errors='replace')))
                except (OSError,subprocess.TimeoutExpired) as exc:record['cleanup'].append(dict(error=repr(exc)))
            else:
                try:os.killpg(child.pid,signal.SIGKILL)
                except OSError as exc:record['cleanup'].append(dict(error=repr(exc)))
            try:
                if child.poll() is None:child.kill()
                out,err=child.communicate(timeout=2)
            except (OSError,subprocess.TimeoutExpired) as exc:record['cleanup'].append(dict(drain_error=repr(exc)))
            record['returncode']=child.poll()
    marker=check.get('marker')
    if record['status']=='PASS' and marker:
        lines=[line for line in out.decode(errors='replace').splitlines() if line.startswith(marker)]
        if len(lines)!=1 or b'$finish' not in out:record.update(status='FAIL_COMPLETION')
        else:
            observed={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',lines[0])}
            record['observed']=observed
            if any(observed.get(k)!=v for k,v in check['expected_counters'].items()):record.update(status='FAIL_COVERAGE')
    for channel,data in [('stdout',out),('stderr',err)]:
        (report/(check['name']+'.'+channel+'.txt')).write_bytes(data)
        record[channel+'_sha256']=hashlib.sha256(data).hexdigest()
    record.update(seconds=round(time.monotonic()-begin,4),timeout_seconds=20,cleanup_budget_seconds=7,marker=marker)
    return record


def main():
    if sys.argv[1:]!=['--execute-approved-repair']:raise SystemExit('Explicit root repair review/authorization required')
    report_root=HERE/'reports'
    if report_root.exists() and any(report_root.iterdir()):raise SystemExit('Existing repair attempt; no automatic retry')
    plan=json.loads((HERE/'REPAIR_PLAN.json').read_text())
    seal=json.loads((HERE/'REPAIR_SEAL.json').read_text())
    sources=plan['sources']
    assert set(seal['sha256'])==set(sources)-{'repairs/repair01/REPAIR_SEAL.json'}
    assert all(sha(ROOT/p)==h for p,h in seal['sha256'].items())
    assert sha(OLD/'results.json')==plan['previous_receipt_sha256']
    old=json.loads((OLD/'results.json').read_text())
    assert old['status']=='FAIL' and [(c['name'],c['status']) for c in old['checks']]==[('syntax_default','PASS'),('syntax_example','FAIL')]
    assert old['preparation_attempts']==old['preparation_completed_calls']==4
    assert all(sha(OLD/'sources'/p.replace('../','parent/'))==h for p,h in old['source_sha256'].items())
    assert all(sha(ROOT/p)==h for p,h in old['source_sha256'].items() if p!='example/files.f')
    assert old['source_sha256']['example/files.f']==plan['example_files_previous_sha256']
    assert sha(ROOT/'example/files.f')==plan['example_files_current_sha256']
    vector_hashes={p:sha(ROOT/p) for p in plan['reused_vectors']}
    assert vector_hashes==plan['reused_vectors']
    tool_hashes={p:sha(Path(p)) for p in plan['tools']}
    assert tool_hashes==plan['tools']==old['tools']
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    report=report_root/stamp;report.mkdir(parents=True,exist_ok=False)
    build=HERE/'.build'/stamp;build.mkdir(parents=True,exist_ok=False)
    result=dict(schema='anscore-b40-pulse-fraction-timing-repair-v1',status='INCOMPLETE',utc=stamp,
        source_sha256={p:sha(ROOT/p) for p in sources},checks=[],artifacts=[],
        previous_receipt=plan['previous_receipt'],previous_receipt_sha256=plan['previous_receipt_sha256'],
        reused_vectors=vector_hashes,tools=tool_hashes,archive_complete=False,suite_complete=False,
        oracle_imports=0,preparation_attempts=0,preparation_completed_calls=0,automatic_retry=False,
        expected_checks=[c['name'] for c in plan['checks']],synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
    def persist():
        temporary=report/'results.json.tmp'
        with temporary.open('w',encoding='utf8',newline='\n') as stream:
            json.dump(result,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        temporary.replace(report/'results.json')
    persist()
    try:
        for p in sources:
            target=report/'sources'/p.replace('../','parent/')
            target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/p).read_bytes())
        result['archive_complete']=True;persist()
        env=dict(os.environ);env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
        for check in plan['checks']:
            assert all(sha(ROOT/p)==h for p,h in result['source_sha256'].items())
            assert all(sha(ROOT/p)==h for p,h in vector_hashes.items())
            assert sha(OLD/'results.json')==result['previous_receipt_sha256']
            argv=[arg.replace('<stamp>',stamp) for arg in check['argv']]
            result['active_child']=check['name'];persist()
            record=execute(check,argv,ROOT,env,report);result['checks'].append(record);result['active_child']=None
            if check.get('artifact'):
                artifact=Path(check['artifact'].replace('<stamp>',stamp))
                if artifact.is_file():result['artifacts'].append(dict(path=artifact.relative_to(ROOT).as_posix(),sha256=sha(artifact),bytes=artifact.stat().st_size))
            persist();print(check['name'],record['status'],flush=True)
            if record['status']!='PASS':result['status']=record['status'];return 1
        result.update(status='PASS',suite_complete=True);return 0
    except Exception:
        result.update(status='RUNNER_FAILED',exception=traceback.format_exc());raise
    finally:
        result['sources_unchanged']=all(sha(ROOT/p)==h for p,h in result['source_sha256'].items())
        result['archive_unchanged']=result['archive_complete'] and all(sha(report/'sources'/p.replace('../','parent/'))==h for p,h in result['source_sha256'].items())
        result['vectors_unchanged']=all(sha(ROOT/p)==h for p,h in vector_hashes.items())
        result['previous_receipt_unchanged']=sha(OLD/'results.json')==result['previous_receipt_sha256']
        result['tools_unchanged']=all(sha(Path(p))==h for p,h in tool_hashes.items())
        result['check_sequence_matches']=[c['name'] for c in result['checks']]==result['expected_checks']
        if not all(result[k] for k in ('sources_unchanged','archive_unchanged','vectors_unchanged','previous_receipt_unchanged','tools_unchanged')):result['status']='SOURCE_CHANGED'
        if result['status']=='PASS' and not(result['suite_complete'] and result['check_sequence_matches']):result['status']='INCOMPLETE'
        persist();print('Repair evidence:',report.relative_to(ROOT),flush=True)


if __name__=='__main__':sys.exit(main())
