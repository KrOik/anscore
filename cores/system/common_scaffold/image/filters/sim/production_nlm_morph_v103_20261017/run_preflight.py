#!/usr/bin/env python3
"""Run a no-apply production-source simulation and integration-gate precheck.

This runner never edits production RTL or manifests, and never invokes synthesis,
place-and-route, or board programming. Persistent outputs are limited to this
runner's timestamped evidence directory; all staged source trees and simulator
images are removed after use.
"""
from __future__ import annotations

from datetime import datetime, timezone
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
IMAGE = ROOT / "cores/system/common_scaffold/image"
FILTERS = IMAGE / "filters"
PRODUCTION = FILTERS / "rtl"
sys.path.insert(0, str(ROOT / "cores/signal_processing/dsp_isp_library/board/tang25k"))
import device_flow
DEFAULT_CANDIDATE = ROOT / (
    "cores/system/common_scaffold/board/tang25k/build/"
    "image_filter_frame_selftest_25k_20261017_v103_nlm_morph"
)
CANDIDATE = DEFAULT_CANDIDATE
OPS = [CANDIDATE / f"op{op}" for op in range(3)]
EXPECTED_FREEZE = "a18e341165205f1a87332bd99e0a6f496b8dd210ae8d4f1123c3c2296e34bb5a"
EXPECTED_ROUTE_GATE = {
    "lut4_max": 15000,
    "mult12_max": 4,
    "setup_mhz_min": 50,
    "hold_violations_max": 0,
}
DEVICE_RESOURCE_MAX = {"lut4": 15000, "dff": 18400, "bsram": 44, "mult12": 4}
ENGINE_NAME = "img_filter_frame_engine.v"
WEIGHT_NAME = "img_filter_exp_weight.v"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def display_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(ROOT.resolve()))
    except ValueError:
        return str(resolved)


def select_op2_reset_state(engine_source: str) -> str:
    """Pick a reset trigger valid for the state names in the staged engine."""
    without_comments = re.sub(r"//[^\n]*|/\*.*?\*/", "", engine_source, flags=re.S)
    return "DIV_MID" if re.search(r"\bDIV_MID\s*=\s*\d+\b", without_comments) else "NWEIGHT"


def declared_pixel_width_limit(engine_source: str) -> int:
    without_comments = re.sub(r"//[^\n]*|/\*.*?\*/", "", engine_source, flags=re.S)
    limits = re.findall(r"\bPIXEL_W\s*>\s*(\d+)\b", without_comments)
    if not limits:
        raise ValueError("could not find the PIXEL_W upper-bound guard in the selected engine")
    return max(int(value) for value in limits)


def verify_frozen_inputs(candidate_root: Path = CANDIDATE,
                         expected_freeze: str = EXPECTED_FREEZE) -> dict[str, Any]:
    issues: list[str] = []
    op_records: list[dict[str, Any]] = []
    ops = [candidate_root / f"op{op}" for op in range(3)]
    for op, op_dir in enumerate(ops):
        manifest_path = op_dir / "FREEZE_MANIFEST.json"
        source_manifest_path = op_dir / "SOURCE_FREEZE_MANIFEST.json"
        build_status_path = op_dir / "build_status.json"
        if not manifest_path.is_file() or not source_manifest_path.is_file() or not build_status_path.is_file():
            issues.append(f"OP{op}: missing freeze/source-freeze/build-status manifest")
            continue
        manifest = load_json(manifest_path)
        build_status = load_json(build_status_path)
        freeze_digest = manifest.get("verification", {}).get("source_freeze_sha256")
        if freeze_digest != expected_freeze:
            issues.append(f"OP{op}: frozen source digest {freeze_digest!r} != expected {expected_freeze}")
        if sha256_file(source_manifest_path) != expected_freeze:
            issues.append(f"OP{op}: SOURCE_FREEZE_MANIFEST.json SHA256 does not match the explicit freeze")
        if build_status.get("source_candidate_freeze_sha256") != expected_freeze:
            issues.append(f"OP{op}: build status does not bind to expected candidate freeze")
        if manifest.get("op") != op or manifest.get("parameters", {}).get("OP") != op:
            issues.append(f"OP{op}: manifest operation number mismatch")
        gate = manifest.get("parameters", {}).get("route_gate")
        if gate != EXPECTED_ROUTE_GATE:
            issues.append(f"OP{op}: frozen route-gate thresholds differ from the agreed limits")
        if manifest.get("verification", {}).get("result") != "PASS":
            issues.append(f"OP{op}: source-freeze verification is not PASS")

        listed = manifest.get("files_sha256", {})
        checked = 0
        for rel, expected in listed.items():
            rel_path = Path(rel)
            if rel_path.is_absolute() or ".." in rel_path.parts:
                issues.append(f"OP{op}: unsafe frozen path {rel!r}")
                continue
            path = op_dir / rel_path
            if not path.is_file():
                issues.append(f"OP{op}: frozen file missing: {rel}")
            elif sha256_file(path) != expected:
                issues.append(f"OP{op}: frozen digest mismatch: {rel}")
            else:
                checked += 1

        source_hashes = build_status.get("source_sha256", {})
        for rel in (f"rtl/{ENGINE_NAME}", f"rtl/{WEIGHT_NAME}"):
            path = op_dir / rel
            if not path.is_file() or sha256_file(path) != source_hashes.get(rel):
                issues.append(f"OP{op}: source snapshot mismatch: {rel}")
        op_records.append({
            "op": op,
            "freeze_manifest_sha256": sha256_file(manifest_path),
            "source_freeze_sha256": freeze_digest,
            "listed_files_verified": checked,
            "physical_board": manifest.get("verification", {}).get("physical_board"),
            "synthesis": manifest.get("verification", {}).get("synthesis"),
            "pnr": manifest.get("verification", {}).get("pnr"),
        })
    return {"status": "PASS" if not issues and len(op_records) == 3 else "FAIL",
            "candidate_root": display_path(candidate_root),
            "expected_candidate_freeze_sha256": expected_freeze,
            "ops": op_records, "issues": issues}


