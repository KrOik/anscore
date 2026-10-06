"""Generate independent integer FFT vectors; never consume simulation output."""
import argparse
import json
import random
from pathlib import Path
from golden_model import fft64, fft_stim, fft_digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    rng = random.Random(0xFF764)  # fixed replay seed
    vectors = [(fft_stim(v), [0] * 64) for v in range(4)]
    edges = [-32768, -32767, -1, 0, 1, 32766, 32767]
    vectors += [([a] * 64, [b] * 64) for a in edges for b in edges]
    vectors += [([edges[(n + v) % 7] for n in range(64)],
                 [edges[(3 * n + v) % 7] for n in range(64)]) for v in range(7)]
    vectors += [([rng.randint(-32768, 32767) for _ in range(64)],
                 [rng.randint(-32768, 32767) for _ in range(64)]) for _ in range(68)]
    assert len(vectors) == 128
    assert fft_digest()[0] == 0x53D1DDAF
    inputs, outputs = [], []
    for re, im in vectors:
        ore, oim = fft64(re, im)
        inputs.extend(f'{r & 65535:04x}{i & 65535:04x}' for r, i in zip(re, im))
        outputs.extend(f'{r & 65535:04x}{i & 65535:04x}' for r, i in zip(ore, oim))
    (args.output / 'fft_input.mem').write_text('\n'.join(inputs) + '\n', encoding='ascii')
    (args.output / 'fft_expected.mem').write_text('\n'.join(outputs) + '\n', encoding='ascii')
    selected = [0, 1, 2, 3, 4, 52, 60, 127]
    board_inputs, frames, input_frames = [], bytearray(), bytearray()
    for v, source in enumerate(selected):
        board_inputs.extend(inputs[source * 64:(source + 1) * 64])
        input_frames.extend(b'FFT' + bytes([v, 0, 0, 0, 0xa5]))
        for word in inputs[source * 64:(source + 1) * 64]:
            input_frames.extend(bytes.fromhex(word))
        frames.extend(b'FFT' + bytes([v, 3, 0, 0, 0xa5]))
        for word in outputs[source * 64:(source + 1) * 64]:
            frames.extend(bytes.fromhex(word))
    (args.output / 'fft_board_input.mem').write_text('\n'.join(board_inputs) + '\n', encoding='ascii')
    (args.output / 'fft_board_expected.bin').write_bytes(frames)
    (args.output / 'fft_input_readback_expected.bin').write_bytes(input_frames)
    (args.output / 'fft_board_expected.mem').write_text(''.join(f'{b:02x}\n' for b in frames), encoding='ascii')
    (args.output / 'vectors.json').write_text(json.dumps({
        'vectors': len(vectors), 'bins_per_vector': 64, 'seed': 0xFF764,
        'legacy_digest': '53D1DDAF', 'model': 'golden_model.fft64',
        'coverage': ['legacy', 'constant complex extrema', 'alternating extrema',
                     'seeded full-range complex random']}, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
