#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite Fraction-oracle checks. No synthesis, routing, STA or hardware."""
from fractions import Fraction
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
DEPENDENCY = '../dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv'
PROFILES = [(1, 1, 0, 1), (2, 4, 0, 3), (4, 8, 0, 8),
            (8, 7, 8, 8), (16, 16, 16, 8), (24, 256, 24, 32)]


def make_vectors(w, capacity, frac, tag_w):
    rng = random.Random(0x43484932 + w*1000 + capacity*10 + frac)
    ceiling = (1 << w)-1
    frames = []

    def add(pairs):
        frames.append([(a, b, keep) for a, b, keep in pairs])

    def kept(pairs):
        add([(a, b, 1) for a, b in pairs])

    add([(ceiling, 0, 0)])
    add([(ceiling, 0, 0), (0, ceiling, 0), (0, 0, 0)])
    kept([(0, 0)])
    kept([(1, 1)])
    kept([(0, 0)]*capacity)
    kept([(ceiling, ceiling)]*capacity)
    add([(ceiling, ceiling, 1)]*capacity + [(ceiling, 0, 0), (ceiling, 0, 0)])
    kept([(ceiling, 1), (1, ceiling)])
    kept([(0, ceiling), (ceiling, 0)])
    kept([(1, 0), (0, 1)])
    kept([(ceiling, 1), (ceiling, 1)])
    kept([(0, 1), (0, 1)])
    kept([(1, 1), (0, 0), (1, 1)])
    add([(ceiling, 0, 0), (1, 1, 1), (ceiling, 0, 0), (1, 1, 1), (0, ceiling, 0)])
    kept([(ceiling, ceiling)]*(capacity+2))
    kept([(ceiling, 1)]*capacity + [(1, 0), (0, 0)])
    kept([(1, 0)]*capacity + [(1, 1), (0, 0)])
    kept([(ceiling, 1) if i%2==0 else (1, ceiling) for i in range(capacity)])
    if w >= 4 and capacity >= 2:
        kept([(3, 6), (9, 6)])  # two 1.5 terms, ties to even 2 at F=0
        kept([(1, 2), (3, 2)])  # two 0.5 terms, ties to even 0 at F=0
    if w in (1, 2):
        choices = list(itertools.product(range(ceiling+1), repeat=2))
        for length in range(1, 4):
            for sequence in itertools.product(choices, repeat=length):
                kept(sequence)
    for n in range(45):
        length = rng.randint(1, min(capacity, 16))
        es = [rng.randint(1, ceiling) for _ in range(length)]
        observed = list(es)
        rng.shuffle(observed)
        pairs = list(zip(observed, es))
        if n%3 == 0:
            # Nonuniform mass-preserving transfer, avoiding a permutations-only oracle fixture.
            if length >= 2:
                amount = min(pairs[0][0], ceiling-pairs[1][0])
                pairs[0] = (pairs[0][0]-amount, pairs[0][1])
                pairs[1] = (pairs[1][0]+amount, pairs[1][1])
        kept(pairs)
    for n in range(40):
        length = rng.randint(1, min(capacity+3, 20))
        add([(rng.randint(0, ceiling), rng.randint(0, ceiling), int(rng.randrange(5)!=0))
             for _ in range(length)])
    inputs, expected = [], []
    grow = (capacity-1).bit_length()
    cw = max(1, capacity.bit_length())
    mw, sw = w+grow, 2*w+frac+grow
    rw = sw+3*cw+2*mw+tag_w+5
    coverage = {'valid': 0, 'empty': 0, 'over_capacity': 0, 'zero_expected': 0,
                'mass_mismatch': 0, 'insufficient_active': 0, 'multi_error': 0,
                'term_tie_up': 0, 'term_tie_down': 0, 'differs_from_single_RNE': 0,
                'negative_difference': 0, 'positive_difference': 0,
                'retained_zero_zero': 0, 'domain_error_in_excess': 0}
    worst_error = Fraction(0)
    error_patterns = set()
    for fi, frame in enumerate(frames):
        tag = 0 if fi%13 == 0 else ((1 << tag_w)-1 if fi%13 == 1 else rng.getrandbits(tag_w))
        for i, (a, b, keep) in enumerate(frame):
            inputs.append(f'{a:x} {b:x} {keep} {int(i==len(frame)-1)} '
                          f'{tag if i==0 else rng.getrandbits(tag_w):x}\n')
        all_kept = [(a, b) for a, b, keep in frame if keep]
        retained = all_kept[:capacity]
        count = len(retained)
        active = sum(b > 0 for a, b in retained)
        so, se = sum(a for a, b in retained), sum(b for a, b in retained)
        bits = [count == 0, len(all_kept) > capacity,
                any(a > 0 and b == 0 for a, b in all_kept), so != se, active < 2]
        errors = sum(int(value) << i for i, value in enumerate(bits))
        error_patterns.add(errors)
        for name, bit in zip(['empty', 'over_capacity', 'zero_expected', 'mass_mismatch', 'insufficient_active'], bits):
            coverage[name] += int(bit)
        coverage['multi_error'] += errors.bit_count() > 1
        coverage['domain_error_in_excess'] += any(a > 0 and b == 0 for a, b in all_kept[capacity:])
        terms = [Fraction((a-b)**2, b) for a, b in retained if b > 0]
        # Fraction.__round__ is Python's exact nearest-even rational operation.
        # It shares neither DUT digit recurrence nor its saturation/sign logic.
        rounded = [round(x*(1 << frac)) for x in terms]
        statistic = sum(rounded) if errors == 0 else 0
        if errors == 0:
            coverage['valid'] += 1
            exact = sum(terms, Fraction(0))
            error = abs(Fraction(statistic, 1 << frac)-exact)
            assert error <= Fraction(active, 2*(1 << frac))
            worst_error = max(worst_error, error*(1 << frac))
            coverage['differs_from_single_RNE'] += statistic != round(exact*(1 << frac))
            for term, q in zip(terms, rounded):
                scaled = term*(1 << frac)
                if scaled.denominator == 2:
                    coverage['term_tie_up' if q > scaled else 'term_tie_down'] += 1
        coverage['negative_difference'] += sum(a < b for a, b in retained)
        coverage['positive_difference'] += sum(a > b for a, b in retained)
        coverage['retained_zero_zero'] += sum(a == b == 0 for a, b in retained)
        assert statistic < (1 << sw) and so < (1 << mw) and se < (1 << mw)
        fields = [(statistic, sw), (count, cw), (active, cw), (active-1 if active >= 2 else 0, cw),
                  (so, mw), (se, mw), (tag, tag_w), (errors, 5)]
        packed = shift = 0
        for value, width in fields:
            assert 0 <= value < 1 << width
            packed |= value << shift
            shift += width
        assert shift == rw
        expected.append(f'{packed:0{(rw+3)//4}x}\n')
    return ''.join(inputs), ''.join(expected), coverage, sorted(error_patterns), str(worst_error)


