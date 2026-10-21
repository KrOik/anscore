"""Runs ON the rig host: 25K dock full-duplex UART transport gate.

Injects a fresh random nonce list into the FPGA (pad B3 via the onboard USB
debugger) and reads the XOR-A5 echo back from /dev/ttyUSB1 (pad C3).  This
qualifies the transport only -- the same link every per-core 25K board round
uses -- and qualifies no algorithm.

    python3 transport_check_25k.py --fs design_25k.fs --out round_01 [--bytes 200]
"""
import argparse, hashlib, json, secrets, subprocess, time
from datetime import datetime, timezone
from pathlib import Path
import serial


def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fs', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--board', default='tangprimer25k')
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--bytes', type=int, default=200)
    p.add_argument('--timeout', type=float, default=20.0)
    a = p.parse_args()
    out = a.out
    out.mkdir(parents=True, exist_ok=True)
    status = dict(status='FAIL', started_at=now_iso(), fs=str(a.fs),
                  sha256=hashlib.sha256(a.fs.read_bytes()).hexdigest(),
                  board=a.board, uart=a.uart, baud=a.baud, count=a.bytes)
    nonce = bytes(secrets.randbits(8) for _ in range(a.bytes))
    (out / 'nonce.bin').write_bytes(nonce)
    try:
        with (out / 'program.log').open('w') as log:
            r = subprocess.run(['openFPGALoader', '-b', a.board, str(a.fs)],
                               stdout=log, stderr=subprocess.STDOUT, timeout=300)
        if r.returncode:
            raise RuntimeError('Programming failed; SRAM state unconfirmed')
        status['sram_programmed'] = True
        time.sleep(1.0)
        echo = bytearray()
        with serial.Serial(a.uart, a.baud, timeout=0.05, write_timeout=5) as port:
            port.reset_input_buffer()
            for b in nonce:
                port.write(bytes([b]))
                port.flush()
                time.sleep(0.0015)
                echo += port.read(4096)
            deadline = time.monotonic() + a.timeout
            while len(echo) < a.bytes and time.monotonic() < deadline:
                echo += port.read(4096)
        (out / 'echo.bin').write_bytes(bytes(echo))
        exp = bytes(b ^ 0xA5 for b in nonce)
        status['received'] = len(echo)
        status['first_divergence'] = next(
            (i for i in range(min(len(echo), a.bytes)) if echo[i] != exp[i]),
            None)
        status['status'] = ('PASS' if len(echo) == a.bytes and echo == exp
                            else 'FAIL')
    except Exception as exc:
        status['error'] = repr(exc)
    status['finished_at'] = now_iso()
    (out / 'verdict.json').write_text(json.dumps(status, indent=2) + '\n')
    print(json.dumps(dict(status=status['status'], sent=a.bytes,
                          received=status.get('received'),
                          first_divergence=status.get('first_divergence'),
                          error=status.get('error', ''))))
    return 0 if status['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
