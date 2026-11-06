"""Independent packet-list oracle; prepare only through the frozen source gate.

The oracle counts accepted KEEP bits and classifies complete input packets. It
has no RAM address, pipeline state, dependency import or simulator input.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os

PROFILES = {
    'singleton': (1, 8, 1, 1, 1, 1),
    'ragged': (3, 16, 5, 4, 3, 3),
    'maximum': (8, 64, 512, 24, 16, 1024),
}


def classify(beats, first_flow, enabled, capacity, flows, max_beats, lanes):
    """Packet-level decisions: saturate diagnostic counts, preserve all words."""
    byte_count = sum(keep.bit_count() for _, keep in beats)
    if first_flow >= flows:
        status = 1
    elif not enabled:
        status = 5
    elif len(beats) > max_beats:
        status = 3
    elif byte_count == 0:
        status = 2
    elif byte_count > capacity:
        status = 4
    else:
        status = 0
    return status, min(byte_count, max_beats * lanes + 1), min(len(beats), max_beats + 1)


def fixture(profile):
    flows, width, limit, token_width, tag_width, quantum = PROFILES[profile]
    lanes = width // 8
    max_bytes = limit * lanes
    mask = (1 << lanes) - 1
    cases = []
    for number in range(12):
        flow = 0 if number not in (9, 11) or flows == 1 else 1
        if number == 6:
            flow = 0xffffffff
        count = {0: min(limit, 3), 1: 1, 2: limit + 1, 3: limit,
                 4: 1, 5: 1, 6: min(limit, 2), 7: min(limit, 4), 8: min(limit, 4), 9: min(limit, 4)}.get(number, 1)
        capacity, rate, initial, enabled = max_bytes, 0, max_bytes, True
        if number == 4:
            capacity = initial = 1
        if number == 5:
            enabled = False
        if number == 10:
            rate, initial = (1 if flows == 1 else 0), 0
        if number == 11:
            rate, initial = 1, 0
        payload = []
        for index in range(count):
            # Byte construction preserves masked bytes too, and differs between
            # adjacent words/cases. It is not read from a hardware trace.
            value = sum(((29 * number + 17 * index + 11 * lane + 3) & 255) << (8 * lane)
                        for lane in range(lanes))
            keep = mask
            if number == 1:
                keep = 0
            elif number in (0, 7):
                if index == 0 and count > 1:
                    keep = 0
                elif index == count - 1:
                    keep = 1
                elif lanes > 1:
                    keep = sum(1 << lane for lane in range(lanes) if lane % 2)
            elif number in (10, 11):
                keep = 1
            payload.append((value, keep))
        status, byte_count, beat_count = classify(payload, flow, enabled, capacity,
                                                  flows, limit, lanes)
        cases.append(dict(id=number, flow=flow, tag=(number + 1) % (1 << tag_width),
                          payload=payload, capacity=capacity, rate=rate, initial=initial,
                          enabled=enabled, status=status, byte_count=byte_count,
                          beat_count=beat_count,
                          emitted=status == 0 and not (number == 10 and flows > 1)))
    return cases


def prepare(profile, output):
    values = PROFILES[profile]
    cases = fixture(profile)
    output.mkdir(parents=True, exist_ok=False)
    vector = output / 'packets.txt'
    with vector.open('x', encoding='ascii', newline='\n') as stream:
        stream.write(' '.join(map(str, (*values, len(cases)))) + '\n')
        for case in cases:
            stream.write(' '.join(map(str, (case['id'], case['flow'], case['tag'], len(case['payload']),
                case['capacity'], case['rate'], case['initial'], int(case['enabled']),
                case['status'], case['byte_count'], case['beat_count']))) + '\n')
            for index, (data, keep) in enumerate(case['payload']):
                # Disturbed later metadata must not redirect ownership.
                flow = case['flow'] if index == 0 else 0xfffffffe
                tag = case['tag'] if index == 0 else case['tag'] ^ ((1 << values[4]) - 1)
                stream.write(f'{data:x} {keep:x} {flow} {tag} {int(index == len(case["payload"]) - 1)}\n')
        stream.flush()
        os.fsync(stream.fileno())
    digest = hashlib.sha256(vector.read_bytes()).hexdigest()
    expected = dict(cases=len(cases), vector_frames=sum(c['emitted'] for c in cases),
                    vector_beats=sum(len(c['payload']) for c in cases if c['emitted']),
                    admissions=len(cases), reset_probes=5, recovery_frames=5)
    receipt = dict(schema='b48-payload-model-v1', profile=profile, parameters=values,
                   cases=[{k: v for k, v in c.items() if k != 'payload'} for c in cases],
                   vector=dict(path=vector.name, sha256=digest, bytes=vector.stat().st_size),
                   expected=expected, source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    with (output / 'preparation.json').open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(receipt, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    print('B48_A_MODEL_PASS ' + ' '.join(f'{k}={v}' for k, v in expected.items()))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepare', action='store_true', required=True)
    parser.add_argument('--profile', choices=PROFILES, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.profile, args.out)


if __name__ == '__main__':
    main()