def validate_route_gate(path: Path, op: int) -> tuple[bool, str]:
    if not path.is_file():
        return False, f"OP{op}: waiting for {path.name} (hold-aware routed result not present)"
    try:
        data = load_json(path)
    except Exception as exc:
        return False, f"OP{op}: cannot parse {path.name}: {exc}"
    if not isinstance(data, dict):
        return False, f"OP{op}: {path.name} must contain a JSON object"
    if data.get("status") != "BUILD_PASS_NOT_BOARD":
        return False, f"OP{op}: {path.name} must contain status=BUILD_PASS_NOT_BOARD"
    expected_attempt = f"op{op}_router1_seed3"
    if data.get("attempt") != expected_attempt:
        return False, f"OP{op}: {path.name} attempt must be {expected_attempt}"
    required_gates = ("route_process", "route_complete", "lut4_device_gate",
                      "dff_device_gate", "bsram_device_gate", "mult12_device_gate",
                      "lut_15k", "dsp_4", "timing_50mhz", "hold",
                      "official_apicula_import")
    gates = data.get("gates", {})
    if not isinstance(gates, dict) or any(gates.get(key) is not True for key in required_gates):
        return False, f"OP{op}: {path.name} is missing a passing route/all-resource/setup/hold/packer gate"
    values = data.get("util", {})
    if not isinstance(values, dict) or any(key not in values for key in DEVICE_RESOURCE_MAX):
        return False, f"OP{op}: {path.name} util must provide LUT4, DFF, BSRAM, and MULT12 counts"
    resources: dict[str, int] = {}
    for key, maximum in DEVICE_RESOURCE_MAX.items():
        raw = values.get(key)
        if isinstance(raw, bool) or not isinstance(raw, int) or raw < 0:
            return False, f"OP{op}: {path.name} has an invalid {key} resource count"
        resources[key] = raw
        if raw > maximum:
            return False, f"OP{op}: {key.upper()}={raw}>{maximum} device/resource limit"
    lut4, mult12 = resources["lut4"], resources["mult12"]
    fmax_raw = data.get("fmax_mhz")
    if (not isinstance(fmax_raw, list) or not fmax_raw
            or any(isinstance(value, bool) or not isinstance(value, (int, float))
                   or not math.isfinite(float(value)) for value in fmax_raw)):
        return False, f"OP{op}: {path.name} has no finite numeric fmax_mhz list"
    fmax_values = [float(value) for value in fmax_raw]
    if any(value <= 0 for value in fmax_values):
        return False, f"OP{op}: {path.name} has empty or invalid fmax_mhz evidence"
    hold_lines = data.get("hold_violation_lines")
    if not isinstance(hold_lines, list) or hold_lines:
        return False, f"OP{op}: {path.name} must provide an empty hold_violation_lines list"
    hold_counts = data.get("hold_violation_counts")
    if hold_counts is not None and (not isinstance(hold_counts, list) or any(
            isinstance(value, bool) or not isinstance(value, int) or value != 0
            for value in hold_counts)):
        return False, f"OP{op}: {path.name} reports invalid/nonzero optional hold violation counts"
    hold_slacks = data.get("hold_slacks_ns")
    if hold_slacks is not None and (not isinstance(hold_slacks, list) or any(
            isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(float(value)) or value < 0 for value in hold_slacks)):
        return False, f"OP{op}: {path.name} has invalid optional explicit min-delay hold slack evidence"
    failures = []
    if lut4 < 0 or lut4 > EXPECTED_ROUTE_GATE["lut4_max"]:
        failures.append(f"LUT4={lut4}>{EXPECTED_ROUTE_GATE['lut4_max']}")
    if mult12 < 0 or mult12 > EXPECTED_ROUTE_GATE["mult12_max"]:
        failures.append(f"MULT12={mult12}>{EXPECTED_ROUTE_GATE['mult12_max']}")
    if min(fmax_values) < EXPECTED_ROUTE_GATE["setup_mhz_min"]:
        failures.append(f"fmax={min(fmax_values):g}MHz<{EXPECTED_ROUTE_GATE['setup_mhz_min']}MHz")
    top_json = path.parent / "top25k.json"
    expected_top_sha = data.get("input_top25k_sha256")
    if not isinstance(expected_top_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected_top_sha):
        failures.append("input_top25k_sha256 missing or malformed")
    elif not top_json.is_file() or sha256_file(top_json) != expected_top_sha.lower():
        failures.append("input_top25k_sha256 does not match OP top25k.json")
    if failures:
        return False, f"OP{op}: route gate failed: " + ", ".join(failures)
    return True, f"OP{op}: official route summary, input hash, resources/setup pass; router hold gate and empty violation list pass"


