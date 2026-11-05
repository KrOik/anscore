"""Freeze a small, deterministic CNF corpus. No RTL or external code executes."""
from pathlib import Path
import hashlib
import json
import random

ROOT = Path(__file__).resolve().parents[1]
PROFILES = [(1, 1, 1), (2, 4, 3), (4, 8, 5), (8, 16, 8), (16, 64, 32)]


def truth_table(n, clauses):
    """Evaluate all assignments in parallel, without propagation or search."""
    total = 1 << n
    universe = (1 << total) - 1
    columns = [int(("1" * (1 << v) + "0" * (1 << v)) *
                   (1 << (n-v-1)), 2) for v in range(n)]
    solutions = universe
    for positive, negative in clauses:
        clause = 0
        for v, column in enumerate(columns):
            if positive >> v & 1:
                clause |= column
            if negative >> v & 1:
                clause |= universe ^ column
        solutions &= clause
    smallest = (solutions & -solutions).bit_length()-1 if solutions else 0
    return bool(solutions), smallest, solutions.bit_count()


def scalar_satisfies(value, clauses):
    return all((positive & value) or (negative & ~value)
               for positive, negative in clauses)


def make_case(name, n, rows, *, declared=None, upstream=0, tag=0):
    return dict(name=name, num_vars=n,
                num_clauses=len(rows) if declared is None else declared,
                command_error=upstream, tag=tag,
                rows=[dict(positive=p, negative=q, last=int(i == len(rows)-1),
                           error=0) for i, (p, q) in enumerate(rows)])


def expectation(case, v, c):
    n, count = case['num_vars'], case['num_clauses']
    error = (int(n > v) | (int(count > c) << 1) |
             (int(bool(case['command_error'])) << 5))
    if error & 3:
        assert not case['rows']
    else:
        active = (1 << n)-1
        assert len(case['rows']) <= count
        for i, row in enumerate(case['rows']):
            final = i == count-1
            error |= int(bool((row['positive'] | row['negative']) & ~active)) << 2
            error |= int(bool(row['last'] and not final)) << 3
            error |= int(bool(final and not row['last'])) << 4
            error |= int(bool(row['error'])) << 5
            if row['last'] or final:
                assert i == len(case['rows'])-1
        assert count == 0 or case['rows'][-1]['last'] or len(case['rows']) == count
    if error:
        return dict(error=error, sat=False, smallest_assignment=0, solutions=0)
    clauses = [(r['positive'], r['negative']) for r in case['rows']]
    sat, witness, solutions = truth_table(n, clauses)
    if n <= 4:
        brute = [x for x in range(1 << n) if scalar_satisfies(x, clauses)]
        assert (sat, witness, solutions) == (bool(brute), brute[0] if brute else 0,
                                             len(brute))
    return dict(error=0, sat=sat, smallest_assignment=witness, solutions=solutions)


