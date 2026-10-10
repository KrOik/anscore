"""Independent golden model for ips_debounce_matrix.

Written from the core's documented contract in src/ips_debounce_matrix.v, not from
simulation output (docs/IP_CORE_SOP.md trap T1): the civil rules here are the
debounce rules, and this file re-states them from the contract text -- two-flop
synchroniser, modulo sample prescaler, per-key stable count with priority event
encoder, most-recent window ledger with drop accounting.

Folding rule, mirrored verbatim in sim/tb_ips_debounce_matrix.v: one index i is one
core clock cycle, a stalled index folds nothing, and every enabled cycle folds the
complete registered state as SEVEN 32-bit words, MSB byte first:
    W1 = {key_state, chg_sticky}
    W2 = ledger[63:32]
    W3 = ledger[31:0]
    W4 = {key_change, event_rec, seq_tag, led_count, drop_count}
    W5 = {event_total, tick_total, bounce_count, multi_count, led_full,
          multi_sticky, sample_tick, event_valid}
    W6 = cnt_flat[47:24]
    W7 = cnt_flat[23:0]

Stimulus contract shared with the testbench:
    BEATS = 560, SEED = 0x5A17F00D, state = state*1664525 + 1013904223 (mod 2**32)
    advanced once per index including stalled indices.
    stall(i) : (i % 40) == 39 -> clk_en low, bus idle, strobe low.
    Directed windows 16..383 press/release/glitch the named lines, 320..351 drives
    rows 11..8, 384..503 toggles lines 0,1,2,3,4,6 on staggered 20-beat half
    periods, 504..559 use the LCG bus (line 5 always masked off) with LCG clear
    strobes.  Line 5 is never driven in any phase.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

# Geometry exactly as declared in the core's parameter list and localparams.
KEY_N = 8
SAMPLE_DIV = 1
STABLE_MAX = 3
LED_SLOTS = 6
SEQ_MAX = 5
DROP_SAT = 10
MULTI_SAT = 7
BOUNCE_SAT = 12
KEY_BUS = 12
LED_BUS = 8

BEATS = 560
SEED = 0x5A17F00D


def stimulus(i, state):
    """The TB's drive_cycle(): advance the generator, then pick the inputs."""
    state = lcg32(state)
    if (i % 40) == 39:
        return state, 0, 0, True
    raw = 0
    clear = 0
    if 16 <= i <= 47:
        raw = 1 << 0
    elif 80 <= i <= 103:
        raw = (1 << 1) if (((i - 80) % 12) < 2) else 0
    elif 104 <= i <= 135:
        raw = 1 << 2
    elif 168 <= i <= 191:
        raw = (1 << 3) if (((i - 168) % 5) == 0) else 0
    elif 192 <= i <= 223:
        raw = (1 << 4) | (1 << 6)
    elif 256 <= i <= 287:
        raw = 1 << 7
    elif 320 <= i <= 351:
        raw = 0xF << 8
    elif 384 <= i <= 503:
        bits = (0, 1, 2, 3, 4, 6)
        offs = (1, 4, 7, 10, 13, 16)
        for b, o in zip(bits, offs):
            if (((i - 384 + o) // 20) % 2) == 1:
                raw |= 1 << b
    elif i >= 504:
        raw = u(state, 12) & ~(1 << 5)
        clear = 1 if ((state & 0x7) == 2) else 0
    return state, u(raw, 12), clear, False


def nib(v, k):
    return (v >> (4 * k)) & 0xF


def put_nib(v, k, x):
    shift = 4 * k
    return (v & ~(0xF << shift)) | ((x & 0xF) << shift)


def step(s, raw, clear):
    """One enabled core cycle of the contract in src/ips_debounce_matrix.v."""
    n = dict(s)

    # two-flop synchroniser on the raw scan bus
    n['raw_q2'] = s['raw_q1']
    n['raw_q1'] = raw

    stb = 1 if (s['sdiv'] == SAMPLE_DIV) else 0
    n['sdiv'] = 0 if stb else (u(s['sdiv'] + 1, 3))

    n['sample_tick'] = stb
    n['event_valid'] = 0
    n['key_change'] = 0

    if clear:
        n['ledger'] = 0
        n['led_count'] = 0
        n['led_full'] = 0
        n['drop_count'] = 0

    if stb:
        n['tick_total'] = u(s['tick_total'] + 1, 8)

        nxt_state = s['key_state']
        nxt_sticky = s['chg_sticky']
        nxt_cnt = s['cnt_flat']
        nxt_chg = 0
        ev_any = 0
        ev_multi = 0
        ev_bounce = 0
        ev_idx = 0
        ev_lvl = 0

        for k in range(KEY_BUS):
            live = 1 if k < KEY_N else 0
            ccur = nib(s['cnt_flat'], k)
            st = (s['key_state'] >> k) & 1
            lvl = ((s['raw_q2'] >> k) & 1) & live
            if not live:
                nxt_cnt = put_nib(nxt_cnt, k, 0)
                nxt_state &= ~(1 << k)
            elif lvl == st:
                if ccur != 0:
                    nxt_cnt = put_nib(nxt_cnt, k, 0)
                    ev_bounce = 1
            elif ccur == STABLE_MAX:
                nxt_cnt = put_nib(nxt_cnt, k, 0)
                nxt_state = (nxt_state & ~(1 << k)) | (lvl << k)
                nxt_chg |= 1 << k
                nxt_sticky |= 1 << k
                if ev_any:
                    ev_multi = 1
                else:
                    ev_any = 1
                    ev_idx = k
                    ev_lvl = lvl
            else:
                nxt_cnt = put_nib(nxt_cnt, k, ccur + 1)

        n['key_state'] = nxt_state
        n['chg_sticky'] = nxt_sticky
        n['cnt_flat'] = nxt_cnt
        n['key_change'] = nxt_chg

        if ev_bounce and s['bounce_count'] != BOUNCE_SAT:
            n['bounce_count'] = u(s['bounce_count'] + 1, 4)
        if ev_multi:
            n['multi_sticky'] = 1
            if s['multi_count'] != MULTI_SAT:
                n['multi_count'] = u(s['multi_count'] + 1, 4)

        if ev_any:
            n['event_valid'] = 1
            rec = (ev_idx << 4) | (s['seq_tag'] << 1) | ev_lvl
            n['event_rec'] = rec
            n['seq_tag'] = 0 if s['seq_tag'] == SEQ_MAX else u(s['seq_tag'] + 1, 3)

            base = 0 if clear else s['ledger']
            nxt_led = 0
            for b in range(LED_BUS):
                if b == 0:
                    nb = rec
                elif b < LED_SLOTS:
                    nb = (base >> (8 * (b - 1))) & 0xFF
                else:
                    nb = 0
                nxt_led |= nb << (8 * b)
            n['ledger'] = u(nxt_led, 64)

            if clear:
                n['led_count'] = 1
            elif s['led_count'] == LED_SLOTS:
                n['led_full'] = 1
                if s['drop_count'] != DROP_SAT:
                    n['drop_count'] = u(s['drop_count'] + 1, 4)
            else:
                n['led_count'] = u(s['led_count'] + 1, 4)

            if s['event_total'] != 0xFF:
                n['event_total'] = u(s['event_total'] + 1, 8)

    return n


def fold(s):
    w1 = (s['key_state'] << 12) | s['chg_sticky']
    w2 = (s['ledger'] >> 32) & MASK32
    w3 = s['ledger'] & MASK32
    w4 = ((s['key_change'] << 19) | (s['event_rec'] << 11) |
          (s['seq_tag'] << 8) | (s['led_count'] << 4) | s['drop_count'])
    w5 = ((s['event_total'] << 20) | (s['tick_total'] << 12) |
          (s['bounce_count'] << 8) | (s['multi_count'] << 4) |
          (s['led_full'] << 3) | (s['multi_sticky'] << 2) |
          (s['sample_tick'] << 1) | s['event_valid'])
    w6 = (s['cnt_flat'] >> 24) & MASK32
    w7 = s['cnt_flat'] & 0xFFFFFF
    return [u(w1, 32), u(w2, 32), u(w3, 32), u(w4, 32), u(w5, 32), u(w6, 32), u(w7, 32)]


def initial_state():
    return {
        'raw_q1': 0, 'raw_q2': 0, 'sdiv': 0,
        'key_state': 0, 'key_change': 0, 'chg_sticky': 0, 'cnt_flat': 0,
        'sample_tick': 0, 'event_valid': 0, 'event_rec': 0,
        'ledger': 0, 'led_count': 0, 'seq_tag': 0, 'led_full': 0,
        'drop_count': 0, 'multi_count': 0, 'multi_sticky': 0,
        'bounce_count': 0, 'event_total': 0, 'tick_total': 0,
    }


def run():
    st = initial_state()
    state = SEED
    words = []
    trace = []
    for i in range(BEATS):
        state, raw, clear, stalled = stimulus(i, state)
        if stalled:
            continue
        st = step(st, raw, clear)
        trace.append((i, fold(st), raw, clear))
        words.extend(fold(st))
    return words, trace


def main():
    words, _ = run()
    emit('ips_debounce_matrix', words)


if __name__ == '__main__':
    main()
