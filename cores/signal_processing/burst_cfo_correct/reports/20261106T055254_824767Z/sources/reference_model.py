"""SPDX-License-Identifier: Apache-2.0.

Whole-prefix integer sums and direct mathematical atan2/rotation. No CORDIC,
serial multiplier, helper FSM, or controller recurrence is reproduced here.
"""
import math
import random


def prefix_oracle(words, threshold, floor):
    a, b = words[:16], words[16:32]
    re = sum(x*u+y*v for (x, y), (u, v) in zip(a, b))
    im = sum(x*v-y*u for (x, y), (u, v) in zip(a, b))
    energy = sum(x*x+y*y for x, y in words[:32])
    if energy == 0 or (re == 0 and im == 0):
        return 5, 0.0, 0, (re, im, energy)
    angle = math.atan2(im, re)
    phase = round(angle * (1 << 24) / (2*math.pi)) & 0xffffff
    signed = phase if phase < (1 << 23) else phase-(1 << 24)
    if energy < floor or ((re*re+im*im) << 18) < threshold*energy*energy:
        status = 6
    elif abs(signed) >= (1 << 23)-4:
        status = 7
    else:
        status = 0
    return status, angle, phase, (re, im, energy)


def rotate(words, angle):
    for n, (x, y) in enumerate(words):
        c, s = math.cos(-n*angle/16), math.sin(-n*angle/16)
        yield tuple(max(-2048, min(2047, round(value))) for value in (x*c-y*s, x*s+y*c))


