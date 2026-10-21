"""Runs ON the rig host (bianbu): per-case UART inject + report read + verify
for Tang Primer 25K (GW5A) dsp_isp_library harness images.

Transport is the dock's own USB serial console (/dev/ttyUSB1: FPGA TX pad C3,
host TX to pad B3), not the FX2 logic analyzer: the 25K dock's FPGA UART is
wired to the onboard SIPEED USB debugger, so the reply is read back through the
same link the request went in on.  That is a stricter end-to-end check than
sniffing a mirror pin.

The build directory is the harness's own evidence dir, frozen: it carries
protocol.py plus the bit-exact model it imports, so every reply is checked
against the independent oracle and never against anything read from the DUT.

All three harness report magics share one 20-byte header:
    magic(4) tag(4LE) config(4LE) in_count(1) flags(1) inc(1) outc(1) cycles(4LE)
so the reply length is 20 + 4*outc regardless of RES1/RES2/IMR1.

    python3 board_case_25k.py --build . --out round_01 --mode dstream
"""
import argparse, hashlib, importlib.util, json, secrets, struct, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

import serial

HEADER = struct.Struct('<4sIIBBBBI')


def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def load_protocol(build):
    spec = importlib.util.spec_from_file_location('frozen_protocol',
                                                 build / 'protocol.py')
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(build))
    spec.loader.exec_module(mod)
    return mod


