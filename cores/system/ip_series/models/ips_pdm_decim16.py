"""Independent golden model for ips_pdm_decim16.

Written from the contract in src/ips_pdm_decim16.v, never from simulation output
(docs/IP_CORE_SOP.md trap T1):

  * one oversample = one enabled cycle with pdm_tick high; the input is mapped
    bipolar, 1 -> +1 and 0 -> -1, so a stuck stream is the full-scale case;
  * the integrator section i1 += x, i2 += i1, i3 += i2 is evaluated combinationally
    for the current sample, all sums modulo 2**ACC_W with ACC_W = OUT_W + GAIN_SH;
  * the comb section fires when phase == R_RATE-1: c1 = i3 - cd1, c2 = c1 - cd2,
    c3 = c2 - cd3, then cd1 <= i3, cd2 <= c1, cd3 <= c2;
  * the scaled frame is wide = (c3 << GAIN_SH) truncated to ACC_W bits; pcm takes
    the low OUT_W bits, clamped to signed full scale, and pcm_hr reports the
    HR_BITS slice wide[ACC_W-1:OUT_W];
  * a frame whose sign extension of the low OUT_W bits differs from wide is
    clamped: it sets sat_pos / sat_neg for that frame, latches sat_sticky and
    bumps sat_count, which saturates at SAT_MAX; out_count counts published
    frames and holds at 8'hFF.  A non-clamped frame clears both direction flags.
  * with pdm_tick low the whole filter holds, phase included -- the withdrawn
    oversample clock is the deliberately corrupt case.

Stimulus contract shared with sim/tb_ips_pdm_decim16.v, one core cycle per beat
(state = lcg32(state) at the head of every beat):
    [0,120)      pdm_in = i&1        alternating 1010, half-scale silence
    [120,240)    pdm_in = 1          stuck high  -> positive saturation
    [240,360)    pdm_in = 0          stuck low   -> negative saturation
    [360,700)    pdm_in = ((i%16) < ((i-360)//20))   duty ramp, linear region
    [700,960)    pdm_in = (state>>7)&1               LCG dither
    [960,1000)   pdm_in = 1 with pdm_tick withdrawn for beats [960,966)
    [1000,1120)  pdm_in = i&1
    [1120,1200)  pdm_in = 1
Folded word order per beat: w1, w2, w3, then a final w1, w2, w3 and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

# Core defaults, exactly as declared in the ANSI header.
R_RATE = 16
OUT_W = 16
GAIN_SH = 4
SAT_MAX = 5

ACC_W = OUT_W + GAIN_SH
R_LAST = R_RATE - 1
HR_BITS = 4
ACC_MASK = (1 << ACC_W) - 1
OUT_MASK = (1 << OUT_W) - 1
SIGN = 1 << (ACC_W - 1)
VAL_MAX = (1 << (OUT_W - 1)) - 1
VAL_MIN = 1 << (OUT_W - 1)          # two's-complement bit pattern of -2**(OUT_W-1)

# Stimulus contract, mirrored from the testbench.
BEATS = 1200
SEED = 0x9ADDECA5
W_DC_HI = 120
W_DC_LO = 240
W_RAMP = 360
W_RAMP_L = 20
W_NOISE = 700
W_GAP = 960
W_CORR = 1000
W_ALT2 = 1120
GAP_A = W_GAP
GAP_B = W_CORR - 34                 # the tick is withdrawn on [960,966)


def stimulus(i, state):
    if i < W_DC_HI:
        pdm = i & 1
    elif i < W_DC_LO:
        pdm = 1
    elif i < W_RAMP:
        pdm = 0
    elif i < W_NOISE:
        pdm = 1 if (i % R_RATE) < ((i - W_RAMP) // W_RAMP_L) else 0
    elif i < W_GAP:
        pdm = (state >> 7) & 1
    elif i < W_CORR:
        pdm = 1
    elif i < W_ALT2:
        pdm = i & 1
    else:
        pdm = 1
    tick = 0 if (GAP_A <= i < GAP_B) else 1
    return tick, pdm


def step(st, tick, pdm):
    if not tick:
        return dict(st)
    nxt = dict(st)
    xi = 1 if pdm else -1
    i1 = u(st['integ1'] + xi, ACC_W)
    i2 = u(st['integ2'] + i1, ACC_W)
    i3 = u(st['integ3'] + i2, ACC_W)
    c1 = u(i3 - st['comb1'], ACC_W)
    c2 = u(c1 - st['comb2'], ACC_W)
    c3 = u(c2 - st['comb3'], ACC_W)
    wide = u(c3 << GAIN_SH, ACC_W)

    nxt['integ1'] = i1
    nxt['integ2'] = i2
    nxt['integ3'] = i3

    clip = wide & OUT_MASK
    sext = u(clip | (ACC_MASK ^ OUT_MASK), ACC_W) if (clip >> (OUT_W - 1)) & 1 else clip
    overflow = wide != sext
    over_neg = 1 if (overflow and (wide & SIGN)) else 0
    over_pos = 1 if (overflow and not (wide & SIGN)) else 0

    if st['phase'] == R_LAST:
        nxt['phase'] = 0
        nxt['comb1'] = i3
        nxt['comb2'] = c1
        nxt['comb3'] = c2
        nxt['pcm'] = VAL_MIN if over_neg else (VAL_MAX if overflow else clip)
        nxt['pcm_hr'] = (wide >> OUT_W) & ((1 << HR_BITS) - 1)
        nxt['pcm_valid'] = 1
        if st['out_count'] != 0xFF:
            nxt['out_count'] = u(st['out_count'] + 1, 8)
        if overflow:
            nxt['sat_sticky'] = 1
            nxt['sat_pos'] = over_pos
            nxt['sat_neg'] = over_neg
            if st['sat_count'] < SAT_MAX:
                nxt['sat_count'] = u(st['sat_count'] + 1, 8)
        else:
            nxt['sat_pos'] = 0
            nxt['sat_neg'] = 0
    else:
        nxt['phase'] = u(st['phase'] + 1, 5)
        nxt['pcm_valid'] = 0
    return nxt


def fold(st):
    # w1 = {19'd0, pcm_valid, sat_pos, sat_neg, sat_sticky, pcm_hr, phase}
    w1 = ((st['pcm_hr'] << 5) | st['phase'] | (st['sat_sticky'] << 9) |
          (st['sat_neg'] << 10) | (st['sat_pos'] << 11) | (st['pcm_valid'] << 12))
    w2 = st['pcm'] & OUT_MASK
    w3 = (st['sat_count'] << 8) | st['out_count']
    return w1, w2, w3


def main():
    st = dict(integ1=0, integ2=0, integ3=0, comb1=0, comb2=0, comb3=0,
              pcm=0, pcm_hr=0, pcm_valid=0, sat_pos=0, sat_neg=0,
              sat_sticky=0, sat_count=0, out_count=0, phase=0)
    state = SEED
    words = []
    for i in range(BEATS):
        state = lcg32(state)
        st = step(st, *stimulus(i, state))
        for w in fold(st):
            words.append(u(w, 32))
    for w in fold(st):
        words.append(u(w, 32))
    words.append(BEATS)
    emit('ips_pdm_decim16', words)


if __name__ == '__main__':
    main()
