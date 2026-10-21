"""Independent stimulus/oracle and strict SSF1 raw-result capture verification."""
import argparse
import json
from pathlib import Path
import re

def fixture(depth):
    stimulus, results = [], bytearray()
    for frame in range(4):
        sums = [[0, 0] for _ in range(depth)]
        for row in range(3):
            stimulus.append(1 << 32)  # Row marker, no valid data.
            for col in range(depth):
                lanes = [(frame*73 + row*37 + col*19 + lane*53) % 256 for lane in range(2)]
                stimulus.append((1 << 33) | lanes[0] | (lanes[1] << 8))
                for lane, value in enumerate(lanes):
                    sums[col][lane] += value if value < 128 else value - 256
        for pair in sums:
            for value in pair:
                results.extend((value & 65535).to_bytes(2, 'little'))
    return stimulus, results

def golden():
    return b'SSF1\x00\x18' + fixture(1)[1] + fixture(2)[1]

def verify(data):
    expected = golden()
    size = len(expected)
    start = data.find(b'SSF1')
    if not 0 <= start < size:
        raise ValueError('Missing frame synchronization')
    if start and data[:start] != expected[-start:]:
        raise ValueError('Corrupt leading fragment')
    count = 0
    pos = start
    while pos + size <= len(data):
        if data[pos:pos+size] != expected:
            bad = next(i for i in range(size) if data[pos+i] != expected[i])
            raise ValueError(f'Frame {count}, byte {bad}: got {data[pos+bad]:02X}, expected {expected[bad]:02X}')
        pos += size
        count += 1
    if not count or data[pos:] != expected[:len(data)-pos]:
        raise ValueError('No complete frame or corrupt trailing fragment')
    return dict(status='PASS', frames=count, signed_values=count*24, depths=[1,2],
                leading_bytes=start, trailing_bytes=len(data)-pos)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--generate',type=Path)
    p.add_argument('--capture',type=Path)
    p.add_argument('--self-test',action='store_true')
    a=p.parse_args()
    if a.generate:
        a.generate.mkdir(parents=True,exist_ok=False)
        for depth in (1,2):
            words,_=fixture(depth)
            (a.generate/f'spatial_d{depth}.mem').write_text(''.join(f'{w:09x}\n' for w in words))
        (a.generate/'expected.bin').write_bytes(golden())
        (a.generate/'expected.mem').write_text(''.join(f'{b:02x}\n' for b in golden()))
    if a.self_test:
        g=golden()
        for offset in range(len(g)):
            verify((g*5)[offset:offset+len(g)*3])
        for offset in range(len(g)):
            bad=bytearray(g*2);bad[offset]^=1
            try: verify(bytes(bad))
            except ValueError: pass
            else: raise AssertionError('Corruption accepted')
        print('PASS SSF1 checker: all 54 offsets and 54 corrupted-byte positions')
    if a.capture:
        tokens=[]
        for line in a.capture.read_text(encoding='utf-8-sig').splitlines():
            if line.startswith('uart-1: '):
                token=line[8:].strip()
                if not re.fullmatch('[0-9a-fA-F]{2}',token): raise ValueError('Expected hex annotations')
                tokens.append(int(token,16))
        data=bytes(tokens)
        a.capture.with_suffix('.bin').write_bytes(data)
        try: result=verify(data)
        except ValueError as exc:
            a.capture.with_suffix('.verdict.json').write_text(json.dumps(dict(status='FAIL',reason=str(exc)),indent=2))
            raise
        a.capture.with_suffix('.verdict.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result))

if __name__=='__main__': main()
