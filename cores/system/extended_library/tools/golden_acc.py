#!/usr/bin/env python3
# ============================================================================
# golden_acc.py -- independent golden model for wave2_ip_20k group H units
# (idx35..39): bnn_conv3x3, bnn_dense, tmr_voter, wdt_win, lfsr_prng.
#
# For each unit this computes the exact byte stream that the st_<unit> cell
# folds into its FNV-1a digest, writes sim/golden_<unit>.txt (one hex byte
# per line, matching sim/dump_<unit>.txt from the TBs), and prints
# "<TAG> DIGEST=XXXXXXXX".  EXP constants in src/st_*.v come ONLY from this
# script (trap T1: never back-fill expected values from simulation).
#
# Run from the project root:  python tools/golden_acc.py
# ============================================================================
import os

FNV_INIT = 0x811C9DC5

def fnv(h, b):
    h ^= b & 0xFF
    return (h * 0x01000193) & 0xFFFFFFFF

def digest(bs):
    h = FNV_INIT
    for b in bs:
        h = fnv(h, b)
    return h

def write_golden(name, bs):
    path = os.path.join("sim", "golden_%s.txt" % name)
    with open(path, "w") as f:
        for b in bs:
            f.write("%02x\n" % (b & 0xFF))
    return path

# ============================================================================
# idx35 BC3: bnn_conv3x3
#   image: w2_img_stim formula (16x16, frame 0), bin = pix > 128
#   window (oy,ox): tap(r,c)=I[clamp(oy+r-1)][clamp(ox+c-1)], win9[i]=tap(r,c)
#   per channel: out = popcount(~(win9 ^ w9)) >= thr ; byte = {6'b0,out1,out0}
# ============================================================================
W = H = 16

def stim_pix(x, y, f=0):
    base = ((x + (x << 4)) ^ (y + (y << 3) + (y << 5)) ^ ((x & y) << 3)) & 0xFF
    sx0, sy0 = 6 + 2 * f, 5 + f
    if sx0 <= x <= sx0 + 3 and sy0 <= y <= sy0 + 5:
        base = (base + 0x50) & 0xFF
    return base

img = [[1 if stim_pix(x, y) > 128 else 0 for x in range(W)] for y in range(H)]
W9  = [0b101100101, 0b011010011]          # ch0, ch1 (matches st_ WCFG)
THR = [5, 4]                              # ch0, ch1 (matches st_ THCFG)

def clamp(v, m):
    return 0 if v < 0 else (m if v > m else v)

bc3 = []
for oy in range(H):
    for ox in range(W):
        win = 0
        for r in range(3):
            for c in range(3):
                b = img[clamp(oy + r - 1, H - 1)][clamp(ox + c - 1, W - 1)]
                win |= b << (r * 3 + c)
        byte = 0
        for ch in range(2):
            pc = bin((~(win ^ W9[ch])) & 0x1FF).count("1")
            if pc >= THR[ch]:
                byte |= 1 << ch
        bc3.append(byte)
assert len(bc3) == 256

# ============================================================================
# idx36 BDN: bnn_dense  (NIN=32, N=4, 16 streamed vectors)
#   xorshift32 stream: weights = s0..s3, biases = signed6(s4..s7 low 6b),
#   vectors = s8..s23.  out[n] = (popcount(~(v^w[n])) + bias[n]) >= 0
# ============================================================================
def xs32(v):
    v ^= (v << 13) & 0xFFFFFFFF
    v ^= v >> 17
    v ^= (v << 5) & 0xFFFFFFFF
    return v & 0xFFFFFFFF

s = 0x9E3779B9
wds, bis, vcs = [], [], []
for _ in range(4):
    wds.append(s); s = xs32(s)
for _ in range(4):
    b6 = s & 0x3F
    bis.append(b6 - 64 if b6 >= 32 else b6)   # signed 6-bit
    s = xs32(s)
for _ in range(16):
    vcs.append(s); s = xs32(s)

bdn = []
for v in vcs:
    byte = 0
    for n in range(4):
        pc = bin((~(v ^ wds[n])) & 0xFFFFFFFF).count("1")
        if pc + bis[n] >= 0:
            byte |= 1 << n
    bdn.append(byte)
assert len(bdn) == 16

# ============================================================================
# idx37 TMR: tmr_voter + tmr_reg
#   write i: din=(i<<5)^(i<<3)^(i<<1)^0x11, fault mask 1<<i on replica i%3
#   (i=7 clean).  Per vote fold: y, {4'b0,err,mism_c,mism_b,mism_a};
#   end: err_cnt lo,hi.
# ============================================================================
tmr = []
errcnt = 0
for i in range(8):
    din = ((i << 5) ^ (i << 3) ^ (i << 1) ^ 0x11) & 0xFF
    mask = (1 << i) if i < 7 else 0
    ops = [din, din, din]
    ops[i % 3] ^= mask
    a, b, c = ops
    y = 0
    for bit in range(8):
        ab = (a >> bit) & 1; bb = (b >> bit) & 1; cb = (c >> bit) & 1
        y |= ((ab & bb) | (ab & cb) | (bb & cb)) << bit
    ma = a != y; mb = b != y; mc = c != y
    err = ma or mb or mc
    if err:
        errcnt += 1
    flags = (int(err) << 3) | (int(mc) << 2) | (int(mb) << 1) | int(ma)
    assert y == din                       # single fault always voted away
    tmr += [y, flags]
