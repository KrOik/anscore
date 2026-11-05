"""One separately approved preparation of ten fixed analytic TV cases; no HDL."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
ATTEMPT = ROOT/'preparation/attempt_01'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path: Path) -> dict:
    return json.loads(path.read_bytes())


def write(path: Path, value: dict, exclusive: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x' if exclusive else 'w', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(value, indent=2)+'\n')


def local(base: Path, name: str) -> Path:
    value = PurePosixPath(name)
    assert name and not value.is_absolute() and '..' not in value.parts
    assert '\\' not in name and ':' not in name and not any(c in name for c in '\r\n\0')
    target = (base/name).resolve()
    assert target.is_relative_to(base.resolve())
    return target


def source_guard(expected: str, initial: bool = False) -> dict:
    assert not sys.flags.optimize
    path = ROOT/'SOURCE_FREEZE.json'
    assert sha(path) == expected, 'source freeze changed'
    freeze = read(path)
    assert freeze['schema'] == 'anscore-tv-source-freeze-v1'
    assert freeze['status'] == 'SOURCE_ONLY_NOT_RUN'
    assert freeze['source_execution'] == freeze['preparation_execution'] == freeze['hdl_execution'] == 0
    for relative, digest in freeze['files_sha256'].items():
        assert sha(local(ROOT, relative)) == digest, relative
    if initial:
        actual = {p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*') if p.is_file()}
        assert actual == set(freeze['files_sha256']) | {'SOURCE_FREEZE.json'}, 'unexpected package file before preparation'
    return freeze


def approval_guard(path: Path, expected: str, freeze: dict) -> dict:
    assert not path.resolve().is_relative_to(ROOT)
    approval = read(path)
    required = dict(schema='anscore-tv-prepare-approval-v1', approved_by='root',
                    source_freeze_sha256=expected, finite_plan_sha256=sha(ROOT/'FINITE_PLAN.json'),
                    preparation_invocations=1, timeout_seconds_per_tree=20,
                    fixed_normal_cases=10, profile_count=6, max_future_hdl_children=26,
                    numerical_scope='ten fixed analytic KKT certificates only',
                    hdl_execution=False, tool_execution=False, automatic_retry=False)
    assert all(approval.get(key) == value for key, value in required.items())
    assert approval['source_files_sha256'] == freeze['files_sha256']
    reviews = approval['independent_reviews']
    assert len(reviews) >= 2
    for name, digest in reviews.items():
        review = local(REPO, name)
        assert not review.is_relative_to(ROOT) and sha(review) == digest
    assert set(approval['tools']) == {'PYTHON', 'IVERILOG', 'VVP'}
    for tool in approval['tools'].values():
        assert sha(Path(tool['path']).resolve(strict=True)) == tool['sha256']
    assert Path(approval['tools']['PYTHON']['path']).resolve() == Path(sys.executable).resolve()
    return approval


def copied_guard(folder: Path, expected: dict) -> None:
    actual = {p.relative_to(folder).as_posix(): sha(p) for p in folder.rglob('*') if p.is_file()}
    assert actual == expected, 'preparation tested-source copies changed'


def load_frozen(name: str, path: Path):
    assert name not in sys.modules
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def archive_partial() -> None:
    target = ROOT/'failure_archive/preparation_01'
    target.mkdir(parents=True, exist_ok=False)
    owned = [p for folder in (ATTEMPT, ROOT/'prepared') if folder.exists()
             for p in folder.rglob('*') if p.is_file()]
    if (ROOT/'SOURCE_SEAL.json').exists():
        owned.append(ROOT/'SOURCE_SEAL.json')
    inventory = {}
    for source in sorted(owned):
        name = source.relative_to(ROOT).as_posix()
        destination = local(target, name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        inventory[name] = sha(destination)
        assert inventory[name] == sha(source)
    write(target/'ARCHIVE.json', dict(status='FAILED_STOPPED_NO_RETRY',
                                    original_files_sha256=inventory), exclusive=True)


def run_once(expected: str, approval_path: Path) -> int:
    started = time.monotonic()
    sys.dont_write_bytecode = True
    freeze = source_guard(expected, initial=True)
    approval_path = approval_path.resolve(strict=True)
    approval = approval_guard(approval_path, expected, freeze)
    approval_hash = sha(approval_path)
    assert not ATTEMPT.exists() and not (ROOT/'prepared').exists() and not (ROOT/'SOURCE_SEAL.json').exists()
    assert not (ROOT/'failure_archive/preparation_01').exists(), 'no retry'
    ATTEMPT.mkdir(parents=True, exist_ok=False)
    write(ATTEMPT/'LOCK.json', dict(status='STARTED_ONCE', source_freeze_sha256=expected,
                                 approval_sha256=approval_hash), exclusive=True)
    receipt = dict(schema='anscore-tv-preparation-receipt-v1', status='STARTED',
                   source_freeze_sha256=expected, finite_plan_sha256=sha(ROOT/'FINITE_PLAN.json'),
                   approval_sha256=approval_hash, preparation_invocations=1,
                   numerical_scope='ten fixed analytic KKT certificates only',
                   compiler_launched=False, author_code_launched=False,
                   hdl_execution=False, automatic_retry=False, hardware='HW_UNVERIFIED')
    write(ATTEMPT/'receipt.json', receipt)
    try:
        copies = ATTEMPT/'sources'
        copied_hashes = {**freeze['files_sha256'], 'SOURCE_FREEZE.json': expected}
        for relative, digest in copied_hashes.items():
            destination = local(copies, relative)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('xb') as stream:
                stream.write(local(ROOT, relative).read_bytes())
            assert sha(destination) == digest
        copied_guard(copies, copied_hashes)
        runtime = load_frozen('tv_preparation_static_runtime', copies/'sim/runtime.py')
        runtime_record = runtime.snapshot({key: value['path'] for key, value in approval['tools'].items()})
        assert runtime_record['tools'] == approval['tools']
        runtime.verify(runtime_record)
        write(ATTEMPT/'RUNTIME.json', runtime_record, exclusive=True)
        receipt['runtime_record_sha256'] = sha(ATTEMPT/'RUNTIME.json')
        write(ATTEMPT/'receipt.json', receipt)
        oracle = load_frozen('tv_preparation_fixed_certificate', copies/'sim/oracle.py')
        cases, profiles = oracle.load_fixed()
        bundle = oracle.certificate_bundle(cases, profiles)
        (ROOT/'prepared').mkdir(exist_ok=False)
        write(ROOT/'prepared/CERTIFICATES.json', bundle, exclusive=True)
        for name, profile in profiles.items():
            with (ROOT/'prepared'/f'{name}.txt').open('x', encoding='utf-8', newline='\n') as stream:
                stream.write(oracle.fixture_text(profile, cases))
        write(ROOT/'prepared/RUNTIME.json', runtime_record, exclusive=True)
        prepared = {p.relative_to(ROOT).as_posix(): sha(p) for p in (ROOT/'prepared').rglob('*') if p.is_file()}
        assert len(prepared) == 8
        source_guard(expected)
        assert sha(approval_path) == approval_hash
        copied_guard(copies, copied_hashes)
        runtime.verify(runtime_record)
        plan = read(copies/'FINITE_PLAN.json')
        assert len(plan['children']) == plan['max_children'] == 26
        assert len(cases) == 10 and len(profiles) == 6
        seal = dict(schema='anscore-tv-prepared-seal-v1', status='PREPARED_NOT_HDL_RUN',
                    source_freeze_sha256=expected, source_files_sha256=freeze['files_sha256'],
                    finite_plan_sha256=sha(ROOT/'FINITE_PLAN.json'), prepared_sha256=prepared,
                    tools=runtime_record['tools'], runtime=runtime_record,
                    path_prefix=runtime_record['path_prefix'],
                    preparation_approval_sha256=approval_hash,
                    preparation_tested_copies_sha256=copied_hashes,
                    fixed_normal_cases=10, profiles=6, normal_rows=162, reset_fresh_rows=24,
                    max_children=26, timeout_seconds_per_tree=20, automatic_retry=False,
                    compiler_launched=False, hardware='HW_UNVERIFIED')
        write(ROOT/'SOURCE_SEAL.json', seal, exclusive=True)
        receipt.update(status='PASS_FIXED_PREPARATION_ONLY', fixed_cases=10, profile_count=6,
                       prepared_sha256=prepared, source_seal_sha256=sha(ROOT/'SOURCE_SEAL.json'),
                       tested_copies_sha256=copied_hashes,
                       numerical_certificate_execution=True,
                       elapsed_seconds=round(time.monotonic()-started, 6))
        write(ATTEMPT/'receipt.json', receipt)
        print('PASS PREPARED TV cases=10 profiles=6 fixed_only=1 no_hdl=1', flush=True)
        return 0
    except Exception as error:
        receipt.update(status='FAILED_STOPPED', failure=f'{type(error).__name__}: {error}',
                       elapsed_seconds=round(time.monotonic()-started, 6))
        write(ATTEMPT/'receipt.json', receipt)
        archive_partial()
        print('FAILED_STOPPED TV preparation; original partial files retained; no retry', flush=True)
        return 1


def main() -> int:
    if sys.flags.optimize:
        raise RuntimeError('optimized Python is forbidden for preparation gates')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-source-freeze', required=True)
    parser.add_argument('--approval', required=True, type=Path)
    args = parser.parse_args()
    return run_once(args.approved_source_freeze, args.approval)


if __name__ == '__main__':
    raise SystemExit(main())
