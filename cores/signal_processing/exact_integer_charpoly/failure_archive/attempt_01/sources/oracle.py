#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent exact principal-minor and Fraction/Newton fixture oracles.

No SymPy import, no Berkowitz recurrence, no HDL execution.
"""
from fractions import Fraction
from functools import lru_cache
from hashlib import sha256
from itertools import combinations, permutations
from math import factorial
from pathlib import Path
import argparse
import json


def matrix(rows):
    a = tuple(tuple(int(x) for x in row) for row in rows)
    assert a and all(len(row) == len(a) for row in a)
    return a


@lru_cache(None)
def signed_permutations(n):
    return tuple((p, -1 if sum(p[i] > p[j] for i in range(n)
                              for j in range(i + 1, n)) % 2 else 1)
                 for p in permutations(range(n)))


def determinant(a):
    n = len(a)
    answer = 0
    for order, sign in signed_permutations(n):
        term = sign
        for i, j in enumerate(order):
            term *= a[i][j]
            if not term:
                break
        answer += term
    return answer


@lru_cache(None)
def principal_coefficients(a):
    n = len(a)
    coefficients = [1]
    for k in range(1, n + 1):
        total = 0
        for subset in combinations(range(n), k):
            minor = tuple(tuple(a[i][j] for j in subset) for i in subset)
            total += determinant(minor)
        coefficients.append((-1 if k % 2 else 1) * total)
    return tuple(coefficients)


def identity(n):
    return tuple(tuple(int(i == j) for j in range(n)) for i in range(n))


def matmul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(len(b)))
                       for j in range(len(b[0]))) for i in range(len(a)))


def power(a, exponent):
    """Independent full-matrix binary exponentiation, not vector ping-pong."""
    result = identity(len(a))
    base = a
    while exponent:
        if exponent & 1:
            result = matmul(result, base)
        exponent >>= 1
        if exponent:
            base = matmul(base, base)
    return result


@lru_cache(None)
def certificates(a):
    n = len(a)
    coefficients = principal_coefficients(a)
    powers = [power(a, k) for k in range(n + 1)]
    traces = [sum(p[i][i] for i in range(n)) for p in powers]
    newton = [Fraction(1)]
    for k in range(1, n + 1):
        newton.append(-sum(newton[j] * traces[k - j] for j in range(k)) / k)
        assert newton[-1].denominator == 1
    assert tuple(int(x) for x in newton) == coefficients
    ch = [[sum(coefficients[k] * powers[n-k][i][j] for k in range(n+1))
           for j in range(n)] for i in range(n)]
    assert all(x == 0 for row in ch for x in row)
    assert coefficients[1] == -traces[1]
    assert coefficients[-1] == (-1 if n % 2 else 1) * determinant(a)
    stages = []
    for m in range(1, n + 1):
        start = n-m
        trailing = tuple(tuple(a[i][j] for j in range(start, n))
                         for i in range(start, n))
        q = principal_coefficients(trailing)
        g = [1, -trailing[0][0]]
        vectors = []
        if m > 1:
            b = tuple(tuple(row[j] for j in range(1,m)) for row in trailing[1:])
            c = tuple((row[0],) for row in trailing[1:])
            r = trailing[0][1:]
            for exponent in range(m-1):
                v = tuple(row[0] for row in matmul(power(b, exponent), c))
                vectors.append(v)
                g.append(-sum(x*y for x,y in zip(r,v)))
        stages.append(dict(m=m, coefficients=q, g=g, vectors=vectors))
    terms = sum(factorial(n)//factorial(n-k) for k in range(n+1))
    return dict(coefficients=coefficients, newton=tuple(int(x) for x in newton),
                traces=traces, cayley_hamilton=ch, stages=stages,
                principal_permutation_terms=terms)


def verify_plan(path):
    root = path.resolve().parent
    plan = json.loads(path.read_text(encoding='utf-8'))
    assert plan['frozen_before_rtl'] and plan['timeout_seconds'] == 20
    verified = 0
    for profile in plan['profiles']:
        for group in profile['main'] + profile['resets']:
            for key in ('json', 'text'):
                p = root/group[key]
                assert sha256(p.read_bytes()).hexdigest() == group[key+'_sha256']
            fixture = json.loads((root/group['json']).read_text())
            cases = fixture['frames'] if fixture['kind'] == 'main' else [fixture['owner'],fixture['fresh']]
            for case in cases:
                if case['complete'] and not case['errors']:
                    a = matrix(case['matrix'])
                    assert json.loads(json.dumps(certificates(a))) == case['certificate']
                    verified += 1
    assert sha256((root/'prepare.py').read_bytes()).hexdigest() == plan['preparation_sha256']
    assert sha256(Path(__file__).read_bytes()).hexdigest() == plan['oracle_sha256']
    print('PASS fixture_oracles cases='+str(verified)+' fixtures='+str(plan['totals']['fixtures']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify-plan', type=Path, required=True)
    verify_plan(parser.parse_args().verify_plan)
