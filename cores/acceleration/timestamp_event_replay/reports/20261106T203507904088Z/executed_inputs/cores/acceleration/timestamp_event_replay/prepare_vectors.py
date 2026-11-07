#!/usr/bin/env python3
"""Finite stdlib-only fixture preparation; never launches/imports project tools.

Independent time oracle: due ticks use exact ceil(delta * 65536 / step),
phase uses arbitrary-precision (completed_ticks * step). It does not emulate
RTL's fixed-width accumulator, deadline register, or signal-level datapath.
All schedules are finite and named. This file has NOT been executed at draft.
"""
import argparse
import hashlib
import json
from pathlib import Path

FIELDS = (
    'rst run_enable abort_run c_valid c_count c_step_q16 c_tag '
    's_valid s_time s_data m_ready d_ready '
    'c_ready s_ready m_valid m_time m_data m_tag '
    'd_valid d_status d_received d_emitted d_anchor d_elapsed_q16 d_tag '
    'active epoch_flush'
).split()
PROFILES = (
    ('tiny', 1, 1, 1), ('ragged', 9, 37, 5),
    ('wide', 64, 577, 8), ('payload_max', 64, 1024, 32),
)
MAX_CASE_CYCLES = 2048
MAX_PROFILE_ROWS = 65536


class Oracle:
    def __init__(self, time_w, data_w, tag_w):
        self.tw, self.dw, self.gw = time_w, data_w, tag_w
        self.reset()

    def reset(self):
        self.mode = 'idle'
        self.total = self.received = self.emitted = self.step = self.tag = 0
        self.anchor = None
        self.ticks = self.head_time = self.head_data = self.status = 0
        self.has_head = self.offered = False

    @property
    def phase(self):
        return self.ticks * self.step

    def snapshot(self, x):
        active = self.mode in ('run', 'overflow_hold')
        flush = bool(x['rst'] or (active and x['abort_run']))
        overflow = (self.mode == 'run' and self.anchor is not None
                    and x['run_enable']
                    and (self.ticks + 1) * self.step >= (1 << (self.tw + 16)))
        return dict(
            c_ready=int(not x['rst'] and not x['abort_run'] and self.mode == 'idle'),
            s_ready=int(not flush and self.mode == 'run' and not self.has_head
                        and self.received < self.total and not overflow),
            m_valid=int(not flush and active and self.offered),
            m_time=self.head_time, m_data=self.head_data, m_tag=self.tag,
            d_valid=int(not x['rst'] and self.mode == 'done'), d_status=self.status,
            d_received=self.received, d_emitted=self.emitted,
            d_anchor=0 if self.anchor is None else self.anchor,
            d_elapsed_q16=self.phase, d_tag=self.tag,
            active=int(active), epoch_flush=int(flush), overflow=overflow,
        )

    def advance(self, x, y):
        if x['rst']:
            self.reset()
            return
        if y['active'] and x['abort_run']:
            self.mode, self.status = 'done', 4
            self.has_head = self.offered = False
            return
        if self.mode == 'idle':
            if x['c_valid'] and y['c_ready']:
                self.total, self.step, self.tag = x['c_count'], x['c_step_q16'], x['c_tag']
                self.received = self.emitted = self.ticks = 0
                self.anchor = None
                self.head_time = 0
                self.has_head = self.offered = False
                self.status = int(not self.total or not self.step)
                self.mode = 'done' if self.status else 'run'
            return
        if self.mode == 'done':
            if x['d_ready']:
                self.mode = 'idle'
            return
        output_take = bool(y['m_valid'] and x['m_ready'])
        if self.mode == 'overflow_hold':
            if output_take:
                self.emitted += 1
                self.has_head = self.offered = False
                self.mode = 'done'
            return
        if output_take and self.emitted + 1 == self.total:
            self.emitted += 1
            self.has_head = self.offered = False
            self.mode, self.status = 'done', 0
            return
        if y['overflow']:
            self.status = 3
            if output_take:
                self.emitted += 1
                self.has_head = self.offered = False
                self.mode = 'done'
            elif self.offered:
                self.mode = 'overflow_hold'
            else:
                self.has_head = False
                self.mode = 'done'
            return
        input_take = bool(x['s_valid'] and y['s_ready'])
        if input_take and self.anchor is not None and x['s_time'] < self.head_time:
            self.received += 1
            self.has_head = self.offered = False
            self.mode, self.status = 'done', 2
            return
        old_ticks = self.ticks
        old_anchored = self.anchor is not None
        if self.has_head and not self.offered and x['run_enable']:
            distance = (self.head_time - self.anchor) * 65536
            due_tick = (distance + self.step - 1) // self.step
            if old_ticks >= due_tick:
                self.offered = True
        if old_anchored and x['run_enable']:
            self.ticks += 1
        if output_take:
            self.emitted += 1
            self.has_head = self.offered = False
        if input_take:
            self.received += 1
            self.has_head, self.offered = True, False
            self.head_time, self.head_data = x['s_time'], x['s_data']
            if not old_anchored:
                self.anchor, self.ticks = x['s_time'], 0


