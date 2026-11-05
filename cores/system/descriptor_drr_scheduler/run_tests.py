"""Freeze, then execute exactly the authorized 24-child matrix once."""
import argparse
from collections import Counter
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
REPAIR_SEAL = ROOT/'REPAIR_SEAL.json'
REPAIR_RECEIPT = ROOT/'verification_attempt02.json'
REPAIR_SEAL_ATTEMPT03 = ROOT/'REPAIR_SEAL_ATTEMPT03.json'
REPAIR_RECEIPT_ATTEMPT03 = ROOT/'verification_attempt03.json'


def digest(raw):
    return sha256(raw).hexdigest()


def read(name):
    return json.loads((ROOT/name).read_bytes())


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n', encoding='utf-8', newline='\n')


def sources(attempt02=False, attempt03=False):
    # Only root-relative qualification metadata is excluded. Archived seals and
    # receipts are evidence sources and must remain in the repaired source map.
    excluded = {'REPAIR_SEAL_ATTEMPT03.json','verification_attempt03.json'}
    if not attempt03:
        excluded |= {'REPAIR_SEAL.json','verification_attempt02.json'}
    if not attempt02 and not attempt03:
        excluded |= {'SOURCE_SEAL.json','verification.json'}
    return {p.relative_to(ROOT).as_posix():digest(p.read_bytes())
            for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.relative_to(ROOT).parts[0] not in ('artifacts','reports','__pycache__')
            and p.relative_to(ROOT).as_posix() not in excluded}


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


def timeout_cleanup(child, record, index, command, partial_out, partial_err, report_directory='reports'):
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
        path=report_directory+'/%02d_%s.tree_kill.%s'%(index,command['name'],suffix)
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


def original_failure_evidence():
    """Bind the terminal first attempt and its complete immutable byte archive."""
    assert digest(SEAL.read_bytes()) == '2c554eb9ba124956578c745452795306e88920b30c23e94240aa851890dc6fd3'
    assert digest(RECEIPT.read_bytes()) == 'c7111aae3c8686dfe9f6b513641d1441f23d6a4df664b05ac14692c2b62c9738'
    original = read('verification.json')
    assert original['status'] == 'FAIL'
    assert [r['status'] for r in original['records']] == ['PASS','PASS','PASS','FAIL']+['NOT_RUN']*20
    archive = ROOT/'failure_archive/attempt_01'
    manifest = archive/'ARCHIVE.json'
    assert digest(manifest.read_bytes()) == 'c7219c8273ce1eb771a684640b597bff4ceefd150a919d6c76bf595e66b002d8'
    evidence = json.loads(manifest.read_bytes())
    assert evidence['status'] == 'FAIL_STOPPED' and evidence['automatic_retry'] is False
    assert len(evidence['files']) == 52
    assert {p.relative_to(archive).as_posix() for p in archive.rglob('*') if p.is_file()} == set(evidence['files'])|{'ARCHIVE.json'}
    for name, item in evidence['files'].items():
        path = archive/name
        assert digest(path.read_bytes()) == item['sha256'] and path.stat().st_size == item['bytes']
    for name, value in evidence['original_files_sha256'].items():
        if name not in ('run_tests.py','sim/tb_descriptor_drr.sv','README.md'):
            assert digest((ROOT/name).read_bytes()) == value, ('original evidence changed',name)
    old_tb = (archive/'sources/sim/tb_descriptor_drr.sv').read_bytes()
    old_line = b'1: begin @(negedge clk); run_enable=a[1][0]; end'
    assert old_tb.count(old_line) == 1
    assert (ROOT/'sim/tb_descriptor_drr.sv').read_bytes() == old_tb.replace(old_line,b'1: begin run_enable=a[1][0]; end')
    return read('SOURCE_SEAL.json'), evidence


