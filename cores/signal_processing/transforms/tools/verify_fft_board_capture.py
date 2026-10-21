"""Validate sigrok UART hex annotations against independently generated bins."""
import argparse
import json
import re
from pathlib import Path


def verify(data, expected):
    if len(expected) != 8 * 264:
        raise ValueError('Invalid golden frame length')
    first = data.find(b'FFT')
    if first < 0 or first >= 264:
        raise ValueError('No FFT frame header')
    counts = [0] * 8
    previous = None
    pos = first
    while pos + 264 <= len(data):
        frame = data[pos:pos + 264]
        if frame[:3] != b'FFT' or frame[3] >= 8:
            raise ValueError(f'Invalid frame at byte {pos}')
        v = frame[3]
        if previous is not None and v != (previous + 1) % 8:
            raise ValueError('Missing or reordered vector')
        if frame != expected[v * 264:(v + 1) * 264]:
            raise ValueError(f'Bin, latency or status mismatch in vector {v}')
        counts[v] += 1
        previous = v
        pos += 264
    if not all(counts):
        raise ValueError(f'Incomplete coverage: {counts}')
    # A partial final frame must match the expected prefix as well.
    tail = data[pos:]
    next_v = (previous + 1) % 8
    if tail != expected[next_v * 264:next_v * 264 + len(tail)]:
        raise ValueError('Corrupt trailing fragment')
    return {'status': 'PASS', 'frames_per_vector': counts,
            'complete_frames': sum(counts), 'complex_bins_checked': sum(counts) * 64,
            'cycles_per_vector': int.from_bytes(expected[4:6], 'big'), 'clock_mhz': 27,
            'ignored_leading_bytes': first, 'checked_trailing_bytes': len(tail)}


def verify_legacy(data, expected):
    if len(expected) != 160 or not expected.startswith(b'SIG4'):
        raise ValueError('Invalid legacy golden report')
    first = data.find(b'SIG4')
    if first < 0 or first >= 160:
        raise ValueError('No legacy report header')
    count, pos = 0, first
    while pos + 160 <= len(data):
        if data[pos:pos + 160] != expected:
            raise ValueError(f'Legacy UART report mismatch at byte {pos}')
        pos += 160
        count += 1
    if not count or data[pos:] != expected[:len(data) - pos]:
        raise ValueError('Missing complete report or corrupt final fragment')
    return {'status': 'PASS', 'complete_reports': count,
            'golden_report': expected.decode('ascii'),
            'ignored_leading_bytes': first, 'checked_trailing_bytes': len(data) - pos}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('annotations', type=Path)
    parser.add_argument('--expected', type=Path, required=True)
    parser.add_argument('--enable-div', type=int, choices=[1, 16], default=1)
    parser.add_argument('--legacy', action='store_true')
    args = parser.parse_args()
    raw = bytearray()
    for line in args.annotations.read_text(encoding='utf-8-sig').splitlines():
        if line.startswith('uart-1: '):
            token = line[8:].strip()
            if not re.fullmatch(r'[0-9a-fA-F]{2}', token):
                raise ValueError(f'Unexpected UART hex annotation {token!r}')
            raw.append(int(token, 16))
    expected = (bytes(int(line, 16) for line in args.expected.read_text().split())
                if args.legacy else args.expected.read_bytes())
    checker = verify_legacy if args.legacy else verify
    args.annotations.with_suffix('.bin').write_bytes(raw)
    try:
        result = checker(bytes(raw), expected)
    except ValueError as exc:
        args.annotations.with_suffix('.verdict.json').write_text(
            json.dumps({'status': 'FAIL', 'reason': str(exc)}, indent=2), encoding='utf-8')
        raise
    if args.legacy:
        result['fft_enable_divisor'] = 16
    else:
        result['enable_divisor'] = args.enable_div
    result['full_rate'] = not args.legacy and args.enable_div == 1
    # Prove that a bad complete payload cannot pass the same verifier.
    bad = bytearray(expected * 2)
    bad[30] ^= 1
    try:
        checker(bytes(bad), expected)
    except ValueError:
        result['negative_payload_test'] = 'PASS'
    else:
        raise AssertionError('Checker accepted corrupted payload')
    args.annotations.with_suffix('.verdict.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
