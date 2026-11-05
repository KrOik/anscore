"""Byte guards only. Importing this module performs no filesystem mutation."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding='utf-8'))

def inventory(directory: Path) -> set[str]:
    return {p.relative_to(directory).as_posix() for p in directory.rglob('*') if p.is_file()}

def file_map(directory: Path) -> dict:
    return {p.relative_to(directory).as_posix():sha(p) for p in directory.rglob('*') if p.is_file()}

def exact_map(directory: Path,mapping: dict) -> None:
    if file_map(directory)!=mapping: raise RuntimeError('exact file/hash guard: '+str(directory))

def dump(path: Path,value: dict,exclusive: bool=False) -> None:
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,indent=2);stream.write('\n')

def save_raw(output: Path,name: str,data: bytes) -> dict:
    path=output/name
    with path.open('xb') as stream: stream.write(data)
    return dict(file=path.relative_to(ROOT).as_posix(),bytes=len(data),sha256=sha(path))

def archive_failure(destination: Path,paths: list[Path],terminal_receipt: dict) -> str:
    destination.mkdir(parents=True,exist_ok=False);files={}
    for base in paths:
        candidates=[base] if base.is_file() else sorted(base.rglob('*')) if base.exists() else []
        for path in candidates:
            if not path.is_file(): continue
            relative=path.relative_to(ROOT).as_posix();wanted=sha(path)
            target=destination/relative;target.parent.mkdir(parents=True,exist_ok=True)
            with target.open('xb') as stream: stream.write(path.read_bytes())
            if sha(target)!=wanted or sha(path)!=wanted: raise RuntimeError('archive byte guard')
            files[relative]=wanted
    dump(destination/'ARCHIVE.json',dict(schema=1,status='FAILED_STOPPED_NO_RETRY',files=len(files),
         original_files_sha256=files,terminal_receipt=terminal_receipt,automatic_retry=False),exclusive=True)
    return sha(destination/'ARCHIVE.json')

def verify_map(base: Path,mapping: dict) -> None:
    for relative,wanted in mapping.items():
        if sha(base/relative)!=wanted: raise RuntimeError('byte guard: '+relative)

def verify_author(expected_digest: str | None=None) -> dict:
    if sys.flags.optimize: raise RuntimeError('optimized Python forbidden')
    if expected_digest is not None and sha(ROOT/'AUTHOR_SEAL.json')!=expected_digest:
        raise RuntimeError('approved author seal changed')
    seal=read(ROOT/'AUTHOR_SEAL.json')
    verify_map(ROOT,seal['sources'])
    verify_map(REPO,seal['external_sources'])
    for value in seal['tools'].values():
        if sha(Path(value['path']))!=value['sha256']: raise RuntimeError('tool byte guard')
    verify_map(REPO,seal['runtime_dlls']);verify_map(REPO,seal['runtime_modules'])
    compiler=REPO/seal['compiler_install_directory']
    expected={Path(f).relative_to(seal['compiler_install_directory']).as_posix() for f in seal['compiler_install_files_sha256']}
    if inventory(compiler)!=expected: raise RuntimeError('compiler install inventory changed')
    verify_map(REPO,seal['compiler_install_files_sha256'])
    for anchor in seal['anchors'].values():
        if sha(REPO/anchor['path'])!=anchor['sha256']: raise RuntimeError('anchor byte guard')
    if expected_digest is not None and sha(ROOT/'AUTHOR_SEAL.json')!=expected_digest:
        raise RuntimeError('approved author seal changed')
    return seal

def verify_reviews(approval: dict) -> None:
    reviews=approval.get('static_reviews',{})
    if len(reviews)<2: raise RuntimeError('two independent review anchors required')
    verify_map(REPO,reviews)

def verify_source(expected_digest: str | None=None,expected_author: str | None=None) -> dict:
    if expected_digest is not None and sha(ROOT/'SOURCE_SEAL.json')!=expected_digest:
        raise RuntimeError('approved source seal changed')
    author=verify_author(expected_author);seal=read(ROOT/'SOURCE_SEAL.json')
    if seal['author_seal_sha256']!=sha(ROOT/'AUTHOR_SEAL.json'): raise RuntimeError('author seal binding')
    verify_map(ROOT,seal['files'])
    if set(seal['files'])!=set(author['sources'])|{'AUTHOR_SEAL.json'}|set(seal['prepared_files']):
        raise RuntimeError('sealed file inventory')
    verify_map(ROOT,seal['prepared_files'])
    if seal['test_plan_sha256']!=sha(ROOT/'TEST_PLAN.json') or seal['preparation_receipt_sha256']!=sha(ROOT/'preparation/receipt.json'):
        raise RuntimeError('prepared plan/receipt binding')
    receipt=read(ROOT/'preparation/receipt.json')
    if receipt['status']!='PASS' or receipt['author_seal_sha256']!=seal['author_seal_sha256']:
        raise RuntimeError('preparation did not pass')
    if expected_digest is not None and sha(ROOT/'SOURCE_SEAL.json')!=expected_digest:
        raise RuntimeError('approved source seal changed')
    return seal
