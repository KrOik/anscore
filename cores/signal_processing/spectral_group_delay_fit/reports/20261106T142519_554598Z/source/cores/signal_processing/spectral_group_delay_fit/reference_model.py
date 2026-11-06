"""SPDX-License-Identifier: Apache-2.0.
Independent pairwise integer oracle. No project imports; CLI is a gated child.
"""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import random

PROFILES = {
    'core_p8_n5_t1': (0, 8, 5, 1, 4, 0, 8),
    'core_p16_n64_t8': (0, 16, 64, 8, 16, 0, 16),
    'core_p24_n256_t32': (0, 24, 256, 32, 16, 0, 16),
    'iq_p8_n5_t1': (1, 8, 5, 1, 4, 8, 8),
    'iq_p16_n64_t8': (1, 16, 64, 8, 16, 24, 16),
}


def fit(phases, phase_width, fft_log2):
    modulus = 1 << phase_width
    half = modulus // 2
    values = [phases[0] if phases[0] < half else phases[0]-modulus]
    for previous, current in zip(phases, phases[1:]):
        representatives = (current-previous-modulus, current-previous, current-previous+modulus)
        delta = min(representatives, key=lambda value: (abs(value), value))
        values.append(values[-1]+delta)
    # Deliberately does not use the RTL sums N*sum(k*y)-sum(k)*sum(y).
    pairs = [(j-i, values[j]-values[i]) for i in range(len(values)) for j in range(i+1, len(values))]
    d = sum(dx*dx for dx, _ in pairs)
    b = sum(dx*dy for dx, dy in pairs)
    c = sum(dy*dy for _, dy in pairs)
    residual = c*d-b*b
    assert d > 0 and residual >= 0
    delay = round(Fraction(-b*(1 << (fft_log2+16)), d*modulus))
    return delay, b, c, d, residual


