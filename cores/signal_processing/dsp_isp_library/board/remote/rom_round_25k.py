"""Runs ON the rig host (bianbu): one 25K board round of the ROM-stimulus harness.

The dock's USB-UART bridge cannot drive the FPGA RX pad, so this image emits its own
BLK1/IMG1 packets from an on-chip case ROM (see board/tang25k/harness/stim_25k.v) and
the only direction that carries evidence is FPGA -> host.  A round is therefore:
open the console, drain whatever the bridge backlogged, load the image into SRAM over
JTAG, and read the report stream until every declared report is in.

Pass/fail never comes from the DUT.  rom_cases_25k.json carries the descriptors the
frozen protocol.cases() produced for this core; build_rom_25k.py's grade() runs that
protocol's verify() against them (plus a flipped-bit rejection check), and the input
words are the same LFSR sequence the RTL was compared against byte-for-byte in
simulation.  report_sha256 per case lets two rounds be compared for silicon
determinism.

    python3 rom_round_25k.py --build . --out round_01 --image dstream_25k.fs
"""
import argparse, hashlib, importlib.util, json, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

import serial


def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def listen(port, want, timeout):
    """Read until ``want`` bytes or silence; then a short tail drain."""
    buf = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        chunk = port.read(256)
        if chunk:
            buf += chunk
            if len(buf) >= want:
                break
    end = time.monotonic() + 0.4
    while time.monotonic() < end:
        chunk = port.read(256)
        if chunk:
            buf += chunk
    return bytes(buf)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--build', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--image', default='design_25k.fs')
    p.add_argument('--board', default='tangprimer25k')
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--timeout', type=float, default=30.0)
    p.add_argument('--attempts', type=int, default=3)
    p.add_argument('--no-program', action='store_true',
                   help='assume the image is already in SRAM')
    a = p.parse_args()

    build = a.build.resolve()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(build))
    bm = load(build / 'build_rom_25k.py', 'rom_build_shared')
    cases = json.loads((build / 'rom_cases_25k.json').read_text())
    pr = load(build / 'protocol.py', 'frozen_protocol')
    descs, all_words = cases['cases'], cases['words']
    # Report geometry comes off the descriptor: the DC -> statistics chain emits 17
    # bytes per result, and builds staged before that key existed are 32-bit-word
    # harnesses, which is the default.
    want = sum(20 + (d.get('report_bpe', 4) * d['count']
                     if d['kind'] == 'case' else 0) for d in descs)
    image = build / a.image
    verdict = dict(status='FAIL', started_at=now_iso(), mode='rom',
                   family=cases['family'], core=cases['core'],
                   core_name=cases['core_name'], stimulus='rom',
                   image=str(image),
                   sha256=hashlib.sha256(image.read_bytes()).hexdigest(),
                   board=a.board, uart=a.uart, baud=a.baud,
                   case_count=len(descs), expected_bytes=want, rounds=[])
    if (build / 'build_25k_summary.json').exists():
        verdict['build_25k'] = json.loads(
            (build / 'build_25k_summary.json').read_text())
    if (build / 'simulation_summary.json').exists():
        verdict['simulation'] = json.loads(
            (build / 'simulation_summary.json').read_text())

    try:
        raw = b''
        for attempt in range(1, a.attempts + 1):
            rec = dict(attempt=attempt)
            ser = serial.Serial()
            ser.port = a.uart
            ser.baudrate = a.baud
            ser.timeout = 0.05
            ser.xonxoff = ser.rtscts = ser.dsrdtr = False
            ser.open()
            ser.dtr = False
            ser.rts = False
            ser.reset_input_buffer()
            listen(ser, 1, 0.5)               # drop bridge backlog before the run
            ser.reset_input_buffer()
            if not a.no_program:
                with (out / ('program_%02d.log' % attempt)).open('w') as log:
                    r = subprocess.run(
                        ['openFPGALoader', '-b', a.board, str(image)],
                        stdout=log, stderr=subprocess.STDOUT, timeout=300)
                rec['program_rc'] = r.returncode
                if r.returncode:
                    ser.close()
                    raise RuntimeError('Programming failed; SRAM state unconfirmed')
            t0 = time.monotonic()
            raw = listen(ser, want, a.timeout)
            ser.close()
            rec['elapsed_ms'] = int((time.monotonic() - t0) * 1e3)
            rec['captured_bytes'] = len(raw)
            reports, skipped, tail = bm.split_reports(raw, descs,
                                                      cases['report_magic'].encode())
            rows = bm.grade(cases['family'], pr, descs, all_words, reports,
                            cases['bits'], cases['padding'], cases['core'])
            for row, rep in zip(rows, reports):
                row['report_sha256'] = hashlib.sha256(rep).hexdigest()
            passed = sum(1 for row in rows if row['ok'])
            rec.update(resync_skipped=skipped, trailing_bytes=len(tail),
                       passed=passed, failed=len(rows) - passed, cases=rows)
            verdict['rounds'].append(rec)
            print('%s attempt %d -> %d/%d cases, %d of %d bytes'
                  % (now_iso(), attempt, passed, len(rows), len(raw), want),
                  flush=True)
            if passed == len(rows) and not skipped:
                break
        (out / 'raw.bin').write_bytes(raw)
        (out / 'raw.hex').write_text(
            '\n'.join('%02x' % b for b in raw) + '\n')
        good = [r for r in verdict['rounds']
                if r.get('passed') == verdict['case_count']
                and not r.get('resync_skipped')]
        best = good[-1] if good else verdict['rounds'][-1]
        verdict.update(status='PASS' if good else 'FAIL',
                       passed=best['passed'], failed=best['failed'],
                       cases=best['cases'], captured_bytes=best['captured_bytes'],
                       resync_skipped=best['resync_skipped'],
                       trailing_bytes=best['trailing_bytes'])
        # two attempts that report the same digests are the repeat the SOP asks for
        if len(verdict['rounds']) > 1:
            sigs = [tuple(r['report_sha256'] for r in c['cases'])
                    for c in verdict['rounds'] if c.get('cases')]
            verdict['repeat_identical'] = (len(set(sigs)) == 1)
    except Exception as exc:
        verdict['error'] = repr(exc)
    verdict['finished_at'] = now_iso()
    (out / 'verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(dict(status=verdict['status'], passed=verdict.get('passed'),
                          failed=verdict.get('failed'),
                          captured_bytes=verdict.get('captured_bytes'),
                          error=verdict.get('error', ''))))
    return 0 if verdict['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