def validate_board_gate(op_dir: Path, op: int) -> tuple[bool, str]:
    path = op_dir / "board_validation_summary.json"
    if not path.is_file():
        return False, f"OP{op}: waiting for board_validation_summary.json with 3 independent SRAM/UART PASS records"
    try:
        data = load_json(path)
    except Exception as exc:
        return False, f"OP{op}: cannot parse board validation summary: {exc}"
    if not isinstance(data, dict):
        return False, f"OP{op}: board validation summary must contain a JSON object"
    if data.get("status") not in (None, "PASS"):
        return False, f"OP{op}: board validation summary reports a non-PASS status"
    if data.get("op", op) != op or data.get("independent_sram_loads") != 3:
        return False, f"OP{op}: board summary must bind this OP and report 3 independent SRAM loads"
    expected_uart_path = op_dir / "expected_uart.txt"
    if not expected_uart_path.is_file():
        return False, f"OP{op}: frozen expected_uart.txt missing"
    try:
        expected_uart = expected_uart_path.read_bytes().decode("ascii")
    except (OSError, UnicodeDecodeError) as exc:
        return False, f"OP{op}: frozen UART fixture is unreadable or non-ASCII: {exc}"
    if "expected_uart" in data and data["expected_uart"] != expected_uart:
        return False, f"OP{op}: board summary UART fixture differs from frozen expected_uart.txt"
    loads = data.get("loads")
    if not isinstance(loads, list) or len(loads) != 3:
        return False, f"OP{op}: expected exactly three independent SRAM/UART records"
    op_root = op_dir.resolve()
    record_paths: set[str] = set()
    for index, load in enumerate(loads, 1):
        if not isinstance(load, dict):
            return False, f"OP{op}: load {index} must be a JSON object"
        rel = load.get("record")
        if not isinstance(rel, str):
            return False, f"OP{op}: load {index} has no record path"
        rel_path = Path(rel)
        if rel_path.is_absolute() or rel_path.drive or ".." in rel_path.parts:
            return False, f"OP{op}: load {index} record path escapes its OP directory"
        record = op_dir / rel_path
        resolved_record = record.resolve()
        if not resolved_record.is_relative_to(op_root):
            return False, f"OP{op}: load {index} record resolves outside its OP directory"
        if not record.is_file():
            return False, f"OP{op}: load {index} record missing: {rel}"
        resolved_key = str(resolved_record).casefold()
        if resolved_key in record_paths:
            return False, f"OP{op}: SRAM/UART record reused: {rel}"
        record_paths.add(resolved_key)
        record_sha = load.get("record_sha256")
        if not isinstance(record_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", record_sha):
            return False, f"OP{op}: load {index} record_sha256 is missing or malformed"
        if sha256_file(record) != record_sha.lower():
            return False, f"OP{op}: load {index} record SHA256 mismatch"
        try:
            capture = load_json(record)
        except Exception as exc:
            return False, f"OP{op}: load {index} record is invalid JSON: {exc}"
        if capture.get("status") != "PASS":
            return False, f"OP{op}: load {index} UART record status is not PASS"
        if capture.get("programming") != "PASS_SRAM_ONLY":
            return False, f"OP{op}: load {index} did not complete a volatile SRAM program"
        if capture.get("uart_validation") != "PASS_EXACT_BYTES":
            return False, f"OP{op}: load {index} UART record is not a byte-exact PASS"
        if capture.get("jtag_detected_idcode") != "0x1281b":
            return False, f"OP{op}: load {index} does not prove Tang 25K JTAG identity"
        if capture.get("uart_capture") != expected_uart:
            return False, f"OP{op}: load {index} UART bytes differ from the frozen expected line"
    return True, f"OP{op}: three distinct JTAG/SRAM/UART PASS records verified"


def check_integration_gates(candidate_root: Path = CANDIDATE) -> dict[str, Any]:
    blockers: list[str] = []
    records: list[dict[str, Any]] = []
    for op in range(3):
        op_dir = candidate_root / f"op{op}"
        route_path = op_dir / f"build_op{op}_router1_seed3_summary.json"
        route_ok, route_msg = validate_route_gate(route_path, op)
        board_ok, board_msg = validate_board_gate(op_dir, op)
        if not route_ok:
            blockers.append(route_msg)
        if not board_ok:
            blockers.append(board_msg)
        records.append({"op": op, "route_gate": "PASS" if route_ok else "WAITING_OR_FAIL",
                        "route_evidence": display_path(route_path),
                        "board_gate": "PASS" if board_ok else "WAITING_OR_FAIL",
                        "board_evidence": display_path(op_dir / "board_validation_summary.json")})
    return {"status": "PASS" if not blockers else "WAITING", "ops": records, "blockers": blockers}


def self_test_gates() -> int:
    """Exercise the official route and board evidence schemas with disposable files."""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="production_gate_schema_") as temp_raw:
        op_dir = Path(temp_raw) / "op0"
        op_dir.mkdir()
        top_json = op_dir / "top25k.json"
        top_json.write_bytes(b'{"fixture":"mapped-netlist"}\n')
        route_path = op_dir / "build_op0_router1_seed3_summary.json"
        route_summary = {
            "status": "BUILD_PASS_NOT_BOARD",
            "attempt": "op0_router1_seed3",
            "gates": {"route_process": True, "route_complete": True,
                      "lut4_device_gate": True, "dff_device_gate": True,
                      "bsram_device_gate": True, "mult12_device_gate": True,
                      "lut_15k": True, "dsp_4": True, "timing_50mhz": True,
                      "hold": True, "official_apicula_import": True},
            "util": {"lut4": 1234, "dff": 987, "bsram": 2, "mult12": 2},
            "fmax_mhz": [52.0, 50.5],
            "hold_slacks_ns": [0.04], "hold_violation_lines": [],
            "hold_violation_counts": [0],
            "input_top25k_sha256": sha256_file(top_json),
        }
        write_json(route_path, route_summary)
        passed, message = validate_route_gate(route_path, 0)
        if not passed:
            raise AssertionError("official route summary fixture rejected: " + message)
        print("PASS preflight gate official_route_schema")
        checks += 1
        route_summary["input_top25k_sha256"] = "0" * 64
        write_json(route_path, route_summary)
        if validate_route_gate(route_path, 0)[0]:
            raise AssertionError("route summary with a mismatched input SHA was accepted")
        print("PASS preflight gate route_input_sha_mismatch_rejected")
        checks += 1
        route_summary["input_top25k_sha256"] = sha256_file(top_json)
        route_summary["util"]["bsram"] = DEVICE_RESOURCE_MAX["bsram"] + 1
        write_json(route_path, route_summary)
        if validate_route_gate(route_path, 0)[0]:
            raise AssertionError("route summary over the BSRAM device limit was accepted")
        print("PASS preflight gate all_resource_limit_enforced")
        checks += 1
        route_summary["util"]["bsram"] = 2
        route_summary.pop("hold_slacks_ns")
        route_summary.pop("hold_violation_counts")
        write_json(route_path, route_summary)
        accepted, hold_message = validate_route_gate(route_path, 0)
        if not accepted or "router hold gate" not in hold_message:
            raise AssertionError("current official route schema should retain router-only hold evidence")
        print("PASS preflight gate router_hold_schema_distinguished_from_min_delay")
        checks += 1

        expected = b"IF0 PASS E=00 F=00 D=E38BA478\r\n"
        (op_dir / "expected_uart.txt").write_bytes(expected)
        loads: list[dict[str, Any]] = []
        for index in range(1, 4):
            record_name = f"board_uart_fixture{index}.json"
            record_path = op_dir / record_name
            write_json(record_path, {
                "status": "PASS", "programming": "PASS_SRAM_ONLY",
                "jtag_detected_idcode": "0x1281b",
                "uart_validation": "PASS_EXACT_BYTES",
                "uart_capture": expected.decode("ascii"),
            })
            loads.append({"load": index, "record": record_name,
                          "record_sha256": sha256_file(record_path)})
        # The generated validation summary schema binds each record by its
        # record_sha256 and intentionally does not need a top-level status key.
        board_summary = {"op": 0, "independent_sram_loads": 3,
                         "expected_uart": expected.decode("ascii"), "loads": loads}
        board_path = op_dir / "board_validation_summary.json"
        write_json(board_path, board_summary)
        passed, message = validate_board_gate(op_dir, 0)
        if not passed:
            raise AssertionError("generated board-load schema fixture rejected: " + message)
        print("PASS preflight gate board_record_sha_uart_schema")
        checks += 1

        record_path = op_dir / loads[1]["record"]
        failed_record = load_json(record_path)
        failed_record["status"] = "FAIL"
        write_json(record_path, failed_record)
        loads[1]["record_sha256"] = sha256_file(record_path)
        write_json(board_path, board_summary)
        if validate_board_gate(op_dir, 0)[0]:
            raise AssertionError("non-PASS individual UART record was accepted")
        print("PASS preflight gate individual_uart_failure_rejected")
        checks += 1
    legacy_engine = "module old_engine; localparam IDLE=0,NWEIGHT=8; endmodule"
    divided_engine = "module candidate_engine; localparam IDLE=0,NWEIGHT=10,DIV_MID=18; endmodule"
    commented_divider = "module old_engine; // localparam DIV_MID=18\nlocalparam NWEIGHT=8; endmodule"
    if select_op2_reset_state(legacy_engine) != "NWEIGHT":
        raise AssertionError("legacy production reset trigger must select NWEIGHT")
    print("PASS preflight reset_trigger legacy_NWEIGHT")
    checks += 1
    if select_op2_reset_state(divided_engine) != "DIV_MID":
        raise AssertionError("divider candidate reset trigger must select DIV_MID")
    print("PASS preflight reset_trigger candidate_DIV_MID")
    checks += 1
    if select_op2_reset_state(commented_divider) != "NWEIGHT":
        raise AssertionError("commented state names must not affect reset trigger selection")
    print("PASS preflight reset_trigger ignores_comments")
    checks += 1
    if declared_pixel_width_limit("if (PIXEL_W<1 || PIXEL_W>12) reject();") != 12:
        raise AssertionError("legacy PIXEL_W upper-bound was not detected")
    if declared_pixel_width_limit("if (PIXEL_W<1 || PIXEL_W>16) reject();") != 16:
        raise AssertionError("candidate PIXEL_W upper-bound was not detected")
    print("PASS preflight pixel_width_boundary legacy12_candidate16")
    checks += 1
    with tempfile.TemporaryDirectory(prefix="production_freeze_root_") as temp_raw:
        candidate_root = Path(temp_raw)
        source_manifest_bytes = b"fixture source freeze manifest\n"
        expected_freeze = sha256_bytes(source_manifest_bytes)
        for op in range(3):
            op_dir = candidate_root / f"op{op}"
            rtl = op_dir / "rtl"
            rtl.mkdir(parents=True)
            source_hashes: dict[str, str] = {}
            listed: dict[str, str] = {}
            for name, body in ((ENGINE_NAME, b"module fixture_engine; endmodule\n"),
                               (WEIGHT_NAME, b"module fixture_weight; endmodule\n")):
                rel = f"rtl/{name}"
                (rtl / name).write_bytes(body)
                source_hashes[rel] = sha256_file(rtl / name)
                listed[rel] = source_hashes[rel]
            (op_dir / "SOURCE_FREEZE_MANIFEST.json").write_bytes(source_manifest_bytes)
            write_json(op_dir / "FREEZE_MANIFEST.json", {
                "op": op, "parameters": {"OP": op, "route_gate": EXPECTED_ROUTE_GATE},
                "verification": {"result": "PASS", "source_freeze_sha256": expected_freeze},
                "files_sha256": listed,
            })
            write_json(op_dir / "build_status.json", {
                "source_candidate_freeze_sha256": expected_freeze,
                "source_sha256": source_hashes,
            })
        if verify_frozen_inputs(candidate_root, expected_freeze)["status"] != "PASS":
            raise AssertionError("explicit candidate-root freeze fixture was rejected")
        if verify_frozen_inputs(candidate_root, "0" * 64)["status"] != "FAIL":
            raise AssertionError("candidate-root accepted an incorrect explicit freeze SHA")
        print("PASS preflight candidate_root_exact_source_freeze_sha")
        checks += 1
    print(f"PRODUCTION PREFLIGHT GATE SCHEMA SELF-TEST PASS checks={checks}")
    return 0


