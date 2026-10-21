"""Run the 25K dock ROM-stimulus sweep: build, load, capture, grade, twice.

    python sweep_rom_25k.py                      # every in-scope core
    python sweep_rom_25k.py --only biquad lms    # a subset
    python sweep_rom_25k.py --no-board           # build/gate only

In scope means the core is board-verified on the 20K (its requirement carries
``board_injection`` evidence) *and* the harness family has a 25K build path here.
Cores that only ever passed simulation, and the RMII/UDP rate path (the dock has
no Ethernet PHY wired to the fabric), are excluded by construction.

Each core is built and simulated by build_rom_25k.py, then run_25k.py programs the
25K over JTAG and captures the report stream for --rounds separate loads, so a PASS
means two independent SRAM images produced protocol-exact reports.  Everything is
recorded per core under artifacts/ds25k_board_<date>/ and summarised in
evidence/rom_sweep_<stamp>.json; a core that fails does not stop the sweep.
"""
import argparse, datetime, json, shutil, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent                    # board/tang25k/harness
BOARD = HERE.parents[1]                                   # board
LIB = BOARD.parent                                        # dsp_isp_library
ROOT = LIB.parents[1]
sys.path.insert(0, str(HERE))

import build_rom_25k                                     # noqa: E402
import rom_board_scope                                   # noqa: E402

# The board round imports these from the staged dir to grade with the same code the
# simulation used, so a reused build must still carry the current copies.
GRADER_FILES = ['build_rom_25k.py', 'rom_stim_25k.py', 'device_flow.py']


def restage_grader(dest):
    src = {'device_flow.py': HERE.parent}
    for name in GRADER_FILES:
        base = src.get(name, HERE)
        if (base / name).exists():
            shutil.copy2(base / name, dest / name)


def sh(cmd, log):
    with log.open('w', encoding='utf-8') as f:
        f.write('$ ' + ' '.join(str(c) for c in cmd) + '\n')
        f.flush()
        r = subprocess.run([str(c) for c in cmd], stdout=f,
                           stderr=subprocess.STDOUT, cwd=str(HERE))
    return r.returncode


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--only', nargs='*', default=None)
    p.add_argument('--rounds', type=int, default=2)
    p.add_argument('--no-board', action='store_true')
    p.add_argument('--skip-built', action='store_true',
                   help='reuse an existing build_25k_summary.json instead of '
                        're-simulating; this is the board-only phase')
    p.add_argument('--bits', type=int, default=8)
    p.add_argument('--date', default=datetime.date.today().strftime('%Y%m%d'))
    a = p.parse_args()

    scope = rom_board_scope.in_scope(a.bits)
    if a.only:
        scope = [s for s in scope if s['core'] in a.only]
    out_root = ROOT / 'artifacts' / ('ds25k_board_%s' % a.date)
    out_root.mkdir(parents=True, exist_ok=True)
    report = dict(started_at=datetime.datetime.now().isoformat(),
                  rounds=a.rounds, out_root=str(out_root), cores=[])
    for s in scope:
        fam, core = s['family'], s['core']
        dest = HERE / 'evidence' / ('%s_rom' % core)
        row = dict(family=fam, core=core, requirement=s['requirement'],
                   build='FAIL', board='SKIPPED', dest=str(dest))
        report['cores'].append(row)
        dest.mkdir(parents=True, exist_ok=True)
        if a.skip_built and (dest / 'build_25k_summary.json').exists():
            row['build'] = 'REUSED'
        else:
            sh([sys.executable, 'build_rom_25k.py', '--family', fam,
                '--core', core, '--bits', a.bits, '--build',
                '--dest', 'evidence/%s_rom' % core],
               dest.parent / ('%s_build.log' % core))
            if not (dest / 'build_25k_summary.json').exists():
                print('%s %s: BUILD FAILED (see %s)' % (fam, core, core), flush=True)
                continue
            row['build'] = 'PASS'
        row['build_25k'] = json.loads(
            (dest / 'build_25k_summary.json').read_text())
        restage_grader(dest)
        if a.no_board:
            print('%s %s: BUILD PASS %s' % (fam, core, row['build_25k'].get('lut4')),
                  flush=True)
            continue
        out = out_root / core
        code = sh([sys.executable, str(BOARD / 'remote' / 'run_25k.py'),
                   '--build', dest, '--mode', 'rom',
                   '--image', build_rom_25k.FAMS[fam]['image'],
                   '--out', out, '--rounds', a.rounds, '--bits', a.bits],
                  dest.parent / ('%s_board.log' % core))
        vj = out / 'verdict.json'
        row['board'] = ('PASS' if code == 0 and vj.exists()
                        and json.loads(vj.read_text())['status'] == 'PASS'
                        else 'FAIL')
        row['board_out'] = str(out)
        print('%s %s: build=%s board=%s' % (fam, core, row['build'], row['board']),
              flush=True)
        (HERE / 'evidence' / ('rom_sweep_%s.json' % a.date)).write_text(
            json.dumps(report, indent=2) + '\n')
    (HERE / 'evidence' / ('rom_sweep_%s.json' % a.date)).write_text(
        json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(cores=[dict(core=r['core'], build=r['build'],
                                      board=r['board']) for r in report['cores']]),
                     indent=2))
    return 0 if all(r['board'] in ('PASS', 'SKIPPED') for r in report['cores']) else 1


if __name__ == '__main__':
    sys.exit(main())
