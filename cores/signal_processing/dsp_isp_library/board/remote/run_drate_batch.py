"""Hold .boardlock while running a serial batch of drate board rounds.

Each entry is PROGRAM+CAPTURE+VERIFY for one dsp_rate_harness build, then a
second reprogram/retest round (_02_reprogram).  Board access is strictly
serial; the lock file is released (and archived to .boardlock_released.json)
at the end even on failure.

    python run_drate_batch.py --spec batch.json

batch.json: {"session": "...", "rounds": [{"build": "...",
             "output": "..."}, ...]}
"""
import argparse, json, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]
ROOT = LIB.parents[1]
sys.path.insert(0, str(LIB / 'board'))
from board_lock import BoardLock

RUN_BOARD = HERE / 'run_board_remote.py'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--spec', type=Path, required=True)
    a = p.parse_args()
    spec = json.loads(a.spec.read_text())
    rounds = spec['rounds']
    results = []
    lock = BoardLock(purpose=spec.get('session', 'drate_adapter_verification'),
                     output='batch')
    with lock:
        for entry in rounds:
            build = str(Path(entry['build']).resolve())
            out = str(Path(entry['output']).resolve())
            cmd = [sys.executable, str(RUN_BOARD), '--build', build,
                   '--output', out]
            print('+', ' '.join(cmd), flush=True)
            r = subprocess.run(cmd)
            verdict = {}
            try:
                verdict = json.loads(
                    (Path(out) / 'verdict.json').read_text())
            except Exception as exc:
                verdict = {'status': 'NO_VERDICT', 'error': repr(exc)}
            results.append(dict(build=build, output=out,
                                rc=r.returncode,
                                status=verdict.get('status')))
            print('  ->', verdict.get('status'), flush=True)
            if verdict.get('status') != 'PASS':
                break  # stop the batch on first failure
    released = dict(session=spec.get('session'), owner='devin',
                    board='Tang_Primer_20K_Dock',
                    released_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',
                                              time.gmtime()),
                    purpose=spec.get('session'),
                    results=results)
    (ROOT / '.boardlock_released.json').write_text(
        json.dumps(released, indent=2))
    print(json.dumps(results, indent=2))
    return 0 if all(r['status'] == 'PASS' for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