def allowed_diagnostics(stderr):
    if not stderr.strip():
        return True
    lines = [x.strip() for x in stderr.strip().splitlines()]
    header = ['warning: Some design elements have no explicit time unit and/or',
              ': time precision. This may cause confusing timing results.',
              ': Affected design elements are:']
    return (lines[:3] == header and len(lines) == 5 and
            all(re.fullmatch(r':\s+-- module fp_div_(iter|pipe) declared here: '
                             r'\.\./dsp_isp_library/infra/fixedpoint/rtl/recip_div\.sv:\d+', x)
                for x in lines[3:]))


def main():
    report = {'status': ['NOT_RUN', 'HW_UNVERIFIED'], 'checks': [], 'profiles': [],
              'not_run': ['synthesis', 'place_and_route', 'STA', 'hardware', 'expanded_regression'],
              'known_diagnostic': 'Unchanged recip_div.sv has no explicit timescale; only its two module warnings permitted.'}
    suite = ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env = os.environ.copy()
    env['PATH'] = str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH', '')
    executables = {x: os.environ.get(x.upper()) or shutil.which(x, path=env['PATH']) for x in ['iverilog', 'vvp']}
    temporary = ''

    def run(args, reject=False, version=False):
        result = subprocess.run([executables[args[0]], *args[1:]], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=15)
        okay = ((result.returncode != 0 and 'chi_square_gof_invalid_parameters' in result.stderr) if reject else
                result.returncode == 0 and (version or allowed_diagnostics(result.stderr)))
        report['checks'].append({'command': args, 'exit_code': result.returncode,
                                 'status': 'PASS' if okay else 'FAIL', 'stdout': result.stdout.strip(),
                                 'stderr': result.stderr.strip(), 'timeout_seconds': 15})
        if not okay:
            raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()

    try:
        if not all(executables.values()):
            raise RuntimeError('Icarus/vvp unavailable: NOT_RUN')
        report['tool'] = run(['iverilog', '-V'], version=True).splitlines()[0]
        run(['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'chi_square_gof', '-f', 'files.f'])
        run(['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'category_fit16', '-f', 'example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_chi_square_gof_') as temporary:
            path = Path(temporary)
            for w, capacity, frac, tag_w in PROFILES:
                inputs, expected, coverage, patterns, worst = make_vectors(w, capacity, frac, tag_w)
                beats, frames = len(inputs.splitlines()), len(expected.splitlines())
                (path/'inputs.txt').write_bytes(inputs.encode())
                (path/'expected.mem').write_bytes(expected.encode())
                image = path/'unit.vvp'
                run(['iverilog', '-g2012', '-Wall', '-s', 'tb_chi_square_gof',
                     f'-Ptb_chi_square_gof.DATA_W={w}', f'-Ptb_chi_square_gof.MAX_BINS={capacity}',
                     f'-Ptb_chi_square_gof.FRAC={frac}', f'-Ptb_chi_square_gof.TAG_W={tag_w}',
                     f'-Ptb_chi_square_gof.BEATS={beats}', f'-Ptb_chi_square_gof.FRAMES={frames}',
                     '-o', str(image), '-f', 'files.f', 'sim/tb_chi_square_gof.sv'])
                output = run(['vvp', str(image), f'+INPUTS={(path/"inputs.txt").as_posix()}',
                              f'+EXPECTED={(path/"expected.mem").as_posix()}'])
                if f'PASS frames={frames} beats={beats} outputs={frames}' not in output or 'reset_probes=8' not in output:
                    raise RuntimeError('bounded simulation did not finish')
                report['profiles'].append({'DATA_W': w, 'MAX_BINS': capacity, 'FRAC': frac, 'TAG_W': tag_w,
                    'beats': beats, 'frames': frames, 'coverage': coverage, 'error_patterns': patterns,
                    'worst_valid_error_output_LSB_exact': worst,
                    'inputs_sha256': hashlib.sha256(inputs.encode()).hexdigest(),
                    'expected_sha256': hashlib.sha256(expected.encode()).hexdigest(), 'result': output})
                print(output, flush=True)
            for parameter, value in [('DATA_W', 0), ('DATA_W', 25), ('MAX_BINS', 0), ('MAX_BINS', 257),
                                     ('FRAC', -1), ('FRAC', 25), ('TAG_W', 0), ('TAG_W', 33)]:
                run(['iverilog', '-g2012', '-tnull', '-s', 'chi_square_gof',
                     f'-Pchi_square_gof.{parameter}={value}', '-f', 'files.f'], reject=True)
        report['status'] = ['LINT_PASS', 'UNIT_SIM_PASS', 'INTEGRATION_CANDIDATE', 'HW_UNVERIFIED']
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        report['status'] = ['FAILED_OR_NOT_RUN', 'HW_UNVERIFIED']
        report['detail'] = str(exc)
        raise
    finally:
        for check in report['checks']:
            check['command'] = [a.replace(temporary, '<temporary>').replace(temporary.replace('\\', '/'), '<temporary>')
                                if temporary else a for a in check['command']]
        names = ['.gitattributes', 'README.md', 'SOURCES.md', 'files.f', 'rtl/chi_square_gof.sv',
                 'example/files.f', 'example/category_fit16.sv', 'sim/tb_chi_square_gof.sv', 'run_tests.py']
        report['source_sha256'] = {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
                                   for name in names if (ROOT/name).is_file()}
        report['dependency_sha256'] = {DEPENDENCY: hashlib.sha256((ROOT/DEPENDENCY).read_bytes()).hexdigest()}
        report['tools'] = executables
        (ROOT/'verification.json').write_bytes((json.dumps(report, indent=2)+'\n').encode())


if __name__ == '__main__':
    main()
