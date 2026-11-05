"""Freeze finite ternary-rule mathematics and exact HDL commands before RTL."""
from hashlib import sha256
import itertools
import json
from pathlib import Path
import random
import re

ROOT = Path(__file__).resolve().parent
BASELINE = 'da85338f8a22c454cce77f5b88dd7a803975deb6'
PROFILES = [(1, 1, 1, 1), (3, 4, 3, 3), (7, 9, 8, 5),
            (16, 32, 16, 8), (17, 64, 32, 16), (64, 128, 64, 32)]
STATES = ['IDLE', 'VALIDATE', 'WRITE', 'READ', 'MATCH', 'FINISH', 'HOLD']
TARGETS = STATES + [
    'QUERY_MULTI_MATCH_HELD', 'QUERY_MISS_HELD', 'QUERY_CATCHALL_MATCH',
    'QUERY_NONCONTIGUOUS_MATCH', 'QUERY_LOWEST_PRIORITY_HELD',
    'QUERY_HIGHEST_ONLY_HELD', 'QUERY_LAST_ROW_MATCH', 'QUERY_LAST_ROW_MISS',
    'QUERY_INACTIVE_READ', 'GET_OWNED_READ', 'GET_HELD',
    'SET_NEW_BEFORE_WRITE', 'SET_REPLACE_BEFORE_WRITE', 'SET_REPLACE_HELD',
    'DELETE_LIVE_VALIDATE', 'DELETE_MISSING_HELD', 'CLEAR_HELD',
    'STATUS_FULL_HELD', 'BAD_SLOT_HELD', 'BAD_OP_HELD',
    'QUERY_SUCCESS_HELD', 'ACTUAL_NEXT_BLOCKED', 'SET_PUBLISHED_HELD',
    'DELETE_PUBLISHED_HELD', 'GET_MISSING_HELD', 'QUERY_FIRST_ROW_MATCH',
    'QUERY_MIDDLE_ROW_MATCH', 'QUERY_FIRST_ACCUMULATED_MASK']
HELD = {6, 7, 8, 11, 12, 17, 20, 22, 23, 24, 25, 26, 27, 29, 30, 31}
# Literal expressions implemented by target_reached() in the frozen testbench.
# row_hit means live[scan] && (((read_pattern ^ cmd_value) & read_care)==0).
# published compares every live bit and every live packed row with owner.after.
PREDICATES = [
    'state==IDLE && !owner_accepted && c_valid && command==owner.command && !m_valid',
    'state==VALIDATE && op==QUERY', 'state==WRITE && op==SET',
    'state==READ && op==QUERY', 'state==MATCH && op==QUERY',
    'state==FINISH && op==QUERY', 'state==HOLD && m_valid && !m_ready',
    'held && op==QUERY && m_found && m_match_count>1',
    'held && op==QUERY && m_status==MISS && !m_found',
    'state==MATCH && op==QUERY && row_hit && read_care==0',
    'state==MATCH && op==QUERY && row_hit && read_care==((1<<(K-1))|1)',
    'held && op==QUERY && m_slot==0 && m_match_count>1',
    'held && op==QUERY && m_slot==N-1 && m_match_count==1',
    'state==MATCH && op==QUERY && scan==N-1 && row_hit',
    'state==MATCH && op==QUERY && scan==N-1 && live[scan] && !row_hit',
    'state==READ && op==QUERY && !live[scan]',
    'state==READ && op==GET && live[slot]',
    'held && op==GET && m_found',
    'state==WRITE && op==SET && !live[slot]',
    'state==WRITE && op==SET && live[slot]',
    'held && op==SET && owner.before_count==N && published',
    'state==VALIDATE && op==DELETE && live[slot]',
    'held && op==DELETE && m_status==NOT_LIVE',
    'held && op==CLEAR && live_count==0 && published',
    'held && op==STATUS && live_count==N',
    'held && m_status==BAD_SLOT && slot==0xffffffff',
    'held && m_status==BAD_OP && op==7 && slot==0xffffffff',
    'held && op==QUERY && m_found && m_status==OK',
    'state==VALIDATE && owner_accepted && c_valid && command==actual_next && !c_ready',
    'held && op==SET && live[slot] && published',
    'held && op==DELETE && !live[slot] && published',
    'held && op==GET && m_status==NOT_LIVE',
    'state==MATCH && op==QUERY && scan==0 && row_hit',
    'state==MATCH && op==QUERY && scan==N/2 && row_hit',
    'state==MATCH && op==QUERY && scan>0 && match_mask!=0',
]
assert len(PREDICATES) == len(TARGETS)


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n',
                    encoding='utf-8', newline='\n')


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def pattern_text(value, care, width):
    bits, enabled = format(value, '0%db' % width), format(care, '0%db' % width)
    return ''.join(bit if mask == '1' else '-' for bit, mask in zip(bits, enabled))


