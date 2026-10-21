#!/usr/bin/env python3
"""Read-only three-OP v103 release gate. This program never applies RTL."""
from __future__ import annotations

from datetime import datetime, timezone
import argparse
import hashlib
import importlib.util
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

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
TASK_EVIDENCE = HERE / "evidence"
CANDIDATE = ROOT / (
    "cores/system/common_scaffold/board/tang25k/build/"
    "image_filter_frame_selftest_25k_20261017_v103_nlm_morph"
)
PRODUCTION = ROOT / "cores/system/common_scaffold/image/filters/rtl"
PREFLIGHT_SCRIPT = HERE / "run_preflight.py"
ENGINE_NAME = "img_filter_frame_engine.v"
WEIGHT_NAME = "img_filter_exp_weight.v"
PRODUCTION_FILES = (ENGINE_NAME, WEIGHT_NAME)
EXPECTED_FREEZE = "a18e341165205f1a87332bd99e0a6f496b8dd210ae8d4f1123c3c2296e34bb5a"
ROUTE_LIMITS = {"lut4_max": 15000, "mult12_max": 4, "setup_mhz_min": 50,
                "hold_violations_max": 0}
LUT_MAX = 15000
DSP_MAX = 4


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import local gate module: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREFLIGHT = load_module("v103_preflight_gate", HERE / "run_preflight.py")
QUALIFIED = load_module("v103_qualified_synthesis_gate", HERE / "run_qualified_synthesis.py")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def safe_child(base: Path, relative: str) -> Path:
    rel = Path(relative)
    if rel.is_absolute() or rel.drive or ".." in rel.parts:
        raise ValueError(f"unsafe relative path: {relative!r}")
    root = base.resolve()
    target = (base / rel).resolve()
    if not target.is_relative_to(root):
        raise ValueError(f"path escapes {root}: {relative!r}")
    return target


def safe_repo_path(repo_root: Path, relative: str) -> Path:
    return safe_child(repo_root, relative)


def validate_frozen_op(candidate_root: Path, op: int,
                       expected_freeze: str = EXPECTED_FREEZE) -> tuple[dict[str, Any] | None, list[str]]:
    op_dir = candidate_root / f"op{op}"
    errors: list[str] = []
    manifest_path = op_dir / "FREEZE_MANIFEST.json"
    source_manifest_path = op_dir / "SOURCE_FREEZE_MANIFEST.json"
    status_path = op_dir / "build_status.json"
    for path in (manifest_path, source_manifest_path, status_path):
        if not path.is_file():
            errors.append(f"OP{op}: required frozen file missing: {path.name}")
    if errors:
        return None, errors
    try:
        manifest = load_json(manifest_path)
        status = load_json(status_path)
    except Exception as exc:
        return None, [f"OP{op}: frozen metadata cannot be parsed: {exc}"]

    if manifest.get("op") != op or manifest.get("parameters", {}).get("OP") != op:
        errors.append(f"OP{op}: freeze manifest operation mismatch")
    if manifest.get("verification", {}).get("result") != "PASS":
        errors.append(f"OP{op}: frozen source simulation is not PASS")
    if manifest.get("verification", {}).get("source_freeze_sha256") != expected_freeze:
        errors.append(f"OP{op}: freeze manifest source digest differs from the reviewed candidate")
    if status.get("op") != op or status.get("simulation") != "PASS":
        errors.append(f"OP{op}: build status does not prove frozen simulation PASS")
    if status.get("status") != "FROZEN_INPUT_PASS":
        errors.append(f"OP{op}: build status is not FROZEN_INPUT_PASS")
    if status.get("source_candidate_freeze_sha256") != expected_freeze:
        errors.append(f"OP{op}: build status does not bind to the reviewed source freeze")
    if sha256_file(source_manifest_path) != expected_freeze:
        errors.append(f"OP{op}: SOURCE_FREEZE_MANIFEST digest mismatch")
    if manifest.get("parameters", {}).get("route_gate") != ROUTE_LIMITS:
        errors.append(f"OP{op}: route thresholds are not 15K LUT / 4 DSP / 50 MHz / zero hold violations")

    listed = manifest.get("files_sha256")
    if not isinstance(listed, dict):
        listed = {}
        errors.append(f"OP{op}: files_sha256 is not an object")
    required_files = set(QUALIFIED.frozen_inputs_for_op(op)) | {
        "SOURCE_FREEZE_MANIFEST.json", "expected_uart.txt",
    }
    missing_listed = sorted(required_files - set(listed))
    if missing_listed:
        errors.append(f"OP{op}: frozen manifest omits required inputs: {', '.join(missing_listed)}")
    verified = 0
    for rel, expected in listed.items():
        try:
            path = safe_child(op_dir, rel)
        except ValueError as exc:
            errors.append(f"OP{op}: {exc}")
            continue
        if not path.is_file():
            errors.append(f"OP{op}: frozen file missing: {rel}")
        elif not isinstance(expected, str) or sha256_file(path) != expected.lower():
            errors.append(f"OP{op}: frozen digest mismatch: {rel}")
        else:
            verified += 1

    source_hashes = status.get("source_sha256", {})
    for rel in (f"rtl/{ENGINE_NAME}", f"rtl/{WEIGHT_NAME}"):
        path = op_dir / rel
        if not path.is_file() or not isinstance(source_hashes, dict) \
                or sha256_file(path) != source_hashes.get(rel):
            errors.append(f"OP{op}: build-status source snapshot mismatch: {rel}")

    return ({"op": op,
             "status": "PASS" if not errors else "FAIL",
             "freeze_manifest_sha256": sha256_file(manifest_path),
             "source_freeze_sha256": expected_freeze,
             "listed_files_verified": verified,
             "listed_files_total": len(listed),
             "physical_board_at_freeze": manifest.get("verification", {}).get("physical_board"),
             "synthesis_at_freeze": manifest.get("verification", {}).get("synthesis"),
             "pnr_at_freeze": manifest.get("verification", {}).get("pnr")}, errors)


