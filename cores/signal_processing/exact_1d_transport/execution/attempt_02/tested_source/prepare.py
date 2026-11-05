"""Separately approved, once-only fixed 16-frame preparation. No HDL/tools."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

ROOT=Path(__file__).resolve().parent
sys.dont_write_bytecode=True


def bootstrap(expected: str):
    assert not sys.flags.optimize
    assert hashlib.sha256((ROOT/'AUTHOR_SEAL.json').read_bytes()).hexdigest() == expected
    author=json.loads((ROOT/'AUTHOR_SEAL.json').read_bytes())
    for name,digest in author['files_sha256'].items():
        path=(ROOT/name).resolve()
        assert path.is_relative_to(ROOT) and hashlib.sha256(path.read_bytes()).hexdigest() == digest
    spec=importlib.util.spec_from_file_location('transport_prepare_integrity',ROOT/'sim/integrity.py')
    assert spec is not None and spec.loader is not None
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    return helper


def run_once(expected: str, approval_path: Path, outer_binding: Path) -> int:
    started=time.monotonic();h=bootstrap(expected)
    author=h.author_guard(ROOT,expected,True);plan=h.read(ROOT/'FINITE_PLAN.json')
    approval_path=approval_path.resolve(strict=True);outer_binding=outer_binding.resolve(strict=True)
    approval=h.approval_guard(ROOT,approval_path,'prepare',expected,author,plan)
    approval_hash=h.sha(approval_path)
    outer_hash=h.outer_preparation_guard(ROOT,outer_binding,approval,approval_hash)
    attempt=ROOT/'preparation/attempt_01'
    assert not attempt.exists() and not (ROOT/'prepared').exists() and not (ROOT/'SOURCE_SEAL.json').exists()
    assert not (ROOT/'failure_archive/preparation_01').exists(), 'no retry'
    attempt.mkdir(parents=True,exist_ok=False)
    h.write(attempt/'LOCK.json',dict(status='STARTED_ONCE',author_seal_sha256=expected,
                                   approval_sha256=approval_hash,outer_binding_sha256=outer_hash),True)
    receipt=dict(schema='anscore-transport-preparation-receipt-v1',status='STARTED',
                 author_seal_sha256=expected,approval_sha256=approval_hash,outer_binding_sha256=outer_hash,
                 preparation_invocations=1,model_invocations=0,tools_launched=0,hdl_execution=False,
                 automatic_retry=False,hardware='HW_UNVERIFIED')
    h.write(attempt/'receipt.json',receipt)
    try:
        copied={**author['files_sha256'],'AUTHOR_SEAL.json':expected}
        copies=attempt/'sources';h.copy_frozen(ROOT,copies,copied)
        runtime=h.load_frozen('transport_prepare_runtime',copies/'sim/runtime.py')
        tools=h.read(copies/'TOOL_INVENTORY.json');runtime.verify(tools)
        assert tools['tools'] == approval['tools']
        model=h.load_frozen('transport_fixed_cut_overlap_model',copies/'sim/model.py')
        receipt['model_invocations']=1;h.write(attempt/'receipt.json',receipt)
        certificates,fixtures=model.prepare(copies/'fixtures/cases.json')
        assert len(certificates['cases']) == 16 and set(fixtures) == {'p0','p1','p2','p3'}
        prepared=ROOT/'prepared';prepared.mkdir(exist_ok=False)
        h.write(prepared/'CERTIFICATES.json',certificates,True)
        h.write(prepared/'RUNTIME.json',tools,True)
        for name,data in fixtures.items():
            with (prepared/(name+'.txt')).open('x',encoding='ascii',newline='\n') as stream: stream.write(data)
        prepared_hashes={('prepared/'+name):digest for name,digest in h.inventory(prepared).items()}
        assert len(prepared_hashes) == 6
        h.author_guard(ROOT,expected);h.copied_guard(copies,copied);runtime.verify(tools)
        assert h.sha(approval_path) == approval_hash and h.sha(outer_binding) == outer_hash
        seal=dict(schema='anscore-transport-prepared-seal-v1',status='PREPARED_NOT_HDL_RUN',
                  author_seal_sha256=expected,source_files_sha256=author['files_sha256'],
                  finite_plan_sha256=h.sha(ROOT/'FINITE_PLAN.json'),tool_inventory_sha256=h.sha(ROOT/'TOOL_INVENTORY.json'),
                  tools=tools['tools'],prepared_sha256=prepared_hashes,
                  preparation_approval_sha256=approval_hash,preparation_tested_copies_sha256=copied,
                  fixed_base_frames=16,profiles=4,max_children=25,simulations=10,named_parameter_rejects=8,
                  preparation_invocations=1,model_invocations=1,hdl_children_executed=0,automatic_retry=False,
                  hardware='HW_UNVERIFIED')
        h.write(ROOT/'SOURCE_SEAL.json',seal,True)
        receipt.update(status='PASS_FIXED_PREPARATION_ONLY',prepared_sha256=prepared_hashes,
                       source_seal_sha256=h.sha(ROOT/'SOURCE_SEAL.json'),tested_copies_sha256=copied,
                       elapsed_seconds=round(time.monotonic()-started,6))
        h.write(attempt/'receipt.json',receipt)
        print('PASS PREPARED TRANSPORT frames=16 profiles=4 model_invocations=1 no_hdl=1',flush=True)
        return 0
    except Exception as error:
        receipt.update(status='FAILED_STOPPED',failure=f'{type(error).__name__}: {error}',
                       elapsed_seconds=round(time.monotonic()-started,6))
        h.write(attempt/'receipt.json',receipt)
        archive_hash=h.archive(ROOT,'preparation_01',[attempt,ROOT/'prepared'],[ROOT/'SOURCE_SEAL.json'])
        print('FAILED_STOPPED TRANSPORT preparation archive_sha256='+archive_hash+' no_retry=1',flush=True)
        return 1


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-author-seal',required=True)
    parser.add_argument('--approval',required=True,type=Path)
    parser.add_argument('--outer-binding',required=True,type=Path)
    args=parser.parse_args()
    return run_once(args.approved_author_seal,args.approval,args.outer_binding)


if __name__ == '__main__':
    raise SystemExit(main())
