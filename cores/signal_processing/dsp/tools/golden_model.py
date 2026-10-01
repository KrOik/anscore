#!/usr/bin/env python3
# ============================================================================
# golden_model.py -- independent functional model for dsp_20k units.
# Replicates the RTL bit-exactly (quantization, wrap, saturation, cycle
# semantics) using only Python math; produces:
#   * sine256.mem           (project root, $readmemh for dds_nco)
#   * expected digests      (printed; pasted into dsp_selftest.v EXP_*)
#   * sim/expected_report*.mem via gen_uart_golden.py
#   * sim/golden_stream_*.mem raw expected byte streams for TB debug
# ============================================================================
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FNV_SEED = 0x811C9DC5
FNV_PRIME = 0x01000193

def fnv(h, b):
    return ((h ^ (b & 0xFF)) * FNV_PRIME) & 0xFFFFFFFF

def digest(bs):
    h = FNV_SEED
    for b in bs:
        h = fnv(h, b)
    return h

def sar(v, i):            # arithmetic shift right (floor), matches >>>
    return v >> i

def wrap(v, w):           # signed wrap to w bits
    v &= (1 << w) - 1
    return v - (1 << w) if v >= (1 << (w - 1)) else v

def sat(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)

ATAN = [int(round(math.atan(2.0 ** -i) * 16384)) for i in range(16)]
PI_Q = int(round(math.pi * 16384))       # 51472
PI2_Q = int(round(math.pi / 2 * 16384))  # 25736

def cordic(x_in, y_in, z_in, mode, stages=16):
    """Returns (x_out16, y_out16, z_out18) identical to cordic.v."""
    x, y, z = x_in, y_in, z_in
    # stage 0: quadrant pre-rotation
    if mode:  # vectoring
        if x_in < 0:
            x, y = -x_in, -y_in
            z = z_in + (-PI_Q if y_in < 0 else PI_Q)
        else:
            z = z_in
    else:     # rotation
        if z_in > PI2_Q:
            x, y, z = -x_in, -y_in, z_in - PI_Q
        elif z_in < -PI2_Q:
            x, y, z = -x_in, -y_in, z_in + PI_Q
    for i in range(stages):
        neg = (y >= 0) if mode else (z < 0)   # e=-1 condition
        if neg:
            x, y, z = x + sar(y, i), y - sar(x, i), z + ATAN[i]
        else:
            x, y, z = x - sar(y, i), y + sar(x, i), z - ATAN[i]
        x, y, z = wrap(x, 18), wrap(y, 18), wrap(z, 18)
    return sat(x, -32768, 32767), sat(y, -32768, 32767), wrap(z, 18)

# ---------------------------------------------------------------------------
# Unit byte streams (must mirror dsp_selftest.v fold order exactly)
# ---------------------------------------------------------------------------

def stream_crdr():
    bs = []
    for k in range(64):
        z_in = wrap(-31000 + k * 1000, 16)
        xo, yo, zo = cordic(9949, 0, z_in, mode=0)
        bs += [xo & 0xFF, (xo >> 8) & 0xFF, yo & 0xFF, (yo >> 8) & 0xFF]
    return bs

def stream_crdv():
    bs = []
    xr = yr = 0
    for k in range(48):
        x_in = xr - 15000
        y_in = yr - 12000
        xo, yo, zo = cordic(x_in, y_in, 0, mode=1)
        bs += [xo & 0xFF, (xo >> 8) & 0xFF,
               zo & 0xFF, (zo >> 8) & 0xFF, (zo >> 16) & 0x3]
        xr = xr + 521 - 30000 if xr >= 29479 else xr + 521
        yr = yr + 733 - 24000 if yr >= 23267 else yr + 733
    return bs

def stream_dds():
    """beats b=2..129: sine=lut[ph_{b-2}>>24], square=ph_{b-1}>>31."""
    lut = [int(round(32767 * math.sin(2 * math.pi * i / 256))) for i in range(256)]
    tw = 0x08000000
    bs = []
    # captured at beat b: sine_out was written at edge b-1 = lut[ph_{b-1}>>24],
    # square_out = ph_b[31] (combinational on accumulator just before edge b).
    for b in range(2, 130):
        s = lut[(((b - 1) * tw) & 0xFFFFFFFF) >> 24]
        sq = ((b * tw) & 0xFFFFFFFF) >> 31
        bs += [s & 0xFF, (s >> 8) & 0xFF, sq & 1]
    return bs

def stream_fir():
    C = [1, 2, 4, 8, 16, 32, 32, 16]
    s = [0] * 16
    bs = []
    for n in range(80):
        samp = 200 if n < 8 else (n * 53 + 7) & 0xFF
        acc = sum(C[k] * (s[k] + s[15 - k]) for k in range(8))
        bs.append(min(255, acc >> 8))
        s = [samp] + s[:15]
    return bs

def stream_pid():
    KP_MUL, KP_SH = 96, 6
    KI_MUL, KI_SH = 4, 6
    KD_MUL, KD_SH = 32, 6
    I_LIM, OUT_LIM = 16000, 32000
    i_acc = err_prev = 0
    bs = []
    for n in range(64):
        if n < 16:
            err = 4000
        elif n < 32:
            err = -2000
        else:
            err = ((n * 997) & 0x3FFF) - 4000
        i_next = sat(i_acc + err, -I_LIM, I_LIM)
        d_err = sat(err - err_prev, -32768, 32767)
        u = sat((err * KP_MUL >> KP_SH) + (i_next * KI_MUL >> KI_SH)
                + (d_err * KD_MUL >> KD_SH), -OUT_LIM, OUT_LIM)
        i_acc, err_prev = i_next, err
        bs += [u & 0xFF, (u >> 8) & 0xFF]
    return bs

STREAMS = {
    "CRDR": stream_crdr,
    "CRDV": stream_crdv,
    "DDS":  stream_dds,
    "FIR":  stream_fir,
    "PID":  stream_pid,
}

def write_sine_mem():
    path = os.path.join(ROOT, "sine256.mem")
    with open(path, "w") as f:
        for i in range(256):
            v = int(round(32767 * math.sin(2 * math.pi * i / 256)))
            f.write("%04x\n" % (v & 0xFFFF))
    return path

def write_streams(dig):
    for name, fn in STREAMS.items():
        path = os.path.join(ROOT, "sim", "golden_stream_%s.mem" % name.lower())
        with open(path, "w") as f:
            for b in fn():
                f.write("%02x\n" % b)

if __name__ == "__main__":
    write_sine_mem()
    dig = {}
    for name, fn in STREAMS.items():
        bs = fn()
        dig[name] = digest(bs)
        print("%-4s bytes=%4d digest=%08X" % (name, len(bs), dig[name]))
    write_streams(dig)
    # sanity: cordic rotation accuracy
    err = 0
    for k in range(64):
        z = wrap(-31000 + k * 1000, 16) / 16384.0
        xo, yo, _ = cordic(9949, 0, wrap(-31000 + k * 1000, 16), 0)
        err = max(err, abs(xo / 16384.0 - math.cos(z)),
                     abs(yo / 16384.0 - math.sin(z)))
    print("cordic rot max err vs math: %.4f (%.1f LSB)" % (err, err * 16384))