def members(text):
    """Small-domain gold enumerates the actual accepted key set."""
    options = [('0', '1') if bit == '-' else (bit,) for bit in text]
    return frozenset(int(''.join(bits), 2) for bits in itertools.product(*options))


def matches(value, care, key, width):
    text = pattern_text(value, care, width)
    if width <= 4:
        return key in members(text)
    regex = ''.join('[01]' if bit == '-' else bit for bit in text)
    return re.fullmatch(regex, format(key, '0%db' % width)) is not None


def snapshot(table):
    return [[slot, *table[slot]] for slot in sorted(table)]


def evaluate(profile, commands):
    n, k, d, t = profile
    table, result = {}, []
    for command in commands:
        op, slot, value, care, action, tag = command
        assert 0 <= op <= 7 and 0 <= slot < 2**32
        assert 0 <= value < 2**k and 0 <= care < 2**k
        assert 0 <= action < 2**d and 0 <= tag < 2**t
        before = snapshot(table)
        out = dict(status=0, found=0, matches=0, match_count=0,
                   slot=0, pattern=0, care=0, action=0)
        if op >= 6:
            out['status'] = 3
        elif op in (1, 2, 3) and slot >= n:
            out['status'] = 2
        elif op == 0:
            hit = [i for i, (v, m, a) in sorted(table.items()) if matches(v, m, value, k)]
            # Independent per-position bit relation, without regex/expanded sets.
            direct = [i for i, (v, m, a) in sorted(table.items()) if all(
                not ((m >> bit) % 2) or ((v >> bit) % 2 == (value >> bit) % 2)
                for bit in range(k))]
            assert hit == direct
            out['matches'] = sum(2**i for i in hit)
            out['match_count'] = len(hit)
            if hit:
                out.update(found=1, slot=hit[0], action=table[hit[0]][2])
            else:
                out['status'] = 1
        elif op == 1:
            text = pattern_text(value, care, k)
            canonical = int(text.replace('-', '0'), 2)
            assert canonical == value & care
            table[slot] = (canonical, care, action)
            out.update(found=1, slot=slot, pattern=canonical, care=care, action=action)
        elif op in (2, 3):
            if slot not in table:
                out['status'] = 4
            elif op == 2:
                del table[slot]
            else:
                v, m, a = table[slot]
                out.update(found=1, slot=slot, pattern=v, care=m, action=a)
        elif op == 4:
            table.clear()
        out.update(op=op, tag=tag, live_count=len(table))
        result.append(dict(command=command, before=before, after=snapshot(table), expected=out))
    return result


class Commands:
    def __init__(self, profile, seed=0):
        self.n, self.k, self.d, self.t = profile
        self.counter = seed
        self.items = []

    def add(self, op, slot=0, value=0, care=0, action=0):
        self.counter += 1
        tag = (self.counter * 13 ^ (self.counter >> 2)) % 2**self.t
        self.items.append([op, slot, value % 2**self.k, care % 2**self.k,
                           action % 2**self.d, tag])


