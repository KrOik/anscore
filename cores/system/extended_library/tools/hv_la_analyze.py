#!/usr/bin/env python3
"""Analyze hv_la_*.sr captures: per-channel edges, first-transition times,
UART decode on whichever channel carries it."""
import sys, zipfile, struct

def load_sr(path):
    z = zipfile.ZipFile(path)
    meta = z.read('metadata').decode()
    sr = 12_000_000
    import re
    m = re.search(r'samplerate=([\d.]+)\s*([kMG]?Hz)', meta)
    if m:
        sr = int(float(m.group(1)) * {'Hz': 1, 'kHz': 1e3,
                                      'MHz': 1e6, 'GHz': 1e9}[m.group(2)])
    parts = sorted((n for n in z.namelist() if n.startswith('logic-1-')),
                   key=lambda n: int(n.rsplit('-', 1)[1]))
    logic = b''.join(z.read(n) for n in parts)
    return logic, sr

def chan(logic, c):
    return bytes((b >> c) & 1 for b in logic)

def edges(bits):
    out, prev = [], bits[0]
    for i, b in enumerate(bits):
        if b != prev:
            out.append(i); prev = b
    return out

def first_last(bits, sr):
    e = edges(bits)
    if not e: return None
    return e[0]/sr*1e6, e[-1]/sr*1e6, len(e)

def decode_uart(bits, sr, baud=115200):
    """Return list of (t_us, byte)."""
    bit = sr / baud
    out, i, n = [], 0, len(bits)
    while True:
        # find falling edge
        while i < n and bits[i] == 1: i += 1
        if i + 10*bit >= n: break
        val = 0
        ok = True
        for k in range(8):
            p = int(i + (k+1)*bit + bit/2)
            if p >= n: ok = False; break
            val |= bits[p] << k
        sp = int(i + 9*bit + bit/2)
        if ok:
            out.append((i/sr*1e6, val))
        i = int(i + 10*bit)
    return out

def main():
    logic, sr = load_sr(sys.argv[1])
    print(f"samples={len(logic)} sr={sr/1e6:.1f}MHz dur={len(logic)/sr*1000:.1f}ms")
    for c in range(8):
        bits = chan(logic, c)
        r = first_last(bits, sr)
        if r:
            print(f"D{c}: first={r[0]:9.1f}us last={r[1]:9.1f}us edges={r[2]}")
        else:
            print(f"D{c}: static level={bits[0]}")
    # try uart decode on every channel; report only if mostly printable
    for c in range(8):
        bits = chan(logic, c)
        d = decode_uart(bits, sr)
        if len(d) > 4:
            pr = sum(1 for _, v in d
                     if 32 <= v < 127 or v in (10, 13)) / len(d)
            if pr > 0.6:
                txt = ''.join(chr(v) if 32 <= v < 127 or v in (10, 13)
                              else '.' for _, v in d[:60])
                print(f"D{c} UART-ish ({len(d)} bytes): {txt!r}")

if __name__ == '__main__':
    main()
