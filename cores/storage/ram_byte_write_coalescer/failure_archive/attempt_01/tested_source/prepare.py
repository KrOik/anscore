#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Create the entire finite input/oracle matrix before any production RTL."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import random

ROOT = Path(__file__).resolve().parent
BASELINE = 'b6af9a4c6b843924c6eb4d45b2fdf362dcc8b333'
PROFILES = [(1, 1, 1, 1), (3, 1, 2, 3), (3, 5, 2, 3),
            (7, 16, 4, 8), (16, 32, 4, 8), (32, 64, 8, 32)]
U64 = (1 << 64) - 1
TARGETS = ['idle', 'load_masked', 'append_first', 'append_last',
           'scan_read_first', 'scan_read_middle', 'scan_read_last',
           'scan_check_first', 'scan_check_middle', 'scan_check_last',
           'merge_first', 'merge_last', 'prep',
           'out_read_first', 'out_read_middle', 'out_read_last',
           'request_hold_first', 'request_hold_last',
           'ack_wait_first', 'ack_wait_last', 'ack_after_error',
           'held_ok', 'held_write_error', 'drain_format', 'drain_range',
           'drain_capacity']


def encoded(obj):
    return (json.dumps(obj, sort_keys=True, indent=2) + '\n').encode('utf-8')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def pack(items):
    value = 0
    for item, width in items:
        assert 0 <= item < (1 << width), (item, width)
        value = (value << width) | item
    return value


def geometry(profile):
    n, a, b, _ = profile
    physical = (1 << a) // b
    return min(n, physical), physical


