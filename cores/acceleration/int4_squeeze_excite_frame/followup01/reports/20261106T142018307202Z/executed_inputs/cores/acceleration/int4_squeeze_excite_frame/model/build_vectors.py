"""Independent integer frame/channel oracle and finite event fixture. Source only."""
from pathlib import Path
import argparse
import hashlib
import json

PROFILES = {'tiny': (1, 1, 1, 1, False), 'odd': (9, 3, 7, 8, False),
            'limits': (64, 32, 4096, 32, False), 'example': (3, 1, 7, 8, True)}


def rne(numerator, denominator):
    q, r = divmod(abs(numerator), denominator)
    q += 2*r > denominator or (2*r == denominator and q % 2 == 1)
    return -q if numerator < 0 else q


def project(vector, rows, matrix, metadata):
    output, clipped, inexact = [], False, False
    for r in range(rows):
        bias, scale, shift, zero = metadata[r]
        accumulator = bias + sum(x*w for x, w in zip(vector, matrix[r]))
        product = accumulator*scale
        rounded = rne(product, 1 << shift) + zero
        clipped |= not -128 <= rounded <= 127
        inexact |= product % (1 << shift) != 0
        output.append(max(-128, min(127, rounded)))
    return output, int(clipped), int(inexact)


def evaluate(samples, pixels, channels, hidden, matrices, metadata):
    sums = [sum(samples[p*channels+c] for p in range(pixels)) for c in range(channels)]
    means = [rne(value, pixels) for value in sums]
    reduced, clip0, ix0 = project(means, hidden, matrices[0], metadata[0])
    logits, clip1, ix1 = project([max(0, x) for x in reduced], channels, matrices[1], metadata[1])
    gates = [max(0, min(256, rne((x+96)*4, 3))) for x in logits]
    flags = (int(any(s % pixels for s in sums)), clip0 | clip1, ix0 | ix1,
             int(any(-96 < x < 96 and (x+96)*4 % 3 for x in logits)),
             int(any(x < -96 or x > 96 for x in logits)))
    rows = [(rne(x*gates[i % channels], 256), gates[i % channels],
             int(x*gates[i % channels] % 256 != 0)) for i, x in enumerate(samples)]
    assert all(-128 <= row[0] <= 127 and 0 <= row[1] <= 256 for row in rows)
    return rows, flags