def read_report(port, timeout):
    """Read one header, then exactly the payload the header declares."""
    deadline = time.monotonic() + timeout
    buf = bytearray()
    while len(buf) < HEADER.size and time.monotonic() < deadline:
        chunk = port.read(HEADER.size - len(buf))
        if chunk:
            buf += chunk
    if len(buf) < HEADER.size:
        return bytes(buf), None
    magic, tag, config, n, flags, inc, outc, cycles = HEADER.unpack(buf[:20])
    total = 20 + 4 * outc
    while len(buf) < total and time.monotonic() < deadline:
        chunk = port.read(min(64, total - len(buf)))
        if chunk:
            buf += chunk
    return bytes(buf), total


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--build', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--mode', required=True, choices=['dstream', 'drate', 'isp'])
    p.add_argument('--image', default='design_25k.fs')
    p.add_argument('--board', default='tangprimer25k')
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--bits', type=int, default=8)
    p.add_argument('--padding', type=int, default=1)
    p.add_argument('--timeout', type=float, default=8.0)
    p.add_argument('--attempts', type=int, default=3)
    p.add_argument('--limit', type=int, default=0, help='first N cases only')
    p.add_argument('--no-program', action='store_true',
                   help='assume the image is already in SRAM')
    a = p.parse_args()

    build = a.build.resolve()
    out = a.out.resolve()
    (out / 'cases').mkdir(parents=True, exist_ok=True)
    pr = load_protocol(build)
    image = build / a.image
    verdict = dict(status='FAIL', started_at=now_iso(), mode=a.mode,
                   image=str(image), sha256=hashlib.sha256(image.read_bytes())
                   .hexdigest(), board=a.board, uart=a.uart, baud=a.baud,
                   build_simulation=json.loads(
                       (build / 'simulation_summary.json').read_text())
                   if (build / 'simulation_summary.json').exists() else {},
                   cases=[])
    if (build / 'build_25k_summary.json').exists():
        verdict['build_25k'] = json.loads(
            (build / 'build_25k_summary.json').read_text())

    try:
        if not a.no_program:
            with (out / 'program.log').open('w') as log:
                r = subprocess.run(['openFPGALoader', '-b', a.board, str(image)],
                                   stdout=log, stderr=subprocess.STDOUT,
                                   timeout=300)
            if r.returncode:
                raise RuntimeError('Programming failed; SRAM state unconfirmed')
            verdict['sram_programmed'] = True
            time.sleep(1.0)

        if a.mode == 'isp':
            core = pr._core()
            work = [(t, c, w, s) for (t, c, w, s) in pr.cases(a.bits, core=core)]

            def call_verify(d, t, c, w, s):
                return pr.verify(d, t, c, w, a.bits, s, a.padding, core=core)

            def call_oracle(c, w):
                return None
        else:
            work = list(pr.cases())
            if a.mode == 'dstream':
                def call_verify(d, t, c, w, s):
                    return pr.verify(d, t, c, w, s)
            else:
                def call_verify(d, t, c, w, s):
                    return pr.verify(d, t, c, w, s)

            def call_oracle(c, w):
                return pr.oracle(c, w)
        if a.limit:
            work = work[:a.limit]
        verdict['case_count'] = len(work)

        with serial.Serial(a.uart, a.baud, timeout=0.05, write_timeout=5) as port:
            port.reset_input_buffer()
            for index, (_, config, words, stall) in enumerate(work):
                tag = secrets.randbits(32)
                packet = pr.make_packet(tag, config, words, stall)
                rec = dict(name='%s%02d' % (a.mode, index), tag='%08x' % tag,
                           config=config, stall=stall, words=len(words),
                           ok=False, attempts=0)
                report = b''
                for attempt in range(a.attempts):
                    rec['attempts'] = attempt + 1
                    port.reset_input_buffer()
                    t0 = time.monotonic()
                    for byte in packet:
                        port.write(bytes([byte]))
                        port.flush()
                        time.sleep(0.0015)      # T15: byte gap is mandatory
                    report, want = read_report(port, a.timeout)
                    rec['elapsed_ms'] = int((time.monotonic() - t0) * 1e3)
                    if want and len(report) == want:
                        break
                folder = out / 'cases' / ('%02d' % index)
                folder.mkdir(exist_ok=True)
                (folder / 'request.bin').write_bytes(packet)
                (folder / 'report.bin').write_bytes(report)
                exp = call_oracle(config, words)
                if exp is not None:
                    (folder / 'expected.json').write_text(json.dumps(dict(
                        tag=tag, config=config, words=words, stall=stall,
                        outputs=exp), indent=2))
                if want is None or len(report) != want:
                    rec['error'] = 'reply length %d of %s' % (len(report), want)
                    verdict['cases'].append(rec)
                    print('%s %s -> FAIL %s' % (now_iso(), rec['name'],
                                                rec['error']), flush=True)
                    continue
                try:
                    res = call_verify(report, tag, config, words, stall)
                    mut = bytearray(report)
                    mut[HEADER.size] ^= 0x01
                    try:
                        call_verify(bytes(mut), tag, config, words, stall)
                    except AssertionError:
                        rec['negative_check'] = 'PASS'
                    else:
                        raise RuntimeError('checker accepted a corrupted reply')
                    rec.update(ok=True, **{k: v for k, v in res.items()
                                           if k != 'status'})
                except AssertionError as exc:
                    rec['error'] = 'verify: %r' % (exc.args,)
                verdict['cases'].append(rec)
                (folder / 'verdict.json').write_text(json.dumps(rec, indent=2))
                print('%s %s -> %s %s' % (now_iso(), rec['name'],
                                          'PASS' if rec['ok'] else 'FAIL',
                                          rec.get('error', '')), flush=True)
        verdict['passed'] = sum(1 for c in verdict['cases'] if c['ok'])
        verdict['failed'] = len(verdict['cases']) - verdict['passed']
        verdict['status'] = ('PASS' if verdict['cases'] and verdict['passed']
                             == len(verdict['cases']) else 'FAIL')
    except Exception as exc:
        verdict['error'] = repr(exc)
    verdict['finished_at'] = now_iso()
    (out / 'verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(dict(status=verdict['status'], passed=verdict.get('passed'),
                          failed=verdict.get('failed'),
                          error=verdict.get('error', ''))))
    return 0 if verdict['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
