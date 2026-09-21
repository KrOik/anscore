"""Independent sum-over-input-slots fixture for the CPO=1 CNN output layer."""
import argparse
from pathlib import Path
from gen_uart_golden import build


def stimulus(pixel, ci, col, page):
    return (pixel * 11 + ci * 5 + col * 3 + page * 13) % 31 - 15


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pages', type=int, default=2)
    args = parser.parse_args()
    if args.pages < 1:
        parser.error('--pages must be positive')
    args.output.mkdir(parents=True, exist_ok=False)
    words = []
    for t in range(64):
        word = 0
        for page in range(args.pages):
            for col in range(2):
                s = t - 5 - col
                value = stimulus(s // 3, s % 3, col, page) if 0 <= s < 24 else 0
                word |= (value & 65535) << (16 * (page * 2 + col))
        words.append(f'{word:0{args.pages * 8}x}')
    frame = bytearray(b'COL1\x08\x00')
    for pixel in range(8):
        for col in [1, 0]:
            value = sum(stimulus(pixel, ci, col, page) for ci in range(3) for page in range(args.pages))
            frame.extend((value & 65535).to_bytes(2, 'big'))
    (args.output / 'accumulation_input.mem').write_text('\n'.join(words) + '\n', encoding='ascii')
    (args.output / 'accumulation_bias.mem').write_text('0000000000000000\n' * 2, encoding='ascii')
    (args.output / 'accumulation_expected.bin').write_bytes(frame)
    (args.output / 'accumulation_expected.mem').write_text(''.join(f'{b:02x}\n' for b in frame), encoding='ascii')
    full_report = build(unit_en=0xffff).encode('ascii')
    (args.output / 'cnn_all_expected.mem').write_text(''.join(f'{b:02x}\n' for b in full_report), encoding='ascii')
    (args.output / 'cnn_legacy_expected.bin').write_bytes(build(unit_en=0x1800).encode('ascii'))


if __name__ == '__main__':
    main()
