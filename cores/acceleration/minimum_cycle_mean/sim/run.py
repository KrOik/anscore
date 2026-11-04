#!/usr/bin/env python3
"""Frozen finite qualification; no synthesis, implicit retries or network use."""
import argparse
import collections
from fractions import Fraction
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]
PROFILES = [(1, 1, 1), (2, 3, 3), (3, 4, 5), (7, 8, 8), (8, 8, 8), (32, 16, 32)]
PUBLIC = ['.gitattributes', 'README.md', 'SOURCES.md', 'files.f',
          'rtl/minimum_cycle_mean.sv', 'example/cycle_mean8.sv',
          'sim/run.py', 'sim/tb_minimum_cycle_mean.sv']


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(obj):
    return (json.dumps(obj, sort_keys=True, indent=2) + '\n').encode('utf-8')


def widths(n, w):
    cw = n.bit_length()
    dw = w + (n - 1).bit_length() + 1
    return cw, dw, dw + 1


def negative_cycle(n, graph, q):
    """Independent scaled Bellman-Ford predicate plus predecessor certificate."""
    costs = [0] * n
    parent = [-1] * n
    changed = -1
    for _ in range(n):
        changed = -1
        for (u, v), weight in sorted(graph.items()):
            trial = costs[u] + weight * q.denominator - q.numerator
            if trial < costs[v]:
                costs[v], parent[v], changed = trial, u, v
        if changed < 0:
            return False, costs, []
    vertex = changed
    for _ in range(n):
        vertex = parent[vertex]
        assert vertex >= 0
    cycle = [vertex]
    node = parent[vertex]
    while node != vertex:
        assert node >= 0 and node not in cycle
        cycle.append(node)
        node = parent[node]
    cycle.reverse()
    return True, costs, cycle


def elementary_means(n, graph):
    """Small-graph secondary crosscheck, with each cycle's minimum ID first."""
    answers = []
    outgoing = collections.defaultdict(list)
    for (u, v), weight in graph.items():
        outgoing[u].append((v, weight))
    def visit(start, path, total):
        for v, weight in outgoing[path[-1]]:
            if v == start:
                answers.append(Fraction(total + weight, len(path)))
            elif v > start and v not in path:
                visit(start, path + [v], total + weight)
    for start in range(n):
        visit(start, [start], 0)
    return answers