tmr += [errcnt & 0xFF, (errcnt >> 8) & 0xFF]
assert errcnt == 7

# ============================================================================
# idx38 WDT: wdt_win (WMIN=4, WMAX=9)
#   beat model of the DUT driven by the st_ schedule:
#   en from t=0 (arm at end of t=0); kicks at t=7,10,16,29,35; script ends
#   at t=40 then counters {good,early,late,tout} + reset_req are folded.
#   event codes: good=0x01 early=0xE1 late=0x1A tout=0x70
# ============================================================================
WMIN, WMAX = 4, 9
KICKS = {7, 10, 16, 29, 35}
wdt = []
cnt = None                      # None = not yet armed
good = early = late = tout = 0
rr = 0
for tt in range(0, 41):
    kick = tt in KICKS
    if cnt is None:
        cnt = 0                 # arm beat (t=0)
        continue
    if kick:
        if cnt > WMAX:
            late += 1; wdt.append(0x1A)
        elif cnt < WMIN:
            early += 1; wdt.append(0xE1)
        else:
            good += 1; wdt.append(0x01)
        cnt = 0
    elif cnt > WMAX:
        pass                    # expired: hold
    elif cnt == WMAX:
        cnt += 1; tout += 1; rr = 1; wdt.append(0x70)
    else:
        cnt += 1
assert (good, early, late, tout, rr) == (3, 1, 1, 1, 1)
wdt += [good, early, late, tout, rr]
assert len(wdt) == 11

# ============================================================================
# idx39 LFSR: lfsr_prng + scrambler/descrambler
#   Galois LFSR taps {32,22,2,1} -> mask 0x80200003, right-shift form.
#   scrambler: c = m ^ k(s); s = {s[23:0],c}; k = XOR of the 4 state bytes
#   descrambler shifts ciphertext in -> self-sync after 4 bytes.
#   stream: 16 stepped states (LSB-first, 64B) + 16 cipher + 16 plain
#           (correct seed) + 16 plain' (wrong seed -> first 4 garbled)
# ============================================================================
TAPS = 0x80200003

def gstep(sv):
    return (((sv >> 1) ^ TAPS) if (sv & 1) else (sv >> 1)) & 0xFFFFFFFF

def kbyte(sv):
    return ((sv & 0xFF) ^ ((sv >> 8) & 0xFF) ^
            ((sv >> 16) & 0xFF) ^ ((sv >> 24) & 0xFF))

lfsr = []
st = 0x0000ACE1
for _ in range(16):
    st = gstep(st)
    lfsr += [st & 0xFF, (st >> 8) & 0xFF, (st >> 16) & 0xFF, (st >> 24) & 0xFF]

pt = [((i << 4) + i + 0x55) & 0xFF for i in range(16)]   # i*17+0x55

ss = 0x1BADB002
cbuf = []
for m in pt:
    c = m ^ kbyte(ss)
    cbuf.append(c)
    ss = ((ss & 0xFFFFFF) << 8) | c
lfsr += cbuf

ds = 0x1BADB002
m1 = []
for c in cbuf:
    m = c ^ kbyte(ds)
    m1.append(m)
    ds = ((ds & 0xFFFFFF) << 8) | c
assert m1 == pt                       # pass1: exact round-trip
lfsr += m1

ds = 0x0BADF00D                        # wrong seed -> self-sync demo
m2 = []
for c in cbuf:
    m = c ^ kbyte(ds)
    m2.append(m)
    ds = ((ds & 0xFFFFFF) << 8) | c
assert m2[4:] == pt[4:]                # synced after 4 cipher bytes
lfsr += m2
assert len(lfsr) == 112

# ============================================================================
# emit golden files + digests
# ============================================================================
streams = [
    ("BC3",  "bnn_conv3x3", bc3),
    ("BDN",  "bnn_dense",   bdn),
    ("TMR",  "tmr_voter",   tmr),
    ("WDT",  "wdt_win",     wdt),
    ("LFSR", "lfsr_prng",   lfsr),
]

os.makedirs("sim", exist_ok=True)
for tag, name, bs in streams:
    write_golden(name, bs)
    print("%s DIGEST=%08X  (%d bytes -> sim/golden_%s.txt)"
          % (tag, digest(bs), len(bs), name))
