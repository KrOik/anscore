"""Independent golden model for ips_rr_arbiter4.

Replays the arbiter contract documented in src/ips_rr_arbiter4.v: four masters,
a registered one-hot grant, cyclic priority scan from the restart point, a grant
that is locked until its owner drops req or acknowledges after HOLD_MIN held
steps, per-master saturating starvation counters, a lock-step service history and
sticky error causes.  Nothing here is copied from simulation output; the gate
compares this digest against the RTL one (docs/IP_CORE_SOP.md trap T1).

Contract steps replayed per enabled rising edge (one beat):
    releasing  = rvalid and (not req[cur] or (ack[cur] and hold >= HOLD_MIN))
    sel_active = not rvalid or releasing
    scanning   = lowest set bit of req taken cyclically from prio_ptr
    grant      = scanning result while sel_active, the held grant otherwise
    prio_ptr   = grant index + 1 whenever a grant is valid, frozen while idle
    starve_j   = 0 unless j is pending and ungranted, else saturating at LIMIT
    starve_hit / err_seen sticky, err_cause latches the first cause
    txn_count  counts released transactions, saturating at 0xFF
Stimulus contract shared with sim/tb_ips_rr_arbiter4.v (same phase schedule,
same LCG position per index, disabled beats step neither the DUT nor the fold):
    state = state * 1664525 + 1013904223  (mod 2**32), starting from 0x2A5B7C04
Observed word order per beat, matching the testbench fold:
    W0 = {svc_hist, starve_hit, hold, grant_valid, fair_ok, grant_idx, prio_ptr,
          grant} packed right-aligned, then starve_all, starve_max, txn_count,
    {err_cause, err_seen}; the run closes with txn_count, that error word,
    starve_all and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

BEATS = 420
SEED = 0x2A5B7C04

# Contract constants read straight off the core's header comment.
STARVE_LIMIT = 20        # 6'd20, the per-master saturation point
HOLD_MIN = 2             # 3'd2, held steps required before an ack releases
PRIO_INIT = 0            # 2'd0, restart point out of reset
HOLD_SAT = 6             # 3'h6, the hold counter never exceeds this
TXN_SAT = 0xFF           # 8'hFF, transaction counter saturation
IDX_BITS = 4             # four masters

ERR_NONE = 0
ERR_MPOP_ACK = 1
ERR_ACK_NOG = 2
ERR_STARVE = 3


def bit(vec, idx):
    return (vec >> idx) & 1


def rotate_first(req, base):
    """Cyclic-priority scan: lowest request bit at or after `base`, wrapping."""
    for off in range(IDX_BITS):
        idx = (base + off) % IDX_BITS
        if bit(req, idx):
            return 1 << idx, idx
    return 0, 0


def popcount(vec):
    n = 0
    for j in range(IDX_BITS):
        n += bit(vec, j)
    return n


def phase_inputs(i, state, grant):
    """The testbench phase schedule, in the same order it is written there."""
    if i < 20:
        req, ack = 0, 0
    elif i < 36:
        m = ((i - 20) // 4) % IDX_BITS
        req = 1 << m
        ack = grant if ((i - 20) % 4) == 3 else 0
    elif i < 100:
        req, ack = 0xF, grant
    elif i < 165:
        req, ack = 0xF, 0
    elif i < 172:
        req, ack = 0xF & (~grant & 0xF), 0
    elif i < 180:
        req = 0
        slot = (i - 172) % 6
        ack = {0: 0x4, 2: 0xC, 4: 0x2}.get(slot, 0)
    elif i < 360:
        req = state & 0xF
        ack = grant if bit(state, 15) else 0
    else:
        req, ack = 0, 0
    return req, ack


def beat_enabled(i):
    return not (i >= 180 and (i % 37) == 11)


def fair_distinct(hist):
    h = [(hist >> (2 * k)) & 0x3 for k in range(4)]
    for a in range(IDX_BITS):
        for b in range(a + 1, IDX_BITS):
            if h[a] == h[b]:
                return 0
    return 1


def main():
    rvalid = 0
    rgnt = 0
    cur = 0
    hold = 0
    prio = PRIO_INIT
    starve = [0, 0, 0, 0]
    starve_hit = 0
    svc_hist = 0
    txn = 0
    cause = ERR_NONE
    seen = 0

    state = SEED
    words = []

    for i in range(BEATS):
        req, ack = phase_inputs(i, state, rgnt)
        state = lcg32(state)
        if not beat_enabled(i):
            continue

        # ---- grant decision: keep the held master unless it has released ----
        rel_drop = rvalid and not bit(req, cur)
        rel_ack = rvalid and bit(ack, cur) and hold >= HOLD_MIN
        releasing = rel_drop or rel_ack
        sel_active = (not rvalid) or releasing

        if sel_active:
            nvalid = 1 if req != 0 else 0
            ngnt, nidx = rotate_first(req, prio)
            if nvalid == 0:
                ngnt, nidx = 0, 0
        else:
            nvalid = 1
            ngnt, nidx = rgnt, cur

        # ---- starvation: grows only while pending and ungranted, saturating --
        hit = 0
        nxt = []
        for j in range(IDX_BITS):
            pd = bit(req, j)
            gr = nvalid and bit(ngnt, j)
            if not pd or gr:
                sn = 0
            elif starve[j] >= STARVE_LIMIT:
                sn = starve[j]
            else:
                sn = starve[j] + 1
            if sn == STARVE_LIMIT and pd and not gr:
                hit |= 1 << j
            nxt.append(sn)

        ack_multi = popcount(ack) >= 2
        ack_nog = (ack != 0) and not rvalid
        any_hit = hit != 0

        # ---- register updates ---------------------------------------------
        rvalid, rgnt, cur = nvalid, ngnt, nidx
        if nvalid:
            prio = u(nidx + 1, 2)
        if not nvalid or sel_active:
            hold = 0
            if nvalid and sel_active:
                svc_hist = u((svc_hist << 2) | nidx, 8)
        elif hold < HOLD_SAT:
            hold += 1
        if releasing and txn != TXN_SAT:
            txn = u(txn + 1, 8)
        starve = nxt
        starve_hit |= hit
        if ack_multi:
            seen |= 1 << ERR_MPOP_ACK
        if ack_nog:
            seen |= 1 << ERR_ACK_NOG
        if any_hit:
            seen |= 1 << ERR_STARVE
        if cause == ERR_NONE:
            if ack_multi:
                cause = ERR_MPOP_ACK
            elif ack_nog:
                cause = ERR_ACK_NOG
            elif any_hit:
                cause = ERR_STARVE

        # ---- fold the beat's observed words --------------------------------
        words.append(u((svc_hist << 17) | (starve_hit << 13) | (hold << 10)
                       | (rvalid << 9) | (fair_distinct(svc_hist) << 8)
                       | (cur << 6) | (prio << 4) | rgnt, 32))
        words.append(u((starve[3] << 18) | (starve[2] << 12)
                       | (starve[1] << 6) | starve[0], 32))
        words.append(u(max(starve), 32))
        words.append(u(txn, 32))
        words.append(u((cause << 4) | seen, 32))

    words.append(u(txn, 32))
    words.append(u((cause << 4) | seen, 32))
    words.append(u((starve[3] << 18) | (starve[2] << 12)
                   | (starve[1] << 6) | starve[0], 32))
    words.append(u(BEATS, 32))

    emit("ips_rr_arbiter4", words)


if __name__ == "__main__":
    main()
