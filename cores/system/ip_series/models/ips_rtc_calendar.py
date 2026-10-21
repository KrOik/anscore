"""Independent golden model for ips_rtc_calendar.

Written from the core's documented contract (src/ips_rtc_calendar.v header) and
from Python's own calendar module for the civil rules: month lengths come from
calendar.monthrange() and the leap-year rule from calendar.isleap(), so this file
never re-derives the RTL's month table or its century compares
(docs/IP_CORE_SOP.md trap T1).  The internal 9-bit year field is the civil year
modulo 400; 2000 is a multiple of 400, so calendar rules applied to the image
year 2000 + y agree with y exactly.

Folding rule, mirrored verbatim in sim/tb_ips_rtc_calendar.v: one index i is one
core clock cycle, a stalled index folds nothing, and every enabled cycle folds
the complete registered state as four 32-bit words, MSB byte first:
    W1 = {year, mon, day, hour}
    W2 = {dim, leap, tick, alarm_hit, alarm_sticky, set_ack, set_err,
          clamp_sticky, mon_sticky, mon_count}
    W3 = {tick_count, day_count}
    W4 = {err_count, clamp_count, alarm_count}

Stimulus contract shared with the testbench:
    BEATS = 400, SEED = 0x2C15A7E3, state = state*1664525 + 1013904223 (mod 2**32)
    advanced once per index including stalled indices.
    stall(i)  : i % 40 == 39, clk_en low and every stimulus input 0.
    sweep     : 60 <= i < 180, j = (i-60)//5, o = (i-60)%5, preset at o == 0.
    free      : 180 <= i < 260, stimulus 0.
    probe     : 260 <= i < 320, LCG stimulus.
    tail      : 320 <= i < 400, LCG stimulus with the set/alarm/ack selectors
                remapped to 3 / 6 / 1.
"""

import calendar
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

# Defaults exactly as declared in the core's parameter list.
PRESC_DIV = 2
HOUR_LAST = 23
MON_LAST = 12
YEAR_LAST = 399

DIM_31, DIM_30, DIM_29, DIM_28 = 31, 30, 29, 28
ERR_SAT = 7
YEAR_BASE = 2000            # a multiple of 400, so the modulo image is faithful

BEATS = 400
SEED = 0x2C15A7E3
SWEEP_START = 60
SWEEP_N = 24
SWEEP_WIN = 5
PROBE_START = 260
TAIL_START = 320

# (year mod 400, month) preset targets, identical to SW_YR/SW_MO in the TB.
SWEEP = [
    (24, 1), (24, 2), (24, 3), (24, 4), (24, 5), (24, 6), (24, 7), (24, 8),
    (24, 9), (24, 10), (24, 11), (24, 12), (100, 2), (200, 2), (300, 2),
    (0, 2), (0, 12), (25, 2), (99, 12), (100, 12), (399, 12), (3, 2), (4, 2),
    (24, 1),
]


def leap_of(year):
    """Gregorian leap rule for the modulo-400 year image, from the stdlib."""
    return calendar.isleap(YEAR_BASE + year)


def dim_of(year, mon):
    """Month length for the modulo-400 year image, from the stdlib."""
    return calendar.monthrange(YEAR_BASE + year, mon)[1]


def idle(mirror):
    v = dict(mirror)
    v.update({'set_stb': 0, 'al_stb': 0, 'alarm_ack': 0})
    return v


def sweep_inputs(j, mirror):
    # drive_cycle() leaves alarm_ack low here: every oo == 0 index follows a cycle
    # that drove it low (idle_inputs, or the mode-5 ack that only pulses at oo==2).
    v = dict(mirror)
    v['set_stb'] = 1
    v['alarm_ack'] = 0
    v['set_year'] = SWEEP[j][0]
    v['set_mon'] = SWEEP[j][1]
    v['set_day'] = 31
    v['set_hour'] = 23 if j <= 20 else 0
    v['al_stb'] = 0
    v['al_en'] = mirror['al_en']
    v['al_mask'] = mirror['al_mask']
    mode = j % 6
    if mode == 0:
        y, m = SWEEP[j]
        v['al_stb'] = 1
        v['al_en'] = 1
        v['al_mask'] = 0xF
        v['al_day'] = 1
        v['al_hour'] = 0
        v['al_mon'] = 1 if m == 12 else m + 1
        v['al_year'] = (0 if y == 399 else y + 1) if m == 12 else y
    elif mode == 3:
        v.update({'al_stb': 1, 'al_en': 0, 'al_mask': 0xF, 'al_year': 0,
                  'al_mon': 0, 'al_day': 0, 'al_hour': 0})
    elif mode == 4:
        v.update({'al_stb': 1, 'al_en': 1, 'al_mask': 0x0, 'al_year': 0,
                  'al_mon': 0, 'al_day': 0, 'al_hour': 0})
    elif mode == 5:
        v.update({'al_stb': 1, 'al_en': 1, 'al_mask': 0x1, 'al_year': 0,
                  'al_mon': 1, 'al_day': 1, 'al_hour': 0})
    else:
        v.update({'al_year': mirror['al_year'], 'al_mon': mirror['al_mon'],
                  'al_day': mirror['al_day'], 'al_hour': mirror['al_hour']})
    return v


