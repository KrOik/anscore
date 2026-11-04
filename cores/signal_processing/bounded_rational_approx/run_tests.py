#!/usr/bin/env python3
"""Frozen bounded qualification. Never execute downloaded code or use shell=True."""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
from fractions import Fraction
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
BASELINE = 'ff2aadf8ebdc8e5475b7022cd68d47e496b9f593'
PROFILES = [(2, 1, 1), (3, 2, 3), (4, 3, 8), (8, 4, 8), (12, 6, 8), (16, 8, 32)]
NEGATIVES = [('w1', 1, 4, 8), ('w17', 17, 4, 8), ('q0', 8, 0, 8),
             ('q9', 8, 9, 8), ('t0', 8, 4, 0), ('t33', 8, 4, 33)]
MARKER = 'bounded_rational_approx_invalid_parameter__see_README'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8', newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ['TEST_PLAN.json', 'verification.json']}


def oracle(n, d, limit):
    """Independent enumeration of denominators, no bound-search or CF recurrence."""
    status = (d == 0) | ((limit == 0) << 1)
    if status:
        return (0, 0, 0, status), False
    candidates = {}
    for q in range(1, limit + 1):
        low = n*q // d
        for p in (low, low+1):
            g = math.gcd(p, q)
            pn, qn = p//g, q//g
            e = n*qn - pn*d
            candidates[(pn, qn)] = (Fraction(abs(e), qn), qn, abs(pn))
    p, q = min(candidates, key=candidates.get)
    best = candidates[(p, q)][0]
    tied = sum(v[0] == best for v in candidates.values()) > 1
    e = n*q-p*d
    assert math.gcd(p, q) == 1 and abs(e) < d and 1 <= q <= limit
    return (p, q, e, 0), tied


def signed_tag(v, t):
    v &= (1 << t)-1
    return v-(1 << 32) if v >= (1 << 31) else v