def freeze_attempt02():
    assert not REPAIR_RECEIPT.exists(), 'attempt02 already executed'
    assert not (ROOT/'reports/attempt02').exists() and not (ROOT/'artifacts/attempt02').exists()
    if REPAIR_SEAL.exists():
        history=ROOT/'history/attempt02_prehdl_01'
        index=json.loads((history/'index.json').read_bytes())
        assert index['status']=='ATTEMPT02_NO_HDL' and index['compiler_simulator_invocations_attempt02']==0
        assert REPAIR_SEAL.read_bytes()==(history/'prehdl_repair_seal.json').read_bytes(), 'only named unexecuted draft may be superseded'
        for name,value in index['files_sha256'].items():
            assert digest((history/name).read_bytes())==value
    original, evidence = original_failure_evidence()
    plan, audit = preparation_check()
    assert expanded_commands(plan,audit) == original['commands']
    for item in original['tools'].values():
        assert digest(Path(item['path']).read_bytes()) == item['sha256']
    mapping = sources(attempt02=True)
    for name in ('SOURCE_SEAL.json','verification.json',
                 'failure_archive/attempt_01/sources/SOURCE_SEAL.json',
                 'failure_archive/attempt_01/sources/verification.json'):
        assert name in mapping, 'root-relative exclusion must retain archived metadata'
    write(REPAIR_SEAL, dict(schema=2, attempt=2, baseline=plan['baseline'],
          repair='TB run_enable action commits at its current negedge; no extra idle visit before pause',
          original_source_seal_sha256=digest(SEAL.read_bytes()),
          original_verification_sha256=digest(RECEIPT.read_bytes()),
          original_archive_manifest_sha256=digest((ROOT/'failure_archive/attempt_01/ARCHIVE.json').read_bytes()),
          files_sha256=mapping,
          files_map_sha256=digest(json.dumps(mapping,sort_keys=True,separators=(',',':')).encode()),
          test_plan_sha256=digest((ROOT/'TEST_PLAN.json').read_bytes()),
          fixture_audit_sha256=digest((ROOT/'fixture_audit.json').read_bytes()),
          tools=original['tools'], commands=original['commands'],
          artifact_directory='artifacts/attempt02', report_directory='reports/attempt02',
          receipt='verification_attempt02.json', compiler_simulator_calls_attempt02_before_seal=0,
          preparation_reruns=0, oracle_reruns=0, first_failure_terminal=True, automatic_retry=False))
    print(json.dumps(dict(status='REPAIR_SEALED_NOT_EXECUTED',files=len(mapping),sha256=digest(REPAIR_SEAL.read_bytes()))))


def validate_attempt02_seal():
    original, evidence = original_failure_evidence()
    plan, audit = preparation_check()
    repair = read('REPAIR_SEAL.json')
    assert repair['attempt'] == 2 and sources(attempt02=True) == repair['files_sha256']
    assert repair['original_source_seal_sha256'] == digest(SEAL.read_bytes())
    assert repair['original_verification_sha256'] == digest(RECEIPT.read_bytes())
    assert repair['original_archive_manifest_sha256'] == digest((ROOT/'failure_archive/attempt_01/ARCHIVE.json').read_bytes())
    assert repair['test_plan_sha256'] == digest((ROOT/'TEST_PLAN.json').read_bytes())
    assert repair['fixture_audit_sha256'] == digest((ROOT/'fixture_audit.json').read_bytes())
    assert repair['commands'] == original['commands'] == expanded_commands(plan,audit)
    assert repair['tools'] == original['tools']
    for item in repair['tools'].values():
        assert digest(Path(item['path']).read_bytes()) == item['sha256']
    return repair,plan


def attempt02_failure_evidence():
    assert digest(REPAIR_SEAL.read_bytes()) == '994017700452adea8e8b990889a1e0f4b28c36b1162fa4bdd62784a9d7b5f9a8'
    assert digest(REPAIR_RECEIPT.read_bytes()) == '5d99a09d301dc58b65987de6af4e0011e13566f04040d8d7c2e1b1c97a8ee4ef'
    original=read('verification_attempt02.json')
    assert original['status']=='FAIL'
    assert [r['status'] for r in original['records']]==['PASS']*5+['FAIL']+['NOT_RUN']*18
    archive=ROOT/'failure_archive/attempt_02';manifest=archive/'ARCHIVE.json'
    assert digest(manifest.read_bytes())=='d787e0ad783702b85f562fe5c1e44a0320c9bbc063bd896466da113bd99c35c6'
    evidence=json.loads(manifest.read_bytes())
    assert evidence['status']=='FAIL_STOPPED' and evidence['automatic_retry'] is False
    assert len(evidence['files'])==115
    assert {p.relative_to(archive).as_posix() for p in archive.rglob('*') if p.is_file()}==set(evidence['files'])|{'ARCHIVE.json'}
    for name,item in evidence['files'].items():
        path=archive/name
        assert digest(path.read_bytes())==item['sha256'] and path.stat().st_size==item['bytes']
    for name,value in evidence['original_files_sha256'].items():
        if name not in ('run_tests.py','README.md'):
            assert digest((ROOT/name).read_bytes())==value, ('attempt02 evidence changed',name)
    return read('REPAIR_SEAL.json'),evidence


