"""Independent golden model for ips_booth_mult_s16.

Written from the core's documented contract: a radix-4 Booth scan of operand_b
over ITER accumulation beats, digit d_i = -2*b(2i+1) + b(2i) + b(2i-1) with
b(-1) = 0 and partial product d_i * (operand_a << 2i), summed modulo 2**32 so the
collected product is the two's-complement operand_a * operand_b.  Pipeline:
stage 0 idle -> 1 capture -> 2 accumulate -> 3 collect -> PIPE output -> 0.
ovf marks a product outside [-32768, 32767]; valid pulses one beat; a start seen
while a stage is in flight is dropped and counted in err_start.  The model never
reads simulation output; the gate diffs this digest against the RTL one
(docs/IP_CORE_SOP.md trap T1).

Stimulus contract shared with sim/tb_ips_booth_mult_s16.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x51A7E51A, every beat
    operand_a = state[15:0], operand_b = state[31:16] (signed)
    start on beat 0 and beat 5 of each OPB-beat window (beat 5 collides)
    op index % 5 == 0..3 forces (min,min), (max,-1), (0,max), (min,-1)
Observed word order per beat, matching the testbench fold:
    {ovf, valid, busy, stage, ppc}, product, then err_start and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, s, u

ITER = 8
PIPE = 4
S_IDLE, S_CAP, S_ACC, S_COL = 0, 1, 2, 3
BEATS = 288
OPB = 16
SEED = 0x51A7E51A
M32 = 0xFFFFFFFF
CORNER = ((-32768, -32768), (32767, -1), (0, 32767), (-32768, -1))


def main():
    state = SEED
    product = 0
    ovf = 0
    valid = 0
    stage = S_IDLE
    ppc = 0
    err = 0
    acc = 0
    ash = 0
    qreg = 0
    qm1 = 0
    words = []

    for i in range(BEATS):
        state = (state * 1664525 + 1013904223) & MASK32
        a = s(state & 0xFFFF, 16)
        b = s((state >> 16) & 0xFFFF, 16)
        k = i % OPB
        if k == 0 and (i // OPB) % 5 < 4:
            a, b = CORNER[(i // OPB) % 5]
        start = 1 if (k == 0 or k == 5) else 0

        # combinational Booth digit of the current scanning register
        c2 = (qreg >> 1) & 1
        c1 = qreg & 1
        c0 = qm1
        d = -2 * c2 + c1 + c0

        if start and stage == S_IDLE:
            product, ovf, valid = 0, 0, 0
            acc, ash, qreg, qm1, ppc = 0, u(a, 32), b, 0, 0
            stage = S_CAP
        elif start and stage != S_IDLE:
            err = (err + 1) & 0xFF
        elif stage == S_CAP:
            stage = S_ACC
        elif stage == S_ACC:
            mag = (ash << 1) & M32 if abs(d) == 2 else ash
            pp = 0 if d == 0 else (mag if d > 0 else (-mag) & M32)
            acc = (acc + pp) & M32
            last = (ppc == ITER - 1)
            ppc = (ppc + 1) & 0xF
            ash = (ash << 2) & M32
            qm1 = qreg & 1
            qreg = qreg >> 2
            if last:
                stage = S_COL
        elif stage == S_COL:
            product = acc
            ovf = 1 if s(acc, 32) < -32768 or s(acc, 32) > 32767 else 0
            stage = PIPE
        else:
            if stage == PIPE:
                valid = 1
                stage = S_IDLE
            else:
                valid = 0

        busy_now = 1 if stage != S_IDLE else 0
        words.append(((ovf & 1) << 10) | ((valid & 1) << 9)
                     | ((busy_now & 1) << 8) | ((stage & 0xF) << 4)
                     | (ppc & 0xF))
        words.append(u(product, 32))

    words.append(err)
    words.append(BEATS)
    emit('ips_booth_mult_s16', words)


if __name__ == '__main__':
    main()