def payload(width, seed):
    value, word = 0, seed & 0xffffffff
    for offset in range(0, width, 32):
        word = (1664525 * word + 1013904223) & 0xffffffff
        value |= word << offset
    return (value | (1 << (width - 1))) & ((1 << width) - 1)


class Fixture:
    def __init__(self, name, tw, dw, gw):
        self.name = name
        self.model = Oracle(tw, dw, gw)
        self.rows, self.cases = [], []
        self.coverage = dict(command=0, accepted=0, emitted=0,
                             held_output=0, held_done=0, paused=0, flush=0,
                             overflow_hold=0)

    def cycle(self, **changes):
        m = self.model
        x = dict(rst=0, run_enable=1, abort_run=0, c_valid=0,
                 c_count=0x12345678, c_step_q16=0xabcdef123456,
                 c_tag=(1 << m.gw) - 1, s_valid=0,
                 s_time=(1 << m.tw) - 1, s_data=payload(m.dw, len(self.rows)),
                 m_ready=1, d_ready=0)
        x.update(changes)
        y = m.snapshot(x)
        self.rows.append([x[k] if k in x else y[k] for k in FIELDS])
        if len(self.rows) > MAX_PROFILE_ROWS:
            raise RuntimeError('declared profile row cap exceeded')
        self.coverage['command'] += int(x['c_valid'] and y['c_ready'])
        self.coverage['accepted'] += int(x['s_valid'] and y['s_ready'])
        self.coverage['emitted'] += int(y['m_valid'] and x['m_ready'])
        self.coverage['held_output'] += int(y['m_valid'] and not x['m_ready'])
        self.coverage['held_done'] += int(y['d_valid'] and not x['d_ready'])
        self.coverage['paused'] += int(y['active'] and not x['run_enable'])
        self.coverage['flush'] += y['epoch_flush']
        self.coverage['overflow_hold'] += int(m.mode == 'overflow_hold')
        m.advance(x, y)
        return y

    def reset(self):
        self.cycle(rst=1)
        self.cycle(rst=1)
        self.cycle()

    def finish(self):
        if self.model.mode != 'done':
            raise RuntimeError('terminal response absent')
        for _ in range(4):
            self.cycle(d_ready=0, run_enable=0)
        self.cycle(d_ready=1)
        self.cycle()

    def case(self, label, times, step, status=0, *, count=None, stalls=False,
             pause=False, delayed=False, abort_empty=False, abort_held=False,
             reset_held=False):
        start = len(self.rows)
        count = len(times) if count is None else count
        command_tag = (len(self.cases) * 7 + 1) & ((1 << self.model.gw) - 1)
        accepted = self.cycle(c_valid=1, c_count=count, c_step_q16=step,
                              c_tag=command_tag, run_enable=0)
        if not accepted['c_ready']:
            raise RuntimeError('scenario failed to own command interface')
        index = held = 0
        for phase in range(MAX_CASE_CYCLES):
            if self.model.mode == 'done':
                break
            ready = not (stalls and phase < 16)
            enabled = not (pause and phase % 17 in (3, 4, 5, 6, 7))
            arrival = 0 if not delayed or index == 0 else 20 + 3 * index
            valid = index < len(times) and phase >= arrival
            abort = (abort_empty and phase == 3) or (abort_held and held == 4)
            if abort_empty:
                valid = False
            if reset_held and held == 4:
                self.cycle(rst=1, m_ready=0)
                self.cycle()
                self.cases.append(dict(label=label, start=start, end=len(self.rows),
                                       result='RESET_CANCELLED'))
                return
            y = self.cycle(run_enable=int(enabled), abort_run=int(abort),
                           s_valid=int(valid),
                           s_time=times[index] if valid else (1 << self.model.tw) - 1,
                           s_data=payload(self.model.dw, 0x5000 + index),
                           m_ready=int(ready))
            if valid and y['s_ready']:
                index += 1
            if y['m_valid'] and not ready:
                held += 1
        else:
            raise RuntimeError('finite scenario exhausted: ' + label)
        if self.model.status != status:
            raise RuntimeError(f'{label}: oracle status {self.model.status} != {status}')
        self.cases.append(dict(label=label, start=start, end=len(self.rows),
                               status=self.model.status, received=self.model.received,
                               emitted=self.model.emitted, anchor=self.model.anchor,
                               elapsed_q16=self.model.phase))
        self.finish()


