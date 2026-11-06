"""SPDX-License-Identifier: Apache-2.0. Whole-frame integer EVM reference.

No RTL states, multiplier pipeline, scalar-vector schedule or divider recurrence.
"""
import random


def rne_ratio(numerator, denominator):
    quotient, remainder = divmod(numerator, denominator)
    return quotient + (2 * remainder > denominator or
                       (2 * remainder == denominator and quotient % 2 == 1))


def nearest16(rx, spacing=3):
    levels = [-3 * spacing, -spacing, spacing, 3 * spacing]
    # Explicit mathematical closest point; list order resolves exact ties.
    return tuple(min(levels, key=lambda level: abs(value - level)) for value in rx)


def frame_oracle(received, reference):
    assert len(received) == len(reference) and received
    errors = [(a - c) ** 2 + (b - d) ** 2 for (a, b), (c, d) in zip(received, reference)]
    error_energy = sum(errors)
    reference_energy = sum(a * a + b * b for a, b in reference)
    peak = max(errors)
    peak_index = errors.index(peak)
    if reference_energy == 0:
        return 3, error_energy, reference_energy, peak, peak_index, 0, 0
    ideal = rne_ratio(error_energy << 16, reference_energy)
    return 0, error_energy, reference_energy, peak, peak_index, min(ideal, 0xffffffff), int(ideal > 0xffffffff)


def prepare(profile):
    dw, cap, tagw, example = (profile[k] for k in ('data_w', 'max_symbols', 'tag_w', 'example'))
    lo, hi = -(1 << (dw - 1)), (1 << (dw - 1)) - 1
    mask = (1 << dw) - 1
    rows = []
    counts = dict(commands=0, records=0, samples=0, bad_lengths=0, bad_last=0,
                  zero_reference=0, all_zero=0, ratio_clips=0, nonfirst_peak_ties=0,
                  rne_even_ties=0, rne_odd_ties=0, largest_runtime_n=0, qam_faults=0)
    rng = random.Random(380038 + dw * 31 + cap)

    def emit(*args):
        assert len(args) <= 16
        rows.append([int(value) & ((1 << 64) - 1) for value in args] + [0] * (16 - len(args)))

    def pack(iq):
        return (iq[0] & mask) | ((iq[1] & mask) << dw)

    def command(n):
        tag = (0xfe000001 + counts['commands']) & ((1 << tagw) - 1)
        emit(1, n, tag)
        counts['commands'] += 1
        return tag

    def result(status, n, tag, err=0, ref=0, peak=0, index=0, ratio=0, clip=0, faults=0, timing=0):
        emit(3, status, n, tag, err, ref, peak, index, ratio, clip, faults, faults, timing)
        counts['records'] += 1
        counts['qam_faults'] += faults

    def batch(rx, ref=None, gaps=False, malformed=None):
        assert 1 <= len(rx) <= cap
        if example:
            ref = [nearest16(word) for word in rx]
        assert ref is not None and len(ref) == len(rx)
        assert all(lo <= value <= hi for word in rx + ref for value in word)
        tag = command(len(rx))
        counts['largest_runtime_n'] = max(counts['largest_runtime_n'], len(rx))
        for index, (word, target) in enumerate(zip(rx, ref)):
            last = index == len(rx) - 1
            if index == malformed:
                last = not last
            emit(2, pack(word), pack(target), last, index > 0 and not gaps)
            counts['samples'] += 1
            if index == malformed:
                faults = sum(abs(x) > 21 or abs(y) > 21 for x, y in rx[:index + 1]) if example else 0
                result(2, index + 1, tag, faults=faults)
                counts['bad_last'] += 1
                return
            if gaps and index % 3 == 1:
                emit(4, 3)
        status, err, energy, peak, peak_index, ratio, clip = frame_oracle(rx, ref)
        faults = sum(abs(x) > 21 or abs(y) > 21 for x, y in rx) if example else 0
        result(status, len(rx), tag, err, energy, peak, peak_index, ratio, clip, faults, 1)
        counts['zero_reference'] += energy == 0
        counts['all_zero'] += energy == err == 0
        counts['ratio_clips'] += clip
        errors = [(a-c)**2+(b-d)**2 for (a,b),(c,d) in zip(rx,ref)]
        counts['nonfirst_peak_ties'] += len(errors)>1 and errors.count(peak)>1
        if energy:
            quotient, remainder = divmod(err << 16, energy)
            counts['rne_even_ties'] += 2*remainder == energy and quotient%2 == 0
            counts['rne_odd_ties'] += 2*remainder == energy and quotient%2 == 1

    n = min(cap, 7)
    batch([(0, 0)] * n, [(0, 0)] * n)
    batch([(0, 0)] * n, [(1, 0)] * n)
    batch([(lo, lo)] * n, [(hi, hi)] * n)
    batch([(hi, lo)] * n, [(lo, hi)] * n)
    batch([(3, 4)] * n, [(3, 4)] * n, gaps=True)
    batch([(3, 4)] * n, [(1, 2)] * n)
    batch([(lo, hi)] * n, [(1, 0)] * n)
    batch([(1, 0)] * n, [(0, 0)] * n)
    if cap > 1:
        # Earliest equal maximum occurs at index1, not index0.
        batch([(0, 0), (hi, hi), (hi, hi)][:min(cap, 3)], [(1, 1)] * min(cap, 3))
        batch([(9, -9), (-9, 9), (3, -3), (-3, 3), (0, 0), (6, -6), (-6, 6)][:n], [(1, 0)] * n)
    if dw == 16 and cap > 1 and not example:
        # True Q16 half-LSB ties: Eref=2^17, Eerr=1 or3.
        batch([(257, 256)], [(256, 256)])
        batch([(257, 257), (1, 0)], [(256, 256), (0, 0)])
    long_n = min(cap, 37)
    for trial in range(4):
        rx = [(rng.choice([lo, -23, -1, 0, 1, 17, hi]), rng.choice([lo, -7, 0, 3, hi])) for _ in range(long_n)]
        ref = [(rng.choice([lo, -5, 0, 1, hi]), rng.choice([lo, -1, 0, 13, hi])) for _ in range(long_n)]
        batch(rx, ref, gaps=trial % 2 == 1)
    for nbad in [0, cap + 1, 0x80000001, 0xffffffff]:
        tag = command(nbad)
        result(1, 0, tag)
        counts['bad_lengths'] += 1
    bad_n = min(cap, 3)
    batch([(3, 4)] * bad_n, [(1, 2)] * bad_n, malformed=bad_n-1)
    if cap > 1:
        batch([(3, 4)] * bad_n, [(1, 2)] * bad_n, malformed=0)
    assert counts['records'] == counts['commands']
    assert counts['largest_runtime_n'] <= 37
    if dw == 16 and not example:
        assert counts['rne_even_ties'] > 0 and counts['rne_odd_ties'] > 0
    return ''.join(' '.join('%016x' % value for value in row) + '\n' for row in rows), counts
