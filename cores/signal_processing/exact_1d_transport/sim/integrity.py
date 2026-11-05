"""Shared future integrity, copy and failure-preservation helpers; no model imports."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path: Path):
    return json.loads(path.read_bytes())


def write(path: Path, value, exclusive: bool = False) -> None:
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        stream.write(json.dumps(value,indent=2)+'\n')


def local(base: Path, name: str) -> Path:
    relative = PurePosixPath(name)
    assert name and not relative.is_absolute() and '..' not in relative.parts
    assert '\\' not in name and ':' not in name and not any(c in name for c in '\0\r\n')
    result = (base/name).resolve()
    assert result.is_relative_to(base.resolve())
    return result


def inventory(folder: Path) -> dict[str,str]:
    return {p.relative_to(folder).as_posix():sha(p) for p in folder.rglob('*') if p.is_file()}


def copied_guard(folder: Path, expected: dict) -> None:
    assert inventory(folder) == expected, 'copied path set/bytes changed'


def copy_frozen(root: Path, destination: Path, expected: dict) -> None:
    assert not destination.exists()
    for name,digest in expected.items():
        source=local(root,name);target=local(destination,name)
        assert sha(source) == digest
        target.parent.mkdir(parents=True,exist_ok=True)
        with target.open('xb') as stream: stream.write(source.read_bytes())
        assert sha(target) == digest
    copied_guard(destination,expected)


def load_frozen(name: str, path: Path):
    assert name not in sys.modules and sys.dont_write_bytecode
    spec=importlib.util.spec_from_file_location(name,path)
    assert spec is not None and spec.loader is not None
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def author_guard(root: Path, expected: str, initial: bool = False) -> dict:
    assert not sys.flags.optimize and os.name == 'nt'
    assert sha(root/'AUTHOR_SEAL.json') == expected
    seal=read(root/'AUTHOR_SEAL.json')
    assert seal['schema'] == 'anscore-transport-author-seal-v1'
    assert seal['status'] == 'SOURCE_ONLY_NOT_RUN'
    assert seal['models_executed'] == seal['preparation_invocations'] == seal['hdl_children_executed'] == 0
    for name,digest in seal['files_sha256'].items():
        assert sha(local(root,name)) == digest, name
    assert sha(root/'FINITE_PLAN.json') == seal['finite_plan_sha256']
    assert sha(root/'TOOL_INVENTORY.json') == seal['tool_inventory_sha256']
    if initial:
        assert set(inventory(root)) == set(seal['files_sha256']) | {'AUTHOR_SEAL.json'}, 'unexpected initial files'
    return seal


def review_guard(root: Path, approval: dict) -> None:
    reviews=approval['independent_reviews']
    assert len(reviews) >= 2
    repo=root.parents[2]
    for name,digest in reviews.items():
        path=local(repo,name)
        assert not path.is_relative_to(root) and sha(path) == digest


def approval_guard(root: Path, path: Path, operation: str, seal_hash: str, author: dict, plan: dict) -> dict:
    assert path.is_file() and not path.resolve().is_relative_to(root)
    approval=read(path)
    required=dict(schema=f'anscore-transport-{operation}-approval-v1',approved_by='root',
                  author_seal_sha256=sha(root/'AUTHOR_SEAL.json'),finite_plan_sha256=sha(root/'FINITE_PLAN.json'),
                  tool_inventory_sha256=sha(root/'TOOL_INVENTORY.json'),
                  fixed_base_frames=16,profiles=4,timeout_seconds_per_tree=20,automatic_retry=False)
    if operation == 'prepare':
        required.update(preparation_invocations=1,hdl_execution=False,tool_execution=False,
                        numerical_scope='16 fixed cut and overlap certificates only')
        assert seal_hash == required['author_seal_sha256']
    else:
        assert operation == 'hdl'
        required.update(source_seal_sha256=seal_hash,max_children=25,simulations=10,named_parameter_rejects=8,
                        stop_on_first_failure=True,preparation_reexecution=False,
                        preparation_receipt_sha256=sha(root/'preparation/attempt_01/receipt.json'))
        assert approval['children'] == plan['children']
    assert all(approval.get(k) == v for k,v in required.items())
    assert approval['source_files_sha256'] == author['files_sha256']
    assert approval['tools'] == read(root/'TOOL_INVENTORY.json')['tools']
    assert Path(approval['tools']['PYTHON']['path']).resolve() == Path(sys.executable).resolve()
    review_guard(root,approval)
    return approval


def outer_preparation_guard(root: Path, binding_path: Path, approval: dict, approval_hash: str) -> str:
    # Root writes this after attaching a suspended child to Job20, before resume.
    assert binding_path.is_file() and not binding_path.resolve().is_relative_to(root)
    assert str(binding_path.resolve()) == str(Path(approval['outer_binding_path']).resolve())
    binding=read(binding_path)
    required=dict(schema='anscore-transport-root-job20-binding-v1',approved_by='root',
                  status='ATTACHED_BEFORE_RESUME',operation='prepare',child_pid=os.getpid(),
                  hard_seconds=20,kill_on_close=True,breakaway=False,
                  approval_sha256=approval_hash,author_seal_sha256=sha(root/'AUTHOR_SEAL.json'),
                  entry_sha256=sha(root/'prepare.py'),supervisor_sha256=sha(root/'sim/process_tree.py'))
    assert all(binding.get(k) == v for k,v in required.items())
    return sha(binding_path)


def archive(root: Path, name: str, folders: list[Path], extra: list[Path] | None = None) -> str:
    target=root/'failure_archive'/name
    target.mkdir(parents=True,exist_ok=False)
    sources=[p for folder in folders if folder.exists() for p in folder.rglob('*') if p.is_file()]
    sources += [p for p in (extra or []) if p.is_file()]
    hashes={}
    for source in sorted(set(sources)):
        name=source.relative_to(root).as_posix()
        destination=local(target,name);destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source,destination)
        hashes[name]=sha(destination)
        assert hashes[name] == sha(source)
    write(target/'ARCHIVE.json',dict(status='FAILED_STOPPED_NO_RETRY',original_files_sha256=hashes),True)
    return sha(target/'ARCHIVE.json')
