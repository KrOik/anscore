#!/usr/bin/env python3
"""Gate and regression-test a frozen geometry candidate against production RTL.

The candidate is always selected explicitly. Test benches, simulator images,
candidate-local mapper/sampler regression outputs, and logs are staged below
this directory and removed automatically. No RTL is copied into or written to
the production source tree by this runner.
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
from datetime import datetime, timezone

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
BUILD_ROOT = ROOT / "cores/system/common_scaffold/board/tang25k/build"
PRODUCTION = ROOT / "cores/system/common_scaffold/image/geometry/rtl"
PRODUCTION_SIM = ROOT / "cores/system/common_scaffold/image/geometry/sim"
SNAPSHOT = HERE / "production_sources_before.json"
SNAPSHOT_DIR = HERE / "production_sources_before"
REFERENCE_MANIFEST = HERE / "v89i_reference_snapshot.json"
REFERENCE_DIR = HERE / "references/v89i_sim"
LEGACY_PRODUCTION_CANDIDATE = ROOT / "cores/system/common_scaffold/board/tang25k/build/image_geometry_frame_selftest_25k_20261017_v89h"
LEGACY_SAMPLER_RUNNER = LEGACY_PRODUCTION_CANDIDATE / "run_sampler_regression.py"
GROUP_RUNNER = PRODUCTION_SIM / "run_geometry_group.py"

FRAME_CHAIN = (
    "img_geo_frame_buffered.v",
    "img_geo_frame_sampler.v",
    "img_geo_frame_transform.v",
    "img_geo_frame_writer.v",
    "img_geo_inverse_map.v",
    "img_geo_raster_coords.v",
)
TOP = "image_geometry_frame_selftest_25k"
CORE_TB = "tb_image_geometry_frame_selftest_25k"
BOARD_TB = "tb_image_geometry_frame_board_wrapper"
MAPPER_TB = "tb_img_geo_inverse_map_divider_equiv"
EXPECTED_BOARD_TESTS = {
    "normal",
    "fault_injection",
    "reset_recovery",
    "divider_equivalence",
    "board_wrapper_por",
    "board_wrapper_fault_injection",
}
UART_PASS_REFERENCE = b"GEO89 PASS D=70A68FFB P=000000B6\r\n"
# Checker injection changes PASS/FAIL only: the original v89c/h frozen stream
# still completes with its normal digest and output count.
UART_FAIL_REFERENCE = b"GEO89 FAIL D=70A68FFB P=000000B6\r\n"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_device_flow():
    flow_dir = ROOT / "cores/signal_processing/dsp_isp_library/board/tang25k"
    if str(flow_dir) not in sys.path:
        sys.path.insert(0, str(flow_dir))
    import device_flow
    return device_flow


def import_script(path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import validation script: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def safe_candidate_path(argument: str) -> Path:
    supplied = Path(argument)
    root = BUILD_ROOT.resolve()
    unresolved = supplied if supplied.is_absolute() else BUILD_ROOT / supplied
    if unresolved.parent.resolve() != root or unresolved.is_symlink():
        raise RuntimeError("--candidate must be a non-symlink direct child of the Tang 25K build directory")
    candidate = unresolved.resolve()
    if candidate.parent != root or not candidate.is_dir():
        raise RuntimeError("--candidate must name an existing direct child of the Tang 25K build directory")
    return candidate


def source_snapshot(candidate: Path, production_state: str) -> dict:
    """Verify old production backups and the caller-selected production state."""
    manifest = read_json(SNAPSHOT)
    if manifest.get("schema") != "production_geometry_source_snapshot_v1":
        raise RuntimeError("preserved production-source snapshot schema is invalid")
    entries = manifest.get("files")
    if not isinstance(entries, dict) or set(entries) != set(FRAME_CHAIN):
        raise RuntimeError("preserved snapshot must cover all six frame-chain RTL files")
    candidate_provenance = read_json(candidate / "production_source_sha256.json")
    baseline_map = candidate_provenance.get("byte_identical_production_rtl")
    if not isinstance(baseline_map, dict) or set(baseline_map) != set(FRAME_CHAIN):
        raise RuntimeError("candidate production-source manifest has an incomplete RTL map")

    before_hashes = {}
    candidate_hashes = {}
    actual_hashes = {}
    for name in FRAME_CHAIN:
        row = entries[name]
        production_path = (ROOT / row["production_path"]).resolve()
        backup_path = (HERE / row["snapshot_path"]).resolve()
        candidate_path = (candidate / "rtl" / name).resolve()
        if (production_path.parent != PRODUCTION.resolve()
                or HERE.resolve() not in backup_path.parents
                or candidate.resolve() not in candidate_path.parents
                or not production_path.is_file() or not backup_path.is_file()
                or not candidate_path.is_file()):
            raise RuntimeError(f"missing or unsafe source/backup path for {name}")
        expected = row.get("sha256")
        backup_sha = sha(backup_path)
        candidate_sha = sha(candidate_path)
        actual_sha = sha(production_path)
        if backup_sha != expected:
            raise RuntimeError(f"preserved pre-candidate bytes changed: {name}")
        if baseline_map.get(name) != expected:
            raise RuntimeError(f"candidate's recorded production baseline differs: {name}")
        before_hashes[name] = expected
        candidate_hashes[name] = candidate_sha
        actual_hashes[name] = actual_sha

    if set(path.name for path in SNAPSHOT_DIR.glob("*.v")) != set(FRAME_CHAIN):
        raise RuntimeError("preserved production RTL backup inventory is incomplete")
    if production_state == "baseline" and actual_hashes != before_hashes:
        changed = [name for name in FRAME_CHAIN if actual_hashes[name] != before_hashes[name]]
        raise RuntimeError("production RTL is not at its preserved baseline: " + ", ".join(changed))
    if production_state == "candidate" and actual_hashes != candidate_hashes:
        changed = [name for name in FRAME_CHAIN if actual_hashes[name] != candidate_hashes[name]]
        raise RuntimeError("production RTL is not byte-identical to the selected candidate: "
                           + ", ".join(changed))

    reference = read_json(REFERENCE_MANIFEST)
    reference_files = reference.get("files", {})
    if not reference_files:
        raise RuntimeError("legacy behavior reference manifest is empty")
    for name, row in reference_files.items():
        staged = (HERE / row["snapshot_path"]).resolve()
        if HERE.resolve() not in staged.parents or not staged.is_file() or sha(staged) != row["sha256"]:
            raise RuntimeError(f"preserved legacy reference changed: {name}")

    group_sources = sorted(PRODUCTION.glob("*.v"), key=lambda path: path.name)
    if not group_sources:
        raise RuntimeError("production geometry RTL directory contains no Verilog sources")
    return {
        "baseline_manifest_sha256": sha(SNAPSHOT),
        "baseline_frame_chain_sha256": before_hashes,
        "candidate_frame_chain_sha256": candidate_hashes,
        "actual_production_frame_chain_sha256": actual_hashes,
        "production_state": production_state,
        "group_rtl_sha256": {path.name: sha(path) for path in group_sources},
        "group_rtl_paths": group_sources,
    }


def candidate_files_to_watch(candidate: Path) -> dict[str, str]:
    freeze_path = candidate / "FREEZE_MANIFEST.json"
    watched = {}
    if freeze_path.is_file():
        manifest = read_json(freeze_path)
        files = manifest.get("files_sha256")
        if isinstance(files, dict) and files:
            watched.update(files)
    else:
        expected = (
            "README.md", "production_source_sha256.json", "simulation_summary.json",
            "image_geometry_frame_selftest_25k.v", "geometry_case_table.vh",
            "rtl/img_geo_frame_buffered.v", "rtl/img_geo_frame_sampler.v",
            "rtl/img_geo_frame_transform.v", "rtl/img_geo_frame_writer.v",
            "rtl/img_geo_inverse_map.v", "rtl/img_geo_raster_coords.v",
            "expected_uart.txt", "expected_uart_fault.txt", "expected_uart.hex",
            "expected_uart_fault.hex", "run_mapper_input_regression.py",
            "run_sampler_regression.py", "sampler_regression_summary.json",
            "sim/tb_img_geo_inverse_map_input_regression.sv",
            "sim/tb_img_geo_frame_sampler_pipeline_contract.sv",
        )
        watched.update({relative: sha(candidate / relative) for relative in expected
                        if (candidate / relative).is_file()})

    # These release records are produced after the source freeze and therefore
    # are intentionally not in its input-file map. Still watch them during
    # this read-only run, along with any linked route and SRAM-load records.
    evidence = {
        "FREEZE_MANIFEST.json", "simulation_summary.json",
        "sampler_regression_summary.json", "build_status.json",
        "board_validation_summary.json", "expected_uart.txt",
        "expected_uart_fault.txt", "production_source_sha256.json",
    }
    for route_status in candidate.glob("route_*_status.json"):
        evidence.add(route_status.name)
    board_path = candidate / "board_validation_summary.json"
    if board_path.is_file():
        board = read_json(board_path)
        build_name = board.get("original_build_summary")
        if isinstance(build_name, str) and Path(build_name).name == build_name:
            evidence.add(build_name)
        for row in board.get("loads", []):
            record_name = row.get("record", "")
            if isinstance(record_name, str) and Path(record_name).name == record_name:
                evidence.add(record_name)
    for relative in evidence:
        path = candidate / relative
        if path.is_file():
            watched[relative] = sha(path)
    return watched


def assert_candidate_unchanged(candidate: Path, before: dict[str, str]) -> None:
    changed = []
    for relative, expected in before.items():
        path = (candidate / relative).resolve()
        if candidate.resolve() not in path.parents or not path.is_file() or sha(path) != expected:
            changed.append(relative)
    if changed:
        raise RuntimeError("candidate bytes changed during read-only integration: "
                           + ", ".join(changed))


def latency_profile_from_cases(cases: list) -> dict:
    labels = {1: "scale", 7: "affine", 8: "perspective"}
    profile: dict[str, dict[str, list[int] | int]] = {}
    for case in cases:
        if not hasattr(case, "mode") or not hasattr(case, "latency"):
            continue
        label = labels.get(case.mode, f"mode_{case.mode}")
        row = profile.setdefault(label, {"mode": int(case.mode), "valid_latencies": set(), "case_count": 0})
        row["case_count"] = int(row["case_count"]) + 1
        expected = getattr(case, "expected", None)
        if expected is not None and len(expected) >= 4 and expected[3] == 0:
            row["valid_latencies"].add(int(case.latency))
    return {name: {"mode": row["mode"], "case_count": row["case_count"],
                   "valid_latencies": sorted(row["valid_latencies"])}
            for name, row in sorted(profile.items())}


def run_candidate_mapper_regression(candidate: Path, stage: Path) -> dict:
    work = stage / "candidate_mapper"
    rtl = work / "rtl/img_geo_inverse_map.v"
    negative = work / "sim/img_geo_inverse_map_negative_control.v"
    bench = work / "sim/tb_img_geo_inverse_map_input_regression.sv"
    script = work / "run_mapper_input_regression.py"
    for relative, destination in (
        ("rtl/img_geo_inverse_map.v", rtl),
        ("sim/img_geo_inverse_map_v89i_negative_control.v", negative),
        ("sim/tb_img_geo_inverse_map_input_regression.sv", bench),
        ("run_mapper_input_regression.py", script),
    ):
        copy_file(candidate / relative, destination)

    module = import_script(script, "selected_geometry_candidate_mapper_regression")
    module.HERE = work
    module.RTL = rtl
    module.V89I_RTL = negative
    module.BENCH = bench
    cases = module.build_cases() if hasattr(module, "build_cases") else None
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = module.main()
    captured = output.getvalue()
    if result not in (0, None):
        raise RuntimeError("selected candidate's own mapper test returned failure:\n" + captured[-12000:])
    case_match = re.search(r"PYTHON INTEGER GOLDEN PASS cases=(\d+)", captured)
    if not case_match:
        raise RuntimeError("candidate mapper runner did not report its integer-golden case count:\n"
                           + captured[-12000:])
    case_count = int(case_match.group(1))
    if cases is not None and case_count != len(cases):
        raise RuntimeError("candidate mapper output count differs from its own generated case list")
    if "NEGATIVE CONTROL CONFIRMED" not in captured:
        raise RuntimeError("candidate mapper runner omitted its negative-control result")
    local_summary = read_json(candidate / "simulation_summary.json") if (candidate / "simulation_summary.json").is_file() else {}
    embedded = local_summary.get("mapper_input_regression", {})
    source_sha = sha(rtl)
    if embedded:
        if (embedded.get("status") != "PASS"
                or embedded.get("source_sha256") != source_sha
                or embedded.get("independent_integer_golden_cases") != case_count):
            raise RuntimeError("candidate simulation summary's mapper evidence is stale")
    return {
        "status": "PASS",
        "candidate_source_sha256": source_sha,
        "candidate_bench_sha256": sha(bench),
        "negative_control_source_sha256": sha(negative),
        "independent_integer_golden_cases": case_count,
        "mode_latency_profile_from_candidate_test": latency_profile_from_cases(cases or []),
        "output_sha256": hashlib.sha256(captured.encode("utf-8")).hexdigest(),
    }


def comparable_rows(rows: list, keys: tuple[str, ...]) -> list[dict]:
    return [{key: row.get(key) for key in keys} for row in rows]


def run_candidate_sampler_regression(candidate: Path, stage: Path) -> dict:
    work = stage / "candidate_sampler"
    rtl = work / "rtl/img_geo_frame_sampler.v"
    baseline = work / "sim/img_geo_frame_sampler_baseline.v"
    bench = work / "sim/tb_img_geo_frame_sampler_pipeline_contract.sv"
    script = work / "run_sampler_regression.py"
    for relative, destination in (
        ("rtl/img_geo_frame_sampler.v", rtl),
        ("sim/img_geo_frame_sampler_baseline.v", baseline),
        ("sim/tb_img_geo_frame_sampler_pipeline_contract.sv", bench),
        ("run_sampler_regression.py", script),
    ):
        copy_file(candidate / relative, destination)

    module = import_script(script, "selected_geometry_candidate_sampler_regression")
    module.HERE = work
    module.ROOT = ROOT
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = module.main()
    captured = output.getvalue()
    summary_path = work / "sampler_regression_summary.json"
    if not isinstance(result, dict) or not summary_path.is_file():
        raise RuntimeError("candidate's sampler test did not produce a temporary summary:\n"
                           + captured[-12000:])
    actual = read_json(summary_path)
    if actual.get("status") != "PASS" or actual.get("source_sha256") != sha(rtl):
        raise RuntimeError("candidate's sampler regression is stale or failed")
    frozen_path = candidate / "sampler_regression_summary.json"
    if frozen_path.is_file():
        frozen = read_json(frozen_path)
        if frozen.get("status") != "PASS" or frozen.get("source_sha256") != sha(candidate / "rtl/img_geo_frame_sampler.v"):
            raise RuntimeError("candidate's stored sampler evidence is stale")
        for key, fields in (
            ("configurations", ("pixel_width", "lanes", "address_width", "cases")),
            ("directed_configurations", ("pixel_width", "lanes", "address_width", "cases")),
            ("direct_old_rtl_contract", ("pixel_width", "lanes", "address_width",
                                           "old_enabled_edges_after_last_response",
                                           "new_enabled_edges_after_last_response", "extra_enabled_edges",
                                           "async_reset_replays")),
        ):
            if comparable_rows(actual.get(key, []), fields) != comparable_rows(frozen.get(key, []), fields):
                raise RuntimeError(f"candidate sampler rerun disagrees with stored suite metadata: {key}")

    configs = actual.get("configurations", [])
    directed = actual.get("directed_configurations", [])
    contracts = actual.get("direct_old_rtl_contract", [])
    if not configs or len(configs) != len(directed) or len(configs) != len(contracts):
        raise RuntimeError("candidate sampler runner omitted one or more parameter configurations")
    if not actual.get("internal_stage_ce_snapshot") or not actual.get("temporary_images_removed"):
        raise RuntimeError("candidate sampler runner omitted CE or temporary-image cleanup evidence")
    return {
        "status": "PASS",
        "source_sha256": actual["source_sha256"],
        "configuration_count": len(configs),
        "original_cases_per_configuration": [row.get("cases") for row in configs],
        "directed_configuration_count": len(directed),
        "directed_cases_per_configuration": [row.get("cases") for row in directed],
        "old_rtl_contract_count": len(contracts),
        "output_sha256": hashlib.sha256(captured.encode("utf-8")).hexdigest(),
    }


def run_candidate_local_regressions(candidate: Path, stage: Path) -> dict:
    device_flow = load_device_flow()
    if not device_flow.resolve("iverilog") or not device_flow.resolve("vvp"):
        raise RuntimeError("Icarus Verilog tools are required for candidate-local regressions")
    mapper = run_candidate_mapper_regression(candidate, stage)
    sampler = run_candidate_sampler_regression(candidate, stage)
    return {"status": "PASS", "mapper": mapper, "sampler": sampler}


def verify_candidate_freeze_and_release(candidate: Path) -> dict:
    """Require a complete source freeze, corrected 50 MHz route, and three SRAM loads."""
    required = (
        "FREEZE_MANIFEST.json", "simulation_summary.json", "sampler_regression_summary.json",
        "build_status.json", "board_validation_summary.json", "expected_uart.txt",
        "expected_uart_fault.txt", "production_source_sha256.json",
    )
    missing = [name for name in required if not (candidate / name).is_file()]
    if missing:
        raise RuntimeError("final-candidate release gate is incomplete; missing " + ", ".join(missing))

    freeze_path = candidate / "FREEZE_MANIFEST.json"
    freeze = read_json(freeze_path)
    if freeze.get("candidate") != candidate.name:
        raise RuntimeError("candidate freeze manifest names another candidate")
    files = freeze.get("files_sha256")
    if not isinstance(files, dict) or not files:
        raise RuntimeError("candidate freeze has no file map")
    for relative, expected in files.items():
        path = (candidate / relative).resolve()
        if candidate.resolve() not in path.parents or not path.is_file() or sha(path) != expected:
            raise RuntimeError(f"candidate frozen input changed, escaped, or is missing: {relative}")
    aggregate = hashlib.sha256(
        "\n".join(f"{name}  {files[name]}" for name in sorted(files)).encode("utf-8")
    ).hexdigest()
    if aggregate != freeze.get("aggregate_sha256"):
        raise RuntimeError("candidate freeze aggregate SHA256 mismatch")
    freeze_sha = sha(freeze_path)

    simulation = read_json(candidate / "simulation_summary.json")
    if simulation.get("status") != "PASS" or simulation.get("candidate") != candidate.name:
        raise RuntimeError("candidate functional simulation is not a PASS for this candidate")
    if freeze.get("simulation", {}).get("summary_sha256") not in (None, sha(candidate / "simulation_summary.json")):
        raise RuntimeError("candidate freeze points to another simulation summary")
    tests = simulation.get("tests", [])
    if {row.get("test") for row in tests} != EXPECTED_BOARD_TESTS or any(
        row.get("status") != "PASS" for row in tests
    ):
        raise RuntimeError("candidate's six core/wrapper simulation suites are not all PASS")

    expected_pass = (candidate / "expected_uart.txt").read_bytes()
    expected_fault = (candidate / "expected_uart_fault.txt").read_bytes()
    if expected_pass != UART_PASS_REFERENCE or expected_fault != UART_FAIL_REFERENCE:
        raise RuntimeError("candidate changed one of the original 34-byte UART contracts")
    digest_match = re.search(rb"\bD=([0-9A-Fa-f]{8})\b", expected_pass)
    if not digest_match or simulation.get("expected_digest", "").upper() != digest_match.group(1).decode().upper():
        raise RuntimeError("candidate simulation digest does not match its frozen UART fixture")

    mapper = simulation.get("mapper_input_regression", {})
    if (mapper.get("status") != "PASS"
            or mapper.get("source_sha256") != sha(candidate / "rtl/img_geo_inverse_map.v")):
        raise RuntimeError("candidate simulation mapper evidence is missing or stale")
    sampler = read_json(candidate / "sampler_regression_summary.json")
    if (sampler.get("status") != "PASS"
            or sampler.get("source_sha256") != sha(candidate / "rtl/img_geo_frame_sampler.v")):
        raise RuntimeError("candidate sampler evidence is missing or stale")

    # Official synthesis and source-to-freeze provenance.
    build_status = read_json(candidate / "build_status.json")
    if build_status.get("status") != "PASS" or build_status.get("synthesis") != "PASS":
        raise RuntimeError("candidate official synthesis did not pass")
    if build_status.get("freeze_manifest_sha256") not in (None, freeze_sha):
        raise RuntimeError("candidate synthesis status points to a different source freeze")

    board = read_json(candidate / "board_validation_summary.json")
    if board.get("candidate") != candidate.name or board.get("status") != "PASS":
        raise RuntimeError("candidate three-load board summary is not a PASS")
    if (board.get("programming") != "SRAM_ONLY"
            or board.get("independent_sram_loads") != 3
            or len(board.get("loads", [])) != 3
            or board.get("functional_clk_mhz") != 50
            or board.get("uart_bytes_per_load") != len(expected_pass)
            or board.get("expected_uart") != expected_pass.decode("ascii")):
        raise RuntimeError("three independent SRAM loads or exact board UART contract are incomplete")

    build_name = board.get("original_build_summary")
    if not isinstance(build_name, str) or Path(build_name).name != build_name:
        raise RuntimeError("board evidence does not identify a safe routed-build report")
    route_summary_path = candidate / build_name
    if not route_summary_path.is_file():
        raise RuntimeError("board evidence's routed-build summary is missing")
    route_summary = read_json(route_summary_path)
    gates = route_summary.get("gates", {})
    fmax = route_summary.get("fmax_mhz", [])
    util = route_summary.get("util", {})
    lut_count = route_summary.get("lut_class_cells", util.get("lut4"))
    dsp_count = route_summary.get("dsp_class_cells", util.get("mult12"))
    if (route_summary.get("status") != "BUILD_PASS_NOT_BOARD"
            or route_summary.get("clk_mhz") != 50
            or not gates or not all(gates.values())
            or gates.get("timing_50mhz") is not True
            or gates.get("hold") is not True
            or not fmax or min(fmax) < 50
            or lut_count is None or int(lut_count) > 15000
            or dsp_count is None or int(dsp_count) > 4):
        raise RuntimeError("corrected route resource/setup/hold gates must pass at 50 MHz within budget")

    route_status_matches = []
    for path in candidate.glob("route_*_status.json"):
        route_status = read_json(path)
        if route_status.get("artifacts", {}).get("summary") == route_summary_path.name:
            route_status_matches.append((path, route_status))
    if len(route_status_matches) != 1:
        raise RuntimeError("expected exactly one route-status record linked to the board build summary")
    route_status_path, route_status = route_status_matches[0]
    if route_status.get("status") != "PASS" or route_status.get("candidate") not in (
        str(candidate), candidate.name
    ):
        raise RuntimeError("corrected-chipdb route status is not a passing record for this candidate")
    chipdb = route_status.get("chipdb")
    chipdb_sha = route_status.get("chipdb_sha256", "").lower()
    route_command = route_status.get("route_command", [])
    if (not isinstance(chipdb, str) or not chipdb_sha or len(chipdb_sha) != 64
            or "--chipdb" not in route_command
            or route_command[route_command.index("--chipdb") + 1] != chipdb):
        raise RuntimeError("route status does not prove which corrected chipdb was actually used")
    if not any(tag in Path(chipdb).name.lower() for tag in ("patched", "corrected")):
        raise RuntimeError("route status does not identify the corrected timing chipdb")
    chipdb_path = Path(chipdb)
    if not chipdb_path.is_file() or sha(chipdb_path) != chipdb_sha:
        raise RuntimeError("corrected timing chipdb is missing or differs from its recorded SHA256")

    bitstream_name = route_summary.get("bitstream")
    bitstream_sha = route_summary.get("bitstream_sha256", "").lower()
    if (not isinstance(bitstream_name, str) or Path(bitstream_name).name != bitstream_name
            or not bitstream_sha or len(bitstream_sha) != 64):
        raise RuntimeError("routed build summary lacks a safe bitstream filename/hash")
    bitstream = candidate / bitstream_name
    if not bitstream.is_file() or sha(bitstream) != bitstream_sha:
        raise RuntimeError("routed bitstream file does not match its recorded SHA256")
    if board.get("bitstream_sha256", "").lower() != bitstream_sha:
        raise RuntimeError("three-load summary is not bound to the routed bitstream hash")

    load_rows = board.get("loads", [])
    records_seen = set()
    for row in load_rows:
        if row.get("idcode", "").lower() != "0x1281b" or row.get("uart_bytes") != len(expected_pass):
            raise RuntimeError("a Tang 25K SRAM record lacks the expected IDCODE or UART length")
        record_name = row.get("record", "")
        if not isinstance(record_name, str) or Path(record_name).name != record_name:
            raise RuntimeError("board load record path is unsafe")
        record_path = candidate / record_name
        if (record_path in records_seen or not record_path.is_file()
                or sha(record_path) != row.get("sha256")):
            raise RuntimeError("a board load record is missing, duplicated, or hash-mismatched")
        records_seen.add(record_path)
        record = read_json(record_path)
        if (record.get("status") != "PASS"
                or record.get("programming") != "PASS_SRAM_ONLY"
                or record.get("uart_validation") != "PASS_EXACT_BYTES"
                or record.get("jtag_detected_idcode", "").lower() != "0x1281b"
                or record.get("uart_bytes") != len(expected_pass)
                or record.get("uart_capture") != expected_pass.decode("ascii")
                or record.get("expected_uart_sha256") != sha(candidate / "expected_uart.txt")
                or record.get("bitstream_sha256", "").lower() != bitstream_sha):
            raise RuntimeError("a board record lacks exact UART evidence for the same frozen bitstream")
        program_proof = record.get("pre_program_artifact_verification", {})
        freeze_proof = program_proof.get("simulation_freeze", {})
        if freeze_proof and freeze_proof.get("freeze_manifest_sha256") not in (None, freeze_sha):
            raise RuntimeError("a board load record was programmed from a different candidate freeze")

    return {
        "candidate": candidate.name,
        "freeze_manifest_sha256": freeze_sha,
        "freeze_aggregate_sha256": aggregate,
        "expected_digest": simulation["expected_digest"],
        "route_summary": route_summary_path.name,
        "route_status": route_status_path.name,
        "corrected_chipdb_sha256": chipdb_sha,
        "fmax_mhz": fmax,
        "resource_counts": {"lut_class_cells": int(lut_count), "dsp_class_cells": int(dsp_count)},
        "bitstream_sha256": bitstream_sha,
        "independent_sram_loads": len(records_seen),
        "uart_bytes_per_load": len(expected_pass),
    }


def prepare_sampler_sandbox(sandbox: Path, rtl: Path) -> None:
    copy_file(rtl, sandbox / "rtl/img_geo_frame_sampler.v")


def run_sampler_suite(script: Path, rtl: Path, sandbox: Path) -> dict:
    prepare_sampler_sandbox(sandbox, rtl)
    module = import_script(script, "geometry_production_sampler_regression")
    module.HERE = sandbox
    module.ROOT = ROOT
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = module.main()
    summary_path = sandbox / "sampler_regression_summary.json"
    if not isinstance(result, dict) or not summary_path.is_file():
        raise RuntimeError("production sampler regression did not return a summary:\n" + output.getvalue()[-12000:])
    summary = read_json(summary_path)
    if summary.get("status") != "PASS" or summary.get("source_sha256") != sha(rtl):
        raise RuntimeError("production sampler regression is stale or failed")
    return summary


def copy_candidate_runtime_inputs(candidate: Path, temp: Path) -> None:
    files = (
        "image_geometry_frame_selftest_25k.v",
        "geometry_case_table.vh",
        "expected_uart.hex",
        "expected_uart_fault.hex",
        "sim/tb_image_geometry_frame_selftest_25k.sv",
        "sim/tb_image_geometry_frame_board_wrapper.sv",
        "sim/tb_img_geo_inverse_map_divider_equiv.sv",
        "sim/img_geo_inverse_map_v89c_baseline.v",
    )
    for relative in files:
        copy_file(candidate / relative, temp / relative)


def run_command(command: list[str], cwd: Path, env: dict, timeout: int) -> str:
    proc = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                          text=True, encoding="utf-8", errors="replace", timeout=timeout)
    output = proc.stdout + proc.stderr
    if proc.returncode:
        raise RuntimeError(f"command failed rc={proc.returncode}: {' '.join(command)}\n{output[-12000:]}")
    return output


def compile_and_run_board_case(device_flow, temp: Path, production_rtl: list[Path],
                               name: str, inject: int, reset: int,
                               board_wrapper: bool, required: str) -> dict:
    tb = BOARD_TB if board_wrapper else CORE_TB
    bench = (temp / "sim/tb_image_geometry_frame_board_wrapper.sv" if board_wrapper
             else temp / f"sim/{CORE_TB}.sv")
    image = temp / f"{name}.vvp"
    command = [device_flow.resolve("iverilog"), "-g2012", "-I", str(temp),
               "-s", tb, f"-P{tb}.INJECT_FAILURE={inject}"]
    if not board_wrapper:
        command.append(f"-P{tb}.RESET_RECOVERY={reset}")
    command.extend(["-o", str(image), str(temp / f"{TOP}.v"),
                    *map(str, production_rtl), str(bench)])
    output = run_command(command, temp, device_flow.tool_env(), 180)
    output += run_command([device_flow.resolve("vvp"), str(image)],
                          temp, device_flow.tool_env(), 120)
    if required not in output:
        raise RuntimeError(f"{name} did not produce the expected functional record:\n{output[-12000:]}")
    return {"test": name, "status": "PASS", "output": output,
            "output_sha256": hashlib.sha256(output.encode("utf-8")).hexdigest()}


def run_production_mapper_equivalence(device_flow, candidate: Path,
                                      temp: Path, production_rtl: list[Path],
                                      production_state: str) -> dict:
    source_path = candidate / f"sim/{MAPPER_TB}.sv"
    source = source_path.read_text(encoding="utf-8")
    calls = re.findall(r"\btransact\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)\s*;", source)
    if not calls:
        raise RuntimeError("candidate mapper equivalence bench has no timed transactions")
    if production_state == "baseline":
        source = re.sub(
            r"\btransact\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)\s*;",
            lambda match: f"transact({match.group(1)},{match.group(1)});", source,
        )
    pass_line = ("GEO89E PRODUCTION MAPPER PASS "
                 f"transactions={len(calls)} production_state={production_state}")
    source, replacements = re.subn(
        r'\$display\("GEO89E DIVIDER EQUIV PASS[^"\n]*"\);',
        '$display("' + pass_line + '");', source,
    )
    if replacements != 1:
        raise RuntimeError("candidate mapper equivalence bench has no unique final PASS marker")
    bench = temp / "sim/tb_img_geo_inverse_map_production_equiv.sv"
    bench.parent.mkdir(parents=True, exist_ok=True)
    bench.write_text(source, encoding="utf-8")
    image = temp / "production_mapper_equiv.vvp"
    command = [device_flow.resolve("iverilog"), "-g2012", "-s", MAPPER_TB,
               "-o", str(image), str(production_rtl[FRAME_CHAIN.index("img_geo_inverse_map.v")]),
               str(temp / "sim/img_geo_inverse_map_v89c_baseline.v"), str(bench)]
    output = run_command(command, temp, device_flow.tool_env(), 180)
    output += run_command([device_flow.resolve("vvp"), str(image)],
                          temp, device_flow.tool_env(), 90)
    if pass_line not in output:
        raise RuntimeError("production mapper did not match its declared state/latency contract:\n" + output[-12000:])
    return {"test": "production_mapper_equivalence", "status": "PASS",
            "transactions": len(calls), "production_state": production_state,
            "bench_sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
            "output_sha256": hashlib.sha256(output.encode("utf-8")).hexdigest()}


def run_geometry_group(temp: Path, group_sources: list[Path]) -> dict:
    group_root = temp / "original_image_geometry_group"
    rtl_dir = group_root / "rtl"
    rtl_dir.mkdir(parents=True)
    for source in group_sources:
        copy_file(source, rtl_dir / source.name)
    module = import_script(GROUP_RUNNER, "production_geometry_original_group")
    module.GROUP = group_root
    module.HERE = group_root / "sim"
    module.HERE.mkdir(parents=True)
    module.ROOT = ROOT
    build = temp / "original_group_build"
    previous_argv = sys.argv
    output = io.StringIO()
    try:
        sys.argv = [str(GROUP_RUNNER), "--build-dir", str(build)]
        with contextlib.redirect_stdout(output):
            result = module.main()
    finally:
        sys.argv = previous_argv
    summary_path = build / "result.json"
    summary = read_json(summary_path)
    if result != 0 or not summary.get("passed"):
        raise RuntimeError("original production image_geometry group regression failed:\n" + output.getvalue()[-12000:])
    return {"test": "original_image_geometry_group", "status": "PASS",
            "case_count": len(summary.get("cases", [])),
            "summary_sha256": sha(summary_path),
            "output_sha256": hashlib.sha256(output.getvalue().encode("utf-8")).hexdigest()}


def run_production_regressions(candidate: Path, production_state: str,
                               candidate_gate: dict, initial_sources: dict,
                               stage: Path) -> dict:
    device_flow = load_device_flow()
    records = []
    candidate_temp = stage / "candidate_runtime"
    candidate_temp.mkdir()
    copy_candidate_runtime_inputs(candidate, candidate_temp)

    rtl_temp = stage / "production_frame_chain"
    rtl_temp.mkdir()
    production_rtl = []
    for name in FRAME_CHAIN:
        destination = rtl_temp / name
        copy_file(PRODUCTION / name, destination)
        if sha(destination) != initial_sources["actual_production_frame_chain_sha256"][name]:
            raise RuntimeError(f"production RTL changed while staging: {name}")
        production_rtl.append(destination)

    group_temp_sources = []
    for source in initial_sources["group_rtl_paths"]:
        destination = stage / "captured_geometry_rtl" / source.name
        copy_file(source, destination)
        if sha(destination) != initial_sources["group_rtl_sha256"][source.name]:
            raise RuntimeError(f"production group RTL changed while staging: {source.name}")
        group_temp_sources.append(destination)

    # The inherited regression exercises the six original parameter sets on
    # actual production sampler bytes; candidate-specific directed/latency
    # checks already ran from that candidate's own regression module.
    production_sampler_dir = stage / "production_sampler_regression"
    production_sampler = run_sampler_suite(
        LEGACY_SAMPLER_RUNNER,
        rtl_temp / "img_geo_frame_sampler.v",
        production_sampler_dir,
    )
    if (len(production_sampler.get("configurations", [])) != 6
            or any(row.get("cases") != 433 for row in production_sampler["configurations"])):
        raise RuntimeError("production sampler regression omitted one of the original six 433-case sets")
    records.append({"test": "production_sampler_six_configurations", "status": "PASS",
                    "configurations": len(production_sampler["configurations"]),
                    "cases_per_configuration": [row["cases"] for row in production_sampler["configurations"]],
                    "source_sha256": production_sampler["source_sha256"]})

    simulation = read_json(candidate / "simulation_summary.json")
    digest = simulation["expected_digest"].upper()
    pixels = simulation.get("expected_output_pixels")
    uart_bytes = simulation.get("uart_bytes")
    quiet_bits = simulation.get("uart_quiet_bits")
    core_cases = (
        ("production_normal", 0, 0),
        ("production_fault_injection", 1, 0),
        ("production_reset_recovery", 0, 1),
    )
    for name, inject, reset in core_cases:
        required = (f"GEO89 BOARD SIM PASS injected={inject} reset={reset} bytes={uart_bytes} "
                    f"quiet_bits={quiet_bits} digest={digest.lower()} outputs={pixels}")
        records.append(compile_and_run_board_case(
            device_flow, candidate_temp, production_rtl, name, inject, reset,
            board_wrapper=False, required=required,
        ))
    for name, inject in (("production_board_wrapper_por", 0),
                         ("production_board_wrapper_fault_injection", 1)):
        required = (f"GEO89 WRAPPER POR PASS injected={inject} bytes={uart_bytes} "
                    f"quiet_bits={quiet_bits} auto_por=1")
        records.append(compile_and_run_board_case(
            device_flow, candidate_temp, production_rtl, name, inject, 0,
            board_wrapper=True, required=required,
        ))
    records.append(run_production_mapper_equivalence(
        device_flow, candidate, candidate_temp, production_rtl, production_state))
    records.append(run_geometry_group(stage, group_temp_sources))

    for name, before in initial_sources["group_rtl_sha256"].items():
        if sha(PRODUCTION / name) != before:
            raise RuntimeError(f"production geometry RTL changed during regression: {name}")
    for name, before in initial_sources["actual_production_frame_chain_sha256"].items():
        if sha(PRODUCTION / name) != before:
            raise RuntimeError(f"production frame-chain RTL changed during regression: {name}")
    return {"status": "PASS", "tests": records, "production_rtl_written": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True,
                        help="candidate directory name or absolute path under Tang 25K build/")
    parser.add_argument("--production-state", choices=("baseline", "candidate"), default="baseline",
                        help="require production to match the preserved bytes (default) or selected candidate")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--preflight-only", action="store_true",
                      help="check source and full release gates without running RTL regressions")
    mode.add_argument("--local-regressions-only", action="store_true",
                      help="run only the selected candidate's own mapper/sampler tests in staging")
    args = parser.parse_args()
    candidate = safe_candidate_path(args.candidate)
    initial_sources = source_snapshot(candidate, args.production_state)
    watched = candidate_files_to_watch(candidate)

    if args.preflight_only:
        release = verify_candidate_freeze_and_release(candidate)
        print(json.dumps({"status": "PASS", "candidate": candidate.name,
                          "production_state": args.production_state,
                          "source_snapshot": {key: value for key, value in initial_sources.items()
                                              if not key.endswith("_paths")},
                          "release_gate": release}, indent=2))
        return 0

    if args.local_regressions_only:
        staging = None
        with tempfile.TemporaryDirectory(prefix="candidate_local_geometry_", dir=str(HERE)) as directory:
            staging = Path(directory)
            local = run_candidate_local_regressions(candidate, staging)
        if staging is None or staging.exists():
            raise RuntimeError("candidate-local test staging was not automatically removed")
        assert_candidate_unchanged(candidate, watched)
        print(json.dumps({"status": "PASS", "candidate": candidate.name,
                          "local_regressions": local, "temporary_staging_removed": True,
                          "production_rtl_written": False}, indent=2))
        return 0

    # Run the selected candidate's own tests first, in isolated copies. This
    # proves the explicit candidate argument controls the actual mapper and
    # sampler code under test before any release or production integration gate.
    local = None
    release = None
    run_result = None
    staging = None
    with tempfile.TemporaryDirectory(prefix="final_geometry_candidate_", dir=str(HERE)) as directory:
        staging = Path(directory)
        local = run_candidate_local_regressions(candidate, staging)
        assert_candidate_unchanged(candidate, watched)
        release = verify_candidate_freeze_and_release(candidate)
        run_result = run_production_regressions(
            candidate, args.production_state, release, initial_sources, staging)
    if staging is None or staging.exists():
        raise RuntimeError("production geometry integration staging was not automatically removed")
    assert_candidate_unchanged(candidate, watched)
    after = source_snapshot(candidate, args.production_state)
    if (after["actual_production_frame_chain_sha256"] != initial_sources["actual_production_frame_chain_sha256"]
            or after["group_rtl_sha256"] != initial_sources["group_rtl_sha256"]):
        raise RuntimeError("production RTL changed during the read-only candidate integration")

    result = {
        "schema": "final_geometry_candidate_production_integration_v1",
        "status": "PASS",
        "candidate": candidate.name,
        "production_state": args.production_state,
        "completed_utc": datetime.now(timezone.utc).isoformat(),
        "candidate_local_regressions": local,
        "candidate_release_gate": release,
        "production_regressions": run_result,
        "production_frame_chain_sha256": after["actual_production_frame_chain_sha256"],
        "production_group_rtl_sha256": after["group_rtl_sha256"],
        "temporary_staging": "EXCLUSIVE_RUNNER_DIRECTORY_AUTO_REMOVED",
        "temporary_staging_removed": True,
        "synthesis": "VERIFIED_FROM_CANDIDATE_EVIDENCE_ONLY",
        "pnr": "VERIFIED_FROM_CANDIDATE_EVIDENCE_ONLY",
        "board_programming": "NOT_RUN_BY_THIS_RUNNER",
        "production_rtl_written": False,
    }
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    result_path = HERE / f"final_geometry_candidate_result_{candidate.name}_{stamp}.json"
    if result_path.exists():
        raise RuntimeError(f"refusing to overwrite existing integration result: {result_path.name}")
    result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "PASS", "candidate": candidate.name,
                      "production_state": args.production_state,
                      "result": result_path.name,
                      "local_mapper_cases": local["mapper"]["independent_integer_golden_cases"],
                      "sampler_configurations": local["sampler"]["configuration_count"],
                      "production_tests": len(run_result["tests"]),
                      "temporary_staging_removed": True,
                      "production_rtl_written": False}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"status": "FAIL", "error": str(error)}, indent=2), file=sys.stderr)
        raise SystemExit(1)