def corrected_attempt03_commands(original):
    patch=read('COMMAND_ORDER_PATCH.json')
    assert patch['attempt']==3 and patch['command_name']=='default_compile'
    commands=json.loads(json.dumps(original['commands']))
    selected=[c for c in commands if c['name']=='default_compile']
    assert len(selected)==1 and selected[0]['argv']==patch['old_argv']
    old=patch['old_argv'];assert old[-3:]==['-s','descriptor_drr4','example/descriptor_drr4.sv']
    new=old[:-3]+old[-1:]
    first_source=next(i for i,arg in enumerate(new) if arg.endswith('.sv'))
    new[first_source:first_source]=['-s','descriptor_drr4']
    assert new==patch['new_argv'] and Counter(new)==Counter(old)
    assert [x for x in new if x.endswith('.sv')]==[x for x in old if x.endswith('.sv')]
    selected[0]['argv']=new
    assert len(commands)==24
    assert [c['name'] for c,o in zip(commands,original['commands']) if c!=o]==['default_compile']
    return commands


def freeze_attempt03():
    assert not REPAIR_SEAL_ATTEMPT03.exists() and not REPAIR_RECEIPT_ATTEMPT03.exists(), 'attempt03 already sealed/executed'
    assert not (ROOT/'reports/attempt03').exists() and not (ROOT/'artifacts/attempt03').exists()
    original_failure_evidence();original,evidence=attempt02_failure_evidence()
    plan,audit=preparation_check()
    assert expanded_commands(plan,audit)==original['commands']
    commands=corrected_attempt03_commands(original)
    for item in original['tools'].values():assert digest(Path(item['path']).read_bytes())==item['sha256']
    mapping=sources(attempt03=True)
    for name in ('SOURCE_SEAL.json','verification.json','REPAIR_SEAL.json','verification_attempt02.json',
                 'failure_archive/attempt_01/ARCHIVE.json','failure_archive/attempt_02/ARCHIVE.json',
                 'failure_archive/attempt_02/sources/REPAIR_SEAL.json',
                 'failure_archive/attempt_02/sources/verification_attempt02.json'):
        assert name in mapping
    write(REPAIR_SEAL_ATTEMPT03,dict(schema=3,attempt=3,baseline=plan['baseline'],
          repair='Move the same default wrapper -s selection before the first source token; no numerical/source-set change',
          original_source_seal_sha256=digest(SEAL.read_bytes()),original_verification_sha256=digest(RECEIPT.read_bytes()),
          original_archive_manifest_sha256=digest((ROOT/'failure_archive/attempt_01/ARCHIVE.json').read_bytes()),
          attempt02_source_seal_sha256=digest(REPAIR_SEAL.read_bytes()),attempt02_verification_sha256=digest(REPAIR_RECEIPT.read_bytes()),
          attempt02_archive_manifest_sha256=digest((ROOT/'failure_archive/attempt_02/ARCHIVE.json').read_bytes()),
          files_sha256=mapping,files_map_sha256=digest(json.dumps(mapping,sort_keys=True,separators=(',',':')).encode()),
          test_plan_sha256=digest((ROOT/'TEST_PLAN.json').read_bytes()),fixture_audit_sha256=digest((ROOT/'fixture_audit.json').read_bytes()),
          command_order_patch_sha256=digest((ROOT/'COMMAND_ORDER_PATCH.json').read_bytes()),
          tools=original['tools'],commands_original=original['commands'],commands=commands,
          artifact_directory='artifacts/attempt03',report_directory='reports/attempt03',receipt='verification_attempt03.json',
          compiler_simulator_calls_attempt03_before_seal=0,preparation_reruns=0,oracle_reruns=0,
          first_failure_terminal=True,automatic_retry=False))
    print(json.dumps(dict(status='ATTEMPT03_SEALED_NOT_EXECUTED',files=len(mapping),sha256=digest(REPAIR_SEAL_ATTEMPT03.read_bytes()))))


