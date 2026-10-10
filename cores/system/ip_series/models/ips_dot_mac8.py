"""Independent golden model for ips_dot_mac8.

Written from the core's documented contract, not from simulation output
(docs/IP_CORE_SOP.md trap T1): eight signed lanes arrive as FLAT bundles, one
lane is consumed per multiply beat through one time-shared multiplier, and each
consumed product is added into a saturating int32 accumulator whose sum is
formed in ACCW+GUARD bits and clamped back to ACCW every beat.

Contract as implemented by src/ips_dot_mac8.v and observed by
sim/tb_ips_dot_mac8.v:
  * lane j of a vector is av[j*AW +: AW] * bv[j*BW +: BW], j = 0..7.
  * base is 0 for lane 0 when the accepted frame flag `first` was set, otherwise
    the accumulator carried in from the previous vector.
  * p_j = (a_j * b_j) >>> PSH with PSH = 0, so the accumulation is exact.
  * S = base + p_j; if S fits in ACCW signed bits acc = S, else acc is clamped
    to +int32_max / -int32_min and that beat counts as a saturating beat.
  * The published observation is taken on the beat that consumes lane 7:
    prod is lane 7's raw product, headroom/sat_pos/sat_neg describe that last
    beat, sat_count counts saturating beats modulo 256, ovf_sticky latches,
    pub_first is the accepted frame flag and vec_count counts published vectors.

Stimulus contract shared with sim/tb_ips_dot_mac8.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0xD07A9000,
    eight draws per vector, d0..d3 -> av = {d3,d2,d1,d0}, d4..d7 -> bv,
    directed vectors by idx % 64: 15 -> all lanes zero, 31 -> every lane
    -32768 * -32768, 47 -> every lane -32768 * +32767, 63 -> even lanes -32768
    and odd lanes +32767 against +32767.  first = (idx % 32 == 0).

Observed word order per published vector, matching the testbench fold:
    prod, {phase, headroom, sat_pos, sat_neg}, acc,
    {sat_count, ovf_sticky, pub_first}, then vec_count, sat_count, VECTORS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, headroom_bits, s, u

AW = 16
BW = 16
ACCW = 32
GUARD = 4
PSH = 0
LANES = 8
VECTORS = 256
SEED = 0xD07A9000

TB_HEADROOM_BITS = GUARD + 1      # the testbench samples one bit wider than GUARD
PHASE_AT_PUBLISH = LANES - 1      # the publishing beat consumed the last lane

A_LO = -(1 << (ACCW - 1))
A_HI = (1 << (ACCW - 1)) - 1


def draw(state):
    return (state * 1664525 + 1013904223) & MASK32


def build_vector(idx):
    """Return (lane_a, lane_b, first) for vector idx, mirroring the TB task."""
    words_a = SEED_A[idx]
    words_b = SEED_B[idx]
    lanes_a = []
    lanes_b = []
    for j in range(LANES):
        word = words_a[j // 2]
        half = (word >> 16) if (j & 1) else word
        lanes_a.append(s(half & 0xFFFF, AW))
        word = words_b[j // 2]
        half = (word >> 16) if (j & 1) else word
        lanes_b.append(s(half & 0xFFFF, BW))

    m = idx % 64
    if m == 15:
        lanes_a = [0] * LANES
        lanes_b = [0] * LANES
    elif m == 31:
        lanes_a = [-(1 << (AW - 1))] * LANES
        lanes_b = [-(1 << (BW - 1))] * LANES
    elif m == 47:
        lanes_a = [-(1 << (AW - 1))] * LANES
        lanes_b = [(1 << (BW - 1)) - 1] * LANES
    elif m == 63:
        lanes_a = [((1 << (AW - 1)) - 1) if (j & 1) else -(1 << (AW - 1))
                   for j in range(LANES)]
        lanes_b = [(1 << (BW - 1)) - 1] * LANES

    return lanes_a, lanes_b, 1 if (idx % 32) == 0 else 0


def make_stimulus():
    """Run the shared LCG stimulus contract once, up front."""
    global SEED_A, SEED_B
    state = SEED
    SEED_A = []
    SEED_B = []
    for _ in range(VECTORS):
        words = []
        for _k in range(8):
            state = draw(state)
            words.append(state)
        SEED_A.append(words[0:4])
        SEED_B.append(words[4:8])


def accumulate(acc, lanes_a, lanes_b, first):
    """One vector through the time-shared multiply + saturating adder."""
    sat_pos = 0
    sat_neg = 0
    saturations = 0
    prod = 0
    grow = 0
    for j in range(LANES):
        raw = lanes_a[j] * lanes_b[j]
        p = raw >> PSH                       # arithmetic shift, PSH = 0 here
        base = 0 if (j == 0 and first) else acc
        total = base + p
        # the guard slice the RTL reports, then the clamp back to ACCW bits
        grow = headroom_bits(total, ACCW, GUARD)
        sign_bit = (total >> (ACCW - 1)) & 1
        if grow == (sign_bit * ((1 << GUARD) - 1)):
            acc = s(total, ACCW)
            sat_pos = 0
            sat_neg = 0
        else:
            unclipped_msb = (total >> (ACCW + GUARD - 1)) & 1
            sat_neg = 1 if unclipped_msb else 0
            sat_pos = 0 if unclipped_msb else 1
            acc = A_LO if unclipped_msb else A_HI
            saturations += 1
        prod = raw
    return acc, prod, grow, sat_pos, sat_neg, saturations


def main():
    make_stimulus()

    acc = 0
    sat_count = 0
    sticky = 0
    vec_count = 0
    words = []

    for idx in range(VECTORS):
        lanes_a, lanes_b, first = build_vector(idx)
        acc, prod, grow, sat_pos, sat_neg, nsat = accumulate(
            acc, lanes_a, lanes_b, first)
        sat_count = (sat_count + nsat) & 0xFF
        if nsat:
            sticky = 1
        vec_count = (vec_count + 1) & 0xFF

        headroom = grow & ((1 << TB_HEADROOM_BITS) - 1)
        words.append(u(prod, ACCW))
        words.append((PHASE_AT_PUBLISH << 7) | (headroom << 2) |
                     ((sat_pos & 1) << 1) | (sat_neg & 1))
        words.append(u(acc, ACCW))
        words.append((sat_count << 2) | (sticky << 1) | (first & 1))

    words.append(vec_count)
    words.append(sat_count)
    words.append(VECTORS)

    emit('ips_dot_mac8', words)


if __name__ == '__main__':
    main()
