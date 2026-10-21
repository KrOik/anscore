"""Independent golden model for ips_i2s_tx_master.

Derived from the contract written in src/ips_i2s_tx_master.v, not from any
simulation output (docs/IP_CORE_SOP.md trap T1):

  * SCLK toggles every BCLK_DIV ticks; a bit is launched on each SCLK falling
    edge, so one bit leaves the shift register every 2*BCLK_DIV ticks.
  * A stereo frame is FRAME_B = 2*SLOT_B launches.  Position 0 is the left slot
    start, position SLOT_B the right slot start; LRCLK is registered from the
    next position, i.e. it flips one bit time before the slot it names.
  * The slot vector is the WORD_W-bit sample placed at bit offset ALIGN inside
    the slot and zero padded to SLOT_B bits, MSB launched first.
  * ch_valid latches the pair and marks both channels fresh; a slot start
    consumes that channel's fresh flag.  An offer on a slot-start launch is
    consumed by that same slot (the launch path is written after the latch path,
    so consume wins).
  * A slot start without a fresh flag re-runs the latched word, sets
    underflow_sticky and bumps under_count until it saturates at UNDER_MAX.
  * word_count bumps once per completed frame and wraps.

Stimulus contract shared with sim/tb_ips_i2s_tx_master.v, one core cycle per
beat (clk_en is high for exactly one clock edge per beat):
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x1DEEA2E5
    ch_l = state[31:16], ch_r = state[15:0]          (the WORD_W-wide port slice)
    tick = 0 inside [IDLE_A, IDLE_A+IDLE_W) and [IDLE_B, IDLE_B+IDLE_BW), else 1
    ch_valid = (i < OFFER_END and i % 64 == 0) or i == COIN
Folded word order per beat: w1 then w2, then a final w1, w2 and BEATS, with
    w1 = {15'd0, fresh_r, fresh_l, underflow_sticky, sclk, lrclk, sd, bit_idx, div_idx}
    w2 = {16'd0, word_count, under_count}
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

# Default geometry of the core, exactly as declared in the ANSI header.
WORD_W = 16
SLOT_B = 32
BCLK_DIV = 4
ALIGN = 1
UNDER_MAX = 3

FRAME_B = SLOT_B + SLOT_B
TAIL_B = SLOT_B - WORD_W - ALIGN
BCLK_LAST = BCLK_DIV - 1
FRAME_LAST = FRAME_B - 1

SLOT_MASK = (1 << SLOT_B) - 1

# Stimulus contract, mirrored from the testbench.
BEATS = 2560
SEED = 0x1DEEA2E5
OFFER_END = 600
COIN = 1028
IDLE_A = 1200
IDLE_W = 24
IDLE_B = 2100
IDLE_BW = 3


def stimulus(i, state):
    """Return (tick, ch_valid, ch_l, ch_r) for beat i given the updated LCG state."""
    tick = 1
    if IDLE_A <= i < IDLE_A + IDLE_W:
        tick = 0
    if IDLE_B <= i < IDLE_B + IDLE_BW:
        tick = 0
    ch_valid = 1 if ((i < OFFER_END and (i % 64 == 0)) or i == COIN) else 0
    ch_l = u(state >> 16, WORD_W)
    ch_r = u(state, WORD_W)
    return tick, ch_valid, ch_l, ch_r


def step(st, tick, ch_valid, ch_l, ch_r):
    """One enabled core cycle, mirroring the RTL assignment order."""
    nxt = dict(st)
    if ch_valid:
        nxt['lat_l'] = ch_l
        nxt['lat_r'] = ch_r
        nxt['fresh_l'] = 1
        nxt['fresh_r'] = 1
    if tick:
        if st['div_idx'] == 0:
            nxt['div_idx'] = BCLK_LAST
            if st['sclk']:
                use_l = ch_l if ch_valid else st['lat_l']
                use_r = ch_r if ch_valid else st['lat_r']
                eff_l = 1 if ch_valid else st['fresh_l']
                eff_r = 1 if ch_valid else st['fresh_r']
                slot_l = (st['bit_idx'] == 0)
                slot_r = (st['bit_idx'] == SLOT_B)
                if slot_l:
                    vec = u(use_l << TAIL_B, SLOT_B)
                elif slot_r:
                    vec = u(use_r << TAIL_B, SLOT_B)
                else:
                    vec = st['sr']
                nxt['sclk'] = 0
                nxt['sd'] = (vec >> (SLOT_B - 1)) & 1
                nxt['sr'] = u(vec << 1, SLOT_B)
                bit_next = 0 if st['bit_idx'] == FRAME_LAST else u(st['bit_idx'] + 1, 7)
                nxt['bit_idx'] = bit_next
                nxt['lrclk'] = 1 if bit_next >= SLOT_B else 0
                if slot_l:
                    nxt['fresh_l'] = 0
                    if not eff_l:
                        nxt['sticky'] = 1
                        if st['under_count'] < UNDER_MAX:
                            nxt['under_count'] = u(st['under_count'] + 1, 8)
                if slot_r:
                    nxt['fresh_r'] = 0
                    if not eff_r:
                        nxt['sticky'] = 1
                        if st['under_count'] < UNDER_MAX:
                            nxt['under_count'] = u(st['under_count'] + 1, 8)
                if st['bit_idx'] == FRAME_LAST:
                    nxt['word_count'] = u(st['word_count'] + 1, 8)
            else:
                nxt['sclk'] = 1
        else:
            nxt['div_idx'] = u(st['div_idx'] - 1, 4)
    return nxt


def fold(st):
    w1 = (st['div_idx'] | (st['bit_idx'] << 4) | ((st['sd'] & 1) << 11) |
          ((st['lrclk'] & 1) << 12) | ((st['sclk'] & 1) << 13) |
          ((st['sticky'] & 1) << 14) | ((st['fresh_l'] & 1) << 15) |
          ((st['fresh_r'] & 1) << 16))
    w2 = (st['word_count'] << 8) | st['under_count']
    return w1, w2


def main():
    state = SEED
    st = dict(sclk=0, lrclk=0, sd=0, fresh_l=0, fresh_r=0, bit_idx=0, div_idx=0,
              word_count=0, under_count=0, sticky=0, sr=0, lat_l=0, lat_r=0)
    words = []
    for i in range(BEATS):
        state = lcg32(state)
        st = step(st, *stimulus(i, state))
        w1, w2 = fold(st)
        words.append(u(w1, 32))
        words.append(u(w2, 32))
    f1, f2 = fold(st)
    words.append(u(f1, 32))
    words.append(u(f2, 32))
    words.append(BEATS)
    emit('ips_i2s_tx_master', words)


if __name__ == '__main__':
    main()
