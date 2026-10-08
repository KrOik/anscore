#!/usr/bin/env python3
# ============================================================================
# golden_sys.py -- independent Python golden model for wave2 group G units:
#   dma_sg (DMA), ila_core (ILA), crc32_eth (CRC), prbs31 (PRBS),
#   mem_bist (MBST).
#
# For every unit it writes sim/golden_<unit>.txt (one hex byte per line =
# the exact byte stream folded by the st_ cell) and prints
# "TAG DIGEST=XXXXXXXX" -- those digests are the ONLY legal source for the
# EXP constants in the st_ cells (SOP trap T1).
#
# Run from the project root:  python tools/golden_sys.py
# ============================================================================
import os

FNV_INIT = 0x811C9DC5

def fnv(h, b):
    x = (h ^ (b & 0xFF)) & 0xFFFFFFFF
    return (x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24)) & 0xFFFFFFFF

def digest(stream):
    h = FNV_INIT
    for b in stream:
        h = fnv(h, b)
    return h

def write_golden(name, stream):
    path = os.path.join("sim", "golden_%s.txt" % name)
    with open(path, "w") as f:
        for b in stream:
            f.write("%02x\n" % (b & 0xFF))
    return digest(stream)

# ----------------------------------------------------------------------------
# idx30 DMA dma_sg
#   fill A[i] = (i*5 + 0x3C) & 0xFF ; B[i] = 0xC3
#   desc1: A[16..79] -> B[100..163] ; read back B[0..255]; status {irq,done}=0x03
#   desc2: B[200..215] -> A[0..15]  ; read back A[0..15];  status = 0x03
# ----------------------------------------------------------------------------
def model_dma_sg():
    A = [((i * 5 + 0x3C) & 0xFF) for i in range(256)]
    B = [0xC3] * 256
    B[100:164] = A[16:80]
    stream = list(B)
    stream.append(0x03)                  # {irq1, done} = 2'b11
    A[0:16] = B[200:216]
    stream += A[0:16]
    stream.append(0x03)
    return stream

# ----------------------------------------------------------------------------
# idx31 ILA ila_core   AW=10, DEPTH=1024
#   probe(s) = (s & 0xFF) ^ (((s >> 8) & 7) << 5)
#   run1: mask=0xE0 val=0xE0 mode=0(level)  pre=200
#   run2: mask=0x01 val=0x01 mode=1(rising) pre=50
#   per run: buf[0..1023], trig_ptr_lo, {6'b0,trig_ptr[9:8]}, {6'b0,fired,done}
# ----------------------------------------------------------------------------
def ila_probe(s):
    return ((s & 0xFF) ^ (((s >> 8) & 7) << 5)) & 0xFF

def ila_run(mask, val, mode, pre):
    DEPTH = 1024
    pre_c = min(pre, DEPTH - 1)
    post_len = DEPTH - pre_c
    buf = [None] * DEPTH
    ptr = 0
    samp = 0
    post_rem = 0
    fired = False
    prev = False
    trig_ptr = 0
    s = 0
    while s < 100000:
        p = ila_probe(s)
        cap_we = (not fired) or (post_rem != 0)
        m = ((p & mask) == (val & mask))
        if mode == 0:
            tc = m
        elif mode == 1:
            tc = m and not prev
        else:
            tc = (not m) and prev
        if cap_we:
            buf[ptr] = p
        if not fired:
            if tc and samp >= pre_c:
                fired = True
                trig_ptr = ptr
                post_rem = post_len - 1
        else:
            if post_rem == 0:
                break                    # done beat: no write
            post_rem -= 1
        if cap_we:
            ptr = (ptr + 1) & (DEPTH - 1)
            if samp < DEPTH:
                samp += 1
            prev = m
        s += 1
    assert fired, "ILA: trigger never fired"
    assert all(b is not None for b in buf), "ILA: buffer not fully written"
    stream = list(buf)
    stream.append(trig_ptr & 0xFF)
    stream.append((trig_ptr >> 8) & 0xFF)
    stream.append(0x03)                  # {fired, done} = 2'b11
    return stream, trig_ptr, s

