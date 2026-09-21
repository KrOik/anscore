"""Verify every complete CIG1 UART frame and any captured edge fragments."""
import argparse
import json
import re
from pathlib import Path

def verify(data, expected):
    size = 166
    if len(expected) != size or expected[:6] != b'CIG1\x50\x00':
        raise ValueError('Invalid expected frame')
    start = data.find(b'CIG1')
    if not 0 <= start < size:
        raise ValueError('Missing frame synchronization')
    if start and data[:start] != expected[-start:]:
        raise ValueError('Corrupt leading fragment')
    pos, count = start, 0
    while pos + size <= len(data):
        if data[pos:pos+size] != expected:
            raise ValueError(f'Frame {count} mismatch')
        count += 1
        pos += size
    if not count or data[pos:] != expected[:len(data)-pos]:
        raise ValueError('No complete frame or corrupt trailing fragment')
    return dict(status='PASS', complete_frames=count, convolution_bytes=count*160,
                leading_fragment_bytes=start, trailing_fragment_bytes=len(data)-pos)

def self_test(expected):
    for offset in range(166):
        verify((expected*4)[offset:offset+400], expected)
    for index in (4, 5, 6, 165, 200):
        bad = bytearray(expected*2)
        bad[index] ^= 1
        try:
            verify(bytes(bad), expected)
        except ValueError:
            pass
        else:
            raise AssertionError(f'Corruption accepted at {index}')
    for bad in (b'', expected[:100], expected + expected[1:]):
        try:
            verify(bad, expected)
        except ValueError:
            pass
        else:
            raise AssertionError('Truncated/dropped-byte stream accepted')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('annotations', type=Path, nargs='?')
    parser.add_argument('--expected', type=Path, required=True)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    expected = args.expected.read_bytes()
    self_test(expected)
    if args.self_test and args.annotations is None:
        print('PASS CIG1 verifier: all 166 offsets and corrupt/drop/truncation cases')
        return
    if args.annotations is None:
        parser.error('annotations required unless --self-test')
    data = bytearray()
    for line in args.annotations.read_text(encoding='utf-8-sig').splitlines():
        if line.startswith('uart-1: '):
            token = line[8:].strip()
            if not re.fullmatch(r'[0-9a-fA-F]{2}', token):
                raise ValueError('Expected sigrok hex annotations')
            data.append(int(token, 16))
    args.annotations.with_suffix('.bin').write_bytes(data)
    try:
        result = verify(bytes(data), expected)
    except ValueError as exc:
        args.annotations.with_suffix('.verdict.json').write_text(json.dumps(dict(status='FAIL', reason=str(exc))))
        raise
    args.annotations.with_suffix('.verdict.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result))

if __name__ == '__main__':
    main()
