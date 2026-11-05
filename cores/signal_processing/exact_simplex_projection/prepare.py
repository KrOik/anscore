"""One fixed, separately root-approved numeric preparation. Never invokes HDL."""
from pathlib import Path
import argparse
import hashlib
import json
import sys

sys.dont_write_bytecode = True
from oracle import certificate, small_support_crosscheck
from control_walk import TARGETS, N1_EXCLUDED, reset_witness, always_ready_bound

ROOT = Path(__file__).resolve().parent
PROFILES = [('p0', 1, 2, 1, 12), ('p1', 3, 3, 3, 32),
            ('p2', 16, 16, 8, 28), ('p3', 64, 24, 32, 28)]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n', encoding='utf-8', newline='\n')


def main_inputs(n, width):
    lo, hi, maximum = -(1 << (width-1)), (1 << (width-1))-1, (1 << width)-1
    if n == 1:
        yield from [
            ('min_zero', [-2], 0), ('min_unit', [-2], 1), ('min_max_mass', [-2], 3),
            ('negative_zero', [-1], 0), ('negative_two', [-1], 2), ('negative_max_mass', [-1], 3),
            ('zero_zero', [0], 0), ('zero_unit', [0], 1), ('zero_max_mass', [0], 3),
            ('max_zero', [1], 0), ('max_two', [1], 2), ('max_max_mass', [1], 3),
        ]
        return
    if n == 3:
        yield from [
            ('all_min_zero', [-4,-4,-4], 0), ('all_max_zero', [3,3,3], 0),
            ('all_zero_zero', [0,0,0], 0), ('all_min_unit', [-4,-4,-4], 1),
            ('all_min_max_mass', [-4,-4,-4], 7), ('all_max_unit', [3,3,3], 1),
            ('all_max_max_mass', [3,3,3], 7), ('all_zero_unit', [0,0,0], 1),
            ('all_zero_max_mass', [0,0,0], 7), ('negative_ramp_unit', [-3,-2,-1], 1),
            ('negative_ramp_max_mass', [-3,-2,-1], 7),
            ('single_first', [3,-4,-4], 1), ('single_middle', [-4,3,-4], 1),
            ('single_last', [-4,-4,3], 1), ('two_first_fraction', [3,3,-4], 1),
            ('two_outer_fraction', [3,-4,3], 1), ('two_last_fraction', [-4,3,3], 1),
            ('three_fraction', [3,3,3], 2),
            ('equality_multiround', [2,1,-2], 1), ('equality_reversed', [-2,1,2], 1),
            ('negative_equality', [-1,-2,-4], 1), ('negative_equality_reversed', [-4,-2,-1], 1),
            ('descending_unit', [3,2,1], 1), ('descending_mass_three', [3,2,1], 3),
            ('descending_max_mass', [3,2,1], 7), ('mixed_max_mass', [-4,0,3], 7),
            ('minimum_exact_zero_boundary', [-4,-4,3], 7),
            ('two_maxima_large_fraction', [-4,3,3], 7), ('signed_zero_mass', [1,0,-1], 0),
            ('signed_unit_equality', [1,0,-1], 1), ('signed_mass_two', [1,0,-1], 2),
            ('negative_large_mass_three_active', [-4,-3,-2], 7),
        ]
        return
    ramp = [i-n//2 for i in range(n)]
    rows = [
        ('zero_mass_min', [lo]*n, 0),
        ('zero_mass_max', [hi]*n, 0),
        ('equal_zero_unit_mass', [0]*n, 1),
        ('equal_zero_max_mass', [0]*n, maximum),
        ('equal_min_max_mass', [lo]*n, maximum),
        ('equal_max_max_mass', [hi]*n, maximum),
        ('all_negative_unit_mass', [-1]*n, 1),
        ('equal_positive_unit_mass', [1]*n, 1),
        ('single_first_survivor', [hi]+[lo]*(n-1), 1),
        ('single_last_survivor', [lo]*(n-1)+[hi], 1),
        ('one_low_max_mass', [lo]+[hi]*(n-1), maximum),
        ('alternating_extrema_unit', [lo if i%2 == 0 else hi for i in range(n)], 1),
        ('alternating_extrema_max', [hi if i%2 == 0 else lo for i in range(n)], maximum),
        ('ascending_small_ramp', ramp, 1),
        ('descending_small_ramp', list(reversed(ramp)), 1),
        ('strict_equality_multiround', [2, 1]+[-2]*(n-2), 1),
        ('negative_equality_multiround', [-1, -2]+[lo]*(n-2), 1),
        ('descending_near_max', [hi-i for i in range(n)], 1),
        ('zero_mass_ramp', ramp, 0),
        ('ramp_max_mass', ramp, maximum),
        ('three_level_repeated', [-7 if i%3 == 0 else 5 if i%3 == 1 else 0 for i in range(n)], 7),
        ('negative_equal_integer_mass', [-3]*n, n),
        ('two_equal_maxima_fraction', [hi, hi]+[lo]*(n-2), 1),
        ('three_equal_maxima_fraction', [hi]*3+[lo]*(n-3), 2),
        ('large_mass_single_high', [hi]+[lo+1]*(n-1), maximum),
        ('negative_alternating_large_mass', [-2 if i%2 else -1 for i in range(n)], maximum),
        ('sparse_negative_large_mass', [0 if i%5 == 0 else lo for i in range(n)], maximum-1),
        ('fixed_asymmetric_pattern', [(17*i) % (1 << width)+lo for i in range(n)], 57),
    ]
    assert len(rows) == 28
    yield from rows


def certify(values, mass, tag, width):
    assert all(-(1 << (width-1)) <= x < (1 << (width-1)) for x in values)
    assert 0 <= mass < (1 << width)
    result = certificate(values, mass, tag)
    if len(values) <= 3:
        small_support_crosscheck(result)
    assert all(0 <= x < (1 << (width+(len(values)-1).bit_length())) for x in result['numerators'])
    return result


def command_lines(c):
    lines = [f"{c['mass']:x} {c['tag']:x} {c['denominator']}"]
    lines += [f'{x} {num:x}' for x, num in zip(c['values'], c['numerators'], strict=True)]
    return lines


def prepare(approved):
    preparation = ROOT/'PREPARATION_PLAN.json'
    assert approved == sha(preparation), 'exact root-approved preparation plan required'
    spec = json.loads(preparation.read_bytes())
    assert spec['stage'] == 'PREPARATION_ONLY_BEFORE_ANY_ORACLE_OR_HDL_EXECUTION'
    assert all(sha(ROOT/path) == digest for path, digest in spec['source_sha256'].items())
    assert not any((ROOT/path).exists() for path in ['fixtures', 'PREPARED.json', 'SOURCE_FREEZE.json', 'verification.json'])
    plan = json.loads((ROOT/'TEST_PLAN.json').read_bytes())
    assert plan['profiles'] == [dict(name=p, n=n, data_w=w, tag_w=t, main_count=c,
                                     reset_count=11 if n == 1 else 18) for p, n, w, t, c in PROFILES]
    assert len(plan['children']) == 23 and spec['timeout_seconds'] == 20
    (ROOT/'fixtures').mkdir()
    profiles = []
    for name, n, width, tag_width, expected_count in PROFILES:
        tag_mask = (1 << tag_width)-1
        cases = []
        for i, (label, values, mass) in enumerate(main_inputs(n, width)):
            tag = (i if i%2 == 0 else ~i) & tag_mask
            c = certify(values, mass, tag, width)
            c['label'] = label
            cases.append(c)
        assert len(cases) == expected_count
        assert len({c['label'] for c in cases}) == expected_count
        assert {c['mass'] for c in cases} >= {0, 1, (1 << width)-1}
        if n > 1:
            assert {c['denominator'] for c in cases if c['mass'] > 0} >= {1, 2, 3}
            assert any(any(num % c['denominator'] for num in c['numerators']) for c in cases)
        probes = []
        for target, label in enumerate(TARGETS):
            if n == 1 and target in N1_EXCLUDED:
                continue
            # Fixed analytical witness, never a candidate search or DUT-dependent choice.
            values = [-(1 << (width-1))] if n == 1 else [2, 1]+[-2]*(n-2)
            mass = 0 if target == 1 else 1
            tag = (target*13+1) & tag_mask
            owner = certify(values, mass, tag, width)
            fresh = certify([0]*n, (1 << width)-1, tag ^ tag_mask, width)
            assert fresh['values'] != owner['values'] and fresh['tag'] != owner['tag']
            witness = reset_witness(target, values, mass, owner)
            probes.append(dict(id=target, label=label, owner=owner, fresh=fresh,
                               predicate=witness, actual_next_offer=target == 17))
        assert len(probes) == (11 if n == 1 else 18)
        base = dict(n=n, data_w=width, tag_w=tag_width, name=name,
                    always_ready_bound=always_ready_bound(n), cases=cases, probes=probes,
                    excluded=N1_EXCLUDED if n == 1 else [])
        lines = [f'{len(cases)} {n} {width} {tag_width}']
        for c in cases:
            lines.extend(command_lines(c))
        main_file = ROOT/f'fixtures/{name}_main.txt'
        main_file.write_text('\n'.join(lines)+'\n', encoding='ascii', newline='\n')
        lines = [f'{len(probes)} {n} {width} {tag_width}']
        for p in probes:
            e = p['predicate']
            lines.append(f"{p['id']} {int(p['actual_next_offer'])}")
            lines.append(' '.join(str(e.get(key, 0)) for key in ['mask', 'state', 'index', 'prefix', 'k', 'round', 'kept']))
            lines.append(' '.join(str(e.get(key, 0)) for key in ['acc', 'threshold', 'read', 'product'])+f" {e.get('active', 0):x}")
            lines.extend(command_lines(p['owner']))
            lines.extend(command_lines(p['fresh']))
        reset_file = ROOT/f'fixtures/{name}_reset.txt'
        reset_file.write_text('\n'.join(lines)+'\n', encoding='ascii', newline='\n')
        cert_file = ROOT/f'fixtures/{name}.json'
        write_json(cert_file, base)
        profiles.append(dict(name=name, main_count=len(cases), reset_count=len(probes),
                             main_outputs=len(cases)*n,
                             owner_prefix_outputs=sum(p['predicate']['prefix'] for p in probes),
                             fresh_outputs=len(probes)*n,
                             files_sha256={p.relative_to(ROOT).as_posix(): sha(p) for p in [main_file, reset_file, cert_file]}))
    totals = dict(main_frames=sum(p['main_count'] for p in profiles),
                  main_replays=2*sum(p['main_count'] for p in profiles),
                  main_outputs=2*sum(p['main_outputs'] for p in profiles),
                  resets=sum(p['reset_count'] for p in profiles),
                  owner_prefix_outputs=sum(p['owner_prefix_outputs'] for p in profiles),
                  fresh_outputs=sum(p['fresh_outputs'] for p in profiles), hdl_children=23)
    assert totals == plan['totals'], (totals, plan['totals'])
    write_json(ROOT/'PREPARED.json', dict(schema=1, preparation_plan_sha256=approved,
               test_plan_sha256=sha(ROOT/'TEST_PLAN.json'), profiles=profiles, totals=totals,
               hdl_executed=0, no_adaptive_splits=True))
    print(json.dumps(totals, sort_keys=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-plan', required=True)
    prepare(parser.parse_args().approved_plan)
