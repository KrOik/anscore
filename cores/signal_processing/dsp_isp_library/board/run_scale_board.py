"""Route-gated physical SCL1/SCR1 scaler qualification on Tang Primer 20K.

SRAM-programs the scale_harness build, injects SCL1 packets on the board
UART (COM port -> FT2232 -> T13), and reads the SCR1 response back on the
same COM port (M11 -> FT2232 -> host).  Board sharing is coordinated via
.boardlock at the repo root (see board_lock.py); the runner waits for the
lock instead of colliding with a concurrent session.

Usage:
    python run_scale_board.py --build <evidence/scale_*> --output <dir>
        [--port COM24] [--baud 115200] [--lock-timeout 300]
"""
import argparse, hashlib, json, os, secrets, subprocess, sys, time
from pathlib import Path
import serial
from probe_external import ROOT, HERE
from build_log_gate import assert_clean_build
from board_lock import BoardLock
sys.path.insert(0, str(HERE / 'scale_harness'))
from protocol import (cases, make_packet, oracle, verify, make_frame,
                      frame_to_words, HEADER_SIZE)
import random


def exchange(port, packet, nresp, folder, timeout=20):
    """Send packet at line rate, read exactly nresp bytes or timeout."""
    t0 = time.monotonic()
    view = memoryview(packet)
    pos = 0
    while pos < len(view):
        pos += port.write(view[pos:pos + 512])
        time.sleep(0.02)
    port.flush()
    sent_s = time.monotonic() - t0
    data = bytearray()
    t1 = time.monotonic()
    while len(data) < nresp and time.monotonic() - t1 < timeout:
        data += port.read(nresp - len(data))
    (folder / 'timing.json').write_text(json.dumps(dict(
        send_seconds=sent_s,
        response_seconds=time.monotonic() - t1), indent=2))
    return bytes(data)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--port', default='COM24')
    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--lock-timeout', type=float, default=300)
    a = p.parse_args()
    build = a.build.resolve()
    out = a.output.resolve()
    summary = json.loads((build / 'build_summary.json').read_text())
    assert_clean_build(build)
    sim = json.loads((build / 'simulation_summary.json').read_text())
    if sim['status'] != 'PASS':
        raise ValueError('simulation gate')
    for source, digest in json.loads(
            (build / 'hashes.json').read_text()).items():
        if hashlib.sha256(
                (build / Path(source).name).read_bytes()).hexdigest() != digest:
            raise ValueError('frozen source identity: ' + source)
    image = build / 'image.fs'
    sha = hashlib.sha256(image.read_bytes()).hexdigest()
    if (summary['status'] != 'BUILD_PASS_NOT_BOARD'
            or summary['bitstream_sha256'] != sha):
        raise ValueError('image identity/build gate')
    if summary['routed_lut4'] > 15000 or min(summary['fmax_mhz']) < 27:
        raise ValueError('resource/timing gate')
    out.mkdir(parents=True, exist_ok=True)
    verdict = dict(status='FAIL', image=str(image), sha256=sha,
                   baud=a.baud, cases=[])
    lock = BoardLock(purpose='poly6 scaler board qualification',
                     output=out, timeout=a.lock_timeout)
    try:
        lock.acquire()
        (out / 'boardlock.json').write_text(
            json.dumps(lock.owner, indent=2))
        with (out / 'program.log').open('w') as log:
            r = subprocess.run(
                ['pwsh', '-NoProfile', '-File',
                 str(HERE / 'program_probe.ps1'), '-Image', str(image)],
                stdout=log, stderr=subprocess.STDOUT, timeout=90)
        if r.returncode:
            raise RuntimeError('SRAM programming failed; image unconfirmed')
        verdict['sram_programmed'] = True
        rng = random.Random(20260925)
        with serial.Serial(a.port, a.baud, timeout=1,
                           write_timeout=60) as port:
            port.reset_input_buffer()
            (out / 'serial_before.bin').write_bytes(port.read(65536))
            for index, c in enumerate(cases()):
                dims = c['dims']
                folder = out / f'case_{index:02d}'
                folder.mkdir()
                tag = secrets.randbits(32)
                frame = make_frame(rng, dims[0], dims[1], c['kind'])
                words = frame_to_words(frame)
                packet = make_packet(tag, dims, words, c['stall'])
                nresp = HEADER_SIZE + 4 * dims[2] * dims[3]
                (folder / 'request.bin').write_bytes(packet)
                (folder / 'expected.json').write_text(json.dumps(dict(
                    tag=tag, dims=list(dims), stall=c['stall'],
                    kind=c['kind'], words=words,
                    outputs=oracle(dims, words)), indent=2))
                data = exchange(port, packet, nresp, folder)
                (folder / 'decoded.bin').write_bytes(data)
                result = verify(data, tag, dims, words, c['stall'])
                bad = bytearray(data)
                bad[-1] ^= 1
                try:
                    verify(bytes(bad), tag, dims, words, c['stall'])
                except AssertionError:
                    pass
                else:
                    raise RuntimeError('checker accepted corrupted result')
                result['negative_check'] = 'PASS'
                (folder / 'verdict.json').write_text(
                    json.dumps(result, indent=2))
                verdict['cases'].append(result)
                print('PASS scale', index, result, flush=True)
            (out / 'serial_after.bin').write_bytes(port.read(65536))
        verdict['status'] = 'PASS'
    except Exception as exc:
        verdict['error'] = repr(exc)
    finally:
        if lock.held:
            lock.release()
            (out / 'released_boardlock.json').write_text(
                json.dumps(lock.owner, indent=2))
        (out / 'verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(verdict, indent=2))
    return int(verdict['status'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
