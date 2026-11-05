"""Exact certificates for ten literal analytic TV targets; no solution search."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
NAMES = (
    'SINGLETON_MIN', 'ZERO_PENALTY_PAIR', 'FUSED_HALF_PAIR',
    'RETAINED_UP_JUMP', 'FRACTIONAL_THREE', 'FLAT_BINDING_EQUALITY',
    'OPPOSITE_JUMPS', 'DEFAULT_TWO_PLATEAUS', 'MAX_WIDTH_STEP',
    'MAX_LAMBDA_ALTERNATING',
)
PROFILE_CASES = {
    'p0': (1, 2, 1, ('SINGLETON_MIN',)),
    'p1': (2, 3, 2, ('ZERO_PENALTY_PAIR', 'FUSED_HALF_PAIR', 'RETAINED_UP_JUMP')),
    'p2': (3, 4, 3, ('FRACTIONAL_THREE',)),
    'p3': (4, 8, 8, ('FLAT_BINDING_EQUALITY', 'OPPOSITE_JUMPS')),
    'p4': (16, 16, 8, ('DEFAULT_TWO_PLATEAUS',)),
    'p5': (64, 24, 32, ('MAX_WIDTH_STEP', 'MAX_LAMBDA_ALTERNATING')),
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_fixed() -> tuple[list[dict], dict[str, dict]]:
    source = json.loads((ROOT/'fixtures/cases.json').read_bytes())
    assert source['schema'] == 'anscore-tv-fixed-analytic-cases-v1'
    cases = source['cases']
    assert tuple(c['name'] for c in cases) == NAMES
    assert len(source['profiles']) == 6
    profiles = {p['name']: p for p in source['profiles']}
    assert set(profiles) == set(PROFILE_CASES)
    for name, (n, width, tag_width, names) in PROFILE_CASES.items():
        p = profiles[name]
        assert (p['N'], p['DATA_W'], p['TAG_W'], tuple(p['cases'])) == (n, width, tag_width, names)
    assert all(c['name'] in profiles[c['profile']]['cases'] for c in cases)
    return cases, profiles


def expand_literal(case: dict, profile: dict) -> tuple[list[int], list[tuple[int, int]]]:
    """Expand only the finite blocks specifying this one named vector."""
    n = profile['N']
    x: list[int] = []
    targets: list[tuple[int, int]] = []
    for block in case['input_blocks']:
        values, repeat = block['values'], block['repeat']
        assert values and all(type(v) is int for v in values)
        assert type(repeat) is int and repeat > 0 and len(values)*repeat <= n
        x.extend(values*repeat)
    for block in case['target_blocks']:
        numerator, denominator, repeat = block['n'], block['d'], block['repeat']
        assert all(type(v) is int for v in (numerator, denominator, repeat))
        assert 1 <= denominator <= n and 1 <= repeat <= n
        targets.extend([(numerator, denominator)]*repeat)
    assert len(x) == len(targets) == n
    return x, targets


def certify(case: dict, profile: dict) -> dict:
    """Check a supplied analytic target by KKT, without the RTL recurrence."""
    n, width, tag_width = profile['N'], profile['DATA_W'], profile['TAG_W']
    x, targets = expand_literal(case, profile)
    penalty, tag = case['lambda'], case['tag']
    assert type(penalty) is int and 0 <= penalty < 1 << width
    assert type(tag) is int and 0 <= tag < 1 << tag_width
    assert all(-(1 << (width-1)) <= value < 1 << (width-1) for value in x)
    p = width + (n+3).bit_length()
    assert all(-(1 << (p-1)) <= a < 1 << (p-1) for a, _ in targets)
    y = [Fraction(a, d) for a, d in targets]
    q = [Fraction(0)]
    for observed, supplied in zip(y, x):
        q.append(q[-1] + observed - supplied)
    assert q[-1] == 0, (case['name'], 'sample sum')
    for k in range(1, n):
        assert abs(q[k]) <= penalty, (case['name'], 'dual bound', k)
        jump = y[k]-y[k-1]
        if jump:
            assert q[k] == (penalty if jump > 0 else -penalty), (case['name'], 'jump sign', k)
    if penalty == 0 or n == 1:
        assert all(a == value and d == 1 for value, (a, d) in zip(x, targets))
    gap_after, gap_cycles = case['gap_after'], case['gap_cycles']
    assert (gap_after == -1 and gap_cycles == 0) or (1 <= gap_after < n and 1 <= gap_cycles <= 8)
    assert len(case['stalls']) <= 2
    assert len({item[0] for item in case['stalls']}) == len(case['stalls'])
    assert all(0 <= index < n and 1 <= cycles <= 8 for index, cycles in case['stalls'])
    assert type(case['offer_future']) is bool
    if case['offer_future']:
        assert any(index == n-1 for index, _ in case['stalls'])
    return dict(name=case['name'], profile=case['profile'], x=x,
                targets=[list(pair) for pair in targets],
                q=[[v.numerator, v.denominator] for v in q],
                kkt_exact=True, unique_by_strict_convexity=True)


def certificate_bundle(cases: list[dict], profiles: dict[str, dict]) -> dict:
    return dict(schema='anscore-tv-fixed-kkt-certificates-v1',
                target_source='ten literal analytic cases; no algorithm or input search',
                cases=[certify(c, profiles[c['profile']]) for c in cases])


def fixture_text(profile: dict, cases: list[dict]) -> str:
    selected = [c for c in cases if c['name'] in profile['cases']]
    assert [c['name'] for c in selected] == profile['cases']
    lines = [f"TVFIX1 {profile['N']} {profile['DATA_W']} {profile['TAG_W']} {len(selected)}"]
    for case in selected:
        x, targets = expand_literal(case, profile)
        lines.append(f"CASE {case['name']} {case['lambda']} {case['tag']:08x} "
                     f"{case['gap_after']} {case['gap_cycles']} {len(case['stalls'])} {int(case['offer_future'])}")
        lines.extend(f'STALL {index} {cycles}' for index, cycles in case['stalls'])
        lines.extend(f'X {value}' for value in x)
        lines.extend(f'Y {a} {d}' for a, d in targets)
        lines.append('END')
    return '\n'.join(lines)+'\n'


def verify_stored() -> None:
    seal = json.loads((ROOT/'SOURCE_SEAL.json').read_bytes())
    assert seal['schema'] == 'anscore-tv-prepared-seal-v1'
    expected = seal['prepared_sha256']
    actual = {p.relative_to(ROOT).as_posix(): digest(p) for p in (ROOT/'prepared').rglob('*') if p.is_file()}
    assert actual == expected
    cases, profiles = load_fixed()
    bundle = certificate_bundle(cases, profiles)
    assert json.loads((ROOT/'prepared/CERTIFICATES.json').read_bytes()) == bundle
    for name, profile in profiles.items():
        assert (ROOT/'prepared'/f'{name}.txt').read_bytes() == fixture_text(profile, cases).encode('utf-8')
    # Canonical raw bytes also on Windows; print() would translate LF to CRLF.
    sys.stdout.buffer.write(b'PASS CERTIFICATES cases=10 profiles=6 KKT_EXACT_FIXED\n')
    sys.stdout.buffer.flush()


def main() -> int:
    if sys.flags.optimize:
        raise RuntimeError('optimized Python is forbidden for certificate gates')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-stored', action='store_true', required=True)
    parser.parse_args()
    verify_stored()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
