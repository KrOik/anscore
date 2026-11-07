# SPDX-License-Identifier: Apache-2.0
"""Independent spatial oracle plus a separate exact Winograd identity check.

This file is source-only until the root/peer execution gate. It imports no
project code and does not invoke subprocesses. Only explicit --out emits files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random

BT = ((1, 0, -1, 0), (0, 1, 1, 0), (0, -1, 1, 0), (0, -1, 0, 1))
GP = ((2, 0, 0), (1, 1, 1), (1, -1, 1), (0, 0, 2))
AT = ((1, 1, 1, 0), (0, 1, -1, 1))


def transpose(a):
    return tuple(zip(*a))


def mm(a, b):
    return [[sum(x * y for x, y in zip(row, col)) for col in transpose(b)] for row in a]


def spatial(tile, weights, xzero, bias):
    """Golden results use direct 3x3 spatial cross-correlation, not transforms."""
    return [bias + sum((tile[(y + ky) * 4 + x + kx] - xzero) * weights[ky * 3 + kx]
                       for ky in range(3) for kx in range(3))
            for y in range(2) for x in range(2)]


def identity(tile, weights, xzero):
    d = [[tile[4 * r + c] - xzero for c in range(4)] for r in range(4)]
    g = [weights[3 * r:3 * r + 3] for r in range(3)]
    u4 = mm(mm(GP, g), transpose(GP))
    v = mm(mm(BT, d), transpose(BT))
    assert all(-128 <= x <= 127 for row in u4 for x in row)
    assert all(-1024 <= x <= 1023 for row in v for x in row)
    products = [[u4[r][c] * v[r][c] for c in range(4)] for r in range(4)]
    y4 = mm(mm(AT, products), transpose(AT))
    flat = [x for row in y4 for x in row]
    assert all(x % 4 == 0 for x in flat)
    assert [x // 4 for x in flat] == spatial(tile, weights, xzero, 0)


def requant(acc, scale, shift, zero):
    product = acc * scale
    floor, remainder = divmod(product, 1 << shift)
    half_compare = 2 * remainder - (1 << shift)
    rounded = floor + int(half_compare > 0 or (half_compare == 0 and floor % 2 != 0))
    translated = rounded + zero
    return min(127, max(-128, translated)), int(translated < -128 or translated > 127), int(remainder != 0)


class Fixture:
    def __init__(self, max_rows, tag_w, wrapped):
        self.max_rows, self.tag_w, self.wrapped = max_rows, tag_w, wrapped
        self.rng = random.Random(0x50_726F6F74 + max_rows + int(wrapped) * 1000)
        self.lines = []
        self.rows = {}
        self.tile_checks = 0
        self.commands = 0
        self.outputs = 0
        self.configs = 0
        self.record(4)  # simultaneous cfg/command arbitration, independent TB task

    def record(self, kind, *payload):
        assert len(payload) <= 11
        self.lines.append(" ".join(str(x) for x in (kind, *payload, *((0,) * (11 - len(payload)))))

    def cfg(self, op, row=0, tap=0, weight=0, bias=0, scale=0, shift=0, zero=0, error=0):
        self.configs += 1
        self.record(0, op, row, tap, weight, bias, scale, shift, zero, error)

    def configure(self, nrows):
        for row in range(nrows):
            weights = [self.rng.randrange(-8, 8) for _ in range(9)]
            if row == 0:
                weights = [-8] * 9
            elif row == 1:
                weights = [7] * 9
            elif row == nrows - 1:
                weights = [-8, 7, -8, 7, -8, 7, -8, 7, -8]
            bias = (-2147483648, 2147483647, 0, -3, 3)[row % 5]
            scale = (65535, 0, 1, 1, 32769)[row % 5]
            shift = (31, 0, 0, 1, 15)[row % 5]
            zero = (-128, 127, 0, 1, -7)[row % 5]
            self.rows[row] = (weights, bias, scale, shift, zero)
            for tap, weight in enumerate(weights):
                self.cfg(0, row=row, tap=tap, weight=weight)
            self.cfg(1, row=row, bias=bias, scale=scale, shift=shift, zero=zero)
            self.cfg(2, row=row)

    def run(self, nrows, xzero=0, tile=None, error=0, inputs=True, malformed=-1):
        tile = [self.rng.randrange(256) for _ in range(16)] if tile is None else tile
        count = 4 * nrows if inputs else 0
        tag = ((self.commands * 0x9E3779B1) ^ ((1 << self.tag_w) - 1)) & ((1 << self.tag_w) - 1)
        self.record(1, nrows, xzero, tag, error, count, 16 if inputs else 0)
        self.commands += 1
        for row in range(nrows if inputs else 0):
            weights, bias, scale, shift, zero = self.rows[row]
            identity(tile, weights, xzero)
            self.tile_checks += 1
            for pixel, acc in enumerate(spatial(tile, weights, xzero, bias)):
                assert -(1 << 32) <= acc < (1 << 32)
                q, clip, inexact = requant(acc, scale, shift, zero)
                self.record(2, row, pixel, acc, scale, shift, zero, tag,
                            int(row == nrows - 1 and pixel == 3), q, clip, inexact)
                self.outputs += 1
        if inputs:
            for index, sample in enumerate(tile):
                last = int(index == 15)
                if index == malformed:
                    last ^= 1
                self.record(3, sample, last)

    def build(self):
        self.run(0, error=1, inputs=False)
        self.run(self.max_rows + 1, error=1, inputs=False)
        self.run(1, error=2, inputs=False)
        self.cfg(0, row=self.max_rows, error=1)
        self.cfg(0, tap=9, error=1)
        self.cfg(1, shift=63, error=2)
        self.cfg(2, error=3)
        self.configure(self.max_rows)
        # Rejected writes must preserve the already published row.
        self.cfg(0, row=self.max_rows, error=1)
        self.cfg(0, tap=15, error=1)
        self.cfg(1, shift=32, error=2)
        self.cfg(2, row=self.max_rows, error=1)
        self.run(self.max_rows, 0, [255] * 16)
        self.run(self.max_rows, 255, [0] * 16)
        self.run(self.max_rows, 128, [255 if i % 2 else 0 for i in range(16)])
        self.run(1, 255, [255] * 16)
        self.run(self.max_rows, 7)
        self.run(self.max_rows, 128, error=3, malformed=3)
        self.run(self.max_rows, 0, error=3, malformed=15)
        weights, bias, scale, shift, zero = self.rows[0]
        weights = list(weights)
        weights[0] = 7
        self.cfg(0, weight=7)
        self.rows[0] = (weights, bias, scale, shift, zero)
        self.run(1, error=2, inputs=False)
        self.cfg(2)
        self.run(1, 0, [255] * 16)
        # Isolate exact positive/negative ties and zero-point translation.
        for acc, sc, sh, z in ((3, 1, 1, 1), (-3, 1, 1, 1), (1, 1, 1, -1),
                              (-1, 1, 1, -1), (2147483647, 65535, 0, -128),
                              (-2147483648, 65535, 0, 127), (17, 0, 31, -9)):
            for tap in range(9):
                self.cfg(0, tap=tap, weight=0)
            self.cfg(1, bias=acc, scale=sc, shift=sh, zero=z)
            self.cfg(2)
            self.rows[0] = ([0] * 9, acc, sc, sh, z)
            self.run(1, 128)
        self.cfg(3)
        self.rows.clear()
        self.run(1, error=2, inputs=False)
        self.cfg(0, tap=0, weight=1)
        self.cfg(2, error=3)
        self.configure(1)
        # Synchronous reset during held config, publish, capture, transform,
        # product, held raw/quantized output, and held final response.
        for target in (1, 2, 7, 8, 12, 15, 16, *((30,) if self.wrapped else ())):
            self.record(5, target)
            self.rows.clear()
            self.run(1, error=2, inputs=False)
            self.configure(1)
            self.run(1, self.rng.randrange(256))
        self.record(9)
        return "\n".join(self.lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    manifest = {"schema": 1, "oracle": "direct spatial integer sums", "fixtures": []}
    for max_rows, tag_w, wrapped in ((1, 1, False), (3, 17, False), (64, 32, False), (8, 32, True)):
        fixture = Fixture(max_rows, tag_w, wrapped)
        content = fixture.build().encode("ascii")
        name = f"{'wrapper' if wrapped else 'core'}_r{max_rows}_t{tag_w}.txt"
        with (args.out / name).open("xb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        manifest["fixtures"].append({"name": name, "sha256": hashlib.sha256(content).hexdigest(),
                                    "bytes": len(content), "max_rows": max_rows, "tag_w": tag_w,
                                    "wrapped": wrapped, "commands": fixture.commands,
                                    "expected_outputs": fixture.outputs,
                                    "transform_identity_checks": fixture.tile_checks,
                                    "configuration_records": fixture.configs})
    with (args.out / "vectors.json").open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
