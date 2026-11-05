"""Frozen tool, complete directory and PE-closure byte guard; never launches tools."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations
import hashlib
from pathlib import Path


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(record: dict) -> None:
    assert record['schema'] == 'anscore-transport-static-tools-v1'
    assert record['compiler_or_numerical_launched'] is False
    for value in record['tools'].values():
        assert sha(Path(value['path'])) == value['sha256'], 'tool changed'
    for field in ('compiler_backend_sha256','runtime_modules_sha256','python_extensions_sha256','windows_system_files_sha256'):
        for name,digest in record[field].items():
            assert sha(Path(name)) == digest, (field,name)
    for name,node in record['local_pe_graph'].items():
        assert sha(Path(name)) == node['sha256'], 'PE graph owner changed'
    for directory,inventory in record['complete_directory_inventories'].items():
        folder = Path(directory)
        mode = inventory['mode']
        if mode == 'recursive_all_files':
            files = [p for p in folder.rglob('*') if p.is_file()]
        else:
            assert mode == 'direct_dll_pyd'
            files = [p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in ('.dll','.pyd')]
        actual = {p.relative_to(folder).as_posix():sha(p) for p in files}
        assert actual == inventory['files_sha256'], ('complete directory inventory changed',directory)
    assert all(Path(p).is_dir() for p in record['path_prefix'])
