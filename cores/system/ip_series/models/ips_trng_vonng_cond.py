"""Independent golden model for ips_trng_vonng_cond.

Derived from the core's published conditioning contract, not from the RTL and
never from simulation output (docs/IP_CORE_SOP.md trap T1):

  * one entropy sample is taken per enabled clock through a SYNC_STAGES-deep shift
    synchroniser; only the settled (last-stage) bit is consumed, and a bit is
    offered only while the run request was high SYNC_STAGES clocks earlier;
  * settled bits are grouped into pairs.  Pair 01 emits a 1, pair 10 emits a 0,
    pairs 00 and 11 are discarded; a first bit with no partner yet leaves
    pair_pending high;
  * bit_cnt counts consumed settled bits, out_bit_cnt counts emitted bits (moving
    exactly when out_valid rises) and disc_pair_cnt counts discarded pairs, so
    bit_cnt == 2*(out_bit_cnt + disc_pair_cnt) + pair_pending at all times;
  * the watchdog counts consumed bits that repeat the previous settled level, the
    initial previous level after a restart being 0.  A repeat that pushes the count
    to STUCK_LIMIT raises stuck_alarm; the count saturates there and the alarm is
    sticky -- a transition or normal output traffic never clears it;
  * cond_start restarts a run: synchroniser, valid pipeline, pairing state,
    counters, watchdog and alarm all clear;
  * every count moves by COUNT_STEP.

Stimulus contract shared with sim/tb_ips_trng_vonng_cond.v: for each of EPISODES
runs one LCG step
    state = state * 1664525 + 1013904223 (mod 2**32), seed 0x77AC0E00
selects kind = state & 3 and warm-up length wlen = 12 + (state & 31).  Per run:
one restart beat, wlen strictly alternating beats, then kind 0 = HOLD_LONG beats
frozen at 0, kind 1 = HOLD_SHORT beats frozen at 1, kind 2 = twice (HOLD_SHORT
frozen at 0 then 1, interleaved with wlen alternating beats), kind 3 = HOLD_LONG
beats frozen at 1; then TAIL_LEN alternating beats.  Four beat-level folds
(bit_cnt, out_bit_cnt, disc_pair_cnt, {stuck_alarm, pair_pending, out_valid,
out_bit}) are taken per beat, including three drain beats with the run request low
and one further quiet beat, and finally EPISODES, HOLD_LONG and the DUT geometry
stamp (CNT_BITS, SYNC_STAGES).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

CNT_BITS = 12
SYNC_STAGES = 2
STUCK_LIMIT = 64
COUNT_STEP = 1

VONN_ONE = 0b01
VONN_ZERO = 0b10

EPISODES = 10
HOLD_LONG = 90
HOLD_SHORT = 24
TAIL_LEN = 12
SEED = 0x77AC0E00


class Cond(object):
    def __init__(self):
        self.sync = [0] * SYNC_STAGES
        self.val = [0] * SYNC_STAGES
        self.first = 0
        self.prev_ent = 0
        self.pending = 0
        self.out_bit = 0
        self.out_valid = 0
        self.alarm = 0
        self.out_cnt = 0
        self.disc_cnt = 0
        self.bit_cnt = 0
        self.wd = 0

    def clear_run(self):
        self.sync = [0] * SYNC_STAGES
        self.val = [0] * SYNC_STAGES
        self.first = 0
        self.prev_ent = 0
        self.pending = 0
        self.alarm = 0
        self.out_cnt = 0
        self.disc_cnt = 0
        self.bit_cnt = 0
        self.wd = 0

    def beat(self, start, run, bit):
        self.out_valid = 0
        if start:
            self.clear_run()
            return

        # shift synchroniser: the newest sample enters at the near end and the
        # settled sample leaves at the far end
        self.sync = [bit] + self.sync[:SYNC_STAGES - 1]
        self.val = [run] + self.val[:SYNC_STAGES - 1]
        ent_bit = self.sync[SYNC_STAGES - 1]
        ent_vld = self.val[SYNC_STAGES - 1]

        if not ent_vld:
            return

        self.bit_cnt = u(self.bit_cnt + COUNT_STEP, CNT_BITS)

        if not self.pending:
            self.first = ent_bit
            self.pending = 1
        else:
            self.pending = 0
            pair = ((self.first << 1) | ent_bit) & 0b11
            if pair == VONN_ONE:
                self.out_bit = 1
                self.out_valid = 1
                self.out_cnt = u(self.out_cnt + COUNT_STEP, CNT_BITS)
            elif pair == VONN_ZERO:
                self.out_bit = 0
                self.out_valid = 1
                self.out_cnt = u(self.out_cnt + COUNT_STEP, CNT_BITS)
            else:
                self.disc_cnt = u(self.disc_cnt + COUNT_STEP, CNT_BITS)

        same = (ent_bit == self.prev_ent)
        if not same:
            self.wd = 0
        else:
            nxt = u(self.wd + COUNT_STEP, CNT_BITS)
            if nxt > STUCK_LIMIT:
                nxt = STUCK_LIMIT
            self.wd = nxt
            if self.wd >= STUCK_LIMIT:
                self.alarm = 1

        self.prev_ent = ent_bit

    def words(self):
        return [u(self.bit_cnt, 32), u(self.out_cnt, 32), u(self.disc_cnt, 32),
                ((self.alarm & 1) << 3) | ((self.pending & 1) << 2)
                | ((self.out_valid & 1) << 1) | (self.out_bit & 1)]

    def frozen(self, length, lvl, words):
        """Drive `length` beats with the entropy pin held at `lvl`."""
        for _ in range(length):
            self.beat(0, 1, lvl)
            words.extend(self.words())


def altern(dut, alt, length, words):
    """Drive `length` beats of strictly alternating pin, folding every beat."""
    for _ in range(length):
        alt ^= 1
        dut.beat(0, 1, alt)
        words.extend(dut.words())
    return alt


def main():
    dut = Cond()
    state = SEED
    alt = 0
    words = []

    for _e in range(EPISODES):
        state = lcg32(state)
        kind = state & 3
        wlen = 12 + (state & 31)

        dut.beat(1, 0, 0)
        words += dut.words()

        alt = altern(dut, alt, wlen, words)

        if kind == 0:
            # long freeze on level 0: the stuck alarm must arm
            dut.frozen(HOLD_LONG, 0, words)
        elif kind == 1:
            # short freeze on level 1: pairs are discarded, no alarm
            dut.frozen(HOLD_SHORT, 1, words)
        elif kind == 2:
            # choppy: two short freezes separated by alternation
            dut.frozen(HOLD_SHORT, 0, words)
            alt = altern(dut, alt, wlen, words)
            dut.frozen(HOLD_SHORT, 1, words)
            alt = altern(dut, alt, wlen, words)
        else:
            # long freeze on level 1: the stuck alarm must arm
            dut.frozen(HOLD_LONG, 1, words)

        alt = altern(dut, alt, TAIL_LEN, words)

    # drain beats with the run request low, then one quiet beat
    for _ in range(4):
        dut.beat(0, 0, alt)
        words += dut.words()

    words.append(EPISODES)
    words.append(HOLD_LONG)
    words.append(CNT_BITS)
    words.append(SYNC_STAGES)

    emit('ips_trng_vonng_cond', words)


if __name__ == '__main__':
    main()
