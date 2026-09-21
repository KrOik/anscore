"""Independent fixed 8x6 convolution oracle and board stimulus."""
import argparse
from pathlib import Path

def generate(out):
    out.mkdir(parents=True, exist_ok=False)
    stimulus = []
    for y in range(6):
        stimulus.append(1 << 17)
        for x in range(8):
            stimulus.extend([0, 0, (1 << 16) | ((3*(x+1)+7*y+2) << 8) | (x+1+8*y)])
        stimulus.extend([0]*32)
    stimulus.extend([0]*(512-len(stimulus)))
    (out/'input_gap_stimulus.mem').write_text(''.join(f'{v:05x}\n' for v in stimulus))
    frame = bytearray(b'CIG1' + bytes([80, 0]))
    for y in range(5):
        for x in range(8):
            acc = 8
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    iy, ix = y+dy, x+dx
                    if 0 <= iy < 6 and 0 <= ix < 8:
                        acc += ix+1+8*iy + 3*(ix+1)+7*iy+2
            value = min(255, (acc >> 4) + ((acc >> 3) & 1))
            frame.extend([value]*4)  # two columns, two output slots
    (out/'input_gap_expected.bin').write_bytes(frame)
    (out/'input_gap_expected.mem').write_text(''.join(f'{v:02x}\n' for v in frame))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    generate(parser.parse_args().output)