def build(label):
    mc, mh, mp, tw, example = PROFILES[label]
    events, statistics = [], {'frames': 0, 'oracle_frames': 0, 'configs': 0, 'resets': 0}
    matrices, metadata, word_valid, meta_valid = [], [], [], []

    def clear():
        nonlocal matrices, metadata, word_valid, meta_valid
        matrices = [[[0]*mc for _ in range(mh)], [[0]*mh for _ in range(mc)]]
        metadata = [[(0, 1, 0, 0)]*mh, [(0, 1, 0, 0)]*mc]
        word_valid = [set(), set()]
        meta_valid = [set(), set()]
        if example:
            matrices[0] = [[1, 1, 1]]
            matrices[1] = [[-1], [0], [1]]
            word_valid = [{(0, 0)}, {(0, 0), (1, 0), (2, 0)}]
            meta_valid = [{0}, {0, 1, 2}]

    def reset():
        events.append(['0']); clear(); statistics['resets'] += 1

    def config(bank, op, row=0, word=0, data=0, bias=0, scale=1, shift=0, zero=0):
        max_rows, max_cols = ((mh, mc), (mc, mh))[bank]
        error = 2 if op == 3 else 1 if (op == 0 and (row >= max_rows or word >= (max_cols+7)//8)
                                       or op == 1 and row >= max_rows) else 0
        events.append(['1 ' + ' '.join(map(str, (bank, op, row, word, data, bias, scale, shift, zero, error)))])
        statistics['configs'] += 1
        if not error:
            if op == 0:
                word_valid[bank].add((row, word))
                for lane in range(8):
                    c = word*8+lane
                    if c < max_cols:
                        value = (data >> (lane*4)) & 15
                        matrices[bank][row][c] = value-16 if value >= 8 else value
            elif op == 1:
                metadata[bank][row] = bias, scale, shift, zero
                meta_valid[bank].add(row)
            else:
                word_valid[bank].clear(); meta_valid[bank].clear()

    def configure(mode=0, only=None):
        if example:
            return
        for bank, (rows, cols) in enumerate(((mh, mc), (mc, mh))):
            if only is not None and bank != only:
                continue
            for row in range(rows):
                for word in range((cols+7)//8):
                    weights = [0 if mode == 0 or mode >= 4 else ((row*5+(word*8+i)*3+mode) % 16)-8 for i in range(8)]
                    packed = sum((w & 15) << (4*i) for i, w in enumerate(weights))
                    config(bank, 0, row, word, packed)
                if mode >= 4:
                    values = ([0, 96, -96, 1, -1][mode-4] if bank else 0), 1, 0, 0
                elif mode == 0:
                    values = ([-128, -97, -96, -95, -1, 0, 1, 95, 96, 97, 127][row % 11]
                              if bank else 3), 1, 0, 0
                elif mode == 1:
                    values = row*7-11, 1, (row+bank) % 4, (row % 3)-1
                elif mode == 2:
                    values = (-2147483648 if row % 2 else 2147483647), 65535, 31, (-128 if row % 2 else 127)
                else:
                    values = row*3-7, 3, 1, 0
                config(bank, 1, row, 0, 0, *values)

    def frame(p, c, h, tag, malformed=0, samples=None):
        statistics['frames'] += 1
        error, stage, child = 0, 3, 0
        if p == 0 or p > mp or c == 0 or c > mc or h == 0 or h > mh:
            error = 1
        else:
            for bank, (rows, cols) in enumerate(((h, c), (c, h))):
                if any(row not in meta_valid[bank] or (row, word) not in word_valid[bank]
                       for row in range(rows) for word in range((cols+7)//8)):
                    error, stage = 2, bank
                    break
        inputs, outputs, flags = [], [], (0, 0, 0, 0, 0)
        if not error:
            samples = list(samples) if samples is not None else [((i*73+tag*29) % 256)-128 for i in range(p*c)]
            assert len(samples) == p*c
            if malformed:
                count = 1 if malformed == 1 else p*c
                inputs = [(x, int(i == 0) if malformed == 1 else 0) for i, x in enumerate(samples[:count])]
                # A one-element early-LAST is legal; use missing-LAST for that shape.
                if p*c == 1:
                    inputs = [(samples[0], 0)]
                error, stage, child = 3, 2, 2
            else:
                inputs = [(x, int(i == p*c-1)) for i, x in enumerate(samples)]
                outputs, flags = evaluate(samples, p, c, h, matrices, metadata)
                statistics['oracle_frames'] += 1
        header = (2, p, c, h, tag & ((1 << tw)-1), len(inputs), len(outputs), error, stage, child, *flags)
        events.append([' '.join(map(str, header))] + ['%d %d' % row for row in inputs]
                      + ['%d %d %d' % row for row in outputs])

    reset()
    c, h, p = min(mc, 9), min(mh, 3), min(mp, 5)
    if example:
        for i in range(6):
            frame(p, 3, 1, i, samples=[((j*31+i*67) % 256)-128 for j in range(p*3)])
        frame(p, 3, 1, 7, malformed=1); frame(p, 3, 1, 8, malformed=2)
        frame(0, 3, 1, 9)
        for target in (5, 10, 16, 20, 21):
            # Zero means -> zero hidden/logit -> non-saturated gate, including divider ownership.
            values = [0]*(p*3)
            events.append([' '.join(map(str, (3, target, p, 3, 1, 11, len(values))))]
                          + ['%d %d' % (x, i == len(values)-1) for i, x in enumerate(values)])
            clear(); statistics['resets'] += 1; frame(1, 3, 1, 12, samples=[-128, 0, 127])
    else:
        frame(0, c, h, 1); frame(mp+1, c, h, 2); frame(p, mc+1, h, 3); frame(p, c, mh+1, 4)
        frame(p, c, h, 5)
        config(0, 3); config(0, 0, mh, 0); config(1, 1, mc, 0); config(1, 0, 0, (mh+7)//8)
        configure(0, only=0); frame(p, c, h, 6); configure(0, only=1)
        for mode in range(4):
            if mode:
                configure(mode)
            frame(p, c, h, mode+7)
            frame(1, c, h, mode+20, samples=[-128 if i % 2 else 127 for i in range(c)])
        for mode in range(4, 9):
            configure(mode)
            frame(p, c, h, mode+24, samples=[[-128, -3, -1, 0, 1, 3, 127][i % 7] for i in range(p*c)])
        frame(p, c, h, 30, malformed=1); frame(p, c, h, 31, malformed=2); frame(p, c, h, 32)
        config(1, 2); frame(p, c, h, 33); configure(1, only=1); frame(p, c, h, 34)
        config(0, 2); frame(p, c, h, 35); configure(1, only=0); frame(p, c, h, 36)
        if label == 'limits':
            frame(mp, 1, 1, 37); frame(1, mc, mh, 38)
        for target in (5, 10, 16, 20, 21):
            configure(4)
            values = [0]*(p*c)
            events.append([' '.join(map(str, (3, target, p, c, h, 39, len(values))))]
                          + ['%d %d' % (x, i == len(values)-1) for i, x in enumerate(values)])
            clear(); statistics['resets'] += 1
            frame(1, c, h, 40); configure(1); frame(1, c, h, 41)
        events.append(['4']); clear(); statistics['resets'] += 1
        frame(1, c, h, 42); configure(3); frame(1, c, h, 43)
    return str(len(events))+'\n'+'\n'.join(line for event in events for line in event)+'\n', statistics


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=PROFILES, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    data, stats = build(args.profile)
    with args.out.open('x', encoding='ascii', newline='\n') as stream:
        stream.write(data)
    print(json.dumps(dict(profile=args.profile, file=str(args.out), bytes=len(data.encode('ascii')),
                          sha256=hashlib.sha256(data.encode('ascii')).hexdigest(), **stats), sort_keys=True))


if __name__ == '__main__':
    main()