def find_iverilog() -> str:
    path = Path(device_flow.resolve("iverilog"))
    if path.is_file():
        return str(path)
    raise RuntimeError(f"iverilog was not found in OSS CAD Suite or on PATH: {path}")


def find_vvp() -> str:
    path = Path(device_flow.resolve("vvp"))
    if path.is_file():
        return str(path)
    raise RuntimeError(f"vvp was not found in OSS CAD Suite or on PATH: {path}")


def oss_tool_environment() -> dict[str, str]:
    """Use the shared Tang 25K flow's executable and DLL path resolution."""
    return device_flow.tool_env()


def invoke_sim(name: str, top: str, sources: list[Path], parameters: list[str], marker: str,
               cwd: Path, evidence: Path, iverilog: str, vvp: str,
               include_dirs: list[Path] | None = None) -> dict[str, Any]:
    evidence.mkdir(parents=True, exist_ok=True)
    image = evidence / f"{name}.vvp"
    command = [iverilog, "-g2012", "-Wall", "-s", top]
    for include in include_dirs or []:
        command.extend(["-I", str(include)])
    command.extend(parameters)
    command.extend(["-o", str(image)])
    command.extend(str(p) for p in sources)
    env = oss_tool_environment()
    compile_result = subprocess.run(command, cwd=cwd, env=env, text=True,
                                    capture_output=True, timeout=180)
    (evidence / f"{name}.compile.log").write_text(
        compile_result.stdout + compile_result.stderr, encoding="utf-8")
    simulation_result: subprocess.CompletedProcess[str] | None = None
    output = ""
    try:
        if compile_result.returncode != 0:
            raise RuntimeError(f"Icarus compile failed ({compile_result.returncode})")
        simulation_result = subprocess.run([vvp, str(image)], cwd=cwd, env=env, text=True,
                                           capture_output=True, timeout=180)
        output = simulation_result.stdout + simulation_result.stderr
        (evidence / f"{name}.simulation.log").write_text(output, encoding="utf-8")
        if simulation_result.returncode != 0:
            raise RuntimeError(f"vvp simulation failed ({simulation_result.returncode})")
        if marker not in output:
            raise RuntimeError(f"PASS marker missing: {marker}")
        return {"name": name, "status": "PASS", "marker": marker,
                "compile_command": command, "compile_exit": compile_result.returncode,
                "simulation_exit": simulation_result.returncode,
                "temporary_vvp_bytes_removed": image.stat().st_size if image.exists() else 0}
    finally:
        if image.exists():
            image.unlink()