def validate_attempt03_seal():
    original_failure_evidence();original,evidence=attempt02_failure_evidence()
    plan,audit=preparation_check();repair=read('REPAIR_SEAL_ATTEMPT03.json')
    assert repair['attempt']==3 and sources(attempt03=True)==repair['files_sha256']
    assert repair['original_source_seal_sha256']==digest(SEAL.read_bytes())
    assert repair['original_verification_sha256']==digest(RECEIPT.read_bytes())
    assert repair['original_archive_manifest_sha256']==digest((ROOT/'failure_archive/attempt_01/ARCHIVE.json').read_bytes())
    assert repair['attempt02_source_seal_sha256']==digest(REPAIR_SEAL.read_bytes())
    assert repair['attempt02_verification_sha256']==digest(REPAIR_RECEIPT.read_bytes())
    assert repair['attempt02_archive_manifest_sha256']==digest((ROOT/'failure_archive/attempt_02/ARCHIVE.json').read_bytes())
    assert repair['test_plan_sha256']==digest((ROOT/'TEST_PLAN.json').read_bytes())
    assert repair['fixture_audit_sha256']==digest((ROOT/'fixture_audit.json').read_bytes())
    assert repair['command_order_patch_sha256']==digest((ROOT/'COMMAND_ORDER_PATCH.json').read_bytes())
    assert expanded_commands(plan,audit)==original['commands']==repair['commands_original']
    assert repair['commands']==corrected_attempt03_commands(original)
    assert repair['tools']==original['tools']
    for item in repair['tools'].values():assert digest(Path(item['path']).read_bytes())==item['sha256']
    return repair,plan


def execute_attempt02(approved_repair_seal, attempt03=False):
    receipt_path=REPAIR_RECEIPT_ATTEMPT03 if attempt03 else REPAIR_RECEIPT
    seal_path=REPAIR_SEAL_ATTEMPT03 if attempt03 else REPAIR_SEAL
    attempt=3 if attempt03 else 2
    assert not receipt_path.exists(), 'this attempt receipt is terminal; no automatic retry'
    repair, plan = validate_attempt03_seal() if attempt03 else validate_attempt02_seal()
    assert approved_repair_seal == digest(seal_path.read_bytes()), 'explicit approved repair seal required'
    for name in (repair['artifact_directory'],repair['report_directory']):
        assert not (ROOT/name).exists(), 'previous outputs for this attempt are terminal'
        (ROOT/name).mkdir()
    env = os.environ.copy()
    suite = REPO/'tools/oss-cad-suite/oss-cad-suite'
    env['PATH'] = os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    receipt = dict(schema=attempt, attempt=attempt, baseline=plan['baseline'], status='RUNNING',
          source_seal_sha256=digest(seal_path.read_bytes()),
          original_source_seal_sha256=digest(SEAL.read_bytes()),
          original_verification_sha256=digest(RECEIPT.read_bytes()),
          original_archive_manifest_sha256=repair['original_archive_manifest_sha256'],
          test_plan_sha256=digest((ROOT/'TEST_PLAN.json').read_bytes()),
          records=[dict(command=c,status='NOT_RUN') for c in repair['commands']],
          first_failure_terminal=True, automatic_retry=False, preparation_reruns=0, oracle_reruns=0,
          maturity=['RTL_CANDIDATE','HW_UNVERIFIED'], excluded_checks=plan['excluded_checks'])
    if attempt03:
        receipt.update(attempt02_source_seal_sha256=digest(REPAIR_SEAL.read_bytes()),
                       attempt02_verification_sha256=digest(REPAIR_RECEIPT.read_bytes()),
                       attempt02_archive_manifest_sha256=repair['attempt02_archive_manifest_sha256'],
                       command_order_patch_sha256=repair['command_order_patch_sha256'])
    write(receipt_path,receipt)
    for index, record in enumerate(receipt['records']):
        command = record['command']
        argv = [arg.replace('{ARTIFACT}',str((ROOT/repair['artifact_directory']).resolve())) for arg in command['argv']]
        argv[0] = repair['tools'][argv[0]]['path']
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
                out,err=timeout_cleanup(child,record,index,command,error.stdout or b'',error.stderr or b'',repair['report_directory'])
            record['returncode']=child.returncode
        except Exception as error:
            record['runner_error']=type(error).__name__+': '+str(error)
            record['returncode']=None
        record.update(elapsed_seconds=time.monotonic()-start,timeout=timed_out)
        for suffix,raw in (('stdout',out),('stderr',err)):
            path=repair['report_directory']+'/%02d_%s.%s'%(index,command['name'],suffix)
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
                if command['kind'] == 'compile':
                    artifact=ROOT/repair['artifact_directory']/(command['profile']+'.vvp')
                    record['artifact']=artifact.relative_to(ROOT).as_posix()
                    record['artifact_sha256']=digest(artifact.read_bytes())
            except Exception as error:
                record['status']='FAIL'; record['validation_error']=type(error).__name__+': '+str(error)
        write(receipt_path,receipt)
        print('attempt%02d '%attempt+command['name']+' '+record['status'],flush=True)
        if record['status'] not in ('PASS','EXPECTED_REJECT'):
            receipt['status']=record['status']; write(receipt_path,receipt); return 1
    receipt['status']='PASS'
    receipt['maturity']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED']
    receipt['totals']=dict(children=24, passed=12, expected_reject=12,
           simulations=7, commands=sum(r.get('summary',{}).get('commands',0) for r in receipt['records']),
           outputs=sum(r.get('summary',{}).get('outputs',0) for r in receipt['records']),
           resets=sum(r.get('summary',{}).get('resets',0) for r in receipt['records']),
           max_child_seconds=max(r['elapsed_seconds'] for r in receipt['records']))
    assert sources(attempt02=not attempt03,attempt03=attempt03) == repair['files_sha256'], 'repair source or original evidence changed during run'
    write(receipt_path,receipt)
    print(json.dumps(receipt['totals']))
    return 0


