"""Independent golden model for ips_i2s_rx_slave.

Written from the contract in src/ips_i2s_rx_slave.v, never from simulation
output (docs/IP_CORE_SOP.md trap T1):

  * one tick = one synchroniser step: q1 <= pin, q2 <= q1; the recognised bit
    clock edge is q1 & ~q2 and the word-select edge is l1 ^ l2; SD is taken from
    the q2 tap of its own chain;
  * each recognised edge shifts SD, MSB first, into the WORD_W-deep capture
    register and advances bit_count (saturated at 6'h3F);
  * the word is published when bit_count reaches WORD_W; a publish onto a word
    that rx_ready did not consume bumps drop_count up to DROP_MAX;
  * at a word-select edge the slot length is checked against SLOT_B; any other
    length is a slip (slip_sticky, saturating slip_count) and bit_count restarts;
  * TIMEOUT_T ticks without a recognised edge set lost_sticky, bump the
    saturating lost_count and re-arm the watchdog.

Stimulus contract shared with sim/tb_ips_i2s_rx_slave.v, one core cycle per beat:
    with OSO = 2 ticks per SCLK half period a bit lasts BIT_BEATS = 4 ticks, a
    slot SLOT_BITS = 17 bits and a stereo frame FRAME_BITS = 34 bits.
    every FRAME_BEATS beats: fstate = fstate*1664525 + 1013904223,
        cur_l = fstate[15:0], cur_r = fstate[31:16]
    m = i // BIT_BEATS, fp = m % FRAME_BITS, q = fp % SLOT_BITS
    sclk = 0 during the stall window, i&1 during the glitch window, else
        (i // OSO) & 1
    lrclk = fp >= SLOT_BITS
    sd = 0 for q == 0 else the (WORD_BITS - q)-th bit of the slot's sample word
    tick = 0 in [IDLE_A, IDLE_A+IDLE_W); rx_ready = 0 in the two backpressure
    windows.  Both windows are the malformed-input cases.
Folded word order per beat: w1, w2, w3, then a final w1, w2, w3 and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

# Core defaults, exactly as declared in the ANSI header.
WORD_W = 16
SLOT_B = 17
TIMEOUT_T = 40
DROP_MAX = 3

CNT_TOP = 0x3F
WORD_MASK = (1 << WORD_W) - 1

# Stimulus contract, mirrored from the testbench.
BEATS = 1600
SEED = 0x5A1710E2
OSO = 2
BIT_BEATS = 4
FRAME_BITS = 34
FRAME_BEATS = 136
STALL_A = 300
STALL_L = 50
GLITCH_A = 700
GLITCH_L = 10
IDLE_A = 1000
IDLE_W = 6
BP1_A = 400
BP1_L = 300
BP2_A = 900
BP2_L = 300


def stimulus(i, cur_l, cur_r):
    m = i // BIT_BEATS
    fp = m % FRAME_BITS
    q = fp % SLOT_B
    in_stall = STALL_A <= i < STALL_A + STALL_L
    in_glitch = GLITCH_A <= i < GLITCH_A + GLITCH_L
    if in_stall:
        sclk = 0
    elif in_glitch:
        sclk = i & 1
    else:
        sclk = (i // OSO) & 1
    lrclk = 1 if fp >= SLOT_B else 0
    word = cur_r if fp >= SLOT_B else cur_l
    sd = 0 if q == 0 else ((word >> (WORD_W - q)) & 1)
    tick = 0 if IDLE_A <= i < IDLE_A + IDLE_W else 1
    rx_ready = 0 if (BP1_A <= i < BP1_A + BP1_L or BP2_A <= i < BP2_A + BP2_L) else 1
    return tick, sclk, lrclk, sd, rx_ready


def step(st, tick, sclk_i, lrclk_i, sd_i, rx_ready):
    if not tick:
        return dict(st)
    nxt = dict(st)
    nxt['sclk_q1'] = sclk_i
    nxt['lrclk_q1'] = lrclk_i
    nxt['sd_q1'] = sd_i
    nxt['sclk_q2'] = st['sclk_q1']
    nxt['lrclk_q2'] = st['lrclk_q1']
    nxt['sd_q2'] = st['sd_q1']
    nxt['sclk_q'] = sclk_i
    nxt['lrclk_q'] = lrclk_i

    rise = st['sclk_q1'] & (1 - st['sclk_q2'])
    ws = st['lrclk_q1'] ^ st['lrclk_q2']
    cap_next = u((st['cap'] << 1) | st['sd_q2'], WORD_W)
    if rise:
        cnt_next = CNT_TOP if st['bit_count'] == CNT_TOP else u(st['bit_count'] + 1, 6)
        nxt['cap'] = cap_next
    else:
        cnt_next = st['bit_count']

    take = st['rx_valid'] & rx_ready
    still = st['rx_valid'] & (1 - take)
    if take:
        nxt['rx_valid'] = 0
    done_word = cap_next if rise else st['cap']

    if cnt_next == WORD_W:
        if still and st['drop_count'] < DROP_MAX:
            nxt['drop_count'] = u(st['drop_count'] + 1, 8)
        nxt['rx_word'] = done_word
        nxt['rx_chan'] = st['lrclk_q2']
        nxt['rx_valid'] = 1
        if st['cap_count'] != 0xFF:
            nxt['cap_count'] = u(st['cap_count'] + 1, 8)

    if ws:
        if cnt_next != SLOT_B:
            nxt['slip_sticky'] = 1
            if st['slip_count'] != 0xF:
                nxt['slip_count'] = u(st['slip_count'] + 1, 4)
        nxt['bit_count'] = 0
    elif rise:
        nxt['bit_count'] = cnt_next

    if rise:
        nxt['idle_cnt'] = 0
    elif st['idle_cnt'] >= TIMEOUT_T:
        nxt['idle_cnt'] = 0
        nxt['lost_sticky'] = 1
        if st['lost_count'] != 0xF:
            nxt['lost_count'] = u(st['lost_count'] + 1, 4)
    else:
        nxt['idle_cnt'] = u(st['idle_cnt'] + 1, 8)
    return nxt


def fold(st):
    w1 = (st['lost_count'] | (st['slip_count'] << 4) | (st['bit_count'] << 8) |
          (st['lrclk_q'] << 14) | (st['sclk_q'] << 15) | (st['lost_sticky'] << 16) |
          (st['slip_sticky'] << 17) | (st['rx_chan'] << 18) | (st['rx_valid'] << 19))
    w2 = st['rx_word'] & WORD_MASK
    w3 = (st['cap_count'] << 8) | st['drop_count']
    return w1, w2, w3


def main():
    st = dict(sclk_q1=0, sclk_q2=0, lrclk_q1=0, lrclk_q2=0, sd_q1=0, sd_q2=0,
              cap=0, idle_cnt=0, rx_word=0, rx_valid=0, rx_chan=0, bit_count=0,
              cap_count=0, drop_count=0, slip_count=0, lost_count=0,
              slip_sticky=0, lost_sticky=0, sclk_q=0, lrclk_q=0)
    fstate = SEED
    cur_l = 0
    cur_r = 0
    words = []
    for i in range(BEATS):
        if i % FRAME_BEATS == 0:
            fstate = lcg32(fstate)
            cur_l = fstate & 0xFFFF
            cur_r = (fstate >> 16) & 0xFFFF
        st = step(st, *stimulus(i, cur_l, cur_r))
        for w in fold(st):
            words.append(u(w, 32))
    for w in fold(st):
        words.append(u(w, 32))
    words.append(BEATS)
    emit('ips_i2s_rx_slave', words)


if __name__ == '__main__':
    main()
