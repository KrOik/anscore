"""Original direct scatter oracle and separately packed phase configuration.

SOURCE ONLY until root reviews this file, RTL, TB and the exact finite plan.
No import of any existing oracle, runner or HDL model.
"""
from pathlib import Path
import argparse, hashlib, json

PROFILES = {
    'tiny': (1, 1, 1, 1, 1, False),
    'rgb': (3, 3, 7, 5, 8, False),
    'limits': (16, 16, 1023, 1023, 32, False),
    'example': (3, 3, 7, 5, 8, True),
}


def quantize(value, scale, shift, zero):
    product = value * scale
    quotient, remainder = divmod(abs(product), 1 << shift)
    if remainder * 2 > (1 << shift) or (remainder * 2 == (1 << shift) and quotient & 1):
        quotient += 1
    rounded = -quotient if product < 0 else quotient
    translated = rounded + zero
    return max(-128, min(127, translated)), int(translated < -128 or translated > 127), int(remainder != 0)


def scatter(width, height, ci, co, xzero, values, kernel, metadata):
    # This oracle does not gather neighbours or emit phase matrices.
    ow, oh = 2 * width + 1, 2 * height + 1
    accum = [metadata[o][0] for _ in range(ow * oh) for o in range(co)]
    for y in range(height):
        for x in range(width):
            for i in range(ci):
                v = values[(y * width + x) * ci + i] - xzero
                for ky in range(3):
                    for kx in range(3):
                        base = ((2 * y + ky) * ow + 2 * x + kx) * co
                        for o in range(co):
                            accum[base + o] += v * kernel[ky][kx][i][o]
    return [quantize(a, *metadata[n % co][1:]) for n, a in enumerate(accum)]


