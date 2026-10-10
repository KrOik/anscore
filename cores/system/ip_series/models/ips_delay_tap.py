"""Independent golden model for ips_delay_tap.

Derived from the core's written contract only (docs/IP_CORE_SOP.md trap T1):

  tap_sel    = min(delay_sel, MAX_DELAY)                    (8-bit clamp)
  accepted   = in_valid && in_ready_q && !stall
  chain      = two flat shift vectors, tap k = bit k of the valid vector and word
               k of the payload vector; every enabled beat without stall the
               vectors shift one tap up and the accepted beat enters tap 0
  tap_index  <= tap_sel_q, active_lat <= tap_sel_q + 1, in_ready <= !stall
  lat_events <= lat_events + 1 when delay_sel != tap_sel_q
  drop_count <= drop_count + 1 and drop_sticky set for a beat presented while the
               line is not accepting (stall or !in_ready_q)
  beat_count <= beat_count + 1 on an accepted beat
  out_valid / out_data are the combinational read of tap tap_sel of the chain

Stimulus contract shared with sim/tb_ips_delay_tap.v (LCG state starts at
0x517A1E05 and is stepped with state = state*1664525 + 1013904223 mod 2**32
before every beat drives its stimulus):
  in_data = state[11:0] (the core sees the low PAY_W bits), in_valid = ~state[0],
  stall = 1 while (beat % 53) < 4, delay_sel = dsel(beat) step function.
Folded word order per beat, matching the testbench:
  {tap_index, active_lat}, {beat_count, drop_count},
  {lat_events, drop_sticky, in_ready, out_valid}, {out_data}; then BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

PAY_W = 8
MAX_DELAY = 15
NSTAGE = MAX_DELAY + 1
V_BITS = NSTAGE
D_BITS = NSTAGE * PAY_W
BEATS = 400
SEED = 0x517A1E05


def dsel(n):
    if n < 60:
        return 0
    if n < 120:
        return 7
    if n < 180:
        return 15
    if n < 240:
        return 20
    if n < 300:
        return 3
    return 255


def stalling(n):
    return 1 if (n % 53) < 4 else 0


def main():
    vbuf = 0
    dbuf = 0
    tsel = 0
    in_ready = 0
    tap_index = 0
    active_lat = 1
    beat_count = 0
    drop_count = 0
    lat_events = 0
    drop_sticky = 0
    words = []
    state = SEED

    for i in range(BEATS):
        state = (state * 1664525 + 1013904223) & MASK32
        in_data = state & 0xFFF
        in_valid = 1 - (state & 1)
        stall = stalling(i)
        delay_sel = dsel(i)

        core_data = u(in_data, PAY_W)
        accepted = 1 if (in_valid and in_ready and not stall) else 0

        if delay_sel > MAX_DELAY:
            new_tsel = MAX_DELAY
        else:
            new_tsel = delay_sel

        if delay_sel != tsel:
            lat_events = u(lat_events + 1, 8)
        if in_valid and (stall or not in_ready):
            drop_count = u(drop_count + 1, 8)
            drop_sticky = 1
        if accepted:
            beat_count = u(beat_count + 1, 8)

        tap_index = tsel
        active_lat = u(tsel + 1, 8)
        in_ready = 0 if stall else 1
        tsel = new_tsel

        if not stall:
            vbuf = u((vbuf << 1) | accepted, V_BITS)
            dbuf = u((dbuf << PAY_W) | core_data, D_BITS)

        out_valid = (vbuf >> tsel) & 1
        out_data = u(dbuf >> (tsel * PAY_W), PAY_W)

        words.append(u((tap_index << 8) | active_lat, 32))
        words.append(u((beat_count << 8) | drop_count, 32))
        words.append(u((lat_events << 3) | (drop_sticky << 2) |
                       (in_ready << 1) | out_valid, 32))
        words.append(u(out_data, 32))

    words.append(BEATS)
    emit('ips_delay_tap', words)


if __name__ == '__main__':
    main()
