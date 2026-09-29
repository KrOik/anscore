#!/usr/bin/env python3
# Decode UART (115200 8N1) on D0 of a sigrok .sr capture + report D1..D3 stats.
# .sr is a zip: metadata + logic-1-N chunks (raw sample bytes, bit i = channel Di).
import sys, re, zipfile

sr = sys.argv[1] if len(sys.argv) > 1 else "build_oss/la_cap.sr"
z = zipfile.ZipFile(sr)
names = z.namelist()

# samplerate from metadata, e.g. "samplerate=4 MHz"
meta = z.read("metadata").decode("utf-8", "replace")
m = re.search(r"samplerate=(\d+)\s*(kHz|MHz|Hz)", meta)
rate = 1e6
if m:
    rate = float(m.group(1)) * {"Hz": 1.0, "kHz": 1e3, "MHz": 1e6}[m.group(2)]
print("samplerate:", rate)

logic_names = sorted(
    [n for n in names if n.startswith("logic-1-")],
    key=lambda n: int(n.rsplit("-", 1)[1]))
data = b"".join(z.read(n) for n in logic_names)
print("samples:", len(data))

d0 = [(b & 1) for b in data]
d1 = [(b >> 1) & 1 for b in data]
d2 = [(b >> 2) & 1 for b in data]
d3 = [(b >> 3) & 1 for b in data]

def stats(bits, name):
    edges = sum(1 for i in range(1, len(bits)) if bits[i] != bits[i-1])
    print("%s: level=%d edges=%d high_frac=%.3f" % (name, bits[-1], edges, sum(bits)/len(bits)))

stats(d0, "D0 uart")
stats(d1, "D1 hb  ")
stats(d2, "D2 pass")
stats(d3, "D3 fail")

# UART decode: idle high; falling edge = start bit; majority-vote 3 samples
# around each bit centre to reject single-sample glitches.
BIT = rate / 115200.0
def vote(pos):
    s = 0
    for off in (-1, 0, 1):
        p = int(pos + off * BIT * 0.08)
        if 0 <= p < len(d0):
            s += d0[p]
    return 1 if s >= 2 else 0

out = []
i = 0
n = len(d0)
while i < n - int(BIT * 10):
    if d0[i] == 1 and d0[i+1] == 0:
        start = i + 1
        v = 0
        ok = True
        for bit in range(8):
            pos = start + BIT * (bit + 1.5)
            if pos >= n:
                ok = False
                break
            v |= (vote(pos) << bit)
        stop_pos = start + BIT * 9.5
        if stop_pos < n and vote(stop_pos) == 1 and ok:
            out.append(v)
            i = start + int(BIT * 10)
        else:
            i = start + 1
    else:
        i += 1

txt = bytes(out).decode("ascii", "replace")
with open("doc/board_uart_la.txt", "w", newline="", encoding="ascii", errors="replace") as f:
    f.write(txt)
print("decoded %d bytes -> doc/board_uart_la.txt" % len(out))
sys.stdout.write(txt.encode("ascii", "replace").decode("ascii"))
