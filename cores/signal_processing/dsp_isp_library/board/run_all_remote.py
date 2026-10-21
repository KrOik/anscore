"""Sequential remote board qualification for the generic harnesses.

Takes the repo .boardlock, then runs each built evidence dir through
run_board_remote.py one at a time (the board is exclusive).  Releases the
lock when done.  Every output lands in a fresh artifacts dir.

    python board/run_all_remote.py --plan board/plan.json
"""
import argparse, json, os, secrets, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parent            # cores/signal_processing/dsp_isp_library
ROOT = LIB.parents[1]        # repo root (D:\sipeedTANG20K)
LOCK = ROOT / '.boardlock'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--plan', type=Path, required=True,
                   help='JSON: [{build, out}] remote runs in order')
    a = p.parse_args()
    plan = json.loads(a.plan.read_text())
    if LOCK.exists():
        print('board lock exists - refusing to start', LOCK)
        sys.exit(2)
    lock = dict(pid=os.getpid(), token=secrets.token_hex(16),
                purpose='dsp_isp generic harness board qualification',
                acquired_at=time.time())
    LOCK.write_text(json.dumps(lock, indent=2))
    results = []
    try:
        for entry in plan:
            build = str((ROOT / entry['build']).resolve())
            outdir = str((ROOT / entry['out']).resolve())
            print(f'=== remote run {build} -> {outdir}', flush=True)
            r = subprocess.run(
                [sys.executable,
                 str(HERE / 'remote/run_board_remote.py'),
                 '--build', build, '--output', outdir],
                 cwd=ROOT)
            verdict = {}
            vj = Path(outdir) / 'verdict.json'
            if vj.exists():
                verdict = json.loads(vj.read_text())
            results.append(dict(build=build, out=outdir, rc=r.returncode,
                                verdict_status=verdict.get('status'),
                                sha256=verdict.get('sha256'),
                                image=verdict.get('image')))
            print(f'   rc={r.returncode} verdict={verdict.get("status")}',
                  flush=True)
    finally:
        LOCK.unlink(missing_ok=True)
        (ROOT / '.boardlock_released.json').write_text(json.dumps(
            dict(released_at=time.time(), token=lock['token']), indent=2))
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