def probe_inputs(state, tail):
    v = {}
    sel = state & 0x7
    v['set_stb'] = 1 if sel == (3 if tail else 5) else 0
    v['al_stb'] = 1 if sel == (6 if tail else 2) else 0
    v['alarm_ack'] = 1 if sel == (1 if tail else 7) else 0
    v['set_mon'] = (state >> 4) & 0xF
    v['set_day'] = (state >> 8) & 0x3F
    v['set_hour'] = (state >> 14) & 0x1F
    v['set_year'] = (state >> 19) & 0x1FF
    v['al_en'] = (state >> 3) & 1
    v['al_mask'] = (state >> 10) & 0xF
    v['al_year'] = (~((state >> 19) & 0x1FF)) & 0x1FF
    v['al_mon'] = (state >> 14) & 0xF
    v['al_day'] = (state >> 18) & 0x3F
    v['al_hour'] = (state >> 24) & 0x1F
    return v


def stimulus(i, state, mirror):
    """The TB's drive_cycle(): advance the generator, then pick the inputs."""
    state = lcg32(state)
    if (i % 40) == 39:
        return state, idle(mirror), True
    v = dict(mirror)
    v.update({'set_stb': 0, 'al_stb': 0, 'alarm_ack': 0})
    if SWEEP_START <= i < SWEEP_START + SWEEP_N * SWEEP_WIN:
        j = (i - SWEEP_START) // SWEEP_WIN
        o = (i - SWEEP_START) % SWEEP_WIN
        if o == 0:
            v = sweep_inputs(j, mirror)
        elif (j % 6) == 5:
            v['alarm_ack'] = 1 if o == 2 else 0
    elif i >= PROBE_START:
        v = probe_inputs(state, i >= TAIL_START)
    else:
        v = idle(mirror)
    return state, v, False