def stage_candidate_suite(stage: Path, ops: list[Path], candidate_root: Path,
                          source_rtl_root: Path) -> tuple[Path, Path, Path]:
    suite = stage / "suite"
    rtl = suite / "rtl"
    sim = suite / "sim"
    rtl.mkdir(parents=True)
    sim.mkdir(parents=True)
    shutil.copyfile(source_rtl_root / ENGINE_NAME, rtl / ENGINE_NAME)
    shutil.copyfile(source_rtl_root / WEIGHT_NAME, rtl / WEIGHT_NAME)
    for name in ("tb_img_filter_frame_engine.v", "tb_img_filter_frame_engine_12bit.v",
                 "generate_vectors.py"):
        source = ops[0] / "sim" / name
        # The frozen per-OP handoffs carry the testbenches, while their shared
        # independent-vector generator remains in the candidate-level sim dir.
        if not source.is_file() and name == "generate_vectors.py":
            source = candidate_root / "sim" / name
        if not source.is_file():
            raise FileNotFoundError(f"frozen regression input is missing: {source}")
        shutil.copyfile(source, sim / name)
    for name in ("image_filter_frame_board_selftest_25k.v", "tb_image_filter_frame_board_selftest_25k.sv",
                 "tb_img_filter_board_por.sv", "board_input.mem", "board_golden_op0.mem",
                 "board_golden_op1.mem", "board_golden_op2.mem", "expected_uart_op0_pass.hex",
                 "expected_uart_op0_fault.hex", "expected_uart_op1_pass.hex",
                 "expected_uart_op1_fault.hex", "expected_uart_op2_pass.hex",
                 "expected_uart_op2_fault.hex"):
        if name.startswith("expected_uart_"):
            match = re.fullmatch(r"expected_uart_op([0-2])_(?:pass|fault)\.hex", name)
            if match is None:
                raise RuntimeError(f"unexpected frozen UART fixture name: {name}")
            fixture_op = int(match.group(1))
            source = ops[fixture_op] / "uart_fixture" / name
            manifest_path = ops[fixture_op] / "FREEZE_MANIFEST.json"
            manifest = load_json(manifest_path)
            expected = manifest.get("files_sha256", {}).get(f"uart_fixture/{name}")
            if not isinstance(expected, str) or not source.is_file() or sha256_file(source) != expected:
                raise RuntimeError(
                    f"frozen OP{fixture_op} UART fixture missing or digest mismatch: {source}")
        else:
            source = ops[0] / name
        shutil.copyfile(source, suite / name)
    return suite, rtl, sim


