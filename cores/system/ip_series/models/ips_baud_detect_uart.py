"""Independent golden model for ips_baud_detect_uart.

Written from the contract in src/ips_baud_detect_uart.v, never from simulation
output (docs/IP_CORE_SOP.md trap T1).

Core rules replayed here:
  * rx is sampled on a tick only and every register moves on an enabled tick only,
    so a beat with tick low or clk_en low freezes the estimator and the run plan
    expressed in quanta stays aligned;
  * rx_q resets to 1'b1 because the line idles high;
  * a high -> low transition opens a run with len = 1, further ticks at the same
    low level step len and len holds at LEN_MAX (an over-long break is reported as
    LEN_MAX rather than wrapping); a low -> high transition closes the run:
    run_valid pulses, meas takes the closed length, len returns to 0 and the state
    returns to idle.  max_len keeps the longest run ever closed and min_len the
    shortest accepted one;
  * classification of a closed run of length w, in this order:
      w < GLITCH                 line noise: the glitch flag latches and the run is
                                 discarded, nothing counts it;
      w < RUN_MIN or w > RUN_MAX out of range: the range flag latches, err_count
                                 steps, the agreement built so far is dropped and a
                                 locked tracker unlocks (unlock_count steps);
      otherwise                  a credible 0 bit: it feeds the estimator, and
                                 min_len/len-based quantities update;
      run_count steps for every non-noise run, accepted or not;
  * estimator, with bit_len the current bit-length estimate and
    tick_est = bit_len >> OS_SHIFT the integer oversample tick:
      idle (agree = 0)           the run seeds the estimate, agree = 1;
      agree != 0, |w - bit_len| <= TOL
                                 the run agrees: the estimate tracks it and when
                                 agree + 1 >= LOCK_N it locks (lock_valid pulses,
                                 lock_count steps, agree returns to 0);
      agree != 0, disagreeing    the run re-seeds, agree = 1;
      locked, agreeing           the estimate tracks it, hold_count steps -- drift
                                 inside TOL is tolerated, which is what keeps a
                                 slightly-off rate locked;
      locked, disagreeing        the tracker unlocks and the run re-seeds;
  * restart clears the agreement and, if locked, counts an unlock; it never
    corrupts a run in progress;
  * counters saturate: err/lock/unlock/hold at 0xF, run_count at 0x3F, agree at 7.

Stimulus plan shared with sim/tb_ips_baud_detect_uart.v: RUNQ(L, sp) pulls the
line low for L quanta and releases it for sp quanta, RSEQ(L, n, sp) repeats it n
times (a burst of 0 bits at bit length L as a run-length estimator sees it),
RSTR(n) holds restart high over n idle beats.  Gap beats (GAPN of them, tick low)
and stall beats (STN of them, clk_en low) are appended inside the first run of the
marked sequences at quantum indices GQ/SQ and repeat that quantum's level, so the
run still closes with exactly L quanta.  The plan walks every boundary of the
default geometry (exact 16, tolerated 18, TOL+1 jump to 14, RUN_MIN 12 and 11,
RUN_MAX 20 and 21, far too fast 6, far too slow 26, noise 1 and 2, a saturating
64-quantum break) and then three LCG-driven sequences sweep the accepted range;
the LCG steps twice per case, exactly as the testbench does.

Folded word order per beat, all from the values observed after that beat's
enabled edge: w1 = (state << 26) | (rx_q << 25) | (locked << 24) | (len << 16) |
(tick_est << 8) | meas; w2 = (agree << 26) | (run_count << 20) |
(run_valid << 19) | (lock_valid << 18) | (glitch << 17) | (range << 16) |
(min_len << 8) | max_len; w3 = (bit_len << 16) | (lock_count << 12) |
(unlock_count << 8) | (hold_count << 4) | err_count.  Then nbeats, then
((lcg & 7) << 12) | (lock_count << 8) | (unlock_count << 4) | err_count.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

# Core defaults, exactly as declared in the ANSI header.
OS_SHIFT = 2
RUN_MIN = 12
RUN_MAX = 20
LOCK_N = 3
TOL = 3
LEN_MAX = 60
GLITCH = 3

S_IDLE = 0
S_LOW = 1
RUN_SAT = 0x3F
CNT_SAT = 0xF

# Testbench stimulus constants.
GAPN = 3
STN = 4
GQ = 5
SQ = 9
SEED = 0xB16B1351

BEATS = []                    # (rx, tick, clk_en, restart) per beat
CHECKS = []                   # (beat index, length the run must have measured)


def beat(rx=1, tick=1, en=1, rst=0):
    BEATS.append((rx, tick, en, rst))


def idleb(count):
    for _ in range(count):
        beat()


def runq(length, space, gq=-1, sq=-1, exp=0):
    for p in range(length):
        beat(rx=0)
        if gq >= 0 and p == gq:
            for _ in range(GAPN):
                beat(rx=0, tick=0)
        if sq >= 0 and p == sq:
            for _ in range(STN):
                beat(rx=0, en=0)
    for p in range(space):
        beat(rx=1)
        if exp > 0 and p == 0:
            CHECKS.append((len(BEATS) - 1, exp))


def rseq(length, count, space, gap, stall, exp=0):
    for j in range(count):
        runq(length, space, GQ if (gap and j == 0) else -1,
             SQ if (stall and j == 0) else -1, exp if j == 0 else 0)


def rstr(count):
    for _ in range(count):
        beat(rst=1)


def build_plan():
    del BEATS[:]
    del CHECKS[:]
    idleb(6)
    rseq(16, 3, 3, True, False, 16)      # exact rate -> lock
    rseq(18, 2, 3, False, True, 18)      # slightly off -> tolerated
    runq(14, 3, exp=14)                  # rate jump of TOL+1 -> unlock
    rseq(14, 2, 1, False, False)         # -> lock again
    rseq(12, 2, 3, False, False, 12)     # RUN_MIN boundary, accepted
    rstr(2)                              # restart while locked
    rseq(11, 2, 3, False, False)         # RUN_MIN-1 -> out of range
    rseq(20, 3, 3, True, False, 20)      # RUN_MAX boundary -> lock
    rseq(21, 2, 3, False, True)          # RUN_MAX+1 -> out of range
    rseq(6, 3, 3, False, False, 6)       # far too fast
    rseq(26, 2, 3, False, False)         # far too slow
    runq(1, 3)                           # line noise
    runq(2, 3)                           # line noise
    runq(64, 4)                          # long break -> saturates
    lcg = SEED
    for c in range(3):
        lcg = lcg32(lcg)
        rseq(12 + (lcg % 9), 2 + ((lcg >> 7) % 3), 2, c == 1, c == 2)
        lcg = lcg32(lcg)
    idleb(4)
    return lcg


def step(st, rx, tick, restart):
    if not tick:
        return
    st['run_valid'] = 0
    st['lock_valid'] = 0
    prev = st['rx_q']
    st['rx_q'] = rx
    if not prev and rx:                             # the low run closed
        w = st['len']
        st['state'] = S_IDLE
        st['len'] = 0
        st['meas'] = w
        st['run_valid'] = 1
        if w > st['max_len']:
            st['max_len'] = w
        if w < GLITCH:
            st['glitch'] = 1                        # line noise, discarded
        else:
            if st['run_c'] != RUN_SAT:
                st['run_c'] = u(st['run_c'] + 1, 6)
            if w < RUN_MIN or w > RUN_MAX:
                st['range'] = 1
                if st['err'] != CNT_SAT:
                    st['err'] = u(st['err'] + 1, 4)
                st['agree'] = 0
                if st['locked']:
                    st['locked'] = 0
                    if st['unlock'] != CNT_SAT:
                        st['unlock'] = u(st['unlock'] + 1, 4)
            else:
                if w < st['min_len']:
                    st['min_len'] = w
                st['tick_est'] = u(w >> OS_SHIFT, 8)
                near = abs(w - st['bit_len']) <= TOL
                if st['locked']:
                    if near:
                        st['bit_len'] = w
                        if st['hold'] != CNT_SAT:
                            st['hold'] = u(st['hold'] + 1, 4)
                    else:
                        st['locked'] = 0
                        st['bit_len'] = w
                        st['agree'] = 1
                        if st['unlock'] != CNT_SAT:
                            st['unlock'] = u(st['unlock'] + 1, 4)
                elif st['agree'] == 0:
                    st['bit_len'] = w
                    st['agree'] = 1
                elif near:
                    st['bit_len'] = w
                    if st['agree'] + 1 >= LOCK_N:
                        st['locked'] = 1
                        st['lock_valid'] = 1
                        st['agree'] = 0
                        if st['lock'] != CNT_SAT:
                            st['lock'] = u(st['lock'] + 1, 4)
                    else:
                        st['agree'] = u(st['agree'] + 1, 3)
                else:
                    st['bit_len'] = w
                    st['agree'] = 1
    elif prev and not rx:                           # a new low run opens
        st['state'] = S_LOW
        st['len'] = 1
    elif st['state'] == S_LOW:
        if st['len'] != LEN_MAX:
            st['len'] = u(st['len'] + 1, 8)
    if restart:
        st['agree'] = 0
        if st['locked']:
            st['locked'] = 0
            if st['unlock'] != CNT_SAT:
                st['unlock'] = u(st['unlock'] + 1, 4)


def fold(st):
    w1 = u((st['state'] << 26) | (st['rx_q'] << 25) | (st['locked'] << 24) |
           (st['len'] << 16) | (st['tick_est'] << 8) | st['meas'], 32)
    w2 = u((st['agree'] << 26) | (st['run_c'] << 20) | (st['run_valid'] << 19) |
           (st['lock_valid'] << 18) | (st['glitch'] << 17) | (st['range'] << 16) |
           (st['min_len'] << 8) | st['max_len'], 32)
    w3 = u((st['bit_len'] << 16) | (st['lock'] << 12) | (st['unlock'] << 8) |
           (st['hold'] << 4) | st['err'], 32)
    return w1, w2, w3


def main():
    lcg = build_plan()
    st = dict(rx_q=1, state=S_IDLE, len=0, meas=0, bit_len=0, min_len=0xFF,
              max_len=0, tick_est=0, agree=0, run_c=0, lock=0, unlock=0, hold=0,
              err=0, locked=0, run_valid=0, lock_valid=0, glitch=0, range=0)
    words = []
    for idx, (rx, tick, en, rst) in enumerate(BEATS):
        if en:
            step(st, rx, tick, rst)
        for beat_idx, want in CHECKS:
            # the marked beats really are the ones where the plan's run closed
            if beat_idx == idx:
                assert st['run_valid'] and st['meas'] == want
        for w in fold(st):
            words.append(w)
    words.append(u(len(BEATS), 32))
    words.append(u(((lcg & 7) << 12) | (st['lock'] << 8) | (st['unlock'] << 4) |
                   st['err'], 32))
    emit('ips_baud_detect_uart', words)


if __name__ == '__main__':
    main()
