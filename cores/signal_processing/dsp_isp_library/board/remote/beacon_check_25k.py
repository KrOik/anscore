"""Runs ON the rig host: 25K dock transport differential.

An echo-only probe is silent when either direction is dead, so it cannot tell
"the image is not running" from "the host cannot reach pad B3".  This script
loads the beacon image and splits the two:

  phase 1  listen only.  The design emits 'B','C','N',ramp on its own, so a
           clean ramp proves the 50 MHz clock, the SRAM-loaded image, the
           115200 divider and pad C3 -> ttyUSB1.
  phase 2  inject random bytes and look for the XOR-A5 echoes, which only
           appear if the host's FTDI TXD actually reaches pad B3.

    python3 beacon_check_25k.py --fs design_25k.fs --out round_01
"""
import argparse, hashlib, json, secrets, subprocess, time
from datetime import datetime, timezone
from pathlib import Path
import serial

BCN = (0x42, 0x43, 0x4e)          # 'B','C','N'


def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def parse_beacon(buf):
    """Return (groups, ramp_errors) over a buffer assumed to be pure beacon.

    The ramp restarts wherever the capture began (the design is free-running),
    so the first group seeds the expectation and each later one must be +1.
    """
    groups = errs = 0
    expect = None
    i = 0
    while i + 3 < len(buf):
        if tuple(buf[i:i + 3]) == BCN:
            got = buf[i + 3]
            if expect is None:
                expect = got
            elif got != expect:
                errs += 1
                expect = got
            expect = (expect + 1) & 0xff
            groups += 1
            i += 4
        else:
            i += 1
    return groups, errs


def match_seq(buf, want):
    """Greedy in-order subsequence match; returns how many were found."""
    it = iter(buf)
    n = 0
    for b in want:
        if any(x == b for x in it):
            n += 1
        else:
            break
    return n


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fs', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--board', default='tangprimer25k')
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--bytes', type=int, default=32)
    p.add_argument('--listen', type=float, default=2.0)
    p.add_argument('--drain', type=float, default=4.0)
    p.add_argument('--gap', type=float, default=0.0015)
    a = p.parse_args()
    out = a.out
    out.mkdir(parents=True, exist_ok=True)
    st = dict(status='FAIL', started_at=now_iso(), fs=str(a.fs),
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
        st['sram_programmed'] = True
        head, tail = bytearray(), bytearray()
        with serial.Serial(a.uart, a.baud, timeout=0.05, write_timeout=5) as port:
            port.reset_input_buffer()
            port.read(4096)                       # discard post-program backlog
            deadline = time.monotonic() + a.listen
            while time.monotonic() < deadline:
                tail = bytearray()
                head += port.read(4096)
                g, e = parse_beacon(head)
                if g >= 4 and e == 0:
                    break
                time.sleep(0.01)
            st['beacon_bytes'] = len(head)
            st['tx_groups'], st['tx_ramp_errors'] = parse_beacon(head)
            (out / 'beacon.bin').write_bytes(bytes(head))
            for b in nonce:
                port.write(bytes([b]))
                port.flush()
                time.sleep(a.gap)
                tail += port.read(4096)
            deadline = time.monotonic() + a.drain
            while len(tail) < a.bytes and time.monotonic() < deadline:
                tail += port.read(4096)
        (out / 'echo.bin').write_bytes(bytes(tail))
        st['tx_ok'] = (st['tx_groups'] >= 4 and st['tx_ramp_errors'] == 0)
        st['rx_expected'] = a.bytes
        st['rx_echo_bytes'] = len(tail)
        exp = bytes(b ^ 0xA5 for b in nonce)
        st['echo_matched'] = match_seq(tail, exp)
        st['loop_matched'] = match_seq(tail, nonce)
        st['rx_ok'] = st['echo_matched'] == a.bytes
        st['rx_pad_driven'] = st['loop_matched'] >= max(2, a.bytes // 2)
        st['status'] = 'PASS' if (st['tx_ok'] and st['rx_ok']) else 'FAIL'
        if not st['tx_ok']:
            st['failed_direction'] = 'tx-or-clock'
        elif not st['rx_pad_driven']:
            st['failed_direction'] = 'host-to-fpga(pad B3) silent'
        elif not st['rx_ok']:
            st['failed_direction'] = 'pad B3 driven but never framed'
    except Exception as exc:
        st['error'] = repr(exc)
    st['finished_at'] = now_iso()
    (out / 'verdict.json').write_text(json.dumps(st, indent=2) + '\n')
    print(json.dumps(dict(status=st['status'], tx_ok=st.get('tx_ok'),
                          tx_groups=st.get('tx_groups'),
                          echo='%s/%s' % (st.get('echo_matched'), a.bytes),
                          loop='%s/%s' % (st.get('loop_matched'), a.bytes),
                          pad_driven=st.get('rx_pad_driven'),
                          failed=st.get('failed_direction', st.get('error', '')))))
    return 0 if st['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
