#!/usr/bin/env python3
"""Independent unbounded-integer oracle; no RTL radix recurrence is reused."""
from __future__ import annotations

import hashlib
import json
import random
from pathlib import Path

HERE = Path(__file__).resolve().parent
ISP = HERE.parents[1]
LEGACY = (ISP / "evidence/production_awb_v95_20261017/regression/solver_vectors.mem")
HELPER_WIDTHS = (1, 2, 3, 7, 49, 50, 51)
AUTOGAIN_WIDTHS = (1, 8, 9, 13, 16, 17, 48, 49)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pack(fields: list[tuple[int, int]]) -> int:
    value = 0
    offset = 0
    for field, width in fields:
        if not 0 <= field < (1 << width):
            raise ValueError((field, width))
        value |= field << offset
        offset += width
    return value


def awb_reference(r: int, g: int, b: int, count: int, frame: int,
                  overflow: int, minimum: int, maximum: int) -> tuple[int, int, int, int, int]:
    error = int(count == 0) | (overflow << 1) | (int(minimum > maximum) << 2)
    if error or r + g + b == 0:
        return 256, 256, 256, frame, error
    target = (r + g + b) // 3
    gains = []
    for channel in (r, g, b):
        if channel == 0:
            gains.append(maximum)
            error |= 8
        else:
            gains.append(min(max((target << 8) // channel, minimum), maximum))
    return *gains, frame, error


def awb_packed(width: int, row: tuple[int, ...]) -> int:
    r, g, b, count, frame, overflow, minimum, maximum = row
    gr, gg, gb, out_frame, error = awb_reference(*row)
    return pack([(r, width), (g, width), (b, width), (count, 32), (frame, 32),
                 (overflow, 1), (minimum, 16), (maximum, 16),
                 (gr, 16), (gg, 16), (gb, 16), (out_frame, 32), (error, 8)])


def unpack_legacy(value: int) -> tuple[int, ...]:
    fields = []
    for width in (48, 48, 48, 32, 32, 1, 16, 16):
        fields.append(value & ((1 << width) - 1))
        value >>= width
    return tuple(fields)


def helper_vectors(width: int) -> tuple[list[int], dict[str, object]]:
    rng = random.Random(0xD13320261017 + width)
    maximum = (1 << width) - 1
    numbers: set[int] = set()
    categories: dict[str, int] = {}

    def add(tag: str, values) -> None:
        before = len(numbers)
        numbers.update(n for n in values if 0 <= n <= maximum)
        categories[tag] = len(numbers) - before

    if width <= 7:
        add("exhaustive", range(maximum + 1))
    else:
        add("small_and_max_boundaries", [*range(128), *(maximum - k for k in range(64))])
        add("powers_of_two_neighbors", (2**k + delta for k in range(width + 1)
                                        for delta in (-2, -1, 0, 1, 2)))
        quotients = [0, 1, 2, 3, maximum // 3, maximum // 3 - 1]
        quotients += [2**k for k in range(width)]
        quotients += [rng.randrange(maximum // 3 + 1) for _ in range(256)]
        add("integer_multiple_of_three_neighbors", (3*q + delta for q in quotients
                                                     for delta in (-1, 0, 1)))
        add("random", (rng.getrandbits(width) for _ in range(4096 if width == 50 else 128)))
    ordered = sorted(numbers)
    encoded = [pack([(n % 3, 2), (n // 3, width), (n, width)]) for n in ordered]
    return encoded, {"width": width, "vectors": len(encoded), "unique_categories": categories,
                     "seed": 0xD13320261017 + width,
                     "oracle": "Python unbounded int n//3 and n%3"}


def autogain_vectors(width: int) -> tuple[list[int], dict[str, object]]:
    rng = random.Random(0xA8B20261017 + width)
    maximum = (1 << width) - 1
    packed: list[int] = []
    labels: list[str] = []
    legacy_count = 0
    if width == 48:
        # Read old goldens without rewriting them. Recompute and cross-check
        # every expected field with the independent integer specification.
        legacy = [int(line.strip().split()[0], 16) for line in LEGACY.read_text().splitlines()
                  if line.strip() and not line.lstrip().startswith("//")]
        if len(legacy) != 17:
            raise RuntimeError("v95 legacy fixture must contain exactly 17 vectors")
        for index, value in enumerate(legacy):
            regenerated = awb_packed(width, unpack_legacy(value))
            if regenerated != value:
                raise RuntimeError(f"legacy golden disagrees with integer oracle, vector {index}")
            packed.append(regenerated)
            labels.append(f"unchanged_legacy_v95_{index}")
        legacy_count = len(legacy)

    def add(tag: str, r: int, g: int, b: int, count: int = 1,
            overflow: int = 0, minimum: int = 0, cap: int = 1024) -> None:
        row = (r & maximum, g & maximum, b & maximum, count,
               (0xA0000000 | len(packed)) & 0xFFFFFFFF, overflow, minimum, cap)
        packed.append(awb_packed(width, row))
        labels.append(tag)

    # Explicit black neutral contract even when 256 lies outside the bounds.
    for minimum, cap in ((0, 0), (0, 100), (300, 400), (65535, 65535), (0, 65535)):
        add("black_neutral_outside_clamp", 0, 0, 0, minimum=minimum, cap=cap)
    for r, g, b in ((maximum, maximum, maximum), (maximum, 1, 1),
                    (1, maximum, 1), (1, 1, maximum),
                    (maximum, 0, 0), (0, maximum, 0), (0, 0, maximum),
                    (maximum, maximum, 0), (0, maximum, maximum), (maximum, 0, maximum),
                    (1, 0, 0), (1, 1, 0), (1, 1, 1), (2, 0, 0), (2, 1, 0),
                    (maximum, maximum-1, max(0, maximum-2))):
        for minimum, cap in ((0, 65535), (9, 1024), (300, 300), (0, 0)):
            add("directed_floor_zero_and_clamp", r, g, b, minimum=minimum, cap=cap)
    # All metadata-error combinations, with neutral outputs preserved.
    for count_zero in (False, True):
        for overflow in (0, 1):
            for invalid_bounds in (False, True):
                if not (count_zero or overflow or invalid_bounds):
                    continue
                add("metadata_error_combination", maximum, 1, 0,
                    count=0 if count_zero else 0xFFFFFFFF, overflow=overflow,
                    minimum=65535 if invalid_bounds else 5, cap=1024)
    # Exercise byte, 16-bit-group, and high numerator boundaries independently.
    for bit in range(width):
        if bit % 8 == 0 or bit % 16 in (14, 15) or bit == width-1:
            for delta in (-1, 0, 1):
                channel = max(0, min(maximum, (1 << bit) + delta))
                add("channel_group_and_byte_neighbors", maximum, channel, max(1, maximum // 7))
    for _ in range(160 if width == 48 else 32):
        lo = rng.randrange(65536)
        hi = rng.randrange(lo, 65536)
        sums = [rng.getrandbits(width) for _ in range(3)]
        if rng.randrange(8) == 0:
            sums[rng.randrange(3)] = 0
        add("random", *sums, count=rng.randrange(1, 1 << 32), minimum=lo, cap=hi)
    return packed, {"width": width, "vectors": len(packed), "legacy_unchanged_vectors": legacy_count,
                    "seed": 0xA8B20261017 + width, "labels": labels,
                    "oracle": "Python unbounded integer mean floor, per-channel floor, clamp and explicit error bits"}


def write_mem(path: Path, values: list[int], width: int) -> None:
    digits = (width + 3) // 4
    path.write_text("".join(f"{value:0{digits}x}\n" for value in values), encoding="ascii")


def generate() -> dict[str, object]:
    manifest: dict[str, object] = {"helper": [], "autogain": [],
        "legacy_read_only_fixture": {"path": str(LEGACY.relative_to(HERE.parents[5])).replace("\\", "/"),
                                     "sha256": sha(LEGACY)}}
    for width in HELPER_WIDTHS:
        values, record = helper_vectors(width)
        path = HERE / f"helper_vectors_w{width}.mem"
        write_mem(path, values, 2*width+2)
        record.update(file=path.name, sha256=sha(path))
        manifest["helper"].append(record)
    for width in AUTOGAIN_WIDTHS:
        values, record = autogain_vectors(width)
        path = HERE / f"autogain_vectors_w{width}.mem"
        write_mem(path, values, 3*width+185)
        record.update(file=path.name, sha256=sha(path))
        manifest["autogain"].append(record)
    (HERE / "vectors_manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    result = generate()
    print(f"AWB_DIV3_VECTORS_PASS helper_widths={len(result['helper'])} autogain_widths={len(result['autogain'])}")