def run_local_regressions(run_dir: Path, include_group: bool,
                          candidate_root: Path = CANDIDATE,
                          source_rtl_root: Path = PRODUCTION) -> list[dict[str, Any]]:
    iverilog, vvp = find_iverilog(), find_vvp()
    results: list[dict[str, Any]] = []
    ops = [candidate_root / f"op{op}" for op in range(3)]
    with tempfile.TemporaryDirectory(prefix=".stage_", dir=run_dir) as stage_raw:
        stage = Path(stage_raw)
        suite, rtl, sim = stage_candidate_suite(stage, ops, candidate_root, source_rtl_root)
        vector_dir = stage / "vectors"
        vector_dir.mkdir()
        generator = subprocess.run([sys.executable, "-B", str(sim / "generate_vectors.py"),
                                    "--output-dir", str(vector_dir)], cwd=suite,
                                   text=True, capture_output=True, timeout=60)
        (run_dir / "tests/fixture_generation.log").parent.mkdir(parents=True, exist_ok=True)
        (run_dir / "tests/fixture_generation.log").write_text(
            generator.stdout + generator.stderr, encoding="utf-8")
        if generator.returncode != 0:
            raise RuntimeError("production-source golden-vector generation failed")
        shutil.copy2(vector_dir / "case_summary.json", run_dir / "tests/case_summary.json")
        shutil.copy2(vector_dir / "filter_vectors.vh", run_dir / "tests/filter_vectors.vh")

        engine = rtl / ENGINE_NAME
        weight = rtl / WEIGHT_NAME
        result_dir = run_dir / "tests"
        e8 = invoke_sim("production_engine_8bit", "tb_img_filter_frame_engine",
                        [weight, engine, sim / "tb_img_filter_frame_engine.v"], [],
                        "FILTER103 PASS cases=10 pixels=120 backpressure=3cycles clk_en_pause=3cycles",
                        suite, result_dir, iverilog, vvp, [vector_dir])
        e8["scope"] = "production engine/helper + frozen 8-bit independent model"
        results.append(e8)
        e12 = invoke_sim("production_engine_12bit", "tb_img_filter_frame_engine_12bit",
                         [weight, engine, sim / "tb_img_filter_frame_engine_12bit.v"], [],
                         "FILTER103 NLM12 RANGE PASS min_h=1 max_h=1048575 search_radius=3 candidates=49 uniform_max=4095",
                         suite, result_dir, iverilog, vvp, [vector_dir])
        if "FILTER103 NLM12 PASS" not in (result_dir / "production_engine_12bit.simulation.log").read_text(encoding="utf-8"):
            raise RuntimeError("production 12-bit regression missed its primary PASS marker")
        e12["scope"] = "production engine/helper + frozen 12-bit NLM integer references"
        results.append(e12)

        # Exercise the board wrapper against the selected RTL. Choose the reset
        # point from its declared states instead of relying on a candidate name.
        board_tb = suite / "tb_image_filter_frame_board_selftest_25k.sv"
        board_source = (ops[0] / "tb_image_filter_frame_board_selftest_25k.sv").read_text(encoding="utf-8")
        reset_state = select_op2_reset_state((source_rtl_root / ENGINE_NAME).read_text(encoding="utf-8"))
        adapted, substitutions = re.subn(
            r"if\(OP==2\)wait\(dut\.engine\.state==dut\.engine\.DIV_MID\);",
            f"if(OP==2)wait(dut.engine.state==dut.engine.{reset_state});", board_source)
        if substitutions != 1:
            raise RuntimeError("could not make the isolated production-compatible OP2 reset adaptation")
        board_tb.write_text(adapted, encoding="utf-8")
        board_top = suite / "image_filter_frame_board_selftest_25k.v"
        board_cases: list[dict[str, Any]] = []
        for op in range(3):
            for fault in range(2):
                for reset in range(2):
                    name = f"production_board_op{op}_fault{fault}_reset{reset}"
                    marker = f"FILTER103 BOARD PASS op={op} fault={fault} reset={reset}"
                    result = invoke_sim(
                        name, "tb_image_filter_frame_board_selftest_25k",
                        [weight, engine, board_top, board_tb],
                        [f"-Ptb_image_filter_frame_board_selftest_25k.OP={op}",
                         f"-Ptb_image_filter_frame_board_selftest_25k.FAULT={fault}",
                         f"-Ptb_image_filter_frame_board_selftest_25k.RESET={reset}"],
                        marker, suite, result_dir, iverilog, vvp)
                    board_cases.append(result)
        por = invoke_sim(
            "production_board_por", "tb_img_filter_board_por",
            [weight, engine, board_top, ops[0] / "tb_img_filter_board_por.sv"], [],
            "FILTER103 BOARD POR PASS release_edges=2,3,10,66", suite,
            result_dir, iverilog, vvp)
        results.extend(board_cases)
        results.append(por)

        pixel_width_max = declared_pixel_width_limit(
            (source_rtl_root / ENGINE_NAME).read_text(encoding="utf-8"))
        boundary = invoke_sim(
            "production_width_ce_reset_contract", "tb_production_contract",
            [weight, engine, HERE / "tb_production_contract.sv"],
            [f"-Ptb_production_contract.PIXEL_W_MAX={pixel_width_max}"],
            "PASS PRODUCTION CONTRACT PIXEL_W=1,16 NLM=CE+RESET", suite,
            result_dir, iverilog, vvp)
        boundary["scope"] = (f"PIXEL_W=1 accepted, PIXEL_W=16 "
                             f"{'accepted' if pixel_width_max >= 16 else 'rejected'}, "
                             f"{reset_state} CE hold and asynchronous reset/replay")
        results.append(boundary)

    if include_group:
        group_result = run_image_core_group(run_dir, iverilog, vvp)
        results.append(group_result)
    return results


