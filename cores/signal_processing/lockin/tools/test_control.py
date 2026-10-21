"""Real CSR->atomic configuration->ADC->lock-in, independently checked IQ."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/signal_processing/lockin'


def main():
    out = ROOT / 'artifacts/lockin_dsp_25k' / datetime.now(timezone.utc).strftime('control_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    sources = sorted((P / 'rtl').glob('*.v')) + [P / 'tb/tb_lockin_control.v'] + [ROOT / p for p in [
        'cores/system/stream_bus_library/rtl/sys_atomic_config.v',
        'cores/system/stream_bus_library/rtl/sys_timestamp64.v',
        'cores/signal_processing/dsp/src/dds_nco.v', 'cores/signal_processing/dsp/src/cordic.v']]
    report = dict(status='FAIL', physical_measurement=False, sources={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in sources + [Path(__file__).resolve(), P / 'vectors/sine.mem', P / 'vectors/cosine.mem']})
    try:
        exe = out / 'test.vvp'
        cmd = ['iverilog', '-g2012', '-s', 'tb_lockin_control',
               '-Ptb_lockin_control.SIN_FILE="' + (P / 'vectors/sine.mem').as_posix() + '"',
               '-Ptb_lockin_control.COS_FILE="' + (P / 'vectors/cosine.mem').as_posix() + '"',
               '-o', str(exe)] + list(map(str, sources))
        for name, command in [('compile', cmd), ('run', ['vvp', str(exe)])]:
            r = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=60)
            (out / (name + '.log')).write_text(r.stdout + r.stderr)
            if r.returncode:
                raise RuntimeError(r.stdout + r.stderr)
        if 'PASS CSR atomic' not in r.stdout:
            raise RuntimeError('missing completion')
        # Derive ideal ROM values independently; do not use DUT output as golden.
        import math
        cos = [round(32767 * math.cos(2 * math.pi * n / 256)) for n in range(256)]
        sin = [round(32767 * math.sin(2 * math.pi * n / 256)) for n in range(256)]
        expected = []
        for amplitude, phase in zip([1000, 4000, 12000, 24000], [0, 32, 192, 96]):
            x = [amplitude * cos[(n + phase) % 256] >> 15 for n in range(256)]
            expected.append((sum(a*b for a, b in zip(x, cos)) >> 23,
                             -sum(a*b for a, b in zip(x, sin)) >> 23))
        rows = re.findall(r'CSR_IQ run=(\d+) lane=(\d+) i=(-?\d+) q=(-?\d+)', r.stdout)
        if {(int(run), int(lane)) for run, lane, _, _ in rows} != {(run, lane) for run in [100, 101] for lane in range(4)} or len(rows) != 8:
            raise RuntimeError('missing channel readback')
        for run, lane, i, q in rows:
            if (int(i), int(q)) != expected[int(lane)]:
                raise RuntimeError('CSR IQ differs from independent reference')
        polar = re.findall(r'CSR_POLAR run=(\d+) lane=(\d+) amplitude=(\d+) phase=(-?\d+)', r.stdout)
        if len(polar) != 8:
            raise RuntimeError('missing polar results')
        amp_errors, phase_errors = [], []
        for run, lane, amplitude, phase in polar:
            lane = int(lane)
            amp_errors.append(abs(int(amplitude) - [1000, 4000, 12000, 24000][lane]))
            target = [0, math.pi/4, -math.pi/2, 3*math.pi/4][lane]
            phase_errors.append(abs((int(phase)/16384 - target + math.pi) % (2*math.pi) - math.pi))
        if max(amp_errors) > 12 or max(phase_errors) > .06:
            raise RuntimeError('polar readback exceeds existing numeric limits')
        report.update(status='PASS', successful_runs=2, error_runs=1, exact_iq_pairs=8,
                      max_amplitude_error=max(amp_errors), max_phase_error_rad=max(phase_errors))
        print('PASS real CSR replay: queued runs,8 exact IQ pairs,timeout,guards,held results')
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
