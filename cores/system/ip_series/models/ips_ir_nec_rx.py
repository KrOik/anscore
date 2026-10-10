"""Independent golden model for ips_ir_nec_rx.

Written from the contract in src/ips_ir_nec_rx.v, never from simulation output
(docs/IP_CORE_SOP.md trap T1).

Core rules replayed here:
  * the pin is sampled only on a tick; every register moves only when clk_en is
    high, so a beat with clk_en low or tick low leaves the measurement frozen;
  * on a tick with an unchanged level the running width increments and saturates
    at 6'h3F; on a tick with a changed level the finished segment is committed
    with that width, the width restarts at 1 and the state machine classifies it;
  * `burst' is the level of the segment that just ended (pin low = carrier), so
    the states consume alternating burst / space segments:
      S_IDLE     burst end must be within TOL of TICK_LEAD   -> S_LEAD_SP
      S_LEAD_SP  space end within LEAD_SP -> S_BMARK, within REPEAT_SP -> S_TAIL
                                                        (+ repeat_valid/count)
      S_BMARK    burst end within BIT_MARK -> S_BSPACE
      S_BSPACE   burst... space end within BIT0_SP (bit 0, wins on an overlap)
                 or BIT1_SP (bit 1) -> shift in, next bit or frame completion
      S_TAIL     burst end within BIT_MARK -> S_IDLE
    an idle space in S_IDLE is never an error; any other mismatch is a timing
    error: back to idle, bit_index restarts, timing_sticky latches and
    timing_count steps (all counters hold at 8'hFF);
  * the 32-bit word is filled with the first received bit in bit 31 and is
    published only when {addr,~addr} and {cmd,~cmd} both XOR to 8'hFF, otherwise
    crc_sticky latches and crc_count steps.

Stimulus contract shared with sim/tb_ips_ir_nec_rx.v: the waveform is a list of
(level, ticks, tag) segments; a beat is a waveform tick unless (i % 4) == 3, the
first GAP_N waveform ticks of a T_GAP segment present no tick to the core, a
T_STALL segment holds clk_en low while 4 <= k < 8, and a T_GLITCH segment inverts
the pin on its non-tick beats.  The plan below is the testbench plan, segment for
segment.  Folded word order per beat: rx_word, status+measurement, addr/cmd +
error counters, frame/repeat counters; then nbeats.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, u

# Core defaults, exactly as declared in the ANSI header.
TICK_LEAD = 48
LEAD_SP = 24
REPEAT_SP = 12
BIT0_SP = 6
BIT1_SP = 12
TOL = 2

BIT_MARK = 3
BITS = 32
W_MAX = 0x3F
BIT_LAST = BITS - 1

S_IDLE = 0
S_LEAD_SP = 1
S_BMARK = 2
S_BSPACE = 3
S_TAIL = 4

# Testbench stimulus constants.
T_NONE = 0
T_GAP = 1
T_STALL = 2
T_GLITCH = 3
GAP_N = 12
ST_A = 4
ST_L = 4

SEG = []


def push(lvl, length, tag=T_NONE):
    SEG.append((lvl & 1, length, tag))


def nec_frame(word, lead, lsp, mk, s0, s1, stop):
    push(0, lead)
    push(1, lsp)
    b = 31
    while b > (31 - stop):
        push(0, mk)
        push(1, s1 if (word >> b) & 1 else s0)
        b -= 1
    push(0, mk)


def build_plan():
    del SEG[:]
    push(1, 40)
    nec_frame(0x5AA517E8, 48, 24, 3, 6, 12, 32)
    push(1, 40, T_GLITCH)
    nec_frame(0x5A5A17E8, 48, 24, 3, 6, 12, 32)
    push(1, 40, T_GAP)
    nec_frame(0x3CC3F00F, 46, 22, 1, 4, 10, 32)
    push(1, 40, T_STALL)
    nec_frame(0x5AA517E8, 48, 24, 3, 6, 9, 2)
    push(1, 30)
    push(0, 48)
    push(1, 12)
    push(0, 3)
    push(1, 30)
    push(0, 46)
    push(1, 10)
    push(0, 3)
    push(1, 40)
    nec_frame(0x3CC3F00F, 48, 24, 3, 6, 15, 2)
    push(1, 40)
    push(0, 48)
    push(1, 9)
    push(0, 3)
    push(1, 40)
    push(0, 48)
    push(1, 24)
    push(0, 3)
    push(1, 63)
    push(0, 3)
    push(1, 40)
    push(0, 20)
    push(1, 40)
    nec_frame(0x12ED34CB, 48, 24, 3, 6, 12, 32)
    push(1, 40)


def spread():
    """Turn the tick-domain plan into per-beat (ir, tick, clk_en) triples."""
    beats = []
    s = 0
    k = 0
    lvl = SEG[0][0]
    nb = 0
    while s < len(SEG):
        seg_lvl, seg_len, tag = SEG[s]
        wt = (nb % 4) != 3
        ir = lvl ^ (1 if (tag == T_GLITCH and not wt) else 0)
        tick = 1 if (wt and not (tag == T_GAP and k < GAP_N)) else 0
        en = 0 if (tag == T_STALL and ST_A <= k < ST_A + ST_L) else 1
        beats.append((ir, tick, en))
        if wt:
            if (k + 1) >= seg_len:
                s += 1
                k = 0
                if s < len(SEG):
                    lvl = SEG[s][0]
            else:
                k += 1
        nb += 1
    return beats


def tol_hit(wq, target):
    return (wq >= target - TOL) and (wq <= target + TOL)


def step(st, tick, ir):
    if not tick:
        return
    st['frame_valid'] = 0
    st['repeat_valid'] = 0
    wq = st['width']
    burst = 1 - st['ir_q']
    mk_lead = tol_hit(wq, TICK_LEAD)
    sp_lead = tol_hit(wq, LEAD_SP)
    sp_rep = tol_hit(wq, REPEAT_SP)
    mk_bit = tol_hit(wq, BIT_MARK)
    sp_b0 = tol_hit(wq, BIT0_SP)
    sp_b1 = tol_hit(wq, BIT1_SP)
    acc_bit = sp_b0 or sp_b1
    bit_val = 0 if sp_b0 else 1
    nxt = u((st['rx_word'] << 1) | bit_val, 32)
    crc_ok = (((nxt >> 24) & 0xFF) ^ ((nxt >> 16) & 0xFF)) == 0xFF and \
             (((nxt >> 8) & 0xFF) ^ (nxt & 0xFF)) == 0xFF

    def timing_error():
        st['timing_sticky'] = 1
        if st['timing_count'] != 0xFF:
            st['timing_count'] = u(st['timing_count'] + 1, 8)

    if ir != st['ir_q']:
        st['width'] = 1
        if st['state'] == S_IDLE:
            if burst and not mk_lead:
                timing_error()
            elif burst and mk_lead:
                st['state'] = S_LEAD_SP
        elif st['state'] == S_LEAD_SP:
            if (not burst) and sp_lead:
                st['state'] = S_BMARK
                st['bit_index'] = 0
            elif (not burst) and sp_rep:
                st['state'] = S_TAIL
                st['repeat_valid'] = 1
                if st['repeat_count'] != 0xFF:
                    st['repeat_count'] = u(st['repeat_count'] + 1, 8)
            else:
                st['state'] = S_IDLE
                timing_error()
        elif st['state'] == S_BMARK:
            if burst and mk_bit:
                st['state'] = S_BSPACE
            else:
                st['state'] = S_IDLE
                st['bit_index'] = 0
                timing_error()
        elif st['state'] == S_BSPACE:
            if (not burst) and acc_bit:
                st['rx_word'] = nxt
                if st['bit_index'] == BIT_LAST:
                    st['state'] = S_TAIL
                    st['bit_index'] = 0
                    if crc_ok:
                        st['addr'] = (nxt >> 24) & 0xFF
                        st['cmd'] = (nxt >> 8) & 0xFF
                        st['frame_valid'] = 1
                        if st['frame_count'] != 0xFF:
                            st['frame_count'] = u(st['frame_count'] + 1, 8)
                    else:
                        st['crc_sticky'] = 1
                        if st['crc_count'] != 0xFF:
                            st['crc_count'] = u(st['crc_count'] + 1, 8)
                else:
                    st['bit_index'] = u(st['bit_index'] + 1, 6)
                    st['state'] = S_BMARK
            else:
                st['state'] = S_IDLE
                st['bit_index'] = 0
                timing_error()
        elif st['state'] == S_TAIL:
            if burst and mk_bit:
                st['state'] = S_IDLE
            elif burst:
                st['state'] = S_IDLE
                timing_error()
        else:
            st['state'] = S_IDLE
        st['ir_q'] = ir
    else:
        if st['width'] != W_MAX:
            st['width'] = u(st['width'] + 1, 6)
        st['ir_q'] = ir


def fold(st):
    w1 = st['rx_word']
    w2 = ((st['timing_sticky'] << 18) | (st['crc_sticky'] << 17) |
          (st['frame_valid'] << 16) | (st['repeat_valid'] << 15) |
          (st['state'] << 12) | (st['bit_index'] << 6) | st['width'])
    w3 = ((st['addr'] << 24) | (st['cmd'] << 16) |
          (st['timing_count'] << 8) | st['crc_count'])
    w4 = (st['frame_count'] << 8) | st['repeat_count']
    return w1, w2, w3, w4


def main():
    build_plan()
    beats = spread()
    st = dict(rx_word=0, addr=0, cmd=0, frame_valid=0, repeat_valid=0,
              state=S_IDLE, bit_index=0, width=0, ir_q=1, timing_sticky=0,
              crc_sticky=0, timing_count=0, crc_count=0, frame_count=0,
              repeat_count=0)
    words = []
    for ir, tick, en in beats:
        if en:
            step(st, tick, ir)
        for w in fold(st):
            words.append(u(w, 32))
    words.append(len(beats))
    emit('ips_ir_nec_rx', words)


if __name__ == '__main__':
    main()
