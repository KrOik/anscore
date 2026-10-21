"""Independent golden model for ips_gpio_irq_bank.

Implements the register / calendar / arbitration semantics of the core straight
from the contract written in the header of src/ips_gpio_irq_bank.v.  It never
reads simulation output; the gate compares this digest against the RTL one
(docs/IP_CORE_SOP.md trap T1).

Stimulus contract shared with sim/tb_ips_gpio_irq_bank.v (one step per enabled
beat, clk_en comes from the testbench divisor and is not part of the model):
    state = state * 1664525 + 1013904223  (mod 2**32), starting from 0x5A170C0D
    pin_in[15:0] = state[15:0]
    bus_addr     = state[3:0]
    bus_we       = state[20]
    bus_wdata    = {16'hA5A5, ~state[15:0]}   so wdata[15:0] = ~state[15:0]
    bus_ack      = (state[13:10] == 0xA)
Folded word order per beat, matching the testbench:
    bus_rdata, pend, pin_out,
    {sync_idx, irq_active, level_any, storm, acked},
    {irq_vec, err_count}, {set_evts, w1c_evts}
then after the loop: pend, err_count, set_evts, BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32

BEATS = 320
SEED = 0x5A170C0D

# Contract constants (mirrors the core's localparams).
SYNC_WRAP = 2
EVT_SAT = 28
INVALID_RD = 0xDEADB100
VEC_BIAS = 5
CNT_SAT = 9

A_DIR, A_POL, A_MIE, A_PEND, A_OUT, A_STAT = 0, 1, 2, 3, 4, 5
M16 = 0xFFFF
M32 = MASK32


def low_bit(vec):
    """Index of the least significant set bit, 0 when the word is empty."""
    for bit in range(16):
        if (vec >> bit) & 1:
            return bit
    return 0


def main():
    state = SEED

    bus_rdata = 0
    pend = 0
    dir_r = 0
    pol_r = M16
    ie_r = 0
    out_r = 0
    sync_meta = 0
    sync_q = 0
    sync_d = M16
    mode_g = 0
    irq_active = 0
    irq_vec = 0
    storm = 0
    acked = 0
    sync_idx = 0
    set_evts = 0
    w1c_evts = 0
    err_count = 0

    words = []
    for _ in range(BEATS):
        state = lcg32(state)
        pin16 = state & M16
        addr = state & 0xF
        we = (state >> 20) & 1
        wlo = (~state) & M16
        bus_ack = 1 if ((state >> 10) & 0xF) == 0xA else 0

        w_dir = bool(we and addr == A_DIR)
        w_pol = bool(we and addr == A_POL)
        w_mie = bool(we and addr == A_MIE)
        w_pend = bool(we and addr == A_PEND)
        w_out = bool(we and addr == A_OUT)
        bad_addr = addr > A_STAT

        ie_next = (((wlo >> 4) & 0xF) * 0x1111) & M16 if w_mie else ie_r
        mode_next = (wlo & 1) if w_mie else mode_g

        rise = sync_q & ((~sync_d) & M16)
        fall = ((~sync_q) & M16) & sync_d
        changed = sync_q ^ sync_d
        edge_arm = ((pol_r & rise) | ((~pol_r & M16) & fall)) & M16
        lev_arm = ((pol_r & sync_q) | ((~pol_r & M16) & (~sync_q & M16))) & M16
        cand = edge_arm if mode_g else lev_arm
        newly = cand & ie_next & (~pend & M16)
        w1c = wlo if w_pend else 0
        pend_nx = 0 if bus_ack else ((pend | newly) & (~w1c & M16))
        arm = pend_nx & ie_next
        vec_nx = low_bit(arm) ^ VEC_BIAS
        level_any_pre = 1 if (pend & (~ie_r & M16) & changed) else 0

        if addr == A_DIR:
            rd = dir_r
        elif addr == A_POL:
            rd = pol_r
        elif addr == A_MIE:
            rd = (mode_g << 4) | (ie_r & 0xF)
        elif addr == A_PEND:
            rd = pend
        elif addr == A_OUT:
            rd = out_r
        elif addr == A_STAT:
            rd = ((err_count << 15) | (w1c_evts << 11) | (set_evts << 6) |
                  (irq_active << 5) | (storm << 4) | (acked << 3) |
                  (level_any_pre << 2) | sync_idx)
        else:
            rd = INVALID_RD

        step = (sync_idx == SYNC_WRAP)

        # commit the enabled beat
        new_sync_q = sync_meta if step else sync_q
        if step:
            sync_meta = pin16
        sync_d = sync_q
        sync_q = new_sync_q
        sync_idx = 0 if step else ((sync_idx + 1) & 0x3)
        pend = pend_nx
        ie_r = ie_next
        mode_g = mode_next
        irq_active = 1 if arm else 0
        irq_vec = vec_nx
        bus_rdata = rd
        if w_dir:
            dir_r = wlo
        if w_pol:
            pol_r = wlo
        if w_out:
            out_r = wlo
        if newly:
            storm = 1 if ((set_evts + 1) & 0x1F) == EVT_SAT else storm
            if set_evts < EVT_SAT:
                set_evts = (set_evts + 1) & 0x1F
        if w_pend and wlo:
            if w1c_evts < CNT_SAT:
                w1c_evts = (w1c_evts + 1) & 0xF
        if we and bad_addr:
            if err_count < CNT_SAT:
                err_count = (err_count + 1) & 0xF
        if bus_ack:
            acked = 1

        level_any_post = 1 if (pend & (~ie_r & M16) & (sync_q ^ sync_d)) else 0

        words.append(bus_rdata & M32)
        words.append(pend)
        words.append((out_r & dir_r) & M32)
        words.append((sync_idx << 4) | (irq_active << 3) | (level_any_post << 2) |
                     (storm << 1) | acked)
        words.append((irq_vec << 4) | err_count)
        words.append((set_evts << 4) | w1c_evts)

    words.append(pend)
    words.append(err_count)
    words.append(set_evts)
    words.append(BEATS)

    emit('ips_gpio_irq_bank', words)


if __name__ == '__main__':
    main()