def step(st, x):
    """One enabled core cycle of the contract in src/ips_rtc_calendar.v."""
    s = dict(st)
    s['set_ack'] = 0
    s['set_err'] = 0
    s['alarm_hit'] = 0

    dset = False
    serr = False
    lp = dm = None
    if x['set_stb']:
        if (x['set_mon'] == 0 or x['set_mon'] > MON_LAST or x['set_day'] == 0 or
                x['set_hour'] > HOUR_LAST or x['set_year'] > YEAR_LAST):
            serr = True
        else:
            lp = 1 if leap_of(x['set_year']) else 0
            dm = dim_of(x['set_year'], x['set_mon'])
            dset = True

    # al_stb is a plain register load, visible to the next cycle's compare.
    nxt_al = dict((k, s[k]) for k in
                  ('al_en_r', 'al_mask_r', 'al_year_r', 'al_mon_r', 'al_day_r',
                   'al_hour_r'))
    if x['al_stb']:
        nxt_al = {'al_en_r': x['al_en'], 'al_mask_r': x['al_mask'],
                  'al_year_r': x['al_year'], 'al_mon_r': x['al_mon'],
                  'al_day_r': x['al_day'], 'al_hour_r': x['al_hour']}
    if x['alarm_ack']:
        s['alarm_sticky'] = 0
    if serr:
        s['set_err'] = 1
        if s['err_count'] != ERR_SAT:
            s['err_count'] = (s['err_count'] + 1) & 0xF

    p = (s['psc'] == PRESC_DIV) and not dset
    s['tick'] = 1 if p else 0
    s['psc'] = 0 if (dset or p) else (s['psc'] + 1)

    if dset:
        s['year'] = x['set_year']
        s['mon'] = x['set_mon']
        s['hour'] = x['set_hour']
        s['leap'] = lp
        s['dim'] = dm
        s['day'] = min(x['set_day'], dm)
        s['hit_latch'] = 0
        s['set_ack'] = 1
        if x['set_day'] > dm:
            s['clamp_sticky'] = 1
            s['clamp_count'] = (s['clamp_count'] + 1) & 0xF

    if p:
        s['tick_count'] = (s['tick_count'] + 1) & 0xFF
        droll = False
        mroll = False
        nyr, nmo, nday, nhr = s['year'], s['mon'], s['day'], s['hour']
        nlp, ndm = s['leap'], s['dim']
        if s['hour'] == HOUR_LAST:
            nhr = 0
            droll = True
            if s['day'] == s['dim']:
                nday = 1
                mroll = True
                if s['mon'] == MON_LAST:
                    nmo = 1
                    nyr = 0 if s['year'] == YEAR_LAST else (s['year'] + 1) & 0x1FF
                    nlp = 1 if leap_of(nyr) else 0
                else:
                    nmo = (s['mon'] + 1) & 0xF
                    nlp = s['leap']
                ndm = dim_of(nyr, nmo)
            else:
                nday = (s['day'] + 1) & 0x3F
        else:
            nhr = (s['hour'] + 1) & 0x1F

        if droll:
            s['day_count'] = (s['day_count'] + 1) & 0xFF
        if mroll:
            s['mon_count'] = (s['mon_count'] + 1) & 0xF
            s['mon_sticky'] = 1

        m_ok = 1
        if s['al_mask_r'] & 1 and nhr != s['al_hour_r']:
            m_ok = 0
        if s['al_mask_r'] & 2 and nday != s['al_day_r']:
            m_ok = 0
        if s['al_mask_r'] & 4 and nmo != s['al_mon_r']:
            m_ok = 0
        if s['al_mask_r'] & 8 and nyr != s['al_year_r']:
            m_ok = 0
        hl = 0 if droll else s['hit_latch']
        hit = 1 if (s['al_en_r'] and not hl and m_ok) else 0
        if hit:
            s['alarm_hit'] = 1
            s['alarm_sticky'] = 1
            if s['alarm_count'] != 0xFF:
                s['alarm_count'] = (s['alarm_count'] + 1) & 0xFF
        s['hit_latch'] = 1 if hit else hl

        s['year'], s['mon'], s['day'], s['hour'] = nyr, nmo, nday, nhr
        s['leap'], s['dim'] = nlp, ndm

    s.update(nxt_al)
    return s


def fold(s):
    w1 = (s['year'] << 15) | (s['mon'] << 11) | (s['day'] << 5) | s['hour']
    w2 = ((s['dim'] << 12) | (s['leap'] << 11) | (s['tick'] << 10) |
          (s['alarm_hit'] << 9) | (s['alarm_sticky'] << 8) |
          (s['set_ack'] << 7) | (s['set_err'] << 6) |
          (s['clamp_sticky'] << 5) | (s['mon_sticky'] << 4) | s['mon_count'])
    w3 = (s['tick_count'] << 8) | s['day_count']
    w4 = (s['err_count'] << 12) | (s['clamp_count'] << 8) | s['alarm_count']
    return [u(w1, 32), u(w2, 32), u(w3, 32), u(w4, 32)]


def initial_state():
    return {
        'year': 0, 'mon': 1, 'day': 1, 'hour': 0, 'dim': DIM_31, 'leap': 1,
        'tick': 0, 'tick_count': 0, 'day_count': 0, 'mon_count': 0,
        'mon_sticky': 0, 'alarm_hit': 0, 'alarm_sticky': 0, 'alarm_count': 0,
        'set_ack': 0, 'set_err': 0, 'err_count': 0, 'clamp_sticky': 0,
        'clamp_count': 0, 'psc': 0, 'hit_latch': 0, 'al_en_r': 0, 'al_mask_r': 0,
        'al_year_r': 0, 'al_mon_r': 0, 'al_day_r': 0, 'al_hour_r': 0,
    }


def run():
    st = initial_state()
    mirror = {'al_en': 0, 'al_mask': 0, 'al_year': 0, 'al_mon': 0, 'al_day': 0,
              'al_hour': 0, 'set_year': 0, 'set_mon': 0, 'set_day': 0,
              'set_hour': 0}
    state = SEED
    words = []
    trace = []
    for i in range(BEATS):
        state, x, stalled = stimulus(i, state, mirror)
        if stalled:
            continue
        st = step(st, x)
        trace.append((i, fold(st), x, dict(st)))
        words.extend(fold(st))
        if x['al_stb']:
            mirror.update((k, x[k]) for k in
                          ('al_en', 'al_mask', 'al_year', 'al_mon', 'al_day',
                           'al_hour'))
    return words, trace


def main():
    words, _ = run()
    emit('ips_rtc_calendar', words)


if __name__ == '__main__':
    main()
