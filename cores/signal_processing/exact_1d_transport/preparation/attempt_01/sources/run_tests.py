"""Future root-approved fixed 25-child qualification. Never imports the model."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

ROOT=Path(__file__).resolve().parent
OUT=ROOT/'execution/attempt_01'
sys.dont_write_bytecode=True


def bootstrap(expected: str):
    assert not sys.flags.optimize and os.name == 'nt'
    assert hashlib.sha256((ROOT/'SOURCE_SEAL.json').read_bytes()).hexdigest() == expected
    seal=json.loads((ROOT/'SOURCE_SEAL.json').read_bytes())
    assert hashlib.sha256((ROOT/'AUTHOR_SEAL.json').read_bytes()).hexdigest() == seal['author_seal_sha256']
    author=json.loads((ROOT/'AUTHOR_SEAL.json').read_bytes())
    assert seal['source_files_sha256'] == author['files_sha256']
    for name,digest in author['files_sha256'].items():
        path=(ROOT/name).resolve()
        assert path.is_relative_to(ROOT) and hashlib.sha256(path.read_bytes()).hexdigest() == digest
    spec=importlib.util.spec_from_file_location('transport_hdl_integrity',ROOT/'sim/integrity.py')
    assert spec is not None and spec.loader is not None
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    return helper


def prepared_guard(h, expected: str) -> tuple[dict,dict,dict]:
    assert h.sha(ROOT/'SOURCE_SEAL.json') == expected
    seal=h.read(ROOT/'SOURCE_SEAL.json')
    assert seal['schema'] == 'anscore-transport-prepared-seal-v1' and seal['status'] == 'PREPARED_NOT_HDL_RUN'
    assert seal['preparation_invocations'] == seal['model_invocations'] == 1 and seal['hdl_children_executed'] == 0
    author=h.author_guard(ROOT,seal['author_seal_sha256'])
    assert author['files_sha256'] == seal['source_files_sha256']
    assert h.sha(ROOT/'FINITE_PLAN.json') == seal['finite_plan_sha256']
    assert h.sha(ROOT/'TOOL_INVENTORY.json') == seal['tool_inventory_sha256']
    prepared={('prepared/'+name):digest for name,digest in h.inventory(ROOT/'prepared').items()}
    assert prepared == seal['prepared_sha256'] and len(prepared) == 6
    tools=h.read(ROOT/'TOOL_INVENTORY.json')
    assert h.read(ROOT/'prepared/RUNTIME.json') == tools and seal['tools'] == tools['tools']
    receipt=h.read(ROOT/'preparation/attempt_01/receipt.json')
    assert receipt['status'] == 'PASS_FIXED_PREPARATION_ONLY'
    assert receipt['source_seal_sha256'] == expected and receipt['author_seal_sha256'] == seal['author_seal_sha256']
    assert receipt['model_invocations'] == 1 and receipt['tools_launched'] == 0 and receipt['hdl_execution'] is False
    assert receipt['prepared_sha256'] == prepared and receipt['tested_copies_sha256'] == seal['preparation_tested_copies_sha256']
    h.copied_guard(ROOT/'preparation/attempt_01/sources',seal['preparation_tested_copies_sha256'])
    plan=h.read(ROOT/'FINITE_PLAN.json')
    assert plan['schema'] == 'anscore-transport-finite-plan-v1'
    assert len(plan['children']) == plan['max_children'] == 25
    assert len({child['name'] for child in plan['children']}) == 25
    assert all(child['hard_seconds'] == 20 for child in plan['children'])
    assert sum(c['kind'] == 'simulation' for c in plan['children']) == plan['simulation_children'] == 10
    assert sum(c['kind'] == 'reject' for c in plan['children']) == plan['named_parameter_rejects'] == 8
    assert sum(c['kind'] == 'compile' for c in plan['children']) == 5
    assert sum(c['kind'] == 'lint' for c in plan['children']) == 2
    assert plan['automatic_retry'] is False and plan['stop_on_first_failure'] is True
    return seal,author,plan


def artifacts_guard(h, expected: dict) -> None:
    assert h.inventory(OUT/'artifacts') == expected, 'fresh artifact names/bytes changed'


def register_artifact(h, slot: dict, artifacts: dict, tools: dict) -> None:
    path=OUT/'artifacts'/(slot['profile']+'.vvp')
    assert path.name not in artifacts and path.is_file() and path.stat().st_size > 0
    data=path.read_bytes();text=data.decode('utf-8','strict')
    modules={str(Path(name).resolve(strict=True)) for name in re.findall(r'^:vpi_module "([^"]+)";',text,re.MULTILINE)}
    assert modules == set(tools['runtime_modules_sha256']), 'fresh VVP module closure changed'
    artifacts[path.name]=h.sha(path)
    slot['generated_artifact']=dict(path=path.relative_to(ROOT).as_posix(),bytes=len(data),sha256=artifacts[path.name])


def run_once(expected: str, approval_path: Path) -> int:
    h=bootstrap(expected);seal,author,plan=prepared_guard(h,expected)
    approval_path=approval_path.resolve(strict=True)
    approval=h.approval_guard(ROOT,approval_path,'hdl',expected,author,plan)
    approval_hash=h.sha(approval_path)
    assert not OUT.exists() and not (ROOT/'failure_archive/hdl_01').exists(), 'no retry'
    OUT.mkdir(parents=True,exist_ok=False)
    h.write(OUT/'LOCK.json',dict(status='STARTED_ONCE',source_seal_sha256=expected,approval_sha256=approval_hash),True)
    slots=copy.deepcopy(plan['children'])
    for slot in slots: slot['status']='NOT_RUN'
    receipt=dict(schema='anscore-transport-hdl-receipt-v1',status='STARTED',source_seal_sha256=expected,
                 author_seal_sha256=seal['author_seal_sha256'],finite_plan_sha256=seal['finite_plan_sha256'],
                 approval_sha256=approval_hash,children=slots,preparation_reexecution=False,
                 model_invocations=0,max_children=25,timeout_seconds_per_tree=20,
                 automatic_retry=False,hardware='HW_UNVERIFIED')
    h.write(OUT/'receipt.json',receipt)
    artifacts={};current=None;child_started=False
    try:
        copied={**author['files_sha256'],'AUTHOR_SEAL.json':seal['author_seal_sha256'],
                'SOURCE_SEAL.json':expected,**seal['prepared_sha256']}
        copies=OUT/'sources';h.copy_frozen(ROOT,copies,copied)
        receipt['tested_copies_sha256']=copied
        runtime=h.load_frozen('transport_hdl_runtime',copies/'sim/runtime.py')
        supervisor=h.load_frozen('transport_hdl_job20',copies/'sim/process_tree.py')
        parser=h.load_frozen('transport_hdl_stored_raw_parser',copies/'sim/raw_parser.py')
        tools=h.read(copies/'TOOL_INVENTORY.json');runtime.verify(tools)
        assert tools['tools'] == approval['tools']
        (OUT/'artifacts').mkdir(exist_ok=False);(OUT/'tmp').mkdir(exist_ok=False)
        system=Path(os.environ['SystemRoot']).resolve(strict=True)
        env=dict(SystemRoot=str(system),WINDIR=str(system),PATH=os.pathsep.join(tools['path_prefix']),
                 TEMP=str((OUT/'tmp').resolve()),TMP=str((OUT/'tmp').resolve()),
                 PYTHONDONTWRITEBYTECODE='1',PYTHONNOUSERSITE='1',PYTHONPATH='',PYTHONIOENCODING='utf-8',
                 LANG='C',LC_ALL='C')
        receipt['effective_environment_sha256']=hashlib.sha256(json.dumps(env,sort_keys=True).encode()).hexdigest()
        for current in slots:
            child_started=False
            prepared_guard(h,expected);h.copied_guard(copies,copied);runtime.verify(tools)
            assert h.sha(approval_path) == approval_hash
            artifacts_guard(h,artifacts)
            if current['kind'] == 'compile':
                assert not (OUT/'artifacts'/(current['profile']+'.vvp')).exists()
            if current['kind'] == 'simulation':
                assert current['profile']+'.vvp' in artifacts
            argv=[tools['tools'][current['tool']]['path']]
            argv += [arg.replace('{ARTIFACT}',str((OUT/'artifacts').resolve())) for arg in current['args']]
            current.update(argv=argv,working_directory=str(copies.resolve()),status='STARTED')
            h.write(OUT/'receipt.json',receipt);child_started=True
            result=supervisor.execute(argv,copies,env,20)
            stdout,stderr=result.pop('stdout'),result.pop('stderr')
            current.update(result)
            for name,data in (('stdout',stdout),('stderr',stderr)):
                path=OUT/(current['name']+'.'+name+'.raw')
                with path.open('xb') as stream: stream.write(data)
                current[name+'_file']=path.relative_to(ROOT).as_posix()
                current[name+'_sha256']=h.sha(path);current[name+'_bytes']=len(data)
            # Record generated/partial files even when the child fails.
            current['observed_artifacts_sha256']=h.inventory(OUT/'artifacts')
            assert not current['timed_out'] and current['failure'] is None
            assert current['process_tree_cleanup'].get('windows_kill_on_close_job_closed') is True
            assert 0 <= current['elapsed_seconds'] < 20
            if current['kind'] == 'reject':
                assert current['returncode'] != 0 and current['marker'].encode('ascii') in stdout+stderr
                assert not (OUT/'artifacts'/(current['name']+'.vvp')).exists()
                current['status']='EXPECTED_REJECT'
            else:
                assert current['returncode'] == 0
                if current['kind'] in ('compile','lint'):
                    assert stdout == stderr == b'', 'unexpected compiler diagnostic'
                    if current['kind'] == 'compile': register_artifact(h,current,artifacts,tools)
                else:
                    assert current['kind'] == 'simulation' and stderr == b''
                    current['observed_tuples']=parser.validate(stdout,current,copies)
                    assert current['observed_tuples'] == current['expected_tuples']
                current['status']='PASS'
            artifacts_guard(h,artifacts);h.copied_guard(copies,copied)
            prepared_guard(h,expected);runtime.verify(tools)
            assert h.sha(approval_path) == approval_hash
            receipt['generated_artifacts_sha256']=dict(artifacts)
            h.write(OUT/'receipt.json',receipt)
        assert len(artifacts) == 5
        simulations=[s for s in slots if s['kind'] == 'simulation']
        totals={kind:sum(s['observed_tuples'][kind] for s in simulations) for kind in simulations[0]['observed_tuples']}
        assert all(totals[k] == v for k,v in dict(IN=1212,OUT=659,HOLD=90,OFFER=12,PROBE=8,RESET=24).items())
        receipt.update(status='PASS_FIXED_25',completed_children=25,simulations=10,named_parameter_rejects=8,
                       actual_tuples=totals,model_invocations=0,
                       artifacts_retained_for_independent_review=True)
        h.write(OUT/'receipt.json',receipt)
        print('PASS TRANSPORT FIXED children=25 simulations=10 rejects=8 HW_UNVERIFIED',flush=True)
        return 0
    except Exception as error:
        if current is not None:
            current['status']='TIMEOUT' if current.get('timed_out') else 'FAIL'
        receipt.update(status='FAILED_STOPPED',first_failure=current['name'] if current else 'metadata_setup',
                       failed_during_launched_child=child_started,failure=f'{type(error).__name__}: {error}',
                       generated_artifacts_sha256=h.inventory(OUT/'artifacts'),
                       not_run_children=[s['name'] for s in slots if s['status'] == 'NOT_RUN'])
        h.write(OUT/'receipt.json',receipt)
        archive_hash=h.archive(ROOT,'hdl_01',[OUT])
        print('FAILED_STOPPED TRANSPORT archive_sha256='+archive_hash+' no_retry=1',flush=True)
        return 1


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-source-seal',required=True)
    parser.add_argument('--approval',required=True,type=Path)
    args=parser.parse_args()
    return run_once(args.approved_source_seal,args.approval)


if __name__ == '__main__':
    raise SystemExit(main())
