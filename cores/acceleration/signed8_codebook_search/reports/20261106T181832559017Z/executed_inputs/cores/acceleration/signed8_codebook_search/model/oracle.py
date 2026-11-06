"""Independent integer codebook oracle and deterministic finite vector author.

No project imports, HDL execution, training, floats, or third-party packages.
The oracle sorts complete Python integer distances instead of following RTL
candidate-ranking registers, synchronous reads, or computation scheduling.
"""
from pathlib import Path
import argparse
import os
import random


class Codebook:
    def __init__(self, codes, dims):
        self.codes, self.dims = codes, dims
        self.rows = [[] for _ in range(codes)]

    def configure(self, code, dim, first, value):
        if not (0 <= code < self.codes and 0 <= dim < self.dims):
            return 1
        row = self.rows[code]
        if first:
            if dim != 0:
                return 2
            self.rows[code] = [value]
        elif row and dim == len(row):
            row.append(value)
        else:
            return 2
        return 0

    def search(self, codes, dims, query):
        if not (1 <= codes <= self.codes and 1 <= dims <= self.dims):
            return (1, 0, 0, 0, 0), []
        if any(len(row) < dims for row in self.rows[:codes]):
            return (2, 0, 0, 0, 0), []
        assert len(query) == dims and all(-128 <= value <= 127 for value in query)
        ranking = sorted((sum((x-y)**2 for x, y in zip(query, row[:dims])), index)
                         for index, row in enumerate(self.rows[:codes]))
        distance, winner = ranking[0]
        margin = ranking[1][0]-distance if codes > 1 else 0
        reconstructed = list(self.rows[winner][:dims])
        return (0, winner, distance, margin, int(codes > 1)), reconstructed


def requantize(value, shift):
    divisor = 1 << shift
    quotient, remainder = divmod(abs(value), divisor)
    if 2*remainder > divisor or (2*remainder == divisor and quotient % 2):
        quotient += 1
    rounded = -quotient if value < 0 else quotient
    return max(-128, min(127, rounded)), int(not -128 <= rounded <= 127), int(remainder != 0)


def vectors(codes, dims):
    model = Codebook(codes, dims)
    lines = []
    query_count = 0

    def reset():
        nonlocal model
        model = Codebook(codes, dims)
        lines.append('R')

    def configure(code, dim, first, value):
        status = model.configure(code, dim, first, value)
        lines.append(f'C {code} {dim} {first} {value} {status}')

    def search(count, size, values, shift=0):
        nonlocal query_count
        tag = (37*query_count+19) & 255
        query_count += 1
        summary, decoded = model.search(count, size, values)
        error, winner, distance, margin, second = summary
        lines.append(f'Q {count} {size} {tag} {shift} {error} {winner} {distance} {margin} {second}')
        for original, reconstructed in zip(values, decoded):
            residual = original-reconstructed
            encoded, clip, inexact = requantize(residual, shift)
            lines.append(f'D {original} {reconstructed} {residual} {encoded} {clip} {inexact}')

    reset()
    search(0, 1, [])
    search(codes+1, 1, [])
    search(1, 0, [])
    search(1, dims+1, [])
    search(1, 1, [])
    configure(codes, 0, 1, 0)
    configure(0, dims, 1, 0)
    configure(0, 0, 0, 0)
    configure(0, 1, 1, 0)
    reset()
    palette = [-128, 127, 0, -1, 1, 64, -64]
    for code in range(codes):
        # First two complete rows tie, while later rows differ genuinely.
        pattern = 0 if code < 2 else code
        for dim in range(dims):
            configure(code, dim, int(dim == 0), palette[(3*pattern+dim) % len(palette)])
    search(codes, dims, list(model.rows[0]), 0)
    search(codes, dims, [127]*dims, 0)
    search(codes, dims, [-128]*dims, 1)
    rng = random.Random(0xB4900+codes*257+dims)
    search(codes, dims, [rng.randrange(-128, 128) for _ in range(dims)], 7)
    search(min(codes, 2), 1, [0], 8)
    search(codes, dims, [0]*dims, 15)
    if codes > 1 and dims > 1:
        for dim in range(dims):
            configure(codes-1, dim, int(dim == 0), 0)
        search(codes, dims, [0]*dims, 0)  # Unique winner at the final row/address.
    configure(0, 0, 0, -1)  # Reject overwrite without explicit restart.
    search(1, 1, [127], 0)
    configure(0, 0, 1, 127)
    if dims > 1:
        search(codes, dims, [])  # Old suffix is no longer published.
    for dim in range(1, dims):
        configure(0, dim, 0, -128 if dim % 2 else 127)
    search(codes, dims, [0]*dims, 2)
    configure(0, 0, 1, -128)
    search(1, 1, [127], 0)  # Exact residual255, square65025, output clipping.
    for dim in range(1, dims):
        configure(0, dim, 0, -128)
    search(1, dims, [127]*dims, 0)  # Full 24-bit distance bound at dims256.
    search(1, 1, [-127], 1)  # Positive half tie to even zero.
    configure(0, 0, 1, 127)
    search(1, 1, [-128], 0)  # Exact residual-255 and negative clipping.
    for dim in range(1, dims):
        configure(0, dim, 0, 127)
    search(1, dims, [-128]*dims, 0)
    search(1, 1, [126], 1)  # Negative half tie to even zero.
    reset()
    search(1, 1, [])
    configure(0, 0, 1, 0)
    search(1, 1, [7], 1)  # Fresh configuration after reset; odd half rounds4.
    lines.append('E')
    return lines, query_count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--codes', type=int, required=True)
    parser.add_argument('--dims', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert 1 <= args.codes <= 64 and 1 <= args.dims <= 256
    lines, queries = vectors(args.codes, args.dims)
    with args.output.open('x', encoding='ascii', newline='\n') as stream:
        stream.write('\n'.join(lines)+'\n')
        stream.flush()
        os.fsync(stream.fileno())
    print(f'CODEBOOK_VECTORS codes={args.codes} dims={args.dims} records={len(lines)} queries={queries}')


if __name__ == '__main__':
    main()