def prepare(profile):
    cap, tagw = profile['max_samples'], profile['tag_w']
    rows = []
    counts = dict(commands=0, records=0, samples=0, successful_bursts=0,
                  error_markers=0, largest_runtime_n=0, gaps=0,
                  phase_positive=0, phase_negative=0, branch_boundary=0,
                  unqualified=0, zero_prefix=0, bad_last=0, invalid_commands=0,
                  expected_saturations=0, ideal_zero_cfo=0)
    rng = random.Random(390039+cap)

    def emit(*values):
        assert len(values) <= 16
        rows.append([int(v) & ((1 << 64)-1) for v in values]+[0]*(16-len(values)))

    def command(n, threshold=49152, floor=1):
        tag = (0x9abc0000+counts['commands']) & ((1 << tagw)-1)
        emit(1, n, threshold, floor, tag)
        counts['commands'] += 1
        return tag

    def marker(status, tag, index=0):
        emit(3, status, index, tag, 0, 0, 0, 1, 4)
        counts['records'] += 1
        counts['error_markers'] += 1

    def batch(words, threshold=49152, floor=1, gaps=False, malformed=None):
        assert 32 <= len(words) <= cap
        assert all(-2048 <= value <= 2047 for word in words for value in word)
        tag = command(len(words), threshold, floor)
        counts['largest_runtime_n'] = max(counts['largest_runtime_n'], len(words))
        previous_gap = False
        for n, (x, y) in enumerate(words):
            last = n == len(words)-1
            if n == malformed:
                last = not last
            ii = (9 if n < 32 else 1) if n and not previous_gap else 0
            emit(2, (x & 0xfff) | ((y & 0xfff) << 12), last, ii)
            counts['samples'] += 1
            if n == malformed:
                marker(4, tag, n)
                counts['bad_last'] += 1
                return
            previous_gap = gaps and n % 7 == 3
            if previous_gap:
                emit(4, 3)
                counts['gaps'] += 1
        status, angle, phase, evidence = prefix_oracle(words, threshold, floor)
        if status:
            marker(status, tag)
            counts['branch_boundary'] += status == 7
            counts['unqualified'] += status == 6
            counts['zero_prefix'] += status == 5
            return
        counts['successful_bursts'] += 1
        counts['phase_positive'] += angle > 0
        counts['phase_negative'] += angle < 0
        counts['ideal_zero_cfo'] += angle == 0
        for n, (x, y) in enumerate(rotate(words, angle)):
            hold = 4 if n == 0 or n == len(words)-1 or n % 31 == 7 else 0
            emit(3, 0, n, tag, phase, x, y, n == len(words)-1, hold)
            counts['records'] += 1
            counts['expected_saturations'] += abs(x) >= 2047 or abs(y) >= 2047

    def repeated(prefix, n=32, payload=None):
        if payload is None:
            payload = [(rng.randint(-2048,2047), rng.randint(-2048,2047)) for _ in range(n-32)]
        return prefix+prefix+payload

    # Unknown repeated content, including every signed endpoint; zero CFO.
    prefix = [(2047,-2048),(-2048,2047),(0,0),(1,-1)]*4
    batch(repeated(prefix, min(cap, 47)), threshold=65536)
    # Exact integer +/-quarter-turn correlations; correction sign must reverse.
    base = [(1000,0)]*16
    for sign in [1,-1]:
        words = base+[(0,sign*1000)]*16
        words += [(2047,2047),(-2048,-2048),(2047,-2048),(-2048,2047)]*((min(cap,64)-32)//4)
        words += [(123,-456)]*(min(cap,64)-len(words))
        batch(words, gaps=sign < 0)
    # Real-valued CFO sampled and quantized once; oracle uses resulting exact P.
    for frequency in [0.00625,-0.011,0.025,-0.028]:
        unknown = [(rng.randint(-700,700),rng.randint(-700,700)) for _ in range(16)]
        words = []
        for n in range(min(cap, 65)):
            x,y = unknown[n%16] if n<32 else (rng.randint(-900,900),rng.randint(-900,900))
            a=2*math.pi*frequency*n
            words.append((round(x*math.cos(a)-y*math.sin(a)),round(x*math.sin(a)+y*math.cos(a))))
        batch(words)
    # Exact energy-floor inclusion and normalized metric equality/adjacency.
    batch(repeated([(1,0)]*16), threshold=65536, floor=32)
    batch(repeated([(1,0)]*16), threshold=65536, floor=33)
    # P=8,E=32: M=1/4, threshold equality exactly16384.
    batch([(1,0)]*16+[(1,0)]*12+[(-1,0)]*4, threshold=16384)
    batch([(1,0)]*16+[(1,0)]*12+[(-1,0)]*4, threshold=16385)
    batch([(0,0)]*min(cap,35))
    batch([(1,0)]*16+[(1,0)]*8+[(-1,0)]*8)
    # Exact half-turn ambiguity and +/-near-boundary estimates are rejected.
    batch([(1000,0)]*16+[(-1000,0)]*16)
    for imag in [1,-1,1000,-1000]:
        batch([(1,0)]+[(2047,0)]*15+[(-1,imag)]+[(-2047,0)]*15)
    # Small P can be nonaxis: this exercises magnitude-independent atan2 bound.
    batch([(1,0)]+[(0,0)]*15+[(1,1)]+[(0,0)]*15, threshold=1)
    # Largest legal address/counter and accumulated correction phase.
    # One full4096 replay only on the max profile, bounded by the same20s child.
    n = cap if profile['full_capacity'] else min(cap, 97)
    batch([(700,0)]*16+[(300,600)]*16+
          [(rng.randint(-2048,2047),rng.randint(-2048,2047)) for _ in range(n-32)], threshold=1)
    for bad_n in [0,31,cap+1,0x80000020,0xffffffff]:
        tag=command(bad_n, 0, 1<<40)
        marker(1,tag)
        counts['invalid_commands'] += 1
    for bad_threshold in [0,65537,0x80000001,0xffffffff]:
        tag=command(32,bad_threshold,1<<40)
        marker(2,tag)
        counts['invalid_commands'] += 1
    tag=command(32,1,1<<29);marker(3,tag);counts['invalid_commands'] += 1
    for malformed in [0,17,31,min(cap,40)-1]:
        batch(repeated([(3,4)]*16,min(cap,40)), malformed=malformed)
        # The next batch proves helper flush and ownership recovery.
        batch(repeated([(3,4)]*16))
    assert counts['phase_positive'] and counts['phase_negative']
    assert counts['branch_boundary'] and counts['unqualified'] and counts['zero_prefix']
    return ''.join(' '.join('%016x'%v for v in row)+'\n' for row in rows), counts