def build_profile(name, tw, dw, gw):
    f = Fixture(name, tw, dw, gw)
    f.reset()
    f.case('zero_count', [], 65536, status=1, count=0)
    f.case('zero_step', [0], 0, status=1)
    f.case('minimum_step_equal_ties', [0, 0, 0], 1)
    f.case('fractional_quarter', [0, 1], 16384)
    f.case('abort_before_anchor', [0], 65536, status=4, abort_empty=True)
    f.case('abort_held_flush', [0], 1, status=4, stalls=True, abort_held=True)
    f.case('reset_held_flush', [0], 1, stalls=True, reset_held=True)
    f.case('recovery_after_reset', [0], 65536)
    if tw == 1:
        f.case('final_retirement_precedes_tick_overflow', [1], 65536)
        f.case('overflow_before_offer_full_step_high_bits', [1], (1 << 48) - 1, status=3)
        f.case('overflow_retains_held_output', [0], 65536, status=3, stalls=True)
        f.case('abort_overrides_overflow_hold', [0], 65536, status=4,
               stalls=True, abort_held=True)
    else:
        top = (1 << tw) - 1
        f.case('unsigned_max_anchor', [top - 3, top - 2, top], 65536)
        f.case('backwards_terminal', [top - 3, top - 1, top - 2], 65536, status=2)
        f.case('clock_runs_while_source_absent', [0, 4, 9], 65536, delayed=True)
        f.case('pause_and_held_output', [0, 4, 9], 32768, stalls=True, pause=True)
        if tw == 64:
            f.case('unsigned_sign_boundary', [(1 << 63) - 1, 1 << 63, (1 << 63) + 1], 65536)
            f.case('maximum_step_without_narrowing', [0, (1 << 32) - 1, (1 << 32) + 2],
                   (1 << 48) - 1)
    return f


def add_message(timestamp, order, locate, tracking, sell=False):
    msg = (b'A' + locate.to_bytes(2, 'big') + tracking.to_bytes(2, 'big')
           + timestamp.to_bytes(6, 'big') + order.to_bytes(8, 'big')
           + (b'S' if sell else b'B') + (100 + order).to_bytes(4, 'big')
           + b'TEST    ' + (1000 + order).to_bytes(4, 'big'))
    assert len(msg) == 36
    return len(msg).to_bytes(2, 'big') + msg


def packet(feed):
    session = b'B50FEED00' + bytes([48 + feed])
    assert len(session) == 10
    base = 100 if feed == 0 else 200
    messages = b''.join(add_message(100000 + (feed + 2 * i) * 1000,
                                    10 + feed + 2 * i, 11 + feed,
                                    20 + i, bool(feed)) for i in range(2))
    result = session + base.to_bytes(8, 'big') + (2).to_bytes(2, 'big') + messages
    assert len(result) == 96
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    # Fresh exclusive directory: an existing attempt is never overwritten/reused.
    args.out.mkdir(parents=False, exist_ok=False)
    manifest = dict(schema='timestamp-event-replay-fixtures-v1', status='PREPARED_ONLY',
                    fields=FIELDS, max_case_cycles=MAX_CASE_CYCLES,
                    max_profile_rows=MAX_PROFILE_ROWS, profiles=[], files={})
    for name, tw, dw, gw in PROFILES:
        fixture = build_profile(name, tw, dw, gw)
        content = str(len(fixture.rows)) + '\n' + ''.join(' '.join(format(v, 'x') for v in row) + '\n' for row in fixture.rows)
        path = args.out / (name + '.txt')
        path.write_text(content, encoding='ascii', newline='\n')
        manifest['profiles'].append(dict(name=name, time_w=tw, data_w=dw, tag_w=gw,
                                         rows=len(fixture.rows), cases=fixture.cases,
                                         coverage=fixture.coverage))
        manifest['files'][path.name] = hashlib.sha256(content.encode('ascii')).hexdigest()
    for feed in (0, 1):
        data = packet(feed)
        content = ''.join(f'{b:02x}\n' for b in data)
        path = args.out / f'feed{feed}.hex'
        path.write_text(content, encoding='ascii', newline='\n')
        manifest['files'][path.name] = hashlib.sha256(content.encode('ascii')).hexdigest()
    (args.out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n',
                                           encoding='utf-8', newline='\n')
    print(json.dumps(dict(status='PREPARED_ONLY', profiles=len(PROFILES),
                         rows=sum(p['rows'] for p in manifest['profiles']),
                         payload_files=len(manifest['files'])), sort_keys=True))


if __name__ == '__main__':
    main()