def main_groups(profile):
    n, k, d, t = profile
    km, am = 2**k - 1, 2**d - 1
    groups = []
    c = Commands(profile)
    c.add(5); c.add(0); c.add(0, 2**32 - 1, km, km, am)
    for op in (1, 2, 3):
        for slot in (n, 2**31, 2**32 - 1): c.add(op, slot, km, km, am)
    for op in (6, 7): c.add(op, 2**32 - 1, km, km, am)
    c.add(1, 0, km, 0, am); c.add(3, 0); c.add(0, 2**32 - 1, km, km, am)
    c.add(1, 0, km, km, 0); c.add(0, value=0); c.add(0, value=km)
    c.add(2, 0); c.add(2, 0); c.add(3, 0); c.add(4, 2**32 - 1, km, km, am)
    c.add(5); c.add(0, value=km)
    groups.append(('boundaries', c.items))
    if k <= 4:
        patterns = list(itertools.product('-01', repeat=k))
        for start in range(0, len(patterns), 8):
            c = Commands(profile, 1000 + start)
            for ordinal, bits in enumerate(patterns[start:start + 8], start):
                text = ''.join(bits); care = int(''.join('0' if x == '-' else '1' for x in bits), 2)
                value = int(''.join(str((ordinal >> i) % 2) if x == '-' else x
                                    for i, x in enumerate(bits)), 2)
                c.add(4); c.add(1, ordinal % n, value, care, ordinal)
                c.add(3, ordinal % n)
                for key in range(2**k): c.add(0, 2**32 - 1, key, km, am)
                c.add(4)
            groups.append(('ternary_%03d' % start, c.items))
    for start in range(0, k, 16):
        c = Commands(profile, 2000 + start)
        for bit in range(start, min(start + 16, k)):
            c.add(4); c.add(1, bit % n, km, 2**bit, bit + 1); c.add(3, bit % n)
            c.add(0, value=0); c.add(0, value=km); c.add(4)
        groups.append(('bits_%03d' % start, c.items))
    c = Commands(profile, 3000)
    c.add(4)
    for slot in range(n): c.add(1, slot, km, 0, slot + 1)
    c.add(5); c.add(0, value=km)
    for slot in range(n): c.add(3, slot)
    c.add(1, 0, km, 0, am); c.add(0, value=0)
    for slot in range(n): c.add(2, slot); c.add(0, value=slot % 2**k)
    c.add(1, n - 1, km, km, am); c.add(0, value=km); c.add(0, value=km ^ 1)
    c.add(4); c.add(5)
    groups.append(('overlaps', c.items))
    if k > 1:
        c = Commands(profile, 4000)
        c.add(4)
        for slot in range(n):
            care = (2**(k - 1) + 1) if slot % 2 == 0 else (km ^ 1)
            c.add(1, slot, (slot * 101) ^ km, care, slot * 7)
        for key in (0, km, 1, 2**(k - 1), 2**(k - 1) + 1, km ^ 1): c.add(0, value=key)
        for slot in range(n): c.add(3, slot)
        c.add(4); groups.append(('noncontiguous', c.items))
    for group in range(4):
        rng = random.Random(0xB26A + n * 4096 + k * 16 + group)
        c = Commands(profile, 5000 + group * 64); c.add(4)
        for _ in range(64):
            op = rng.choice([0, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7])
            slot = rng.randrange(n) if rng.randrange(4) else rng.choice([n, 2**32 - 1])
            care = rng.choice([0, km, rng.getrandbits(k)])
            c.add(op, slot, rng.getrandbits(k), care, rng.getrandbits(d))
        c.add(4); groups.append(('random_%d' % group, c.items))
    return groups


def fresh_commands(profile, target):
    n, k, d, t = profile
    c = Commands(profile, 10000 + target * 257)
    for slot in range(n): c.add(1, slot, (slot * 37 + target + 1), 2**k - 1, slot * 19 + target + 1)
    for slot in range(n): c.add(3, slot)
    for key in (0, 2**k - 1, (target + 1) % 2**k): c.add(0, value=key)
    c.add(5); c.add(4)
    return c.items


