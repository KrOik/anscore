"""Independent golden model for ips_fifo_sync_fwft.

Written from the core's documented contract only (docs/IP_CORE_SOP.md trap T1):

  PW       = clog2(DEPTH), LAST = DEPTH-1, FULL_LVL = DEPTH
  full     = (level == FULL_LVL)          empty = (level == 0)
  do_write = wr_req && !full              do_read = rd_req && !empty
  on do_write : mem[wptr] = wdata, wptr = 0 if wptr == LAST else wptr + 1
  on do_read  : rptr = 0 if rptr == LAST else rptr + 1
  on exactly one of do_write / do_read : level = level +/- 1
  wr_req while full  : ov_flag sticky, ov_count + 1 (4-bit wrap)
  rd_req while empty : uf_flag sticky, uf_count + 1 (4-bit wrap)
  flag_hi = (level_q >= wm_hi), flag_lo = (level_q <= wm_lo)  (registered, so the
               comparison uses the occupancy before this beat)
  rdata = 0 while empty else mem[rptr]   (first word, no read bubble)

Stimulus contract shared with sim/tb_ips_fifo_sync_fwft.v, beat i steps the LCG
first and then drives: state = state*1664525 + 1013904223 mod 2**32,
wdata = state[11:0] (the core sees the low DATA_W bits); requests are
write-only for i < 130, read-only for i < 230, then wr_req = ~state[3] and
rd_req = ~state[1]; wm_hi = 12 below beat 150 else 5; wm_lo = 1 below 260 else 3.
Folded word order per beat, matching the testbench:
    level, rdata, {full, empty, flag_hi, flag_lo, ov_flag, uf_flag},
    {ov_count, uf_count}; then BEATS once.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

DATA_W = 8
DEPTH = 16
BEATS = 500
SEED = 0x13572468


def pw(depth):
    n = 0
    while (1 << n) < depth:
        n += 1
    return n


def wmhi_at(n):
    return 12 if n < 150 else 5


def wmlo_at(n):
    return 1 if n < 260 else 3


def main():
    PW = pw(DEPTH)
    LAST = DEPTH - 1
    FULL_LVL = DEPTH
    LVL_BITS = PW + 1

    mem = [0] * DEPTH
    wptr = 0
    rptr = 0
    level = 0
    flag_hi = 0
    flag_lo = 1
    ov_flag = 0
    uf_flag = 0
    ov_count = 0
    uf_count = 0
    state = SEED
    words = []

    for i in range(BEATS):
        state = (state * 1664525 + 1013904223) & MASK32
        wdata = u(state, DATA_W)
        if i < 130:
            wr_req, rd_req = 1, 0
        elif i < 230:
            wr_req, rd_req = 0, 1
        else:
            wr_req = 1 - ((state >> 3) & 1)
            rd_req = 1 - ((state >> 1) & 1)
        wm_hi = wmhi_at(i)
        wm_lo = wmlo_at(i)

        full = 1 if level == FULL_LVL else 0
        empty = 1 if level == 0 else 0
        level_q = level
        do_write = 1 if (wr_req and not full) else 0
        do_read = 1 if (rd_req and not empty) else 0

        if do_write:
            mem[wptr] = wdata
            wptr = 0 if wptr == LAST else u(wptr + 1, PW)
        if do_read:
            rptr = 0 if rptr == LAST else u(rptr + 1, PW)
        if do_write != do_read:
            level = u(level + 1, LVL_BITS) if do_write else u(level - 1, LVL_BITS)
        if wr_req and full:
            ov_flag = 1
            ov_count = u(ov_count + 1, 4)
        if rd_req and empty:
            uf_flag = 1
            uf_count = u(uf_count + 1, 4)
        flag_hi = 1 if (level_q >= wm_hi) else 0
        flag_lo = 1 if (level_q <= wm_lo) else 0

        new_empty = 1 if level == 0 else 0
        new_full = 1 if level == FULL_LVL else 0
        rdata = 0 if new_empty else mem[rptr]

        words.append(u(level, 32))
        words.append(u(rdata, 32))
        words.append(((new_full & 1) << 5) | ((new_empty & 1) << 4) |
                     ((flag_hi & 1) << 3) | ((flag_lo & 1) << 2) |
                     ((ov_flag & 1) << 1) | (uf_flag & 1))
        words.append(((ov_count & 0xF) << 4) | (uf_count & 0xF))

    words.append(BEATS)
    emit('ips_fifo_sync_fwft', words)


if __name__ == '__main__':
    main()
