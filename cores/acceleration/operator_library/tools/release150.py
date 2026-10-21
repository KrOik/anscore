"""Run the 150-core release integration as resumable stages.

deal -> generate -> board -> selftest -> verify

Each stage is a subprocess of the existing tools, so this script adds no new
semantics: it only sequences them, stops on the first failure with the failing
command and its tail of output, and records where it got to. Use --from to
resume after fixing whatever a stage complained about.

Synthesis, place-and-route and board programming are deliberately NOT here: they
need a decision between stages (an oversized core, an unroutable group), so they
stay interactive.
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import catalog
from groups import ROOT

STAGES = ['deal', 'generate', 'board', 'selftest', 'verify']


def run(argv, timeout):
    print('$ ' + ' '.join(argv), flush=True)
    proc = subprocess.run([sys.executable, *argv], cwd=ROOT / 'tools',
                          capture_output=True, text=True, timeout=timeout)
    text = proc.stdout + proc.stderr
    tail = [line for line in text.splitlines() if line.strip()][-12:]
    for line in tail:
        print('  ' + line, flush=True)
    if proc.returncode:
        raise RuntimeError(f'{argv[0]} {" ".join(argv[1:])} exit={proc.returncode}')
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from', dest='start', default='deal', choices=STAGES)
    ap.add_argument('--only', choices=STAGES)
    ap.add_argument('--timeout', type=int, default=7200, help='seconds per stage')
    args = ap.parse_args()
    stages = [args.only] if args.only else STAGES[STAGES.index(args.start):]
    log = dict(timestamp=datetime.now(timezone.utc).isoformat(),
               cores=len(catalog.CORES), families=catalog.LOADED_FAMILIES,
               missing=catalog.MISSING_FAMILIES, stages=[])
    out = ROOT / 'evidence' / ('release_' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S') + '.json')
    failed = None
    for stage in stages:
        print(f'=== {stage} ===', flush=True)
        try:
            if stage == 'deal' and len(catalog.CORES) != 150:
                raise RuntimeError(f'catalog holds {len(catalog.CORES)} cores; every '
                                   f'family must load before dealing')
            if stage == 'deal':
                run(['deal.py'], args.timeout)
                run(['deal.py', '--write'], args.timeout)
            elif stage == 'generate':
                run(['generate.py'], args.timeout)
            elif stage == 'board':
                run(['generate_board.py'], args.timeout)
            elif stage == 'selftest':
                run(['model_selftest.py'], args.timeout)
            elif stage == 'verify':
                run(['verify.py', '--board', '--uart', '--mutations', '--tag', 'sim150'],
                    args.timeout)
            log['stages'].append(dict(stage=stage, status='PASS'))
        except Exception as exc:
            log['stages'].append(dict(stage=stage, status='FAIL', reason=str(exc)[:400]))
            failed = stage
            break
        finally:
            out.write_text(json.dumps(log, indent=2) + '\n', encoding='utf-8')
    print(f'{"FAILED at " + failed if failed else "ALL STAGES PASS"}; log={out}', flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
