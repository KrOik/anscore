"""Independent golden model for ips_ewma_moving_avg.

Written from the core's documented contract, not from simulation output
(docs/IP_CORE_SOP.md trap T1).

EWMA, signed Q7 samples, alpha = 1 / 2**KSHIFT:

    dif    = x(n) - ewma(n)                      (9-bit signed)
    step   = dif >> KSHIFT                       (arithmetic, floors)
    ewma   = ewma + step                         (truncated to 8 bits)

frac is dif[3:0]; the sticky stall flag latches when dif is non-zero while step is
zero, i.e. the 0 < dif < 2**KSHIFT limit cycle where the average cannot catch up.

Moving average: NTAP samples live in a circular file written at wptr; the window sum
is maintained exactly as msum + x(n) - mem[wptr] and cnt counts stored samples,
saturating at NTAP, so during warm-up the mean divides by the samples actually
present rather than by NTAP.  The mean is |msum| / cnt from DIVSTEPS = 11 restoring
shift/subtract steps on magnitudes (it counts them), truncated toward zero, and both
mean and rem take the sign of msum, with |rem| < cnt.

One sample takes 1 + DIVSTEPS + 2 enabled beats: capture, the division steps,
collect, output pulse.  Stages: 0 idle, 1 divide, 2 collect, 3 output; start is
ignored while busy.

Stimulus contract shared with sim/tb_ips_ewma_moving_avg.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x6E0DA505, every beat
    x_in = state[9:2] (signed Q7), forced on beat 0 of each OPB-beat window to
    CORNER[window % 10] = 0, 5, 127, -128, 0, 64, -92, 7 for classes 0..7 and left
    random for classes 8 and 9.  Class 1 (x = 5 from a converged ewma = 0) is what
    latches the sticky stall flag.
    start on beats 0 and 7 of every window (beat 7 collides with a division)
Observed word order per beat, matching the testbench fold:
    {ewma, mean}, {msum, frac, rem}, {stall, valid, busy, stage, wptr, cnt, it},
then those three words again and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, s, u

NTAP = 8
KSHIFT = 3
DIVSTEPS = 11
BEATS = 480
OPB = 15
SEED = 0x6E0DA505
CORNER = (0, 5, 127, -128, 0, 64, -92, 7)


def main():
    state = SEED
    ewma = 0
    mean = 0
    msum = 0
    rem = 0
    frac = 0
    stall = 0
    valid = 0
    stage = 0
    wptr = 0
    cnt = 0
    it = 0
    dreg = 0
    dsign = 0
    dsv = 0
    drem = 0
    dq = 0
    mem = [0] * NTAP
    words = []

    def flags():
        busy = 1 if stage != 0 else 0
        return ((stall & 1) << 18) | (valid << 17) | (busy << 16) \
            | ((stage & 7) << 13) | ((wptr & 15) << 9) | ((cnt & 15) << 5) \
            | (it & 31)

    for i in range(BEATS):
        state = (state * 1664525 + 1013904223) & MASK32
        x = s((state >> 2) & 0xFF, 8)
        k = i % OPB
        window = i // OPB
        if k == 0 and window % 10 < 8:
            x = CORNER[window % 10]
        start = 1 if (k == 0 or k == 7) else 0

        dif = s(u(x - ewma, 9), 9)
        step = dif >> KSHIFT
        wold = mem[wptr]
        sum_nxt = s(u(msum + x - wold, 11), 11)
        mag_nxt = u(-sum_nxt, 11) if sum_nxt < 0 else u(sum_nxt, 11)
        cnt_nxt = cnt + 1 if cnt < NTAP else cnt

        shifted = u((drem << 1) | ((dreg >> 10) & 1), 6)
        fits = 1 if shifted >= dsv else 0
        rem_nxt = u(shifted - dsv, 6) if fits else shifted

        if start and stage == 0:
            ewma = s(u(ewma + step, 8), 8)
            frac = u(dif, 4)
            if dif != 0 and step == 0:
                stall = 1
            mem[wptr] = x
            msum = sum_nxt
            cnt = cnt_nxt
            wptr = 0 if wptr == NTAP - 1 else wptr + 1
            dreg = mag_nxt
            dsign = 1 if sum_nxt < 0 else 0
            dsv = cnt_nxt
            drem = 0
            dq = 0
            it = 0
            valid = 0
            stage = 1
        else:
            valid = 0
            if stage == 1:
                drem = rem_nxt
                dreg = u(dreg << 1, 11)
                dq = u((dq << 1) | fits, 11)
                last = (it == DIVSTEPS - 1)
                it = u(it + 1, 5)
                if last:
                    stage = 2
            elif stage == 2:
                mean = s(u(-dq if dsign else dq, 8), 8)
                r4 = drem & 0xF
                rem = s(u(-r4 if dsign else r4, 4), 4)
                stage = 3
            elif stage == 3:
                valid = 1
                stage = 0
            else:
                stage = 0

        words.append((u(ewma, 8) << 8) | u(mean, 8))
        words.append((u(msum, 11) << 8) | (u(frac, 4) << 4) | u(rem, 4))
        words.append(flags())

    words.append((u(ewma, 8) << 8) | u(mean, 8))
    words.append((u(msum, 11) << 8) | (u(frac, 4) << 4) | u(rem, 4))
    words.append(flags())
    words.append(BEATS)
    emit('ips_ewma_moving_avg', words)


if __name__ == '__main__':
    main()
