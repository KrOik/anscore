#!/usr/bin/env python3
"""Run and freeze an explicitly selected isolated geometry candidate.

All generated benches, Icarus images, subprocess logs, and helper summaries
are staged below the selected candidate and removed before the durable
simulation summary is written. This runner never writes production RTL.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
DEVICE_FLOW_DIR = ROOT / "cores/signal_processing/dsp_isp_library/board/tang25k"
if str(DEVICE_FLOW_DIR) not in sys.path:
    sys.path.insert(0, str(DEVICE_FLOW_DIR))
CANDIDATES = {
    "image_resample_frame_selftest_25k_20261017_v102d":
        ROOT / "cores/system/common_scaffold/board/tang25k/build/image_resample_frame_selftest_25k_20261017_v102d",
}
V89I = ROOT / "cores/system/common_scaffold/board/tang25k/build/image_geometry_frame_selftest_25k_20261017_v89i"
V89J = ROOT / "cores/system/common_scaffold/board/tang25k/build/image_geometry_frame_selftest_25k_20261017_v89j"
EXPECTED_PASS = b"RSMP PASS C=11 I=0053 O=0096 E=06 D=4229D567\r\n"
EXPECTED_FAIL = b"RSMP FAIL C=01 I=0014 O=0009 E=00 D=03BED539\r\n"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def run_json_command(command: list[str], cwd: Path) -> tuple[dict, str]:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=180)
    output = result.stdout + result.stderr
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {command!r}\n{output[-12000:]}")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"command did not return JSON: {command!r}\n{output[-12000:]}") from error
    if payload.get("status") != "PASS":
        raise RuntimeError(f"command reported non-PASS: {command!r}\n{output[-12000:]}")
    return payload, output


def load_module(script: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, script)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load regression script: {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def copy(source: Path, target: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def verify_upstreams(candidate: Path) -> dict:
    command = [sys.executable, "-B", str(candidate / "verify_freeze.py"), "--verify-upstreams"]
    payload, _ = run_json_command(command, ROOT)
    if payload.get("upstream_geometry", {}).get("status") != "PASS":
        raise RuntimeError("candidate upstream geometry freeze proof is incomplete")
    provenance = read_json(candidate / "UPSTREAM_GEOMETRY_PROVENANCE.json")
    mapper_sha = provenance["dependencies"]["rtl/img_geo_inverse_map.v"]["upstream_sha256"]
    sampler_sha = provenance["dependencies"]["rtl/img_geo_frame_sampler.v"]["upstream_sha256"]
    if sha(candidate / "rtl/img_geo_inverse_map.v") != mapper_sha:
        raise RuntimeError("candidate mapper differs from its frozen v89j source")
    if sha(candidate / "rtl/img_geo_frame_sampler.v") != sampler_sha:
        raise RuntimeError("candidate sampler differs from its frozen v89i source")
    if mapper_sha != "9d259a6ed0ae0bc1e7c61c143cff5bd295f069621a5ec60fe954e73fee329c6d":
        raise RuntimeError("v89j mapper hash differs from the reviewed candidate input")
    if sampler_sha != "5258b99ead82b8875b7900f765fecf1588af3792b8484fe62dd6bb9199343449":
        raise RuntimeError("v89i sampler hash differs from the reviewed candidate input")
    return payload


def run_mapper_regression(candidate: Path, stage: Path) -> dict:
    source = V89J
    work = stage / "v89j_mapper_regression"
    work.mkdir()
    rtl = work / "rtl/img_geo_inverse_map.v"
    negative = work / "sim/img_geo_inverse_map_v89i_negative_control.v"
    bench = work / "sim/tb_img_geo_inverse_map_input_regression.sv"
    script = work / "run_mapper_input_regression.py"
    copy(candidate / "rtl/img_geo_inverse_map.v", rtl)
    copy(source / "sim/img_geo_inverse_map_v89i_negative_control.v", negative)
    copy(source / "sim/tb_img_geo_inverse_map_input_regression.sv", bench)
    copy(source / "run_mapper_input_regression.py", script)

    module = load_module(script, "candidate_v89j_mapper_input_regression")
    module.HERE = work
    module.RTL = rtl
    module.V89I_RTL = negative
    module.BENCH = bench
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        return_code = module.main()
    captured = output.getvalue()
    expected = "PYTHON INTEGER GOLDEN PASS cases=143"
    if return_code != 0 or expected not in captured or "V89I NEGATIVE CONTROL CONFIRMED" not in captured:
        raise RuntimeError("v89j mapper regression or v89i negative control failed:\n" + captured[-12000:])
    return {
        "status": "PASS",
        "cases": 143,
        "candidate_mapper_sha256": sha(rtl),
        "negative_control": "v89i fails on the q8=2^24 out-of-range vector as expected",
        "output_sha256": hashlib.sha256(captured.encode("utf-8")).hexdigest(),
    }


def run_sampler_regression(candidate: Path, stage: Path) -> dict:
    work = stage / "v89i_sampler_regression"
    rtl = work / "rtl/img_geo_frame_sampler.v"
    baseline = work / "sim/img_geo_frame_sampler_baseline.v"
    bench = work / "sim/tb_img_geo_frame_sampler_pipeline_contract.sv"
    script = work / "run_sampler_regression.py"
    copy(candidate / "rtl/img_geo_frame_sampler.v", rtl)
    copy(V89I / "sim/img_geo_frame_sampler_baseline.v", baseline)
    copy(V89I / "sim/tb_img_geo_frame_sampler_pipeline_contract.sv", bench)
    copy(V89I / "run_sampler_regression.py", script)

    module = load_module(script, "candidate_v89i_sampler_regression")
    module.HERE = work
    module.ROOT = ROOT
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = module.main()
    captured = output.getvalue()
    summary_path = work / "sampler_regression_summary.json"
    if not isinstance(result, dict) or not summary_path.is_file():
        raise RuntimeError("v89i sampler regression did not produce its temporary summary")
    summary = read_json(summary_path)
    if summary.get("status") != "PASS" or summary.get("source_sha256") != sha(rtl):
        raise RuntimeError("v89i sampler summary is stale or failed")
    configs = summary.get("configurations", [])
    directed = summary.get("directed_configurations", [])
    contracts = summary.get("direct_old_rtl_contract", [])
    if len(configs) != 6 or any(row.get("cases") != 433 for row in configs):
        raise RuntimeError("v89i sampler original 433-vector configurations are incomplete")
    if len(directed) != 6 or any(row.get("cases") != 28 for row in directed):
        raise RuntimeError("v89i directed sampler suite is incomplete")
    if len(contracts) != 6 or any(
        row.get("old_enabled_edges_after_last_response") != 1
        or row.get("new_enabled_edges_after_last_response") != 5
        or row.get("extra_enabled_edges") != 4
        or row.get("async_reset_replays") != 7
        for row in contracts
    ):
        raise RuntimeError("v89i old-sampler latency/reset contract is incomplete")
    return {
        "status": "PASS",
        "source_sha256": summary["source_sha256"],
        "original_configurations": len(configs),
        "original_cases_per_configuration": 433,
        "directed_configurations": len(directed),
        "directed_cases_per_configuration": 28,
        "old_rtl_contract_configurations": len(contracts),
        "extra_enabled_edges": 4,
        "async_reset_replays_per_configuration": 7,
        "output_sha256": hashlib.sha256(captured.encode("utf-8")).hexdigest(),
    }


def run_candidate_sim(candidate: Path, stage: Path) -> dict:
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        raise RuntimeError("PowerShell is required to run the candidate's build_and_sim.ps1")
    env = dict(os.environ)
    env["TEMP"] = str(stage)
    env["TMP"] = str(stage)
    env["TMPDIR"] = str(stage)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    script = candidate / "build_and_sim.ps1"
    command = [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)]
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                            text=True, encoding="utf-8", errors="replace", timeout=900)
    output = result.stdout + result.stderr
    if result.returncode:
        raise RuntimeError(f"v102d candidate simulation failed ({result.returncode}):\n{output[-16000:]}")
    markers = (
        "POR RESET TEST PASS cycles=4 release=2",
        "AREA DIVIDER RESET/CE TEST PASS",
        "UART=RSMP PASS C=11 I=0053 O=0096 E=06 D=4229D567",
        "UART=RSMP FAIL C=01 I=0014 O=0009 E=00 D=03BED539",
        "RESAMPLE SELFTEST PASS",
    )
    missing = [marker for marker in markers if marker not in output]
    if missing:
        raise RuntimeError("candidate simulation omitted required contract output "
                           + repr(missing) + ":\n" + output[-16000:])
    if (candidate / "expected_uart.txt").read_bytes() != EXPECTED_PASS:
        raise RuntimeError("normal UART fixture changed from the preserved 46-byte contract")
    if (candidate / "expected_uart_fault.txt").read_bytes() != EXPECTED_FAIL:
        raise RuntimeError("fault UART fixture changed from the preserved 46-byte contract")
    golden = read_json(candidate / "golden_summary.json")
    if (golden.get("case_count") != 17
            or golden.get("stored_input_pixels") != 78
            or golden.get("accepted_input_pixels_including_soft_reset_replays") != 83
            or golden.get("expected_output_pixels") != 150
            or golden.get("expected_error_responses") != 6
            or golden.get("expected_output_sum_hex", "").upper() != "4229D567"):
        raise RuntimeError("candidate Python golden no longer matches the preserved 17-case contract")
    return {
        "status": "PASS",
        "checks": [
            "independent Python golden generation: 17 cases / 78 stored pixels / 150 outputs",
            "synchronous frame-RAM structural gate",
            "area divider reset, replay, and clock-enable freeze",
            "top-level POR synchronizer",
            "normal 46-byte UART digest contract",
            "fault-injection 46-byte UART contract",
            "seven-snapshot local geometry dependencies",
        ],
        "golden": golden,
        "uart_contracts": {
            "normal_bytes": len(EXPECTED_PASS),
            "normal": EXPECTED_PASS.decode("ascii").rstrip("\r\n"),
            "fault_bytes": len(EXPECTED_FAIL),
            "fault": EXPECTED_FAIL.decode("ascii").rstrip("\r\n"),
        },
        "command_output_sha256": hashlib.sha256(output.encode("utf-8")).hexdigest(),
        "pass_lines": [line.strip() for line in output.splitlines()
                       if "PASS" in line or line.strip().startswith("UART=")],
    }


def upstream_timing_note() -> dict:
    report_path = V89J / "build_corrected_arcs_router1_seed3_v89j_summary.json"
    report = read_json(report_path)
    fmax = report.get("fmax_mhz", [])
    gates = report.get("gates", {})
    if (report.get("status") != "BUILD_GATE_FAIL"
            or gates.get("timing_50mhz") is not False
            or report.get("board") != "NOT_RUN"
            or fmax != [35.66, 36.11]):
        raise RuntimeError("v89j timing evidence changed; refusing to summarize it as the reviewed failure")
    return {
        "upstream_v89j": {
            "functional_mapper_golden": "PASS, 143-vector independent integer golden",
            "50mhz_timing": "FAIL",
            "fmax_mhz": fmax,
            "board_programming": "NOT_RUN",
            "evidence": str(report_path.relative_to(ROOT)).replace("\\", "/"),
            "evidence_sha256": sha(report_path),
        },
        "v102d_timing": "NOT_RUN; v102d has not been synthesized or routed",
    }


def release_check(candidate: Path) -> dict:
    """Reject promotion until one frozen image has three exact SRAM UART passes."""
    freeze_path = candidate / "FREEZE_MANIFEST.json"
    summary_path = candidate / "simulation_summary.json"
    board_path = candidate / "board_validation_summary.json"
    missing = [path.name for path in (freeze_path, summary_path, board_path)
               if not path.is_file()]
    if missing:
        raise RuntimeError("release promotion blocked; missing " + ", ".join(missing))
    freeze = read_json(freeze_path)
    frozen_summary = freeze.get("files_sha256", {}).get("simulation_summary.json")
    if frozen_summary != sha(summary_path):
        raise RuntimeError("release promotion blocked; simulation summary is not frozen")
    board = read_json(board_path)
    if board.get("status") != "PASS" or board.get("candidate") != candidate.name:
        raise RuntimeError("release promotion blocked; board summary is not a candidate PASS")
    if board.get("programming") != "SRAM_ONLY" or board.get("independent_sram_loads") != 3:
        raise RuntimeError("release promotion blocked; exactly three independent SRAM loads are required")
    if board.get("uart_bytes_per_load") != 46:
        raise RuntimeError("release promotion blocked; expected 46 UART bytes per SRAM load")
    if board.get("expected_uart") != EXPECTED_PASS.decode("ascii"):
        raise RuntimeError("release promotion blocked; board summary uses a different UART contract")
    build_name = board.get("original_build_summary")
    if not isinstance(build_name, str) or Path(build_name).name != build_name:
        raise RuntimeError("release promotion blocked; board summary does not name a safe routed-build report")
    build_path = candidate / build_name
    if not build_path.is_file():
        raise RuntimeError("release promotion blocked; routed-build report is missing")
    build = read_json(build_path)
    gates = build.get("gates", {})
    fmax = build.get("fmax_mhz", [])
    if (build.get("status") != "BUILD_PASS_NOT_BOARD"
            or not gates or not all(gates.values())
            or not fmax or min(fmax) < 50):
        raise RuntimeError("release promotion blocked; routed resource/setup/hold gates must pass at 50MHz")
    bitstream_sha = build.get("bitstream_sha256")
    bitstream_name = build.get("bitstream")
    if (not isinstance(bitstream_sha, str) or len(bitstream_sha) != 64
            or not isinstance(bitstream_name, str) or Path(bitstream_name).name != bitstream_name):
        raise RuntimeError("release promotion blocked; routed report lacks a safe bitstream identity")
    bitstream_path = candidate / bitstream_name
    if (not bitstream_path.is_file() or sha(bitstream_path) != bitstream_sha.lower()
            or board.get("bitstream_sha256") != bitstream_sha.lower()):
        raise RuntimeError("release promotion blocked; board and routed bitstream hashes differ")
    loads = board.get("loads", [])
    if len(loads) != 3:
        raise RuntimeError("release promotion blocked; board summary must contain three load records")
    seen_records = set()
    for load in loads:
        relative = Path(load.get("record", ""))
        record_path = (candidate / relative).resolve()
        if candidate.resolve() not in record_path.parents or not record_path.is_file():
            raise RuntimeError("release promotion blocked; load record escapes candidate or is missing")
        if record_path in seen_records:
            raise RuntimeError("release promotion blocked; load records are not independent")
        seen_records.add(record_path)
        record_sha = sha(record_path)
        if load.get("sha256") != record_sha:
            raise RuntimeError("release promotion blocked; a load record hash differs")
        record = read_json(record_path)
        if (record.get("status") != "PASS"
                or record.get("programming") != "PASS_SRAM_ONLY"
                or record.get("uart_validation") != "PASS_EXACT_BYTES"
                or record.get("uart_bytes") != 46
                or record.get("uart_capture") != EXPECTED_PASS.decode("ascii")
                or record.get("expected_uart_sha256") != sha(candidate / "expected_uart.txt")
                or record.get("bitstream_sha256") != bitstream_sha.lower()):
            raise RuntimeError("release promotion blocked; load record lacks exact frozen-image UART evidence")
    return {"status": "PASS", "candidate": candidate.name,
            "independent_sram_loads": 3, "uart_bytes_per_load": 46,
            "bitstream_sha256": bitstream_sha.lower(), "fmax_mhz": fmax,
            "routed_build_gates": gates}


def source_hashes(candidate: Path) -> dict[str, str]:
    freeze_tool = load_module(candidate / "verify_freeze.py", "candidate_v102d_freeze_tool")
    return {relative: sha(candidate / relative) for relative in freeze_tool.FROZEN_FILES
            if relative != "simulation_summary.json"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, choices=sorted(CANDIDATES),
                        help="candidate directory name; no implicit/default candidate is selected")
    parser.add_argument("--release-check", action="store_true",
                        help="validate frozen build provenance and three independent exact SRAM UART records")
    args = parser.parse_args()
    candidate = CANDIDATES[args.candidate].resolve()
    if ROOT.resolve() not in candidate.parents or candidate.name != args.candidate:
        raise RuntimeError("selected candidate path is not the declared repository candidate")

    if args.release_check:
        result, _ = run_json_command([sys.executable, "-B", str(candidate / "verify_freeze.py")], ROOT)
        if result.get("status") != "PASS":
            raise RuntimeError("candidate freeze verification failed")
        print(json.dumps(release_check(candidate), indent=2))
        return 0

    summary_path = candidate / "simulation_summary.json"
    freeze_path = candidate / "FREEZE_MANIFEST.json"
    if summary_path.exists() or freeze_path.exists():
        raise RuntimeError("refusing to overwrite existing candidate simulation or freeze evidence")

    upstream = verify_upstreams(candidate)
    freeze_tool = load_module(candidate / "verify_freeze.py", "candidate_v102d_freeze_tool")
    freeze_tool.check_production_inputs()
    mapper_result = None
    sampler_result = None
    candidate_result = None
    staging_removed = False
    stage_path = None
    with tempfile.TemporaryDirectory(prefix=".v102d_candidate_stage_", dir=str(candidate)) as stage_name:
        stage_path = Path(stage_name)
        mapper_result = run_mapper_regression(candidate, stage_path)
        sampler_result = run_sampler_regression(candidate, stage_path)
        candidate_result = run_candidate_sim(candidate, stage_path)
    staging_removed = stage_path is not None and not stage_path.exists()
    if not staging_removed:
        raise RuntimeError("candidate-local regression staging was not automatically removed")

    # Recheck source proofs after scripts ran. In particular, the golden
    # generator may rewrite candidate fixtures, but it may not change them.
    upstream_after = verify_upstreams(candidate)
    freeze_tool.check_production_inputs()
    if upstream_after != upstream:
        raise RuntimeError("upstream freeze proof changed while candidate tests ran")

    timing = upstream_timing_note()
    timing_path = V89J / "build_corrected_arcs_router1_seed3_v89j_summary.json"
    simulation = {
        "schema": "isolated_geometry_candidate_simulation_v1",
        "candidate": candidate.name,
        "status": "PASS",
        "verified_utc": datetime.now(timezone.utc).isoformat(),
        "command": "python -B cores/system/common_scaffold/image/geometry/sim/production_geometry_v89h_20261017/run_candidate_integration.py --candidate " + candidate.name,
        "upstream_freeze_verification": upstream,
        "v89j_mapper_input_regression": mapper_result,
        "v89i_sampler_regression": sampler_result,
        "candidate_integration": candidate_result,
        "timing_evidence": timing,
        "candidate_source_sha256_before_freeze": source_hashes(candidate),
        "temporary_staging": "CANDIDATE_LOCAL_AUTO_REMOVED",
        "temporary_staging_removed": staging_removed,
        "resource_impact": "Simulation only; no technology synthesis or PNR resource report generated.",
        "synthesis": "NOT_RUN",
        "pnr": "NOT_RUN",
        "bitstream": "NOT_CREATED",
        "board_programming": "NOT_RUN",
        "three_independent_sram_loads": "PENDING_RELEASE_GATE",
        "promotion_gate": "BLOCKED_UNTIL_TIMING_AND_THREE_SRAM_LOADS_PASS",
    }
    summary_path.write_text(json.dumps(simulation, indent=2) + "\n", encoding="utf-8")
    frozen, freeze_output = run_json_command(
        [sys.executable, "-B", str(candidate / "verify_freeze.py"), "--freeze"], ROOT)
    verified, verify_output = run_json_command(
        [sys.executable, "-B", str(candidate / "verify_freeze.py")], ROOT)
    print(json.dumps({
        "status": "PASS",
        "candidate": candidate.name,
        "simulation_summary": str(summary_path.relative_to(ROOT)).replace("\\", "/"),
        "freeze_manifest": str(freeze_path.relative_to(ROOT)).replace("\\", "/"),
        "freeze": frozen,
        "verification": verified,
        "temporary_staging_removed": staging_removed,
        "timing_evidence": timing,
    }, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"status": "FAIL", "error": str(error)}, indent=2), file=sys.stderr)
        raise SystemExit(1)