def corpus(v, c, t):
    mask = (1 << v)-1
    cases = []

    def add(name, n, clauses, **kwargs):
        case = make_case(name, n, clauses, **kwargs)
        case['tag'] = (len(cases)*37+11) & ((1 << t)-1)
        cases.append(case)
        return len(cases)-1

    empty = add('empty_cnf', v, [])
    add('zero_variable_empty_cnf', 0, [])
    conflict = add('empty_clause', v, [(0, 0)])
    add('zero_variable_empty_clause', 0, [(0, 0)])
    unit = add('positive_unit', v, [(1, 0)])
    add('negative_unit', v, [(0, 1)])
    tautology = add('tautology', v, [(mask, mask)])
    add('full_width_positive_clause', v, [(mask, 0)])
    add('full_width_negative_clause', v, [(0, mask)])
    # Full RAM overwrite and a nonzero, upper-variable fresh witness.
    fresh = add('fresh_full_capacity', v,
                [(mask, mask)]*(c-1)+[(1 << (v-1), 0)])
    branch = pop = nested = None
    if v >= 2:
        branch = add('decision_false_child', v, [(3, 0)]*c)
        if c >= 2:
            pop = add('true_child_restore', v, [(3, 0), (1, 2)])
            add('opposite_units', v, [(1, 0), (0, 1)])
        if c >= 3:
            # (x OR NOT x), (NOT x OR y), (NOT y) must allow x=y=0.
            add('tautology_must_not_force', v, [(1, 1), (2, 1), (0, 2)])
        if c >= 4:
            add('both_branches_unsat', v, [(3, 0), (1, 2), (2, 1), (0, 3)])
        if v >= 3:
            nested = add('nested_pending_snapshots', v, [(mask, 0)]*c)
    # Unit implication chain, with a full-domain positive terminal witness.
    chain = [(1, 0)]+[(1 << i, 1 << (i-1)) for i in range(1, min(v, c))]
    add('unit_chain', v, chain)
    if len(chain) < c:
        add('unit_chain_conflict', v, chain+[(0, 1 << (len(chain)-1))])
    add('runtime_subdomain', max(0, v-1), [(0, 0)])
    add('bad_literal_with_zero_vars', 0, [(1, 0)])
    add('bad_literal_tautology', 0, [(mask, mask)])
    bad_up = add('upstream_empty_clause', v, [(0, 0)], upstream=1)
    add('command_error_empty_cnf', v, [], upstream=1)
    for n, count in ((v+1, 0), (0xffffffff, 0), (0, c+1),
                     (0, 0xffffffff), (0xffffffff, 0xffffffff)):
        add(f'bad_counts_{n}_{count}', n, [], declared=count)
    add('bad_counts_and_upstream', 0xffffffff, [], declared=0xffffffff, upstream=1)
    missing = add('missing_last', v, [(mask, mask)]*c)
    cases[missing]['rows'][-1]['last'] = 0
    if c > 1:
        early = add('early_last', v, [(1, 0)], declared=c)
        mixed = add('literal_early_upstream', 0, [(1, 1)], declared=c, upstream=1)
        cases[mixed]['rows'][0]['error'] = 1
    mixed = add('literal_missing_upstream', 0, [(mask, mask)]*c)
    cases[mixed]['rows'][-1].update(last=0, error=1)
    rng = random.Random(0xC0F026 + v*101+c)
    for k in range(12):
        n = rng.randint(0, v)
        rows = []
        for _ in range(rng.randint(0, c)):
            p = q = 0
            for bit in range(n):
                choice = rng.randrange(5)
                if choice == 1: p |= 1 << bit
                if choice == 2: q |= 1 << bit
                if choice == 3: p |= 1 << bit; q |= 1 << bit
            rows.append((p, q))
        add(f'seeded_{k}', n, rows)
    if v >= 2 and c >= 2:
        if v >= 3:
            add('nested_restore_discards_false_child_units', v,
                [(7, 0), (3, 4)])
        blocking_vars = min(v, c.bit_length()-1, 6)
        blocking_mask = (1 << blocking_vars)-1
        if blocking_vars >= 2:
            # One clause falsified by each assignment; all are necessary.
            add('all_assignment_blockers', v,
                [(blocking_mask ^ x, x) for x in range(1 << blocking_vars)])
        # Random planted clauses have no empty/tautological fast path.
        planted = rng.randrange(1 << v)
        rows = []
        for _ in range(c):
            chosen = rng.sample(range(v), min(3, v))
            p = q = 0
            for bit in chosen:
                if rng.randrange(2): p |= 1 << bit
                else: q |= 1 << bit
            bit = chosen[0]
            if planted >> bit & 1: p |= 1 << bit; q &= ~(1 << bit)
            else: q |= 1 << bit; p &= ~(1 << bit)
            rows.append((p, q))
        add('planted_full_capacity', v, rows)
        add('reversed_clause_order', v, list(reversed(rows)))
        swapped = [(int(f'{p:0{v}b}'[::-1], 2), int(f'{q:0{v}b}'[::-1], 2))
                   for p, q in rows]
        add('reversed_variable_order', v, swapped)
    for i, case in enumerate(cases):
        case['id'] = i
        case['expect'] = expectation(case, v, c)
    targets = [dict(name='idle_offer', state=0, owner=empty),
               dict(name='load', state=1, owner=fresh),
               dict(name='scan_start', state=2, owner=fresh),
               dict(name='clause_read', state=3, owner=fresh),
               dict(name='clause_eval', state=4, owner=fresh),
               dict(name='scan_done', state=5, owner=tautology),
               dict(name='empty_stack_conflict', state=7, owner=conflict, condition=1),
               dict(name='held_sat', state=9, owner=unit),
               dict(name='held_error', state=9, owner=bad_up),
               dict(name='unit_before_assignment', state=4, owner=unit, condition=2),
               dict(name='tautology_before_eval', state=4, owner=tautology, condition=3)]
    excluded = []
    if branch is not None:
        targets.append(dict(name='decision_push', state=6, owner=branch))
    else:
        excluded.append('decision_push: V1 clauses cannot have two unassigned variables')
    if pop is not None:
        targets += [dict(name='pending_pop_read', state=7, owner=pop, condition=4),
                    dict(name='pending_restore', state=8, owner=pop)]
    else:
        excluded.append('nonempty pop/restore: V1 has no decisions')
    if nested is not None:
        targets.append(dict(name='nested_pending', state=2, owner=nested, condition=5))
    else:
        excluded.append('pending depth2: runtime variables <=2')
    return cases, targets, excluded, fresh


