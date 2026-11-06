"""Independent full-tensor integer oracle. No RTL/FSM or historical imports."""
from pathlib import Path
import argparse, hashlib, json

def nearest_even(value, shift):
    quotient, remainder = divmod(value, 1 << shift)
    half = (1 << shift) >> 1
    if shift and (remainder > half or (remainder == half and quotient % 2)):
        quotient += 1
    return quotient, bool(remainder)

def tensor_result(image, width, height, channels, kernels, xzero):
    result = []
    for y in range(height - 2):
        for x in range(width - 2):
            for c, (weights, bias, scale, shift, zero) in enumerate(kernels):
                total = bias + sum(
                    (image[((y + dy) * width + x + dx) * channels + c] - xzero)
                    * weights[dy * 3 + dx] for dy in range(3) for dx in range(3))
                rounded, inexact = nearest_even(total * scale, shift)
                raw = rounded + zero
                result.append((max(-128, min(127, raw)) & 255,
                               int(raw < -128 or raw > 127), int(inexact), x, y, c,
                               int(x == 0 and y == 0 and c == 0),
                               int(x == width - 3 and c == channels - 1),
                               int(x == width - 3 and y == height - 3 and c == channels - 1)))
    return result

def prepare(output, max_channels, width, height, tag_width, rgb):
    lines = ['6']
    counts = dict(frames=6, inputs=0, outputs=0, configurations=0)
    per_frame = []
    for case in range(6):
        # Reconfigure geometry/channel stride between frames without RAM clear.
        w = width if case in (0, 1, 2, 4) else 3
        h = height if case in (0, 1, 2, 4) else 3
        cnum = 3 if rgb else (max_channels if case in (0, 1, 2, 4) else 1)
        xzero = [128, 255, 0, 128, 255, 17][case]
        tag = (37 + case * 53) & ((1 << tag_width) - 1)
        bad = int(case == 3)
        kernels = []
        for c in range(cnum):
            weights = [0] * 9
            if case == 0:
                weights[4] = 1
                bias, scale, shift, zero = 0, 1, 0, 0
            elif case == 1:
                weights = [((c * 7 + tap * 5 + 3) % 16) - 8 for tap in range(9)]
                bias, scale, shift, zero = c * 29 - 71, 3 + c, 7, 3 - c
            elif case == 2:
                bias, scale, shift, zero = [1, 3, -1, -3][c % 4], 1, 1, 3
            elif case == 3:
                bias, scale, shift, zero = -3, 1, 1, -3
            elif case == 4:
                weights = [-8 if (c + tap) % 2 else 7 for tap in range(9)]
                bias, scale, shift, zero = (-2147483648 if c % 2 else 2147483647), 65535, 0, (-128 if c % 2 else 127)
            else:
                weights = [-8] * 9
                bias, scale, shift, zero = -2147483648, 0, 31, 127 - c
            kernels.append((weights, bias, scale, shift, zero))
        image = [(i * 73 + (i // cnum) * 19 + case * 47 + (i % cnum) * 101) % 256
                 for i in range(w * h * cnum)]
        expected = tensor_result(image, w, h, cnum, kernels, xzero)
        lines.append('%d %d %d %d %d %d %d %d' % (w, h, cnum, xzero, tag, bad, len(image), len(expected)))
        for weights, bias, scale, shift, zero in kernels:
            packed = sum((value & 15) << (4 * tap) for tap, value in enumerate(weights))
            lines.append('%08x %08x %08x %d %d %02x' % (packed & 0xffffffff, packed >> 32, bias & 0xffffffff, scale, shift, zero & 255))
        lines.extend('%02x' % value for value in image)
        lines.extend('%02x %d %d %d %d %d %d %d %d' % row for row in expected)
        counts['inputs'] += len(image) // (3 if rgb else 1)
        counts['outputs'] += len(expected) // (3 if rgb else 1)
        counts['configurations'] += 3 * cnum
        per_frame.append(dict(case=case, width=w, height=h, channels=cnum, tag=tag,
                              error=3 if bad else 0, scalar_inputs=len(image), scalar_outputs=len(expected)))
    raw = ('\n'.join(lines) + '\n').encode('ascii')
    output.write_bytes(raw)
    summary = dict(parameters=dict(channels=max_channels,width=width,height=height,tag=tag_width,rgb=rgb),
                   counts=counts, per_frame=per_frame, vector_sha256=hashlib.sha256(raw).hexdigest(),
                   model_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   expected_runtime=dict(frames=6, inputs=counts['inputs'], outputs=counts['outputs']),
                   numerical_model_calls=6, historical_imports=0)
    output.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2)+'\n', encoding='utf-8', newline='\n')
    print('PASS prepare_depthwise', json.dumps(counts, sort_keys=True))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--channels', type=int, required=True)
    parser.add_argument('--width', type=int, required=True)
    parser.add_argument('--height', type=int, required=True)
    parser.add_argument('--tag', type=int, required=True)
    parser.add_argument('--rgb', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not (1 <= args.channels <= 16 and 3 <= args.width <= 1024 and 3 <= args.height <= 1024 and 1 <= args.tag <= 32):
        raise SystemExit('unsupported finite profile')
    if args.rgb and args.channels != 3:
        raise SystemExit('RGB profile requires channels three')
    prepare(args.output, args.channels, args.width, args.height, args.tag, args.rgb)