def oracle(n, graph):
    # Kahn detects DAGs independently of the weighted solver.
    degree = [0] * n
    outgoing = [[] for _ in range(n)]
    for u, v in graph:
        degree[v] += 1
        outgoing[u].append(v)
    queue = collections.deque(i for i in range(n) if degree[i] == 0)
    visited = 0
    while queue:
        u = queue.popleft()
        visited += 1
        for v in outgoing[u]:
            degree[v] -= 1
            if degree[v] == 0:
                queue.append(v)
    if visited == n:
        if n <= 8:
            assert not elementary_means(n, graph)
        return None, {'potential': [], 'cycle': [], 'small_cycles': 0}
    lo, hi = Fraction(min(graph.values()) - 1), Fraction(max(graph.values()) + 1)
    while hi - lo >= Fraction(1, n * n):
        mid = (lo + hi) / 2
        if negative_cycle(n, graph, mid)[0]:
            hi = mid
        else:
            lo = mid
    # Distinct reduced fractions with denominator <=N are >=1/N^2 apart.
    possible = set()
    for den in range(1, n + 1):
        bottom = -((-lo.numerator * den) // lo.denominator)
        fraction = Fraction(bottom, den)
        if lo <= fraction < hi:
            possible.add(fraction)
    assert len(possible) == 1, (lo, hi, possible)
    mean = possible.pop()
    negative, potential, _ = negative_cycle(n, graph, mean)
    assert not negative
    assert all(weight * mean.denominator - mean.numerator + potential[u] - potential[v] >= 0
               for (u, v), weight in graph.items())
    negative, _, cycle = negative_cycle(n, graph, mean + Fraction(1, n * n + 1))
    assert negative and cycle
    cycle_sum = sum(graph[cycle[i], cycle[(i + 1) % len(cycle)]] for i in range(len(cycle)))
    assert Fraction(cycle_sum, len(cycle)) == mean
    small = elementary_means(n, graph) if n <= 8 else []
    if n <= 8:
        assert small and min(small) == mean
    return mean, {'potential': potential, 'cycle': cycle, 'small_cycles': len(small)}


def exact_rows(n, graph):
    # Secondary work/image certificate only. This is not the primary oracle.
    rows = [[0] * n]
    for _ in range(n):
        row = [None] * n
        for (u, v), weight in graph.items():
            previous = rows[-1][u]
            if previous is not None:
                trial = previous + weight
                if row[v] is None or trial < row[v]:
                    row[v] = trial
        rows.append(row)
    return rows


def cases(n, w):
    low, high = -(1 << (w - 1)), (1 << (w - 1)) - 1
    cases = []
    def add(kind, edges):
        cases.append((kind, dict(edges)))
    add('empty', {})
    add('minimum_self_loop', {(0, 0): low})
    add('maximum_self_loop', {(n - 1, n - 1): high})
    add('zero_self_loop', {(0, 0): 0})
    add('acyclic_signed_chain', {(i, i + 1): low if i % 2 == 0 else high for i in range(n - 1)})
    add('negative_fraction_ring', {(i, (i + 1) % n): -1 if i == n - 1 else 0 for i in range(n)})
    add('positive_ring', {(i, (i + 1) % n): high for i in range(n)})
    if n > 1:
        add('positive_fraction_ring', {(i, (i + 1) % n): 1 if i == n - 1 else 0 for i in range(n)})
    add('all_minimum_complete', {(u, v): low for u in range(n) for v in range(n)})
    add('all_maximum_complete', {(u, v): high for u in range(n) for v in range(n)})
    if n > 1:
        add('disconnected_cycles', {(0, 0): high, (n - 1, n - 1): low})
        add('transient_to_cycle', {**{(i, i + 1): low for i in range(n - 1)}, (n - 1, n - 1): high})
        add('cycle_to_transient', {**{(i, i + 1): high for i in range(n - 1)}, (0, 0): low})
        add('zero_two_cycle', {(0, 1): -1, (1, 0): 1 if high >= 1 else 0})
        add('tied_cycles', {(0, 0): -1, (n - 1, n - 1): -1})
    if n == 2:
        pairs = list(itertools.product(range(2), repeat=2))
        for selection in itertools.product([None, low, high], repeat=4):
            add('all_two_node_graphs', {p: weight for p, weight in zip(pairs, selection) if weight is not None})
    rng = random.Random(0xB190000 + n * 97 + w)
    count = 18 if n <= 8 else 4
    for index in range(count):
        graph = {}
        for u in range(n):
            for v in range(n):
                if rng.randrange(100) < (40 if n <= 8 else 7):
                    graph[u, v] = rng.randrange(low, high + 1)
        add('seeded', graph)
        if n <= 8 and index < 9:
            permutation = list(range(n))
            rng.shuffle(permutation)
            add('renumbered', {(permutation[u], permutation[v]): weight for (u, v), weight in graph.items()})
    return cases


def fixtures(n, w, t):
    mask = (1 << t) - 1
    frames = []
    def finish(kind, tokens):
        for i, token in enumerate(tokens):
            token.setdefault('first', int(i == 0))
            token.setdefault('last', int(i == len(tokens) - 1))
            token['tag'] = ((len(frames) * 17 + 3) if i == 0 else (i * 7 + 1)) & mask
        frames.append({'kind': kind, 'tokens': tokens})
    def token(u=0, v=0, weight=0, present=1, keep=1, **kwargs):
        return dict(u=u, v=v, weight=weight, present=present, keep=keep, **kwargs)
    for index, (kind, graph) in enumerate(cases(n, w)):
        tokens = []
        if index % 3 != 0 or not graph:
            tokens.append(token(0xffffffff, 0x80000000, keep=0))
        if graph:
            (u, v), value = next(iter(graph.items()))
            tokens.append(token(u, v, -(1 << (w - 1))))
            tokens.append(token(u, v, 0, present=0))
        for (u, v), value in sorted(graph.items()):
            tokens.append(token(u, v, value))
        absent = next(((u, v) for u in range(n) for v in range(n) if (u, v) not in graph), None)
        if absent is not None:
            u, v = absent
            tokens.extend([token(u, v, -1), token(u, v, 0, present=0)])
        if index % 2 == 0 or not tokens:
            tokens.append(token(0xffffffff, 0xffffffff, keep=0))
        finish(kind, tokens)
    finish('bad_from', [token(n, 0)])
    finish('bad_to_delete', [token(0, 0x80000000, present=0)])
    finish('bad_both_endpoints', [token(0xffffffff, 0xffffffff)])
    finish('missing_first', [token(keep=0, first=0)])
    finish('late_first', [token(keep=0), token(0, 0, -1, first=1)])
    finish('both_errors', [token(n, 0xffffffff, first=0)])
    finish('sticky_both_drain', [token(0, 0, -1), token(n, 0), token(keep=0, first=1)])
    finish('masked_bad_ids_ignored', [token(0xffffffff, 0xffffffff, keep=0)])
    cw, dw, nw = widths(n, w)
    packed, dp_words, reference = [], [], []
    totals = collections.Counter()
    for frame in frames:
        graph, error = {}, 0
        for index, beat in enumerate(frame['tokens']):
            if beat['first'] != int(index == 0):
                error |= 2
            if beat['keep']:
                if beat['u'] >= n or beat['v'] >= n:
                    error |= 1
                elif beat['present']:
                    graph[beat['u'], beat['v']] = beat['weight']
                else:
                    graph.pop((beat['u'], beat['v']), None)
            assert beat['last'] == int(index == len(frame['tokens']) - 1)
            fields = [(beat['u'], 32), (beat['v'], 32), (beat['weight'], w),
                      (beat['present'], 1), (beat['keep'], 1), (beat['first'], 1),
                      (beat['last'], 1), (beat['tag'], t)]
            value = 0
            for number, width in fields:
                value = (value << width) | (number & ((1 << width) - 1))
            packed.append(value)
        mean, certificate = (None, {}) if error else oracle(n, graph)
        rows = exact_rows(n, graph)
        for row in rows:
            for cost in row:
                dp_words.append(0 if cost is None else (1 << dw) | (cost & ((1 << dw) - 1)))
        reachable = [v for v in range(n) if rows[n][v] is not None]
        latency = 1 if error else n + n * n * (2 * n + 2) + 3 * n + 1
        if not error:
            for ordinal, v in enumerate(reachable):
                count = sum(rows[k][v] is not None for k in range(n))
                latency += 3 * n + count + 2 * cw * (count - 1) + 1 + 2 * cw * (ordinal > 0)
        record = {'kind': frame['kind'], 'error': error, 'tag': frame['tokens'][0]['tag'],
                  'mean': None if mean is None else [mean.numerator, mean.denominator],
                  'latency': latency, 'certificate': certificate, 'beats': len(frame['tokens'])}
        reference.append(record)
        totals['frames'] += 1
        totals['beats'] += len(frame['tokens'])
        totals['error_' + str(error)] += 1
        if not error:
            totals['dag' if mean is None else ('negative' if mean < 0 else 'positive' if mean > 0 else 'zero')] += 1
            totals['small_cycle_crosschecks'] += int(n <= 8)
            totals['enumerated_cycles'] += certificate['small_cycles']
            totals['optimality_certificates'] += int(mean is not None)
            totals['fractional_means'] += int(mean is not None and mean.denominator != 1)
    input_data = ''.join(f'{value:x}\n' for value in packed).encode()
    dp_data = ''.join(f'{value:x}\n' for value in dp_words).encode()
    frozen = {'NUM_NODES': n, 'WEIGHT_W': w, 'TAG_W': t, 'frames': len(frames),
              'beats': len(packed), 'input_sha256': sha(input_data), 'dp_sha256': sha(dp_data),
              'oracle_sha256': sha(encoded(reference)), 'coverage': dict(totals),
              'reset_probes': 28, 'fresh_recoveries': 28}
    return frozen, input_data, dp_data, reference


def validate_output(path, reference, n, w, t):
    cw, dw, nw = widths(n, w)
    lines = path.read_text(encoding='utf-8').splitlines()
    assert len(lines) == len(reference), (len(lines), len(reference))
    for line, expected in zip(lines, reference):
        word, latency = line.split()
        word = int(word, 16)
        tag = word & ((1 << t) - 1)
        word >>= t
        error = word & 3
        word >>= 2
        den = word & ((1 << cw) - 1)
        word >>= cw
        num = word & ((1 << nw) - 1)
        if num & (1 << (nw - 1)):
            num -= 1 << nw
        word >>= nw
        has_cycle = word & 1
        assert word >> 1 == 0
        assert (tag, error, int(latency)) == (expected['tag'], expected['error'], expected['latency'])
        if error or expected['mean'] is None:
            assert (has_cycle, num, den) == (0, 0, 0)
        else:
            assert has_cycle and 1 <= den <= n
            assert Fraction(num, den) == Fraction(*expected['mean']), (line, expected)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepare', action='store_true')
    args = parser.parse_args()
    generated = [fixtures(*profile) for profile in PROFILES]
    frozen = [item[0] for item in generated]
    history_path = 'history/qualification_001_receipt_parser.json'
    active_public = PUBLIC + ([history_path] if (ROOT / history_path).is_file() else [])
    source = {path: sha((ROOT / path).read_bytes()) for path in active_public}
    plan = {'schema': 1, 'bounded_finite_only': True, 'baseline_commit':
            '897cf84f5861f5fada3c1a5d64127e64cdb9af92', 'timeout_seconds': 20,
            'profiles': frozen, 'invalid_parameters': [
                {'NUM_NODES': 0}, {'NUM_NODES': 33}, {'WEIGHT_W': 0},
                {'WEIGHT_W': 17}, {'TAG_W': 0}, {'TAG_W': 33}],
            'matrix': 'core syntax, example syntax, six compile/sim pairs, six named parameter rejections',
            'source_sha256': source}
    if (ROOT / history_path).is_file():
        prior = json.loads((ROOT / history_path).read_text(encoding='utf-8'))
        plan['post_qualification_metadata_repair'] = {
            'executed_plan_sha256': prior['plan_sha256'],
            'executed_receipt_sha256': prior['receipt_sha256'],
            'reason': 'Select the unique PASS summary rather than the trailing Icarus finish-location line; rebind current documentation/parser/history hashes only. No HDL/oracle rerun or matrix/fixture/RTL/TB change.'}
    plan_path = ROOT / 'TEST_PLAN.json'
    if args.prepare:
        assert not plan_path.exists(), 'Do not overwrite a frozen plan'
        plan_path.write_bytes(encoded(plan))
        print(json.dumps({'prepared_before_first_HDL': True, 'profiles': frozen,
                          'plan_sha256': sha(plan_path.read_bytes())}))
        return
    assert json.loads(plan_path.read_text(encoding='utf-8')) == plan, 'Frozen source/matrix/fixture changed'
    report_path = ROOT / 'verification.json'
    assert not report_path.exists(), 'Existing receipt requires explicit preserved-history handling'
    suite = REPO / 'tools/oss-cad-suite/oss-cad-suite'
    compiler, simulator = suite / 'bin/iverilog.exe', suite / 'bin/vvp.exe'
    assert compiler.is_file() and simulator.is_file()
    env = os.environ.copy()
    env['PATH'] = str(suite / 'bin') + os.pathsep + str(suite / 'lib') + os.pathsep + env.get('PATH', '')
    records, profiles = [], []
    report = {'status': ['RTL_CANDIDATE', 'HW_UNVERIFIED'], 'bounded_finite_only': True,
              'test_plan_sha256': sha(plan_path.read_bytes()),
              'source_sha256': {**source, 'TEST_PLAN.json': sha(plan_path.read_bytes())},
              'frozen_inputs': frozen, 'commands': records, 'profiles': profiles,
              'timeout_occurred': False, 'remaining_profiles': [], 'prior_failed_attempts': []}
    def child(argv, label, reject=False):
        start = time.monotonic()
        item = {'label': label, 'argv': [str(x) for x in argv], 'timeout_seconds': 20}
        try:
            process = subprocess.run(item['argv'], cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, timeout=20)
            item.update(returncode=process.returncode, stdout=process.stdout.decode('utf-8', 'replace'),
                        stderr=process.stderr.decode('utf-8', 'replace'))
            okay = process.returncode != 0 and 'minimum_cycle_mean_invalid_parameters' in item['stderr'] if reject else process.returncode == 0
            item['status'] = 'PASS' if okay else 'FAIL'
        except subprocess.TimeoutExpired as error:
            item.update(returncode=None, status='TIMEOUT_NOT_RUN',
                        stdout=(error.stdout or b'').decode('utf-8', 'replace'),
                        stderr=(error.stderr or b'').decode('utf-8', 'replace'))
            report['timeout_occurred'] = True
        item['elapsed_seconds'] = round(time.monotonic() - start, 6)
        if reject:
            item['expected_failure'] = True
        records.append(item)
        if item['status'] != 'PASS':
            raise RuntimeError(label + ': ' + item['status'])
        return item
    with tempfile.TemporaryDirectory(prefix='anscore_b19_minimum_cycle_mean_') as directory:
        temp = Path(directory)
        try:
            rtl = ROOT / 'rtl/minimum_cycle_mean.sv'
            tb = ROOT / 'sim/tb_minimum_cycle_mean.sv'
            child([compiler, '-g2012', '-Wall', '-s', 'minimum_cycle_mean', '-tnull', rtl], 'core_syntax')
            child([compiler, '-g2012', '-Wall', '-s', 'cycle_mean8', '-tnull', rtl,
                   ROOT / 'example/cycle_mean8.sv'], 'example_syntax')
            for (n, w, t), (meta, inputs, dp, reference) in zip(PROFILES, generated):
                name = f'n{n}_w{w}_t{t}'
                executable, inp, dpfile, out = [temp / (name + suffix) for suffix in ('.vvp', '.mem', '_dp.mem', '.out')]
                inp.write_bytes(inputs)
                dpfile.write_bytes(dp)
                argv = [compiler, '-g2012', '-Wall', '-s', 'tb_minimum_cycle_mean',
                        '-Ptb_minimum_cycle_mean.N=' + str(n), '-Ptb_minimum_cycle_mean.W=' + str(w),
                        '-Ptb_minimum_cycle_mean.T=' + str(t), '-Ptb_minimum_cycle_mean.BEATS=' + str(meta['beats']),
                        '-Ptb_minimum_cycle_mean.FRAMES=' + str(meta['frames']), '-o', executable, rtl, tb]
                child(argv, name + '_compile')
                run = child([simulator, executable, '+INPUT=' + str(inp), '+DP=' + str(dpfile), '+OUTPUT=' + str(out)], name + '_sim')
                assert 'PASS minimum_cycle_mean ' in run['stdout'], run
                validate_output(out, reference, n, w, t)
                summaries = [line for line in run['stdout'].splitlines()
                             if line.startswith('PASS minimum_cycle_mean ')]
                assert len(summaries) == 1, run['stdout']
                summary = summaries[0]
                counts = {key: int(value, 16) if key == 'states' else int(value)
                          for key, value in (part.split('=', 1) for part in summary.split() if '=' in part)}
                profiles.append({'NUM_NODES': n, 'WEIGHT_W': w, 'TAG_W': t, 'status': 'PASS',
                                 'fixture': meta, 'observed': counts, 'output_sha256': sha(out.read_bytes())})
            for index, values in enumerate(plan['invalid_parameters']):
                argv = [compiler, '-g2012', '-s', 'minimum_cycle_mean', '-tnull']
                argv += [f'-Pminimum_cycle_mean.{key}={value}' for key, value in values.items()]
                child(argv + [rtl], 'invalid_' + str(index), reject=True)
            report['status'] = ['LINT_PASS', 'UNIT_SIM_PASS', 'HW_UNVERIFIED']
            report['matrix_status'] = 'PASS'
            report['invalid_parameter_rejections'] = 6
            totals = collections.Counter()
            for profile in profiles:
                for key, value in profile['observed'].items():
                    if key not in ('N', 'W', 'T', 'states', 'max_latency'):
                        totals[key] += value
            report['totals'] = dict(totals)
        except BaseException as error:
            report['matrix_status'] = 'TIMEOUT_NOT_RUN' if report['timeout_occurred'] else 'FAIL'
            report['failure'] = repr(error)
            report['remaining_profiles'] = [list(x) for x in PROFILES[len(profiles):]]
            archive = ROOT / 'history/qualification_001'
            archive.mkdir(parents=True, exist_ok=False)
            for path in active_public + ['TEST_PLAN.json']:
                target = archive / 'source' / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / path, target)
            shutil.copytree(temp, archive / 'artifacts')
            report_path.write_bytes(encoded(report))
            (archive / 'verification.json').write_bytes(encoded(report))
            raise
    report_path.write_bytes(encoded(report))
    print(json.dumps({'matrix_status': report['matrix_status'], 'profiles': len(profiles),
                      'commands': len(records), 'totals': report['totals'],
                      'verification_sha256': sha(report_path.read_bytes())}))


if __name__ == '__main__':
    main()