def main():
    target = ROOT/'TEST_PLAN.json'
    assert not target.exists(), 'frozen plan already exists'
    (ROOT/'fixtures').mkdir(exist_ok=True)
    plan = dict(version=1, primary_oracle='all-assignment truth-table bitsets',
                compiler_simulator_deadline_seconds=20, automatic_retry=False,
                profiles=[])
    for index, (v, c, t) in enumerate(PROFILES):
        cases, resets, excluded, fresh = corpus(v, c, t)
        lines = [str(len(cases))]
        for case in cases:
            e = case['expect']
            lines.append(f"{case['id']} {case['num_vars']:x} {case['num_clauses']:x} "
                         f"{case['command_error']} {case['tag']:x} {e['error']:x} "
                         f"{int(e['sat'])} {len(case['rows'])}")
            lines += [f"{r['positive']:x} {r['negative']:x} {r['last']} {r['error']}"
                      for r in case['rows']]
        reset_lines = [f'{len(resets)} {fresh}'] + [
            f"{x['state']} {x['owner']} {x.get('condition', 0)}" for x in resets]
        files = {f'fixtures/p{index}.txt': '\n'.join(lines)+'\n',
                 f'fixtures/p{index}_reset.txt': '\n'.join(reset_lines)+'\n',
                 f'fixtures/p{index}.json': json.dumps(dict(cases=cases, resets=resets,
                     excluded=excluded, fresh=fresh), indent=2)+'\n'}
        hashes = {}
        for name, content in files.items():
            path = ROOT/name
            assert not path.exists()
            raw = content.encode()
            path.write_bytes(raw)
            hashes[name] = hashlib.sha256(raw).hexdigest()
        plan['profiles'].append(dict(index=index, max_vars=v, max_clauses=c,
            tag_w=t, cases=len(cases), rows=sum(len(x['rows']) for x in cases),
            reset_groups=len(resets), excluded=excluded, sha256=hashes))
    target.write_text(json.dumps(plan, indent=2)+'\n', encoding='utf-8', newline='\n')
    print(json.dumps({'status':'PREPARED', 'profiles':len(plan['profiles']),
                      'cases':sum(x['cases'] for x in plan['profiles']),
                      'reset_groups':sum(x['reset_groups'] for x in plan['profiles'])}))


if __name__ == '__main__':
    main()