def validate_qualified_synthesis(op_dir: Path, op: int, repo_root: Path,
                                 freeze_record: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    handoff_path = op_dir / "qualified_synthesis_handoff.json"
    top_path = op_dir / "top25k.json"
    checksum_path = op_dir / "top25k.json.sha256"
    if not handoff_path.is_file():
        return {"status": "WAITING", "evidence": str(handoff_path)}, [
            f"OP{op}: qualified synthesis handoff is missing"]
    if not top_path.is_file() or not checksum_path.is_file():
        errors.append(f"OP{op}: qualified top25k.json/checksum handoff is incomplete")
    try:
        handoff = load_json(handoff_path)
    except Exception as exc:
        return {"status": "FAIL", "evidence": str(handoff_path)}, [
            f"OP{op}: qualified synthesis handoff is invalid JSON: {exc}"]

    if handoff.get("status") != "QUALIFIED_FOR_OFFICIAL_ROUTE" or handoff.get("op") != op:
        errors.append(f"OP{op}: synthesis handoff is not a qualified operation-specific PASS")
    if handoff.get("top25k_json") != "top25k.json":
        errors.append(f"OP{op}: synthesis handoff points to an unexpected netlist")
    if handoff.get("frozen_manifest_sha256") != freeze_record.get("freeze_manifest_sha256"):
        errors.append(f"OP{op}: synthesis handoff is bound to a different freeze manifest")
    if handoff.get("qualified_synthesis_status") != "PASS":
        errors.append(f"OP{op}: qualified synthesis summary status is not PASS")
    if handoff.get("warning_gate") != "PASS" or handoff.get("structural_gate") != "PASS":
        errors.append(f"OP{op}: qualified synthesis warning/structure gates did not PASS")

    net_hash = sha256_file(top_path) if top_path.is_file() else None
    if not isinstance(handoff.get("top25k_sha256"), str) or handoff.get("top25k_sha256") != net_hash:
        errors.append(f"OP{op}: handoff netlist SHA256 does not match top25k.json")
    if top_path.is_file() and top_path.stat().st_size <= 0:
        errors.append(f"OP{op}: qualified netlist is empty")
    if checksum_path.is_file() and net_hash:
        expected_checksum = f"{net_hash}  top25k.json\n"
        if checksum_path.read_text(encoding="ascii", errors="replace") != expected_checksum:
            errors.append(f"OP{op}: top25k.json.sha256 content does not match the netlist")

    summary_rel = handoff.get("qualified_synthesis_summary")
    summary: dict[str, Any] = {}
    summary_path: Path | None = None
    if not isinstance(summary_rel, str):
        errors.append(f"OP{op}: synthesis handoff has no qualified summary path")
    else:
        try:
            summary_path = safe_repo_path(repo_root, summary_rel)
            evidence_root = (HERE / "evidence").resolve() if repo_root.resolve() == ROOT.resolve() \
                else (repo_root / "task" / "evidence").resolve()
            if not summary_path.is_relative_to(evidence_root):
                errors.append(f"OP{op}: qualified summary is outside the wrapper evidence directory")
            if not summary_path.is_file():
                errors.append(f"OP{op}: qualified synthesis summary is missing")
            else:
                summary = load_json(summary_path)
        except Exception as exc:
            errors.append(f"OP{op}: invalid qualified synthesis summary path/content: {exc}")

    if summary:
        if summary.get("status") != "PASS" or summary.get("op") != op:
            errors.append(f"OP{op}: qualified synthesis summary is not PASS for this OP")
        if summary.get("frozen_manifest_sha256") != freeze_record.get("freeze_manifest_sha256"):
            errors.append(f"OP{op}: synthesis summary is bound to a different freeze manifest")
        if summary.get("netlist_sha256") != net_hash:
            errors.append(f"OP{op}: synthesis summary netlist hash differs from published netlist")
        if summary.get("warning_audit", {}).get("status") != "PASS" \
                or summary.get("warning_audit", {}).get("unreviewed_warnings") != []:
            errors.append(f"OP{op}: synthesis warning audit is missing or not clean")
        if summary.get("structural_gate", {}).get("status") != "PASS":
            errors.append(f"OP{op}: synthesis mapped-netlist structure gate is not PASS")
        structural = summary.get("structural_gate", {})
        lut_count, dsp_count = structural.get("lut4_class_count"), structural.get("dsp_class_count")
        if not isinstance(lut_count, int) or isinstance(lut_count, bool) or not 0 <= lut_count <= LUT_MAX:
            errors.append(f"OP{op}: qualified synthesis LUT count is absent or exceeds {LUT_MAX}")
        if not isinstance(dsp_count, int) or isinstance(dsp_count, bool) or not 0 <= dsp_count <= DSP_MAX:
            errors.append(f"OP{op}: qualified synthesis DSP count is absent or exceeds {DSP_MAX}")
        if summary.get("yosys_error_lines") != []:
            errors.append(f"OP{op}: Yosys synthesis log contains errors or has no explicit clean error list")
        if summary.get("no_place_and_route") is not True or summary.get("no_board_programming") is not True:
            errors.append(f"OP{op}: qualified synthesis record lacks its no-PNR/no-board boundary")
        expected_inputs = {rel: digest for rel, digest in load_json(op_dir / "FREEZE_MANIFEST.json").get(
            "files_sha256", {}).items() if rel in QUALIFIED.frozen_inputs_for_op(op)}
        if summary.get("inputs") != expected_inputs:
            errors.append(f"OP{op}: synthesis input digests do not exactly match the frozen OP inputs")
        if summary_path is not None:
            log_path = summary_path.parent / "yosys_complete.log"
            expected_log_hash = summary.get("complete_log_sha256")
            if (not log_path.is_file() or not isinstance(expected_log_hash, str)
                    or not re.fullmatch(r"[0-9a-f]{64}", expected_log_hash)
                    or sha256_file(log_path) != expected_log_hash):
                errors.append(f"OP{op}: complete Yosys log is missing or its digest differs")

    return ({"status": "PASS" if not errors else "FAIL",
             "handoff": str(handoff_path),
             "netlist_sha256": net_hash,
             "qualified_summary": summary_rel,
             "lut4_class_count": summary.get("structural_gate", {}).get("lut4_class_count"),
             "dsp_class_count": summary.get("structural_gate", {}).get("dsp_class_count")}, errors)


def validate_route_and_board(op_dir: Path, op: int,
                             synthesis_record: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    route_path = op_dir / f"build_op{op}_router1_seed3_summary.json"
    route_ok, route_msg = PREFLIGHT.validate_route_gate(route_path, op)
    if not route_ok:
        errors.append(route_msg)
        route: dict[str, Any] = {}
    else:
        try:
            route = load_json(route_path)
        except Exception as exc:
            route = {}
            errors.append(f"OP{op}: route summary cannot be parsed: {exc}")
    if route:
        if route.get("input_top25k_sha256") != synthesis_record.get("netlist_sha256"):
            errors.append(f"OP{op}: route was not built from this OP's qualified netlist")
        if route.get("clk_mhz") != 50:
            errors.append(f"OP{op}: route summary does not prove the 50 MHz target")
        hold_lines = route.get("hold_violation_lines")
        if not isinstance(hold_lines, list) or hold_lines:
            errors.append(f"OP{op}: route evidence does not show an empty hold-violation list")
        hold_slacks = route.get("hold_slacks_ns")
        explicit_hold_proof = isinstance(hold_slacks, list) and bool(hold_slacks)
        if not isinstance(hold_slacks, list) or any(
                isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(float(value)) or value < 0 for value in hold_slacks):
            errors.append(f"OP{op}: optional explicit min-delay hold-slack evidence is invalid")
        hold_counts = route.get("hold_violation_counts")
        if hold_counts is not None and (not isinstance(hold_counts, list) or any(
                isinstance(value, bool) or not isinstance(value, int) or value != 0
                for value in hold_counts)):
            errors.append(f"OP{op}: route summary reports invalid/nonzero hold violation counts")
        if not explicit_hold_proof:
            errors.append(f"OP{op}: explicit min-delay hold proof is not present; router hold gate alone is insufficient for apply")
        bitstream_name = route.get("bitstream")
        bitstream_hash = route.get("bitstream_sha256")
        if not isinstance(bitstream_name, str) or Path(bitstream_name).name != bitstream_name:
            errors.append(f"OP{op}: route summary has no local bitstream name")
        elif not (op_dir / bitstream_name).is_file():
            errors.append(f"OP{op}: route bitstream file is missing")
        elif not isinstance(bitstream_hash, str) or sha256_file(op_dir / bitstream_name) != bitstream_hash:
            errors.append(f"OP{op}: route bitstream SHA256 mismatch")
        if not isinstance(bitstream_hash, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", bitstream_hash):
            errors.append(f"OP{op}: route bitstream SHA256 is absent or malformed")
    route_sha = sha256_file(route_path) if route_path.is_file() else None

    board_path = op_dir / "board_validation_summary.json"
    board_ok, board_msg = PREFLIGHT.validate_board_gate(op_dir, op)
    if not board_ok:
        errors.append(board_msg)
        board: dict[str, Any] = {}
    else:
        try:
            board = load_json(board_path)
        except Exception as exc:
            board = {}
            errors.append(f"OP{op}: board summary cannot be parsed: {exc}")
    if board and route:
        expected_uart_path = op_dir / "expected_uart.txt"
        expected_uart_bytes = expected_uart_path.read_bytes()
        try:
            expected_uart_text = expected_uart_bytes.decode("ascii")
        except UnicodeDecodeError:
            expected_uart_text = ""
        contract = re.fullmatch(rf"IF{op} PASS E=00 F=00 D=[0-9A-F]{{8}}\r\n", expected_uart_text)
        if contract is None:
            errors.append(f"OP{op}: frozen UART fixture does not match the exact CRLF PASS contract")
        if board.get("build_summary") != route_path.name or board.get("build_summary_sha256") != route_sha:
            errors.append(f"OP{op}: three-load board evidence is not bound to the official route summary")
        if board.get("bitstream_sha256") != route.get("bitstream_sha256"):
            errors.append(f"OP{op}: board summary bitstream differs from the routed bitstream")
        if board.get("programming") != "SRAM_ONLY":
            errors.append(f"OP{op}: board summary is not volatile SRAM-only validation")
        if board.get("uart_bytes_per_load") != len(expected_uart_bytes):
            errors.append(f"OP{op}: board summary UART byte count differs from the frozen contract")
        for index, item in enumerate(board.get("loads", []), 1):
            if item.get("load") != index:
                errors.append(f"OP{op}: board load index sequence is not 1,2,3")
            if item.get("bitstream_sha256") != route.get("bitstream_sha256"):
                errors.append(f"OP{op}: board load {index} used a different bitstream digest")
            record_name = item.get("record")
            if isinstance(record_name, str):
                record_path = safe_child(op_dir, record_name)
                if record_path.is_file():
                    try:
                        capture = load_json(record_path)
                    except Exception:
                        capture = {}
                    if capture.get("bitstream_sha256") != route.get("bitstream_sha256"):
                        errors.append(f"OP{op}: UART record {index} does not bind to the routed bitstream")

    return ({"status": "PASS" if not errors else "FAIL",
             "route_gate": "PASS" if route_ok else "WAITING_OR_FAIL",
             "route_evidence": str(route_path),
             "route_summary_sha256": route_sha,
             "hold_violation_lines": route.get("hold_violation_lines"),
             "hold_slacks_ns": route.get("hold_slacks_ns"),
             "router_hold_gate": route.get("gates", {}).get("hold"),
             "explicit_min_delay_hold_proof": "PASS" if route.get("hold_slacks_ns") else "NOT_PROVIDED",
             "lut4": route.get("util", {}).get("lut4"),
             "mult12": route.get("util", {}).get("mult12"),
             "fmax_mhz": route.get("fmax_mhz"),
             "bitstream_sha256": route.get("bitstream_sha256"),
             "board_gate": "PASS" if board_ok else "WAITING_OR_FAIL",
             "board_evidence": str(board_path),
             "board_loads": len(board.get("loads", []))}, errors)


def compare_production_to_candidate(candidate_root: Path, production_root: Path) -> dict[str, Any]:
    comparisons = {}
    any_difference = False
    for name in PRODUCTION_FILES:
        production_path = production_root / name
        candidate_hashes = {}
        for op in range(3):
            candidate_path = candidate_root / f"op{op}" / "rtl" / name
            candidate_hashes[str(op)] = sha256_file(candidate_path) if candidate_path.is_file() else None
        production_hash = sha256_file(production_path) if production_path.is_file() else None
        all_match = production_hash is not None and all(
            digest == production_hash for digest in candidate_hashes.values())
        if not all_match:
            any_difference = True
        comparisons[name] = {"production_sha256": production_hash,
                             "candidate_sha256_by_op": candidate_hashes,
                             "matches_all_frozen_ops": all_match}
    return {"status": "DIFFERS_FROM_FROZEN_V103_CANDIDATE" if any_difference else "MATCHES_FROZEN_V103_CANDIDATE",
            "production_update_required_for_v103": any_difference,
            "files": comparisons}


def audit_three_ops(candidate_root: Path, repo_root: Path,
                    expected_freeze: str = EXPECTED_FREEZE,
                    regression: dict[str, Any] | None = None) -> dict[str, Any]:
    errors: list[str] = []
    op_results: list[dict[str, Any]] = []
    for op in range(3):
        op_dir = candidate_root / f"op{op}"
        frozen, freeze_errors = validate_frozen_op(candidate_root, op, expected_freeze)
        errors.extend(freeze_errors)
        if frozen is None:
            op_results.append({"op": op, "status": "BLOCKED", "freeze": "FAIL",
                               "qualified_synthesis": "NOT_CHECKED",
                               "route_and_board": "NOT_CHECKED"})
            continue
        synthesis, synthesis_errors = validate_qualified_synthesis(op_dir, op, repo_root, frozen)
        errors.extend(synthesis_errors)
        route_board, route_board_errors = validate_route_and_board(op_dir, op, synthesis)
        errors.extend(route_board_errors)
        passed = not freeze_errors and not synthesis_errors and not route_board_errors
        op_results.append({"op": op, "status": "PASS" if passed else "BLOCKED",
                           "freeze": frozen, "qualified_synthesis": synthesis,
                           "route_and_board": route_board})

    regression_status = (regression or {}).get("status", "NOT_RUN")
    if regression_status != "PASS":
        errors.append("independent production-source regression must PASS before any separate apply review")
    apply_gate = not errors and len(op_results) == 3 and all(r.get("status") == "PASS" for r in op_results)
    return {"status": "READY_FOR_SEPARATE_APPLY_REVIEW" if apply_gate else "BLOCKED",
            "apply_gate": "PASS" if apply_gate else "BLOCKED",
            "apply_performed": False,
            "apply_implemented": False,
            "production_regression": regression_status,
            "ops": op_results,
            "blockers": errors}


def create_production_backup(production_root: Path, evidence_dir: Path) -> dict[str, Any]:
    backup_dir = evidence_dir / "old_production_sources"
    backup_dir.mkdir(parents=True, exist_ok=False)
    files: dict[str, Any] = {}
    for name in PRODUCTION_FILES:
        source = production_root / name
        if not source.is_file():
            raise FileNotFoundError(f"production source missing: {source}")
        target = backup_dir / name
        shutil.copy2(source, target)
        source_hash, backup_hash = sha256_file(source), sha256_file(target)
        if source_hash != backup_hash:
            raise RuntimeError(f"source backup digest mismatch: {name}")
        files[name] = {"sha256": source_hash, "bytes": target.stat().st_size}
    manifest = {"purpose": "recovery snapshot before any future production integration",
                "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "apply_performed": False,
                "source_dir": str(production_root.relative_to(ROOT)) if production_root.resolve().is_relative_to(ROOT.resolve()) else str(production_root),
                "files": files}
    write_json(backup_dir / "backup_manifest.json", manifest)
    return {"directory": str(backup_dir.relative_to(evidence_dir)),
            "manifest": str((backup_dir / "backup_manifest.json").relative_to(evidence_dir)),
            "files": files}


def run_independent_regression(evidence_dir: Path) -> dict[str, Any]:
    prior_dirs = {path.resolve() for path in TASK_EVIDENCE.glob("preflight_*") if path.is_dir()}
    command = [sys.executable, "-B", str(PREFLIGHT_SCRIPT), "--skip-image-core-group"]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True,
                            timeout=1200, check=False)
    tail = (result.stdout + result.stderr)[-12000:]
    (evidence_dir / "production_regression_launcher_tail.txt").write_text(tail, encoding="utf-8")
    new_dirs = [path for path in TASK_EVIDENCE.glob("preflight_*")
                if path.is_dir() and path.resolve() not in prior_dirs]
    if len(new_dirs) != 1:
        return {"status": "FAIL", "exit_code": result.returncode,
                "reason": f"expected one new independent preflight evidence directory; found {len(new_dirs)}"}
    summary_path = new_dirs[0] / "summary.json"
    if not summary_path.is_file():
        return {"status": "FAIL", "exit_code": result.returncode,
                "reason": "independent preflight did not publish summary.json"}
    summary = load_json(summary_path)
    passed = (summary.get("local_regressions") == "PASS"
              and summary.get("production_sources_unchanged") is True
              and summary.get("failure") is None)
    return {"status": "PASS" if passed else "FAIL",
            "exit_code": result.returncode,
            "preflight_summary": str(summary_path.relative_to(ROOT)),
            "preflight_status": summary.get("status"),
            "local_regressions": summary.get("local_regressions"),
            "production_sources_unchanged": summary.get("production_sources_unchanged"),
            "integration_gates": summary.get("integration_gates"),
            "evidence_directory": str(new_dirs[0].relative_to(ROOT))}


def fixture_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def build_valid_fixture(repo_root: Path, expected_freeze: str) -> Path:
    candidate_root = repo_root / "candidate"
    evidence_root = repo_root / "task" / "evidence"
    for op in range(3):
        op_dir = candidate_root / f"op{op}"
        op_dir.mkdir(parents=True)
        payloads: dict[str, bytes] = {}
        for rel in QUALIFIED.frozen_inputs_for_op(op):
            payloads[rel] = f"fixture:{op}:{rel}\n".encode("ascii")
        payloads["SOURCE_FREEZE_MANIFEST.json"] = b"fixture source freeze manifest\n"
        expected_uart = f"IF{op} PASS E=00 F=00 D={0x12345678 + op:08X}\r\n".encode("ascii")
        payloads["expected_uart.txt"] = expected_uart
        for rel, raw in payloads.items():
            path = op_dir / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        files = {rel: hashlib.sha256(raw).hexdigest() for rel, raw in payloads.items()}
        freeze = {"op": op, "parameters": {"OP": op, "route_gate": ROUTE_LIMITS},
                  "verification": {"result": "PASS", "source_freeze_sha256": expected_freeze,
                                   "physical_board": "NOT_RUN", "synthesis": "NOT_RUN", "pnr": "NOT_RUN"},
                  "files_sha256": files}
        fixture_write_json(op_dir / "FREEZE_MANIFEST.json", freeze)
        fixture_write_json(op_dir / "build_status.json", {
            "status": "FROZEN_INPUT_PASS", "op": op, "simulation": "PASS",
            "source_candidate_freeze_sha256": expected_freeze,
            "source_sha256": {rel: files[rel] for rel in (f"rtl/{ENGINE_NAME}", f"rtl/{WEIGHT_NAME}")},
        })

        netlist_raw = json.dumps({"modules": {"fixture": {"cells": {}}}}).encode("ascii")
        (op_dir / "top25k.json").write_bytes(netlist_raw)
        net_hash = hashlib.sha256(netlist_raw).hexdigest()
        (op_dir / "top25k.json.sha256").write_text(f"{net_hash}  top25k.json\n", encoding="ascii")
        manifest_sha = sha256_file(op_dir / "FREEZE_MANIFEST.json")
        synth_dir = evidence_root / f"qualified_synthesis_op{op}_fixture"
        synth_dir.mkdir(parents=True)
        yosys_log = b"fixture Yosys complete log\n"
        (synth_dir / "yosys_complete.log").write_bytes(yosys_log)
        synth_inputs = {rel: files[rel] for rel in QUALIFIED.frozen_inputs_for_op(op)}
        synth_summary = {
            "status": "PASS", "op": op, "frozen_manifest_sha256": manifest_sha,
            "inputs": synth_inputs, "netlist_sha256": net_hash,
            "structural_gate": {"status": "PASS", "lut4_class_count": 1234, "dsp_class_count": 1},
            "warning_audit": {"status": "PASS", "unreviewed_warnings": []},
            "yosys_error_lines": [], "no_place_and_route": True, "no_board_programming": True,
            "complete_log_sha256": hashlib.sha256(yosys_log).hexdigest(),
        }
        fixture_write_json(synth_dir / "summary.json", synth_summary)
        synth_rel = (synth_dir / "summary.json").relative_to(repo_root).as_posix()
        fixture_write_json(op_dir / "qualified_synthesis_handoff.json", {
            "status": "QUALIFIED_FOR_OFFICIAL_ROUTE", "op": op, "top25k_json": "top25k.json",
            "top25k_sha256": net_hash, "frozen_manifest_sha256": manifest_sha,
            "qualified_synthesis_summary": synth_rel, "qualified_synthesis_status": "PASS",
            "warning_gate": "PASS", "structural_gate": "PASS",
        })

        route_hash = ""
        bitstream = f"candidate_op{op}_router1_seed3.fs"
        bitstream_raw = f"fixture-bitstream-op{op}\n".encode("ascii")
        (op_dir / bitstream).write_bytes(bitstream_raw)
        bitstream_sha = hashlib.sha256(bitstream_raw).hexdigest()
        route = {
            "status": "BUILD_PASS_NOT_BOARD", "attempt": f"op{op}_router1_seed3",
            "device": "GW5A-LV25MG121NES", "clk_mhz": 50,
            "gates": {"route_process": True, "route_complete": True,
                      "lut4_device_gate": True, "dff_device_gate": True,
                      "bsram_device_gate": True, "mult12_device_gate": True,
                      "lut_15k": True, "dsp_4": True, "timing_50mhz": True,
                      "hold": True, "official_apicula_import": True},
            "util": {"lut4": 2345, "dff": 1450, "bsram": 2, "mult12": 1},
            "fmax_mhz": [52.0, 50.8],
            "hold_slacks_ns": [0.08], "hold_violation_lines": [], "hold_violation_counts": [0],
            "input_top25k_sha256": net_hash, "bitstream": bitstream,
            "bitstream_sha256": bitstream_sha,
        }
        route_path = op_dir / f"build_op{op}_router1_seed3_summary.json"
        fixture_write_json(route_path, route)
        route_hash = sha256_file(route_path)
        loads = []
        for load_index in range(1, 4):
            record_name = f"board_uart_fixture_{load_index}.json"
            fixture_write_json(op_dir / record_name, {
                "status": "PASS", "programming": "PASS_SRAM_ONLY",
                "jtag_detected_idcode": "0x1281b", "uart_validation": "PASS_EXACT_BYTES",
                "uart_capture": expected_uart.decode("ascii"), "bitstream_sha256": bitstream_sha,
            })
            loads.append({"load": load_index, "record": record_name,
                          "record_sha256": sha256_file(op_dir / record_name),
                          "bitstream_sha256": bitstream_sha})
        fixture_write_json(op_dir / "board_validation_summary.json", {
            "status": "PASS", "op": op, "programming": "SRAM_ONLY",
            "independent_sram_loads": 3, "expected_uart": expected_uart.decode("ascii"),
            "uart_bytes_per_load": len(expected_uart), "build_summary": route_path.name,
            "build_summary_sha256": route_hash, "bitstream_sha256": bitstream_sha,
            "loads": loads,
        })
    return candidate_root


def self_test() -> int:
    checks = 0
    expected_freeze = hashlib.sha256(b"fixture source freeze manifest\n").hexdigest()
    with tempfile.TemporaryDirectory(prefix="v103_final_integration_selftest_") as raw:
        root = Path(raw)
        candidate = build_valid_fixture(root, expected_freeze)
        passed = audit_three_ops(candidate, root, expected_freeze, {"status": "PASS"})
        if passed["apply_gate"] != "PASS" or len(passed["ops"]) != 3:
            raise AssertionError("all-gates positive three-OP fixture was rejected")
        print("PASS final-gate all_three_ops_require_individual_complete_evidence")
        checks += 1

        op1_route = candidate / "op1" / "build_op1_router1_seed3_summary.json"
        route = load_json(op1_route)
        route["fmax_mhz"] = [49.9]
        fixture_write_json(op1_route, route)
        blocked = audit_three_ops(candidate, root, expected_freeze, {"status": "PASS"})
        if blocked["apply_gate"] != "BLOCKED" or not any("50" in item or "fmax" in item.lower()
                                                            for item in blocked["blockers"]):
            raise AssertionError("sub-50 MHz route was not rejected")
        print("PASS final-gate below_50mhz_rejected")
        checks += 1
        route["fmax_mhz"] = [52.0, 50.8]
        route.pop("hold_slacks_ns")
        fixture_write_json(op1_route, route)
        blocked = audit_three_ops(candidate, root, expected_freeze, {"status": "PASS"})
        if blocked["apply_gate"] != "BLOCKED" or not any(
                "explicit min-delay hold proof" in item for item in blocked["blockers"]):
            raise AssertionError("router hold gate without explicit min-delay evidence was accepted for apply")
        print("PASS final-gate router_hold_gate_not_confused_with_min_delay_proof")
        checks += 1
        route["hold_slacks_ns"] = [0.08]
        fixture_write_json(op1_route, route)

        board_path = candidate / "op0" / "board_validation_summary.json"
        board = load_json(board_path)
        board["loads"] = board["loads"][:2]
        fixture_write_json(board_path, board)
        blocked = audit_three_ops(candidate, root, expected_freeze, {"status": "PASS"})
        if blocked["apply_gate"] != "BLOCKED":
            raise AssertionError("board evidence with fewer than three loads was accepted")
        print("PASS final-gate three_distinct_uart_loads_required")
        checks += 1

        board = load_json(board_path)
        # Restore from a fresh complete fixture instead of mutating record digests.
        candidate = build_valid_fixture(root / "repaired", expected_freeze)
        blocked = audit_three_ops(candidate, root / "repaired", expected_freeze, {"status": "NOT_RUN"})
        if blocked["apply_gate"] != "BLOCKED":
            raise AssertionError("missing independent production regression was accepted")
        print("PASS final-gate independent_production_regression_required")
        checks += 1

        source_root = root / "production"
        source_root.mkdir()
        for name in PRODUCTION_FILES:
            (source_root / name).write_bytes(f"old:{name}\n".encode("ascii"))
        backup_evidence = root / "backup-test"
        backup_evidence.mkdir()
        backup = create_production_backup(source_root, backup_evidence)
        for name in PRODUCTION_FILES:
            copied = backup_evidence / backup["directory"] / name
            if not copied.is_file() or sha256_file(copied) != sha256_file(source_root / name):
                raise AssertionError(f"production source backup failed for {name}")
        print("PASS final-gate old_production_source_backup_hashes")
        checks += 1
    print(f"FINAL THREE-OP INTEGRATION HOST SELF-TEST PASS checks={checks}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="run disposable host fixtures only")
    parser.add_argument("--run-production-regression", action="store_true",
                        help="run independent local Icarus regression; no synthesis/PNR/board")
    args = parser.parse_args()
    if args.self_test:
        return self_test()

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    evidence_dir = TASK_EVIDENCE / f"final_integration_{stamp}_{os.getpid()}"
    evidence_dir.mkdir(parents=True, exist_ok=False)
    production_hashes_before = {
        name: sha256_file(PRODUCTION / name) for name in PRODUCTION_FILES
    }
    backup = create_production_backup(PRODUCTION, evidence_dir)
    production_comparison = compare_production_to_candidate(CANDIDATE, PRODUCTION)
    regression = run_independent_regression(evidence_dir) if args.run_production_regression \
        else {"status": "NOT_RUN", "reason": "use --run-production-regression before any separate apply review"}
    production_hashes_after = {
        name: sha256_file(PRODUCTION / name) for name in PRODUCTION_FILES
    }
    if production_hashes_after != production_hashes_before:
        regression = {"status": "FAIL", "reason": "production RTL changed during the no-apply runner"}
    audit = audit_three_ops(CANDIDATE, ROOT, EXPECTED_FREEZE, regression)
    audit.update({
        "runner": str(Path(__file__).relative_to(ROOT)),
        "started_utc": stamp,
        "no_apply": True,
        "no_synthesis": True,
        "no_place_and_route": True,
        "no_hardware": True,
        "production_source_backup": backup,
        "production_source_comparison": production_comparison,
        "production_source_sha256_before": production_hashes_before,
        "production_source_sha256_after": production_hashes_after,
        "production_sources_unchanged": production_hashes_before == production_hashes_after,
        "production_regression_evidence": regression,
        "evidence_directory": str(evidence_dir.relative_to(ROOT)),
    })
    write_json(evidence_dir / "final_integration_summary.json", audit)
    print(json.dumps(audit, indent=2, ensure_ascii=False))
    print(f"Evidence: {evidence_dir.relative_to(ROOT)}")
    return 0 if audit["apply_gate"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
