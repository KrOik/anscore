"""Freeze the complete finite matrix before any RTL exists. Never overwrites it.

The primary model marks elementary endpoint atoms. It never merges an input
range into a list of stored intervals, and it never models a RAM/FSM schedule.
The separate small-address model marks individual bytes in an integer bitmap.
Only Python's standard library is used; upstream code is not imported or run.
"""
from collections import Counter
from hashlib import sha256
from pathlib import Path
from random import Random
import json

ROOT = Path(__file__).resolve().parent
BASELINE = 'd35d71be3bfc76f272809ae250d19cba92dbb18c'
PROFILES = [(1, 1, 1), (3, 1, 3), (3, 4, 3), (7, 16, 8),
            (16, 32, 8), (64, 64, 32)]
ADD, REMOVE, COVER, ENUM, CLEAR, STATUS = range(6)
OK, EMPTY, BAD_RANGE, FULL, BAD_OP = range(5)
STATES = ['IDLE', 'VALIDATE', 'START_BUILD', 'BUILD_READ', 'BUILD_USE',
          'EMIT_CHECK', 'EMIT_WRITE', 'NEXT_ROW', 'BUILD_FINISH', 'PUBLISH',
          'QUERY_START', 'QUERY_READ', 'QUERY_USE', 'QUERY_DONE',
          'ENUM_READ', 'ENUM_USE', 'HOLD', 'FAIL', 'SIMPLE']
SEMANTIC = ['ADD_OVERLAP', 'ADD_LEFT_ADJACENT', 'ADD_RIGHT_ADJACENT',
            'ADD_SECOND_BRIDGE', 'REMOVE_ZERO_FRAGMENT', 'REMOVE_ONE_FRAGMENT',
            'REMOVE_TWO_FRAGMENTS', 'ADD_CAPACITY_BEFORE_REJECT',
            'REMOVE_CAPACITY_BEFORE_REJECT', 'COVER_FULL_DOMAIN',
            'COVER_PARTIAL_MULTICOMPONENT', 'ENUM_FIRST_HELD',
            'ENUM_MIDDLE_HELD', 'ENUM_FINAL_AFTER_PRIOR_RETIRE',
            'FULL_BUILD_BEFORE_PUBLISH', 'SUCCESS_SUMMARY_HELD',
            'BAD_RANGE_SUMMARY_HELD', 'FULL_SUMMARY_HELD', 'ACTUAL_NEXT_BLOCKED',
            'BUILD_FIRST_PRIVATE_WRITE', 'BUILD_MIDDLE_PRIVATE_WRITE',
            'BUILD_LAST_PRIVATE_WRITE', 'CLEAR_SUMMARY_HELD',
            'STATUS_SUMMARY_HELD', 'ENUM_EMPTY_HELD', 'COVER_ZERO_HELD',
            'BAD_OP_SUMMARY_HELD']
TARGETS = STATES + SEMANTIC
PREDICATES = {str(i): 'state==' + str(i) for i in range(len(STATES))}
PREDICATES.update({
    '19': 'BUILD_USE ADD and max(old.lo,cmd.lo)<min(old.end,cmd.end)',
    '20': 'BUILD_USE ADD and old.end==cmd.lo',
    '21': 'BUILD_USE ADD and old.lo==cmd.end',
    '22': 'BUILD_USE ADD touching current row after at least one prior touching row',
    '23': 'BUILD_USE REMOVE and cmd.lo<=old.lo and old.end<=cmd.end',
    '24': 'BUILD_USE REMOVE nonempty overlap and exactly one retained edge fragment',
    '25': 'BUILD_USE REMOVE old.lo<cmd.lo and cmd.end<old.end',
    '26': 'EMIT_CHECK ADD and private_count==N before rejecting the next finalized fragment',
    '27': 'EMIT_CHECK REMOVE and private_count==N before rejecting the next finalized fragment',
    '28': 'QUERY_DONE and accumulated covered==2^A',
    '29': 'QUERY_DONE and 0<covered<requested_bytes and active_count>=2',
    '30': 'HOLD ENUM keep1 index0 with ready0',
    '31': 'HOLD ENUM index1 last0 after retiring exact prefix record0',
    '32': 'HOLD ENUM last1 after retiring exact prefix records0,1',
    '33': 'PUBLISH and private_count==min(N,2^(A-1)) before bank swap',
    '34': 'HOLD ADD statusOK summary with ready0',
    '35': 'HOLD statusBAD_RANGE summary with ready0',
    '36': 'HOLD statusFULL summary with ready0',
    '37': 'actual frozen first-fresh command valid&&!ready while state!=IDLE',
    '38': 'EMIT_WRITE private_count==0',
    '39': 'EMIT_WRITE private_count==floor(reachable_components/2), distinct from first/last',
    '40': 'EMIT_WRITE private_count==reachable_components-1',
    '41': 'HOLD CLEAR statusOK count0 summary with ready0',
    '42': 'HOLD STATUS statusOK summary with ready0',
    '43': 'HOLD ENUM statusEMPTY keep0 summary with ready0',
    '44': 'HOLD COVER statusOK covered0 whole0 summary with ready0',
    '45': 'HOLD statusBAD_OP summary with ready0',
})
A1_EXCLUSIONS = {22: 'only one separated component fits a two-byte domain',
                 25: 'a two-byte domain cannot retain both sides of a positive cut',
                 26: 'one reachable component never exceeds N>=1',
                 27: 'no two-fragment split exists in a two-byte domain',
                 29: 'only one separated component fits a two-byte domain',
                 31: 'fewer than three reachable components',
                 32: 'fewer than two reachable components',
                 36: 'no geometrically valid capacity failure exists',
                 39: 'one reachable row has no distinct middle write'}


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode('utf-8')


