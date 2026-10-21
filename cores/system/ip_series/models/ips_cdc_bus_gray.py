"""Independent golden model for ips_cdc_bus_gray.

Written from the core's documented contract only (docs/IP_CORE_SOP.md trap T1):

  source domain, on src_tick
      bin_next = (bin_ptr + src_step) mod 2**PTR_W
      bin_ptr  = bin_next
      gray_q   = bin_next ^ (bin_next >> 1)            (Gray encode)
  destination domain, on dst_tick, all from the pre-edge register values
      delta = sync2 ^ sync1, dl = delta & (delta - 1)
      multi_hit = dl != 0                             (>1 bit changed: not atomic)
      any_hit   = delta != 0                          (the synced word moved)
      sync1 = gray_q, sync2 = sync1
      multi_hit           -> err_sticky set, err_count + 1 (4-bit wrap)
      delta != 0          -> sync_count + 1, hold_count = 0
      otherwise           -> hold_count + 1
  bin_dec = Gray decode of sync2 (XOR cascade from the MSB down)

Stimulus contract shared with sim/tb_ips_cdc_bus_gray.v, beat i:
  src_tick = (i % 7 == 0), dst_tick = (i % 5 == 0),
  src_step = 1 for i < 40, else 2 when i % 7 == 2, else 3 when i % 13 == 5, else 1.
Folded word order per beat, matching the testbench (PTR_W buses carried in the
6-bit testbench wires):
    {bin_ptr, gray_q}, {sync1, sync2}, {err_sticky, bin_dec, err_count},
    {sync_count, hold_count}; then BEATS once.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, u

PTR_W = 4
TBW = 6                     # the testbench samples every PTR_W bus two bits wide
BEATS = 500


def step_at(n):
    if n < 40:
        return 1
    if n % 7 == 2:
        return 2
    if n % 13 == 5:
        return 3
    return 1


def bin2gray(b):
    return u(b ^ (b >> 1), PTR_W)


def gray2bin(g):
    b = u(g, PTR_W)
    for k in range(PTR_W - 2, -1, -1):
        bit = ((b >> (k + 1)) & 1) ^ ((g >> k) & 1)
        b = (b & ~(1 << k)) | (bit << k)
    return u(b, PTR_W)


def main():
    bin_ptr = 0
    gray_q = 0
    sync1 = 0
    sync2 = 0
    err_sticky = 0
    err_count = 0
    sync_count = 0
    hold_count = 0
    words = []

    for i in range(BEATS):
        src_tick = (i % 7 == 0)
        dst_tick = (i % 5 == 0)
        src_step = u(step_at(i), PTR_W)

        if dst_tick:
            delta = u(sync2 ^ sync1, PTR_W)
            dl = u(delta & u(delta - 1, PTR_W), PTR_W)
            multi = (delta != 0) and (dl != 0)
            anyc = (delta != 0)
            n_sync1 = gray_q
            n_sync2 = sync1
            n_err_sticky = 1 if (err_sticky or multi) else 0
            n_err_count = u(err_count + 1, 4) if multi else err_count
            if anyc:
                n_sync_count = u(sync_count + 1, 4)
                n_hold_count = 0
            else:
                n_sync_count = sync_count
                n_hold_count = u(hold_count + 1, 4)
            sync1, sync2 = n_sync1, n_sync2
            err_sticky, err_count = n_err_sticky, n_err_count
            sync_count, hold_count = n_sync_count, n_hold_count

        if src_tick:
            bin_ptr = u(bin_ptr + src_step, PTR_W)
            gray_q = bin2gray(bin_ptr)

        words.append(u((bin_ptr << TBW) | gray_q, 32))
        words.append(u((sync1 << TBW) | sync2, 32))
        words.append(((err_sticky & 1) << (TBW + PTR_W)) |
                     (gray2bin(sync2) << PTR_W) | (err_count & 0xF))
        words.append(((sync_count & 0xF) << 4) | (hold_count & 0xF))

    words.append(BEATS)
    emit('ips_cdc_bus_gray', words)


if __name__ == '__main__':
    main()
