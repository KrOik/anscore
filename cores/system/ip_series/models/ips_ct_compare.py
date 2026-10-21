"""Independent golden model for ips_ct_compare.

Written from the core's published contract (whole-stream content/length
comparison with an accumulate-never-exit difference register), not from the RTL
and never from simulation output (docs/IP_CORE_SOP.md trap T1).

Contract implemented here:
    per beat: d = cand ^ ref
              acc_next = rol_W(acc, ROT_BITS) | d
              on the end-of-stream beat whose consumed length differs from the
              length latched at cmp_start, acc_next is further xored with
              LEN_BAD_CONST and len_err is raised (sticky until the next restart)
              beat/match/mismatch counters advance on EVERY beat, including the
              ones that arrive after end-of-stream
Geometry: WIDTH=32, LEN_BITS=12, ROT_BITS=5, LEN_BAD_CONST=0xD2E70001.

Stimulus contract shared with sim/tb_ips_ct_compare.v (test-only pattern):
    state = state * 1664525 + 1013904223 (mod 2**32) from seed 0x5E45D000
    per episode: exp = 8 + state[3:0], dsel = state[7:5] selecting the length
    delta from (0, 1, -1, 2, -2, 3, -3, 0), extra = state[13:12] post-stream
    beats; per data beat qual = state[11:10] selects identical / inverted /
    0x5A5A5A5A / 0x00FF00FF candidate masking.
Folded word order per beat: diff_acc, match_cnt, mismatch_cnt, beat_cnt,
exp_cnt, {cmp_done, len_err}; then one idle beat plus the settled tail snapshot
(the same six words), then EPISODES and the DUT parameter stamp (WIDTH,
LEN_BITS, ROT_BITS, LEN_BAD_CONST).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

WIDTH = 32
LEN_BITS = 12
ROT_BITS = 5
LEN_BAD_CONST = 0xD2E70001

EPISODES = 20
SEED = 0x5E45D000
DELTAS = (0, 1, -1, 2, -2, 3, -3, 0)

WMASK = (1 << WIDTH) - 1
LMASK = (1 << LEN_BITS) - 1


def rol(value, amount):
    a = amount % WIDTH
    return ((value << a) | (value >> (WIDTH - a))) & WMASK


class Comparator(object):
    """Cycle-accurate shadow of the core's registered state."""

    def __init__(self):
        self.acc = 0
        self.match = 0
        self.unmatch = 0
        self.beat = 0
        self.exp = 0
        self.len_err = 0
        self.done = 0

    def restart(self, exp_len):
        self.acc = 0
        self.match = 0
        self.unmatch = 0
        self.beat = 0
        self.exp = exp_len & LMASK
        self.len_err = 0
        self.done = 0

    def consume(self, cand, ref, last):
        d = (cand ^ ref) & WMASK
        acc_next = rol(self.acc, ROT_BITS) | d
        beat_next = (self.beat + 1) & LMASK
        if last and beat_next != self.exp:
            self.acc = (acc_next ^ LEN_BAD_CONST) & WMASK
            self.len_err = 1
        else:
            self.acc = acc_next & WMASK
        self.beat = beat_next
        if d == 0:
            self.match = (self.match + 1) & LMASK
        else:
            self.unmatch = (self.unmatch + 1) & LMASK
        if last:
            self.done = 1

    def words(self):
        return [u(self.acc, 32), u(self.match, 32), u(self.unmatch, 32),
                u(self.beat, 32), u(self.exp, 32),
                ((self.done & 1) << 1) | (self.len_err & 1)]


def candidate(state, qual):
    if qual == 0:
        return state
    if qual == 1:
        return (~state) & MASK32
    if qual == 2:
        return (state ^ 0x5A5A5A5A) & MASK32
    return (state ^ 0x00FF00FF) & MASK32


def main():
    dut = Comparator()
    state = SEED
    words = []

    for _ in range(EPISODES):
        state = lcg32(state)
        exp_i = 8 + (state & 0xF)
        dlt = DELTAS[(state >> 5) & 0x7]
        alen = exp_i + dlt
        extra = (state >> 12) & 0x3

        dut.restart(exp_i)
        words += dut.words()

        for b in range(alen):
            state = lcg32(state)
            cand = candidate(state, (state >> 10) & 0x3)
            dut.consume(cand, state, b == alen - 1)
            words += dut.words()

        for _ in range(extra):
            state = lcg32(state)
            dut.consume(state, (~state) & MASK32, False)
            words += dut.words()

    # idle beat: the registers hold, so the same snapshot is folded once more
    words += dut.words()
    # settled tail snapshot folded by the testbench after the idle beat
    words += dut.words()

    words.append(EPISODES)
    words.append(WIDTH)
    words.append(LEN_BITS)
    words.append(ROT_BITS)
    words.append(LEN_BAD_CONST)

    emit('ips_ct_compare', words)


if __name__ == '__main__':
    main()
