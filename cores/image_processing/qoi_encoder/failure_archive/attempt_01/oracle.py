"""Original, finite-fixture QOI oracle; no upstream code is imported or run.

Encoding chooses from tables made by decoding legal DIFF/LUMA fields.  The
separate file parser uses full weighted hashes and explicit chunk arithmetic.
Neither numerical oracle knows the proposed RTL state machine.
"""
from collections import Counter
import hashlib

INITIAL = (0, 0, 0, 255)
ZERO = (0, 0, 0, 0)
END = bytes([0] * 7 + [1])


def digest(data):
    return hashlib.sha256(data).hexdigest()


def color_hash(pixel):
    # Removing each channel's multiples of 64 changes the weighted sum by a
    # multiple of 64. Full sum <= 6630 (13 bits); this sum <= 1638 (11 bits).
    return sum((v & 63) * k for v, k in zip(pixel, (3, 5, 7, 11))) & 63


def legal_delta_tables():
    diff, luma = {}, {}
    for code in range(64):
        d = tuple((((code >> shift) & 3) - 2) & 255 for shift in (4, 2, 0))
        assert d not in diff
        diff[d] = bytes([64 | code])
    for green in range(64):
        dg = green - 32
        for second in range(256):
            d = ((dg + (second >> 4) - 8) & 255, dg & 255,
                 (dg + (second & 15) - 8) & 255)
            assert d not in luma
            luma[d] = bytes([128 | green, second])
    return diff, luma


DIFF, LUMA = legal_delta_tables()


def rgba_pixels(pixels, channels):
    assert channels in (3, 4)
    answer = [tuple(p) + ((255,) if channels == 3 else ()) for p in pixels]
    assert all(len(p) == 4 and all(0 <= v <= 255 for v in p) for p in answer)
    return answer


def encode(pixels, width, height, channels, colorspace):
    """Return canonical bytes plus semantic events for work/reset certificates."""
    rgba = rgba_pixels(pixels, channels)
    assert len(rgba) == width * height and width > 0 and height > 0
    assert colorspace in (0, 1)
    history, previous, run = [ZERO] * 64, INITIAL, 0
    payload, packets, events = bytearray(), [], []
    counts = Counter()

    def emit(kind, data, pixel, phase, length=0):
        packet = dict(kind=kind, data=list(data), pixel=pixel, phase=phase,
                      run_length=length, offset=14 + len(payload))
        packets.append(packet)
        payload.extend(data)
        counts[kind] += 1
        return len(packets) - 1

    for i, current in enumerate(rgba):
        event = dict(pixel=i, previous=list(previous), current=list(current),
                     run_before=run, same=current == previous, packets=[])
        if current == previous:
            run += 1
            if run == 62 or i == len(rgba) - 1:
                event['packets'].append(emit('RUN', bytes([192 + run - 1]), i, 'current', run))
                run = 0
        else:
            if run:
                event['packets'].append(emit('RUN', bytes([192 + run - 1]), i, 'flush', run))
                run = 0
            slot = color_hash(current)
            hit = history[slot] == current
            event.update(slot=slot, hit=hit)
            if hit:
                kind, data = 'INDEX', bytes([slot])
            else:
                history[slot] = current
                delta = tuple((a - b) & 255 for a, b in zip(current[:3], previous[:3]))
                if current[3] != previous[3]:
                    kind, data = 'RGBA', bytes([255, *current])
                elif delta in DIFF:
                    kind, data = 'DIFF', DIFF[delta]
                elif delta in LUMA:
                    kind, data = 'LUMA', LUMA[delta]
                else:
                    kind, data = 'RGB', bytes([254, *current[:3]])
            event['kind'] = kind
            event['packets'].append(emit(kind, data, i, 'current'))
        events.append(event)
        previous = current
    header = b'qoif' + width.to_bytes(4, 'big') + height.to_bytes(4, 'big') + bytes([channels, colorspace])
    data = header + payload + END
    d = sum(not e['same'] for e in events)
    m = sum(not e['same'] and not e['hit'] for e in events)
    stats = dict(different=d, misses=m, payload_bytes=len(payload), bytes=len(data),
                 raw_reads=len(rgba), history_reads=d, history_writes=64 + m,
                 capture_writes=len(rgba), tail=112 + 3 * len(rgba) + 2 * d + m + len(payload),
                 opcodes=dict(sorted(counts.items())),
                 run_lengths=[p['run_length'] for p in packets if p['kind'] == 'RUN'],
                 hash_slots=sorted({e['slot'] for e in events if not e['same']}))
    assert len(data) <= (channels + 1) * len(rgba) + 22
    assert stats['tail'] <= 112 + (channels + 7) * len(rgba)
    return data, events, packets, stats


