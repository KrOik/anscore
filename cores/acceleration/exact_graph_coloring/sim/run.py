#!/usr/bin/env python3
"""Freeze and execute one finite matrix, with independent colouring oracles."""
import argparse
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]
PROFILES = [(1, 1), (2, 3), (4, 5), (6, 8), (8, 8), (10, 32)]
REJECTS = [('NUM_NODES', 0), ('NUM_NODES', 11), ('TAG_W', 0), ('TAG_W', 33)]
PUBLIC = ['.gitattributes', 'README.md', 'SOURCES.md', 'files.f',
          'rtl/exact_graph_coloring.sv', 'example/conflict_slots8.sv',
          'sim/run.py', 'sim/tb_exact_graph_coloring.sv']


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode('utf-8')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def assignment_oracle(n, edges):
    """Direct vertex assignment with colour-name symmetry, no subset DP."""
    order = sorted(range(n), key=lambda u: (-sum(u in e for e in edges), u))
    neighbors = [{v for v in range(n) if tuple(sorted((u, v))) in edges} for u in range(n)]
    colors = [-1] * n
    visits = 0
    def possible(index, used, cap):
        nonlocal visits
        visits += 1
        if index == n:
            return True
        u = order[index]
        forbidden = {colors[v] for v in neighbors[u] if colors[v] >= 0}
        for c in range(min(used + 1, cap)):
            if c not in forbidden:
                colors[u] = c
                if possible(index + 1, max(used, c + 1), cap):
                    return True
                colors[u] = -1
        return False
    for cap in range(1, n + 1):
        colors[:] = [-1] * n
        if possible(0, 0, cap):
            assert all(colors[u] != colors[v] for u, v in edges)
            return cap, visits
    raise AssertionError('N colours must always suffice for a simple graph')


def chromatic_count(n, edges, k):
    """Independent edge-subset inclusion/exclusion, used only through N4."""
    pairs = sorted(edges)
    count = 0
    for mask in range(1 << len(pairs)):
        parent = list(range(n))
        def find(u):
            while parent[u] != u:
                u = parent[u]
            return u
        for i, (u, v) in enumerate(pairs):
            if mask >> i & 1:
                parent[find(u)] = find(v)
        components = len({find(u) for u in range(n)})
        count += (-1 if mask.bit_count() % 2 else 1) * k ** components
    return count


def table_certificate(n, edges):
    """Secondary complete memory/tie/operation certificate, not primary oracle."""
    cw = n.bit_length()
    rows = [sum(1 << v for v in range(n) if tuple(sorted((u, v))) in edges) for u in range(n)]
    independent = [True] + [False] * ((1 << n) - 1)
    counts = [0] * (1 << n)
    choices = [0] * (1 << n)
    candidates = reads = 0
    for subset in range(1, 1 << n):
        predecessor = subset & (subset - 1)
        anchor = subset ^ predecessor
        vertex = anchor.bit_length() - 1
        independent[subset] = independent[predecessor] and not (rows[vertex] & predecessor)
        if independent[subset]:
            counts[subset], choices[subset] = 1, subset
        else:
            best = n
            part = (subset - 1) & subset
            while part:
                candidates += 1
                if part & anchor and independent[part]:
                    reads += 1
                    trial = 1 + counts[subset ^ part]
                    if not choices[subset] or trial < best:
                        best, choices[subset] = trial, part
                part = (part - 1) & subset
            counts[subset] = best
    colors = 0
    remaining, color = (1 << n) - 1, 0
    while remaining:
        chosen = choices[remaining]
        assert chosen and chosen & remaining == chosen and independent[chosen]
        for u in range(n):
            if chosen >> u & 1:
                colors |= color << (u * cw)
        remaining ^= chosen
        color += 1
    words = [(int(independent[s]) << (n + cw)) | (counts[s] << n) | choices[s] for s in range(1 << n)]
    return {'rows': rows, 'words': words, 'count': counts[-1], 'colors': colors,
            'subsets': (1 << n) - 1, 'candidates': candidates, 'dp_reads': reads, 'back_reads': color}