def valid_range(a, base, size):
    return 0 <= base < (1 << a) and size > 0 and base + size <= (1 << a)


def runs_from_atoms(points, flags):
    result = []
    start = None
    for i, present in enumerate(flags):
        if present and start is None:
            start = points[i]
        if start is not None and (not present or i == len(flags) - 1):
            end = points[i] if not present else points[i + 1]
            result.append([start, end])
            start = None
    return result


def runs_from_bytes(bits, size):
    result = []
    start = None
    for address in range(size + 1):
        present = address < size and bool((bits >> address) & 1)
        if present and start is None:
            start = address
        elif not present and start is not None:
            result.append([start, address])
            start = None
    return result


class AtomOracle:
    def __init__(self, n, a, commands):
        self.n, self.a = n, a
        points = {0, 1 << a}
        for op, base, size, tag in commands:
            assert 0 <= op < 8 and 0 <= base < (1 << 64)
            assert 0 <= size < (1 << 65) and tag >= 0
            if op in (ADD, REMOVE, COVER) and valid_range(a, base, size):
                points.update((base, base + size))
        self.points = sorted(points)
        self.flags = [False] * (len(self.points) - 1)
        self.bits = 0
        self.bitmap_checks = 0

    def step(self, command, kind):
        op, base, size, tag = command
        before = runs_from_atoms(self.points, self.flags)
        candidate = self.flags.copy()
        attempted = before
        status, covered, whole = OK, 0, False
        bitmap = self.bits
        if op > STATUS:
            status = BAD_OP
        elif op in (ADD, REMOVE, COVER) and not valid_range(self.a, base, size):
            status = BAD_RANGE
        elif op == CLEAR:
            candidate = [False] * len(candidate)
            bitmap = 0
        elif op in (ADD, REMOVE, COVER):
            for i, start in enumerate(self.points[:-1]):
                if base <= start < base + size:
                    if op == ADD:
                        candidate[i] = True
                    elif op == REMOVE:
                        candidate[i] = False
                    elif self.flags[i]:
                        covered += self.points[i + 1] - start
            if op == COVER:
                whole = covered == size
            if self.a <= 8:
                mask = ((1 << size) - 1) << base
                if op == ADD:
                    bitmap |= mask
                elif op == REMOVE:
                    bitmap &= ~mask
                else:
                    assert covered == (self.bits & mask).bit_count()
        attempted = runs_from_atoms(self.points, candidate)
        if op in (ADD, REMOVE) and status == OK and len(attempted) > self.n:
            status = FULL
            candidate = self.flags.copy()
            bitmap = self.bits
        after = runs_from_atoms(self.points, candidate)
        assert len(after) <= self.n
        assert all(0 <= lo < hi <= (1 << self.a) for lo, hi in after)
        assert all(after[i][1] < after[i + 1][0] for i in range(len(after) - 1))
        if self.a <= 8:
            assert after == runs_from_bytes(bitmap, 1 << self.a)
            self.bitmap_checks += 1
        self.flags, self.bits = candidate, bitmap
        total = sum(hi - lo for lo, hi in after)
        assert total <= (1 << self.a)
        records = []
        if op == ENUM and after:
            records = [dict(keep=1, first=int(i == 0), last=int(i == len(after) - 1),
                            index=i, base=lo, bytes=hi - lo)
                       for i, (lo, hi) in enumerate(after)]
        else:
            if op == ENUM:
                status = EMPTY
            records = [dict(keep=0, first=1, last=1, index=0, base=0, bytes=0)]
        expected = dict(status=status, count=len(after), total=total,
                        covered=covered, whole=int(whole), records=records)
        return dict(command=command, kind=kind, before=before,
                    attempted=attempted, after=after, expected=expected)


