"""Reproducibility sweep: regenerate the whole release into a scratch copy and hash-diff.

Every artifact here (RTL, vectors, testbench, board ROM, expectation) is derived
from the family models, so an author editing a model after the bitstream was
programmed is invisible unless something recomputes and compares. This tool
copies the tooling to a scratch directory OUTSIDE the release, regenerates there,
and reports any release file whose bytes differ. It never writes into the
release except its own evidence JSON.

Usage: python repro.py            # every loaded family
       python repro.py --keep     # leave the scratch tree for inspection
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import catalog
from groups import ROOT, plan

TOOLCHAIN = ['catalog.py', 'golden.py', 'generate.py', 'generate_lib.py', 'groups.py',
             'generate_board.py']
ART_DIRS = ['rtl', 'vectors', 'sim', 'ip', 'tables', 'board', 'doc']
# Board ROMs, acc_top and expectations only exist once every core can generate
# 128 vectors, so a partial catalog cannot reproduce them and must not be called stale.
PARTIAL_SKIP = ['board', 'doc']
# Hand-written simulation models live in sim/ next to generated testbenches, and
# the interface note is authored, not generated.
HANDWRITTEN = {'sim/mult12x12_model.v', 'doc/INTERFACE.md'}
SINGLE = ['catalog.json']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--keep', action='store_true')
    args = ap.parse_args()
    scratch = ROOT.parent / f'.repro_{datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")}'
    (scratch / 'tools').mkdir(parents=True)
    for tool in TOOLCHAIN:
        shutil.copy2(ROOT / 'tools' / tool, scratch / 'tools' / tool)
    for family in catalog.LOADED_FAMILIES:
        shutil.copy2(ROOT / 'tools' / f'{family}.py', scratch / 'tools' / f'{family}.py')
    if (ROOT / 'tools' / 'group_order.json').is_file():
        shutil.copy2(ROOT / 'tools' / 'group_order.json', scratch / 'tools' / 'group_order.json')
    for name in catalog.MISSING_FAMILIES:
        if (ROOT / 'tools' / f'{name}.py').is_file():
            shutil.copy2(ROOT / 'tools' / f'{name}.py', scratch / 'tools' / f'{name}.py')

    def run(argv):
        proc = subprocess.run([sys.executable, *argv], cwd=scratch / 'tools',
                              capture_output=True, text=True)
        return proc.returncode, (proc.stdout + proc.stderr)

    lines = []
    for family in catalog.LOADED_FAMILIES:
        code, text = run(['generate.py', '--family', family.replace('fam_', '')])
        if code:
            lines.append(f'generate --family {family} exit={code}: {text[-400:]}')
    full = len(catalog.CORES) == 150
    if full:
        code, text = run(['generate.py'])
        if code:
            lines.append(f'generate global exit={code}: {text[-400:]}')
        code, text = run(['generate_board.py'])
        if code:
            lines.append(f'generate_board exit={code}: {text[-400:]}')
    else:
        print(f'scratch: only {len(catalog.CORES)} of 150 cores loaded; '
              f'board artifacts and catalog.json are not regenerated')

    compared, differing, missing, stale = 0, [], [], []
    for directory in ART_DIRS:
        if not full and directory in PARTIAL_SKIP:
            continue
        generated = {path.relative_to(scratch).as_posix()
                     for path in (scratch / directory).rglob('*') if path.is_file()}
        present = {path.relative_to(ROOT).as_posix()
                   for path in (ROOT / directory).rglob('*')
                   if path.is_file()} if (ROOT / directory).is_dir() else set()
        for relative in sorted(generated):
            compared += 1
            release = ROOT / relative
            if not release.is_file():
                missing.append(relative)
            elif digest(release) != digest(scratch / relative):
                differing.append(relative)
        stale += sorted(path for path in present - generated - HANDWRITTEN
                        if full or not path.startswith(('sim/tb_board_', 'sim/tb_uart_')))
    for name in SINGLE:
        if full and (scratch / name).is_file():
            compared += 1
            if not (ROOT / name).is_file() or digest(ROOT / name) != digest(scratch / name):
                differing.append(name)
    result = dict(timestamp=datetime.now(timezone.utc).isoformat(),
                  loaded_families=catalog.LOADED_FAMILIES, cores=len(catalog.CORES),
                  full_release=full, files_compared=compared,
                  missing_from_release=sorted(missing), stale_in_release=sorted(stale),
                  differing=sorted(differing), notes=lines,
                  groups=[row['group'] for row in plan()])
    out = ROOT / 'evidence' / ('repro_' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S') + '.json')
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(f'compared {compared} files; {len(differing)} differ, {len(missing)} only in '
          f'scratch, {len(stale)} only in release')
    for name in sorted(differing)[:40]:
        print('  DIFF', name)
    for name in sorted(stale)[:40]:
        print('  STALE', name)
    for line in lines:
        print('  NOTE', line)
    print(f'evidence={out}')
    if not args.keep:
        shutil.rmtree(scratch)
    else:
        print(f'scratch kept at {scratch}')
    return 1 if differing or missing or stale or lines else 0


if __name__ == '__main__':
    raise SystemExit(main())
