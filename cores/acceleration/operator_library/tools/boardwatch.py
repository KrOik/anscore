"""Program the board once integration has accepted every group, without waiting
on a person to notice.

It adds no semantics: it waits for tools/integrate.py to report PASS, collects
the group-build evidence directories, and runs tools/remote_board.py, which is
the only thing here that touches the dock (JTAG SRAM only, guarded by the device
idcode check, credentials resolved by remote_board itself).

If integration fails, or a group has no accepted bitstream, this refuses to
program rather than programming a partial release.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent


def latest_integration():
    dirs = glob.glob(str(ROOT / 'evidence' / 'integrate_*'))
    if not dirs:
        return None
    return max(dirs, key=os.path.getmtime)


def wait_for_integration(timeout):
    """Return (status, evidence_dir) for the newest integrate run once it settles."""
    deadline = time.time() + timeout
    seen = None
    while time.time() < deadline:
        current = latest_integration()
        if current:
            path = Path(current) / 'summary.json'
            try:
                log = json.loads(path.read_text(encoding='utf-8'))
            except (OSError, json.JSONDecodeError):
                time.sleep(10)
                continue
            status = log.get('status')
            if status in ('PASS', 'FAIL'):
                return status, current, log
            seen = current
        time.sleep(20)
    return 'TIMEOUT', seen, {}


def accepted(row):
    """A group-build row bitstream-eligible: routed, in budget, packed."""
    return (row.get('route') == 'PASS' and row.get('under_budget')
            and bool(row.get('bitstream')))


def build_dirs(evidence_dir):
    """Group-build evidence directories to program, newest answer per group.

    integrate.py stamps each shard gb<first-group>, but a group rebuilt on its
    own (build.py --groups 3 --stamp X) lives in a differently-named directory,
    so membership is decided by directory mtime against the run's start, not by
    the name. Directories are then ordered newest-first because remote_board.py
    keeps the first row it sees per group: without that order a per-group rebuild
    would be shadowed by the shard's unaccepted or older row. remote_board.py
    still rejects a stale source hash or an unaccepted bitstream, so this only
    selects candidates.
    """
    run_stamp = Path(evidence_dir).name.split('integrate_', 1)[1]
    try:
        started = datetime.strptime(run_stamp, '%Y%m%dT%H%M%SZ').replace(
            tzinfo=timezone.utc).timestamp()
    except ValueError:
        started = os.path.getmtime(evidence_dir)
    candidates = []
    for path in glob.glob(str(ROOT / 'evidence' / 'build_*')):
        summary = Path(path) / 'summary.json'
        if not summary.is_file() or os.path.getmtime(path) < started:
            continue
        try:
            rows = json.loads(summary.read_text(encoding='utf-8')).get('groups') or []
        except (OSError, json.JSONDecodeError):
            continue
        if any(accepted(row) for row in rows):
            candidates.append((os.path.getmtime(path), path))
    candidates.sort(reverse=True)
    dirs, claimed = [], set()
    for _, path in candidates:
        rows = json.loads((Path(path) / 'summary.json')
                          .read_text(encoding='utf-8')).get('groups') or []
        gained = {row['group'] for row in rows if accepted(row)} - claimed
        if gained:
            claimed |= gained
            dirs.append(path)
    return dirs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--wait', type=int, default=6 * 3600, help='seconds to wait for integration')
    ap.add_argument('--groups', help='comma list, default every group the build accepted')
    ap.add_argument('--dry-run', action='store_true', help='resolve everything, program nothing')
    args = ap.parse_args()

    status, evidence, log = wait_for_integration(args.wait)
    print(f'integration {status} evidence={evidence}', flush=True)
    if status != 'PASS':
        print('refusing to program: ' + str(log.get('reason', 'integration not finished'))[:400],
              flush=True)
        return 1
    dirs = build_dirs(evidence)
    if not dirs:
        print('refusing to program: no group-build evidence in ' + evidence, flush=True)
        return 1
    argv = [sys.executable, 'remote_board.py', '--build', *dirs]
    if args.groups:
        argv += ['--groups', args.groups]
    print('$ ' + ' '.join(argv), flush=True)
    if args.dry_run:
        return 0
    proc = subprocess.run(argv, cwd=TOOLS, env={**os.environ, 'PYTHONUNBUFFERED': '1'})
    print(f'board exit={proc.returncode}', flush=True)
    return proc.returncode


if __name__ == '__main__':
    raise SystemExit(main())