def run_image_core_group(run_dir: Path, iverilog: str, vvp: str) -> dict[str, Any]:
    evidence = run_dir / "tests/image_core_group"
    evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".image_core_", dir=run_dir) as temp_raw:
        image_root = Path(temp_raw) / "image"
        (image_root / "sim").mkdir(parents=True)
        shutil.copyfile(IMAGE / "sim/run_image_core_group.py", image_root / "sim/run_image_core_group.py")
        for source in IMAGE.rglob("*.v"):
            rel = source.relative_to(IMAGE)
            if source.name.startswith("tb_") or any(
                part.startswith("build") or part in ("sim", "evidence") for part in rel.parts[:-1]
            ):
                continue
            target = image_root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        env = os.environ.copy()
        tool_dirs = str(Path(iverilog).resolve().parent)
        env["PATH"] = tool_dirs + os.pathsep + str(Path(vvp).resolve().parent) + os.pathsep + env.get("PATH", "")
        command = [sys.executable, "-B", str(image_root / "sim/run_image_core_group.py")]
        result = subprocess.run(command, cwd=image_root, env=env, text=True,
                                capture_output=True, timeout=180)
        (evidence / "console.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        groups = sorted(image_root.glob("build_core_group_*"))
        if len(groups) != 1:
            return {"name": "production_image_core_group", "status": "FAIL",
                    "reason": f"expected one isolated image_core run directory, got {len(groups)}",
                    "exit_code": result.returncode}
        group = groups[0]
        for filename in ("compile.log", "simulation.log", "summary.json"):
            source = group / filename
            if source.is_file():
                shutil.copy2(source, evidence / filename)
        image = group / "core.vvp"
        removed = image.stat().st_size if image.is_file() else 0
        if image.is_file():
            image.unlink()
        summary_path = evidence / "summary.json"
        summary = load_json(summary_path) if summary_path.is_file() else {}
        passed = (result.returncode == 0 and summary.get("compile_exit") == 0
                  and summary.get("simulation_exit") == 0)
        return {"name": "production_image_core_group", "status": "PASS" if passed else "FAIL",
                "exit_code": result.returncode, "cases": summary.get("cases", []),
                "pixels": summary.get("pixels"), "windows": summary.get("windows"),
                "disposable_vvp_bytes_removed": removed,
                "scope": summary.get("scope"),
                "staging_workspace_removed": True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate-only", action="store_true",
                        help="audit frozen OP and future route/board evidence without simulations")
    parser.add_argument("--self-test-gates", action="store_true",
                        help="test route/board evidence parsing using disposable host fixtures only")
    parser.add_argument("--skip-image-core-group", action="store_true",
                        help="skip the isolated original image_core regression")
    parser.add_argument("--candidate-root", type=Path,
                        help="candidate directory containing op0/op1/op2 (override requires an explicit freeze SHA256)")
    parser.add_argument("--expected-freeze-sha256",
                        help="exact SHA256 of each OP SOURCE_FREEZE_MANIFEST.json")
    parser.add_argument("--source-rtl-root", type=Path, default=PRODUCTION,
                        help="directory containing the engine/helper RTL to simulate (default: production rtl)")
    args = parser.parse_args()
    if args.self_test_gates:
        return self_test_gates()

    if args.candidate_root is not None and args.expected_freeze_sha256 is None:
        parser.error("--candidate-root requires --expected-freeze-sha256")
    expected_freeze = args.expected_freeze_sha256 or EXPECTED_FREEZE
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_freeze):
        parser.error("--expected-freeze-sha256 must be exactly 64 hexadecimal characters")
    candidate_root = args.candidate_root or DEFAULT_CANDIDATE
    if not candidate_root.is_absolute():
        candidate_root = ROOT / candidate_root
    candidate_root = candidate_root.resolve()
    source_rtl_root = args.source_rtl_root
    if not source_rtl_root.is_absolute():
        source_rtl_root = ROOT / source_rtl_root
    source_rtl_root = source_rtl_root.resolve()
    missing_sources = [str(source_rtl_root / name) for name in (ENGINE_NAME, WEIGHT_NAME)
                       if not (source_rtl_root / name).is_file()]
    if missing_sources:
        parser.error("selected RTL root is missing required sources: " + ", ".join(missing_sources))

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    run_dir = HERE / "evidence" / f"preflight_{stamp}_{os.getpid()}"
    run_dir.mkdir(parents=True, exist_ok=False)
    source_paths = {ENGINE_NAME: source_rtl_root / ENGINE_NAME,
                    WEIGHT_NAME: source_rtl_root / WEIGHT_NAME}
    before = {name: sha256_file(path) for name, path in source_paths.items()}
    snapshot_dir = run_dir / "production_snapshot"
    snapshot_dir.mkdir()
    for name, path in source_paths.items():
        shutil.copy2(path, snapshot_dir / name)
    write_json(run_dir / "production_snapshot_sha256.json", before)

    summary: dict[str, Any] = {
        "runner": str(Path(__file__).relative_to(ROOT)),
        "started_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "mode": "NO_APPLY_PRODUCTION_SOURCE_SIMULATION_PREFLIGHT",
        "apply": False,
        "synthesis": "NOT_RUN",
        "place_and_route": "NOT_RUN",
        "physical_board": "NOT_RUN",
        "candidate_root": display_path(candidate_root),
        "expected_candidate_freeze_sha256": expected_freeze.lower(),
        "source_rtl_root": display_path(source_rtl_root),
        "production_sources_before_sha256": before,
        "tests": [],
    }
    freeze = verify_frozen_inputs(candidate_root, expected_freeze.lower())
    gates = check_integration_gates(candidate_root)
    write_json(run_dir / "freeze_audit.json", freeze)
    write_json(run_dir / "integration_gate_audit.json", gates)
    summary["frozen_candidate_audit"] = freeze["status"]
    summary["integration_gates"] = gates["status"]
    summary["integration_gate_blockers"] = gates["blockers"]
    failure: str | None = None
    if freeze["status"] != "PASS":
        failure = "frozen candidate integrity check failed"
    elif not args.gate_only:
        try:
            summary["tests"] = run_local_regressions(
                run_dir, not args.skip_image_core_group, candidate_root, source_rtl_root)
        except Exception as exc:
            failure = f"local production-source regression failed: {exc}"

    after = {name: sha256_file(path) for name, path in source_paths.items()}
    summary["production_sources_after_sha256"] = after
    summary["production_sources_unchanged"] = before == after
    if before != after:
        failure = "production RTL bytes changed during a no-apply preflight"
    test_failures = [test["name"] for test in summary["tests"] if test.get("status") != "PASS"]
    if test_failures and failure is None:
        failure = "one or more local regressions failed: " + ", ".join(test_failures)
    summary["local_regressions"] = (
        "NOT_RUN" if args.gate_only else ("FAIL" if failure else "PASS")
    )
    summary["status"] = ("FAIL" if failure else
                         "WAITING_FOR_ROUTE_AND_BOARD_EVIDENCE" if gates["status"] != "PASS" else
                         "READY_FOR_INTEGRATION_REVIEW")
    if failure:
        summary["failure"] = failure
    summary["completed_utc"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    write_json(run_dir / "summary.json", summary)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"Evidence: {display_path(run_dir)}")
    if failure:
        return 1
    if gates["status"] != "PASS":
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
