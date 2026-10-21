#!/usr/bin/env python3
"""Validate the production geometry RTL against frozen v89i release evidence.

This runner never edits production RTL or candidate evidence.  All generated
testbenches, Icarus images, group-regression build files and intermediate logs
live below an auto-removed directory in the OS temporary area.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
from datetime import datetime, timezone

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
PRODUCTION = ROOT / "cores/system/common_scaffold/image/geometry/rtl"
PRODUCTION_SIM = ROOT / "cores/system/common_scaffold/image/geometry/sim"
SNAPSHOT = HERE / "production_sources_before.json"
SNAPSHOT_DIR = HERE / "production_sources_before"
REFERENCE_MANIFEST = HERE / "v89i_reference_snapshot.json"
REFERENCE_DIR = HERE / "references/v89i_sim"
V89I = ROOT / "cores/system/common_scaffold/board/tang25k/build/image_geometry_frame_selftest_25k_20261017_v89i"
V89H = ROOT / "cores/system/common_scaffold/board/tang25k/build/image_geometry_frame_selftest_25k_20261017_v89h"
GROUP_RUNNER = PRODUCTION_SIM / "run_geometry_group.py"
EXPECTED_RTL = (
    "img_geo_frame_buffered.v",
    "img_geo_frame_sampler.v",
    "img_geo_frame_transform.v",
    "img_geo_frame_writer.v",
    "img_geo_inverse_map.v",
    "img_geo_raster_coords.v",
)
EXPECTED_CANDIDATE_TESTS = {
    "normal",
    "fault_injection",
    "reset_recovery",
    "divider_equivalence",
    "board_wrapper_por",
    "board_wrapper_fault_injection",
}
TOP = "image_geometry_frame_selftest_25k"
CORE_TB = "tb_image_geometry_frame_selftest_25k"
BOARD_TB = "tb_image_geometry_frame_board_wrapper"
MAPPER_TB = "tb_img_geo_inverse_map_divider_equiv"


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


def verify_source_snapshot() -> dict:
    manifest = read_json(SNAPSHOT)
    if manifest.get("schema") != "production_geometry_source_snapshot_v1":
        raise RuntimeError("production source snapshot schema is invalid")
    files = manifest.get("files")
    if not isinstance(files, dict) or tuple(sorted(files)) != tuple(sorted(EXPECTED_RTL)):
        raise RuntimeError("production source snapshot must pin the six frame-chain RTL files")
    candidate_sources = read_json(HERE / "v89i_production_source_sha256.json")
    if sha(HERE / "v89i_production_source_sha256.json") != sha(V89I / "production_source_sha256.json"):
        raise RuntimeError("staged v89i production-source manifest differs from its source")
    candidate_map = candidate_sources.get("byte_identical_production_rtl")
    if not isinstance(candidate_map, dict) or set(candidate_map) != set(EXPECTED_RTL):
        raise RuntimeError("copied v89i production-source manifest is malformed")
    actual = {}
    for name in EXPECTED_RTL:
        record = files[name]
        source = ROOT / record["production_path"]
        backup = HERE / record["snapshot_path"]
        expected = record["sha256"]
        if not source.is_file() or not backup.is_file():
            raise RuntimeError(f"production source or before-snapshot is missing: {name}")
        source_sha, backup_sha = sha(source), sha(backup)
        if source_sha != expected or backup_sha != expected:
            raise RuntimeError(f"production source changed from the preserved before-bytes: {name}")
        if candidate_map.get(name) != expected:
            raise RuntimeError(f"v89i production-source manifest differs from before-bytes: {name}")
        actual[name] = source_sha
    if set(path.name for path in SNAPSHOT_DIR.glob("*.v")) != set(EXPECTED_RTL):
        raise RuntimeError("before-snapshot RTL inventory differs from the six declared modules")

    reference = read_json(REFERENCE_MANIFEST)
    if reference.get("schema") != "production_geometry_reference_snapshot_v1" or reference.get("candidate") != V89I.name:
        raise RuntimeError("staged v89i reference snapshot manifest is invalid")
    reference_files = reference.get("files", {})
    if set(reference_files) != {
        "img_geo_inverse_map_v89c_baseline.v",
        "img_geo_frame_sampler_baseline.v",
        "tb_img_geo_frame_sampler_pipeline_contract.sv",
    }:
        raise RuntimeError("staged v89i reference inventory is incomplete")
    for name, row in reference_files.items():
        staged = HERE / row["snapshot_path"]
        candidate = V89I / row["candidate_path"]
        expected = row["sha256"]
        if not staged.is_file() or not candidate.is_file() or sha(staged) != expected or sha(candidate) != expected:
            raise RuntimeError(f"staged/frozen v89i reference changed: {name}")
    for name in ("img_geo_frame_sampler.v", "img_geo_inverse_map.v"):
        if sha(V89H / "rtl" / name) != sha(V89I / "rtl" / name):
            raise RuntimeError(f"v89i {name} differs bytewise from v89h")

    # The geometry-group test compiles every production RTL file, not just the
    # six frame-chain dependencies. Capture their exact input bytes as well.
    group_sources = sorted(PRODUCTION.glob("*.v"), key=lambda path: path.name)
    if not group_sources:
        raise RuntimeError("production geometry RTL directory contains no Verilog sources")
    return {
        "frame_chain_sha256": actual,
        "group_rtl_sha256": {path.name: sha(path) for path in group_sources},
        "group_rtl_paths": group_sources,
    }


def verify_candidate_freeze() -> dict:
    """Require final v89i simulation, freeze, qualified build and three loads."""
    required = (
        "FREEZE_MANIFEST.json",
        "simulation_summary.json",
        "build_status.json",
        "build_corrected_arcs_router1_seed3_v89i_summary.json",
        "build_qualified_scope_summary.json",
        "board_validation_summary.json",
        "sampler_regression_summary.json",
    )
    missing = [name for name in required if not (V89I / name).is_file()]
    if missing:
        raise RuntimeError(
            "v89i final release gate is incomplete; missing " + ", ".join(missing)
        )

    freeze = read_json(V89I / "FREEZE_MANIFEST.json")
    if freeze.get("candidate") != V89I.name:
        raise RuntimeError("v89i freeze manifest names a different candidate")
    frozen = freeze.get("files_sha256")
    if not isinstance(frozen, dict) or not frozen:
        raise RuntimeError("v89i freeze manifest has no file map")
    for relative, expected in frozen.items():
        path = V89I / relative
        if not path.is_file() or sha(path) != expected:
            raise RuntimeError(f"v89i frozen file changed or is missing: {relative}")
    aggregate = hashlib.sha256(
        "\n".join(f"{name}  {frozen[name]}" for name in sorted(frozen)).encode()
    ).hexdigest()
    if freeze.get("aggregate_sha256") != aggregate:
        raise RuntimeError("v89i freeze aggregate SHA256 mismatch")
    freeze_sha = sha(V89I / "FREEZE_MANIFEST.json")

    simulation = read_json(V89I / "simulation_summary.json")
    if simulation.get("status") != "PASS" or simulation.get("candidate") != V89I.name:
        raise RuntimeError("v89i simulation summary is not a final PASS")
    tests = simulation.get("tests", [])
    if {row.get("test") for row in tests} != EXPECTED_CANDIDATE_TESTS or any(
        row.get("status") != "PASS" for row in tests
    ):
        raise RuntimeError("v89i core, board-wrapper, reset or mapper tests are incomplete")
    if simulation.get("expected_digest", "").upper() != "70A68FFB":
        raise RuntimeError("v89i functional digest no longer matches the frozen UART contract")
    embedded_sampler = simulation.get("sampler_regression", {})
    if (embedded_sampler.get("status") != "PASS"
            or len(embedded_sampler.get("directed_configurations", [])) != 6
            or len(embedded_sampler.get("direct_old_rtl_contract", [])) != 6):
        raise RuntimeError("v89i final simulation summary omits the directed sampler evidence")

    sampler = read_json(V89I / "sampler_regression_summary.json")
    candidate_sampler_sha = sha(V89I / "rtl/img_geo_frame_sampler.v")
    if sampler.get("status") != "PASS" or sampler.get("source_sha256") != candidate_sampler_sha:
        raise RuntimeError("v89i sampler summary is absent, stale, or failed")
    if len(sampler.get("configurations", [])) != 6 or any(
        row.get("cases") != 433 for row in sampler["configurations"]
    ):
        raise RuntimeError("v89i original six sampler suites are incomplete")
    directed = sampler.get("directed_configurations", [])
    contracts = sampler.get("direct_old_rtl_contract", [])
    if len(directed) != 6 or any(row.get("cases") != 28 for row in directed):
        raise RuntimeError("v89i directed sampler suite must cover all six configurations")
    if len(contracts) != 6 or any(
        row.get("old_enabled_edges_after_last_response") != 1
        or row.get("new_enabled_edges_after_last_response") != 5
        or row.get("extra_enabled_edges") != 4
        or row.get("async_reset_replays") != 7
        for row in contracts
    ):
        raise RuntimeError("v89i sampler old-RTL latency/reset contract is incomplete")

    build = read_json(V89I / "build_corrected_arcs_router1_seed3_v89i_summary.json")
    if build.get("status") != "BUILD_PASS_NOT_BOARD":
        raise RuntimeError("v89i routed build is not marked BUILD_PASS_NOT_BOARD")
    gates = build.get("gates")
    fmax = build.get("fmax_mhz")
    if not isinstance(gates, dict) or not gates or not all(gates.values()):
        raise RuntimeError("v89i resource/timing/route gates are absent or failed")
    if not isinstance(fmax, list) or not fmax or min(fmax) < 50:
        raise RuntimeError("v89i routed timing does not meet the 50 MHz gate")

    qualified = read_json(V89I / "build_qualified_scope_summary.json")
    if qualified.get("status") != "BUILD_PASS_NOT_BOARD" or not all(
        qualified.get("gates", {}).values()
    ):
        raise RuntimeError("v89i qualified scope summary is not a passing result")
    board = read_json(V89I / "board_validation_summary.json")
    loads = board.get("loads", [])
    if (
        board.get("status") != "PASS"
        or board.get("independent_sram_loads") != 3
        or len(loads) != 3
        or board.get("uart_bytes_per_load") != 34
        or board.get("functional_clk_mhz") != 50
        or board.get("bitstream_sha256") != build.get("bitstream_sha256")
    ):
        raise RuntimeError("v89i three-independent-SRAM-load board qualification is incomplete")
    for load in loads:
        if load.get("idcode", "").lower() != "0x1281b" or load.get("uart_bytes") != 34:
            raise RuntimeError("a v89i board load lacks the expected IDCODE/UART result")
        record = V89I / load.get("record", "")
        if not record.is_file() or sha(record) != load.get("sha256"):
            raise RuntimeError("a v89i board-load record is missing or changed")

    build_status = read_json(V89I / "build_status.json")
    if build_status.get("status") != "PASS" or build_status.get("synthesis") != "PASS":
        raise RuntimeError("v89i official synthesis status is not PASS")
    if build_status.get("freeze_manifest_sha256") not in (None, freeze_sha):
        raise RuntimeError("v89i build status points to a different freeze manifest")
    return {
        "candidate": V89I.name,
        "freeze_manifest_sha256": freeze_sha,
        "freeze_aggregate_sha256": aggregate,
        "simulation_digest": simulation["expected_digest"],
        "board_loads": len(loads),
        "bitstream_sha256": board["bitstream_sha256"],
        "fmax_mhz": fmax,
        "sampler_directed_configurations": len(directed),
    }


def import_script(path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import validation script: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def copy_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def prepare_sampler_sandbox(sandbox: Path, rtl: Path, candidate: bool) -> None:
    copy_file(rtl, sandbox / "rtl/img_geo_frame_sampler.v")
    if candidate:
        copy_file(REFERENCE_DIR / "img_geo_frame_sampler_baseline.v",
                  sandbox / "sim/img_geo_frame_sampler_baseline.v")
        copy_file(REFERENCE_DIR / "tb_img_geo_frame_sampler_pipeline_contract.sv",
                  sandbox / "sim/tb_img_geo_frame_sampler_pipeline_contract.sv")


def run_sampler_suite(script: Path, rtl: Path, sandbox: Path, candidate: bool) -> dict:
    prepare_sampler_sandbox(sandbox, rtl, candidate)
    module = import_script(script, "geometry_sampler_" + ("v89i" if candidate else "production"))
    module.HERE = sandbox
    module.ROOT = ROOT
    result = module.main()
    summary = read_json(sandbox / "sampler_regression_summary.json")
    if not isinstance(result, dict) or summary.get("status") != "PASS":
        raise RuntimeError("sampler regression did not produce a passing summary")
    return summary


def copy_candidate_runtime_inputs(temp: Path) -> None:
    files = (
        "image_geometry_frame_selftest_25k.v",
        "geometry_case_table.vh",
        "expected_uart.hex",
        "expected_uart_fault.hex",
        "sim/tb_image_geometry_frame_selftest_25k.sv",
        "sim/tb_image_geometry_frame_board_wrapper.sv",
        "sim/tb_img_geo_inverse_map_divider_equiv.sv",
    )
    for relative in files:
        copy_file(V89I / relative, temp / relative)
    copy_file(REFERENCE_DIR / "img_geo_inverse_map_v89c_baseline.v",
              temp / "sim/img_geo_inverse_map_v89c_baseline.v")


def run_command(command: list[str], cwd: Path, env: dict, timeout: int) -> str:
    proc = __import__("subprocess").run(
        command, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout
    )
    output = proc.stdout + proc.stderr
    if proc.returncode:
        raise RuntimeError(
            f"command failed rc={proc.returncode}: {' '.join(command)}\n{output[-12000:]}"
        )
    return output


def compile_and_run_board_case(device_flow, temp: Path, production_rtl: list[Path],
                               name: str, inject: int, reset: int, board_wrapper: bool,
                               required: str) -> dict:
    import subprocess

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
                          temp, device_flow.tool_env(), 90)
    if required not in output:
        raise RuntimeError(f"{name} did not produce the expected functional record:\n{output}")
    return {"test": name, "status": "PASS", "output": output,
            "output_sha256": hashlib.sha256(output.encode()).hexdigest()}


def run_mapper_equivalence(device_flow, temp: Path, production_rtl: list[Path]) -> dict:
    import subprocess

    # v89i splits the 116-cycle legacy divide into a 238-cycle candidate path.
    # Here the production mapper is the legacy implementation, so compare it
    # to the frozen old implementation at 116/116 while keeping every vector,
    # backpressure, CE pause and reset-abort check unchanged.
    bench = temp / "sim/tb_img_geo_inverse_map_production_equiv.sv"
    source = (V89I / f"sim/{MAPPER_TB}.sv").read_text(encoding="utf-8")
    if source.count("transact(116,238);") != 7:
        raise RuntimeError("v89i mapper equivalence bench latency anchors changed")
    source = source.replace("transact(116,238);", "transact(116,116);")
    source = source.replace(
        "GEO89E DIVIDER EQUIV PASS transactions=11 old_latency=116 new_latency=238",
        "GEO89E PRODUCTION MAPPER EQUIV PASS transactions=11 old_latency=116 new_latency=116",
    )
    bench.write_text(source, encoding="utf-8")
    image = temp / "production_mapper_equiv.vvp"
    command = [device_flow.resolve("iverilog"), "-g2012", "-s", MAPPER_TB,
               "-o", str(image), str(temp / "rtl/img_geo_inverse_map.v"),
               str(temp / "sim/img_geo_inverse_map_v89c_baseline.v"), str(bench)]
    output = run_command(command, temp, device_flow.tool_env(), 180)
    output += run_command([device_flow.resolve("vvp"), str(image)],
                          temp, device_flow.tool_env(), 60)
    required = ("GEO89E PRODUCTION MAPPER EQUIV PASS transactions=11 "
                "old_latency=116 new_latency=116 reset_abort=1 ce_pause=1 output_hold=1")
    if required not in output:
        raise RuntimeError(f"production old-mapper equivalence failed:\n{output}")
    return {"test": "production_old_mapper_equivalence", "status": "PASS",
            "output": output, "output_sha256": hashlib.sha256(output.encode()).hexdigest(),
            "transactions": 11, "enabled_cycle_latency": 116}


def run_geometry_group(temp: Path, group_sources: list[Path], env: dict) -> dict:
    # Execute the original group regression against the byte-copied production
    # RTL. Patch only its module globals so no build output lands in the repo.
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
    old_argv = sys.argv
    try:
        sys.argv = [str(GROUP_RUNNER), "--build-dir", str(build)]
        result = module.main()
    finally:
        sys.argv = old_argv
    summary_path = build / "result.json"
    summary = read_json(summary_path)
    if result != 0 or not summary.get("passed"):
        raise RuntimeError("original image_geometry group regression failed")
    return {
        "test": "original_image_geometry_group",
        "status": "PASS",
        "cases": len(summary.get("cases", [])),
        "commands": summary.get("commands", []),
        "summary_sha256": sha(summary_path),
    }


def run_all(candidate_gate: dict, initial_sources: dict) -> dict:
    device_flow = load_device_flow()
    import subprocess

    records = []
    with tempfile.TemporaryDirectory(prefix="production_geometry_v89i_") as directory:
        temp = Path(directory)
        candidate_temp = temp / "candidate_v89i"
        candidate_temp.mkdir()
        copy_candidate_runtime_inputs(candidate_temp)

        rtl_temp = temp / "rtl"
        rtl_temp.mkdir()
        production_rtl = []
        for name in EXPECTED_RTL:
            destination = rtl_temp / name
            copy_file(PRODUCTION / name, destination)
            if sha(destination) != initial_sources["frame_chain_sha256"][name]:
                raise RuntimeError(f"temporary production RTL copy hash mismatch: {name}")
            production_rtl.append(destination)

        group_temp_sources = []
        for source in initial_sources["group_rtl_paths"]:
            destination = temp / "captured_geometry_rtl" / source.name
            copy_file(source, destination)
            if sha(destination) != initial_sources["group_rtl_sha256"][source.name]:
                raise RuntimeError(f"temporary group RTL copy hash mismatch: {source.name}")
            group_temp_sources.append(destination)

        # Original v89h six-configuration scalar regression, now pointed at
        # actual production sampler bytes; v89i's additional directed suite is
        # separately rerun below against the frozen v89i sampler.
        production_sampler = run_sampler_suite(
            V89H / "run_sampler_regression.py",
            rtl_temp / "img_geo_frame_sampler.v",
            temp / "production_sampler_suite",
            candidate=False,
        )
        if (len(production_sampler.get("configurations", [])) != 6
                or production_sampler.get("source_sha256")
                != initial_sources["frame_chain_sha256"]["img_geo_frame_sampler.v"]):
            raise RuntimeError("production sampler six-configuration regression is stale or incomplete")
        records.append({"test": "production_sampler_six_configurations", "status": "PASS",
                        "configurations": 6, "cases_per_configuration": 433,
                        "source_sha256": production_sampler["source_sha256"]})

        # Re-run v89i's candidate-only directed sampler checks in OS temp so
        # they never rewrite a frozen candidate summary or leave VVP files.
        candidate_sampler = run_sampler_suite(
            V89I / "run_sampler_regression.py",
            V89I / "rtl/img_geo_frame_sampler.v",
            temp / "v89i_directed_sampler_suite",
            candidate=True,
        )
        if (len(candidate_sampler.get("directed_configurations", [])) != 6
                or len(candidate_sampler.get("direct_old_rtl_contract", [])) != 6):
            raise RuntimeError("v89i directed sampler regression did not cover all six configurations")
        records.append({"test": "v89i_sampler_directed_and_old_rtl_contract", "status": "PASS",
                        "directed_configurations": 6, "old_rtl_contract_configurations": 6,
                        "source_sha256": candidate_sampler["source_sha256"]})

        core_cases = [
            ("production_normal", 0, 0,
             "GEO89 BOARD SIM PASS injected=0 reset=0 bytes=34 quiet_bits=12"),
            ("production_fault_injection", 1, 0,
             "GEO89 BOARD SIM PASS injected=1 reset=0 bytes=34 quiet_bits=12"),
            ("production_reset_recovery", 0, 1,
             "GEO89 BOARD SIM PASS injected=0 reset=1 bytes=34 quiet_bits=12"),
        ]
        for name, inject, reset, expected in core_cases:
            records.append(compile_and_run_board_case(
                device_flow, candidate_temp, production_rtl, name, inject, reset,
                board_wrapper=False, required=expected,
            ))
        for name, inject in (("production_board_wrapper_por", 0),
                             ("production_board_wrapper_fault_injection", 1)):
            expected = (f"GEO89 WRAPPER POR PASS injected={inject} bytes=34 "
                        "quiet_bits=12 auto_por=1")
            records.append(compile_and_run_board_case(
                device_flow, candidate_temp, production_rtl, name, inject, 0,
                board_wrapper=True, required=expected,
            ))
        records.append(run_mapper_equivalence(device_flow, candidate_temp, production_rtl))
        records.append(run_geometry_group(temp, group_temp_sources, device_flow.tool_env()))

        # Prove that no source moved while the actual production-byte tests ran.
        for name, before in initial_sources["group_rtl_sha256"].items():
            if sha(PRODUCTION / name) != before:
                raise RuntimeError(f"production geometry RTL changed during validation: {name}")
        for name, before in initial_sources["frame_chain_sha256"].items():
            if sha(PRODUCTION / name) != before:
                raise RuntimeError(f"production frame-chain RTL changed during validation: {name}")

    return {
        "status": "PASS",
        "candidate_gate": candidate_gate,
        "production_source_snapshot_manifest_sha256": sha(SNAPSHOT),
        "production_frame_chain_sha256": initial_sources["frame_chain_sha256"],
        "group_rtl_sha256": initial_sources["group_rtl_sha256"],
        "tests": records,
        "temporary_directory_removed": True,
        "synthesis": "NOT_RUN",
        "pnr": "NOT_RUN",
        "board_programming": "NOT_RUN",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight-only", action="store_true",
                        help="verify source snapshots and final v89i gates without running simulations")
    args = parser.parse_args()
    initial_sources = verify_source_snapshot()
    candidate_gate = verify_candidate_freeze()
    print(json.dumps({"preflight": "PASS", "candidate_gate": candidate_gate,
                      "production_files": len(initial_sources["frame_chain_sha256"]),
                      "group_rtl_files": len(initial_sources["group_rtl_sha256"])}, indent=2))
    if args.preflight_only:
        return 0
    result = run_all(candidate_gate, initial_sources)
    result["completed_utc"] = datetime.now(timezone.utc).isoformat()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = HERE / f"production_geometry_result_{stamp}.json"
    if out.exists():
        raise RuntimeError(f"refusing to overwrite prior validation evidence: {out.name}")
    out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "summary": out.name,
                      "tests": len(result["tests"]), "temporary_directory_removed": True}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
