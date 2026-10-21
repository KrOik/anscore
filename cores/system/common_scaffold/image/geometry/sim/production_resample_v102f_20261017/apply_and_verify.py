#!/usr/bin/env python3
"""Gate and test an explicitly frozen geometry resampler candidate.

The normal mode is read-only. All simulator inputs, binaries, and full logs are
created under TemporaryDirectory and removed on exit. ``--apply`` is an
explicit, rollback-protected production update and is intentionally not used
by this runner's self-test or preflight mode.

Explicit minimum-delay evidence is a separate JSON record. Its required
schema is documented by ``--help`` and enforced independently of a router's
``gates.hold`` flag; setup Fmax/slack values are never accepted as hold proof.

The proof record must contain ``schema=explicit_min_delay_proof_v1``,
``status=PASS``, the candidate name, the exact freeze and packed-route-summary
SHA256 values, a non-empty non-negative ``min_delay_slacks_ns`` list, and a
candidate-local source report filename plus its SHA256.
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
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
BUILD_ROOT = ROOT / "cores/system/common_scaffold/board/tang25k/build"
PRODUCTION = ROOT / "cores/system/common_scaffold/image/geometry/rtl"
PRODUCTION_SIM = ROOT / "cores/system/common_scaffold/image/geometry/sim"
GROUP_RUNNER = PRODUCTION_SIM / "run_geometry_group.py"
PRODUCTION_AREA = PRODUCTION / "img_geo_area_resample.v"
AREA_CANDIDATE = "img_geo_area_resample_serial.v"
AREA_PRODUCTION_NAME = "img_geo_area_resample.v"
OTHER_SOURCES = (
    "img_geo_frame_buffered.v",
    "img_geo_frame_sampler.v",
    "img_geo_frame_transform.v",
    "img_geo_frame_writer.v",
    "img_geo_integer_upsample.v",
    "img_geo_inverse_map.v",
    "img_geo_raster_coords.v",
)
TEST_SOURCE_NAMES = (AREA_PRODUCTION_NAME, *OTHER_SOURCES)
TEST_INPUTS = (
    "image_resample_frame_selftest_25k.v",
    "vectors.vh",
    "tb_image_resample_frame_selftest_25k.sv",
    "tb_image_resample_por.sv",
    "tb_img_area_unsigned_divider.v",
    "tb_img_area_dst16_contract.sv",
)
PASS_MARKERS = {
    "divider": ("AREA DIVIDER RESET/CE TEST PASS",),
    "dst16": (
        "AREA DST16 16x1 PIPELINE/RESET/CE PASS",
        "AREA DST16 17x17 GOLDEN PASS",
        "AREA DST16 65535 LAST-COORDINATE PASS",
        "AREA DST16 65535 VERTICAL LAST-COORDINATE PASS",
        "AREA DST16 CONTRACT PASS",
    ),
    "por": ("POR RESET TEST PASS cycles=4 release=2",),
    "normal": ("RSMP PASS C=11 I=0053 O=0096 E=06 D=4229D567", "RESAMPLE SELFTEST PASS"),
    "fault": ("RSMP FAIL C=01 I=0014 O=0009 E=00 D=03BED539", "RESAMPLE SELFTEST PASS"),
}


def sha_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha(path: Path) -> str:
    return sha_bytes(path.read_bytes())


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def safe_candidate_path(argument: str) -> Path:
    unresolved = Path(argument).expanduser()
    if not unresolved.is_absolute():
        if len(unresolved.parts) > 1:
            unresolved = ROOT / unresolved
        else:
            unresolved = BUILD_ROOT / unresolved
    if unresolved.is_symlink():
        raise RuntimeError("candidate root cannot be a symlink")
    candidate = unresolved.resolve(strict=True)
    if candidate.parent != BUILD_ROOT.resolve() or not candidate.is_dir():
        raise RuntimeError("candidate root must be an existing direct child of Tang 25K build/")
    return candidate


def candidate_freeze(candidate: Path, expected_sha: str) -> dict[str, Any]:
    freeze_path = candidate / "FREEZE_MANIFEST.json"
    if not freeze_path.is_file():
        raise RuntimeError("candidate is missing FREEZE_MANIFEST.json")
    actual_sha = sha(freeze_path)
    expected_sha = expected_sha.lower().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha) or actual_sha != expected_sha:
        raise RuntimeError(f"freeze SHA mismatch: expected {expected_sha}, got {actual_sha}")
    freeze = read_json(freeze_path)
    if freeze.get("candidate") != candidate.name:
        raise RuntimeError("freeze manifest candidate name does not match selected root")
    files = freeze.get("files_sha256")
    if not isinstance(files, dict) or not files:
        raise RuntimeError("freeze manifest has no files_sha256 map")
    for relative, expected in files.items():
        rel = Path(relative)
        path = (candidate / rel).resolve()
        if (rel.is_absolute() or candidate not in path.parents or not path.is_file()
                or not isinstance(expected, str) or sha(path) != expected.lower()):
            raise RuntimeError(f"frozen candidate file missing, escaped, or changed: {relative}")
    aggregate = sha_bytes("\n".join(f"{name}  {files[name]}" for name in sorted(files)).encode("utf-8"))
    if aggregate != freeze.get("aggregate_sha256"):
        raise RuntimeError("freeze manifest aggregate SHA256 mismatch")
    sim = candidate / "simulation_summary.json"
    if not sim.is_file():
        raise RuntimeError("candidate is missing simulation_summary.json")
    simulation = read_json(sim)
    if simulation.get("candidate") != candidate.name or simulation.get("status") != "PASS":
        raise RuntimeError("candidate simulation summary is not PASS for this candidate")
    declared_sim_sha = freeze.get("simulation", {}).get("summary_sha256")
    if declared_sim_sha is not None and declared_sim_sha != sha(sim):
        raise RuntimeError("freeze manifest points to a different simulation summary")
    return {
        "status": "PASS", "freeze_manifest_sha256": actual_sha,
        "aggregate_sha256": aggregate, "frozen_file_count": len(files),
        "simulation_summary_sha256": sha(sim), "expected_digest": simulation.get("expected_digest"),
    }


def file_watch(candidate: Path, include_release_evidence: bool = True) -> dict[str, str]:
    """Track all frozen files plus post-freeze release evidence during a run."""
    watch: dict[str, str] = {}
    freeze = read_json(candidate / "FREEZE_MANIFEST.json")
    for relative in freeze["files_sha256"]:
        watch[relative] = sha(candidate / relative)
    if include_release_evidence:
        for name in ("FREEZE_MANIFEST.json", "simulation_summary.json", "build_status.json",
                     "board_validation_summary.json", "expected_uart.txt", "expected_uart_fault.txt"):
            path = candidate / name
            if path.is_file():
                watch[name] = sha(path)
        for path in candidate.glob("*summary*.json"):
            watch[path.name] = sha(path)
        for pattern in ("route_*status.json", "board_uart_*.json", "min_delay*.json", "explicit_min_delay*.json"):
            for path in candidate.glob(pattern):
                if path.is_file():
                    watch[path.name] = sha(path)
    return watch


def assert_unchanged(candidate: Path, before: dict[str, str]) -> None:
    changed = [name for name, expected in before.items()
               if not (candidate / name).is_file() or sha(candidate / name) != expected]
    if changed:
        raise RuntimeError("candidate evidence changed during integration: " + ", ".join(changed))


def safe_candidate_file(candidate: Path, argument: str, label: str) -> Path:
    rel = Path(argument)
    if rel.is_absolute() or rel.name != argument:
        raise RuntimeError(f"{label} must be a filename within the candidate directory")
    path = candidate / rel
    if not path.is_file():
        raise RuntimeError(f"{label} is missing: {argument}")
    return path


def locate_release_paths(candidate: Path, board_name: str | None,
                         summary_name: str | None, route_name: str | None,
                         min_delay_name: str | None) -> dict[str, Path | None]:
    board_path = (safe_candidate_file(candidate, board_name, "board summary") if board_name else
                  (candidate / "board_validation_summary.json"))
    summary_path: Path | None = None
    route_path: Path | None = None
    if board_path.is_file():
        board = read_json(board_path)
        declared = board.get("original_build_summary")
        if summary_name:
            summary_path = safe_candidate_file(candidate, summary_name, "route build summary")
        elif isinstance(declared, str) and Path(declared).name == declared:
            possible = candidate / declared
            if possible.is_file():
                summary_path = possible
        if summary_path is not None and not route_name:
            matches = []
            for path in candidate.glob("route_*status.json"):
                try:
                    record = read_json(path)
                except (OSError, ValueError, json.JSONDecodeError):
                    continue
                if record.get("artifacts", {}).get("summary") == summary_path.name:
                    matches.append(path)
            if len(matches) == 1:
                route_path = matches[0]
    if summary_name and summary_path is None:
        summary_path = safe_candidate_file(candidate, summary_name, "route build summary")
    if route_name:
        route_path = safe_candidate_file(candidate, route_name, "route status")
    if min_delay_name:
        min_delay_path = safe_candidate_file(candidate, min_delay_name, "explicit min-delay proof")
    else:
        choices = [candidate / name for name in ("explicit_min_delay_proof.json", "min_delay_proof.json")
                   if (candidate / name).is_file()]
        min_delay_path = choices[0] if len(choices) == 1 else None
    return {"board": board_path if board_path.is_file() else None,
            "summary": summary_path, "route": route_path, "min_delay": min_delay_path}


def numeric_list(values: Any) -> list[float] | None:
    if not isinstance(values, list) or not values:
        return None
    try:
        result = [float(value) for value in values]
    except (TypeError, ValueError):
        return None
    if any(value != value or value in (float("inf"), float("-inf")) for value in result):
        return None
    return result


def corrected_library_gate(candidate: Path, route: dict[str, Any] | None) -> dict[str, Any]:
    if not route:
        return {"status": "FAIL", "reason": "matching route-status record is missing"}
    chipdb = route.get("chipdb")
    recorded_sha = route.get("chipdb_sha256", "")
    command = route.get("route_command", [])
    if not isinstance(chipdb, str) or not isinstance(recorded_sha, str):
        return {"status": "FAIL", "reason": "route record omits timing library path/hash"}
    if not any(label in Path(chipdb).name.lower() for label in ("patched", "corrected")):
        return {"status": "FAIL", "reason": "timing library path is not marked patched/corrected",
                "path": chipdb}
    if not re.fullmatch(r"[0-9a-fA-F]{64}", recorded_sha):
        return {"status": "FAIL", "reason": "route record has no SHA256 for corrected timing library"}
    if not isinstance(command, list) or "--chipdb" not in command:
        return {"status": "FAIL", "reason": "route command does not identify the timing library"}
    index = command.index("--chipdb")
    if index + 1 >= len(command) or command[index + 1] != chipdb:
        return {"status": "FAIL", "reason": "route command and timing library path disagree"}
    library_path = Path(chipdb)
    if not library_path.is_file() or sha(library_path) != recorded_sha.lower():
        return {"status": "FAIL", "reason": "corrected timing library is absent or hash-mismatched",
                "path": chipdb, "recorded_sha256": recorded_sha.lower()}
    return {"status": "PASS", "path": chipdb, "sha256": recorded_sha.lower()}


def explicit_min_delay_gate(path: Path | None, candidate: Path, freeze_sha: str,
                            summary_path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {"status": "FAIL", "reason": "explicit min-delay proof record is missing"}
    try:
        proof = read_json(path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return {"status": "FAIL", "reason": f"invalid min-delay proof JSON: {error}"}
    slacks = numeric_list(proof.get("min_delay_slacks_ns"))
    if (proof.get("schema") != "explicit_min_delay_proof_v1"
            or proof.get("status") != "PASS"
            or proof.get("candidate") != candidate.name
            or proof.get("freeze_manifest_sha256") != freeze_sha
            or summary_path is None
            or proof.get("route_summary_sha256") != sha(summary_path)
            or slacks is None or min(slacks) < 0):
        return {"status": "FAIL", "reason": "proof must bind PASS min-delay values to this candidate, freeze, and route summary",
                "schema": proof.get("schema"), "reported_status": proof.get("status"),
                "min_delay_slacks_ns": slacks}
    report_name = proof.get("source_report")
    report_sha = proof.get("source_report_sha256")
    if not isinstance(report_name, str) or Path(report_name).name != report_name:
        return {"status": "FAIL", "reason": "proof must identify a source report by safe filename"}
    source_report = candidate / report_name
    if (not source_report.is_file() or not isinstance(report_sha, str)
            or sha(source_report) != report_sha.lower()):
        return {"status": "FAIL", "reason": "min-delay source report is missing or hash-mismatched"}
    return {"status": "PASS", "source": path.name, "source_report": report_name,
            "source_report_sha256": report_sha.lower(), "min_delay_slacks_ns": slacks,
            "minimum_slack_ns": min(slacks)}


def resource_counts(summary: dict[str, Any]) -> tuple[int | None, int | None]:
    util = summary.get("util", {})
    lut = summary.get("lut_class_cells", util.get("lut4") if isinstance(util, dict) else None)
    dsp = summary.get("dsp_class_cells", util.get("mult12") if isinstance(util, dict) else None)
    try:
        return int(lut), int(dsp)
    except (TypeError, ValueError):
        return None, None


def route_build_gate(summary: dict[str, Any]) -> dict[str, Any]:
    gates = summary.get("gates", {})
    passed = (summary.get("status") == "BUILD_PASS_NOT_BOARD"
              and summary.get("clk_mhz") == 50
              and isinstance(gates, dict)
              and gates.get("route_complete") is True
              and gates.get("timing_50mhz") is True)
    return {"status": "PASS" if passed else "FAIL",
            "reason": None if passed else "route summary must be packed BUILD_PASS_NOT_BOARD, route-complete, and setup-qualified at 50 MHz"}


def board_load_gate(candidate: Path, path: Path | None, summary_path: Path | None,
                    expected_uart_path: Path) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {"status": "FAIL", "reason": "three-load board_validation_summary.json is missing"}
    try:
        board = read_json(path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return {"status": "FAIL", "reason": f"invalid board summary: {error}"}
    try:
        expected_uart = expected_uart_path.read_bytes().decode("ascii")
    except (OSError, UnicodeDecodeError) as error:
        return {"status": "FAIL", "reason": f"expected UART fixture is invalid: {error}"}
    rows = board.get("loads")
    declared_summary = board.get("original_build_summary")
    if (board.get("status") != "PASS" or board.get("candidate") != candidate.name
            or board.get("programming") != "SRAM_ONLY"
            or board.get("independent_sram_loads") != 3
            or not isinstance(rows, list) or len(rows) != 3
            or declared_summary is None or summary_path is None
            or declared_summary != summary_path.name
            or board.get("expected_uart") != expected_uart
            or board.get("uart_bytes_per_load") != len(expected_uart_path.read_bytes())
            or board.get("functional_clk_mhz") != 50):
        return {"status": "FAIL", "reason": "board summary is not three independent 50 MHz SRAM-only loads for this route and UART"}
    if (board.get("original_build_summary_sha256") is not None
            and board["original_build_summary_sha256"] != sha(summary_path)):
        return {"status": "FAIL", "reason": "board summary is bound to a different routed build"}
    try:
        summary = read_json(summary_path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return {"status": "FAIL", "reason": f"invalid routed build summary: {error}"}
    bitstream_name = summary.get("bitstream")
    bitstream_sha = summary.get("bitstream_sha256", "").lower()
    if (not isinstance(bitstream_name, str) or Path(bitstream_name).name != bitstream_name
            or not re.fullmatch(r"[0-9a-f]{64}", bitstream_sha)):
        return {"status": "FAIL", "reason": "routed build has not produced a safe, hashed bitstream"}
    bitstream_path = candidate / bitstream_name
    if not bitstream_path.is_file() or sha(bitstream_path) != bitstream_sha:
        return {"status": "FAIL", "reason": "routed bitstream is missing or differs from its build summary"}
    if board.get("bitstream_sha256", "").lower() != bitstream_sha:
        return {"status": "FAIL", "reason": "board loads are not bound to the routed bitstream"}
    bitstream_sha = board.get("bitstream_sha256", "").lower()
    record_paths: set[Path] = set()
    record_shas: set[str] = set()
    for row in rows:
        name = row.get("record")
        digest = row.get("sha256", "").lower()
        if (not isinstance(name, str) or Path(name).name != name
                or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            return {"status": "FAIL", "reason": "board load row has unsafe record name or invalid hash"}
        record_path = candidate / name
        if record_path in record_paths or digest in record_shas or not record_path.is_file() or sha(record_path) != digest:
            return {"status": "FAIL", "reason": "board load records are duplicated, missing, or hash-mismatched"}
        record_paths.add(record_path)
        record_shas.add(digest)
        try:
            record = read_json(record_path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            return {"status": "FAIL", "reason": f"invalid board load record {name}: {error}"}
        if (record.get("status") != "PASS" or record.get("programming") != "PASS_SRAM_ONLY"
                or record.get("uart_validation") != "PASS_EXACT_BYTES"
                or record.get("jtag_detected_idcode", "").lower() != "0x1281b"
                or record.get("uart_capture") != expected_uart
                or record.get("uart_bytes") != len(expected_uart_path.read_bytes())
                or record.get("bitstream_sha256", "").lower() != bitstream_sha
                or record.get("expected_uart_sha256") != sha(expected_uart_path)):
            return {"status": "FAIL", "reason": f"board load record {name} lacks exact UART/JTAG/SRAM evidence"}
    return {"status": "PASS", "independent_sram_loads": len(record_paths),
            "bitstream_sha256": bitstream_sha, "uart_bytes_per_load": len(expected_uart_path.read_bytes()),
            "records": sorted(record.name for record in record_paths)}


def evaluate_gates(candidate: Path, expected_freeze_sha: str,
                   board_name: str | None = None, summary_name: str | None = None,
                   route_name: str | None = None, min_delay_name: str | None = None) -> dict[str, Any]:
    checks: dict[str, Any] = {}
    try:
        frozen = candidate_freeze(candidate, expected_freeze_sha)
        checks["candidate_freeze"] = frozen
    except Exception as error:
        checks["candidate_freeze"] = {"status": "FAIL", "reason": str(error)}
    freeze_sha = checks["candidate_freeze"].get("freeze_manifest_sha256", expected_freeze_sha.lower())
    paths = locate_release_paths(candidate, board_name, summary_name, route_name, min_delay_name)

    summary: dict[str, Any] | None = None
    if paths["summary"] is not None:
        try:
            summary = read_json(paths["summary"])
        except (OSError, ValueError, json.JSONDecodeError) as error:
            checks["route_summary"] = {"status": "FAIL", "reason": f"invalid route summary: {error}"}
    else:
        checks["route_summary"] = {"status": "FAIL", "reason": "route build summary is missing"}

    if summary is not None:
        fmax = numeric_list(summary.get("fmax_mhz"))
        lut, dsp = resource_counts(summary)
        gates = summary.get("gates", {})
        route_build = route_build_gate(summary)
        route_build.update(sha256=sha(paths["summary"]), name=paths["summary"].name)
        checks["route_summary"] = route_build
        checks["setup_50mhz_all_fmax"] = {
            "status": "PASS" if fmax is not None and all(value >= 50 for value in fmax) else "FAIL",
            "fmax_mhz": fmax,
            "reason": None if fmax is not None and all(value >= 50 for value in fmax)
            else "every reported Fmax entry must be present and at least 50 MHz",
        }
        checks["resource_limits"] = {
            "status": "PASS" if lut is not None and dsp is not None and lut <= 15000 and dsp <= 4 else "FAIL",
            "lut_class_cells": lut, "dsp_class_cells": dsp,
            "limits": {"lut_class_cells_max": 15000, "dsp_class_cells_max": 4},
            "reason": None if lut is not None and dsp is not None and lut <= 15000 and dsp <= 4
            else "resource counts are missing or exceed device limits",
        }
        router_hold = gates.get("hold") if isinstance(gates, dict) else None
        checks["router_hold_status"] = {
            "status": "PASS" if router_hold is True else "FAIL",
            "router_reported_hold": router_hold,
            "hold_slacks_ns_reported_by_router": summary.get("hold_slacks_ns"),
            "hold_violation_lines": summary.get("hold_violation_lines"),
            "reason": None if router_hold is True else "router hold gate is not explicitly true",
        }
    else:
        for name, reason in (("setup_50mhz_all_fmax", "route Fmax evidence unavailable"),
                             ("resource_limits", "route resource evidence unavailable"),
                             ("router_hold_status", "router hold evidence unavailable")):
            checks[name] = {"status": "FAIL", "reason": reason}

    route: dict[str, Any] | None = None
    if paths["route"] is not None:
        try:
            route = read_json(paths["route"])
        except (OSError, ValueError, json.JSONDecodeError) as error:
            checks["corrected_timing_library"] = {"status": "FAIL", "reason": f"invalid route status: {error}"}
    if route is not None:
        expected_route_candidate = {str(candidate), candidate.name}
        route_link = route.get("artifacts", {}).get("summary") if isinstance(route.get("artifacts"), dict) else None
        route_ok = (route.get("status") == "PASS"
                    and route.get("candidate") in expected_route_candidate
                    and paths["summary"] is not None
                    and route_link == paths["summary"].name)
        checks["route_status"] = {"status": "PASS" if route_ok else "FAIL",
                                  "reported_status": route.get("status"),
                                  "summary_link": route_link,
                                  "reason": None if route_ok else "route status must be PASS and point to this candidate's packed build summary"}
    else:
        checks["route_status"] = {"status": "FAIL", "reason": "matching route-status record is missing"}
    checks.setdefault("corrected_timing_library", corrected_library_gate(candidate, route))
    checks["explicit_min_delay_proof"] = explicit_min_delay_gate(
        paths["min_delay"], candidate, freeze_sha, paths["summary"])
    expected_uart_path = candidate / "expected_uart.txt"
    checks["three_independent_sram_board_loads"] = board_load_gate(
        candidate, paths["board"], paths["summary"], expected_uart_path)

    passed = all(value.get("status") == "PASS" for value in checks.values())
    return {"status": "PASS" if passed else "BLOCKED", "checks": checks,
            "evidence_paths": {key: value.name if value else None for key, value in paths.items()},
            "production_rtl_written": False}


def production_source_map(candidate: Path) -> dict[str, dict[str, str]]:
    rows = {}
    for name in OTHER_SOURCES:
        candidate_path = candidate / "rtl" / name
        production_path = PRODUCTION / name
        if not candidate_path.is_file() or not production_path.is_file():
            raise RuntimeError(f"candidate/production source missing: {name}")
        candidate_sha = sha(candidate_path)
        production_sha = sha(production_path)
        if candidate_sha != production_sha:
            raise RuntimeError(f"candidate dependency is not byte-identical to production: {name}")
        rows[name] = {"candidate_sha256": candidate_sha, "production_sha256": production_sha}
    area = candidate / AREA_CANDIDATE
    if not area.is_file():
        raise RuntimeError(f"candidate area module is missing: {AREA_CANDIDATE}")
    area_text = area.read_text(encoding="utf-8")
    if not re.search(r"\bmodule\s+img_geo_area_resample\b", area_text):
        raise RuntimeError("candidate serial file does not declare img_geo_area_resample")
    rows[AREA_PRODUCTION_NAME] = {"candidate_sha256": sha(area), "production_sha256": sha(PRODUCTION_AREA)}
    return rows


def load_device_flow():
    flow_dir = ROOT / "cores/signal_processing/dsp_isp_library/board/tang25k"
    if str(flow_dir) not in sys.path:
        sys.path.insert(0, str(flow_dir))
    import device_flow
    return device_flow


def run_command(command: list[str], cwd: Path, env: dict[str, str], timeout: int,
                log_path: Path) -> dict[str, Any]:
    proc = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                          text=True, encoding="utf-8", errors="replace", timeout=timeout)
    output = proc.stdout + proc.stderr
    log_path.write_text(output, encoding="utf-8")
    record = {"command": command, "cwd": str(cwd), "timeout_seconds": timeout,
              "returncode": proc.returncode,
              "log_sha256": sha_bytes(output.encode("utf-8")), "log": output}
    if proc.returncode != 0:
        raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(command)}\n{output[-10000:]}")
    return record


def compile_and_run(device_flow: Any, stage: Path, name: str, top: str,
                    testbench: str, parameters: tuple[str, ...] = (),
                    required_markers: tuple[str, ...] = ()) -> dict[str, Any]:
    image = stage / f"{name}.vvp"
    sources = [stage / name for name in TEST_SOURCE_NAMES]
    top_file = stage / "image_resample_frame_selftest_25k.v"
    tb = stage / testbench
    command = [device_flow.resolve("iverilog"), "-g2012", f"-I{stage}", "-s", top]
    command.extend(parameters)
    command.extend(["-o", str(image), *map(str, sources)])
    if top_file.name == testbench:
        command.append(str(top_file))
    if top != "img_area_unsigned_divider" and testbench in ("tb_image_resample_frame_selftest_25k.sv",
                                                            "tb_image_resample_por.sv"):
        command.append(str(top_file))
    command.append(str(tb))
    compile_result = run_command(command, stage, device_flow.tool_env(), 180,
                                 stage / f"{name}_compile.log")
    run_result = run_command([device_flow.resolve("vvp"), str(image)], stage,
                             device_flow.tool_env(), 240, stage / f"{name}_run.log")
    output = run_result["log"]
    if any(marker not in output for marker in required_markers):
        raise RuntimeError(f"{name} did not emit all required PASS markers\n{output[-10000:]}")
    return {"name": name, "status": "PASS", "compile": compile_result,
            "simulation": run_result, "pass_markers": list(required_markers)}


def copy_runtime_inputs(candidate: Path, stage: Path) -> None:
    for name in TEST_INPUTS:
        source = candidate / name
        if not source.is_file():
            raise RuntimeError(f"candidate simulation input missing: {name}")
        shutil.copyfile(source, stage / name)


def prepare_eight_sources(candidate: Path, stage: Path, use_production_area: bool) -> list[Path]:
    area_source = PRODUCTION_AREA if use_production_area else candidate / AREA_CANDIDATE
    area_dest = stage / AREA_PRODUCTION_NAME
    shutil.copyfile(area_source, area_dest)
    if sha(area_dest) != sha(area_source):
        raise RuntimeError("area resampler staging hash mismatch")
    sources = [area_dest]
    for name in OTHER_SOURCES:
        production_source = PRODUCTION / name
        candidate_source = candidate / "rtl" / name
        if sha(production_source) != sha(candidate_source):
            raise RuntimeError(f"production dependency changed after preflight: {name}")
        destination = stage / name
        shutil.copyfile(production_source, destination)
        if sha(destination) != sha(production_source):
            raise RuntimeError(f"production dependency staging hash mismatch: {name}")
        sources.append(destination)
    return sources


def run_original_geometry_group(candidate: Path, stage: Path, area_source: Path) -> dict[str, Any]:
    group_root = stage / "original_geometry_group"
    rtl = group_root / "rtl"
    rtl.mkdir(parents=True)
    for source in sorted(PRODUCTION.glob("*.v"), key=lambda item: item.name):
        chosen = area_source if source.name == AREA_PRODUCTION_NAME else source
        shutil.copyfile(chosen, rtl / source.name)
    module_name = "geometry_resample_original_group"
    spec = importlib.util.spec_from_file_location(module_name, GROUP_RUNNER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot import original geometry group runner")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    module.GROUP = group_root
    module.HERE = group_root / "sim"
    module.HERE.mkdir()
    module.ROOT = ROOT
    build = stage / "original_geometry_group_build"
    previous_argv = sys.argv
    output = io.StringIO()
    try:
        sys.argv = [str(GROUP_RUNNER), "--build-dir", str(build)]
        with contextlib.redirect_stdout(output):
            return_code = module.main()
    finally:
        sys.argv = previous_argv
    result_path = build / "result.json"
    if return_code != 0 or not result_path.is_file():
        raise RuntimeError("original geometry group regression did not complete")
    summary = read_json(result_path)
    if not summary.get("passed"):
        raise RuntimeError("original geometry group regression failed")
    command_records = []
    for row in summary.get("commands", []):
        log_path = build / row.get("log", "")
        log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
        command_records.append({"command": row.get("command"), "returncode": row.get("returncode"),
                                "log_sha256": sha_bytes(log.encode("utf-8")), "log": log})
    return {"name": "original_geometry_group", "status": "PASS",
            "cases": summary.get("cases"), "summary_sha256": sha(result_path),
            "commands": command_records, "runner_output": output.getvalue(),
            "runner_output_sha256": sha_bytes(output.getvalue().encode("utf-8"))}


def run_integrated_tests(candidate: Path, source_map: dict[str, dict[str, str]],
                         use_production_area: bool) -> dict[str, Any]:
    device_flow = load_device_flow()
    if not device_flow.resolve("iverilog") or not device_flow.resolve("vvp"):
        raise RuntimeError("Icarus Verilog tools are required for geometry integration")
    results = []
    with tempfile.TemporaryDirectory(prefix="geometry_resample_integration_") as directory:
        stage = Path(directory)
        copy_runtime_inputs(candidate, stage)
        prepare_eight_sources(candidate, stage, use_production_area)
        source_hashes = {name: sha(stage / name) for name in TEST_SOURCE_NAMES}
        bench_hashes = {name: sha(stage / name) for name in TEST_INPUTS}
        divider_markers = PASS_MARKERS["divider"]
        results.append(compile_and_run(device_flow, stage, "divider", "tb_img_area_unsigned_divider",
                                       "tb_img_area_unsigned_divider.v", required_markers=divider_markers))
        results.append(compile_and_run(device_flow, stage, "dst16", "tb_img_area_dst16_contract",
                                       "tb_img_area_dst16_contract.sv", required_markers=PASS_MARKERS["dst16"]))
        results.append(compile_and_run(device_flow, stage, "por", "tb_image_resample_por",
                                       "tb_image_resample_por.sv", required_markers=PASS_MARKERS["por"]))
        results.append(compile_and_run(device_flow, stage, "normal", "tb_image_resample_frame_selftest_25k",
                                       "tb_image_resample_frame_selftest_25k.sv",
                                       parameters=("-Ptb_image_resample_frame_selftest_25k.EXPECT_FAULT=0",),
                                       required_markers=PASS_MARKERS["normal"]))
        results.append(compile_and_run(device_flow, stage, "fault", "tb_image_resample_frame_selftest_25k",
                                       "tb_image_resample_frame_selftest_25k.sv",
                                       parameters=("-Ptb_image_resample_frame_selftest_25k.EXPECT_FAULT=1",),
                                       required_markers=PASS_MARKERS["fault"]))
        group_area = PRODUCTION_AREA if use_production_area else candidate / AREA_CANDIDATE
        results.append(run_original_geometry_group(candidate, stage, group_area))
        if source_hashes != {name: sha(stage / name) for name in TEST_SOURCE_NAMES}:
            raise RuntimeError("staged production RTL changed during testing")
    if Path(directory).exists():
        raise RuntimeError("TemporaryDirectory staging survived integration test exit")
    return {"status": "PASS", "tests": results, "tested_source_sha256": source_hashes,
            "candidate_test_input_sha256": bench_hashes,
            "candidate_dependency_sha256": {name: row["candidate_sha256"] for name, row in source_map.items()},
            "temporary_staging_removed": True}


def atomic_write(path: Path, contents: bytes) -> None:
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
        temporary = Path(name)
        with os.fdopen(fd, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def apply_candidate(candidate: Path, source_map: dict[str, dict[str, str]],
                    expected_freeze_sha: str, watched: dict[str, str]) -> dict[str, Any]:
    original = PRODUCTION_AREA.read_bytes()
    candidate_bytes = (candidate / AREA_CANDIDATE).read_bytes()
    backup_sha = sha_bytes(original)
    # The exact original bytes remain available in memory for rollback; no
    # persistent backup artifact is left in the repository.
    applied = False
    try:
        applied = True
        atomic_write(PRODUCTION_AREA, candidate_bytes)
        tests = run_integrated_tests(candidate, source_map, use_production_area=True)
        assert_unchanged(candidate, watched)
        if candidate_freeze(candidate, expected_freeze_sha).get("status") != "PASS":
            raise RuntimeError("candidate freeze changed during apply test")
        return {"status": "PASS", "production_rtl_written": True,
                "production_path": str(PRODUCTION_AREA), "backup_sha256": backup_sha,
                "installed_sha256": sha(PRODUCTION_AREA), "tests": tests}
    except BaseException:
        if applied:
            atomic_write(PRODUCTION_AREA, original)
            if sha(PRODUCTION_AREA) != backup_sha:
                raise RuntimeError("production area RTL rollback failed; original hash was " + backup_sha)
        raise


def write_report(path: str | None, result: dict[str, Any]) -> None:
    rendered = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    print(rendered, end="")
    if path:
        target = Path(path).expanduser().resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(rendered, encoding="utf-8")


def self_test() -> dict[str, Any]:
    checks = []
    assert numeric_list([50.0, 51]) == [50.0, 51.0]
    assert numeric_list([]) is None
    assert numeric_list([50, "nan"]) is None
    checks.append("all_fmax_values_are_numeric_and_nonempty")
    sample = {"util": {"lut4": 14999, "mult12": 4}}
    assert resource_counts(sample) == (14999, 4)
    assert resource_counts({"util": {"lut4": 15001, "mult12": 0}}) == (15001, 0)
    checks.append("lut_and_dsp_limits_are_independent")
    assert route_build_gate({"status": "ROUTE_PASS_NOT_PACKED", "clk_mhz": 50,
                             "gates": {"route_complete": True, "timing_50mhz": True}})["status"] == "FAIL"
    assert route_build_gate({"status": "BUILD_PASS_NOT_BOARD", "clk_mhz": 50,
                             "gates": {"route_complete": True, "timing_50mhz": True}})["status"] == "PASS"
    checks.append("route_only_summary_cannot_qualify_as_packed_build")
    stage_path: Path | None = None
    with tempfile.TemporaryDirectory(prefix="geometry_resample_runner_selftest_") as directory:
        root = Path(directory)
        stage_path = root
        candidate_root = root / "sample"
        candidate_root.mkdir()
        report = root / "route.json"
        source = candidate_root / "timing_report.txt"
        report.write_text("{}", encoding="utf-8")
        source.write_text("min-delay slack = 0.12 ns", encoding="utf-8")
        proof = candidate_root / "proof.json"
        proof.write_text(json.dumps({
            "schema": "explicit_min_delay_proof_v1", "status": "PASS", "candidate": "sample",
            "freeze_manifest_sha256": "a" * 64, "route_summary_sha256": sha(report),
            "min_delay_slacks_ns": [0.12], "source_report": source.name,
            "source_report_sha256": sha(source),
        }), encoding="utf-8")
        actual = explicit_min_delay_gate(proof, candidate_root, "a" * 64, report)
        assert actual["status"] == "PASS" and actual["minimum_slack_ns"] == 0.12
        proof_data = read_json(proof)
        proof_data["min_delay_slacks_ns"] = [-0.01]
        proof.write_text(json.dumps(proof_data), encoding="utf-8")
        actual = explicit_min_delay_gate(proof, candidate_root, "a" * 64, report)
        assert actual["status"] == "FAIL"
        assert explicit_min_delay_gate(None, candidate_root, "a" * 64, report)["status"] == "FAIL"
    assert stage_path is not None and not stage_path.exists()
    checks.append("explicit_min_delay_proof_is_bound_and_cannot_use_setup_values")
    return {"status": "PASS", "self_test_checks": checks, "temporary_staging_removed": True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-root", help="explicit candidate directory under Tang 25K build/")
    parser.add_argument("--expected-freeze-sha", help="required SHA256 of candidate FREEZE_MANIFEST.json")
    parser.add_argument("--board-summary", help="optional candidate-local board summary filename")
    parser.add_argument("--route-summary", help="optional candidate-local routed build summary filename")
    parser.add_argument("--route-status", help="optional candidate-local corrected route status filename")
    parser.add_argument("--min-delay-proof", help="explicit_min_delay_proof_v1 JSON with freeze/route hashes and a hashed source report")
    parser.add_argument("--preflight-only", action="store_true", help="evaluate immutable release gates without simulation")
    parser.add_argument("--local-only", action="store_true",
                        help="test frozen candidate RTL in temporary staging; release synthesis/route/board gates remain WAITING")
    parser.add_argument("--apply", action="store_true",
                        help="after every gate passes, atomically install the candidate and rollback on any test failure")
    parser.add_argument("--evidence-out", help="optional path for a compact JSON run report; no report file is written by default")
    parser.add_argument("--self-test", action="store_true", help="run lightweight gate/parser self-tests only")
    args = parser.parse_args()

    if args.self_test:
        write_report(args.evidence_out, self_test())
        return 0
    if not args.candidate_root or not args.expected_freeze_sha:
        parser.error("--candidate-root and --expected-freeze-sha are required")
    if args.apply and (args.preflight_only or args.local_only):
        parser.error("--apply cannot be combined with --preflight-only or --local-only")
    candidate = safe_candidate_path(args.candidate_root)
    if args.evidence_out:
        evidence_path = Path(args.evidence_out).expanduser().resolve()
        if evidence_path == candidate or candidate in evidence_path.parents:
            parser.error("--evidence-out must be outside the frozen candidate directory")
    watched = file_watch(candidate, include_release_evidence=not args.local_only)
    if args.local_only:
        frozen = candidate_freeze(candidate, args.expected_freeze_sha)
        source_map = production_source_map(candidate)
        production_before = {name: sha(PRODUCTION / name) for name in TEST_SOURCE_NAMES}
        tests = run_integrated_tests(candidate, source_map, use_production_area=False)
        production_after = {name: sha(PRODUCTION / name) for name in TEST_SOURCE_NAMES}
        if production_after != production_before:
            raise RuntimeError("local-only regression modified production RTL")
        assert_unchanged(candidate, watched)
        result = {
            "schema": "geometry_resample_production_integration_v1",
            "status": "PASS", "candidate": str(candidate), "mode": "local_only",
            "freeze": frozen, "source_map": source_map, "tests": tests,
            "release_gates": {
                "status": "WAITING",
                "checks": {
                    "official_synthesis": "WAITING_FOR_RELEASE_EVIDENCE",
                    "50mhz_setup_and_corrected_route": "WAITING_FOR_PACKED_ROUTE_SUMMARY",
                    "router_hold_status": "WAITING_FOR_PACKED_ROUTE_SUMMARY",
                    "explicit_min_delay_proof": "WAITING_FOR_HASH_BOUND_PROOF",
                    "three_sram_board_loads": "WAITING_FOR_BOARD_RECORDS",
                },
            },
            "production_rtl_written": False,
            "production_rtl_sha256_before_after": production_before,
        }
        write_report(args.evidence_out, result)
        return 0
    gates = evaluate_gates(candidate, args.expected_freeze_sha, args.board_summary,
                           args.route_summary, args.route_status, args.min_delay_proof)
    result: dict[str, Any] = {
        "schema": "geometry_resample_production_integration_v1",
        "candidate": str(candidate), "expected_freeze_manifest_sha256": args.expected_freeze_sha.lower(),
        "mode": "preflight" if args.preflight_only else ("apply" if args.apply else "read_only"),
        "release_gates": gates,
    }
    if gates["status"] != "PASS":
        result.update(status="BLOCKED", production_rtl_written=False,
                      reason="one or more freeze, timing, resource, timing-library, min-delay, or SRAM-load gates did not pass")
        write_report(args.evidence_out, result)
        return 2
    if args.preflight_only:
        result.update(status="PASS", production_rtl_written=False)
        assert_unchanged(candidate, watched)
        write_report(args.evidence_out, result)
        return 0

    source_map = production_source_map(candidate)
    before_area_sha = sha(PRODUCTION_AREA)
    if args.apply:
        applied = apply_candidate(candidate, source_map, args.expected_freeze_sha, watched)
        result.update(status="PASS", source_map=source_map, production_area_sha256_before=before_area_sha,
                      production_update=applied)
    else:
        tests = run_integrated_tests(candidate, source_map, use_production_area=False)
        if sha(PRODUCTION_AREA) != before_area_sha:
            raise RuntimeError("read-only integration modified production area RTL")
        result.update(status="PASS", source_map=source_map, production_area_sha256_before=before_area_sha,
                      tests=tests, production_rtl_written=False)
    assert_unchanged(candidate, watched)
    write_report(args.evidence_out, result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
