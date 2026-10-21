#!/usr/bin/env python3
"""Run standalone Icarus checks for the draft 3x3 image filters.

The Python formulas below are deliberately independent of the RTL. Simulator
outputs are parsed and compared transaction by transaction; all bulky simulator
files live in a temporary directory and are removed on exit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
SIM_DIR = HERE / "sim"
TB = SIM_DIR / "tb_img_filter_standalone_generated.v"
RTL = HERE / "rtl"
SUMMARY = SIM_DIR / "standalone_reference_summary.json"
FAILURE = SIM_DIR / "standalone_reference_failure.json"


def make_vectors(random_count: int) -> list[dict]:
    vectors: list[dict] = []

    def add(name: str, taps: list[int], threshold: int, invert: int,
            sof: int | None = None, eol: int | None = None) -> None:
        index = len(vectors)
        vectors.append({
            "name": name,
            "taps": [v & 0xFF for v in taps],
            "threshold": threshold & 0xFF,
            "invert": invert & 1,
            "sof": int(index == 0 if sof is None else sof),
            "eol": int(index % 7 == 6 if eol is None else eol),
        })

    add("zero", [0] * 9, 0, 0, sof=1, eol=0)
    add("full_scale", [255] * 9, 255, 0)
    add("constant_mid", [37] * 9, 37, 1)
    add("ramp", [i * 17 for i in range(9)], 68, 0)
    add("reverse_ramp", [255 - i * 17 for i in range(9)], 128, 1)
    add("center_impulse", [255 if i == 4 else 0 for i in range(9)], 254, 0)
    add("center_hole", [0 if i == 4 else 255 for i in range(9)], 255, 1)
    add("horizontal_step", [0, 0, 0, 0, 127, 255, 0, 127, 255], 127, 0)
    add("vertical_step", [0, 0, 255, 0, 0, 255, 0, 0, 255], 128, 1)
    add("checker", [255 if (i % 3 + i // 3) & 1 else 0 for i in range(9)], 1, 0)
    add("duplicates_median", [9, 9, 9, 64, 64, 64, 200, 200, 200], 64, 1)
    add("alternating_limits", [0, 255, 1, 254, 127, 128, 2, 253, 255], 255, 0)
    for impulse in range(9):
        add(f"impulse_{impulse}", [255 if i == impulse else 0 for i in range(9)],
            (impulse * 31) & 0xFF, impulse & 1)
    # Explicit threshold boundary triplets exercise >= and inversion.
    for value in (0, 1, 127, 128, 254, 255):
        add(f"threshold_equal_{value}", [value] * 9, value, 0)
        add(f"threshold_below_{value}", [max(0, value - 1)] * 9, value, 0)
        add(f"threshold_above_{value}", [min(255, value + 1)] * 9, value, 1)

    rng = random.Random(0x51A7_3F19)
    for i in range(random_count):
        taps = [rng.randrange(256) for _ in range(9)]
        # Mix generic random windows with structured near-boundary windows.
        if i % 4 == 0:
            taps = [rng.choice((0, 1, 127, 128, 254, 255)) for _ in range(9)]
        elif i % 4 == 1:
            taps = [rng.randrange(4) * 85 for _ in range(9)]
        add(f"seeded_{i}", taps, rng.randrange(256), i & 1)
    return vectors


def reference(v: dict) -> dict[str, int]:
    t = v["taps"]
    mean = (sum(t) + 4) // 9
    weights = (1, 2, 1, 2, 4, 2, 1, 2, 1)
    gaussian = (sum(a * b for a, b in zip(t, weights)) + 8) // 16
    gx_sobel = t[2] + 2 * t[5] + t[8] - t[0] - 2 * t[3] - t[6]
    gy_sobel = t[6] + 2 * t[7] + t[8] - t[0] - 2 * t[1] - t[2]
    gx_prewitt = t[2] + t[5] + t[8] - t[0] - t[3] - t[6]
    gy_prewitt = t[6] + t[7] + t[8] - t[0] - t[1] - t[2]
    mag_sobel = abs(gx_sobel) + abs(gy_sobel)
    mag_prewitt = abs(gx_prewitt) + abs(gy_prewitt)
    selected = int((t[4] >= v["threshold"]) ^ bool(v["invert"]))
    return {
        "sof": v["sof"], "eol": v["eol"],
        "mean": mean,
        "gaussian": gaussian,
        "median": sorted(t)[4],
        "sobel_data": min(255, mag_sobel),
        "sobel_gx": gx_sobel,
        "sobel_gy": gy_sobel,
        "sobel_mag": mag_sobel,
        "prewitt_data": min(255, mag_prewitt >> 2),
        "prewitt_gx": gx_prewitt,
        "prewitt_gy": gy_prewitt,
        "prewitt_mag": mag_prewitt,
        "threshold": 255 * selected,
        "erode_all": min(t),
        "dilate_all": max(t),
        "erode_asym": min(t[0], t[1]),
        # The RTL reflects the structuring-element offsets for dilation.
        "dilate_asym": max(t[8], t[7]),
    }


OUTPUT_KEYS = (
    "sof", "eol", "mean", "gaussian", "median", "sobel_data",
    "sobel_gx", "sobel_gy", "sobel_mag", "prewitt_data", "prewitt_gx",
    "prewitt_gy", "prewitt_mag", "threshold", "erode_all", "dilate_all",
    "erode_asym", "dilate_asym",
)


def find_tool(name: str) -> Path:
    env_name = "IVERILOG" if name == "iverilog" else "VVP"
    override = os.environ.get(env_name)
    if override:
        return Path(override)
    bundled = ROOT / "tools" / "oss-cad-suite" / "oss-cad-suite" / "bin" / f"{name}.exe"
    if bundled.exists():
        return bundled
    located = shutil.which(name)
    if located:
        return Path(located)
    raise FileNotFoundError(f"{name} not found; set {env_name} to the executable path")


def write_vectors(path: Path, vectors: list[dict]) -> None:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for v in vectors:
            f.write(" ".join(f"{x:02x}" for x in v["taps"]))
            f.write(f" {v['threshold']} {v['invert']} {v['sof']} {v['eol']}\n")


def parse_output(stdout: str) -> tuple[list[dict[str, int]], dict[str, int] | None]:
    actual: list[dict[str, int]] = []
    done = None
    for line in stdout.splitlines():
        line = line.strip()
        if line.startswith("OUT "):
            parts = line.split()
            if len(parts) != len(OUTPUT_KEYS) + 2:
                raise ValueError(f"malformed simulator output: {line}")
            index = int(parts[1])
            if index != len(actual):
                raise ValueError(f"output index gap: expected {len(actual)}, got {index}")
            try:
                values = list(map(int, parts[2:]))
            except ValueError as exc:
                raise ValueError(f"non-numeric output fields on line: {line}") from exc
            actual.append(dict(zip(OUTPUT_KEYS, values)))
        elif line.startswith("DONE "):
            fields = list(map(int, line.split()[1:]))
            if len(fields) != 4:
                raise ValueError(f"malformed DONE record: {line}")
            done = dict(zip(("accepted", "produced", "ce_stalls", "backpressure_stalls"), fields))
    return actual, done


def run(args: argparse.Namespace) -> int:
    if not TB.exists():
        raise FileNotFoundError(f"testbench missing: {TB}")
    iverilog = find_tool("iverilog")
    vvp = find_tool("vvp")
    vectors = make_vectors(args.random_count)
    rtl_files = [
        RTL / "img_filter_stream_register.v",
        RTL / "img_filter_kernel3x3.v",
        RTL / "img_filter_mean9_rom.v",
        RTL / "img_filter_median_sort3_segment.v",
        RTL / "img_filter_mean3x3.v",
        RTL / "img_filter_gaussian3x3.v",
        RTL / "img_filter_median3x3.v",
        RTL / "img_edge_gradient3x3.v",
        RTL / "img_edge_sobel3x3.v",
        RTL / "img_edge_prewitt3x3.v",
        RTL / "img_filter_threshold.v",
        RTL / "img_morph_erode3x3.v",
        RTL / "img_morph_dilate3x3.v",
    ]
    for path in [TB, *rtl_files]:
        if not path.is_file():
            raise FileNotFoundError(f"required input missing: {path}")

    with tempfile.TemporaryDirectory(prefix="img_filter_ref_") as temp_name:
        temp = Path(temp_name)
        sim_image = temp / "standalone.vvp"
        vector_file = temp / "vectors.txt"
        write_vectors(vector_file, vectors)
        suite_root = ROOT / "tools" / "oss-cad-suite" / "oss-cad-suite"
        process_env = os.environ.copy()
        if suite_root.is_dir() and iverilog.parent == suite_root / "bin":
            # The suite's Windows Icarus binaries need their sibling ivl tools
            # on PATH; otherwise they may fall back to an unrelated Chocolatey
            # installation even though the selected executable is bundled.
            process_env["YOSYSHQ_ROOT"] = str(suite_root) + os.sep
            process_env["PATH"] = os.pathsep.join((
                str(suite_root / "bin"), str(suite_root / "lib"),
                str(suite_root / "lib" / "ivl"), process_env.get("PATH", ""),
            ))
        compile_cmd = [str(iverilog), "-g2012", "-s", "tb_img_filter_standalone_generated",
                       "-o", str(sim_image), str(TB), *(str(p) for p in rtl_files)]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True, check=False, env=process_env)
        if compiled.returncode:
            raise RuntimeError("Icarus compile failed\n" + compiled.stdout + compiled.stderr)
        sim_cmd = [str(vvp), str(sim_image), f"+INFILE={vector_file}"]
        simulated = subprocess.run(sim_cmd, text=True, capture_output=True, check=False, env=process_env)
        if simulated.returncode:
            raise RuntimeError("Icarus simulation failed\n" + simulated.stdout + simulated.stderr)
        try:
            actual, done = parse_output(simulated.stdout)
        except Exception as exc:
            raise ValueError(f"cannot parse simulator output: {exc}\n{simulated.stdout[-6000:]}") from exc
        sim_text = simulated.stdout

    mismatch = None
    if done is None:
        mismatch = {"kind": "missing_done_record", "stdout_tail": sim_text[-3000:]}
    elif done["accepted"] != len(vectors) or done["produced"] != len(vectors):
        mismatch = {"kind": "transaction_count", "expected": len(vectors), "actual": done}
    elif done["ce_stalls"] == 0 or done["backpressure_stalls"] == 0:
        mismatch = {"kind": "stall_coverage", "actual": done}
    elif len(actual) != len(vectors):
        mismatch = {"kind": "output_count", "expected": len(vectors), "actual": len(actual)}
    else:
        for index, (v, got) in enumerate(zip(vectors, actual)):
            expected = reference(v)
            if got != expected:
                mismatch = {
                    "kind": "functional_mismatch", "index": index,
                    "vector": v, "expected": expected, "actual": got,
                }
                break

    if mismatch:
        report = {
            "status": "failed", "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "iverilog": str(iverilog), "vvp": str(vvp), "vector_count": len(vectors),
            "failure": mismatch,
        }
        FAILURE.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
        return 1

    if FAILURE.exists():
        FAILURE.unlink()
    vector_digest = hashlib.sha256(json.dumps(vectors, sort_keys=True).encode()).hexdigest()
    summary = {
        "status": "passed", "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "8-bit standalone datapath; default mean/Gaussian/median/Sobel/threshold/morphology plus Prewitt MAG_SHIFT=2 and asymmetric morphology masks",
        "vectors": len(vectors), "random_vectors": args.random_count,
        "vector_set_sha256": vector_digest,
        "checks": list(OUTPUT_KEYS) + ["ready/valid alignment", "CE pause", "backpressure stability"],
        "accepted": done["accepted"], "produced": done["produced"],
        "ce_stall_cycles": done["ce_stalls"],
        "backpressure_stall_cycles": done["backpressure_stalls"],
        "synthesis": "not run", "board": "not run",
        "temporary_artifacts": "removed after run",
    }
    SUMMARY.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


def main() -> int:
    global SUMMARY, FAILURE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--random-count", type=int, default=128,
                        help="number of seeded random/edge-valued windows (default: 128)")
    parser.add_argument("--evidence-dir", type=Path,
                        help="write new summary/failure records here, preserving prior evidence")
    args = parser.parse_args()
    if args.evidence_dir:
        args.evidence_dir.mkdir(parents=True, exist_ok=False)
        SUMMARY = args.evidence_dir / "standalone_reference_summary.json"
        FAILURE = args.evidence_dir / "standalone_reference_failure.json"
    if args.random_count < 0:
        parser.error("--random-count must be nonnegative")
    try:
        return run(args)
    except Exception as exc:
        report = {
            "status": "failed", "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "failure": {"kind": "runner_error", "message": str(exc)},
        }
        FAILURE.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
