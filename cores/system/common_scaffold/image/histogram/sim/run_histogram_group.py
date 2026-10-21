#!/usr/bin/env python3
"""Small frame-level HE/CLAHE regression; no board, synthesis or per-IP suite.

Independent Python integer reference checks the complete captured/replayed
image, framing, tags, frame counts, errors, strict clipping and tile-center
interpolation. Each invocation keeps all artifacts, including failures.
"""
from __future__ import annotations

import bisect
import collections
import datetime as dt
from fractions import Fraction
import json
from pathlib import Path
import random
import shutil
import subprocess
import sys


GROUP = Path(__file__).resolve().parents[1]
REPO = GROUP.parents[3]
RTL = sorted((GROUP / "rtl").glob("*.v"))


def executable(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for suffix in (".exe", ""):
        local = REPO / "tools/oss-cad-suite/oss-cad-suite/bin" / (name + suffix)
        if local.exists():
            return str(local)
    raise RuntimeError(f"{name} unavailable; first load scripts/env.ps1")


def run_tool(command: list[str], log: Path) -> str:
    completed = subprocess.run(command, capture_output=True, text=True,
                               timeout=120, cwd=REPO)
    transcript = completed.stdout + completed.stderr
    log.write_text(transcript, encoding="utf-8")
    if completed.returncode or any(line.startswith(("ERROR:", "FATAL:"))
                                   for line in transcript.splitlines()):
        raise RuntimeError(f"exit={completed.returncode}: {' '.join(command)}; log={log}")
    return transcript


def he_lut(values: list[int]) -> list[int]:
    hist = collections.Counter(values)
    occupied = sorted(hist)
    if len(occupied) == 1:
        # A constant image is preserved, including a nonzero constant.
        return list(range(256))
    minimum = hist[occupied[0]]
    cdf = 0
    lut = []
    for gray in range(256):
        cdf += hist[gray]
        lut.append(max(0, 255 * (cdf - minimum) // (len(values) - minimum)))
    return lut


def strict_clip(values: list[int], clip: int) -> list[int]:
    hist = collections.Counter(values)
    if clip < 1 or len(values) > 256 * clip:
        raise ValueError("strict clipping capacity is insufficient")
    result = [min(hist[i], clip) for i in range(256)]
    remaining = len(values) - sum(result)
    # Mathematical redistribution policy: repeated ascending round-robin
    # allocation over bins that still have capacity, with no saturation loss.
    while remaining:
        available = [i for i, count in enumerate(result) if count < clip]
        assert available
        for i in available[:remaining]:
            result[i] += 1
            remaining -= 1
    assert sum(result) == len(values) and max(result) <= clip
    return result


def coordinates(index: int, size: int, tiles: int, fraction_bits: int):
    centers = [Fraction((2 * tile + 1) * size - 1, 2) for tile in range(tiles)]
    if index <= centers[0]:
        return 0, 0, 0
    if index >= centers[-1]:
        return tiles - 1, tiles - 1, 0
    hi = bisect.bisect_right(centers, index)
    lo = hi - 1
    fraction = (Fraction(index) - centers[lo]) / size
    return lo, hi, int(fraction * (1 << fraction_bits))


def clahe(values: list[int], width: int, height: int, tw: int, th: int,
          clip: int, fraction_bits: int) -> list[int]:
    nx, ny = width // tw, height // th
    luts = []
    for ty in range(ny):
        for tx in range(nx):
            tile = [values[y * width + x]
                    for y in range(ty * th, (ty + 1) * th)
                    for x in range(tx * tw, (tx + 1) * tw)]
            hist = strict_clip(tile, clip)
            cdf = 0
            lut = []
            for count in hist:
                cdf += count
                lut.append(255 * cdf // len(tile))
            luts.append(lut)
    scale = 1 << fraction_bits
    result = []
    for y in range(height):
        y0, y1, fy = coordinates(y, th, ny, fraction_bits)
        for x in range(width):
            x0, x1, fx = coordinates(x, tw, nx, fraction_bits)
            gray = values[y * width + x]
            weighted = (
                luts[y0 * nx + x0][gray] * (scale - fx) * (scale - fy)
                + luts[y0 * nx + x1][gray] * fx * (scale - fy)
                + luts[y1 * nx + x0][gray] * (scale - fx) * fy
                + luts[y1 * nx + x1][gray] * fx * fy
            )
            result.append((weighted + scale * scale // 2) // (scale * scale))
    return result


def cases():
    rng = random.Random(20261015)
    w, h = 12, 8
    ramp = [(17 * i) % 256 for i in range(w * h)]
    gradient = [((i % w) * 13 + (i // w) * 23) % 256 for i in range(w * h)]
    noise = [rng.randrange(256) for _ in range(w * h)]
    clustered = [25 + ((i % w) // 4 + 3 * ((i // w) // 4)) * 31
                 for i in range(w * h)]
    # Frame tuple is pixels, absolute bin clip limit, framing corruption.
    yield dict(name="he", width=w, height=h, tw=4, th=4, adaptive=0, fb=8,
               frames=[([73] * (w * h), 0, 0), (ramp, 0, 0),
                       (noise, 0, 0), (gradient, 0, 1),
                       (ramp, 0, 2), (gradient, 0, 0)])
    yield dict(name="clahe_multitile", width=w, height=h, tw=4, th=4,
               adaptive=1, fb=8,
               frames=[(clustered, 1, 0), (gradient, 2, 0),
                       (noise, 3, 0), (ramp, 0, 0),
                       (clustered, 1, 1), (noise, 2, 2), (ramp, 1, 0)])
    w, h, tw, th = 32, 32, 16, 32
    # 512 pixels/tile with clip=2 fills all 256 bins and needs multiple
    # redistribution sweeps. Two distinct tile LUTs and both border paths
    # are exercised in the final clip=3 frame.
    dense = [201 if i % w < tw else 5 for i in range(w * h)]
    mixed = [(11 if i % w < tw else (i // w) * 7) for i in range(w * h)]
    noise = [rng.randrange(256) for _ in range(w * h)]
    yield dict(name="clahe_strict_multisweep", width=w, height=h, tw=tw, th=th,
               adaptive=1, fb=6,
               frames=[(dense, 2, 0), (mixed, 2, 0), (dense, 1, 0),
                       (dense, 2, 1), (noise, 3, 0)])


def run_case(case: dict, result_dir: Path, iverilog: str, vvp: str) -> dict:
    name = case["name"]
    frames = case["frames"]
    width, height = case["width"], case["height"]
    pixels = width * height
    raw_file = result_dir / f"{name}_input.hex"
    cfg_file = result_dir / f"{name}_config.hex"
    image = result_dir / f"{name}.vvp"
    raw_file.write_text("".join(f"{v:02x}\n" for data, _, _ in frames for v in data),
                        encoding="ascii")
    configs = []
    expected = []
    for data, clip, bad in frames:
        invalid = bool(case["adaptive"] and
                       (clip == 0 or 256 * clip < case["tw"] * case["th"]))
        configs.append(clip | (bad << 16) | (int(invalid) << 18))
        if invalid:
            expected.append(([], (1, 1, 0)))
        elif bad:
            expected.append(([], (1, 2, pixels)))
        elif case["adaptive"]:
            mapped = clahe(data, width, height, case["tw"], case["th"],
                           clip, case["fb"])
            expected.append((mapped, (0, 0, pixels)))
        else:
            lut = he_lut(data)
            expected.append(([lut[gray] for gray in data], (0, 0, pixels)))
    cfg_file.write_text("".join(f"{v:08x}\n" for v in configs), encoding="ascii")
    command = [iverilog, "-g2012", "-Wall", "-s", "tb_histogram_group", "-o", str(image)]
    for parameter, value in {
        "FRAME_WIDTH": width, "FRAME_HEIGHT": height,
        "TILE_WIDTH": case["tw"], "TILE_HEIGHT": case["th"],
        "ADAPTIVE": case["adaptive"], "FRAME_COUNT": len(frames),
        "FRACTION_BITS": case["fb"],
    }.items():
        command += [f"-Ptb_histogram_group.{parameter}={value}"]
    command += [str(path) for path in RTL] + [str(GROUP / "sim/tb_histogram_group.sv")]
    run_tool(command, result_dir / f"{name}_compile.log")
    transcript = run_tool([vvp, str(image), f"+INPUT={raw_file}", f"+CONFIG={cfg_file}"],
                          result_dir / f"{name}_simulation.log")
    outputs = collections.defaultdict(list)
    completions = collections.defaultdict(list)
    for line in transcript.splitlines():
        fields = line.split()
        if fields and fields[0] == "O":
            frame = int(fields[1])
            outputs[frame].append(tuple(map(int, fields[2:])))
        elif fields and fields[0] == "D":
            frame = int(fields[1])
            completions[frame].append(tuple(map(int, fields[2:])))
    assert "TB_COMPLETE" in transcript, f"{name}: no successful TB completion"
    assert set(outputs) <= set(range(len(frames))), f"{name}: output escaped reset/frame ownership"
    for frame, (mapped, done) in enumerate(expected):
        tag = 0x100 + frame
        assert len(outputs[frame]) == len(mapped), (
            f"{name} frame={frame}: output count {len(outputs[frame])} != {len(mapped)}")
        for index, gray in enumerate(mapped):
            want = (gray, int(index == 0), int(index % width == width - 1),
                    int(index == pixels - 1), tag, 0)
            assert outputs[frame][index] == want, (
                f"{name} frame={frame} pixel={index}: got={outputs[frame][index]} want={want}")
        assert completions[frame] == [(*done, tag)], (
            f"{name} frame={frame}: completion {completions[frame]} != {(*done, tag)}")
    assert set(completions) == set(range(len(frames)))
    result = dict(name=name, pass_result=True, frames=len(frames),
                  checked_pixels=sum(len(mapped) for mapped, _ in expected),
                  error_frames=sum(bool(done[0]) for _, done in expected))
    print(f"PASS {name}: {result['frames']} frames; {result['checked_pixels']} pixels; "
          f"{result['error_frames']} explicit error completions")
    return result


def main() -> int:
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    result_dir = GROUP / "sim/results" / stamp
    result_dir.mkdir(parents=True, exist_ok=False)
    summary = {"scope": "frame_level_group_smoke", "result_dir": str(result_dir), "cases": []}
    try:
        iverilog, vvp = executable("iverilog"), executable("vvp")
        run_tool([iverilog, "-g2012", "-Wall", "-tnull", *map(str, RTL)],
                 result_dir / "all_rtl_compile.log")
        print(f"PASS all RTL compile: {len(RTL)} modules")
        for case in cases():
            summary["cases"].append(run_case(case, result_dir, iverilog, vvp))
        summary["pass_result"] = True
    except Exception as exc:
        summary["pass_result"] = False
        summary["failure"] = repr(exc)
        (result_dir / "failure.log").write_text(repr(exc) + "\n", encoding="utf-8")
        print(f"FAIL: {exc}", file=sys.stderr)
    (result_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n",
                                            encoding="utf-8")
    print(f"Artifacts: {result_dir}")
    return 0 if summary["pass_result"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
