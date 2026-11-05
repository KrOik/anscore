"""Freeze, then execute exactly the authorized 24-child matrix once."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
SEAL = ROOT/'SOURCE_SEAL.json'
RECEIPT = ROOT/'verification.json'


def digest(raw):
    return sha256(raw).hexdigest()


def read(name):
    return json.loads((ROOT/name).read_bytes())


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n', encoding='utf-8', newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix():digest(p.read_bytes())
            for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.relative_to(ROOT).parts[0] not in ('artifacts','reports','__pycache__')
            and p.name not in ('SOURCE_SEAL.json','verification.json')}


def preparation_check():
    plan, audit = read('TEST_PLAN.json'), read('fixture_audit.json')
    assert audit['status'] == 'PASS' and audit['child_processes'] == 0
    assert audit['plan_sha256'] == digest((ROOT/'TEST_PLAN.json').read_bytes())
    assert audit['preparation_sha256'] == digest((ROOT/'prepare.py').read_bytes())
    assert audit['oracle_sha256'] == digest((ROOT/'oracle.py').read_bytes())
    assert len(plan['commands']) == plan['hdl_children'] == 24
    for item in audit['jobs']:
        for kind in ('json','text'):
            assert digest((ROOT/item[kind]).read_bytes()) == item[kind+'_sha256']
    return plan, audit


def expanded_commands(plan, audit):
    profiles = {p['name']:p for p in plan['profiles']}
    fixtures = {j['name']:j for j in audit['jobs']}
    result = []
    for command in plan['commands']:
        item = command.copy()
        fields = dict(command, ARTIFACT='{ARTIFACT}')
        if 'profile' in command:
            fields.update(profiles[command['profile']])
            fields['profile'] = command['profile']
            fields['name'] = command['name']
        if command['kind'] == 'simulate':
            fields['cycle_bound'] = fixtures[command['name']]['cycle_bound']
        item['argv'] = [arg.format(**fields) for arg in plan['argv_rules'][command['kind']]]
        if command['name'] == 'default_compile':
            item['argv'] += plan['argv_rules']['default_compile_append']
        item['timeout_seconds'] = 20
        result.append(item)
    return result


def freeze():
    assert not RECEIPT.exists(), 'execution receipt is terminal'
    if SEAL.exists():
        history = ROOT/'history/prehdl_02'
        index = json.loads((history/'index.json').read_bytes())
        assert index['status'] == 'NO_HDL' and index['compiler_simulator_invocations'] == 0
        assert not (ROOT/'artifacts').exists() and not (ROOT/'reports').exists()
        assert SEAL.read_bytes() == (history/'prehdl_source_seal.json').read_bytes(), 'only named pre-HDL seal may be superseded'
        for name, expected in index['files_sha256'].items():
            assert digest((history/name).read_bytes()) == expected
    plan, audit = preparation_check()
    mapping = sources()
    # Preserve the preparation child's raw Windows stdout/stderr bytes. Only
    # authored text and generated fixtures require LF; logs are sealed verbatim.
    assert all(b'\r' not in (ROOT/name).read_bytes() and not (ROOT/name).read_bytes().startswith(b'\xef\xbb\xbf')
               for name in mapping if name not in ('preparation.stdout','preparation.stderr'))
    binary = REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
    tools = {name:dict(path=str(binary/(name+'.exe')), sha256=digest((binary/(name+'.exe')).read_bytes())) for name in ('iverilog','vvp')}
    write(SEAL, dict(schema=1, baseline=plan['baseline'], files_sha256=mapping,
          files_map_sha256=digest(json.dumps(mapping,sort_keys=True,separators=(',',':')).encode()),
          test_plan_sha256=digest((ROOT/'TEST_PLAN.json').read_bytes()),
          fixture_audit_sha256=digest((ROOT/'fixture_audit.json').read_bytes()), tools=tools,
          commands=expanded_commands(plan,audit), compiler_simulator_calls_before_seal=0))
    print(json.dumps(dict(status='SEALED', files=len(mapping), sha256=digest(SEAL.read_bytes()))))


def check_simulation(command, stdout):
    fixture = read('fixtures/'+command['name']+'.json')
    lines = stdout.decode('utf-8').splitlines()
    actual_c = [[int(v,16) for v in line.split()[1:]] for line in lines if line.startswith('C ')]
    actual_o = [[int(v,16) for v in line.split()[1:]] for line in lines if line.startswith('O ')]
    assert actual_c == fixture['expected_commands'], 'exact command/snapshot transcript'
    assert actual_o == fixture['expected_outputs'], 'exact independent DRR/FIFO transcript'
    summaries = [line for line in lines if line.startswith('PASS ')]
    assert len(summaries) == 1
    summary = {k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',summaries[0])}
    assert summary['commands'] == len(actual_c)
    assert summary['outputs'] == len(actual_o)
    assert summary['resets'] == fixture['resets']
    assert summary['selections'] == fixture['selections']
    assert summary['held_output'] == 3*fixture['selections']
    assert summary['held_response'] == 3*len(actual_c)
    assert summary['cycles'] <= fixture['cycle_bound']
    assert summary['same_edge'] == (0 if command['case'] == 'fairness' else 1+int(fixture['profile']['N'] > 1))
    return summary


def timeout_cleanup(child, record, index, command, partial_out, partial_err):
    """Terminal cleanup only; never launches a compiler/simulator or retries it."""
    cleanup = dict(returncode=None, exception=None)
    killed_out=killed_err=b''
    start=time.monotonic()
    if os.name == 'nt':
        killer=Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'
        argv=[str(killer),'/PID',str(child.pid),'/T','/F']
        cleanup.update(argv=argv, explicit_executable=str(killer), mechanism='Windows taskkill tree')
        try:
            result=subprocess.run(argv, executable=str(killer), capture_output=True,
                                  timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
            cleanup['returncode']=result.returncode
            killed_out,killed_err=result.stdout,result.stderr
        except subprocess.TimeoutExpired as error:
            killed_out=error.stdout or b''; killed_err=error.stderr or b''
            cleanup['exception']='TimeoutExpired: tree cleanup exceeded 5 seconds'
        except Exception as error:
            cleanup['exception']=type(error).__name__+': '+str(error)
    else:
        cleanup.update(argv=['os.killpg',str(child.pid),'SIGKILL'],
                       explicit_executable=None, mechanism='independent POSIX session/process group')
        try:
            os.killpg(child.pid,signal.SIGKILL)
            cleanup['returncode']=0
        except Exception as error:
            cleanup['exception']=type(error).__name__+': '+str(error)
    cleanup['elapsed_seconds']=time.monotonic()-start
    for suffix,raw in (('stdout',killed_out),('stderr',killed_err)):
        path='reports/%02d_%s.tree_kill.%s'%(index,command['name'],suffix)
        (ROOT/path).write_bytes(raw)
        cleanup[suffix]=path; cleanup[suffix+'_sha256']=digest(raw)
    # A broken/missing/timed-out tree killer must not bypass direct kill/drain.
    fallback=dict(pid=child.pid, attempted=False, exception=None)
    try:
        if child.poll() is None:
            fallback['attempted']=True
            child.kill()
        fallback['returncode_after_kill']=child.poll()
    except Exception as error:
        fallback['exception']=type(error).__name__+': '+str(error)
    cleanup['direct_child_kill']=fallback
    out,err=partial_out,partial_err
    try:
        out,err=child.communicate(timeout=5)
        cleanup['drain']='COMPLETE'
    except subprocess.TimeoutExpired as error:
        out=error.stdout or out; err=error.stderr or err
        cleanup['drain']='TIMEOUT'; cleanup['drain_error']='TimeoutExpired: terminal drain exceeded 5 seconds'
    except Exception as error:
        cleanup['drain']='ERROR'; cleanup['drain_error']=type(error).__name__+': '+str(error)
    cleanup['final_child_returncode']=child.poll()
    record['tree_cleanup']=cleanup
    return out,err


def execute():
    assert not RECEIPT.exists(), 'one attempt only; prior receipt is terminal'
    plan, audit = preparation_check()
    seal = read('SOURCE_SEAL.json')
    assert sources() == seal['files_sha256']
    assert digest((ROOT/'TEST_PLAN.json').read_bytes()) == seal['test_plan_sha256']
    assert digest((ROOT/'fixture_audit.json').read_bytes()) == seal['fixture_audit_sha256']
    assert expanded_commands(plan,audit) == seal['commands']
    for item in seal['tools'].values():
        assert digest(Path(item['path']).read_bytes()) == item['sha256']
    for name in ('artifacts','reports'):
        assert not (ROOT/name).exists(), 'prior outputs are terminal'
        (ROOT/name).mkdir()
    env = os.environ.copy()
    suite = REPO/'tools/oss-cad-suite/oss-cad-suite'
    env['PATH'] = os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    receipt = dict(schema=1, baseline=plan['baseline'], status='RUNNING',
         source_seal_sha256=digest(SEAL.read_bytes()), test_plan_sha256=digest((ROOT/'TEST_PLAN.json').read_bytes()),
         records=[dict(command=c,status='NOT_RUN') for c in seal['commands']],
         first_failure_terminal=True, automatic_retry=False,
         maturity=['RTL_CANDIDATE','HW_UNVERIFIED'], excluded_checks=plan['excluded_checks'])
    write(RECEIPT,receipt)
    for index, record in enumerate(receipt['records']):
        command = record['command']
        argv = [arg.replace('{ARTIFACT}',str((ROOT/'artifacts').resolve())) for arg in command['argv']]
        argv[0] = seal['tools'][argv[0]]['path']
        record['executed_argv'] = argv
        start = time.monotonic(); out=err=b''; timed_out=False
        try:
            kwargs=dict(cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            if os.name == 'nt':
                kwargs['creationflags']=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
                record['spawn']=dict(create_new_process_group=True, create_no_window=True)
            else:
                kwargs['start_new_session']=True
                record['spawn']=dict(start_new_session=True)
            child=subprocess.Popen(argv,**kwargs)
            try:
                out,err=child.communicate(timeout=20)
            except subprocess.TimeoutExpired as error:
                timed_out=True
                out,err=timeout_cleanup(child,record,index,command,error.stdout or b'',error.stderr or b'')
            record['returncode']=child.returncode
        except Exception as error:
            record['runner_error']=type(error).__name__+': '+str(error)
            record['returncode']=None
        record.update(elapsed_seconds=time.monotonic()-start,timeout=timed_out)
        for suffix,raw in (('stdout',out),('stderr',err)):
            path='reports/%02d_%s.%s'%(index,command['name'],suffix)
            (ROOT/path).write_bytes(raw)
            record[suffix]=path; record[suffix+'_sha256']=digest(raw)
        if timed_out:
            record['status']='TIMEOUT'
        elif 'runner_error' in record:
            record['status']='FAIL'
        elif command['expected'] == 'EXPECTED_REJECT':
            marker=b'descriptor_drr_scheduler_invalid_parameters__see_README'
            record['status']='EXPECTED_REJECT' if child.returncode != 0 and marker in out+err else 'FAIL'
        elif child.returncode != 0:
            record['status']='FAIL'
        else:
            record['status']='PASS'
            try:
                if command['kind'] == 'simulate': record['summary']=check_simulation(command,out)
            except Exception as error:
                record['status']='FAIL'; record['validation_error']=type(error).__name__+': '+str(error)
        write(RECEIPT,receipt)
        print(command['name']+' '+record['status'],flush=True)
        if record['status'] not in ('PASS','EXPECTED_REJECT'):
            receipt['status']=record['status']; write(RECEIPT,receipt); return 1
    receipt['status']='PASS'
    receipt['maturity']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED']
    receipt['totals']=dict(children=24, passed=12, expected_reject=12,
           simulations=7, commands=sum(r.get('summary',{}).get('commands',0) for r in receipt['records']),
           outputs=sum(r.get('summary',{}).get('outputs',0) for r in receipt['records']),
           resets=sum(r.get('summary',{}).get('resets',0) for r in receipt['records']),
           max_child_seconds=max(r['elapsed_seconds'] for r in receipt['records']))
    assert sources() == seal['files_sha256'], 'sealed source changed during run'
    write(RECEIPT,receipt)
    print(json.dumps(receipt['totals']))
    return 0


def audit_only():
    plan,audit=preparation_check()
    seal=read('SOURCE_SEAL.json'); receipt=read('verification.json')
    assert sources() == seal['files_sha256']
    assert receipt['source_seal_sha256'] == digest(SEAL.read_bytes())
    assert receipt['test_plan_sha256'] == digest((ROOT/'TEST_PLAN.json').read_bytes())
    for record in receipt['records']:
        if record['status'] == 'NOT_RUN': continue
        for kind in ('stdout','stderr'):
            assert digest((ROOT/record[kind]).read_bytes()) == record[kind+'_sha256']
        if 'tree_cleanup' in record:
            for kind in ('stdout','stderr'):
                cleanup=record['tree_cleanup']
                assert digest((ROOT/cleanup[kind]).read_bytes()) == cleanup[kind+'_sha256']
        if record['status'] == 'PASS' and record['command']['kind'] == 'simulate':
            assert check_simulation(record['command'],(ROOT/record['stdout']).read_bytes()) == record['summary']
    print(json.dumps(dict(status='HASH_ONLY_AUDIT_PASS',receipt_status=receipt['status'],hdl_calls=0)))


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('mode',choices=('freeze','run','audit'))
    mode=parser.parse_args().mode
    if mode == 'freeze': freeze()
    elif mode == 'audit': audit_only()
    else: raise SystemExit(execute())
