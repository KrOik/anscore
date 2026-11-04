#!/usr/bin/env python3
"""Freeze finite stimulus before writing HDL; Python stdlib only, no HDL tools."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import random

ROOT = Path(__file__).resolve().parent
PROFILES = [(1, 1), (2, 3), (3, 8), (5, 8), (8, 8), (16, 32)]
NEGATIVES = [('w0', 0, 8), ('w17', 17, 8), ('t0', 8, 0), ('t33', 8, 33)]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def oracle(n, a, b, m):
    # Independent defining sum: neither Euclidean recurrence nor RTL scheduler.
    return (0, 1) if m == 0 else (sum((a*i+b)//m for i in range(n)), 0)


def rounds(n, a, b, m):
    # Scheduling metadata only; never supplies expected sum.
    if not n or not m:
        return 0
    count = 0
    while True:
        count += 1
        a %= m
        b %= m
        y = a*n+b
        if y < m:
            return count
        n, b = divmod(y, m)
        a, m = m, a


def matrix(w, index):
    top = (1 << w)-1
    if w <= 3:
        return [(n, a, b, m) for n in range(top+1) for a in range(top+1)
                for b in range(top+1) for m in range(top+1)]
    half = 1 << (w-1)
    cases = [
        (0, 0, 0, 0), (0, top, top, 0), (top, top, top, 0),
        (0, top, top, top), (top, top, top, 1),
        (top, 0, 0, top), (top, 0, top, top), (top, top, 0, top),
        (top, top, top, top), (1, top, top, 1), (1, top, top, top),
        (top, 1, 0, top), (top, 1, top-1, top),
        (top, top-1, top-1, top), (top, top-1, 0, top),
        (top, top, top-1, top-1), (top, top, top, 2),
        (top, top, top, half), (half, half, half, top),
        (half-1, top, top, half), (half+1, top-1, top, top-1),
        (2, 1, 0, top), (2, top-1, top-1, top),
        (top, 0, top, 1), (top, top, 0, 1), (top, 1, 1, 1),
        (top, half-1, half, half+1), (top, half+1, half-1, half),
        (top, 13, 20, 21), (top, 21, 12, 13),
    ]
    # Deep Fibonacci denominator chains, all within the actual W-bit domain.
    f0, f1 = 1, 2
    while f1 <= top:
        cases.append((top, f0, f1-1, f1))
        f0, f1 = f1, f0+f1
    rng = random.Random(0xB22F100+index)
    count = {5: 144, 8: 112, 16: 24}[w]
    cases += [tuple(rng.randrange(top+1) for _ in range(4)) for _ in range(count)]
    return list(dict.fromkeys(cases))


def target_specs():
    result = [('idle', 'IDLE', -1, -1)]
    result += [('tri_setup', 'TRI_SETUP', -1, -1)]
    for job in range(4):
        result += [(f'mul{job}_first', 'MUL', job, 0),
                   (f'mul{job}_last', 'MUL', job, 'W-1')]
    result += [(f'mul{job}_return', 'MUL_RET', job, -1) for job in range(4)]
    for job in range(3):
        result += [(f'div{job}_first', 'DIV', job, 0),
                   (f'div{job}_last', 'DIV', job, '2W-1')]
    result += [(f'div{job}_return', 'DIV_RET', job, -1) for job in range(3)]
    result += [('terminal_y', 'MUL_RET', 3, 'y<m'),
               ('nonterminal_y', 'MUL_RET', 3, 'y>=m'),
               ('held_success', 'OUTPUT', -1, 'hold>=3'),
               ('held_m0', 'OUTPUT', -1, 'hold>=3'),
               ('held_n0', 'OUTPUT', -1, 'hold>=3'),
               ('deep_round', 'TRI_SETUP', -1, 'round>=3'),
               ('first_success', 'OUTPUT', -1, 'hold=0'),
               ('held_m0_n0_priority', 'OUTPUT', -1, 'hold>=3')]
    assert len(result) == 31
    return [dict(id=i, name=n, state=s, job=j, boundary=b) for i, (n,s,j,b) in enumerate(result)]


def reset_rows(w, t):
    top = (1 << w)-1
    result = []
    for target in range(31):
        owner = (top, top-1, top-1, top)
        if target == 26:
            owner = (top, top, top, 0)
        elif target == 27:
            owner = (0, top, top, top)
        elif target == 30:
            owner = (0, top, top, 0)
        fresh = (top, top-1, top-1, top)
        # Owner/fresh tags deliberately change, including the actual TAG_W MSB.
        otag = ((1 << (t-1)) | (target*19+1)) & ((1 << t)-1)
        ftag = ((1 << t)-1-(target*7)) & ((1 << t)-1)
        result.append((target, *owner, otag, *oracle(*owner), *fresh, ftag, *oracle(*fresh)))
    return result


def write_rows(relative, rows):
    path = ROOT/relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(' '.join(map(str, row)) for row in rows)+'\n', encoding='utf-8', newline='\n')
    return sha(path)


def main():
    assert not (ROOT/'MATRIX_FREEZE.json').exists(), 'immutable matrix already exists'
    assert not list(ROOT.rglob('*.sv')) and not list(ROOT.rglob('*.v')), 'freeze precedes original HDL'
    profiles = []
    for index, (w, t) in enumerate(PROFILES):
        stats = Counter()
        rows = []
        for i, values in enumerate(matrix(w, index)):
            n, a, b, m = values
            tag = [0, (1 << t)-1, 1 << (t-1), i*37+3][i % 4] & ((1 << t)-1)
            total, error = oracle(*values)
            r = rounds(*values)
            latency = r*(10*w+8)-(2*w+1) if r else 0
            rows.append((*values, tag, total, error))
            stats['frames'] += 1
            stats['m0'] += m == 0
            stats['m0_n0'] += m == 0 and n == 0
            stats['n0_success'] += m != 0 and n == 0
            stats['rounds'] += r
            stats['compute_cycles'] += latency
            stats['max_rounds'] = max(stats['max_rounds'], r)
            stats['max_latency'] = max(stats['max_latency'], latency)
            stats['max_sum'] = max(stats['max_sum'], total)
        name = f'w{w}_t{t}'
        fixture = f'sim/fixtures/{name}.txt'
        reset_fixture = f'sim/fixtures/{name}_resets.txt'
        fixture_sha = write_rows(fixture, rows)
        reset_sha = write_rows(reset_fixture, reset_rows(w,t))
        bound = (2*w+1)*(10*w+7)
        # Main stalls/turnaround plus 31 owner waits, all fresh transactions and guards.
        estimate = stats['compute_cycles']+12*len(rows)+62*(bound+16)
        profiles.append(dict(name=name,w=w,t=t,fixture=fixture,sha256=fixture_sha,
                             reset_fixture=reset_fixture,reset_sha256=reset_sha,
                             statistics=dict(stats),reset_probes=31,fresh_recoveries=31,
                             latency_bound=bound,conservative_cycle_estimate=estimate,
                             w1_alias_targets=[18,19,22,24,28] if w==1 else []))
    children = ['version', 'core_syntax', 'example_syntax']
    for p in profiles:
        children += [p['name']+'_compile', p['name']+'_simulate']
    children += ['reject_'+item[0] for item in NEGATIVES]
    freeze = dict(baseline='1fcf2f92dbf763e3251bd2994a7b9fd940c43694',
                  freeze_stage='FINITE_MATRIX_BEFORE_ORIGINAL_HDL',timeout_seconds=20,
                  profiles=profiles,negatives=NEGATIVES,children=children,
                  reset_targets=target_specs(),
                  reset_policy='assert synchronously sampled reset immediately at first observed requested boundary; combinational ready/valid gate immediately; cancel owner; complete and retire one held fresh transaction after every reset',
                  w1_alias_policy='18/19/22/24 alias terminal_y because normalized a=0; 28 aliases first TRI_SETUP because no third round exists',
                  oracle='Python direct defining sum((A*i+B)//M for i in range(N)); M0 priority separately; no Euclidean recurrence supplies expected data',
                  input_order='N A B M TAG EXPECTED_SUM EXPECTED_ERROR; decimal unsigned',
                  reset_order='TARGET OWNER_N A B M TAG SUM ERROR FRESH_N A B M TAG SUM ERROR',
                  source_policy='next actual frozen token continuously valid and stable through acceptance; all output fields held at least three cycles',
                  schedule='seven states IDLE/TRI_SETUP/MUL/MUL_RET/DIV/DIV_RET/OUTPUT; fixed W-step four multiplies and 2W-step two or three divisions each round',
                  exact_latency='M0 or N0:0; otherwise R*(10W+8)-(2W+1)',
                  no_adaptive_changes=True,
                  terminal_timeout='stop all remaining children; preserve TIMEOUT and NOT_RUN; no retry/reduction/increased limit',
                  ordinary_failure='archive exact source/plan/receipt and NOT_RUN; obtain root repair scope before editing',
                  not_run=['synthesis','PnR','STA','board','inherited regression','expanded matrix'],
                  preparation_sha256=sha(Path(__file__)),
                  attribute_sha256=sha(ROOT/'.gitattributes'))
    (ROOT/'MATRIX_FREEZE.json').write_text(json.dumps(freeze,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('MATRIX_FROZEN',sha(ROOT/'MATRIX_FREEZE.json'))
    for p in profiles:
        print(p['name'],p['statistics'],p['conservative_cycle_estimate'])


if __name__ == '__main__':
    main()
