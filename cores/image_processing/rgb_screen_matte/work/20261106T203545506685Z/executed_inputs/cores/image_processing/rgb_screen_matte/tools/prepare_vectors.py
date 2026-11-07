# SPDX-License-Identifier: Apache-2.0
"""Prepare a finite independent vector set, only after exact source approval."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import sys

PACKAGE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE))
from reference_model import matte_over, nearest_even, screen_matte
from fractions import Fraction


def distance(rgb, key):
    r, g, b = rgb >> 16, (rgb >> 8) & 255, rgb & 255
    kr, kg, kb = key >> 16, (key >> 8) & 255, key & 255
    return ((b - g) - (kb - kg))**2 + ((r - g) - (kr - kg))**2


def cases():
    rng = random.Random(0xB50C2026)
    rows = []
    # Every byte alpha occurs in exact denominator255 ramps; both screen axes.
    for rgb, key, screen in ((0x10C818, 0x00FF00, 0), (0x1810C8, 0x0000FF, 1)):
        metric = distance(rgb, key)
        if metric < 255:
            raise AssertionError("ramp fixture requires sufficient metric")
        for alpha in range(256):
            inner = metric - alpha
            rows.append((rgb, key, inner, inner + 255, alpha, screen))
    # Endpoints, equality, invalid windows, extreme metric and per-pixel toggles.
    for rgb, key in ((0, 0), (0xFFFFFF, 0), (0xFF00FF, 0x00FF00),
                     (0x00FF00, 0xFF00FF), (0x0000FF, 0x00FF00),
                     (0x010203, 0xFDFEFF), (0x64E68C, 0x00FF00)):
        metric = distance(rgb, key)
        windows = [(0, 0), (metric, metric), (0, metric), (metric, 524287),
                   (524287, 524287), (1, 0), (524287, 1)]
        if metric > 0:
            windows.append((metric - 1, metric - 1))
        if metric < 524287:
            windows.append((metric + 1, metric + 1))
        for inner, outer in windows:
            for strength in (0, 1, 127, 128, 254, 255):
                rows.append((rgb, key, inner, outer, strength, len(rows) % 2))
    # Exact half ties on both even and odd floor quotients.
    rgb, key = 0x10C818, 0x00FF00
    metric = distance(rgb, key)
    for numerator, denominator in ((1, 2), (1, 6), (3, 6), (5, 6), (1, 510), (3, 510)):
        rows.append((rgb, key, metric - numerator, metric - numerator + denominator, 173, 0))
    for _ in range(384):
        rgb, key = rng.randrange(1 << 24), rng.randrange(1 << 24)
        metric = distance(rgb, key)
        if rng.randrange(3) == 0 and metric:
            inner = rng.randrange(metric)
            outer = rng.randrange(metric + 1, 1 << 19)
        else:
            inner, outer = rng.randrange(1 << 19), rng.randrange(1 << 19)
        rows.append((rgb, key, inner, outer, rng.randrange(256), rng.randrange(2)))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    output = Path(args.output_dir).resolve()
    work_root = (PACKAGE / "work").resolve()
    if not output.is_relative_to(work_root) or output == work_root:
        raise ValueError("output directory must be a new child of package/work")
    output.mkdir(parents=True, exist_ok=False)
    if nearest_even(Fraction(85, 2)) != 42 or nearest_even(Fraction(255, 2)) != 128:
        raise AssertionError("independent nearest-even fixtures")
    if distance(0xFF00FF, 0x00FF00) != 520200:
        raise AssertionError("complete metric range fixture")
    known_metric = distance(0x10C818, 0x00FF00)
    if screen_matte(0x10C818, 0x00FF00, known_metric - 128,
                    known_metric + 127, 255, 0) != (0x080C0C80, 0):
        raise AssertionError("known alpha128 with full green excess removal")
    if matte_over(0x10C818, 0x00FF00, 1, 0, 255, 0, 0x01000000) != (0, 7):
        raise AssertionError("independent simultaneous configuration/background error")
    rng = random.Random(0x50C0FFEE)
    rows = cases()
    lines = [str(len(rows))]
    alpha_seen = set()
    invalid = ties = 0
    for index, row in enumerate(rows):
        rgb, key, inner, outer, strength, blue = row
        rgba, error = screen_matte(*row)
        alpha_seen.add(rgba & 255)
        invalid += error
        metric = distance(rgb, key)
        if inner < metric < outer:
            remainder = (255 * (metric - inner)) % (outer - inner)
            ties += int(2 * remainder == outer - inner)
        # Include opaque, transparent, partially premultiplied and invalid targets.
        if index % 17 == 0:
            background = 0x01000000  # red1 > alpha0: real production error3.
        else:
            alpha = (0, 255, rng.randrange(256))[index % 3]
            background = sum(rng.randrange(alpha + 1) << shift for shift in (24, 16, 8)) | alpha
        over, over_error = matte_over(*row, background)
        x, y, tag, user = rng.randrange(65536), rng.randrange(65536), rng.getrandbits(32), rng.getrandbits(32)
        if index < 4:
            x = (0, 65535, 32768, 32767)[index]
            y = (65535, 0, 32767, 32768)[index]
            tag = (0, 0xFFFFFFFF, 0x80000000, 1)[index]
            user = (0x80000001, 0xFFFFFFFF, 0, 0x7FFFFFFF)[index]
        sof, eol, last = int(index % 23 == 0), int(index % 19 == 18), int(index % 23 == 22)
        fields = (rgb, key, inner, outer, strength, blue, x, y, tag, sof, eol, last,
                  user, rgba, error, background, over, over_error)
        lines.append(" ".join(format(value, "x") for value in fields))
    if alpha_seen != set(range(256)) or invalid == 0 or ties < 4:
        raise AssertionError("finite independent fixture coverage")
    data = ("\n".join(lines) + "\n").encode("ascii")
    vector_path = output / "vectors.txt"
    with vector_path.open("xb") as target:
        target.write(data)
    summary = {"status": "PREPARATION_ONLY", "rows": len(rows), "alpha_values": len(alpha_seen),
               "invalid_windows": invalid, "exact_half_cases": ties,
               "vectors_sha256": hashlib.sha256(data).hexdigest(),
               "seed_cases": "0xB50C2026", "seed_metadata": "0x50C0FFEE"}
    with (output / "preparation.json").open("x", encoding="utf-8", newline="\n") as target:
        json.dump(summary, target, indent=2)
        target.write("\n")
    print(f"MATTE_PREP_PASS rows={len(rows)} alpha_values={len(alpha_seen)} invalid={invalid} ties={ties}")


if __name__ == "__main__":
    main()
