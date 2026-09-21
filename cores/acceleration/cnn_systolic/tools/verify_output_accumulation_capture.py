"""Strict fixed-frame CNN output-layer / legacy UART capture verifier."""
import argparse
import json
import re
from pathlib import Path


def verify(data, expected):
    size = len(expected)
    if size not in (38, 544):
        raise ValueError('Unexpected golden frame size')
    start = data.find(expected[:4])
    if start < 0 or start >= size:
        raise ValueError('No complete frame synchronization')
    pos, count = start, 0
    while pos + size <= len(data):
        frame = data[pos:pos + size]
        if frame != expected:
            bad = next(i for i in range(size) if frame[i] != expected[i])
            raise ValueError(f'Frame {count}, byte {bad}: got {frame[bad]:02X}, expected {expected[bad]:02X}')
        count += 1
        pos += size
    if count == 0 or data[pos:] != expected[:len(data) - pos]:
        raise ValueError('Incomplete coverage or corrupt trailing fragment')
    return dict(status='PASS', complete_frames=count, bytes_per_frame=size,
                full_rate=(size == 38), ignored_leading_bytes=start,
                checked_trailing_bytes=len(data) - pos)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('annotations', type=Path)
    parser.add_argument('--expected', type=Path, required=True)
    parser.add_argument('--pages', type=int, default=2)
    args = parser.parse_args()
    data = bytearray()
    for line in args.annotations.read_text(encoding='utf-8-sig').splitlines():
        if line.startswith('uart-1: '):
            token = line[8:].strip()
            if not re.fullmatch('[0-9a-fA-F]{2}', token):
                raise ValueError('Expected sigrok hex annotation')
            data.append(int(token, 16))
    expected = args.expected.read_bytes()
    args.annotations.with_suffix('.bin').write_bytes(data)
    try:
        result = verify(data, expected)
    except ValueError as exc:
        args.annotations.with_suffix('.verdict.json').write_text(json.dumps(dict(status='FAIL', reason=str(exc)), indent=2))
        raise
    bad = bytearray(expected * 2)
    bad[10] ^= 1
    try:
        verify(bad, expected)
    except ValueError:
        result['negative_payload_test'] = 'PASS'
    else:
        raise AssertionError('Corruption accepted')
    if len(expected) == 38:
        result['signed_values_checked'] = result['complete_frames'] * 16
        result['configuration'] = f'27 MHz, CPO=1, CPI=3, PAGES={args.pages}, COLS=2'
    else:
        result['golden_report'] = expected.decode('ascii')
    args.annotations.with_suffix('.verdict.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
