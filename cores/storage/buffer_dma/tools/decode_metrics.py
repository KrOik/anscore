"""Decode schema-v1 CSR dumps; no physical transport or board qualification implied."""
import argparse
import json
import math
from pathlib import Path


def uint(value, bits):
    if type(value) is not int or not 0 <= value < 1 << bits:
        raise ValueError(f'expected unsigned {bits}-bit integer')
    return value


def validate(capture):
    if capture['schema'] != 'buffer_dma_metrics_v1':
        raise ValueError('unsupported schema')
    if capture['source_kind'] not in ('simulation', 'board') or not isinstance(capture['epoch_id'], str) or not capture['epoch_id']:
        raise ValueError('missing capture provenance/reset epoch')
    hz = capture['clock_hz']
    if type(hz) not in (int, float) or not math.isfinite(hz) or hz <= 0:
        raise ValueError('clock_hz must be finite and positive')
    before = uint(capture['snapshot_id_before'], 32)
    if before != uint(capture['snapshot_id_after'], 32) or capture['captured'] is not True:
        raise ValueError('incoherent or uncaptured snapshot')
    uint(capture['timestamp'], 64)
    words = capture['words']
    if len(words) != 51:
        raise ValueError('expected exactly 51 metric words')
    for word in words:
        uint(word, 32)
    if words[50] > 4:
        raise ValueError('invalid occupancy peak')
    return words


def decode(capture, previous=None):
    w = validate(capture)
    result = {'schema': capture['schema'], 'source_kind': capture['source_kind'],
        'epoch_id': capture['epoch_id'], 'snapshot_id': capture['snapshot_id_before'],
        'timestamp': capture['timestamp'], 'clock_hz': capture['clock_hz'],
        'published': w[0], 'released': w[1], 'aborted': w[2], 'invalid_requests': w[3],
        'elapsed_cycles': w[48], 'allocation_wait_cycles': w[49], 'peak_occupied': w[50],
        'streams': [], 'memory': [], 'slot_latency': []}
    for c, name in enumerate(('input0', 'input1', 'output0', 'output1')):
        result['streams'].append({'name': name, 'bytes': w[16+c], 'last_beats': w[20+c],
            'stall_cycles': w[24+c], 'crc32': f'{w[28+c]:08X}',
            'last_frame_cycles': w[32+c], 'last_frame_crc32': f'{w[36+c]:08X}'})
        result['memory'].append({'master': c, 'requests': w[4+c],
            'completions': w[8+c], 'stall_cycles': w[12+c]})
    for c in range(2):
        result['slot_latency'].append({'consumer': c, 'last_cycles': w[40+c],
            'min_cycles': None if w[42+c] == 0xffffffff else w[42+c],
            'max_cycles': w[44+c], 'sum_cycles_mod32': w[46+c]})
    if previous is not None:
        p = validate(previous)
        for field in ('epoch_id', 'source_kind', 'clock_hz'):
            if capture[field] != previous[field]:
                raise ValueError('interval crosses reset epoch, source, or clock change')
        dt = capture['timestamp'] - previous['timestamp']
        # Accepted byte counters can advance by up to four per clock. Longer
        # intervals cannot distinguish zero/one/multiple 32-bit counter wraps.
        if not 0 < dt <= 0xffffffff // 4:
            raise ValueError('nonpositive or ambiguous counter interval')
        if capture['snapshot_id_before'] == previous['snapshot_id_before']:
            raise ValueError('same snapshot ID')
        if ((w[48] - p[48]) & 0xffffffff) != dt:
            raise ValueError('elapsed counter disagrees with timestamp; reset or corrupt dump')
        seconds = dt / capture['clock_hz']
        for c, stream in enumerate(result['streams']):
            delta = (w[16+c] - p[16+c]) & 0xffffffff
            if delta > 4 * dt:
                raise ValueError('byte delta exceeds stream physical bound')
            stream['interval_bytes'] = delta
            stream['bytes_per_second'] = delta / seconds
        result['interval_cycles'] = dt
        result['interval_seconds'] = seconds
    return result


def self_test():
    a = {'schema': 'buffer_dma_metrics_v1', 'source_kind': 'simulation',
        'epoch_id': 'fixture', 'clock_hz': 100, 'snapshot_id_before': 0xffffffff,
        'snapshot_id_after': 0xffffffff, 'captured': True, 'timestamp': 100,
        'words': [0] * 51}
    a['words'][48] = 100
    a['words'][16] = 0xfffffff0
    b = dict(a, timestamp=110, snapshot_id_before=0, snapshot_id_after=0, words=a['words'].copy())
    b['words'][48] = 110
    b['words'][16] = 8
    assert decode(b, a)['streams'][0]['bytes_per_second'] == 240
    corrupt_time = b['words'].copy()
    corrupt_time[48] = 111
    corrupt_bytes = b['words'].copy()
    corrupt_bytes[17] = 41
    for bad in (dict(b, snapshot_id_after=1), dict(b, epoch_id='reset'),
                dict(b, timestamp=100), dict(b, clock_hz=0),
                dict(b, captured=False), dict(b, clock_hz=float('nan')),
                dict(b, timestamp=100 + 0x40000000), dict(b, words=corrupt_time),
                dict(b, words=corrupt_bytes),
                dict(b, words=b['words'][:-1])):
        try:
            decode(bad, a)
        except ValueError:
            pass
        else:
            raise AssertionError('bad capture accepted')
    print('PASS telemetry decoder: wrap, ID wrap, coherence, reset, interval and schema checks')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, nargs='?')
    parser.add_argument('--previous', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        if args.input is None:
            parser.error('input required')
        output = decode(json.loads(args.input.read_text()),
            json.loads(args.previous.read_text()) if args.previous else None)
        text = json.dumps(output, indent=2, allow_nan=False) + '\n'
        if args.output:
            args.output.write_text(text)
        else:
            print(text, end='')
