"""SPDX-License-Identifier: Apache-2.0. Independent whole-list integer oracle.

No HDL recurrence, helper import, floating point, or upstream code is used.
Preparing fixtures is authorized only through the reviewed finite runner.
"""
import random


def variance(values, m, width):
    count = len(values) - 2*m
    differences = [values[i+2*m] - 2*values[i+m] + values[i]
                   for i in range(count)]
    total = sum(x*x for x in differences)
    bound = count*((1 << (width+1))-2)**2
    assert 0 <= total <= bound
    denominator = 2*m*m*count
    q, r = divmod(total*(1 << 16), denominator)
    rounded = q + (2*r > denominator or (2*r == denominator and q % 2))
    assert rounded < 1 << (2*width+17)
    return count, total, denominator, int(rounded), (2*r == denominator), q % 2


def prepare(profile, target):
    width, capacity, max_m, tag_w, example = [profile[k] for k in
        ('data_w', 'max_samples', 'max_m', 'tag_w', 'example')]
    lo, hi = -(1 << (width-1)), (1 << (width-1))-1
    rng = random.Random(4100+width+capacity)
    lines, labels = [], []
    counts = dict(commands=0, samples=0, records=0)
    coverage = dict(even_half_ties=0, odd_half_ties=0, full_sum_bound_witness=False,
                    maximum_denominator_witness=False, pretrigger_samples=0)

    def case(label, n, m, values=None, early=None, missing=False,
             invalid_at=None, preamble=0):
        if example:
            n = 256
        tag = (7*len(labels)+3) & ((1 << tag_w)-1)
        lines.append(f'1 {n} {m} {tag}')
        labels.append(label)
        counts['commands'] += 1
        legal = 3 <= n <= capacity and 1 <= m <= max_m and 2*m < n
        status, received, terms, total, den, result = 1, 0, 0, 0, 0, 0
        if legal:
            assert values is not None and len(values) == n
            assert all(lo <= x <= hi for x in values)
            if example:
                for i in range(preamble):
                    # PRE=0 must discard even invalid pretrigger observations.
                    lines.append(f'2 {lo if i % 2 else hi} 0 1 0')
                counts['samples'] += preamble
                coverage['pretrigger_samples'] += preamble
            for i, value in enumerate(values):
                marker = (i == 0) if example else (i == early or (i == n-1 and not missing))
                invalid = i == invalid_at
                gap = 2 if i % 11 == 4 else 0
                lines.append(f'2 {value} {int(marker)} {int(invalid)} {gap}')
                received += 1
                counts['samples'] += 1
                if not example and marker and i != n-1:
                    break
            if early is not None and not example:
                status = 2
            elif missing and not example:
                status = 3
            elif invalid_at is not None:
                status = 4
            else:
                status = 0
                terms, total, den, result, tie, odd = variance(values, m, width)
                coverage['even_half_ties'] += int(tie and not odd)
                coverage['odd_half_ties'] += int(tie and odd)
                coverage['full_sum_bound_witness'] |= total == terms*((1 << (width+1))-2)**2
                coverage['maximum_denominator_witness'] |= n == 4096 and m == 64
        hold = len(labels) % 5 + 1
        # Includes replay latency in the capture example, excludes source gaps.
        budget = 40*(n-2*m)+192+(n if example else 0) if status == 0 else (n+16 if example else 16)
        lines.append(f'3 {status} {n} {m} {received} {terms} {total} {den} {result} {tag} {hold} {budget}')
        counts['records'] += 1

    n = 256 if example else min(capacity, 17)
    case('constant', n, 1, [hi]*n)
    case('affine-frequency-offset', n, 1, [i-n//2 for i in range(n)])
    case('curved-phase', n, 1, [(i % 17-8)**2 for i in range(n)])
    case('alternating-signed-extrema', n, 1, [lo if i % 2 else hi for i in range(n)])
    mm = min(max_m, (n-1)//2)
    case('largest-legal-m-at-small-length', n, mm, [rng.randint(lo, hi) for _ in range(n)])
    for j in range(8):
        length = 256 if example else rng.randint(3, min(capacity, 65))
        m = rng.randint(1, min(max_m, (length-1)//2))
        case('deterministic-random-'+str(j), length, m,
             [rng.randint(lo, hi) for _ in range(length)], preamble=(300 if example and j == 0 else 0))
    length = 256 if example else min(capacity, 2*max_m+1)
    m = min(max_m, (length-1)//2)
    extremes = [0]*length
    extremes[0], extremes[m], extremes[2*m] = lo, hi, lo
    case('maximum-m-one-extreme-triplet', length, m, extremes)
    if profile.get('full_capacity'):
        case('full4096-exact-sum-bound', capacity, 1, [lo if i % 2 else hi for i in range(capacity)])
        case('full4096-maximum-denominator', capacity, 64, [0]*capacity)
    if max_m >= 64 and capacity >= 144:
        length = 256 if example else 144
        # The leading impulses contribute disjoint unit squares. Den is 2^20
        # for N256, or 2^17 for N144: exact .5 and 1.5 Q16 ties.
        for k, label in [(8 if example else 1, 'even-half-tie'),
                         (24 if example else 3, 'odd-half-tie')]:
            case(label, length, 64, [1]*k+[0]*(length-k))
    if not example:
        case('early-last-first', n, 1, [0]*n, early=0)
        case('early-last-before-final', n, 1, [hi]*n, early=n-2)
        case('missing-final-last', n, 1, [lo]*n, missing=True)
        case('early-last-precedes-invalid', n, 1, [0]*n, early=0, invalid_at=0)
        case('missing-last-precedes-invalid', n, 1, [0]*n, missing=True, invalid_at=n-1)
    case('invalid-first-sample', n, 1, [0]*n, invalid_at=0)
    case('invalid-final-sample', n, 1, [0]*n, invalid_at=n-1)
    if example:
        for m in [0, 65, 0xffffffff]:
            case('invalid-m-'+str(m), 256, m)
    else:
        for length, m in [(0, 1), (2, 1), (capacity+1, 1), (0xffffffff, 1),
                          (3, 0), (3, max_m+1), (3, 0xffffffff), (3, 2)]:
            case('invalid-config-'+str((length, m)), length, m)
    lines.append('0')
    target.write_bytes(('\n'.join(lines)+'\n').encode('ascii'))
    recovery_n = 256 if example else min(capacity, 17)
    expected = dict(D=width, M=capacity, MM=max_m, T=tag_w, EX=example,
                    commands=counts['commands']+34, records=counts['records']+18,
                    samples=counts['samples']+32*recovery_n+min(recovery_n-1, 7),
                    resets=17, faults=1)
    if max_m >= 64 and capacity >= 144:
        assert coverage['even_half_ties'] and coverage['odd_half_ties']
    if profile.get('full_capacity'):
        assert coverage['full_sum_bound_witness'] and coverage['maximum_denominator_witness']
    return dict(labels=labels, vector_counts=counts, coverage=coverage, expected_counters=expected)


if __name__ == '__main__':
    import json
    from pathlib import Path
    import sys
    if len(sys.argv) != 4 or sys.argv[1] != '--prepare-reviewed-profile':
        raise SystemExit('Use the approved finite runner only')
    index, report = int(sys.argv[2]), Path(sys.argv[3])
    plan = json.loads((Path(__file__).resolve().parent/'PRECHECK_PLAN.json').read_bytes())
    profile = plan['profiles'][index]
    result = prepare(profile, report/('vectors%d.txt' % index))
    (report/('preparation%d.json' % index)).write_bytes((json.dumps(result, indent=2)+'\n').encode())
    print('PREPARED phase_allan_variance profile=%d commands=%d records=%d samples=%d' %
          (index, result['vector_counts']['commands'], result['vector_counts']['records'], result['vector_counts']['samples']))
