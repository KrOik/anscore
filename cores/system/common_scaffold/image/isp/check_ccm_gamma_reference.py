#!/usr/bin/env python3
"""Standalone Icarus/independent-Python regression for ISP CCM and Gamma LUT.

Official algorithm references (pinned OpenCV source):
* cv::transform describes per-pixel matrix/affine color transforms:
  https://github.com/opencv/opencv/blob/9b6287ec500ef7b327ac74c4f6c9cd84a2cbc9cd/modules/core/include/opencv2/core.hpp#L1808-L1829
* OpenCV's 8-bit LUT implementation indexes one shared or channel-specific
  table by the source byte:
  https://github.com/opencv/opencv/blob/9b6287ec500ef7b327ac74c4f6c9cd84a2cbc9cd/modules/core/src/lut.cpp#L25-L38

OpenCV's transform reference is floating/generic and does not define this
RTL's fixed-point rounding. The local CCM contract is signed Q6.10 with
((sum + 512) arithmetic-shift-right 10) followed by integer bias and clip;
Gamma is a host-loaded RGB888 -> RGB888 direct 256-entry/channel lookup with
no interpolation or curve-generation step. The Python model implements those
local fixed-point limits independently of the RTL.
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
TB = SIM_DIR / "tb_isp_ccm_gamma_reference.v"
CCM_RTL = HERE / "img_isp_ccm.v"
GAMMA_RTL = HERE / "img_isp_gamma_lut.v"
SUMMARY = SIM_DIR / "ccm_gamma_reference_summary.json"
FAILURE = SIM_DIR / "ccm_gamma_reference_failure.json"
OPENCV_COMMIT = "9b6287ec500ef7b327ac74c4f6c9cd84a2cbc9cd"
REFERENCE_URLS = {
    "ccm": f"https://github.com/opencv/opencv/blob/{OPENCV_COMMIT}/modules/core/include/opencv2/core.hpp#L1808-L1829",
    "gamma_lut": f"https://github.com/opencv/opencv/blob/{OPENCV_COMMIT}/modules/core/src/lut.cpp#L25-L38",
    "commit_api": "https://api.github.com/repos/opencv/opencv/commits/4.x",
}

MATRIX_1 = [512, -256, 128, -512, 256, 512, 1024, 512, -2048, 3, -5, 12]
MATRIX_2 = [512, 0, 0, -512, 0, 0, 0, 0, 1024, 0, 0, -1]
OUTPUT_KEYS = ("ccm", "gamma", "ccm_sof", "ccm_eol", "gamma_sof", "gamma_eol")


def make_vectors(random_count: int) -> list[dict[str, int]]:
    vectors: list[dict[str, int]] = []

    def add_stage(stage: int, pixels: list[tuple[int, int, int]], line_width: int) -> None:
        for offset, (r, g, b) in enumerate(pixels):
            vectors.append({
                "stage": stage, "r": r & 255, "g": g & 255, "b": b & 255,
                "sof": int(offset == 0),
                "eol": int((offset % line_width == line_width - 1) or offset == len(pixels) - 1),
            })

    add_stage(0, [
        (0, 0, 0), (255, 255, 255), (1, 2, 3), (127, 128, 129),
        (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 1, 127),
    ], 4)

    # Exhaust every 8-bit address independently in all three LUT channels;
    # add asymmetric RGB tuples to catch channel/address wiring swaps.
    stage1 = [(x, x, x) for x in range(256)]
    stage1 += [(x, 255 - x, (7 * x + 13) & 255) for x in range(32)]
    add_stage(1, stage1, 16)

    # Matrix 2 creates exact positive and negative half-LSB cases around the
    # signed Q6.10 rounding boundary, plus clamp and cross-channel cases.
    stage2 = [
        (0, 0, 0), (1, 0, 0), (2, 0, 0), (3, 0, 0), (4, 0, 0),
        (255, 0, 0), (0, 255, 0), (0, 0, 255), (1, 1, 1),
        (255, 255, 255), (3, 2, 1), (5, 0, 1), (7, 1, 2),
    ]
    rng = random.Random(0xCC6A_21F5)
    for _ in range(random_count):
        stage2.append(tuple(rng.randrange(256) for _ in range(3)))
    add_stage(2, stage2, 16)
    return vectors


def matrix_for(stage: int) -> list[int] | None:
    if stage == 1:
        return MATRIX_1
    if stage == 2:
        return MATRIX_2
    return None


def clip8(value: int) -> int:
    return min(255, max(0, value))


def ccm_reference(v: dict[str, int]) -> tuple[int, int, int]:
    matrix = matrix_for(v["stage"])
    if matrix is None:
        return v["r"], v["g"], v["b"]
    pixels = (v["r"], v["g"], v["b"])
    out = []
    for row in range(3):
        acc = sum(matrix[row * 3 + col] * pixels[col] for col in range(3))
        # Python's signed right shift is arithmetic and rounds negative values
        # toward -infinity after the +512 bias, matching the RTL contract.
        q = ((acc + 512) >> 10) + matrix[9 + row]
        out.append(clip8(q))
    return tuple(out)


def gamma_lut(channel: int, address: int) -> int:
    if channel == 0:
        return (address * 3 + 5) & 255
    if channel == 1:
        return 255 - address
    return address ^ 0xA5


def gamma_reference(v: dict[str, int]) -> tuple[int, int, int]:
    if v["stage"] == 0:
        return v["r"], v["g"], v["b"]
    return (gamma_lut(0, v["r"]), gamma_lut(1, v["g"]), gamma_lut(2, v["b"]))


def find_tool(name: str) -> Path:
    env_key = "IVERILOG" if name == "iverilog" else "VVP"
    override = os.environ.get(env_key)
    if override:
        return Path(override)
    bundled = ROOT / "tools" / "oss-cad-suite" / "oss-cad-suite" / "bin" / f"{name}.exe"
    if bundled.exists():
        return bundled
    located = shutil.which(name)
    if located:
        return Path(located)
    raise FileNotFoundError(f"{name} not found; set {env_key} to its executable path")


def write_vectors(path: Path, vectors: list[dict[str, int]]) -> None:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for v in vectors:
            f.write(f"{v['stage']} {v['r']:02x} {v['g']:02x} {v['b']:02x} {v['sof']} {v['eol']}\n")


def parse_output(stdout: str) -> tuple[list[dict[str, int]], dict[str, int] | None]:
    actual: list[dict[str, int]] = []
    done = None
    for raw in stdout.splitlines():
        line = raw.strip()
        if line.startswith("OUT "):
            parts = line.split()
            if len(parts) != len(OUTPUT_KEYS) + 2:
                raise ValueError(f"malformed simulator output: {line}")
            index = int(parts[1])
            if index != len(actual):
                raise ValueError(f"output index gap: expected {len(actual)}, got {index}")
            values = [int(parts[2], 16), int(parts[3], 16), *map(int, parts[4:])]
            actual.append(dict(zip(OUTPUT_KEYS, values)))
        elif line.startswith("DONE "):
            values = list(map(int, line.split()[1:]))
            if len(values) != 4:
                raise ValueError(f"malformed DONE record: {line}")
            done = dict(zip(("accepted", "produced", "ce_stalls", "backpressure_stalls"), values))
    return actual, done


def run(args: argparse.Namespace) -> int:
    for path in (TB, CCM_RTL, GAMMA_RTL):
        if not path.is_file():
            raise FileNotFoundError(f"required input missing: {path}")
    iverilog, vvp = find_tool("iverilog"), find_tool("vvp")
    vectors = make_vectors(args.random_count)

    with tempfile.TemporaryDirectory(prefix="isp_ccm_gamma_") as temp_name:
        temp = Path(temp_name)
        sim_path, vector_path = temp / "isp_reference.vvp", temp / "vectors.txt"
        write_vectors(vector_path, vectors)
        suite_root = ROOT / "tools" / "oss-cad-suite" / "oss-cad-suite"
        process_env = os.environ.copy()
        if suite_root.is_dir() and iverilog.parent == suite_root / "bin":
            process_env["YOSYSHQ_ROOT"] = str(suite_root) + os.sep
            process_env["PATH"] = os.pathsep.join((
                str(suite_root / "bin"), str(suite_root / "lib"),
                str(suite_root / "lib" / "ivl"), process_env.get("PATH", ""),
            ))
        compile_cmd = [str(iverilog), "-g2012", "-s", "tb_isp_ccm_gamma_reference",
                       "-o", str(sim_path), str(TB), str(CCM_RTL), str(GAMMA_RTL)]
        compiled = subprocess.run(compile_cmd, text=True, capture_output=True, check=False, env=process_env)
        if compiled.returncode:
            raise RuntimeError("Icarus compile failed\n" + compiled.stdout + compiled.stderr)
        simulated = subprocess.run([str(vvp), str(sim_path), f"+INFILE={vector_path}"],
                                   text=True, capture_output=True, check=False, env=process_env)
        if simulated.returncode:
            raise RuntimeError("Icarus simulation failed\n" + simulated.stdout + simulated.stderr)
        actual, done = parse_output(simulated.stdout)
        sim_stdout = simulated.stdout

    failure = None
    if done is None:
        failure = {"kind": "missing_done_record", "stdout_tail": sim_stdout[-3000:]}
    elif done["accepted"] != len(vectors) or done["produced"] != len(vectors):
        failure = {"kind": "transaction_count", "expected": len(vectors), "actual": done}
    elif len(actual) != len(vectors):
        failure = {"kind": "output_count", "expected": len(vectors), "actual": len(actual)}
    elif not done["ce_stalls"] or not done["backpressure_stalls"]:
        failure = {"kind": "stall_coverage", "actual": done}
    else:
        for i, (v, got) in enumerate(zip(vectors, actual)):
            ccm_rgb, gamma_rgb = ccm_reference(v), gamma_reference(v)
            want = {
                "ccm": (ccm_rgb[0] << 16) | (ccm_rgb[1] << 8) | ccm_rgb[2],
                "gamma": (gamma_rgb[0] << 16) | (gamma_rgb[1] << 8) | gamma_rgb[2],
                "ccm_sof": v["sof"], "ccm_eol": v["eol"],
                "gamma_sof": v["sof"], "gamma_eol": v["eol"],
            }
            if got != want:
                failure = {"kind": "numeric_mismatch", "index": i, "input": v,
                           "expected": want, "actual": got}
                break

    if failure:
        report = {
            "status": "failed", "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "vector_count": len(vectors), "reference_urls": REFERENCE_URLS, "failure": failure,
        }
        args.failure_path.parent.mkdir(parents=True, exist_ok=True)
        args.failure_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
        return 1

    digest = hashlib.sha256(json.dumps(vectors, sort_keys=True).encode()).hexdigest()
    report = {
        "status": "passed", "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "modules": ["img_isp_ccm", "img_isp_gamma_lut"],
        "vector_count": len(vectors), "random_stage2_vectors": args.random_count,
        "vector_set_sha256": digest,
        "coverage": {
            "ccm": "reset identity; 2 staged/committed signed Q6.10 matrices; cross-channel terms, positive/negative half-LSB cases, signed offsets, lower/upper clipping",
            "gamma": "RGB888 bypass then three independently loaded channel LUTs; every address 0..255 exercised in every channel; no interpolation tested/claimed",
            "stream": "ready/valid alignment, SOF/EOL propagation, CE pause, output stability during CE pause and backpressure",
        "latency": {
            "ccm": "four enabled-edge stages from accepted input through output; initiation interval one",
            "gamma": "one enabled edge in Gamma; testbench adds three elastic comparison-alignment stages",
        },
        },
        "reference_urls": REFERENCE_URLS,
        "limits": {
            "ccm": "8-bit RGB input/output, signed 16-bit Q6.10 coefficients, signed 16-bit integer biases, local +512/>>>10 rounding and uint8 saturation; not exhaustive over all coefficient triples",
            "gamma": "8-bit input/output, 256 addresses per channel, arbitrary loaded tables; does not verify a gamma curve generator or LUT memory inference",
        },
        "synthesis": "not run", "board": "not run",
        "temporary_artifacts": "removed after run",
        "accepted": done["accepted"], "produced": done["produced"],
        "ce_stall_cycles": done["ce_stalls"],
        "backpressure_stall_cycles": done["backpressure_stalls"],
    }
    args.summary_path.parent.mkdir(parents=True, exist_ok=True)
    args.summary_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--random-count", type=int, default=64)
    parser.add_argument("--summary", type=Path, default=SUMMARY,
                        help="write this run's summary here (default preserves the legacy path)")
    parser.add_argument("--failure", type=Path, default=FAILURE,
                        help="write a failure report here; an existing report is never removed")
    args = parser.parse_args()
    args.summary_path = args.summary.resolve()
    args.failure_path = args.failure.resolve()
    if args.random_count < 0:
        parser.error("--random-count must be nonnegative")
    try:
        return run(args)
    except Exception as exc:
        report = {
            "status": "failed", "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "reference_urls": REFERENCE_URLS,
            "failure": {"kind": "runner_error", "message": str(exc)},
        }
        args.failure_path.parent.mkdir(parents=True, exist_ok=True)
        args.failure_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
