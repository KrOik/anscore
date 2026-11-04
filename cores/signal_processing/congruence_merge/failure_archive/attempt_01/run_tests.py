#!/usr/bin/env python3
"""Finite frozen qualification; no shell, network, third-party Python, or synthesis."""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
BASELINE = 'ed4eda4fe213da6f6fec793ef911daaabfeba2cc'
PROFILES = [(1, 1), (2, 3), (3, 8), (5, 8), (8, 8), (16, 32)]
NEGATIVES = [('w0', 0, 8), ('w17', 17, 8), ('t0', 8, 0), ('t33', 8, 33)]
MARKER = 'congruence_merge_invalid_parameters__see_README'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n', encoding='utf-8', newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ['TEST_PLAN.json', 'verification.json']
            and 'failure_archive' not in p.relative_to(ROOT).parts}


def oracle(a, b, m, n, brute=False):
    """Closed-form generalized CRT, independent of the RTL residue walk."""
    status = int(m == 0) | (int(n == 0) << 1)
    if status:
        return 0, 0, status
    ra, rb, g = a % m, b % n, math.gcd(m, n)
    period = m*(n//g)
    if (rb-ra) % g:
        if brute:
            assert not any(x % m == ra and x % n == rb for x in range(period))
        return 0, 0, 4
    ng = n//g
    k = 0 if ng == 1 else (((rb-ra)//g)*pow(m//g, -1, ng)) % ng
    result = ra+m*k
    assert 0 <= result < period and result % m == ra and result % n == rb
    if brute:
        assert [x for x in range(period) if x % m == ra and x % n == rb] == [result]
    return result, period, 0


def tag_value(v, t):
    v &= (1 << t)-1
    return v-(1 << 32) if v >= (1 << 31) else v


def matrix(w, index):
    lo, hi, M = -(1 << (w-1)), (1 << (w-1))-1, (1 << w)-1
    if w <= 3:
        return [(a, b, m, n) for a in range(lo, hi+1) for b in range(lo, hi+1)
                for m in range(M+1) for n in range(M+1)]
    half = 1 << (w-1)
    cases = [
        (0, 0, 0, 0), (lo, hi, 0, M), (hi, lo, M, 0),
        (lo, hi, 1, 1), (lo, lo, M, M), (lo, hi, M, M),
        (hi, lo, M, M), (hi, hi, M, M), (0, 0, M, M),
        (-1, 1, 2, 3), (1, -1, 3, 2), (0, 1, 2, 2),
        (-1, -1, 6, 10), (1, 3, 6, 10), (1, 2, 6, 10),
        (lo, hi, half, half), (lo, lo, half, half),
        (lo, hi, half, 2), (hi, lo, 2, half),
        (lo, hi, 1, M), (hi, lo, M, 1),
        (0, 0, M-1, M), (lo, hi, M, M-1),
        (lo, hi, M-1, M-1), (hi, lo, half, M),
        (lo, hi, 1, 2), (hi, lo, 2, 1),
        (0, 0, half, 1), (hi, hi, 1, half),
        (-2, -1, 7, 7), (-1, -2, 7, 7),
        (hi, lo, M, half), (lo, hi, half, M-1),
    ]
    rng = random.Random(0xB21C00+index)
    # Frozen W16 random moduli <=255: directed cases above exercise full width.
    random_count = 16 if w == 16 else (96 if w == 8 else 128)
    random_max = min(M, 255)
    cases += [(rng.randint(lo, hi), rng.randint(lo, hi),
               rng.randint(0, random_max), rng.randint(0, random_max))
              for _ in range(random_count)]
    return list(dict.fromkeys(cases))


def freeze():
    assert not (ROOT/'TEST_PLAN.json').exists(), 'do not replace frozen plan'
    profiles = []
    for index, (w, t) in enumerate(PROFILES):
        stats, rows = Counter(), []
        for i, (a, b, m, n) in enumerate(matrix(w, index)):
            tag = tag_value([0, (1 << t)-1, 1 << (t-1), i*37+3][i % 4], t)
            x, p, status = oracle(a, b, m, n, brute=w <= 3)
            rows.append(' '.join(map(str, (a, b, m, n, tag, x, p, status))))
            stats['frames'] += 1; stats['status_'+str(status)] += 1
            if m and n:
                L = n//math.gcd(m, n)
                stats['positive_frames'] += 1; stats['orbit_steps'] += L
                stats['main_compute_cycles'] += 4*w+5+L
                stats['large_period'] += p >= (1 << 31)
                stats['negative_inputs'] += a < 0 or b < 0
        name = f'w{w}_t{t}'; relative = f'sim/fixtures/{name}.txt'
        path = ROOT/relative; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('\n'.join(rows)+'\n', encoding='utf-8', newline='\n')
        bound = 4*w+5+(1 << w)-1
        # Includes main output stalls, reset-owner work and 21 small fresh frames.
        estimate = stats['main_compute_cycles']+10*len(rows)+2*bound+60*w+21*60
        profiles.append(dict(name=name, w=w, t=t, fixture=relative, sha256=sha(path),
                             statistics=dict(stats), reset_probes=21, fresh_recoveries=21,
                             latency_bound=bound, conservative_cycle_estimate=estimate))
    children = ['version', 'core_syntax', 'example_syntax']
    for p in profiles:
        children += [p['name']+'_compile', p['name']+'_simulate']
    children += ['reject_'+n[0] for n in NEGATIVES]
    plan = dict(baseline=BASELINE, frozen_before_first_hdl=True, timeout_seconds=20,
                profiles=profiles, negatives=NEGATIVES, children=children,
                reset_policy='21 immediate observed-boundary resets and complete held fresh transactions; W1 explicit aliases 14/20',
                oracle='GCD plus modular inverse; W1..3 cross-checked by every integer below LCM',
                source_policy='actual next frozen token held until acceptance; all-field output hold',
                estimate_policy='W1..3 <=4096 frames; all profile conservative cycles estimated before any HDL child; no adaptive matrix',
                not_run=['synthesis', 'PnR', 'STA', 'board', 'inherited regression', 'expanded matrix'],
                source_sha256=sources())
    write_json(ROOT/'TEST_PLAN.json', plan)
    print('FROZEN', sha(ROOT/'TEST_PLAN.json'))
    print([(p['name'], p['statistics']['frames'], p['conservative_cycle_estimate']) for p in profiles])


def fresh_row(w, t, target):
    if w == 1:
        a, b, m, n, x, p = -1, 0, 1, 1, 0, 1
    elif target % 2 == 0:
        a, b, m, n, x, p = -1, 1, 2, 3, 5, 6
    else:
        a, b, m, n, x, p = 1, -1, 3, 2, 1, 6
    return a, b, m, n, tag_value(target+73, t), x, p, 0


def validate_trace(profile, path):
    w, t = profile['w'], profile['t']
    rows = [tuple(map(int, line.split())) for line in (ROOT/profile['fixture']).read_text().splitlines()]
    rows += [fresh_row(w, t, target) for target in range(21)]
    divs, orbit_counts, hits, outputs, probes = defaultdict(list), Counter(), Counter(), set(), set()
    coverage = Counter()
    for line in path.read_text().splitlines():
        words = line.split(); kind = words[0]; values = list(map(int, words[1:])); i = values[0]
        if kind == 'X':
            assert i not in probes and 0 <= i < 21
            state, job, count, found, status, alias = values[1:]
            assert alias == int(w == 1 and i in [14, 20])
            if i == 0: assert state == 0
            elif i <= 8: assert (state, job, count) == (1, (i-1)//2, 0 if i % 2 else w-1)
            elif i <= 12: assert (state, job) == (2, i-9)
            elif i == 13: assert (state, found) == (3, 0)
            elif i == 14: assert (state == 4) if w == 1 else (state, found) == (3, 1)
            elif i == 15: assert state == 4
            else: assert (state, status) == (5, 0 if i == 16 or (i == 20 and w == 1) else i-16)
            probes.add(i); coverage['reset_boundary_certificates'] += 1
            coverage['reset_aliases'] += alias
            continue
        assert 0 <= i < len(rows), ('trace id', i)
        a, b, m, n, tag, x, p, status = rows[i]
        if kind == 'D':
            job, rem, divisor = values[1:]
            assert job == len(divs[i]) and m and n
            numerators, divisors = [abs(a), abs(b), m, a % m], [m, n, n, n]
            assert divisor == divisors[job] and rem == numerators[job] % divisor
            divs[i].append(rem); coverage['divider_certificates'] += 1
        elif kind == 'R':
            candidate, residue, next_candidate, next_residue, found = values[1:]
            assert m and n
            k, L, ra, rb = orbit_counts[i], n//math.gcd(m, n), a % m, b % n
            assert k < L and candidate == ra+k*m and residue == candidate % n
            assert next_candidate == candidate+m and next_candidate < (1 << (2*w))
            assert next_residue == next_candidate % n and found == int(hits[i] > 0)
            if residue == rb: hits[i] += 1
            assert (next_residue == ra % n) == (k+1 == L)
            orbit_counts[i] += 1; coverage['orbit_certificates'] += 1
        elif kind == 'O':
            assert i not in outputs and values[1:9] == [a, b, m, n, tag, x, p, status]
            latency, ds, steps, matches = values[9:]
            assert matches == hits[i] and steps == orbit_counts[i]
            if m and n:
                L = n//math.gcd(m, n)
                assert len(divs[i]) == 4 and ds == 4*w and steps == L
                assert latency == 4*w+5+L and latency <= profile['latency_bound']
                assert matches == int(status == 0)
                if status == 0:
                    assert p == m*L and 0 <= x < p and x % m == a % m and x % n == b % n
                    coverage['solution_certificates'] += 1
                else:
                    assert status == 4 and (b % n-a % m) % math.gcd(m, n) != 0
                    coverage['conflict_certificates'] += 1
            else:
                assert status == int(m == 0) | (int(n == 0) << 1)
                assert (latency, ds, steps, matches) == (0, 0, 0, 0) and not divs[i]
            outputs.add(i); coverage['latency_certificates'] += 1
            coverage['match_certificates'] += matches
        else:
            raise AssertionError(('unknown trace kind', kind))
    assert outputs == set(range(len(rows))) and probes == set(range(21))
    return dict(coverage), sha(path)


def audit():
    plan = json.loads((ROOT/'TEST_PLAN.json').read_text())
    receipt = json.loads((ROOT/'verification.json').read_text())
    assert plan['source_sha256'] == sources() == receipt['source_sha256']
    assert receipt['plan_sha256'] == sha(ROOT/'TEST_PLAN.json')
    assert receipt['status'] == 'UNIT_SIM_PASS' and not receipt['terminal_timeout']
    assert [r['name'] for r in receipt['records']] == plan['children']
    assert len(receipt['records']) == 19 and all(r['status'] == 'PASS' and r['elapsed_seconds'] < 20.5 for r in receipt['records'])
    assert len(receipt['profiles']) == 6
    for p, observed in zip(plan['profiles'], receipt['profiles']):
        assert all(observed[k] == v for k, v in p.items())
        assert sha(ROOT/p['fixture']) == p['sha256']
        rows = [tuple(map(int, s.split())) for s in (ROOT/p['fixture']).read_text().splitlines()]
        assert len(rows) == p['statistics']['frames']
        for a, b, m, n, tag, x, period, status in rows:
            assert (x, period, status) == oracle(a, b, m, n, brute=p['w'] <= 3)
        o, c = observed['observed'], observed['certificates']
        assert o['frames'] == len(rows) and o['queued'] == len(rows)-1
        assert o['resets'] == o['fresh'] == c['reset_boundary_certificates'] == 21
        assert o['max_latency'] == p['latency_bound'] and o['states'] == 63 and o['jobs'] == 15
        assert c['divider_certificates']*p['w'] == o['div_steps']
        assert c['orbit_certificates'] == o['orbit_steps'] and c['match_certificates'] == o['matches']
        assert c['latency_certificates'] == o['latency_checks'] == len(rows)+21
    for name in sources():
        raw = (ROOT/name).read_bytes(); raw.decode('utf-8')
        assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'), name
    print('OFFLINE_AUDIT_PASS', sha(ROOT/'TEST_PLAN.json'), sha(ROOT/'verification.json'))


def run():
    plan = json.loads((ROOT/'TEST_PLAN.json').read_text())
    assert plan['source_sha256'] == sources(), 'frozen source/fixture mismatch'
    assert not (ROOT/'verification.json').exists(), 'never overwrite qualification receipt'
    tool_bin = ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
    iv, vvp = tool_bin/'iverilog.exe', tool_bin/'vvp.exe'
    assert iv.is_file() and vvp.is_file()
    env = dict(os.environ)
    env['PATH'] = str(tool_bin)+os.pathsep+str(tool_bin.parent/'lib')+os.pathsep+env.get('PATH', '')
    receipt = dict(baseline=BASELINE, status='IN_PROGRESS', hardware='HW_UNVERIFIED',
                   plan_sha256=sha(ROOT/'TEST_PLAN.json'), source_sha256=sources(),
                   profiles=[], records=[], terminal_timeout=False)
    def save(): write_json(ROOT/'verification.json', receipt)
    def child(name, argv, reject=False):
        assert name == plan['children'][len(receipt['records'])]
        start = time.monotonic(); record = dict(name=name, argv=list(map(str, argv)), timeout_seconds=20)
        try:
            r = subprocess.run(record['argv'], cwd=ROOT, env=env, capture_output=True,
                               text=True, encoding='utf-8', errors='replace', timeout=20)
            record.update(exit_code=r.returncode, stdout=r.stdout, stderr=r.stderr)
            passed = (r.returncode != 0 and MARKER in r.stdout+r.stderr) if reject else r.returncode == 0
            record['status'] = 'PASS' if passed else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            def decode(v): return v.decode('utf-8', 'replace') if isinstance(v, bytes) else v or ''
            record.update(exit_code=None, status='TIMEOUT', stdout=decode(exc.stdout), stderr=decode(exc.stderr))
            receipt['terminal_timeout'] = True
        record['elapsed_seconds'] = round(time.monotonic()-start, 3)
        receipt['records'].append(record); save()
        print(name, record['status'], record['elapsed_seconds'], flush=True)
        if record['status'] != 'PASS': raise RuntimeError(name+' '+record['status'])
        return record
    temp_root = Path(tempfile.gettempdir()).resolve()
    tmp = Path(tempfile.mkdtemp(prefix='anscore_b21_crt_', dir=temp_root)).resolve()
    assert tmp.parent == temp_root and tmp.name.startswith('anscore_b21_crt_')
    try:
        child('version', [iv, '-V'])
        child('core_syntax', [iv, '-g2012', '-Wall', '-tnull', '-s', 'congruence_merge', '-f', 'files.f'])
        child('example_syntax', [iv, '-g2012', '-Wall', '-tnull', '-s', 'phase_merge16', '-f', 'example/files.f'])
        for profile in plan['profiles']:
            name = profile['name']; binary, trace = tmp/(name+'.vvp'), tmp/(name+'.trace')
            argv = [iv, '-g2012', '-Wall', '-s', 'tb_congruence_merge', '-o', binary]
            for param, key in [('W', 'w'), ('TAG_W', 't')]:
                argv += ['-P', f'tb_congruence_merge.{param}={profile[key]}']
            argv += ['rtl/congruence_merge.sv', 'sim/tb_congruence_merge.sv']
            child(name+'_compile', argv)
            result = child(name+'_simulate', [vvp, binary, '+FIXTURE='+str(ROOT/profile['fixture']), '+TRACE='+str(trace)])
            summaries = [s for s in result['stdout'].splitlines() if s.startswith('PASS W=')]
            assert len(summaries) == 1, 'require unique PASS summary'
            observed = {k: int(v, 16 if k in ['states', 'jobs', 'statuses'] else 10)
                        for k, v in re.findall(r'(\w+)=([0-9a-f]+)', summaries[0])}
            assert observed['frames'] == profile['statistics']['frames']
            assert observed['resets'] == observed['fresh'] == 21
            assert observed['max_latency'] == profile['latency_bound']
            assert observed['states'] == 63 and observed['jobs'] == 15
            assert observed['statuses'] == (15 if profile['w'] == 1 else 31)
            certificates, trace_sha = validate_trace(profile, trace)
            assert certificates['divider_certificates']*profile['w'] == observed['div_steps']
            assert certificates['orbit_certificates'] == observed['orbit_steps']
            assert certificates['match_certificates'] == observed['matches']
            assert certificates['latency_certificates'] == observed['latency_checks']
            receipt['profiles'].append(dict(profile, observed=observed, certificates=certificates, trace_sha256=trace_sha));save()
        for name, w, t in plan['negatives']:
            child('reject_'+name, [iv, '-g2012', '-tnull', '-s', 'congruence_merge',
                  '-P', f'congruence_merge.W={w}', '-P', f'congruence_merge.TAG_W={t}',
                  'rtl/congruence_merge.sv'], reject=True)
        assert len(receipt['records']) == len(plan['children']) and sources() == plan['source_sha256']
        receipt['totals'] = {k: sum(p['observed'][k] for p in receipt['profiles'])
                             for k in ['frames', 'queued', 'resets', 'fresh', 'div_steps', 'orbit_steps',
                                       'matches', 'source_holds', 'output_holds', 'latency_checks']}
        receipt['status'] = 'UNIT_SIM_PASS';save()
        audit()
        print('QUALIFIED', sha(ROOT/'verification.json'), receipt['totals'])
    except Exception as exc:
        receipt['status'] = 'TIMEOUT_NOT_RUN' if receipt['terminal_timeout'] else 'FAIL'
        receipt['error'] = str(exc)
        for name in plan['children'][len(receipt['records']):]:
            receipt['records'].append(dict(name=name, status='NOT_RUN'))
        save()
        archive_index = 0
        while (ROOT/'failure_archive'/f'attempt_{archive_index:02d}').exists():
            archive_index += 1
        archive = ROOT/'failure_archive'/f'attempt_{archive_index:02d}'
        archive.mkdir(parents=True)
        for relative in [*plan['source_sha256'], 'TEST_PLAN.json', 'verification.json']:
            destination = archive/relative;destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/relative, destination)
        (archive/'NOT_RUN.txt').write_text('\n'.join(r['name'] for r in receipt['records'] if r['status'] == 'NOT_RUN')+'\n', encoding='utf-8', newline='\n')
        raise
    finally:
        assert tmp.parent == temp_root and tmp.name.startswith('anscore_b21_crt_')
        shutil.rmtree(tmp)


if __name__ == '__main__':
    parser = argparse.ArgumentParser();group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--freeze', action='store_true');group.add_argument('--run', action='store_true')
    group.add_argument('--audit', action='store_true');args = parser.parse_args()
    if args.freeze: freeze()
    elif args.run: run()
    else: audit()