def cases_for(profile):
    adapter, p, maximum, tag_width, max_fft, iterations, input_width = PROFILES[profile]
    modulus = 1 << p
    half, quarter, mask = modulus//2, modulus//4, modulus-1
    cases = []

    def add(phases, first=0, fft=None, count=None, last=None, invalid=None):
        count = len(phases) if count is None else count
        fft = max_fft if fft is None else fft
        last = [int(i == count-1) for i in range(len(phases))] if last is None else last
        invalid = [0]*len(phases) if invalid is None else invalid
        cases.append((count, first, fft, list(zip(phases, last, invalid))))

    if adapter:
        eighth = modulus//8
        patterns = ([0, 0], [0, 4], [4, 0], [7, 0], [0, 7],
                    [i % 8 for i in range(maximum)], [(-i) % 8 for i in range(maximum)],
                    [0, 1, 3, 2, 0], [4]*maximum, [1, 2, 3], [2, 2], [6, 5, 4])
        for indices in patterns:
            add([i*eighth for i in indices])
    else:
        patterns = ([0, 0], [half-1, half], [0, half], [half, 0], [half+7]*3,
                    [(mask-7+i*(quarter-1)) & mask for i in range(maximum)],
                    [(2-i*quarter) & mask for i in range(maximum)],
                    [(half-i*half) & mask for i in range(maximum)],
                    [0, quarter, quarter+3, 0, half-1], [mask, 0], [1, 0], [0, 1, 1])
        for phases in patterns:
            add(phases)
        add([0, quarter, quarter+3, 0, half-1], first=2)
        add([0, quarter, quarter+3, 0, half-1], first=(1 << max_fft)-5)
        for phases in ([0, 8], [0, 24], [8, 0], [24, 0]):
            add(phases, fft=4)
        rng = random.Random(4602+p)
        for _ in range(8):
            n = rng.randint(2, maximum)
            add([rng.randrange(modulus) for _ in range(n)], first=rng.randrange((1 << max_fft)-n+1))
    # Full 32-bit config validation includes a 33-bit first+count overflow case.
    for count, first, fft in ((0, 0, max_fft), (1, 0, max_fft), (maximum+1, 0, max_fft),
                              (0xffffffff, 0, max_fft), (2, 0xffffffff, max_fft),
                              (2, 15, 4), (2, 0, 3), (2, 0, max_fft+1), (2, 0, 0xffffffff)):
        add([], count=count, first=first, fft=fft)
    add([0], count=3, last=[1])
    add([0, quarter, 0], count=3, last=[0, 0, 0])
    add([0], count=3, last=[1], invalid=[1])
    add([0, quarter], count=3, last=[0, 0], invalid=[0, 1])
    assert len(cases) == (25 if adapter else 39)
    vectors = ((1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1))
    for number, (count, first, fft, samples) in enumerate(cases):
        status = 0
        received = 0
        if not (2 <= count <= maximum and 4 <= fft <= max_fft and first+count <= 1 << fft):
            status = 1
        else:
            for index, (_, last, invalid) in enumerate(samples):
                received += 1
                if invalid:
                    status = 3
                    break
                if last != int(index == count-1):
                    status = 2
                    break
            assert status or received == count
        result = (0, 0, 0, 0, 0) if status else fit([s[0] for s in samples], p, fft)
        tag = (0xffffffff-number*65537) & ((1 << tag_width)-1)
        # Hex encoding preserves full signed outputs at their public widths.
        l = (maximum-1).bit_length()
        cw = maximum.bit_length()
        bw, cwide, dw = p+3*l+cw+2, 2*p+3*l+cw+1, 3*l+cw+1
        rw = max(cwide+dw, 2*bw)+1
        widths = (max_fft+17, bw, cwide, dw, rw)
        yield ' '.join([f'{count:x}', f'{first:x}', f'{fft:x}', f'{tag:x}', str(status), str(received),
                        *(f'{value & ((1 << width)-1):x}' for value, width in zip(result, widths)), str(len(samples))])
        for phase, last, invalid in samples:
            if adapter:
                i, q = (0, 0) if invalid else vectors[phase//(modulus//8)]
                # Maximum positive vector exercises sign extension; diagonal ratios remain exact.
                amplitude = (1 << (input_width-1))-1
                yield f'{(i*amplitude) & ((1 << input_width)-1):x} {(q*amplitude) & ((1 << input_width)-1):x} {last} {invalid}'
            else:
                yield f'{phase:x} 0 {last} {invalid}'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=PROFILES, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    adapter, p, maximum, tag, max_fft, iterations, _ = PROFILES[args.profile]
    count = 25 if adapter else 39
    data = (str(count)+'\n'+'\n'.join(cases_for(args.profile))+'\n').encode('ascii')
    l = (maximum-1).bit_length()
    cw = maximum.bit_length()
    bw, cwide, dw = p+3*l+cw+2, 2*p+3*l+cw+1, 3*l+cw+1
    mw = max(bw, cwide, dw)+1
    h = mw+(2*mw+7)//8
    tail = 10*h+bw+max_fft+16+23+(iterations+2 if adapter else 0)
    expected = dict(cases=count, holds=count*4, reset_fixtures=7+adapter, recovery_outputs=7+adapter,
                    recovery_holds=4*(7+adapter), future_outputs=2, future_holds=8,
                    PHASE=p, MAX=maximum, TAG=tag, ADAPTER=adapter, ITER=iterations, tail=tail)
    args.output.mkdir(exist_ok=False)
    (args.output/'vectors.txt').write_bytes(data)
    receipt = dict(schema='anscore-b46-b-pairwise-preparation-v1', profile=args.profile,
                   files={'vectors.txt': dict(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data), rows=len(data.splitlines())-1)},
                   cases=count, expected_counters=expected, numerical_preparations=1, oracle_definition_loads=1)
    (args.output/'preparation.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
    print('B46_B_PREP_PASS '+' '.join(f'{key}={value}' for key, value in expected.items()))


if __name__ == '__main__':
    main()
