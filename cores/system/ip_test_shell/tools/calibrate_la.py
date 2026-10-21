"""Two real FPGA frequency signatures establish channel-to-pin mapping."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pins', required=True, help='Eight expected pins ordered CH0..7')
    ap.add_argument('--board', choices=('primer25k', 'primer20k'), default='primer25k')
    ap.add_argument('--coexist', action='store_true', help='detect JTAG during a separate live LA capture')
    a = ap.parse_args()
    is20 = a.board == 'primer20k'
    cable = ['-c', 'cmsisdap'] if is20 else ['-b', 'tangprimer25k']
    expected_id = '0x81b' if is20 else '0x1281b'
    family = 'GW2A-18' if is20 else 'GW5A-25A'
    device = 'GW2A-LV18PG256C8/I7' if is20 else 'GW5A-LV25MG121NES'
    clock_mhz = 27 if is20 else 50
    pins = a.pins.split(',')
    if len(pins) != 8 or len(set(pins)) != 8:
        raise ValueError('eight unique pins required')
    out = ROOT / 'artifacts' / datetime.now(timezone.utc).strftime(('tang20k' if is20 else 'tang25k') + '_la_calibration_%Y%m%dT%H%M%S%fZ')
    out.mkdir()
    baseline = ROOT / 'artifacts/tang25k_la_calibration_20261020_set2'
    for name in ('probe.v', 'tb.v'):
        shutil.copyfile(baseline / name, out / name)
    analysis = (baseline / 'analyze.py').read_text()
    analysis = analysis.replace("pins = ['A10', 'A11', 'E10', 'E11', 'L11', 'K11', 'K5', 'L5']", 'pins = ' + repr(pins))
    if is20:
        analysis = analysis.replace('50e6', '27e6').replace("device='GW5A-25', idcode='0x0001281b'", "device='GW2A-18', idcode='0x0000081b'")
    (out / 'analyze.py').write_text(analysis)
    lines = ['IO_LOC "clk" ' + ('H11' if is20 else 'E2') + ';', 'IO_PORT "clk" IO_TYPE=LVCMOS33 PULL_MODE=NONE;']
    for i, pin in enumerate(pins):
        lines += [f'IO_LOC "probe_out[{i}]" {pin};', f'IO_PORT "probe_out[{i}]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4;']
    (out / 'probe.cst').write_text('\n'.join(lines) + '\n')
    report = {'status': 'IN_PROGRESS', 'board': a.board, 'device': device,
              'clock_hz': clock_mhz * 1000000, 'expected_pins': pins, 'modes': []}
    def run(name, command):
        with (out / (name + '.log')).open('w') as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(name + ' failed; see ' + str(out / (name + '.log')))
    try:
        rel = lambda p: p.relative_to(ROOT).as_posix()
        run('detect', ['openFPGALoader'] + cable + ['--detect'])
        if expected_id not in (out / 'detect.log').read_text():
            raise RuntimeError('unexpected FPGA device')
        run('compile', ['iverilog', '-g2012', '-s', 'tb', '-o', str(out / 'test.vvp'), str(out / 'probe.v'), str(out / 'tb.v')])
        run('sim', ['vvp', str(out / 'test.vvp')])
        for reverse, mode in enumerate(('forward', 'reverse')):
            net, routed, fs = [out / (mode + suffix) for suffix in ('.json', '.pnr.json', '.fs')]
            ys = f'read_verilog {rel(out / "probe.v")}; chparam -set REVERSE {reverse} probe; synth_gowin -family {"gw2a" if is20 else "gw5a"} -top probe -json {rel(net)}; stat'
            run(mode + '_synth', ['yosys', '-Q', '-p', ys])
            run(mode + '_pnr', ['nextpnr-himbaechel', '--json', str(net), '--write', str(routed), '--device',
                               device, '--freq', str(clock_mhz), '--vopt', 'family=' + family,
                               '--vopt', 'cst=' + str(out / 'probe.cst')] + ([] if is20 else ['--vopt', 'sspi_as_gpio']))
            pack = Path(os.environ['OSS_CAD_PYTHON']).parent.parent / 'bin/gowin_pack-script.py'
            run(mode + '_pack', [os.environ['OSS_CAD_PYTHON'], str(pack), '-d', family] + ([] if is20 else ['--sspi_as_gpio']) + ['-o', str(fs), str(routed)])
            run(mode + '_program', ['openFPGALoader'] + cable + [str(fs)])
            run(mode + '_capture', [sys.executable, str(ROOT / 'host/capture_fx2_async.py'), str(out / ('capture_' + mode + '.bin')),
                                    '--rate', '2000000', '--samples', '400000'])
            report['modes'].append({'mode': mode, 'bitstream_sha256': hashlib.sha256(fs.read_bytes()).hexdigest()})
        run('analysis', [sys.executable, str(out / 'analyze.py')])
        measured = json.loads((out / 'channel_map.json').read_text())
        report['status'] = 'PASS' if measured['passed'] else 'FAIL'
        if a.coexist:
            with (out / 'coexist_capture.log').open('w') as log:
                proc = subprocess.Popen([sys.executable, str(ROOT / 'host/capture_fx2_async.py'),
                    str(out / 'capture_coexist.bin'), '--rate', '2000000', '--samples', '2000000'],
                    cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
                try:
                    time.sleep(.35)
                    before = proc.poll() is None
                    run('coexist_detect', ['openFPGALoader'] + cable + ['--detect'])
                    after = proc.poll() is None
                    capture_exit = proc.wait(timeout=20)
                finally:
                    if proc.poll() is None:
                        proc.kill(); proc.wait()
            raw = (out / 'capture_coexist.bin').read_bytes()
            edges = [sum(((x ^ y) >> i) & 1 for x, y in zip(raw, raw[1:])) for i in range(8)]
            passed = before and after and capture_exit == 0 and len(raw) == 2000000 and min(edges) > 20 and expected_id in (out / 'coexist_detect.log').read_text()
            report['coexist'] = {'passed': passed, 'capture_live_before_detect': before,
                'capture_live_after_detect': after, 'capture_exit': capture_exit,
                'samples': len(raw), 'channel_edges': edges,
                'bitstream_sha256': report['modes'][-1]['bitstream_sha256'],
                'capture_sha256': hashlib.sha256(raw).hexdigest()}
            if not passed:
                raise RuntimeError('JTAG/LA coexistence evidence failed')
        print(json.dumps(measured['channels'], indent=2))
    except Exception as exc:
        report['status'] = 'FAIL'; report['reason'] = str(exc); raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out), flush=True)


if __name__ == '__main__':
    main()