def pack_configuration(ci, co, kernel, metadata):
    taps = (((0, 0), (0, 2), (2, 0), (2, 2)),
            ((0, 1), None, (2, 1), None),
            ((1, 0), (1, 2), None, None),
            ((1, 1), None, None, None))
    records = []
    for phase in range(4):
        for o in range(co):
            row = phase * co + o
            weights = [0 if tap is None else kernel[tap[0]][tap[1]][i][o]
                       for tap in taps[phase] for i in range(ci)]
            for word in range((4 * ci + 7) // 8):
                packed = sum((weights[k] & 15) << (4 * j)
                             for j in range(8) if (k := word * 8 + j) < len(weights))
                records.append((0, row, word, packed, 0, 0, 0, 0))
            records.append((1, row, 0, 0, *metadata[o]))
    return records


def make_case(number, width, height, ci, co, tag, mode='mixed', xzero=123,
              clear=1, expected_error=0, fault_index=-1, fault_mask=0, keep_model=None, rgb=False):
    values = [(n * 73 + number * 19 + 11) & 255 for n in range(width * height * ci)]
    kernel = [[[[((ky * 7 + kx * 11 + i * 3 + o * 5 + number) % 16) - 8
                 for o in range(co)] for i in range(ci)] for kx in range(3)] for ky in range(3)]
    metadata = [(o * 7 - 17, 3 + o, 3 + o % 4, o - 3) for o in range(co)]
    if mode == 'nine_taps':
        kernel = [[[[ky * 3 + kx - 4 for _ in range(co)] for _ in range(ci)]
                   for kx in range(3)] for ky in range(3)]
        values = [xzero + 1 for _ in values]
        metadata = [(0, 1, 0, 0) for _ in range(co)]
    elif mode in ('tie_positive', 'tie_negative'):
        values = [xzero for _ in values]
        metadata = [(3 if mode == 'tie_positive' else -3, 1, 1, 1 if o % 2 == 0 else -1) for o in range(co)]
    elif mode == 'extreme':
        metadata = [(-2147483648 if o % 2 else 2147483647, 65535, 31, -128 if o % 2 else 127) for o in range(co)]
    elif mode == 'zero_scale':
        metadata = [(-2147483648 + o, 0, 0, 127 - o) for o in range(co)]
    if keep_model is not None:
        kernel, metadata = keep_model
    output = scatter(width, height, ci, co, xzero, values, kernel, metadata)
    config = [] if keep_model is not None else pack_configuration(ci, co, kernel, metadata)
    public_input = [tuple(values[k:k + 3]) for k in range(0, len(values), 3)] if rgb else values
    if rgb:
        public_input = [(r << 16) | (g << 8) | b for r, g, b in public_input]
        public_output = []
        for n in range(0, len(output), 3):
            group = output[n:n + 3]
            data = sum(((group[c][0] + 128) & 255) << (8 * (2 - c)) for c in range(3))
            clip = sum(group[c][1] << (2 - c) for c in range(3))
            inexact = sum(group[c][2] << (2 - c) for c in range(3))
            public_output.append((data, clip, inexact))
    else:
        public_output = output
    if fault_index >= 0:
        public_input = public_input[:fault_index + 1]
    return dict(number=number, width=width, height=height, ci=ci, co=co, xzero=xzero, tag=tag,
                error=expected_error, fault_index=fault_index, fault_mask=fault_mask,
                clear=clear, config=config, inputs=public_input, outputs=public_output,
                model=(kernel, metadata), mode=mode)


def build(profile):
    mc, mo, mw, mh, tagw, rgb = PROFILES[profile]
    ci, co = (3, 3) if rgb else (1, 1)
    cases = []
    missing = dict(number=0, width=1, height=1, ci=ci, co=co, xzero=0, tag=0,
                   error=2, fault_index=-1, fault_mask=0, clear=1, config=[], inputs=[], outputs=[], mode='missing')
    cases.append(missing)
    first = make_case(1, 1, 1, ci, co, 1, 'nine_taps', rgb=rgb)
    cases.append(first)
    ci, co = (3, 3) if rgb else (min(3, mc), min(3, mo))
    w, h = min(7, mw), min(3, mh)
    mixed = make_case(2, w, h, ci, co, 2 & ((1 << tagw) - 1), rgb=rgb)
    cases.append(mixed)
    cases.append(make_case(3, w, h, ci, co, 3 & ((1 << tagw) - 1), xzero=255,
                           clear=0, keep_model=mixed['model'], rgb=rgb))
    for mode in ('tie_positive', 'tie_negative', 'extreme', 'zero_scale'):
        n = len(cases)
        cases.append(make_case(n, w, h, ci, co, n & ((1 << tagw) - 1), mode, xzero=0 if n & 1 else 255, rgb=rgb))
    n = len(cases)
    # The first scalar/pixel of row2 tests the output-retirement fence where available.
    fault = (w if rgb else w * ci) if h > 1 else 0
    cases.append(make_case(n, w, h, ci, co, n & ((1 << tagw) - 1), expected_error=3,
                           fault_index=fault, fault_mask=1, rgb=rgb))
    for field, value in (('width', 0), ('width', 65535), ('ci', 32768)):
        n = len(cases);bad = dict(missing, number=n, tag=n & ((1 << tagw) - 1), error=1, clear=0, mode='invalid_' + field)
        bad[field] = value
        # RGB's public command fixes channels; exercise height alias instead.
        if rgb and field == 'ci':
            bad['ci'] = 3;bad['co'] = 3;bad['height'] = 65535
        cases.append(bad)
    if profile == 'limits':
        n = len(cases);cases.append(make_case(n, 1023, 1, 1, 1, n, xzero=231))
        n = len(cases);cases.append(make_case(n, 1, 1, 16, 16, 0xfedcba98, xzero=129))
        n = len(cases);cases.append(make_case(n, 5, 3, 5, 3, 0x80000001, xzero=7))
    return cases


def main():
    parser = argparse.ArgumentParser();parser.add_argument('--profile', choices=PROFILES, required=True)
    parser.add_argument('--out', type=Path, required=True);args = parser.parse_args()
    cases = build(args.profile)
    lines = ['1163462213 ' + str(len(cases))]
    for c in cases:
        header = [c[k] for k in ('number','width','height','ci','co','xzero','tag','error','fault_index','fault_mask','clear')]
        header += [len(c['config']),len(c['inputs']),len(c['outputs'])]
        lines.append(' '.join(map(str,header)))
        lines.extend(' '.join(map(str,record)) for record in c['config'])
        lines.extend(str(v) for v in c['inputs'])
        lines.extend(' '.join(map(str,v)) for v in c['outputs'])
    data = ('\n'.join(lines)+'\n').encode('ascii')
    args.out.parent.mkdir(parents=True,exist_ok=True)
    with args.out.open('xb') as stream:stream.write(data)
    summary = dict(profile=args.profile, cases=len(cases), file=str(args.out), bytes=len(data),
                   sha256=hashlib.sha256(data).hexdigest(),
                   direct_scatter_evaluations=sum('model' in c for c in cases),
                   input_units=sum(len(c['inputs']) for c in cases),
                   full_oracle_output_units=sum(len(c['outputs']) for c in cases),
                   numerical_reference='direct-scatter integer; no RTL or historical-model import')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