def freeze():
    assert not (ROOT/'TEST_PLAN.json').exists(), 'do not replace a frozen plan'
    profiles = []
    for profile_id, (w, qw, t) in enumerate(PROFILES):
        lo, hi, dm, qm = -(1 << (w-1)), (1 << (w-1))-1, (1 << w)-1, (1 << qw)-1
        if w <= 4:
            triples = [(n, d, q) for n in range(lo, hi+1)
                       for d in range(dm+1) for q in range(qm+1)]
        else:
            ns = sorted({n for n in [lo, lo+1, -129, -(1 << (w-2)), -7, -2, -1,
                                     0, 1, 2, 7, 1 << (w-2), hi-1, hi] if lo <= n <= hi})
            ds = sorted({0, 1, 2, 3, 5, 7, 1 << (w-1), dm-1, dm})
            qs = sorted({0, 1, 2, 3, qm//2, qm-1, qm})
            triples = [(n, d, q) for n in ns for d in ds for q in qs]
            rng = random.Random(0xB20A00 + profile_id)
            triples += [(rng.randint(lo, hi), rng.randint(0, dm), rng.randint(0, qm))
                        for _ in range(96)]
            triples = list(dict.fromkeys(triples))
        rows, stats = [], Counter()
        for i, (n, d, q) in enumerate(triples):
            tag = signed_tag([0, (1 << t)-1, 1 << (t-1), i*37+3][i % 4], t)
            result, tie = oracle(n, d, q)
            rows.append(' '.join(map(str, (n, d, q, tag, *result))))
            p, den, e, status = result
            stats['frames'] += 1; stats['status_'+str(status)] += 1
            if not status:
                stats['exact' if e == 0 else 'approximate'] += 1
                stats['ties'] += tie; stats['negative_inputs'] += n < 0
                stats['zero_results'] += p == 0; stats['fractional_results'] += den > 1
        name = f'w{w}_q{qw}_t{t}'
        relative = f'sim/fixtures/{name}.txt'
        path = ROOT/relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('\n'.join(rows)+'\n', encoding='utf-8', newline='\n')
        profiles.append(dict(name=name, w=w, qw=qw, t=t, fixture=relative,
                             sha256=sha(path), statistics=dict(stats), reset_probes=19,
                             fresh_recoveries=19, latency_bound=w+qm+3*qw+5))
    children = ['version', 'core_syntax', 'example_syntax']
    for p in profiles:
        children += [p['name']+'_compile', p['name']+'_simulate']
    children += ['reject_'+x[0] for x in NEGATIVES]
    plan = dict(baseline=BASELINE, frozen_before_first_hdl=True, timeout_seconds=20,
                profiles=profiles, negatives=NEGATIVES, children=children,
                reset_policy='19 immediate target resets, each one analytic +/-1 fresh with held output',
                oracle='enumerate all allowed q, original signed floor/ceil p; exact Fraction error,q,abs(p)',
                source_policy='full token held until accept/reset; actual next frozen token queued until accept',
                not_run=['synthesis', 'PnR', 'STA', 'board', 'inherited regression', 'expanded matrix'],
                source_sha256=sources())
    write_json(ROOT/'TEST_PLAN.json', plan)
    print('FROZEN', sha(ROOT/'TEST_PLAN.json'), [(p['name'], p['statistics']['frames']) for p in profiles])


def validate_trace(profile, path):
    w, qw, t = profile['w'], profile['qw'], profile['t']
    rows = [tuple(map(int, s.split())) for s in (ROOT/profile['fixture']).read_text().splitlines()]
    for target in range(19):
        n = 1 if target % 2 == 0 else -1
        tag = signed_tag(target+73, t)
        rows.append((n, 1, 1, tag, n, 1, 0, 0))
    divs, bounds, multiplies, outputs = {}, defaultdict(list), defaultdict(list), {}
    coverage = Counter()
    for line in path.read_text().splitlines():
        words = line.split(); kind = words[0]; a = list(map(int, words[1:])); i = a[0]
        assert 0 <= i < len(rows), ('trace id', i)
        n, d, limit, tag, pn, qn, e, status = rows[i]
        if kind == 'D':
            assert i not in divs and not status
            assert a[1:] == [abs(n)//d, abs(n)%d]
            divs[i] = a[1:]; coverage['divider_certificates'] += 1
        elif kind == 'S':
            ln, ld, rn, rd, el, er = a[1:]
            r = abs(n) % d
            assert not status and r != 0
            assert 0 <= ln <= ld <= limit and 0 <= rn <= rd <= limit
            assert rn*ld-ln*rd == 1 and el == r*ld-ln*d and er == rn*d-r*rd
            assert 0 < el < d and 0 < er < d
            bounds[i].append(a[1:]); coverage['bound_certificates'] += 1
            if ld+rd > limit: coverage['bound_stops'] += 1
            elif el == er: coverage['exact_mediants'] += 1
            elif el > er: coverage['left_updates'] += 1
            else: coverage['right_updates'] += 1
        elif kind == 'M':
            op, x, y, z = a[1:]
            assert op in [0, 1, 2] and z == x*y and z < (1 << (w+qw))
            multiplies[i].append((op, x, y, z)); coverage['multiply_certificates'] += 1
        elif kind == 'O':
            assert i not in outputs
            assert a[1:5] == [n, d, limit, tag]
            assert a[5:9] == [pn, qn, e, status]
            latency, ds, searches, products, steps = a[9:]
            assert len(bounds[i]) == searches and len(multiplies[i]) == products
            assert products*qw == steps
            if status:
                assert (latency, ds, searches, products, steps) == (0, 0, 0, 0, 0)
                assert i not in divs
            else:
                assert ds == w and i in divs
                assert math.gcd(pn, qn) == 1 and 1 <= qn <= limit and e == n*qn-pn*d and abs(e) < d
                assert products in [1, 3]
                assert latency == w+1+searches+steps+products+(products == 3)
                assert latency <= w+limit+3*qw+5
                assert multiplies[i][-1][0:3] == (2, abs(n)//d, qn)
                if products == 3:
                    ln, ld, rn, rd, el, er = bounds[i][-1]
                    assert ld+rd > limit
                    assert multiplies[i][0][0:3] == (0, el, rd)
                    assert multiplies[i][1][0:3] == (1, er, ld)
                coverage['residual_certificates'] += 1
            outputs[i] = a
            coverage['latency_certificates'] += 1
        else:
            raise AssertionError(('unknown trace', kind))
    assert len(outputs) == len(rows) and set(outputs) == set(range(len(rows)))
    assert coverage['left_updates'] > 0 if qw > 1 else True
    assert coverage['right_updates'] > 0 if qw > 1 else True
    return dict(coverage), sha(path)


def run():
    plan = json.loads((ROOT/'TEST_PLAN.json').read_text())
    assert plan['source_sha256'] == sources(), 'frozen source/fixture mismatch'
    assert plan['profiles'] and plan['timeout_seconds'] == 20
    assert not (ROOT/'verification.json').exists(), 'do not overwrite a qualification receipt'
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
        start = time.monotonic()
        record = dict(name=name, argv=list(map(str, argv)), timeout_seconds=20)
        try:
            r = subprocess.run(record['argv'], cwd=ROOT, env=env, capture_output=True,
                               text=True, encoding='utf-8', errors='replace', timeout=20)
            record.update(exit_code=r.returncode, stdout=r.stdout, stderr=r.stderr)
            passed = (r.returncode != 0 and MARKER in r.stdout+r.stderr) if reject else r.returncode == 0
            record['status'] = 'PASS' if passed else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            record.update(exit_code=None, status='TIMEOUT',
                          stdout=(exc.stdout or b'').decode('utf-8', 'replace') if isinstance(exc.stdout, bytes) else exc.stdout or '',
                          stderr=(exc.stderr or b'').decode('utf-8', 'replace') if isinstance(exc.stderr, bytes) else exc.stderr or '')
            receipt['terminal_timeout'] = True
        record['elapsed_seconds'] = round(time.monotonic()-start, 3)
        receipt['records'].append(record); save()
        print(name, record['status'], record['elapsed_seconds'], flush=True)
        if record['status'] != 'PASS': raise RuntimeError(name+' '+record['status'])
        return record
    temp_root = Path(tempfile.gettempdir()).resolve()
    tmp = Path(tempfile.mkdtemp(prefix='anscore_b20_ratio_', dir=temp_root)).resolve()
    assert tmp.parent == temp_root and tmp.name.startswith('anscore_b20_ratio_')
    try:
        child('version', [iv, '-V'])
        child('core_syntax', [iv, '-g2012', '-Wall', '-tnull', '-s', 'bounded_rational_approx', '-f', 'files.f'])
        child('example_syntax', [iv, '-g2012', '-Wall', '-tnull', '-s', 'rate_ratio16', '-f', 'example/files.f'])
        for profile in plan['profiles']:
            name = profile['name']; binary = tmp/(name+'.vvp'); trace = tmp/(name+'.trace')
            args = [iv, '-g2012', '-Wall', '-s', 'tb_bounded_rational_approx', '-o', binary]
            for param, key in [('W', 'w'), ('QW', 'qw'), ('TAG_W', 't')]:
                args += ['-P', f'tb_bounded_rational_approx.{param}={profile[key]}']
            args += ['rtl/bounded_rational_approx.sv', 'sim/tb_bounded_rational_approx.sv']
            child(name+'_compile', args)
            result = child(name+'_simulate', [vvp, binary, '+FIXTURE='+str(ROOT/profile['fixture']), '+TRACE='+str(trace)])
            summaries = [s for s in result['stdout'].splitlines() if s.startswith('PASS W=')]
            assert len(summaries) == 1, 'require unique PASS summary, not $finish location'
            observed = {k: int(v, 16 if k in ['states', 'ops'] else 10)
                        for k, v in re.findall(r'(\w+)=([0-9a-f]+)', summaries[0])}
            assert observed['frames'] == profile['statistics']['frames']
            assert observed['resets'] == observed['fresh'] == 19
            assert observed['max_latency'] == profile['latency_bound']
            assert observed['states'] == 255 and observed['ops'] == 7
            certificates, trace_sha = validate_trace(profile, trace)
            assert certificates['multiply_certificates'] == observed['products']
            assert certificates['bound_certificates'] == observed['searches']
            assert certificates['latency_certificates'] == observed['latency_checks']
            receipt['profiles'].append(dict(profile, observed=observed, certificates=certificates, trace_sha256=trace_sha))
            save()
        for name, w, qw, t in plan['negatives']:
            child('reject_'+name, [iv, '-g2012', '-tnull', '-s', 'bounded_rational_approx',
                  '-P', f'bounded_rational_approx.W={w}', '-P', f'bounded_rational_approx.QW={qw}',
                  '-P', f'bounded_rational_approx.TAG_W={t}', 'rtl/bounded_rational_approx.sv'], reject=True)
        assert len(receipt['records']) == len(plan['children'])
        assert sources() == plan['source_sha256']
        receipt['totals'] = {k: sum(p['observed'][k] for p in receipt['profiles'])
                             for k in ['frames', 'queued', 'resets', 'fresh', 'div_steps', 'searches',
                                       'products', 'mul_steps', 'source_holds', 'output_holds', 'latency_checks', 'ties']}
        receipt['status'] = 'UNIT_SIM_PASS'; save()
        print('QUALIFIED', sha(ROOT/'verification.json'), receipt['totals'])
    except Exception as exc:
        receipt['status'] = 'TIMEOUT_NOT_RUN' if receipt['terminal_timeout'] else 'FAIL'
        receipt['error'] = str(exc); save()
        raise
    finally:
        assert tmp.parent == temp_root and tmp.name.startswith('anscore_b20_ratio_')
        shutil.rmtree(tmp)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--freeze', action='store_true'); group.add_argument('--run', action='store_true')
    args = parser.parse_args()
    freeze() if args.freeze else run()