def decode(data):
    """Strict independent reverse-direction parser, including full-file checks."""
    assert len(data) >= 23 and data[:4] == b'qoif'
    width, height = int.from_bytes(data[4:8], 'big'), int.from_bytes(data[8:12], 'big')
    channels, colorspace = data[12:14]
    assert width > 0 and height > 0 and channels in (3, 4) and colorspace in (0, 1)
    table, pixel, output = [[0, 0, 0, 0] for _ in range(64)], [0, 0, 0, 255], []
    pointer, prior_index, chunks = 14, None, []
    while len(output) < width * height:
        start = pointer
        assert pointer < len(data) - 8
        first = data[pointer]
        pointer += 1
        repeat = 1
        index = None
        if first in (254, 255):
            length = 3 if first == 254 else 4
            assert pointer + length <= len(data) - 8
            pixel[:length] = data[pointer:pointer + length]
            pointer += length
            kind = 'RGB' if length == 3 else 'RGBA'
        elif first < 64:
            index = first
            assert prior_index != index, 'consecutive identical INDEX'
            pixel = table[index][:]
            kind = 'INDEX'
        elif first < 128:
            pixel[:3] = [(pixel[j] + ((first >> shift) & 3) - 2) % 256
                         for j, shift in enumerate((4, 2, 0))]
            kind = 'DIFF'
        elif first < 192:
            assert pointer < len(data) - 8
            second = data[pointer]
            pointer += 1
            green = (first & 63) - 32
            increments = (green + (second >> 4) - 8, green, green + (second & 15) - 8)
            pixel[:3] = [(pixel[j] + increments[j]) % 256 for j in range(3)]
            kind = 'LUMA'
        else:
            repeat = (first & 63) + 1
            assert 1 <= repeat <= 62
            kind = 'RUN'
        assert len(output) + repeat <= width * height
        for _ in range(repeat):
            output.append(tuple(pixel))
            slot = (pixel[0] * 3 + pixel[1] * 5 + pixel[2] * 7 + pixel[3] * 11) % 64
            table[slot] = pixel[:]
        prior_index = index
        chunks.append(dict(offset=start, length=pointer - start, kind=kind, pixels=repeat))
    assert pointer == len(data) - 8 and data[pointer:] == END
    return output, dict(width=width, height=height, channels=channels, colorspace=colorspace,
                        consumed_bytes=len(data), decoded_pixels=len(output),
                        rgba_sha256=digest(bytes(v for p in output for v in p)),
                        file_sha256=digest(data), chunks=chunks)


def certify(pixels, width, height, channels, colorspace):
    data, events, packets, stats = encode(pixels, width, height, channels, colorspace)
    reconstructed, certificate = decode(data)
    assert reconstructed == rgba_pixels(pixels, channels)
    assert [(p['offset'], len(p['data']), p['kind']) for p in packets] == [
        (p['offset'], p['length'], p['kind']) for p in certificate['chunks']]
    certificate['exact_input_reconstruction'] = True
    certificate['canonical_priority'] = 'RUN,INDEX,DIFF,LUMA,RGB/RGBA'
    return data, events, packets, stats, certificate


def hand_anchors():
    anchors = [((0, 0, 0, 0), '00'), ((0, 0, 0, 255), 'c0'),
               ((255, 255, 255, 255), '55'), ((1, 1, 1, 255), '7f'),
               ((38, 31, 23, 255), 'bff0'), ((216, 224, 231, 255), '800f'),
               ((100, 0, 0, 255), 'fe640000'), ((0, 0, 0, 1), 'ff00000001')]
    records = []
    for pixel, expected in anchors:
        data, _, _, _, certificate = certify([pixel], 1, 1, 4, 0)
        assert data[14:-8].hex() == expected
        records.append(dict(rgba=list(pixel), expected_payload_hex=expected,
                            file_sha256=certificate['file_sha256']))
    return records