def reset_unit(profile, target):
    n, k, d, t = profile
    c = Commands(profile, 20000 + target * 257)
    c.add(4)
    empty = target in (15, 18, 22, 31)
    if not empty:
        for slot in range(n):
            value, care = 0, 0
            if target == 8: value, care = 1, 2**k - 1
            if target == 10: value, care = 0, 2**(k - 1) + 1
            if target == 12: value, care = int(slot == n - 1), 2**k - 1
            if target == 14: value, care = int(slot == n - 1), 2**k - 1
            c.add(1, slot, value, care, slot + 1)
    setup = evaluate(profile, c.items)
    owner = Commands(profile, 30000 + target)
    if target in (2, 18, 19, 20, 29): owner.add(1, n - 1, 2**k - 1, 2**k - 1, 2**d - 1)
    elif target in (16, 17, 31): owner.add(3, n - 1)
    elif target in (21, 22, 30): owner.add(2, n - 1)
    elif target == 23: owner.add(4)
    elif target == 24: owner.add(5)
    elif target == 25: owner.add(3, 2**32 - 1)
    elif target == 26: owner.add(7, 2**32 - 1, 2**k - 1, 2**k - 1, 2**d - 1)
    else: owner.add(0, value=1 if target == 12 else 0)
    complete = evaluate(profile, c.items + owner.items)
    return dict(id=target, target=TARGETS[target], setup=setup, owner=complete[-1],
                fresh=evaluate(profile, fresh_commands(profile, target)), owner_retired_prefix=0)


def text_command(item, nxt):
    o, s, v, c, a, t = item['command']; e = item['expected']
    lines = ['%d %d %x %x %x %x %d %d %d %x %d %d %x %x %x %d %d' % (
        o, s, v, c, a, t, e['status'], e['live_count'], e['found'], e['matches'],
        e['match_count'], e['slot'], e['pattern'], e['care'], e['action'],
        len(item['before']), len(item['after']))]
    next_command = nxt if nxt is not None else [0] * 6
    no, ns, nv, nc, na, nt = next_command
    lines.append('%d %d %d %x %x %x %x' % (int(nxt is not None), no, ns, nv, nc, na, nt))
    for rows in (item['before'], item['after']):
        lines += ['%d %x %x %x' % tuple(row) for row in rows]
    return lines


def save_job(name, data, kind):
    path = ROOT / 'fixtures' / (name + '.json'); dump(path, data)
    lines = ['%d %d' % (int(kind == 'resets'), len(data['units'] if kind == 'resets' else data['items']))]
    if kind == 'main':
        for i, item in enumerate(data['items']):
            lines += text_command(item, data['items'][i + 1]['command'] if i + 1 < len(data['items']) else None)
    else:
        for unit in data['units']:
            lines.append('%d %d %d' % (unit['id'], len(unit['setup']), len(unit['fresh'])))
            for role, sequence in (('setup', unit['setup']), ('owner', [unit['owner']]), ('fresh', unit['fresh'])):
                for i, item in enumerate(sequence):
                    nxt = sequence[i + 1]['command'] if i + 1 < len(sequence) else None
                    if role == 'owner': nxt = unit['fresh'][0]['command']
                    lines += text_command(item, nxt)
    text = path.with_suffix('.txt'); text.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    return dict(name=name, json=path.relative_to(ROOT).as_posix(), text=text.relative_to(ROOT).as_posix(),
                json_sha256=digest(path), text_sha256=digest(text))