def make_block(kind, raw, rng, t):
    # Every independent block resets the persistent set through a real command.
    assert raw and raw[0][0] == CLEAR
    return dict(kind=kind, commands=[list(c) + [rng.getrandbits(t)] for c in raw])


def main_blocks(n, a, t):
    rng = Random(0xB251A7 + 131 * n + a)
    limit, f = 1 << a, min(n, 1 << (a - 1))
    blocks = []

    def block(kind, raw):
        blocks.append(make_block(kind, raw, rng, t))

    def fill(stride=2, first_length=1):
        return [(ADD, stride * i, first_length if i == 0 else 1) for i in range(f)]

    ignored = ((1 << 64) - 1, (1 << 65) - 1)
    block('empty_full_domain_and_ignored_fields', [
        (CLEAR, *ignored), (STATUS, *ignored), (ENUM, *ignored),
        (COVER, 0, limit), (REMOVE, 0, limit), (ADD, 0, limit),
        (COVER, 0, limit), (ENUM, *ignored), (ADD, limit - 1, 1),
        (STATUS, *ignored), (REMOVE, 0, limit), (ENUM, *ignored)])
    block('both_endpoint_adjacencies', [
        (CLEAR, 0, 0), (ADD, 0, 1), (ADD, 1, 1), (ENUM, 0, 0),
        (CLEAR, 0, 0), (ADD, 1, 1), (ADD, 0, 1), (ENUM, 0, 0),
        (COVER, 0, 2)])
    block('remove_zero_and_one_fragment', [
        (CLEAR, 0, 0), (ADD, 0, limit), (REMOVE, 0, 1), (ENUM, 0, 0),
        (ADD, 0, 1), (REMOVE, limit - 1, 1), (ENUM, 0, 0),
        (REMOVE, 0, limit), (ENUM, 0, 0), (REMOVE, 0, limit),
        (STATUS, 0, 0)])
    block('full_reachable_rows_both_banks', [(CLEAR, 0, 0)] + fill() + [
        (ADD, 0, 1), (ENUM, 0, 0), (COVER, 0, limit), (STATUS, 0, 0)])
    if a > 1:
        block('bridge_three_and_remove_two_fragments', [
            (CLEAR, 0, 0), (ADD, 0, 1), (ADD, 2, 1), (ADD, 4, 1),
            (ENUM, 0, 0), (ADD, 1, 3), (ENUM, 0, 0), (COVER, 0, 5),
            (REMOVE, 1, 3), (ENUM, 0, 0), (COVER, 0, 5),
            (REMOVE, 1, 3), (ENUM, 0, 0)])
        block('full_add_reject_and_bridge_reclaim', [(CLEAR, 0, 0)] + fill() + [
            (ADD, 2 * n, 1), (ENUM, 0, 0), (STATUS, 0, 0),
            (ADD, 0, 2 * n + 1), (ENUM, 0, 0), (STATUS, 0, 0)])
        block('full_remove_split_reject_and_recovery', [(CLEAR, 0, 0)] + fill(4, 3) + [
            (REMOVE, 1, 1), (ENUM, 0, 0), (COVER, 0, 3), (STATUS, 0, 0),
            (ADD, 0, 4 * n), (REMOVE, 1, 1), (ENUM, 0, 0),
            (COVER, 0, 4 * n), (STATUS, 0, 0)])
    # The host address always remains full unsigned64 even for tiny A.
    for bit in range(64):
        base = 1 << bit
        block('isolated_host_address_bit', [(CLEAR, 0, 0),
              (ADD, base, 1), (COVER, base, 1), (REMOVE, base, 1),
              (ENUM, 0, 0), (STATUS, 0, 0)])
    for base, size in [(0, 0), (limit - 1, 1), (limit - 1, 2),
                       (0, limit), (0, limit + 1),
                       ((1 << 64) - 1, (1 << 65) - 1),
                       ((1 << 64) - 1, 1), (0, (1 << 64)),
                       (0, (1 << 65) - 1)]:
        for op in (ADD, REMOVE, COVER):
            block('full_66bit_geometry_and_65bit_measure', [
                (CLEAR, 0, 0), (ADD, 0, limit), (op, base, size),
                (ENUM, 0, 0), (STATUS, 0, 0)])
    for op in (6, 7):
        block('reserved_opcode_priority', [(CLEAR, 0, 0), (ADD, 0, limit),
              (op, *ignored), (ENUM, *ignored), (STATUS, *ignored)])
    if a <= 4:
        small = min(limit, 8)
        for mask in range(1 << small):
            raw = [(CLEAR, 0, 0)] + [(ADD, i, 1) for i in range(small) if mask >> i & 1]
            raw += [(ENUM, 0, 0), (COVER, 0, limit)]
            for lo, hi in [(0, 1), (small - 1, small), (0, small),
                           (small // 2, small // 2 + 1)]:
                raw.append((COVER, lo, hi - lo))
            raw += [(ADD, 0, small), (REMOVE, small // 2, 1),
                    (ENUM, 0, 0), (STATUS, 0, 0)]
            block('exhaustive_small_byte_sets', raw)
        if a == 1:
            for mask in range(4):
                for lo, hi in [(0, 1), (1, 2), (0, 2)]:
                    for op in (ADD, REMOVE, COVER):
                        raw = [(CLEAR, 0, 0)] + [(ADD, i, 1) for i in range(2) if mask >> i & 1]
                        raw += [(op, lo, hi - lo), (ENUM, 0, 0), (STATUS, 0, 0)]
                        block('exhaustive_two_byte_transitions', raw)
    for trial in range(48):
        raw = [(CLEAR, 0, 0)]
        for j in range(14):
            op = rng.choice([ADD, ADD, REMOVE, REMOVE, COVER, ENUM, STATUS, 6, 7])
            if j % 7 == 0:
                base, size = rng.choice([(0, limit), (limit - 1, 1),
                                         (0, 0), (limit - 1, 2), ignored])
            else:
                # Small local spans exercise fragmentation even in A64.
                domain = min(limit, 4 * n + 16)
                base = rng.randrange(domain)
                size = rng.randrange(domain - base + 1)
            raw.append((op, base, size))
        raw += [(ENUM, 0, 0), (COVER, 0, limit), (STATUS, 0, 0)]
        block('seeded_persistent_operations', raw)
    return blocks


def owner_commands(target, n, a, t):
    limit = 1 << a
    setup = [(CLEAR, 0, 0), (ADD, 0, 1)]
    owner = (ADD, 0, limit)
    if target in (10, 11, 12, 13, 28):
        setup, owner = [(CLEAR, 0, 0), (ADD, 0, limit)], (COVER, 0, limit)
    if target in (14, 15, 16, 30):
        owner = (ENUM, 0, 0)
    if target in (17, 35):
        owner = (ADD, 0, 0)
    if target == 18:
        owner = (STATUS, 0, 0)
    if target == 20:
        owner = (ADD, 1, 1)
    if target == 21:
        setup, owner = [(CLEAR, 0, 0), (ADD, 1, 1)], (ADD, 0, 1)
    if target == 22:
        setup = [(CLEAR, 0, 0), (ADD, 0, 1), (ADD, 2, 1), (ADD, 4, 1)]
        owner = (ADD, 1, 3)
    if target == 23:
        owner = (REMOVE, 0, 1)
    if target == 24:
        setup, owner = [(CLEAR, 0, 0), (ADD, 0, 2)], (REMOVE, 0, 1)
    if target == 25:
        setup, owner = [(CLEAR, 0, 0), (ADD, 0, 3)], (REMOVE, 1, 1)
    if target in (26, 36):
        setup = [(CLEAR, 0, 0)] + [(ADD, 2 * i, 1) for i in range(n)]
        owner = (ADD, 2 * n, 1)
    if target == 27:
        setup = [(CLEAR, 0, 0)] + [(ADD, 4 * i, 3 if i == 0 else 1) for i in range(n)]
        owner = (REMOVE, 1, 1)
    if target == 29:
        setup, owner = [(CLEAR, 0, 0), (ADD, 0, 1), (ADD, 2, 1)], (COVER, 0, 3)
    if target in (31, 32):
        setup = [(CLEAR, 0, 0), (ADD, 0, 1), (ADD, 2, 1), (ADD, 4, 1)]
        owner = (ENUM, 0, 0)
    if target in (33, 38, 39, 40):
        reachable = min(n, 1 << (a - 1))
        setup = [(CLEAR, 0, 0)] + [(ADD, 2 * i, 1) for i in range(reachable)]
        owner = (ADD, 0, 1)
    if target in (41, 42):
        setup = [(CLEAR, 0, 0), (ADD, 0, limit)]
        owner = (CLEAR if target == 41 else STATUS, 0, 0)
    if target == 43:
        setup, owner = [(CLEAR, 0, 0)], (ENUM, 0, 0)
    if target == 44:
        setup, owner = [(CLEAR, 0, 0)], (COVER, 0, limit)
    if target == 45:
        setup, owner = [(CLEAR, 0, 0)], (6, (1 << 64) - 1, (1 << 65) - 1)
    tagmask = (1 << t) - 1
    return ([list(x) + [((i + 1) * 7) & tagmask] for i, x in enumerate(setup)],
            list(owner) + [tagmask])


def fresh_commands(n, a, t):
    reachable = min(n, 1 << (a - 1))
    raw = [(ADD, 2 * i, 1) for i in range(reachable)]
    raw += [(ADD, 0, 1), (ENUM, 0, 0), (COVER, 0, 1 << a), (STATUS, 0, 0)]
    return [list(x) + [(5 + 3 * i) & ((1 << t) - 1)] for i, x in enumerate(raw)]


def evaluate(n, a, commands, kinds):
    oracle = AtomOracle(n, a, commands)
    records = [oracle.step(c, k) for c, k in zip(commands, kinds)]
    assert len(records) == len(commands) == len(kinds)
    return records, oracle.bitmap_checks


def header(item, next_command=None):
    op, base, size, tag = item['command']
    e = item['expected']
    out = [f'{op} {base:016x} {size:017x} {tag:08x} '
           f"{e['status']} {e['count']} {e['total']:017x} {e['covered']:017x} "
           f"{e['whole']} {len(e['records'])} {len(item['before'])} "
           f"{len(item['attempted'])} {len(item['after'])}"]
    nc = next_command or [0, 0, 0, 0]
    out.append(f'{int(next_command is not None)} {nc[0]} {nc[1]:016x} {nc[2]:017x} {nc[3]:08x}')
    for r in e['records']:
        out.append(f"{r['keep']} {r['first']} {r['last']} {r['index']} {r['base']:016x} {r['bytes']:017x}")
    for key in ('before', 'attempted', 'after'):
        out += [f'{lo:016x} {hi:017x}' for lo, hi in item[key]]
    return out


def text_sequence(items, last_next=None):
    out = []
    for i, item in enumerate(items):
        nxt = items[i + 1]['command'] if i + 1 < len(items) else last_next
        out += header(item, nxt)
    return out


def prepare():
    assert not (ROOT / 'TEST_PLAN.json').exists(), 'immutable pre-RTL matrix already exists'
    assert not any(ROOT.rglob('*.sv')) and not any(ROOT.rglob('*.v'))
    all_files, profiles, children, commands = {}, [], [], []
    def child(name, argv, expectation='PASS'):
        children.append(name)
        commands.append(dict(name=name, argv=argv, expected=expectation, timeout_seconds=20))
    child('core_default_lint', ['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'ram_interval_set', '-f', 'files.f'])
    child('example_default_lint', ['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'interval_set16', '-f', 'example/files.f'])
    for pi, (n, a, t) in enumerate(PROFILES):
        name = 'p' + str(pi)
        blocks = main_blocks(n, a, t)
        # Immutable grouping by complete independent blocks, never measured runtime.
        command_limit = 80 if n == 64 else 160
        groups, group, count = [], [], 0
        for b in blocks:
            if group and count + len(b['commands']) > command_limit:
                groups.append(group); group, count = [], 0
            group.append(b); count += len(b['commands'])
        if group:
            groups.append(group)
        compile_argv = ['iverilog', '-g2012', '-Wall', '-s', 'tb_ram_interval_set',
                        '-o', '{TMP}/' + name + '.vvp',
                        '-Ptb_ram_interval_set.N=' + str(n),
                        '-Ptb_ram_interval_set.A=' + str(a),
                        '-Ptb_ram_interval_set.T=' + str(t),
                        'rtl/ram_interval_set.sv', 'sim/tb_ram_interval_set.sv']
        child(name + '_compile', compile_argv)
        profile = dict(name=name, N=n, A=a, T=t, main=[], resets=[],
                       reachable_components=min(n, 1 << (a - 1)),
                       excluded_reset_targets={str(k): v for k, v in A1_EXCLUSIONS.items()} if a == 1 else {},
                       reset_ids=[q for q in range(len(TARGETS)) if a != 1 or q not in A1_EXCLUSIONS],
                       block_coverage=dict(Counter(b['kind'] for b in blocks)),
                       ram_bits=2 * n * (2 * a + 1),
                       provisional_scalar_upper=16 * a + 8 * (n + 1).bit_length() + t + 64,
                       first_response_design_bound=6 * n + 16)
        main_count = main_outputs = bitmap_count = queued = 0
        def fixture(job_name, value, text_lines, metadata):
            jrel, trel = 'fixtures/' + job_name + '.json', 'fixtures/' + job_name + '.txt'
            jb, tb = encoded(value), ('\n'.join(text_lines) + '\n').encode('ascii')
            all_files[jrel], all_files[trel] = jb, tb
            entry = dict(json=jrel, json_sha256=sha256(jb).hexdigest(),
                         text=trel, text_sha256=sha256(tb).hexdigest(), **metadata)
            child(job_name, ['vvp', '{TMP}/' + name + '.vvp', '+INPUT=' + trel])
            return entry
        for gi, group in enumerate(groups):
            cmds = [c for b in group for c in b['commands']]
            kinds = [b['kind'] for b in group for c in b['commands']]
            items, checks = evaluate(n, a, cmds, kinds)
            bitmap_count += checks
            outputs = sum(len(x['expected']['records']) for x in items)
            job_name = f'{name}_main_{gi:03d}'
            value = dict(profile=name, mode='main', blocks=[dict(kind=b['kind'], commands=len(b['commands'])) for b in group], items=items)
            profile['main'].append(fixture(job_name, value, ['0 ' + str(len(items))] + text_sequence(items),
                                           dict(commands=len(items), outputs=outputs, queued=len(items) - 1)))
            main_count += len(items); main_outputs += outputs; queued += len(items) - 1
        reset_units = []
        fresh_raw = fresh_commands(n, a, t)
        fresh, checks = evaluate(n, a, fresh_raw, ['full_reachable_fresh'] * len(fresh_raw))
        assert fresh[-1]['after'] == [[2 * i, 2 * i + 1] for i in range(profile['reachable_components'])]
        for target in profile['reset_ids']:
            setup_raw, owner_raw = owner_commands(target, n, a, t)
            both, setup_checks = evaluate(n, a, setup_raw + [owner_raw],
                                           ['reset_setup'] * len(setup_raw) + ['cancel_owner'])
            bitmap_count += setup_checks + checks
            prefix = 1 if target == 31 else 2 if target == 32 else 0
            assert prefix < len(both[-1]['expected']['records'])
            if target in (26, 27, 36):
                assert both[-1]['expected']['status'] == FULL
            reset_units.append(dict(id=target, target=TARGETS[target],
                                    setup=both[:-1], owner=both[-1], fresh=fresh,
                                    owner_retired_prefix=prefix,
                                    next_offered=fresh_raw[0]))
        # Maximum profile uses one complete reset/recovery sequence per fixed job.
        reset_group = 1 if n == 64 else 2
        for ri in range(0, len(reset_units), reset_group):
            units = reset_units[ri:ri + reset_group]
            lines = ['1 ' + str(len(units))]
            for unit in units:
                lines.append(f"{unit['id']} {len(unit['setup'])} {len(unit['fresh'])} {unit['owner_retired_prefix']}")
                lines += text_sequence(unit['setup'])
                lines += header(unit['owner'], unit['next_offered'])
                lines += text_sequence(unit['fresh'])
            job_name = f'{name}_reset_{ri // reset_group:03d}'
            profile['resets'].append(fixture(job_name, dict(profile=name, mode='reset', units=units), lines,
                                             dict(targets=[x['id'] for x in units],
                                                  setup_commands=sum(len(x['setup']) for x in units),
                                                  fresh_commands=sum(len(x['fresh']) for x in units),
                                                  setup_outputs=sum(len(y['expected']['records']) for x in units for y in x['setup']),
                                                  fresh_outputs=sum(len(y['expected']['records']) for x in units for y in x['fresh']),
                                                  owner_retired_prefix=sum(x['owner_retired_prefix'] for x in units),
                                                  queued=sum(max(0, len(x['setup']) - 1) + len(x['fresh']) - 1 for x in units))))
        profile.update(main_commands=main_count, main_outputs=main_outputs, main_queued=queued,
                       direct_bitmap_command_checks=bitmap_count,
                       reset_count=len(reset_units),
                       fresh_commands=sum(len(x['fresh']) for x in reset_units),
                       fresh_outputs=sum(len(y['expected']['records']) for x in reset_units for y in x['fresh']),
                       setup_commands=sum(len(x['setup']) for x in reset_units),
                       setup_outputs=sum(len(y['expected']['records']) for x in reset_units for y in x['setup']))
        profiles.append(profile)
    rejections = [(p, v) for p, low, high in [('MAX_INTERVALS', 0, 65), ('ADDR_W', 0, 65), ('TAG_W', 0, 33)] for v in (low, high)]
    for p, v in rejections:
        child('reject_' + p + '_' + str(v), ['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'ram_interval_set', '-Pram_interval_set.' + p + '=' + str(v), '-f', 'files.f'], 'EXPECTED_REJECT')
    totals = {key: sum(p[key] for p in profiles) for key in [
        'main_commands', 'main_outputs', 'main_queued', 'direct_bitmap_command_checks',
        'reset_count', 'fresh_commands', 'fresh_outputs', 'setup_commands', 'setup_outputs']}
    totals.update(fixtures=len(all_files) // 2, fixture_files=len(all_files), children=len(children),
                  simulator_children=sum(len(p['main']) + len(p['resets']) for p in profiles),
                  expected_rejections=len(rejections))
    plan = dict(schema=1, baseline=BASELINE, frozen_before_any_rtl=True,
                timeout_seconds=20, timeout_terminal=True, no_adaptive_splits=True,
                preparation_sha256=sha256(Path(__file__).read_bytes()).hexdigest(),
                parameters=['MAX_INTERVALS', 'ADDR_W', 'TAG_W'], profiles=profiles,
                states={str(i): x for i, x in enumerate(STATES)},
                reset_targets={str(i): x for i, x in enumerate(TARGETS)},
                reset_predicates=PREDICATES,
                reset_observation='first falling-edge occurrence asserts reset before next rising edge; only targets31/32 retire the exact frozen ENUM prefix; fresh first command is the real blocked offer and is canceled by reset before re-offer',
                reset_fresh='every sequence fills every reachable row, duplicates one ADD to overwrite the other complete logical bank, retires all ENUM outputs, full-domain COVER and STATUS',
                primary_oracle='elementary endpoint atoms, Boolean occupancy and exact arbitrary-integer weighted integration; independent of interval merge and RAM FSM',
                secondary_oracle='direct per-byte integer bitmap for all A<=8 commands, separate run reconstruction and coverage bit_count',
                response_status=dict(OK=OK, EMPTY=EMPTY, BAD_RANGE=BAD_RANGE, FULL=FULL, BAD_OP=BAD_OP),
                mutation='ADD/REMOVE build private canonical bank; publication only after full fit, before result valid; invalid/FULL keep old entire set',
                input_domain='base unsigned64, bytes unsigned65; positive geometry validated with66-bit sum before narrowing; ignored geometry on ENUM/CLEAR/STATUS and reserved opcode priority',
                output_domain='ENUM spans have A-bit base, A+1-bit positive bytes; total/covered use A+1 bits including whole2^64; all summary geometry zero, first/last1',
                children=children, commands=commands, rejections=rejections, totals=totals,
                excluded_checks=['synthesis', 'PnR', 'STA', 'board', 'expanded regression', 'inherited matrix'])
    # All oracles/checks finish before the first immutable fixture is written.
    (ROOT / 'fixtures').mkdir(exist_ok=False)
    for rel, raw in all_files.items():
        (ROOT / rel).write_bytes(raw)
    (ROOT / 'TEST_PLAN.json').write_bytes(encoded(plan))
    print(json.dumps(dict(plan_sha256=sha256((ROOT / 'TEST_PLAN.json').read_bytes()).hexdigest(), **totals), sort_keys=True))


if __name__ == '__main__':
    prepare()
