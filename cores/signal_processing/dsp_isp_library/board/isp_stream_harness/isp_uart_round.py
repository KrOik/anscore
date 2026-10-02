"""Remote ISP stream harness driver: IMG1 request / IMR1 reply over the dock UART.

Runs on the rig host inside a staged directory that holds isp_stream_harness's
frozen protocol.py, the per-core bit-exact model and the build's variant.json,
so every reply is checked against the independent model oracle and never
against anything read back from the DUT.  Each case is followed by a
single-bit mutation of the reply that must be rejected, proving the check is
actually looking at the data.

Transport note: this path is 115200-baud UART.  The bytes/second measured here
is a property of the serial link, not of the core; core throughput is reported
separately from the harness's own per-frame cycle counter.
"""
import argparse, json, time
from datetime import datetime, timezone
from pathlib import Path
import serial
import protocol as pr

REPLY_BYTES = 276            # 'IMR1' + 16 header + 64 result words


def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def exchange(port, packet, timeout):
    port.reset_input_buffer()
    port.write(packet)
    port.flush()
    deadline = time.monotonic() + timeout
    buf = bytearray()
    while len(buf) < REPLY_BYTES and time.monotonic() < deadline:
        chunk = port.read(min(64, REPLY_BYTES - len(buf)))
        if chunk:
            buf += chunk
    return bytes(buf)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--bits', type=int, default=8)
    p.add_argument('--padding', type=int, default=1)
    p.add_argument('--timeout', type=float, default=5.0)
    p.add_argument('--seed', type=int, default=1)
    p.add_argument('--limit', type=int, default=0,
                   help='only the first N cases (transport probe); 0 = all')
    a = p.parse_args(argv)
    out = a.output
    (out / 'frames').mkdir(parents=True, exist_ok=True)
    core = pr._core()
    frames = pr.cases(a.bits, core=core)
    if a.limit:
        frames = frames[:a.limit]
    rows = []
    started = time.monotonic()
    sent_bytes = 0
    with serial.Serial(a.uart, a.baud, timeout=0.05, write_timeout=5) as port:
        port.reset_input_buffer()
        for i, (tag, config, words, stall) in enumerate(frames):
            packet = pr.make_packet(tag, config, words, stall)
            rec = dict(name='isp%02d' % i, tag='%08x' % tag, config=config,
                       stall=stall, pixels=64, ok=False, attempts=0,
                       negative_check='SKIP')
            report = b''
            for attempt in range(3):
                rec['attempts'] = attempt + 1
                t0 = time.perf_counter()
                report = exchange(port, packet, a.timeout)
                rec['rtt_us'] = int((time.perf_counter() - t0) * 1e6)
                if len(report) == REPLY_BYTES:
                    break
            sent_bytes += len(packet)
            (out / 'frames' / ('%08x.bin' % tag)).write_bytes(report)
            if len(report) != REPLY_BYTES:
                rec['error'] = 'reply length %d of %d' % (len(report),
                                                          REPLY_BYTES)
                rows.append(rec)
                print('%s %-9s -> FAIL %s' % (now_iso(), rec['name'],
                                              rec['error']), flush=True)
                continue
            try:
                res = pr.verify(report, tag, config, words, a.bits, stall,
                                a.padding, core=core)
                mut = bytearray(report)
                mut[24] ^= 0x01
                try:
                    pr.verify(bytes(mut), tag, config, words, a.bits, stall,
                              a.padding, core=core)
                    rec['negative_check'] = 'MISS'
                except AssertionError:
                    rec['negative_check'] = 'PASS'
                rec.update(ok=True, cycles=res['replay_cycles'])
            except AssertionError as exc:
                rec['error'] = 'verify: %s' % (exc,)
            rows.append(rec)
            print('%s %-9s -> %s rtt=%s us cycles=%s neg=%s %s'
                  % (now_iso(), rec['name'], 'PASS' if rec['ok'] else 'FAIL',
                     rec.get('rtt_us'), rec.get('cycles'),
                     rec['negative_check'], rec.get('error') or ''),
                  flush=True)
    elapsed = time.monotonic() - started
    verified = sum(1 for r in rows if r['ok'])
    received = sum(f.stat().st_size for f in (out / 'frames').glob('*.bin'))
    session = dict(status='PASS' if verified == len(rows) and rows and
                   all(r['negative_check'] == 'PASS' for r in rows) else 'FAIL',
                   started_at=now_iso(), transport='uart-%d' % a.baud,
                   core=core, uart=a.uart, bits=a.bits, padding=a.padding,
                   seed=a.seed, planned=len(frames), verified=verified,
                   failed=len(frames) - verified,
                   elapsed_s=round(elapsed, 3),
                   bytes_sent=sent_bytes, bytes_received=received,
                   bytes_per_s=round((sent_bytes + received) /
                                     max(elapsed, 1e-9), 1),
                   cases=rows)
    (out / 'verdict.json').write_text(json.dumps(session, indent=2,
                                                 ensure_ascii=False) + '\n',
                                      encoding='utf-8')
    print('%s verdict %s -> %s' % (now_iso(), session['status'], out),
          flush=True)
    return 0 if session['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