def audit_attempt02(attempt03=False):
    repair, plan = validate_attempt03_seal() if attempt03 else validate_attempt02_seal()
    receipt=read('verification_attempt03.json' if attempt03 else 'verification_attempt02.json')
    assert receipt['status']=='PASS' and receipt['attempt']==(3 if attempt03 else 2)
    assert receipt['source_seal_sha256']==digest((REPAIR_SEAL_ATTEMPT03 if attempt03 else REPAIR_SEAL).read_bytes())
    assert len(receipt['records'])==24
    streams=set();artifacts=set()
    for command,record in zip(repair['commands'],receipt['records']):
        assert record['command']==command and record['status'] in ('PASS','EXPECTED_REJECT')
        argv=[arg.replace('{ARTIFACT}',str((ROOT/repair['artifact_directory']).resolve())) for arg in command['argv']]
        argv[0]=repair['tools'][argv[0]]['path']
        assert record['executed_argv']==argv and not record['timeout'] and record['elapsed_seconds']<20
        for kind in ('stdout','stderr'):
            assert digest((ROOT/record[kind]).read_bytes())==record[kind+'_sha256'];streams.add(record[kind])
        out=(ROOT/record['stdout']).read_bytes();err=(ROOT/record['stderr']).read_bytes()
        if command['expected']=='EXPECTED_REJECT':
            assert record['status']=='EXPECTED_REJECT' and record['returncode']!=0
            assert b'descriptor_drr_scheduler_invalid_parameters__see_README' in out+err
        else:
            assert record['status']=='PASS' and record['returncode']==0
        if command['kind']=='simulate':assert check_simulation(command,out)==record['summary']
        if command['kind']=='compile':
            assert digest((ROOT/record['artifact']).read_bytes())==record['artifact_sha256'];artifacts.add(record['artifact'])
    assert streams=={p.relative_to(ROOT).as_posix() for p in (ROOT/repair['report_directory']).iterdir() if p.is_file()}
    assert artifacts=={p.relative_to(ROOT).as_posix() for p in (ROOT/repair['artifact_directory']).iterdir() if p.is_file()}
    print(json.dumps(dict(status='ATTEMPT%02d_HASH_LOG_AUDIT_PASS'%(3 if attempt03 else 2),receipt_status=receipt['status'],hdl_calls=0,oracle_calls=0)))


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('mode',choices=('freeze','run','audit','freeze-attempt02','run-attempt02','audit-attempt02',
                                       'freeze-attempt03','run-attempt03','audit-attempt03'))
    parser.add_argument('--approved-repair-seal')
    parser.add_argument('--approved-seal')
    args=parser.parse_args();mode=args.mode
    if mode == 'freeze': freeze()
    elif mode == 'audit': audit_only()
    elif mode=='run': raise SystemExit(execute())
    elif mode=='freeze-attempt02': freeze_attempt02()
    elif mode=='audit-attempt02': audit_attempt02()
    elif mode=='run-attempt02': raise SystemExit(execute_attempt02(args.approved_repair_seal))
    elif mode=='freeze-attempt03': freeze_attempt03()
    elif mode=='audit-attempt03': audit_attempt02(attempt03=True)
    else: raise SystemExit(execute_attempt02(args.approved_seal,attempt03=True))
