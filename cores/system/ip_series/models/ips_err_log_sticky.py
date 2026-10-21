"""Independent golden model for ips_err_log_sticky.

Written from the core's written contract, not from the RTL structure and never from
simulation output (docs/IP_CORE_SOP.md trap T1):

  * NSLOTS = 2**LOG_SLOTS slots, each holding one record packed as
    {timestamp, source code} with the stamp above the source code, so the slot
    stride is TS_W + SRC_W.
  * ts_count is a free-running stamp that steps once per enabled beat; a record
    carries the value the stamp held on the beat that captured it, which makes the
    stored stamps strictly increasing inside a wrap window.
  * Two event channels may fire in one enabled beat and exactly one record is
    written.  The LOWER source code takes the slot, an equal pair resolves to
    channel a.  The loser is dropped: drop_count steps (4 bits, saturating at 14,
    never wrapping) and the duplicate class bit is set, but the loser still sets its
    own bit in the per-source ever-errored word.
  * While the log is full later events never touch a stored record: they step
    ovf_count (OVF_W bits, clamped at 2**OVF_W - 1, never wrapping) and set the
    overflow class bit.  log_full only falls on clr_all, so the first NSLOTS records
    stay authoritative for the whole armed period and stay readable afterwards.
  * rd_en pops the oldest unread record, pulses rd_valid for exactly one beat and
    drops that slot's occupancy bit.  A pop with nothing unread is ignored and sets
    the empty-pop class bit.
  * log_used[k] says slot k holds a record that has not been read yet, so the number
    of used bits always equals n_unread and a write can never land on an unread
    record.  Slot data is only ever replaced by a write into an unused slot: neither
    a pop nor clr_all scrubs data, clr_all simply drops the occupancy, which is what
    makes the stale words unreachable.
  * clr_all dominates its beat: everything re-arms except src_sticky, which is the
    ever-errored history and only falls to stk_clr; events on the same beat as
    stk_clr still latch because the clear is applied first.

Stimulus contract shared with sim/tb_ips_err_log_sticky.v (the schedule is restated
here from that file's documented beat plan):
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x5EED1234, advanced once
    per beat index n = 0..BEATS-1 before the inputs for that beat are decoded
    phase A  few events then all readable  (events 10/13/17, pops 22..25, clr 26)
    phase B  exactly NSLOTS events        (events 30/34/38/42, pops 50..54, clr 58)
    phase C  fill then a long storm       (writes 60..63, event every beat 70..230,
                                           duplicate every 6th beat, pops 240..243,
                                           clr 250, sticky clear 251)
    phase D  every source once            (events 255..270, clr 275, stk_clr 276,
                                           duplicates at 280 and 284, pops 282/285/286,
                                           clr 290)
    phase E  clk_en low 300..311 and 316..320 with an event at 305 and a read at 308
    phase F  free-running mixed stream 340..580

Observed word order per beat, matching the testbench fold (MSB byte first):
    ts_count, stk_word, ovf_count, drop_count, src_sticky, rd_record, rd_ts, rd_src,
    n_unread, wr_ptr, rd_ptr, pop_slot, log_used,
    flags = {rd_valid, log_full, log_empty, ovf_sticky, dup_sticky,
             full_sticky, seen_sticky, epop_sticky},
    the ring image as four 32-bit words most significant first,
then BEATS once after the loop.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

# ---- shipped geometry (the core's declared defaults, not overridden anywhere) ----
TS_W = 10
SRC_W = 4
LOG_SLOTS = 2
OVF_W = 6

NSLOTS = 1 << LOG_SLOTS
SLOT_W = TS_W + SRC_W
MEM_W = SLOT_W << LOG_SLOTS
DROP_SAT = 14

STK_OVF = 0x01
STK_DUP = 0x02
STK_FULL = 0x04
STK_SEEN = 0x08
STK_EPOP = 0x10

TS_MASK = (1 << TS_W) - 1
SRC_MASK = (1 << SRC_W) - 1
OVF_MAX = (1 << OVF_W) - 1
NU_MASK = (1 << (LOG_SLOTS + 1)) - 1
STK_WORDS = 4                      # the testbench views the ring image on 128 bits
BEATS = 600
SEED = 0x5EED1234


def plan(n, state):
    """The documented beat plan: the inputs driven for beat index n."""
    inp = {
        'en': 1,
        'a_v': 0, 'a_s': 0,
        'b_v': 0, 'b_s': 0,
        'rd': 0,
        'clr': 0,
        'stk': 0,
    }
    if 300 <= n <= 311 or 316 <= n <= 320:
        inp['en'] = 0

    if n in (10,):
        inp['a_v'], inp['a_s'] = 1, 5
    elif n in (13,):
        inp['a_v'], inp['a_s'] = 1, 9
    elif n in (17,):
        inp['a_v'], inp['a_s'] = 1, 2
    elif n in (22, 23, 24, 25):
        inp['rd'] = 1
    elif n == 26:
        inp['clr'] = 1
    elif n == 30:
        inp['a_v'], inp['a_s'] = 1, 0
    elif n == 34:
        inp['a_v'], inp['a_s'] = 1, 15
    elif n == 38:
        inp['a_v'], inp['a_s'] = 1, 7
    elif n == 42:
        inp['a_v'], inp['a_s'] = 1, 3
    elif n in (50, 51, 52, 53, 54):
        inp['rd'] = 1
    elif n == 58:
        inp['clr'] = 1
    elif 60 <= n <= 63:
        inp['a_v'], inp['a_s'] = 1, (state >> 7) & 0x0F
    elif 70 <= n <= 230:
        inp['a_v'], inp['a_s'] = 1, (state >> 7) & 0x0F
        if (n - 70) % 6 == 0:
            inp['b_v'], inp['b_s'] = 1, (state >> 19) & 0x0F
    elif n in (240, 241, 242, 243):
        inp['rd'] = 1
    elif n == 250:
        inp['clr'] = 1
    elif n == 251:
        inp['stk'] = 1
    elif 255 <= n <= 270:
        inp['a_v'], inp['a_s'] = 1, (n - 255) & 0x0F
    elif n == 275:
        inp['clr'] = 1
    elif n == 276:
        inp['stk'] = 1
    elif n == 280:
        inp['a_v'], inp['a_s'] = 1, 3
        inp['b_v'], inp['b_s'] = 1, 11
    elif n == 282:
        inp['rd'] = 1
    elif n == 284:
        inp['a_v'], inp['a_s'] = 1, 7
        inp['b_v'], inp['b_s'] = 1, 7
    elif n in (285, 286):
        inp['rd'] = 1
    elif n == 290:
        inp['clr'] = 1
    elif n == 305:
        inp['a_v'], inp['a_s'] = 1, 6
    elif n == 308:
        inp['rd'] = 1
    elif 340 <= n <= 580:
        inp['a_v'] = 1 if (state & 0x07) == 0x00 else 0
        inp['a_s'] = (state >> 3) & 0x0F
        inp['b_v'] = 1 if (state & 0x7F) == 0x29 else 0
        inp['b_s'] = (state >> 19) & 0x0F
        inp['rd'] = 1 if (state & 0x0F) == 0x05 else 0
        inp['clr'] = 1 if (state & 0xFFF) == 0x7FF else 0
        inp['stk'] = 1 if (state & 0x7FF) == 0x3F5 else 0
    return inp


def main():
    state = SEED
    ts = 0
    slots = [0] * NSLOTS
    used = 0
    ovf = 0
    drop = 0
    stk = 0
    src_stk = 0
    rec = 0
    wr = 0
    rd = 0
    nu = 0
    pop_slot = 0
    full = 0
    empty = 1
    rv = 0
    words = []

    for n in range(BEATS):
        state = lcg32(state)
        inp = plan(n, state)
        a_v = inp['a_v'] and not inp['clr']
        b_v = inp['b_v'] and not inp['clr']
        rd_en = inp['rd'] and not inp['clr']
        a_s = u(inp['a_s'], SRC_W)
        b_s = u(inp['b_s'], SRC_W)

        if inp['en']:
            if inp['clr']:
                # clr_all dominates its beat: the whole armed state re-arms, the
                # ever-errored source word survives unless stk_clr empties it, and
                # the slot data itself is left alone because the dropped occupancy
                # is what makes it unreadable.
                used = 0
                ovf = 0
                drop = 0
                stk = 0
                wr = 0
                rd = 0
                nu = 0
                pop_slot = 0
                rec = 0
                full = 0
                empty = 1
                rv = 0
                if inp['stk']:
                    src_stk = 0
            else:
                evt = a_v or b_v
                dup = a_v and b_v
                if dup:
                    e_s = a_s if a_s < b_s else b_s
                elif a_v:
                    e_s = a_s
                else:
                    e_s = b_s
                have = nu != 0
                pop_fire = rd_en and have
                epop_fire = rd_en and not have
                wr_fire = evt and not full
                ovf_fire = evt and full
                wr_next = (wr + 1) % NSLOTS
                wr_last = wr_next == 0

                if pop_fire:
                    rec = slots[rd]
                    used &= ~(1 << rd)
                if wr_fire:
                    slots[wr] = u((ts << SRC_W) | e_s, SLOT_W)
                    used |= 1 << wr

                nu = u(nu + (1 if wr_fire else 0) - (1 if pop_fire else 0), LOG_SLOTS + 1)
                if wr_fire:
                    wr = wr_next
                if pop_fire:
                    pop_slot = rd
                    rd = (rd + 1) % NSLOTS
                full = 1 if (full or (wr_fire and wr_last)) else 0
                empty = 1 if nu == 0 else 0
                rv = 1 if pop_fire else 0
                if inp['stk']:
                    # the sticky clear is applied first, so a same-beat event still
                    # leaves its own mark behind
                    src_stk = 0
                if a_v:
                    src_stk |= 1 << a_s
                if b_v:
                    src_stk |= 1 << b_s
                if evt:
                    stk |= STK_SEEN
                if ovf_fire:
                    stk |= STK_OVF
                    if ovf < OVF_MAX:
                        ovf += 1
                if dup:
                    stk |= STK_DUP
                    if drop < DROP_SAT:
                        drop += 1
                if wr_fire and wr_last:
                    stk |= STK_FULL
                if epop_fire:
                    stk |= STK_EPOP

            # the stamp is free running: it steps on every enabled beat, including
            # the one that re-armed the log
            ts = u(ts + 1, TS_W)

        # ---- fold what the beat left on the pins -------------------------------
        flat = 0
        for k in range(NSLOTS):
            flat |= u(slots[k], SLOT_W) << (k * SLOT_W)
        flat = u(flat, MEM_W)
        flags = (
            (rv << 7)
            | (full << 6)
            | (empty << 5)
            | (((stk & STK_OVF) != 0) << 4)
            | (((stk & STK_DUP) != 0) << 3)
            | (((stk & STK_FULL) != 0) << 2)
            | (((stk & STK_SEEN) != 0) << 1)
            | (((stk & STK_EPOP) != 0) << 0)
        )
        words.append(u(ts, 32))
        words.append(u(stk, 32))
        words.append(u(ovf, 32))
        words.append(u(drop, 32))
        words.append(u(src_stk, 32))
        words.append(u(rec, 32))
        words.append(u(rec >> SRC_W, 32))
        words.append(u(rec & SRC_MASK, 32))
        words.append(u(nu, 32))
        words.append(u(wr, 32))
        words.append(u(rd, 32))
        words.append(u(pop_slot, 32))
        words.append(u(used, 32))
        words.append(u(flags, 32))
        for j in range(STK_WORDS):
            words.append(u(flat >> (32 * (STK_WORDS - 1 - j)), 32))

    words.append(BEATS)
    emit('ips_err_log_sticky', words)


if __name__ == '__main__':
    main()
