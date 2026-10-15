#!/usr/bin/env python3
"""UART verification tool for cnn_infer_138k (Tang Mega 138K Pro SOM).

Protocol per cores/acceleration/cnn_inference/SPEC.md (115200 8N1, little-endian):

  request              response
  01                   A5 01 '1' '3' '8' 'K'          PING
  02 ll hh <data>      A5 02 00                        LOAD -> img_ram
  03                   A5 03 00                        RUN
  04                   A5 04 st c0 c1 c2 c3            STAT (st: b0 busy
                                                        b1 done b2 err)
  05                   A5 05 <40B scores> <4B digest> <4B cycles>
  06 ss aaaa nnnn      A5 06 <n bytes>                 DUMP (ss: 0 scores,
                        (addr/len LE, in bytes)         1 fmap_a, 2 fmap_b,
                                                        3 img)
  07                   like RUN then RESC              SELFTEST (engine-side)

After reset the board emits one boot banner
`CNN138K BOOT D=XXXXXXXX C=NNNNNN\\r\\n`; the reader resyncs past it.

CLI:
  cnn_uart.py --port COM25 ping
  cnn_uart.py --port COM25 selftest        ping->load img.mem->run->poll->compare
  cnn_uart.py --port COM25 run --image f.bin   load image (optional) + run, print result
  cnn_uart.py --port COM25 dump --sel 3 --addr 0 --len 784 --out img.bin
  cnn_uart.py --port COM25 golden          compare live RESC vs cnn_model(img.mem)

Exit codes: 0 ok/pass, 1 fail/protocol error, 2 serial open failure, 3 timeout.
Progress goes to stderr, results to stdout.
"""

import argparse
import os
import struct
import sys
import time

import serial

SYNC = 0xA5
CMD_PING, CMD_LOAD, CMD_RUN, CMD_STAT, CMD_RESC, CMD_DUMP = range(1, 7)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MEMDIR = os.path.normpath(os.path.join(
    SCRIPT_DIR, '..', '..', 'projects', 'cnn_infer_138k', 'mem'))
IMG_LEN = 784


class CnnError(Exception):
    """Protocol violation, echo mismatch, or board-reported error."""


class CnnTimeout(TimeoutError):
    """Overall response/poll timeout expired."""


def _eprint(msg):
    print(msg, file=sys.stderr, flush=True)