def model_ila_core():
    s1, tp1, n1 = ila_run(0xE0, 0xE0, 0, 200)
    s2, tp2, n2 = ila_run(0x01, 0x01, 1, 50)
    return s1 + s2, (tp1, n1, tp2, n2)

# ----------------------------------------------------------------------------
# idx32 CRC crc32_eth
#   s1: CRC32  "123456789"            == 0xCBF43926 (mandatory check)
#   s2: CRC32  b(i) = (i*7+1)&0xFF, i=0..19
#   s3: CRC16/CCITT-FALSE "123456789" == 0x29B1
#   s4: CRC16  b(i) = (i*5+3)&0xFF, i=0..15
#   stream: r1[4B LE], r2[4B LE], r3[2B LE], r4[2B LE], {chk16,chk32}
# ----------------------------------------------------------------------------
def crc32_step(c, d):
    x = c ^ d
    for _ in range(8):
        x = (x >> 1) ^ 0xEDB88320 if (x & 1) else (x >> 1)
    return x & 0xFFFFFFFF

def crc16_step(c, d):
    x = c ^ (d << 8)
    for _ in range(8):
        x = ((x << 1) ^ 0x1021) & 0xFFFF if (x & 0x8000) else ((x << 1) & 0xFFFF)
    return x

def crc32_of(data):
    c = 0xFFFFFFFF
    for d in data:
        c = crc32_step(c, d)
    return c ^ 0xFFFFFFFF

def crc16_of(data):
    c = 0xFFFF
    for d in data:
        c = crc16_step(c, d)
    return c

def model_crc32_eth():
    s1 = [ord(c) for c in "123456789"]
    s2 = [((i * 7 + 1) & 0xFF) for i in range(20)]
    s3 = [ord(c) for c in "123456789"]
    s4 = [((i * 5 + 3) & 0xFF) for i in range(16)]
    r1 = crc32_of(s1)
    r2 = crc32_of(s2)
    r3 = crc16_of(s3)
    r4 = crc16_of(s4)
    assert r1 == 0xCBF43926, "CRC32 check failed: %08X" % r1
    assert r3 == 0x29B1,     "CRC16 check failed: %04X" % r3
    stream = ([r1 & 0xFF, (r1 >> 8) & 0xFF, (r1 >> 16) & 0xFF, (r1 >> 24) & 0xFF] +
              [r2 & 0xFF, (r2 >> 8) & 0xFF, (r2 >> 16) & 0xFF, (r2 >> 24) & 0xFF] +
              [r3 & 0xFF, (r3 >> 8) & 0xFF] +
              [r4 & 0xFF, (r4 >> 8) & 0xFF] +
              [0x03])                    # {chk16, chk32} = 2'b11
    return stream

# ----------------------------------------------------------------------------
# idx33 PRBS prbs31   poly x^31 + x^28 + 1
#   seed=0x2AA55AA5; 300 bits; bits 0..30 sync-load, 31..299 checked.
#   forced errors at bit indices {40,100,101,250}.
#   stream: bits 0..255 packed MSB-first (32B), err_cnt lo/hi,
#           bit_cnt lo/hi, {7'b0,synced}
# ----------------------------------------------------------------------------
def model_prbs31():
    NBIT = 300
    INJ = {40, 100, 101, 250}
    r = 0x2AA55AA5
    bits = []
    for i in range(NBIT):
        bits.append(r & 1)
        fb = ((r >> 30) ^ (r >> 27)) & 1
        r = ((fb << 30) | (r >> 1)) & 0x7FFFFFFF

    w = 0
    err = 0
    cnt = 0
    synced = 0
    for i in range(NBIT):
        rx = bits[i] ^ (1 if i in INJ else 0)
        if i < 31:
            w = ((rx << 30) | (w >> 1)) & 0x7FFFFFFF
            if i == 30:
                synced = 1
        else:
            exp = ((w >> 30) ^ (w >> 27)) & 1
            if rx != exp:
                err += 1
            cnt += 1
            w = ((rx << 30) | (w >> 1)) & 0x7FFFFFFF

    stream = []
    for k in range(32):
        b = 0
        for j in range(8):
            b |= bits[8 * k + j] << j           # RTL: byte[j] = bit (8k+j)
        stream.append(b)
    stream += [err & 0xFF, (err >> 8) & 0xFF,
               cnt & 0xFF, (cnt >> 8) & 0xFF,
               synced & 0x01]
    return stream, err, cnt

