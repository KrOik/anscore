"""Offline regression for atomic command admission (no board access)."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def main():
    out = ROOT / 'artifacts/lockin_dsp_25k' / datetime.now(timezone.utc).strftime('config_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    sources = [ROOT / p for p in [
        'cores/system/stream_bus_library/rtl/sys_atomic_config.v',
        'cores/signal_processing/lockin/rtl/lockin_config.v',
        'cores/signal_processing/lockin/tb/tb_lockin_config.v']]
    report = dict(status='FAIL', physical_measurement=False,
                  sources={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sources + [Path(__file__).resolve()]})
    try:
        exe = out / 'test.vvp'
        for name, cmd in [('compile', ['iverilog', '-g2012', '-s', 'tb_lockin_config', '-o', str(exe)] + list(map(str, sources))),
                          ('run', ['vvp', str(exe)])]:
            r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=30)
            (out / (name + '.log')).write_text(r.stdout + r.stderr)
            if r.returncode or (name == 'run' and 'PASS atomic lockin config' not in r.stdout):
                raise RuntimeError(r.stdout + r.stderr)
        report['status'] = 'PASS'
        print('PASS atomic configuration and exactly-once admission')
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