def fixtures(n, t):
    rng = random.Random(0xB200C0 + 37 * n + t)
    pairs = list(itertools.combinations(range(n), 2))
    cases = []
    def add(edges, kind, updates=False, edge_tail=False):
        edges = set(edges)
        tokens = [[0xffffffff, 0x80000000, 1, 0, 1, 0, rng.getrandbits(t)]]
        order = pairs[:]
        rng.shuffle(order)
        for a, b in order:
            if updates:
                tokens.extend([[b, a, int((a, b) not in edges), 1, 0, 0, rng.getrandbits(t)],
                               [a, b, int((a, b) in edges), 1, 0, 0, rng.getrandbits(t)]])
            elif (a, b) in edges:
                tokens.append([b, a, 1, 1, 0, 0, rng.getrandbits(t)])
        tokens.append([n - 1, n - 1, 1, 1, 0, 0, rng.getrandbits(t)])
        if edge_tail and pairs:
            a, b = pairs[0]
            tokens.append([a, b, int((a, b) in edges), 1, 0, 1, rng.getrandbits(t)])
        else:
            tokens.append([0x80000000, 0xffffffff, 0, 0, 0, 1, rng.getrandbits(t)])
        cases.append({'kind': kind, 'tokens': tokens})
    add([], 'empty')
    add(pairs, 'complete', edge_tail=True)
    add(((i, i + 1) for i in range(n - 1)), 'path', updates=True)
    add(((0, i) for i in range(1, n)), 'star')
    add(((a, b) for a, b in pairs if a % 2 != b % 2), 'bipartite', edge_tail=True)
    add(((a, b) for a, b in pairs if a // 3 == b // 3), 'disjoint_cliques', updates=True)
    if n >= 3:
        add((tuple(sorted((i, (i + 1) % n))) for i in range(n)), 'cycle')
    if n >= 5:
        add([(0, 1), (1, 2), (2, 3), (3, 4), (0, 4)], 'odd_cycle_clique_gap')
    if n >= 6:
        add([(0, i) for i in range(1, 6)] + [(1, 2), (2, 3), (3, 4), (4, 5), (1, 5)], 'odd_wheel')
        add(((a, b) for a, b in pairs if a % 2 != b % 2 and a // 2 != b // 2), 'crown')
    for probability in [0.25, 0.65]:
        repeat_count = 1 if n == 10 else 3
        for repeat in range(repeat_count):
            graph = {p for p in pairs if rng.random() < probability}
            add(graph, 'seeded', updates=repeat == 1, edge_tail=repeat == 0)
            permutation = list(range(n))
            rng.shuffle(permutation)
            add((tuple(sorted((permutation[a], permutation[b]))) for a, b in graph), 'renumbered')
    if n <= 4:
        for image in range(1 << len(pairs)):
            add((p for i, p in enumerate(pairs) if image >> i & 1), 'all_small_graphs')
    error_tokens = [
        [[0, 0, 0, 0, 0, 1, 1]],
        [[0, 0, 0, 0, 1, 0, 1], [0, 0, 0, 0, 1, 1, 0]],
        [[n, 0, 1, 1, 1, 1, 1]],
        [[0xffffffff, 0x80000000, 1, 1, 1, 1, 0]],
        [[n, n, 1, 1, 0, 1, 1]],
        [[0xffffffff, 0, 1, 1, 1, 0, 1], [0, 0, 0, 0, 1, 0, 0], [0, 0, 1, 1, 0, 1, 0]],
    ]
    cases.extend({'kind': 'error', 'tokens': ts} for ts in error_tokens)
    data = []
    coverage = Counter()
    for case in cases:
        edges = set()
        error = 0
        for i, (u, v, present, keep, first, last, tag) in enumerate(case['tokens']):
            error |= int(keep and (u >= n or v >= n)) | (int(first != (i == 0)) << 1)
            if not error and keep and u != v:
                pair = tuple(sorted((u, v)))
                if present:
                    edges.add(pair)
                else:
                    edges.discard(pair)
            value = ((((((u << 32) | v) << 1 | present) << 1 | keep) << 1 | first) << 1 | last) << t | tag
            data.append(f'{value:0{(68+t+3)//4}x}')
        expected = {'error': error, 'tag': case['tokens'][0][-1], 'edges': sorted(edges)}
        if error:
            expected.update(count=0, colors=0, latency=1, subsets=0, candidates=0, dp_reads=0, back_reads=0)
        else:
            optimum, visits = assignment_oracle(n, edges)
            expected.update(table_certificate(n, edges))
            assert expected['count'] == optimum
            expected['oracle_assignment_visits'] = visits
            if n <= 4:
                assert chromatic_count(n, edges, optimum) > 0
                assert chromatic_count(n, edges, optimum - 1) == 0
                coverage['inclusion_exclusion_crosschecks'] += 1
            tail = case['tokens'][-1]
            real_tail = tail[3] and tail[0] != tail[1]
            expected['latency'] = 2 + 4 * expected['subsets'] + 2 * expected['candidates'] + 2 * expected['dp_reads'] + 2 * optimum + 4 * real_tail
            assert expected['latency'] <= 4 * 3**n + 2*n + 2
            coverage['assignment_visits'] += visits
            coverage['count_' + str(optimum)] += 1
        case['expected'] = expected
        coverage[case['kind']] += 1
        coverage['error_' + str(error)] += 1
    return cases, ('\n'.join(data) + '\n').encode('ascii'), dict(coverage)


def make_plan():
    profiles = []
    for n, t in PROFILES:
        cases, data, coverage = fixtures(n, t)
        profiles.append({'NUM_NODES': n, 'TAG_W': t, 'frames': len(cases),
                         'beats': sum(len(c['tokens']) for c in cases), 'input_sha256': sha(data),
                         'coverage': coverage, 'immediate_resets_and_full_fresh_frames': 22,
                         'oracle_sha256': sha(encoded([c['expected'] for c in cases]))})
    return {'schema': 1, 'baseline_commit': 'ff2aadf8ebdc8e5475b7022cd68d47e496b9f593',
            'bounded_finite_only': True, 'child_timeout_seconds': 20, 'profiles': profiles,
            'rejections': [list(r) for r in REJECTS], 'planned_child_records': 25,
            'commands': ['version', 'top syntax', 'example syntax'] +
                        [f'N{n}/T{t}: {mode}' for n, t in PROFILES for mode in ['compile TB', 'main simulation', 'reset simulation']] +
                        [f'reject {p}={v}' for p, v in REJECTS],
            'source_sha256': {p: sha((ROOT/p).read_bytes()) for p in PUBLIC}}


def verify_outputs(cases, output, trace, n):
    lines = output.splitlines()
    assert len(lines) == len(cases)
    cw = n.bit_length()
    totals = Counter()
    for frame, (line, case) in enumerate(zip(lines, cases)):
        fields = line.split()
        assert fields[0] == 'R' and int(fields[1]) == frame
        actual = dict(zip(['error', 'tag', 'count', 'colors', 'latency', 'subsets', 'candidates', 'dp_reads', 'back_reads'],
                          [int(v, 16 if i in (1, 3) else 10) for i, v in enumerate(fields[2:])]))
        expected = case['expected']
        for key, value in actual.items():
            assert value == expected[key], (frame, case['kind'], key, value, expected[key])
        totals['latency_checks'] += 1
        if not actual['error']:
            colors = [(actual['colors'] >> (u*cw)) & ((1<<cw)-1) for u in range(n)]
            assert set(colors) == set(range(actual['count']))
            assert all(colors[u] != colors[v] for u, v in expected['edges'])
            totals['proper_edge_checks'] += len(expected['edges'])
            totals['witness_vertex_checks'] += n
            for key in ['subsets', 'candidates', 'dp_reads', 'back_reads']:
                totals[key] += actual[key]
    counts = Counter()
    for line in trace.splitlines():
        kind, frame_s, index_s, value_s = line.split()
        frame, index, value = int(frame_s), int(index_s), int(value_s, 16)
        expected = cases[frame]['expected']
        assert not expected['error']
        assert index == counts[kind, frame]
        values = expected['rows' if kind == 'A' else 'words']
        assert value == values[index], (kind, frame, index, value, values[index])
        counts[kind, frame] += 1
        totals['adjacency_row_checks' if kind == 'A' else 'complete_dp_word_checks'] += 1
    for frame, case in enumerate(cases):
        assert counts['A', frame] == (0 if case['expected']['error'] else n)
        assert counts['D', frame] == (0 if case['expected']['error'] else 1 << n)
    return dict(totals)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--freeze', action='store_true')
    args = parser.parse_args()
    plan = make_plan()
    plan_path, receipt = ROOT/'TEST_PLAN.json', ROOT/'verification.json'
    if args.freeze:
        assert not plan_path.exists() and not receipt.exists(), 'refuse to overwrite qualification'
        plan_path.write_bytes(encoded(plan))
        print(json.dumps({'frozen_plan_sha256': sha(plan_path.read_bytes()), 'children': 25}))
        return
    assert plan_path.read_bytes() == encoded(plan), 'frozen plan/source/fixture mismatch'
    assert not receipt.exists(), 'never overwrite or automatically retry a receipt'
    suite = REPO/'tools/oss-cad-suite/oss-cad-suite'
    iv, vv = str(suite/'bin/iverilog.exe'), str(suite/'bin/vvp.exe')
    assert Path(iv).is_file() and Path(vv).is_file()
    env = os.environ.copy()
    env['PATH'] = os.pathsep.join([str(suite/'bin'), str(suite/'lib'), env.get('PATH', '')])
    report = {'schema': 1, 'bounded_finite_only': True, 'status': ['RTL_CANDIDATE', 'HW_UNVERIFIED'],
              'matrix_status': 'NOT_RUN', 'source_sha256': plan['source_sha256'],
              'test_plan_sha256': sha(plan_path.read_bytes()), 'timeout_occurred': False,
              'commands': [], 'profiles': [], 'prior_failed_attempts': [], 'invalid_parameter_rejections': 0}
    def child(command, reject=False):
        start = time.monotonic()
        try:
            result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                    text=True, encoding='utf-8', errors='replace', timeout=20)
            passed = (result.returncode > 0 and 'exact_graph_coloring_invalid_parameters__see_README' in result.stderr) if reject else result.returncode == 0
            report['commands'].append({'argv': command, 'returncode': result.returncode,
                                       'stdout': result.stdout, 'stderr': result.stderr,
                                       'elapsed_seconds': round(time.monotonic()-start, 6),
                                       'timeout_seconds': 20, 'expected_rejection': reject,
                                       'status': 'PASS' if passed else 'FAIL'})
            assert passed, result.stdout + result.stderr
            return result.stdout
        except subprocess.TimeoutExpired as error:
            report['commands'].append({'argv': command, 'returncode': None,
                                       'stdout': (error.stdout or b'').decode('utf-8', 'replace') if isinstance(error.stdout, bytes) else error.stdout or '',
                                       'stderr': (error.stderr or b'').decode('utf-8', 'replace') if isinstance(error.stderr, bytes) else error.stderr or '',
                                       'elapsed_seconds': round(time.monotonic()-start, 6),
                                       'timeout_seconds': 20, 'status': 'TIMEOUT'})
            report['timeout_occurred'] = True
            raise
    try:
        child([iv, '-V'])
        child([iv, '-g2012', '-Wall', '-tnull', '-s', 'exact_graph_coloring', '-f', 'files.f'])
        child([iv, '-g2012', '-Wall', '-tnull', '-s', 'conflict_slots8', '-f', 'files.f', 'example/conflict_slots8.sv'])
        report['status'] = ['LINT_PASS', 'HW_UNVERIFIED']
        for n, t in PROFILES:
            cases, data, coverage = fixtures(n, t)
            profile = {'NUM_NODES': n, 'TAG_W': t, 'input_sha256': sha(data), 'coverage': coverage}
            with tempfile.TemporaryDirectory(prefix='anscore_b20_coloring_') as temporary:
                directory = Path(temporary)
                inp, out, trace, exe = [directory/name for name in ['input.hex', 'output.txt', 'trace.txt', 'unit.vvp']]
                inp.write_bytes(data)
                child([iv, '-g2012', '-Wall', '-s', 'tb_exact_graph_coloring',
                       f'-Ptb_exact_graph_coloring.N={n}', f'-Ptb_exact_graph_coloring.T={t}',
                       f'-Ptb_exact_graph_coloring.BEATS={sum(len(c["tokens"]) for c in cases)}',
                       f'-Ptb_exact_graph_coloring.FRAMES={len(cases)}', '-o', str(exe), '-f', 'files.f', 'sim/tb_exact_graph_coloring.sv'])
                for mode, label in [(0, 'main'), (1, 'reset')]:
                    stdout = child([vv, str(exe), f'+MODE={mode}', '+INPUT='+inp.as_posix(), '+OUTPUT='+out.as_posix(), '+TRACE='+trace.as_posix()])
                    markers = re.findall(r'^PASS exact_graph_coloring mode='+label+r' (.+)$', stdout, re.M)
                    assert len(markers) == 1, stdout
                    observed = {k: int(v, 16 if k == 'states' else 10) for k, v in re.findall(r'(\w+)=([0-9a-f]+)', markers[0])}
                    profile.update(observed)
                    if mode == 0:
                        assert observed['frames'] == len(cases)
                        assert observed['beats'] == sum(len(c['tokens']) for c in cases)
                        assert observed['blocked'] == observed['source_holds'] and observed['blocked'] > 0
                        assert observed['queued'] > 0
                        profile.update(verify_outputs(cases, out.read_text(encoding='utf-8'), trace.read_text(encoding='utf-8'), n))
                        profile['actual_sha256'], profile['trace_sha256'] = sha(out.read_bytes()), sha(trace.read_bytes())
                        profile['maximum_first_valid_latency'] = max(c['expected']['latency'] for c in cases)
                    else:
                        assert observed['resets'] == observed['fresh'] == 22
                        reachable = set(range(19)) - ({2, 3, 4, 5, 10, 11, 12, 13} if n == 1 else set())
                        assert observed['states'] == sum(1 << s for s in reachable)
                profile['status'] = 'PASS'
                report['profiles'].append(profile)
        for parameter, value in REJECTS:
            child([iv, '-g2012', '-tnull', '-s', 'exact_graph_coloring', f'-Pexact_graph_coloring.{parameter}={value}', '-f', 'files.f'], True)
            report['invalid_parameter_rejections'] += 1
        keys = ['frames', 'beats', 'blocked', 'source_holds', 'queued', 'held', 'resets', 'fresh', 'latency_checks',
                'proper_edge_checks', 'witness_vertex_checks', 'subsets', 'candidates', 'dp_reads',
                'back_reads', 'adjacency_row_checks', 'complete_dp_word_checks']
        report['totals'] = {key: sum(p[key] for p in report['profiles']) for key in keys}
        report['status'] = ['LINT_PASS', 'UNIT_SIM_PASS', 'HW_UNVERIFIED']
        report['matrix_status'] = 'PASS'
        assert len(report['commands']) == 25
    except Exception as error:
        report['matrix_status'] = 'TIMEOUT_NOT_RUN' if report['timeout_occurred'] else 'FAILED_OR_NOT_RUN'
        report['failure'] = repr(error)
        raise
    finally:
        report['remaining_profiles'] = plan['profiles'][len(report['profiles']):]
        receipt.write_bytes(encoded(report))
    print(json.dumps({'status': report['status'], 'totals': report['totals'], 'children': len(report['commands'])}))


if __name__ == '__main__':
    main()
