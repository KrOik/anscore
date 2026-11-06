"""SPDX-License-Identifier: Apache-2.0. Independent Fraction-based finite oracle.

SOURCE_ONLY until exact root/peer approval. The runner executes an archived copy
directly; it never imports this module. No SciPy or other project code is used.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import random

PROFILES = {
    'core_min': dict(max_bins=1, tag_w=1, iq=0),
    'core_odd': dict(max_bins=7, tag_w=8, iq=0),
    'core_max': dict(max_bins=256, tag_w=32, iq=0),
    'iq64': dict(max_bins=64, tag_w=8, iq=1),
}


def power(value, iq):
    if not iq:
        assert 0 <= value < 2**32
        return value
    real, imaginary = value & 65535, value >> 16
    real = real - 65536 if real >= 32768 else real
    imaginary = imaginary - 65536 if imaginary >= 32768 else imaginary
    return real * real + imaginary * imaginary


def fixtures(profile):
    cfg = PROFILES[profile]
    maximum, iq = cfg['max_bins'], cfg['iq']
    n, rows = maximum, []
    tag_mask = (1 << cfg['tag_w']) - 1

    def add(values, restart=0, bins=None, last=None, invalid=None, label=''):
        size = len(values) if bins is None else bins
        marks = [int(i == len(values)-1) for i in range(len(values))] if last is None else last
        flags = [0] * len(values) if invalid is None else invalid
        assert len(values) == len(marks) == len(flags)
        rows.append(dict(bins=size, restart=restart, tag=(len(rows)*37+3) & tag_mask,
                         values=values, last=marks, invalid=flags, label=label))

    one = 1
    two = 2  # I=2 has power4 in the actual I/Q chain.
    zeros, flat = [0]*n, [one]*n
    spike0 = [one] + [0]*(n-1)
    spikel = [0]*(n-1) + [one]
    add(zeros, label='first_zero_warmup')
    add(zeros, label='both_zero')
    add(flat, label='empty_reference')
    add(zeros, label='empty_current')
    add(flat, label='empty_reference_again')
    add([two]*n, label='independent_frame_gain')
    add(spike0, label='uniform_to_impulse')
    add(spikel, label='disjoint_support')
    add(spike0, restart=1, label='explicit_restart')
    add(spike0, label='identical')
    add([], bins=0, label='bad_zero_length_preserves_reference')
    add(spike0, label='reference_after_bad_command')
    add([], bins=maximum+1, label='bad_capacity')
    add([], bins=0xffffffff, label='full_width_bad_length')
    add(spike0, label='reference_after_full_width_reject')
    if n > 1:
        add([one], bins=n, last=[1], label='early_last_breaks_history')
        add(spike0, label='warmup_after_early_last')
    add(flat, last=[0]*n, label='missing_last_breaks_history')
    add(flat, label='warmup_after_missing_last')
    add([one], bins=n, last=[1], invalid=[1], label='invalid_precedes_last_error')
    add(flat, label='warmup_after_invalid')
    maximum_value = 0xffffffff if not iq else 0x80008000
    add([maximum_value]*n, label='all_unsigned_max_or_signed_min_iq')
    add([maximum_value if i & 1 else 0 for i in range(n)], label='alternating_extremes')
    if n > 1:
        add([one], label='length_change_warmup')
        add(flat, label='returning_length_warmup')
    rng = random.Random(0xB480 + maximum + iq)
    for number in range(4):
        values = [rng.randrange(2**32) for _ in range(n)]
        add(values, restart=int(number == 0), label='full_range_random_' + str(number))
    if maximum >= 2 and not iq:
        for odd in (1, 3, 5):
            add([131072, 0], restart=1, label='rne_reference_' + str(odd))
            add([131072-odd, odd], label='rne_half_' + str(odd))
        add([1, 0], restart=1, label='near_unity_reference')
        add([1, 0xffffffff], label='near_unity_rounds_to_unity')
        add([1, 0], restart=1, label='near_half_lsb_reference')
        add([131072, 1], label='below_half_lsb')
        add([1, 0], restart=1, label='above_half_lsb_reference')
        add([131070, 1], label='above_half_lsb')
    if maximum >= 4:
        a, b = [one, 0, one, 0], [0, one, 0, one]
        for sequence, name in (([a, a, b, b], 'AABB'), ([a, b, a, b], 'ABAB')):
            for index, values in enumerate(sequence):
                add(values, restart=int(index == 0), label=name + '_' + str(index))
    if iq:
        add([0x80008000, 0x7fff8000], restart=1, label='iq_signed_extrema_reference')
        add([0x80000000, 0x00008000], label='iq_real_imag_power_equivalence')
        add([0x00010001, 0xffff0001], restart=1, label='iq_phase_rotation_reference')
        add([0x0001ffff, 0x00010001], label='iq_phase_invariant_power')
    return cfg, rows


def expected_records(cfg, rows):
    reference = None
    result = []
    for row in rows:
        bins, values = row['bins'], row['values']
        result_row = dict(row)
        status, received, total, prior, numerator, denominator, q16, valid, inexact = 0, 0, 0, 0, 0, 0, 0, 0, 0
        if not 1 <= bins <= cfg['max_bins']:
            status = 5
            assert not values
        else:
            failure = 0
            for index, value in enumerate(values):
                received += 1
                if row['invalid'][index]:
                    failure = 8
                elif row['last'][index] and index != bins-1:
                    failure = 6
                elif not row['last'][index] and index == bins-1:
                    failure = 7
                if failure:
                    assert index == len(values)-1
                    break
            if failure:
                status, reference = failure, None
            else:
                assert received == bins and row['last'][-1]
                powers = [power(value, cfg['iq']) for value in values]
                total = sum(powers)
                comparable = reference is not None and len(reference) == bins and not row['restart']
                if not comparable:
                    status = 1
                else:
                    prior = sum(reference)
                    if not total or not prior:
                        status = 2 if not total and not prior else 3 if not prior else 4
                    else:
                        # Independent formulation: half the L1 distance of two
                        # normalized Fraction vectors, rather than RTL cross-products.
                        distance = sum(abs(Fraction(a, total)-Fraction(b, prior))
                                       for a, b in zip(powers, reference)) / 2
                        denominator = total * prior
                        exact_numerator = distance * denominator
                        assert exact_numerator.denominator == 1
                        numerator = exact_numerator.numerator
                        scaled = distance * 65536
                        q16, valid, inexact = round(scaled), 1, int(scaled.denominator != 1)
                        assert 0 <= numerator <= denominator and 0 <= q16 <= 65536
                # Each fixture retires its one result; valid zero frames are
                # genuine references. Bad commands above leave reference unchanged.
                reference = powers
        result_row['expected'] = [status, received, total, prior, numerator, denominator, q16, valid, inexact]
        result.append(result_row)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=tuple(PROFILES), required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    out = Path(args.out)
    assert not out.exists()
    out.mkdir(parents=True, exist_ok=False)
    cfg, rows = fixtures(args.profile)
    records = expected_records(cfg, rows)
    lines = [str(len(records))]
    for row in records:
        header = [row['bins'], row['restart'], row['tag'], len(row['values']), *row['expected']]
        lines.append(' '.join(format(value, 'x') for value in header))
        lines.extend(f'{value:x} {last:x} {invalid:x}' for value, last, invalid in
                     zip(row['values'], row['last'], row['invalid']))
    data = ('\n'.join(lines)+'\n').encode('ascii')
    def save(name, content):
        with (out/name).open('xb') as stream:
            stream.write(content);stream.flush();os.fsync(stream.fileno())
    save('vectors.txt', data)
    summary = dict(profile=args.profile, configuration=cfg, cases=len(records), labels=[row['label'] for row in records],
                   vector_sha256=hashlib.sha256(data).hexdigest(), vector_bytes=len(data),
                   expected=dict(cases=len(records), results=len(records)+28, holds=5*(len(records)+28),
                                 resets=9, cancellations=8, arith_errors=1))
    save('preparation.json', (json.dumps(summary, indent=2)+'\n').encode('utf-8'))
    print('B48_SHAPE_PREP_PASS cases=' + str(len(records)))


if __name__ == '__main__':
    main()
