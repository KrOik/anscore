"""Independent golden model for ips_perf_event_ctr.

Written from the core's documented contract, never from simulation output
(docs/IP_CORE_SOP.md trap T1); the gate compares this digest against the RTL one.

Contract re-implemented here:
  * eight 8-bit channels, each owning a 4-bit AND group mask AM[i] and a 4-bit OR
    group mask OM[i] over the strobe bus:
        event[i] = ((strb & AM[i]) == AM[i])
                   and (OM[i] == 0 or (strb & OM[i]) != 0)
    (an empty AND group is vacuous, an empty OR group passes),
  * a channel increments once per enabled beat with en and event[i] set; it HOLDS
    when en is low,
  * write priority clr (all channels to zero) > cnt_we preset (cnt_wval into
    cnt_widx) > increment,
  * snap copies every counter into the shadow bank on one edge, taking the value
    the counter held BEFORE that beat's increment; snap_n counts snapshots,
  * ovf[i] is set exactly on the wrap edge (the increment that really rolls channel i
    from WRAP_AT to zero; a same-beat clear or preset is not a wrap) and is sticky;
    ov_clr drops it but a same-beat wrap still sets,
    ov_seq counts the beats with at least one wrap,
  * `ev` and `wrap` are registered, so what a beat observes is the event vector and
    the wrap strobe that were applied at that beat's own edge.

Stimulus contract shared with sim/tb_ips_perf_event_ctr.v (one LCG step per beat,
state[-1] = SEED):
    state = state * 1664525 + 1013904223  (mod 2**32)
    en      = (i % 150) < 120
    strb    = state[3:0]
    cfg_we  = (i % 64) < 4, cfg_idx = i % 4,
              cfg_amask = {4'h0, state[7:4]}, cfg_omask = {4'h0, state[11:8]}
    cnt_we  = 96..99 (channel i-96 := 0xF0 + (i-96)), 300..303
              (channel i-300 := 0xFF - (i-300)), 155 (channel 0 := 0xFF)
    snap    = (i % 32) == 7
    clr     = i == 250 or i == 430
    ov_clr  = i in (156, 200, 400)
    scripted: i == 128 programs channel 0 with AM=1, OM=0; i == 156 forces strb=1;
              200..203 force strb=15; 330..335 force strb=0.
Observed word order per beat, matching the testbench fold:
    counter bytes 0..7 (LSB byte first), shadow bytes 0..7,
    {ev, ovf} as a 32-bit word with ev in the upper half, {wrap, ov_seq} likewise,
    snap_n; then after the loop ov_seq, snap_n and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

BEATS = 480
SEED = 0x5A17C0DE
WRAP_AT = 0xFF

# shipped reset groups: channels 0..3 empty (they free-run until programmed)
DEF_AM = (0, 0, 0, 0, 0b0011, 0b0101, 0b1111, 0b0000)
DEF_OM = (0, 0, 0, 0, 0b1100, 0b0010, 0b1101, 0b0000)


def stimulus(index, state):
    """The input vector the core sees at the enabled edge of beat `index`."""
    if index < 0 or index >= BEATS:
        return dict(en=0, strb=0, cfg_we=0, cfg_idx=0, cfg_amask=0, cfg_omask=0,
                    cnt_we=0, cnt_widx=0, cnt_wval=0, snap=0, clr=0, ov_clr=0)
    inp = {
        'en': 1 if (index % 150) < 120 else 0,
        'strb': state & 0xF,
        'cfg_we': 1 if (index % 64) < 4 else 0,
        'cfg_idx': index % 4,
        'cfg_amask': (state >> 4) & 0xF,
        'cfg_omask': (state >> 8) & 0xF,
        'cnt_we': 0,
        'cnt_widx': 0,
        'cnt_wval': 0,
        'snap': 1 if (index % 32) == 7 else 0,
        'clr': 1 if (index == 250 or index == 430) else 0,
        'ov_clr': 1 if index in (156, 200, 400) else 0,
    }
    if 96 <= index <= 99:
        inp['cnt_we'] = 1
        inp['cnt_widx'] = index - 96
        inp['cnt_wval'] = u(0xF0 + (index - 96), 8)
    if 300 <= index <= 303:
        inp['cnt_we'] = 1
        inp['cnt_widx'] = index - 300
        inp['cnt_wval'] = u(0xFF - (index - 300), 8)
    if index == 155:
        inp['cnt_we'] = 1
        inp['cnt_widx'] = 0
        inp['cnt_wval'] = 0xFF
    if index == 128:
        inp['cfg_we'] = 1
        inp['cfg_idx'] = 0
        inp['cfg_amask'] = 0b0001
        inp['cfg_omask'] = 0b0000
    if index == 156:
        inp['strb'] = 0b0001
    if 200 <= index < 204:
        inp['strb'] = 0b1111
    if 330 <= index < 336:
        inp['strb'] = 0b0000
    return inp


def select(strb, am, om):
    """Event select: the AND of group one AND the OR of group two."""
    and_ok = (strb & am) == am
    or_ok = (om == 0) or ((strb & om) != 0)
    return 1 if (and_ok and or_ok) else 0


def main():
    trace = '--trace' in sys.argv
    cnt = [0] * 8
    shd = [0] * 8
    am = list(DEF_AM)
    om = list(DEF_OM)
    ev = 0
    wrap = 0
    ovf = 0
    ov_seq = 0
    snap_n = 0
    state = SEED
    words = []

    for index in range(BEATS):
        state = lcg32(state)
        inp = stimulus(index, state)

        ev_c = [select(inp['strb'], am[k], om[k]) for k in range(8)]
        inc = [1 if (inp['en'] and ev_c[k]) else 0 for k in range(8)]
        pre = [1 if (inp['cnt_we'] and inp['cnt_widx'] == k) else 0 for k in range(8)]
        wrap_c = [1 if (inc[k] and not inp['clr'] and not pre[k]
                        and cnt[k] == WRAP_AT) else 0 for k in range(8)]

        new_cnt = list(cnt)
        for k in range(8):
            if inp['clr']:
                new_cnt[k] = 0
            elif pre[k]:
                new_cnt[k] = u(inp['cnt_wval'], 8)
            elif inc[k]:
                new_cnt[k] = u(cnt[k] + 1, 8)
        if inp['snap']:
            shd = list(cnt)
            snap_n = u(snap_n + 1, 4)
        cnt = new_cnt
        for k in range(8):
            if wrap_c[k]:
                ovf |= 1 << k
            elif inp['ov_clr']:
                ovf &= ~(1 << k)
        ev = u(sum(c << k for k, c in enumerate(ev_c)), 8)
        wrap = u(sum(c << k for k, c in enumerate(wrap_c)), 8)
        if any(wrap_c):
            ov_seq = u(ov_seq + 1, 8)
        if inp['cfg_we']:
            am[inp['cfg_idx']] = inp['cfg_amask'] & 0xF
            om[inp['cfg_idx']] = inp['cfg_omask'] & 0xF

        for k in range(8):
            words.append(u(cnt[k], 32))
        for k in range(8):
            words.append(u(shd[k], 32))
        words.append(((ev << 8) | ovf) & MASK32)
        words.append(((wrap << 8) | ov_seq) & MASK32)
        words.append(u(snap_n, 32))
        if trace:
            print("DBG %d en=%d strb=%x cwe=%d ci=%d cam=%x com=%x pwe=%d pwv=%x "
                  "sn=%d cl=%d oc=%d | cnt=%s shd=%s ev=%x wr=%x ovf=%x ovs=%x snn=%x"
                  % (index, inp['en'], inp['strb'], inp['cfg_we'], inp['cfg_idx'],
                     inp['cfg_amask'], inp['cfg_omask'], inp['cnt_we'],
                     inp['cnt_wval'], inp['snap'], inp['clr'], inp['ov_clr'],
                     ''.join('%02x' % c for c in reversed(cnt)),
                     ''.join('%02x' % c for c in reversed(shd)),
                     ev, wrap, ovf, ov_seq, snap_n))

    words.append(u(ov_seq, 32))
    words.append(u(snap_n, 32))
    words.append(BEATS)
    emit('ips_perf_event_ctr', words)


if __name__ == '__main__':
    main()