def frame(profile, ident, name, specs, backend='none', mutate=None, slow=False):
    """Primary oracle: byte dictionary plus insertion-ordered beat keys."""
    n, a, b, t = profile
    tokens = []
    for i, (address, data, keep) in enumerate(specs):
        tokens.append(dict(addr=address, data=data, keep=keep,
                           first=int(i == 0), last=int(i == len(specs)-1),
                           tag=(((1 << t)-1 if ident % 5 == 0 else ident*13+3)
                                if i == 0 else (ident*29+i*7)) & ((1 << t)-1),
                           gap=0 if i % 3 else (ident+i) % 3))
    assert tokens
    if mutate:
        mutate(tokens)
    byte_values = {}
    base_order = []
    errors = 0
    events = []
    total_reads = total_writes = 0
    for i, token in enumerate(tokens):
        address = token['addr']
        assert 0 <= address <= U64 and 0 <= token['data'] <= 255
        if token['first'] != int(i == 0):
            errors |= 1
        valid_address = address < (1 << a)
        if token['keep'] and not valid_address:
            errors |= 2
        k = 0
        changed_index = -1
        changed_row = 0
        work = 0
        if token['keep'] and valid_address and not (errors & 4):
            base = address - address % b
            if base in base_order:
                # Separate first-occurrence rank certificate, not an FSM model.
                rank = base_order.index(base)
                k = rank + 1
                changed_index = rank
            else:
                k = len(base_order)
                if len(base_order) == n:
                    errors |= 4
                    work = 2*k
                else:
                    changed_index = len(base_order)
                    base_order.append(base)
            if changed_index >= 0:
                byte_values[address] = token['data']
                lane_values = [byte_values.get(base+j, 0) for j in range(b)]
                strobe = sum((base+j in byte_values) << j for j in range(b))
                data = sum(value << (8*j) for j, value in enumerate(lane_values))
                changed_row = pack([(base, a), (data, 8*b), (strobe, b)])
                total_writes += 1
                work = 2*k+1
            total_reads += k
        events.append(dict(scan_reads=k, write_index=changed_index,
                           write_row=changed_row, count=len(base_order),
                           errors=errors, work=work))
    assert [i for i, x in enumerate(tokens) if x['last']] == [len(tokens)-1]
    requests = []
    error_mask = 0
    if errors == 0:
        for i, base in enumerate(base_order):
            error = int(backend == 'all' or
                        (backend == 'first' and i == 0) or
                        (backend == 'middle' and i == len(base_order)//2) or
                        (backend == 'last' and i == len(base_order)-1) or
                        (backend == 'alternate' and i % 2 == 0))
            data = sum(byte_values.get(base+j, 0) << (8*j) for j in range(b))
            strobe = sum((base+j in byte_values) << j for j in range(b))
            requests.append(dict(addr=base, data=data, strobe=strobe, error=error,
                                 q_stall=4 if slow else (ident+2*i) % 4,
                                 ack_delay=4 if slow else (2*ident+i) % 5))
            error_mask |= error << i
        total_reads += len(requests)
    status = errors << 1 if errors else (1 if not requests else (16 if error_mask else 0))
    count = len(requests)
    h = events[-1]['work']
    waits = sum(x['q_stall']+x['ack_delay'] for x in requests)
    latency = h + (3*count+1+waits if count else 1)
    return dict(id=ident, name=name, tokens=tokens, events=events,
                requests=requests, backend=backend,
                expected=dict(status=status, tag=tokens[0]['tag'], count=count,
                              error_mask=error_mask, scan_reads=sum(x['scan_reads'] for x in events),
                              ram_reads=total_reads, ram_writes=total_writes,
                              tail_work=h, external_waits=waits, latency=latency),
                final_bytes={str(k): v for k, v in sorted(byte_values.items())})


def main_frames(profile):
    n, a, b, _ = profile
    cap, physical = geometry(profile)
    limit = 1 << a
    masked = (U64, 255, 0)
    low = [(i*b, (17*i+5) & 255, 1) for i in range(cap)]
    high = [((physical-1-i)*b, (31*i+9) & 255, 1) for i in range(cap)]
    full = [masked] + low + [masked]
    overflow = low + ([(cap*b, 99, 1)] if physical > n else [(0, 99, 1)])
    bad = 1 << a if a < 64 else U64
    cases = []
    def add(name, specs, backend='none', mutate=None):
        cases.append((name, specs, backend, mutate))
    add('empty_single', [masked])
    add('empty_many', [masked]*9)
    add('zero_address', [(0, 0, 1)])
    add('highest_address', [(limit-1, 255, 1)])
    add('all_lanes', [(j, 19*j & 255, 1) for j in range(b)])
    add('reverse_lanes', [(j, 255-17*j, 1) for j in reversed(range(b))])
    add('same_byte_replacement', [(0, v, 1) for v in [0, 255, 0, 1, 254, 0]])
    add('noncontiguous_revisit', low+[(0, 207, 1)])
    add('full_capacity', full)
    add('full_then_all_replaced', low+list(reversed([(i*b, 255-i, 1) for i in range(cap)])))
    add('capacity_or_physical_alias', overflow+[masked]*4)
    add('masked_only', [masked]*17)
    add('masked_head_and_tail', [masked, (limit-1, 3, 1), masked])
    add('first_masked_owns_tag', [masked, (0, 17, 1), masked])
    add('missing_first_masked', [masked, (0, 5, 1)], mutate=lambda x: x[0].update(first=0))
    add('missing_first_kept', [(0, 5, 1)], mutate=lambda x: x[0].update(first=0))
    add('late_first_masked', [(0, 5, 1), masked], mutate=lambda x: x[-1].update(first=1))
    add('late_first_kept', [masked, (0, 5, 1)], mutate=lambda x: x[-1].update(first=1))
    add('late_first_tail', full, mutate=lambda x: x[-1].update(first=1))
    add('first_on_every_token', full, mutate=lambda x: [v.update(first=1) for v in x])
    add('full64_ones_address', [(U64, 91, 1)])
    add('first_outside_or_full64_alias', [(bad, 13, 1)])
    add('range_before_legal', [(bad, 13, 1), (0, 23, 1)])
    add('range_after_legal', [(0, 23, 1), (bad, 13, 1)])
    add('masked_range_ignored', [masked, (0, 71, 1), masked])
    add('format_and_range', [(bad, 255, 1), masked], mutate=lambda x: x[0].update(first=0))
    add('capacity_and_format', overflow+[masked], mutate=lambda x: x[-1].update(first=1))
    add('capacity_and_range', overflow+[(bad, 101, 1), masked])
    add('all_frame_error_flags', overflow+[(bad, 101, 1), masked], mutate=lambda x: x[-1].update(first=1))
    add('all_lanes_repeat', [(j, 255, 1) for j in range(b)]+[(j, 0, 1) for j in reversed(range(b))])
    add('interleaved_replacements', low+[(i*b+(b-1), (i+211) & 255, 1) for i in reversed(range(cap))])
    add('high_descending_bases', high)
    add('sixtyfour_same_byte_writes', [(limit-1, (i*43) & 255, 1) for i in range(64)])
    add('many_masked_after_payload', low+[masked]*11)
    for mode in ['first', 'middle', 'last', 'all', 'alternate']:
        add('backend_'+mode, full, mode)
    add('high_bits_valid', high+[(limit-1, 128, 1)])
    add('ignored_later_tags', full, mutate=lambda x: [v.update(tag=0) for v in x[1:]])
    add('kept_tail', [masked]+low)
    add('masked_tail_full', full)
    add('one_byte_per_beat', low)
    add('zero_ff_high_bases', high+[(v[0], 0, 1) for v in high]+[(v[0], 255, 1) for v in reversed(high)])
    add('alternating_byte_zero', [(0, (i & 1)*255, 1) for i in range(19)])
    add('zero_after_ff', [(0, 255, 1), (0, 0, 1)])
    add('next_frame_same_address', [(0, 93, 1), masked])
    assert len(cases) == 48, len(cases)
    for bit in range(64):
        add('isolated_address_bit_'+str(bit), [(1 << bit, (bit*13) & 255, 1)])
    rng = random.Random(0xB240A+19*n+31*a+7*b)
    for i in range(48):
        length = rng.randint(1, 4*cap*b+3)
        specs = []
        for j in range(length):
            address = rng.choice([0, limit-1, rng.randrange(limit), rng.randrange(cap)*b+rng.randrange(b)])
            if a < 64 and i % 7 == 0 and j == length//2:
                address = (1 << a) | rng.randrange(limit)
            specs.append((address, rng.randrange(256), int(rng.randrange(5) != 0)))
        mutation = (lambda x: x[-1].update(first=1)) if i % 11 == 0 else None
        add('seeded_'+str(i), specs, ['none','first','last','alternate'][i % 4], mutation)
    return [frame(profile, i, *case) for i, case in enumerate(cases)]


def reset_cases(profile):
    n, a, b, _ = profile
    cap, physical = geometry(profile)
    masked = (U64, 255, 0)
    fill = [(i*b, (73*i+11) & 255, 1) for i in range(cap)]
    alias = {}
    if cap == 1:
        for name in TARGETS:
            if name.endswith('_middle') or name.endswith('_last'):
                alias[name] = name.rsplit('_', 1)[0]+'_first'
        alias['ack_after_error'] = 'UNREACHABLE: only one representable/live beat'
    if a == 64:
        alias['drain_range'] = 'UNREACHABLE: every full64 address is in domain'
    if physical <= n:
        alias['drain_capacity'] = 'UNREACHABLE: all representable beats fit'
    result = []
    for target_id, target in enumerate(TARGETS):
        if target in alias:
            continue
        specs = [masked]+fill+[(0, 197, 1), ((cap-1)*b, 231, 1), masked]
        mode = 'first' if target in ['ack_after_error','held_write_error'] else 'none'
        if target == 'drain_format':
            mutate = lambda x: x[0].update(first=0)
        else:
            mutate = None
        if target == 'drain_range':
            specs = [masked, (1 << a, 19, 1), masked, (0, 255, 1)]
        elif target == 'drain_capacity':
            specs = [masked]+fill+[(cap*b, 19, 1), masked, (0, 255, 1)]
        candidate = frame(profile, 2000+target_id, 'cancel_'+target, specs, mode, mutate, True)
        fresh_specs = [masked]+[((physical-1-i)*b+j, (target_id*31+i*17+j*7) & 255, 1)
                                for i in range(cap) for j in range(b)]
        fresh_specs += [((physical-cap)*b, 255-target_id, 1), masked]
        fresh_tag = candidate['tokens'][0]['tag'] ^ ((1 << profile[3])-1)
        fresh = frame(profile, 4000+target_id, 'fresh_'+target, fresh_specs, 'none',
                      lambda x, tag=fresh_tag: x[0].update(tag=tag))
        result.append(dict(target_id=target_id, target=target, candidate=candidate, fresh=fresh,
                           prefix_pause_after_tokens=1 if target == 'load_masked' else 0,
                           prefix_pause_cycles=4 if target == 'load_masked' else 0))
    return result, alias


def text_fixture(profile, main, resets):
    n, a, b, t = profile
    frames = main+[f for reset in resets for f in [reset['candidate'], reset['fresh']]]
    lines = [f'{len(main)} {len(resets)} {len(frames)} {sum(len(f["tokens"]) for f in frames)} {sum(len(f["requests"]) for f in frames)}']
    lines += [' '.join(str(r['target_id']) for r in resets)]
    for f in frames:
        e = f['expected']
        lines.append(f'{f["id"]} {len(f["tokens"])} {e["status"]} {e["tag"]:x} {e["count"]} {e["error_mask"]:x} {e["ram_reads"]} {e["ram_writes"]} {e["tail_work"]} {e["external_waits"]} {e["latency"]}')
        for token, event in zip(f['tokens'], f['events']):
            word = pack([(token['addr'],64),(token['data'],8),(token['keep'],1),
                         (token['first'],1),(token['last'],1),(token['tag'],t)])
            lines.append(f'{word:x} {token["gap"]} {event["scan_reads"]} {event["write_index"]} {event["write_row"]:x} {event["count"]} {event["errors"]} {event["work"]}')
        for q in f['requests']:
            lines.append(f'{q["addr"]:x} {q["data"]:x} {q["strobe"]:x} {q["error"]} {q["q_stall"]} {q["ack_delay"]}')
    return ('\n'.join(lines)+'\n').encode('ascii')


def freeze():
    assert not (ROOT/'TEST_PLAN.json').exists(), 'Freeze already exists; no replacement authorized'
    assert not list(ROOT.rglob('*.sv')) and not list(ROOT.rglob('*.v')), 'Must freeze before RTL'
    out = ROOT/'vectors'
    out.mkdir()
    profiles = []
    for number, profile in enumerate(PROFILES):
        main = main_frames(profile)
        resets, aliases = reset_cases(profile)
        obj = dict(profile=list(profile), main=main, resets=resets, reset_aliases=aliases)
        files = {}
        for suffix, data in [('json', encoded(obj)), ('txt', text_fixture(profile, main, resets))]:
            name = f'vectors/p{number}.{suffix}'
            (ROOT/name).write_bytes(data)
            files[name] = dict(sha256=sha(data), bytes=len(data))
        profiles.append(dict(id=f'p{number}', parameters=list(profile), fixtures=files,
                             main_frames=len(main), main_tokens=sum(len(x['tokens']) for x in main),
                             main_requests=sum(len(x['requests']) for x in main),
                             main_status_counts=dict(Counter(x['expected']['status'] for x in main)),
                             resets=[dict(target_id=r['target_id'], target=r['target']) for r in resets],
                             reset_aliases=aliases, fresh_frames=len(resets),
                             fresh_requests=sum(len(r['fresh']['requests']) for r in resets)))
    children = []
    def child(name, argv, expected='PASS'):
        children.append(dict(name=name, argv=argv, expected=expected, timeout_seconds=20))
    child('core_default_lint', ['iverilog','-g2012','-Wall','-tnull','-s','ram_byte_write_coalescer','-f','files.f'])
    child('example_default_lint', ['iverilog','-g2012','-Wall','-tnull','-s','byte_scatter16','-f','example/files.f'])
    for i, profile in enumerate(PROFILES):
        options = [f'-Ptb_ram_byte_write_coalescer.{key}={value}' for key, value in zip(['N','A','B','T'],profile)]
        child(f'p{i}_compile', ['iverilog','-g2012','-Wall','-s','tb_ram_byte_write_coalescer']+options+
              ['-o','{exe}','rtl/ram_byte_write_coalescer.sv','sim/tb_ram_byte_write_coalescer.sv'])
        child(f'p{i}_sim', ['vvp','{exe}',f'+VECTORS=vectors/p{i}.txt',f'+PROFILE=p{i}'])
    invalid = [('N0',{'MAX_BEATS':0}),('N33',{'MAX_BEATS':33}),('A0',{'ADDR_W':0}),
               ('A65',{'ADDR_W':65}),('B0',{'DATA_BYTES':0}),('B3',{'DATA_BYTES':3}),
               ('B16',{'DATA_BYTES':16}),('T0',{'TAG_W':0}),('T33',{'TAG_W':33}),
               ('A2_B8',{'ADDR_W':2,'DATA_BYTES':8})]
    for name, params in invalid:
        child('reject_'+name, ['iverilog','-g2012','-Wall','-tnull','-s','ram_byte_write_coalescer']+
              [f'-Pram_byte_write_coalescer.{k}={v}' for k,v in params.items()]+['-f','files.f'], 'EXPECTED_REJECT')
    plan = dict(schema='anscore.b24.byte_write_coalescer.plan.v1', baseline=BASELINE,
                frozen_before_any_rtl=True, child_timeout_seconds=20, children=children,
                profiles=profiles, reset_target_names=TARGETS,
                protocol_schedule=dict(output_hold_cycles=4, idle_guard_cycles=5,
                                       reset_asserted_edges=2,
                                       main_source='Actual next complete frozen token preoffered through processing/result, held until accepted or reset; per-token gap frozen in fixture.',
                                       reset='Observe actual named phase/index, assert reset immediately without another active edge. load_masked pauses after its first masked token for four active edges without LAST. Every cancellation completes its full reachable-capacity fresh frame and five idle edges.'),
                prepare_sha256=sha(Path(__file__).read_bytes()),
                semantics=dict(input='Full unsigned64 byte address checked against 2**ADDR_W before narrowing; KEEP0 ignores address/data. First accepted token must FIRST1; every later FIRST0; LAST on any accepted token closes. One-token FIRST/LAST is legal. Missing LAST waits until reset. Tokens after LAST belong to a later frame.',
                               errors='FORMAT and RANGE OR across all accepted tokens including capacity drain. FORMAT/RANGE do not stop provisional valid-address combining. First absent valid aligned beat with N retained beats sets sticky CAPACITY, stops all table writes/scans, but still checks FIRST and full64 range until LAST.',
                               output='status bit0 EMPTY, bit1 FORMAT, bit2 RANGE, bit3 CAPACITY, bit4 WRITE_ERROR. Invalid frame has only bits1..3 and zero count/mask; empty has only bit0. Valid nonempty attempts every distinct beat and sets bit4 iff any ACK error. Bitmask index is first-seen beat issue order; all other bits zero. One result with first token tag; no KEEP/FIRST/LAST result markers.',
                               backend='One outstanding acknowledged aligned write. Each distinct base once in first-occurrence order; final byte value is last accepted kept write. Unstrobed data zero. No request before complete validated LAST, no reads, no retry. Continue after ACK errors. Already accepted writes may have effects despite error/reset.',
                               lifetime='One frame through held result retirement; next actual token may preoffer. No same-edge result/next-input fallthrough. Ordinary idempotent RAM domain whose caller allows covered-store elimination and cross-beat reordering; no atomic frame/coherence/MMIO claim.',
                               reset='Synchronous high; public handshakes immediately gated. Cancels frame/output, clears scalar ownership without RAM sweep. Peer shares cancellation and discards pre-reset responses; otherwise old untagged ACK cannot be distinguished. No rollback or erasure guarantee.'),
                architecture=dict(states=['IDLE','LOAD','SCAN_READ','SCAN_CHECK','APPEND','MERGE','PREP','OUT_READ','REQUEST','WAIT_ACK','RESULT'],
                                  ram='N*(A+9B) bits; default1088/max4352; single packed sync-read bank, read/write disjoint',
                                  scalar_budget='2A+9B+2I+C+T+N+16 default153/max296; includes unreset row register, three sticky frame bits and N-bit ACK mask',
                                  clocks='Per accepted byte K scanned rows =>2K+1 work; first append1; full miss2N. After LAST h+1 for invalid/empty, otherwise h+3U+1+measured q/p wait edges. Successful bound5N+2 plus waits.'),
                negative_marker='ram_byte_write_coalescer_invalid_parameters__see_README',
                planned_children=len(children), planned_main_frames=sum(p['main_frames'] for p in profiles),
                planned_resets=sum(len(p['resets']) for p in profiles),
                not_run=['synthesis','PnR','STA','board','expanded regression','inherited matrix'],
                failure_policy='Timeout terminal: no retry, stimulus reduction or increased limit. Ordinary failure preserves exact source/plan/seal/receipt/all NOT_RUN/artifacts then stops for root same-stimulus repair authorization.')
    raw = encoded(plan)
    (ROOT/'TEST_PLAN.json').write_bytes(raw)
    print(json.dumps(dict(plan_sha256=sha(raw), children=len(children), main_frames=plan['planned_main_frames'],
                          resets=plan['planned_resets'], profiles=profiles), sort_keys=True))


if __name__ == '__main__':
    freeze()