def _load_model():
    """Import cnn_model.py (same directory) lazily; never modify it."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'cnn_model', os.path.join(SCRIPT_DIR, 'cnn_model.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CnnLink:
    def __init__(self, port='COM25', baud=115200, timeout=1.0):
        self.baud = baud
        self.timeout = timeout
        # Short per-read timeout; read_exact enforces the overall deadline.
        self.ser = serial.Serial(port, baud, timeout=0.05)
        self.ser.reset_input_buffer()

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass

    # ------------------------------------------------------------ framing

    def _deadline(self, n):
        # Overall budget: base timeout or 2x the wire time for n bytes.
        return time.monotonic() + max(self.timeout, 2.0 * n * 11.0 / self.baud)

    def _fill(self, buf, n, deadline):
        while len(buf) < n:
            if time.monotonic() > deadline:
                raise CnnTimeout(
                    'timeout: wanted %dB, got %dB (%s)'
                    % (n, len(buf), bytes(buf).hex()))
            chunk = self.ser.read(n - len(buf))
            if chunk:
                buf += chunk
        return buf

    def read_exact(self, n):
        """Read one n-byte response. Resyncs on garbage: scans forward until
        the first byte is 0xA5. Overall timeout covers skip+payload."""
        deadline = self._deadline(n)
        skipped = bytearray()
        first = bytearray()
        while True:
            self._fill(first, 1, deadline)
            if first[0] == SYNC:
                break
            skipped += first
            first.clear()
        if skipped:
            _eprint('[cnn] resync: dropped %d byte(s): %s'
                    % (len(skipped), skipped.hex()))
        rest = self._fill(bytearray(), n - 1, deadline)
        return bytes([SYNC]) + bytes(rest)

    def _transact(self, cmd, req_tail, resp_total):
        self.ser.reset_input_buffer()
        self.ser.write(bytes([cmd]) + bytes(req_tail))
        self.ser.flush()
        r = self.read_exact(resp_total)
        if r[1] != cmd:
            raise CnnError('cmd %02X: bad echo byte %02X (resp %s)'
                           % (cmd, r[1], r.hex()))
        return r[2:]

    # ------------------------------------------------------------ commands

    def ping(self):
        """PING -> payload bytes (expect b'138K')."""
        return self._transact(CMD_PING, b'', 6)

    def load_image(self, data: bytes):
        """LOAD: 02 + len16 LE + payload -> A5 02 00."""
        n = len(data)
        if not (0 < n <= 0xFFFF):
            raise ValueError('image length %d out of range' % n)
        p = self._transact(CMD_LOAD,
                           bytes([n & 0xFF, (n >> 8) & 0xFF]) + data, 3)
        if p != b'\x00':
            raise CnnError('LOAD ack payload %s != 00' % p.hex())
        return p

    def run(self):
        """RUN -> A5 03 00."""
        p = self._transact(CMD_RUN, b'', 3)
        if p != b'\x00':
            raise CnnError('RUN ack payload %s != 00' % p.hex())
        return p

    def status(self):
        """STAT -> (busy, done, err, cycles)."""
        p = self._transact(CMD_STAT, b'', 7)
        st = p[0]
        cycles = int.from_bytes(p[1:5], 'little')
        return (bool(st & 1), bool(st & 2), bool(st & 4), cycles)

    def result(self):
        """RESC -> (scores[10] int32, digest int, cycles int)."""
        p = self._transact(CMD_RESC, b'', 50)
        scores = list(struct.unpack('<10i', p[:40]))
        digest = int.from_bytes(p[40:44], 'little')
        cycles = int.from_bytes(p[44:48], 'little')
        return scores, digest, cycles

    def dump(self, sel: int, addr: int, n: int):
        """DUMP: 06 sel addr16 len16 (all in bytes) -> n payload bytes."""
        if not (0 <= sel <= 5):
            raise ValueError('sel must be 0..5')
        if not (0 <= addr <= 0xFFFF) or not (0 < n <= 0xFFFF):
            raise ValueError('addr/len out of 16-bit range')
        req = bytes([sel, addr & 0xFF, (addr >> 8) & 0xFF,
                     n & 0xFF, (n >> 8) & 0xFF])
        return self._transact(CMD_DUMP, req, 2 + n)

    # ------------------------------------------------------------ composites

    def wait_done(self, poll_timeout=30.0, poll_s=0.01):
        """Poll STAT until done or err. Returns final (busy, done, err, cyc)."""
        deadline = time.monotonic() + poll_timeout
        while True:
            st = self.status()
            if st[1] or st[2]:
                return st
            if time.monotonic() > deadline:
                raise CnnTimeout('engine busy, no done within %.1fs'
                                 % poll_timeout)
            time.sleep(poll_s)

    def selftest(self, poll_timeout=30.0):
        """RUN + wait done + RESC. Returns (scores, digest, cycles)."""
        self.run()
        busy, done, err, cyc = self.wait_done(poll_timeout)
        if err:
            raise CnnError('engine asserted err after %d cycles' % cyc)
        return self.result()


# ---------------------------------------------------------------- helpers

def load_image_file(path):
    """Read .bin (raw) or hex-text (.mem style: one hex byte per line/token)."""
    if path.lower().endswith('.bin'):
        with open(path, 'rb') as f:
            return f.read()
    with open(path, 'r') as f:
        toks = f.read().split()
    if len(toks) == 1 and len(toks[0]) > 2:
        return bytes.fromhex(toks[0])          # single continuous hex blob
    return bytes(int(t, 16) for t in toks)     # whitespace-separated hex bytes


def golden_for_image(img):
    """(scores[10], digest) from the golden model for image bytes/list."""
    cm = _load_model()
    res = cm.forward(list(img), cm.gen_weights())
    return res['scores'], cm.digest(res)


def argmax(scores):
    return max(range(len(scores)), key=lambda i: scores[i])


def print_diffs(exp_scores, got_scores, exp_digest, got_digest):
    print('CNN138K FAIL')
    if got_scores != exp_scores:
        for i, (e, g) in enumerate(zip(exp_scores, got_scores)):
            mark = '' if e == g else '   <-- MISMATCH'
            print('  score[%d] exp=%d got=%d%s' % (i, e, g, mark))
    if got_digest != exp_digest:
        print('  digest    exp=%08X got=%08X' % (exp_digest, got_digest))


def compare_and_report(got_scores, got_digest, exp_scores, exp_digest):
    if got_scores == exp_scores and got_digest == exp_digest:
        print('CNN138K PASS D=%08X ARG=%d' % (got_digest, argmax(got_scores)))
        return 0
    print_diffs(exp_scores, got_scores, exp_digest, got_digest)
    return 1


# ---------------------------------------------------------------- CLI verbs

def cmd_ping(link, args):
    p = link.ping()
    print('PING %s' % p.decode('ascii', 'replace'))
    if p != b'138K':
        _eprint('[cnn] FAIL: ping payload %r != b\'138K\'' % p)
        return 1
    return 0


def cmd_run(link, args):
    if args.image:
        img = load_image_file(args.image)
        _eprint('[cnn] load %s (%dB)' % (args.image, len(img)))
        link.load_image(img)
    _eprint('[cnn] run')
    scores, dg, cyc = link.selftest(poll_timeout=args.wait_timeout)
    print('scores: %s' % scores)
    print('CNN138K RUN D=%08X ARG=%d C=%d' % (dg, argmax(scores), cyc))
    return 0


def cmd_dump(link, args):
    data = link.dump(args.sel, args.addr, args.len)
    if args.out:
        with open(args.out, 'wb') as f:
            f.write(data)
        _eprint('[cnn] wrote %dB -> %s' % (len(data), args.out))
        print('%d' % len(data))
    else:
        print(data.hex())
    return 0


def cmd_selftest(link, args):
    img_path = os.path.join(args.memdir, 'img.mem')
    img = load_image_file(img_path)
    _eprint('[cnn] golden model on %s (%dB)' % (img_path, len(img)))
    exp_scores, exp_digest = golden_for_image(img)

    p = link.ping()
    if p != b'138K':
        _eprint('[cnn] ping payload %r != b\'138K\'' % p)
        print('CNN138K FAIL')
        print('  ping      exp=138K got=%s' % p.decode('ascii', 'replace'))
        return 1
    _eprint('[cnn] ping ok')

    _eprint('[cnn] load img.mem (%dB)' % len(img))
    link.load_image(img)
    _eprint('[cnn] run + wait done')
    got_scores, got_digest, cyc = link.selftest(poll_timeout=args.wait_timeout)
    _eprint('[cnn] done: D=%08X C=%d' % (got_digest, cyc))
    return compare_and_report(got_scores, got_digest, exp_scores, exp_digest)


def cmd_golden(link, args):
    """Compare the board's current result regs (boot/last run) with the
    golden model over img.mem."""
    img_path = os.path.join(args.memdir, 'img.mem')
    img = load_image_file(img_path)
    exp_scores, exp_digest = golden_for_image(img)

    p = link.ping()
    if p != b'138K':
        _eprint('[cnn] ping payload %r != b\'138K\'' % p)
        print('CNN138K FAIL')
        return 1
    busy, done, err, _ = link.status()
    if busy:
        raise CnnError('board busy; cannot read a stable result')
    if err:
        _eprint('[cnn] WARNING: engine err flag set')
    got_scores, got_digest, cyc = link.result()
    _eprint('[cnn] live result: D=%08X C=%d' % (got_digest, cyc))
    return compare_and_report(got_scores, got_digest, exp_scores, exp_digest)


def _add_common(p, suppress):
    """Shared link options. `suppress` variant is used on subparsers so the
    same flags work both before and after the verb without overwriting a
    value already parsed at top level."""
    p.add_argument('--port', default='COM25' if not suppress else
                   argparse.SUPPRESS)
    p.add_argument('--baud', type=int,
                   default=115200 if not suppress else argparse.SUPPRESS)
    p.add_argument('--timeout', type=float,
                   default=1.0 if not suppress else argparse.SUPPRESS,
                   help='per-response overall timeout (s)')
    p.add_argument('--wait-timeout', type=float,
                   default=30.0 if not suppress else argparse.SUPPRESS,
                   help='max wait for engine done (s)')
    p.add_argument('--memdir',
                   default=DEFAULT_MEMDIR if not suppress else
                   argparse.SUPPRESS,
                   help='dir holding img.mem')


def main(argv=None):
    ap = argparse.ArgumentParser(
        description='cnn_infer_138k UART verification tool')
    _add_common(ap, suppress=False)
    common = argparse.ArgumentParser(add_help=False)
    _add_common(common, suppress=True)

    sub = ap.add_subparsers(dest='verb', required=True)

    sub.add_parser('ping', parents=[common], help='PING, expect 138K')

    p_run = sub.add_parser('run', parents=[common],
                           help='optional LOAD image, RUN, print result')
    p_run.add_argument('--image', help='.bin raw or hex-text image file')

    p_dump = sub.add_parser('dump', parents=[common],
                            help='DUMP sel/addr/len')
    p_dump.add_argument('--sel', type=int, required=True,
                        help='0 scores, 1 fmap_a, 2 fmap_b, 3 img')
    p_dump.add_argument('--addr', type=lambda s: int(s, 0), required=True)
    p_dump.add_argument('--len', type=lambda s: int(s, 0), required=True)
    p_dump.add_argument('--out', help='output file (default: hex to stdout)')

    sub.add_parser('selftest', parents=[common],
                   help='ping -> load img.mem -> run -> compare vs golden')
    sub.add_parser('golden', parents=[common],
                   help='compare current RESC vs golden model on img.mem')

    args = ap.parse_args(argv)

    try:
        link = CnnLink(args.port, args.baud, args.timeout)
    except (serial.SerialException, OSError) as e:
        _eprint('[cnn] ERROR: cannot open %s @%d: %s' % (args.port, args.baud, e))
        return 2

    try:
        fn = {'ping': cmd_ping, 'run': cmd_run, 'dump': cmd_dump,
              'selftest': cmd_selftest, 'golden': cmd_golden}[args.verb]
        return fn(link, args)
    except CnnTimeout as e:
        _eprint('[cnn] TIMEOUT: %s' % e)
        return 3
    except (CnnError, ValueError, serial.SerialException, OSError) as e:
        _eprint('[cnn] ERROR: %s' % e)
        return 1
    finally:
        link.close()


if __name__ == '__main__':
    sys.exit(main())