# ----------------------------------------------------------------------------
# idx34 MBST mem_bist   DEPTH=256, patterns cb/wk per src/mem_bist.v header
#   run1: clean; run2: fi_addr=0x37 (phase0 write XOR 0xFF there).
#   per run: {phase, {6'b0,fail,done}, fail_addr, fail_exp, fail_got,
#             {4'b0,fail_phase}}; run1 adds 8 host reads
#   {0,1,2,3,0x55,0xAA,0xFE,0xFF} of the final ~wk contents.
# ----------------------------------------------------------------------------
def cb(a): return 0x55 if (a & 1) else 0xAA
def wk(a): return (0x01 << (a & 7)) & 0xFF

def model_mem_bist():
    DEPTH = 256
    stream = []

    def march(fi_addr):
        mem = [0] * DEPTH
        fail = 0; fa = 0; fe = 0; fg = 0; fp = 0
        # phase 0: W cb
        for a in range(DEPTH):
            v = cb(a)
            if fi_addr is not None and a == fi_addr:
                v ^= 0xFF
            mem[a] = v
        # phase 1: R cb, W ~cb
        for a in range(DEPTH):
            e = cb(a)
            if mem[a] != e and not fail:
                fail, fa, fe, fg, fp = 1, a, e, mem[a], 1
            mem[a] = (~cb(a)) & 0xFF
        # phase 2: R ~cb
        for a in range(DEPTH):
            e = (~cb(a)) & 0xFF
            if mem[a] != e and not fail:
                fail, fa, fe, fg, fp = 1, a, e, mem[a], 2
        # phase 3: W wk
        for a in range(DEPTH):
            mem[a] = wk(a)
        # phase 4: R wk, W ~wk
        for a in range(DEPTH):
            e = wk(a)
            if mem[a] != e and not fail:
                fail, fa, fe, fg, fp = 1, a, e, mem[a], 4
            mem[a] = (~wk(a)) & 0xFF
        # phase 5: R ~wk
        for a in range(DEPTH):
            e = (~wk(a)) & 0xFF
            if mem[a] != e and not fail:
                fail, fa, fe, fg, fp = 1, a, e, mem[a], 5
        return mem, [6, (fail << 1) | 1, fa & 0xFF, fe, fg, fp]

    mem1, st1 = march(None)
    stream += st1
    for a in [0, 1, 2, 3, 0x55, 0xAA, 0xFE, 0xFF]:
        stream.append(mem1[a])
    mem2, st2 = march(0x37)
    stream += st2
    return stream, st1, st2

# ----------------------------------------------------------------------------
def main():
    os.makedirs("sim", exist_ok=True)

    s = model_dma_sg()
    d = write_golden("dma_sg", s)
    print("DMA DIGEST=%08X (%d bytes)" % (d, len(s)))

    s, info = model_ila_core()
    d = write_golden("ila_core", s)
    print("ILA DIGEST=%08X (%d bytes) trig_ptr1=%d@%d trig_ptr2=%d@%d"
          % (d, len(s), info[0], info[1], info[2], info[3]))

    s = model_crc32_eth()
    d = write_golden("crc32_eth", s)
    print("CRC DIGEST=%08X (%d bytes)" % (d, len(s)))

    s, err, cnt = model_prbs31()
    d = write_golden("prbs31", s)
    print("PRBS DIGEST=%08X (%d bytes) err_cnt=%d bit_cnt=%d"
          % (d, len(s), err, cnt))

    s, st1, st2 = model_mem_bist()
    d = write_golden("mem_bist", s)
    print("MBST DIGEST=%08X (%d bytes) st1=%s st2=%s"
          % (d, len(s), st1, st2))

if __name__ == "__main__":
    main()