def main():
    assert not (ROOT / 'TEST_PLAN.json').exists(), 'immutable preparation exists'
    assert not (ROOT / 'rtl').exists(), 'preparation must precede RTL'
    profiles, commands = [], []
    def child(name, argv, expected='PASS'):
        commands.append(dict(name=name, argv=argv, expected=expected, timeout_seconds=20))
    child('core_default_lint', ['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'ram_ternary_rule_table', '-f', 'files.f'])
    child('example_default_lint', ['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'ternary_rules16', '-f', 'example/files.f'])
    for pi, profile in enumerate(PROFILES):
        n, k, d, t = profile; name = 'p%d' % pi
        p = dict(name=name, S=n, K=k, D=d, T=t, first_valid_bound=2*n+2,
                 main=[], resets=[], reset_exclusions={})
        child(name + '_compile', ['iverilog', '-g2012', '-s', 'tb_ram_ternary_rule_table',
              '-Ptb_ram_ternary_rule_table.N=%d' % n, '-Ptb_ram_ternary_rule_table.K=%d' % k,
              '-Ptb_ram_ternary_rule_table.D=%d' % d, '-Ptb_ram_ternary_rule_table.T=%d' % t,
              '-o', '{TMP}/' + name + '.vvp', '-f', 'files.f', 'sim/tb_ram_ternary_rule_table.sv'])
        main_commands = setup_commands = fresh_count = 0
        for ji, (label, raw) in enumerate(main_groups(profile)):
            items = evaluate(profile, raw); main_commands += len(items)
            entry = save_job(name + '_main_%03d' % ji, dict(kind='main', profile=name, label=label, items=items), 'main')
            p['main'].append(entry)
            child(entry['name'], ['vvp', '{TMP}/' + name + '.vvp', '+INPUT=' + entry['text']])
        ids = []
        for target in range(len(TARGETS)):
            if n == 1 and target in (7, 11, 33, 34): p['reset_exclusions'][str(target)] = 'requires distinct multiple slots'; continue
            if k == 1 and target == 10: p['reset_exclusions'][str(target)] = 'noncontiguous care needs at least three key positions'; continue
            ids.append(target)
        units = [reset_unit(profile, target) for target in ids]
        for ji, start in enumerate(range(0, len(units), 2)):
            entry = save_job(name + '_reset_%03d' % ji, dict(kind='resets', profile=name, units=units[start:start+2]), 'resets')
            p['resets'].append(entry)
            child(entry['name'], ['vvp', '{TMP}/' + name + '.vvp', '+INPUT=' + entry['text']])
        setup_commands = sum(len(u['setup']) for u in units)
        fresh_count = sum(len(u['fresh']) for u in units)
        p.update(main_commands=main_commands, setup_commands=setup_commands, fresh_commands=fresh_count,
                 reset_ids=ids, reset_count=len(ids), completed_commands=main_commands+setup_commands+fresh_count,
                 held_cancelled_owners=sum(target in HELD for target in ids),
                 exhaustive_ternary_patterns=3**k if k <= 4 else 0,
                 exhaustive_pattern_key_pairs=3**k*2**k if k <= 4 else 0)
        profiles.append(p)
    for parameter, value in [('SLOTS', 0), ('SLOTS', 65), ('KEY_W', 0), ('KEY_W', 129),
                             ('ACTION_W', 0), ('ACTION_W', 65), ('TAG_W', 0), ('TAG_W', 33)]:
        child('reject_%s_%d' % (parameter, value), ['iverilog', '-g2012', '-tnull', '-s', 'ram_ternary_rule_table',
              '-Pram_ternary_rule_table.%s=%d' % (parameter, value), '-f', 'files.f'], 'EXPECTED_REJECT')
    plan = dict(schema=1, baseline=BASELINE, frozen_before_rtl=True, preparation_sha256=digest(Path(__file__)),
                timeout_seconds=20, timeout_terminal=True, no_adaptive_splits=True,
                states=STATES, reset_targets={str(i):dict(name=v, predicate=PREDICATES[i]) for i,v in enumerate(TARGETS)},
                held_owner_targets=sorted(HELD), profiles=profiles, commands=commands,
                excluded_checks=['synthesis', 'PnR', 'STA', 'board', 'inherited numerical matrix', 'expanded regression'])
    dump(ROOT / 'TEST_PLAN.json', plan)
    print(json.dumps(dict(plan_sha256=digest(ROOT / 'TEST_PLAN.json'), profiles=len(profiles),
          children=len(commands), simulations=sum(len(p['main'])+len(p['resets']) for p in profiles),
          completed=sum(p['completed_commands'] for p in profiles), resets=sum(p['reset_count'] for p in profiles)), sort_keys=True))


if __name__ == '__main__':
    main()
