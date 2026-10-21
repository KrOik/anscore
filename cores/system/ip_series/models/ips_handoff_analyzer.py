"""Independent golden model for ips_handoff_analyzer.

Written from the core's documented contract, never from simulation output
(docs/IP_CORE_SOP.md trap T1); the gate compares this digest against the RTL one.

Contract re-implemented here
  * `busy` is the registered burst window: it follows `win` with one beat of delay.
    A beat is OBSERVED iff busy and win are both high, i.e. the opening beat and the
    closing beat are not observed.
  * handoff  = observed beat with valid && ready          -> hnd
    dead     = observed beat with valid && !ready         -> dead
    underrun = observed beat with ready && !valid         -> undr
    overrun  = observed beat with !valid whose previous OBSERVED beat had valid &&
               !ready -- the producer withdrew a beat the consumer never took -> ovr
  * stall is the length of the dead-cycle run in progress; it grows on a dead cycle
    and returns to zero on the first observed beat that is not dead.  mxstall books
    a run when the run ends; a run still growing at the closing beat is booked by
    the ledger too, so the recorded maximum never misses a burst tail.
  * dead and stall saturate at TRIM_AT; FL_TRIM marks the beat that tried to push
    dead past that ceiling, FL_LONG the beat at which a run reached TRIP_AT.
  * flags are sticky inside a burst (FL_OVR, FL_UNDR, FL_LONG, FL_TRIM, FL_RUN,
    FL_XFER) and are cleared by the closing beat only.
  * on the closing beat the ledger (lhnd, ldead, lundr, lovr, lmxstall, lflags)
    books the burst, the live bank re-zeros in the SAME beat, burst_n steps, top_hnd
    takes the handoff high-water mark, and lflags gains FL_CLEAN (burst had no dead
    cycle) and/or FL_EMPTY (burst booked no handoff).
  * every register is gated by clk_en; on a disabled beat nothing moves.

Stimulus contract shared with sim/tb_ips_handoff_analyzer.v (one LCG step per beat
index, state[-1] = SEED):  state = state*1664525 + 1013904223 (mod 2**32).  win /
valid / ready / clk_en per beat index come from the ten-burst table in `plan()`
below, which is written out again (independently, as a schedule) from the same
coverage list the testbench header documents.

Observed word order per beat, matching the testbench fold (16 words):
    hnd, dead, stall, mxstall, undr, ovr, flags, lhnd, ldead, lmxstall, lundr, lovr,
    lflags, burst_n, top_hnd, (busy << 1) | done;  then after the loop burst_n,
    top_hnd, lhnd, lmxstall and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

BEATS = 300
SEED = 0x1A2B3C4D

# the core's documented block constants
TRIP_AT = 0x08
TRIM_AT = 0x3F
FL_OVR = 0x01
FL_UNDR = 0x02
FL_LONG = 0x04
FL_TRIM = 0x08
FL_CLEAN = 0x10
FL_EMPTY = 0x20
FL_RUN = 0x40
FL_XFER = 0x80


def _inRange(index, lo, hi):
    return lo <= index <= hi


def plan(index, state):
    """The input vector the analyser sees at beat `index`.

    Burst table (beat index, window level, producer valid, consumer ready):
      0..5    idle
      6..8    window armed, nothing presented        -> opening beat not observed
      9..26   18 accepted beats, zero dead cycles
      27      window open, idle
      28      window low -> burst 1 books
      31..34  valid held, consumer late
      35      accepted
      36..43  eight-beat stall (the recorded maximum of this burst)
      44..47  accepted
      48      valid held, not accepted
      49..64  valid WITHDRAWN after the unaccepted beat -> overrun
      65..67  ready with no valid -> underrun
      68..69  window open, idle
      70      window low -> burst 2 books
      75..79  accepted beats
      80      window low while valid&&ready -> burst 3 books
      81..87  accepted beats
      88      window low -> burst 4 books (back-to-back with burst 3)
      89..95  ready with no valid, no handoff at all
      96      window low -> burst 5 books FL_EMPTY
      99..197 window open: 100..190 endless stall, 191..196 accepted
      198     window low -> burst 6 books the saturated counters
      211..228 alternating dead runs of 3, 3, 4 and 1 beat with accepted beats
      229     window low -> burst 7 books
      230..246 eight-beat stall, seven accepted beats, one underrun
      247     window low -> burst 8 books
      248..274 eight underruns, eight-beat stall, nine accepted beats
      275     window low -> burst 9 books
      276..291 random traffic from the LCG
      292     window low -> burst 10 books
      293..299 idle
    """
    win = 0
    valid = 0
    ready = 0
    clk_en = 0 if (_inRange(index, 116, 123) or _inRange(index, 295, 298)) else 1

    if _inRange(index, 6, 8):
        win = 1
    elif _inRange(index, 9, 26):
        win = valid = ready = 1
    elif index == 27:
        win = 1
    elif _inRange(index, 31, 34):
        win = valid = 1
    elif index == 35:
        win = valid = ready = 1
    elif _inRange(index, 36, 43):
        win = valid = 1
    elif _inRange(index, 44, 47):
        win = valid = ready = 1
    elif index == 48:
        win = valid = 1
    elif _inRange(index, 49, 64):
        win = 1
    elif _inRange(index, 65, 67):
        win = ready = 1
    elif _inRange(index, 68, 69):
        win = 1
    elif _inRange(index, 75, 79):
        win = valid = ready = 1
    elif index == 80:
        valid = ready = 1
    elif _inRange(index, 81, 87):
        win = valid = ready = 1
    elif _inRange(index, 89, 95):
        win = ready = 1
    elif index == 99:
        win = 1
    elif _inRange(index, 100, 190):
        win = valid = 1
    elif _inRange(index, 191, 196):
        win = valid = ready = 1
    elif index == 197:
        win = 1
    elif _inRange(index, 211, 214):
        win = valid = 1
    elif index == 215:
        win = valid = ready = 1
    elif _inRange(index, 216, 218):
        win = valid = 1
    elif _inRange(index, 219, 222):
        win = valid = ready = 1
    elif _inRange(index, 223, 226):
        win = valid = 1
    elif index == 227:
        win = valid = ready = 1
    elif index == 228:
        win = valid = 1
    elif index == 230:
        win = 1
    elif _inRange(index, 231, 238):
        win = valid = 1
    elif _inRange(index, 239, 245):
        win = valid = ready = 1
    elif index == 246:
        win = ready = 1
    elif index == 248:
        win = 1
    elif _inRange(index, 249, 256):
        win = ready = 1
    elif _inRange(index, 257, 264):
        win = valid = 1
    elif _inRange(index, 265, 273):
        win = valid = ready = 1
    elif index == 274:
        win = 1
    elif _inRange(index, 276, 291):
        win = 1
        valid = (state >> 0) & 1
        ready = (state >> 5) & 1
    return win, valid, ready, clk_en


def main():
    trace = '--trace' in sys.argv
    hnd = dead = stall = mxstall = undr = ovr = flags = 0
    lhnd = ldead = lmxstall = lundr = lovr = lflags = 0
    burst_n = top_hnd = 0
    busy = 0
    done = 0
    p_open = p_valid = p_ready = 0
    state = SEED
    words = []

    for index in range(BEATS):
        state = lcg32(state)
        win, valid, ready, clk_en = plan(index, state)

        # -- combinational decode of this beat (all reads are pre-edge) ----
        opening = 1 if (win and not busy) else 0
        closing = 1 if (busy and not win) else 0
        op = 1 if (busy and win) else 0

        acc = 1 if (op and valid and ready) else 0
        stl = 1 if (op and valid and not ready) else 0
        und = 1 if (op and not valid and ready) else 0
        ovr_e = 1 if (op and not valid and p_open and p_valid and not p_ready) else 0

        grow = 1 if (stl and stall != TRIM_AT) else 0
        dead_grow = 1 if (stl and dead != TRIM_AT) else 0
        trip = 1 if (grow and u(stall + 1, 8) == TRIP_AT) else 0
        saturate = 1 if (stl and dead == TRIM_AT) else 0
        fold = 1 if (not stl and stall > mxstall) else 0
        mx_n = stall if fold else mxstall
        stall0 = stall                     # pre-edge run length, as the RTL reads it
        set_n = ((FL_OVR if ovr_e else 0) | (FL_UNDR if und else 0)
                 | (FL_LONG if trip else 0) | (FL_TRIM if saturate else 0)
                 | (FL_RUN if op else 0) | (FL_XFER if acc else 0))
        verd_n = ((FL_CLEAN if dead == 0 else 0) | (FL_EMPTY if hnd == 0 else 0))

        if clk_en:
            if closing:
                lhnd, ldead, lundr, lovr = hnd, dead, undr, ovr
                lmxstall = u(mx_n, 8)
                lflags = u(flags | verd_n, 8)
                if hnd > top_hnd:
                    top_hnd = hnd
                burst_n = u(burst_n + 1, 8)
                hnd = dead = stall = mxstall = undr = ovr = flags = 0
            else:
                if acc:
                    hnd = u(hnd + 1, 8)
                if dead_grow:
                    dead = u(dead + 1, 8)
                if und:
                    undr = u(undr + 1, 8)
                if ovr_e:
                    ovr = u(ovr + 1, 8)
                if stl:
                    if grow:
                        stall = u(stall + 1, 8)
                elif stall != 0:
                    stall = 0
                if fold:
                    mxstall = stall0       # the run that just ended, pre-edge length
                if set_n:
                    flags = u(flags | set_n, 8)
            busy = win
            done = closing
            p_open, p_valid, p_ready = op, valid, ready

        words += [u(hnd, 32), u(dead, 32), u(stall, 32), u(mxstall, 32),
                  u(undr, 32), u(ovr, 32), u(flags, 32), u(lhnd, 32), u(ldead, 32),
                  u(lmxstall, 32), u(lundr, 32), u(lovr, 32), u(lflags, 32),
                  u(burst_n, 32), u(top_hnd, 32), u((busy << 1) | done, 32)]
        if trace:
            print("DBG %d win=%d val=%d rdy=%d en=%d | hnd=%d dead=%d st=%d mx=%d "
                  "und=%d ovr=%d fl=%02x | L%d/%d/%d/%d/%d/%d/%02x bn=%d top=%d"
                  % (index, win, valid, ready, clk_en, hnd, dead, stall, mxstall,
                     undr, ovr, flags, lhnd, ldead, lmxstall, lundr, lovr, lflags,
                     burst_n, top_hnd))

    words += [u(burst_n, 32), u(top_hnd, 32), u(lhnd, 32), u(lmxstall, 32), BEATS]
    emit('ips_handoff_analyzer', words)


if __name__ == '__main__':
    main()
