#!/usr/bin/env python3
"""Qualified, isolated Yosys synthesis wrapper for frozen v103 OP inputs.

The frozen build_op_synthesis.py is intentionally left unchanged. This wrapper
copies only the verified OP input into an OP-local TemporaryDirectory, uses the
Gowin -noabc9 synthesis path, streams the complete log, then applies explicit
structural, warning, and resource gates. It does not run PNR or program a board.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Iterable

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
sys.path.insert(0, str(ROOT / "cores/signal_processing/dsp_isp_library/board/tang25k"))
DEFAULT_CANDIDATE = ROOT / (
    "cores/system/common_scaffold/board/tang25k/build/"
    "image_filter_frame_selftest_25k_20261017_v103_nlm_morph"
)
CANDIDATE = DEFAULT_CANDIDATE
EXPECTED_FREEZE = "a18e341165205f1a87332bd99e0a6f496b8dd210ae8d4f1123c3c2296e34bb5a"
TOP = "image_filter_frame_board_selftest_25k"
PRIMITIVE_LIB_DIR = ROOT / "tools/oss-cad-suite/oss-cad-suite/share/yosys/gowin"
OSS_CAD_ROOT = ROOT / "tools/oss-cad-suite/oss-cad-suite"
PRIMITIVE_LIBRARY_SHA256 = {
    "cells_sim.v": "690eabb95e8af0fae9244401dc8c7c605c7c6048284587a060b8ae89d8634297",
    "cells_xtra_gw5a.v": "f327da1e0bf9503f4af6b6fcd6df3d45f101b41b46fd4b8461c4d7df619db2fa",
}
REAL_NETLIST_FIXTURE = ROOT / (
    "cores/system/common_scaffold/board/tang25k/build/"
    "image_geometry_frame_selftest_25k_20261017_v89j/top25k.json"
)
REAL_NETLIST_TOP = "image_geometry_frame_selftest_25k"
METADATA_CELL_TYPES = {"$scopeinfo"}
FROZEN_RTL_INPUTS = (
    "rtl/img_filter_exp_weight.v",
    "rtl/img_filter_frame_engine.v",
    "image_filter_frame_board_selftest_25k.v",
    "board_input.mem",
)


def frozen_inputs_for_op(op: int) -> tuple[str, ...]:
    # The Verilog frontend evaluates the top's default OP=2 $readmemh before
    # the later chparam commands specialize this build. Stage and hash-bind all
    # three immutable golden images so parsing never depends on the selected OP.
    return (*FROZEN_RTL_INPUTS,
            "board_golden_op0.mem", "board_golden_op1.mem", "board_golden_op2.mem",
            "tang25k.cst")
RESOURCE_LIMITS = {"lut4_class_max": 15000, "mult12_class_max": 4}
# ABC emits this informational warning when its extracted network is
# combinational. It is reviewed only as this exact complete line; every other
# warning remains a hard failure. No -nowarn/global warning suppression is used.
ABC_COMBINATIONAL_WARNING = (
    'ABC: Warning: The network is combinational (run "fraig" or "fraig_sweep").'
)
RESULT_FRAME_SCOREBOARD_WARNING = (
    "Warning: Replacing memory \\result_frame with list of registers. "
    "See image_filter_frame_board_selftest_25k.v:133"
)
WARNING_ALLOWLIST: tuple[tuple[str, str], ...] = (
    (re.escape(ABC_COMBINATIONAL_WARNING),
     "reviewed ABC notice: this network is combinational; exact line only"),
    (re.escape(RESULT_FRAME_SCOREBOARD_WARNING),
     "reviewed frozen 12x8-bit board-test scoreboard; not a production engine frame buffer"),
)


class GateError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def display_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(ROOT.resolve()))
    except ValueError:
        return str(resolved)


def oss_tool_environment(base: dict[str, str] | None = None) -> dict[str, str]:
    """Put the bundled OSS DLL directory ahead of system paths for child tools."""
    env = dict(os.environ if base is None else base)
    existing = env.get("PATH", "")
    env["PATH"] = os.pathsep.join(
        part for part in (str(OSS_CAD_ROOT / "bin"), str(OSS_CAD_ROOT / "lib"), existing)
        if part
    )
    return env


def parse_yosys_int(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        value = value.strip().lower().replace("_", "")
        if value.startswith("0x"):
            return int(value, 16)
        if value and set(value) <= {"0", "1"} and len(value) > 1:
            return int(value, 2)
        return int(value, 10)
    raise ValueError(f"unsupported Yosys integer attribute: {value!r}")


def is_asserted(value: Any) -> bool:
    try:
        return parse_yosys_int(value) != 0
    except (ValueError, TypeError):
        return str(value).strip().lower() in {"true", "yes", "on"}


@lru_cache(maxsize=1)
def official_primitive_types() -> frozenset[str]:
    """Read the exact primitive names from the hash-pinned local Gowin libraries."""
    primitive_types: set[str] = set()
    for filename, expected_hash in PRIMITIVE_LIBRARY_SHA256.items():
        path = PRIMITIVE_LIB_DIR / filename
        if not path.is_file():
            raise GateError(f"official Gowin primitive library is missing: {path}")
        if sha256(path) != expected_hash:
            raise GateError(f"official Gowin primitive library hash mismatch: {filename}")
        text = path.read_text(encoding="utf-8", errors="replace")
        primitive_types.update(re.findall(
            r"(?m)^\s*module\s+(?:\\)?([A-Za-z_$][A-Za-z0-9_$]*)", text
        ))
    if len(primitive_types) != 170:
        raise GateError(f"expected 170 unique Gowin primitive definitions, found {len(primitive_types)}")
    return frozenset(primitive_types)


def is_lut_class(cell_type: str) -> bool:
    return bool(re.fullmatch(r"LUT[1-4]", cell_type.upper()) or cell_type.upper() == "ALU")


def is_dsp_class(cell_type: str) -> bool:
    return cell_type.upper().startswith(("MULT", "PADD", "ALU54", "DSP"))


def inspect_netlist(document: dict[str, Any], expected_top: str = TOP,
                    primitive_types: frozenset[str] | set[str] | None = None) -> dict[str, Any]:
    """Inspect reachable hardware instances, allowing only known Gowin leaf primitives."""
    modules = document.get("modules")
    if not isinstance(modules, dict) or expected_top not in modules:
        raise GateError(f"Yosys JSON has no top module {expected_top}")
    primitive_types = primitive_types if primitive_types is not None else official_primitive_types()
    issues: list[str] = []
    counts: dict[str, int] = {}
    metadata_counts: dict[str, int] = {}
    hardware_instances = 0
    blackbox_definitions = sum(
        1 for module in modules.values()
        if is_asserted(module.get("attributes", {}).get("blackbox", 0))
    )
    for module_name, module in modules.items():
        if (is_asserted(module.get("attributes", {}).get("blackbox", 0))
                and module_name not in primitive_types):
            issues.append(f"unknown blackbox module definition: {module_name}")

    def inspect_module(module_name: str, stack: tuple[str, ...]) -> None:
        nonlocal hardware_instances
        if module_name in stack:
            issues.append("recursive module hierarchy: " + " -> ".join((*stack, module_name)))
            return
        module = modules.get(module_name)
        if module is None:
            issues.append(f"missing module definition: {module_name}")
            return
        if is_asserted(module.get("attributes", {}).get("blackbox", 0)):
            issues.append(f"blackbox module used as design hierarchy: {module_name}")
            return
        ports = module.get("ports", {})
        cells = module.get("cells", {})
        drivers: dict[str, list[str]] = {}
        sinks: dict[str, list[str]] = {}
        module_inputs: set[str] = set()

        def bits_as_ids(bits: Iterable[Any]) -> list[str]:
            return [str(bit) for bit in bits if isinstance(bit, int) and not isinstance(bit, bool)]

        for port_name, port in ports.items():
            ids = bits_as_ids(port.get("bits", []))
            direction = port.get("direction")
            if direction == "input":
                module_inputs.update(ids)
                for bit_id in ids:
                    drivers.setdefault(bit_id, []).append(f"port:{port_name}")
            elif direction == "output":
                for bit_id in ids:
                    sinks.setdefault(bit_id, []).append(f"port:{port_name}")
            elif direction == "inout":
                for bit_id in ids:
                    drivers.setdefault(bit_id, []).append(f"port:{port_name}:inout")
                    sinks.setdefault(bit_id, []).append(f"port:{port_name}:inout")

        for cell_name, cell in cells.items():
            cell_type = str(cell.get("type", ""))
            if not cell_type:
                issues.append(f"{module_name}.{cell_name}: missing cell type")
                continue
            upper = cell_type.upper()
            if cell_type in METADATA_CELL_TYPES:
                metadata_counts[cell_type] = metadata_counts.get(cell_type, 0) + 1
                continue
            if "RAM16" in upper:
                issues.append(f"RAM16-class cell: {module_name}.{cell_name} ({cell_type})")
            if cell_type.startswith("$"):
                issues.append(f"unmapped generic cell: {module_name}.{cell_name} ({cell_type})")
            elif cell_type in primitive_types:
                counts[cell_type] = counts.get(cell_type, 0) + 1
                hardware_instances += 1
            elif cell_type in modules:
                child = modules[cell_type]
                if is_asserted(child.get("attributes", {}).get("blackbox", 0)):
                    issues.append(f"unknown blackbox primitive: {module_name}.{cell_name} ({cell_type})")
                else:
                    inspect_module(cell_type, (*stack, module_name))
            else:
                issues.append(f"unknown cell type: {module_name}.{cell_name} ({cell_type})")

            directions = cell.get("port_directions")
            if not isinstance(directions, dict):
                issues.append(f"{module_name}.{cell_name}: missing port_directions in JSON")
                continue
            connections = cell.get("connections", {})
            for port_name, bits in connections.items():
                direction = directions.get(port_name)
                ids = bits_as_ids(bits)
                if direction in ("output", "inout"):
                    for bit_id in ids:
                        drivers.setdefault(bit_id, []).append(f"cell:{cell_name}.{port_name}")
                if direction in ("input", "inout"):
                    for bit_id in ids:
                        sinks.setdefault(bit_id, []).append(f"cell:{cell_name}.{port_name}")
                if direction not in ("input", "output", "inout"):
                    issues.append(f"{module_name}.{cell_name}.{port_name}: unknown port direction {direction!r}")

        for bit_id, sources in drivers.items():
            if len(sources) > 1:
                issues.append(f"multiple drivers in {module_name} bit {bit_id}: {sources}")
        for bit_id, uses in sinks.items():
            if bit_id not in drivers and bit_id not in module_inputs:
                issues.append(f"undriven net in {module_name} bit {bit_id}, used by {uses}")

    inspect_module(expected_top, ())
    lut_count = sum(count for name, count in counts.items() if is_lut_class(name))
    dsp_count = sum(count for name, count in counts.items() if is_dsp_class(name))
    if lut_count > RESOURCE_LIMITS["lut4_class_max"]:
        issues.append(f"LUT-class resource gate: {lut_count}>{RESOURCE_LIMITS['lut4_class_max']}")
    if dsp_count > RESOURCE_LIMITS["mult12_class_max"]:
        issues.append(f"DSP-class resource gate: {dsp_count}>{RESOURCE_LIMITS['mult12_class_max']}")
    return {"status": "PASS" if not issues else "FAIL", "top": expected_top,
            "primitive_definition_count": len(primitive_types),
            "blackbox_definition_count": blackbox_definitions,
            "hardware_instance_count": hardware_instances,
            "cell_counts": counts, "metadata_counts": metadata_counts,
            "lut4_class_count": lut_count, "dsp_class_count": dsp_count,
            "issues": issues}


def collect_warnings(log_text: str) -> list[str]:
    return [line.strip() for line in log_text.splitlines()
            if re.search(r"warning:", line, re.IGNORECASE)]


def collect_yosys_errors(log_text: str) -> list[str]:
    # Yosys emits frontend failures as both "ERROR: ..." and
    # "source.v:line: ERROR: ...". Search the complete line so the latter
    # cannot be reported as a clean synthesis log.
    return [line.strip() for line in log_text.splitlines()
            if re.search(r"\bERROR\s*:", line, re.IGNORECASE)]


def audit_warnings(log_text: str,
                   allowlist: tuple[tuple[str, str], ...] = WARNING_ALLOWLIST) -> dict[str, Any]:
    warnings = collect_warnings(log_text)
    classified = []
    unreviewed = []
    for warning in warnings:
        match = next(((pattern, reason) for pattern, reason in allowlist
                      if re.fullmatch(pattern, warning)), None)
        if match is None:
            unreviewed.append(warning)
        else:
            classified.append({"warning": warning, "review": match[1]})
    return {"status": "PASS" if not unreviewed else "FAIL",
            "warnings": warnings, "explicitly_reviewed": classified,
            "unreviewed_warnings": unreviewed}


def validate_frozen_op(op: int, candidate_root: Path = CANDIDATE,
                       expected_freeze: str = EXPECTED_FREEZE) -> tuple[Path, dict[str, Any]]:
    op_dir = candidate_root / f"op{op}"
    manifest_path = op_dir / "FREEZE_MANIFEST.json"
    source_manifest_path = op_dir / "SOURCE_FREEZE_MANIFEST.json"
    status_path = op_dir / "build_status.json"
    if (not op_dir.is_dir() or not manifest_path.is_file()
            or not source_manifest_path.is_file() or not status_path.is_file()):
        raise GateError(f"OP{op}: frozen handoff is incomplete")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    status = json.loads(status_path.read_text(encoding="utf-8-sig"))
    if manifest.get("op") != op or manifest.get("parameters", {}).get("OP") != op:
        raise GateError(f"OP{op}: freeze manifest operation mismatch")
    if status.get("op") != op or status.get("simulation") != "PASS":
        raise GateError(f"OP{op}: frozen simulation gate is absent")
    if manifest.get("verification", {}).get("result") != "PASS":
        raise GateError(f"OP{op}: frozen manifest is not PASS")
    if (manifest.get("verification", {}).get("source_freeze_sha256") != expected_freeze
            or status.get("source_candidate_freeze_sha256") != expected_freeze
            or sha256(source_manifest_path) != expected_freeze):
        raise GateError(f"OP{op}: source-freeze SHA256 does not match the explicit candidate freeze")
    for rel in frozen_inputs_for_op(op):
        expected = manifest.get("files_sha256", {}).get(rel)
        path = op_dir / rel
        if not expected or not path.is_file() or sha256(path) != expected:
            raise GateError(f"OP{op}: frozen input missing or changed: {rel}")
    return op_dir, manifest


def make_yosys_script(op: int, json_name: str = "top25k.json",
                      extra_cells: Path | None = None) -> str:
    inputs = " ".join(FROZEN_RTL_INPUTS[:3])
    lines = [f"read_verilog -sv -I. {inputs}"]
    if extra_cells is not None and extra_cells.is_file():
        lines.append("read_verilog -lib " + extra_cells.as_posix())
    for name, value in {"OP": op, "CLK_HZ": 50000000, "BAUD": 115200,
                        "POR_CYCLES": 64, "FAULT_INJECT": 0,
                        "MAX_SEARCH_RADIUS": 3}.items():
        lines.append(f"chparam -set {name} {value} {TOP}")
    lines.extend([
        f"synth_gowin -noalu -noabc9 -family gw5a -top {TOP} -json {json_name}",
        "check -assert",
        "stat",
    ])
    return "\n".join(lines) + "\n"


def run_streamed(command: list[str], cwd: Path, log_path: Path, timeout_s: int,
                 env: dict[str, str] | None = None) -> tuple[int, str]:
    """Stream combined Yosys output to terminal and a complete persistent log."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    chunks: list[str] = []
    with log_path.open("w", encoding="utf-8", newline="\n") as log:
        log.write("$ " + subprocess.list2cmdline(command) + "\n")
        log.flush()
        process = subprocess.Popen(command, cwd=cwd, env=env or oss_tool_environment(), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                                   errors="replace", bufsize=1)
        start = time.monotonic()
        assert process.stdout is not None
        lines: queue.Queue[str | None] = queue.Queue()

        def pump_output() -> None:
            assert process.stdout is not None
            for output_line in process.stdout:
                lines.put(output_line)
            lines.put(None)

        reader = threading.Thread(target=pump_output, name="yosys-log-reader", daemon=True)
        reader.start()
        try:
            finished_output = False
            while not finished_output:
                remaining = timeout_s - (time.monotonic() - start)
                if remaining <= 0:
                    process.kill()
                    raise TimeoutError(f"Yosys exceeded {timeout_s} seconds")
                try:
                    line = lines.get(timeout=min(remaining, 1.0))
                except queue.Empty:
                    if process.poll() is not None and not reader.is_alive():
                        break
                    continue
                if line is None:
                    finished_output = True
                    continue
                chunks.append(line)
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
            code = process.wait(timeout=max(1, timeout_s - int(time.monotonic() - start)))
        except BaseException:
            if process.poll() is None:
                process.kill()
            process.wait()
            raise
        finally:
            reader.join(timeout=5)
    return code, "".join(chunks)


def copy_to_evidence(source: Path, evidence: Path, record: dict[str, Any]) -> None:
    target = evidence / "top25k.json"
    shutil.copy2(source, target)
    record["retained_netlist"] = str(target.relative_to(ROOT))
    record["retained_netlist_sha256"] = sha256(target)
    record["retained_netlist_bytes"] = target.stat().st_size
    record["retention_reason"] = "diagnostic copy after synthesis/gate failure"


def publish_route_handoff(source: Path, op_dir: Path, op: int,
                          record: dict[str, Any]) -> None:
    """Publish the qualified JSON at the official route input path without clobbering."""
    destination = op_dir / "top25k.json"
    checksum_path = op_dir / "top25k.json.sha256"
    handoff_path = op_dir / "qualified_synthesis_handoff.json"
    conflicts = [path.name for path in (destination, checksum_path, handoff_path) if path.exists()]
    if conflicts:
        raise GateError("refusing to overwrite existing route handoff: " + ", ".join(conflicts))
    netlist_hash = sha256(source)
    temporary: list[Path] = []
    published: list[Path] = []
    try:
        with tempfile.NamedTemporaryFile(prefix=".top25k_handoff_", suffix=".tmp",
                                         dir=op_dir, delete=False) as stream:
            staged_netlist = Path(stream.name)
        temporary.append(staged_netlist)
        shutil.copyfile(source, staged_netlist)
        if sha256(staged_netlist) != netlist_hash:
            raise GateError("staged route netlist SHA256 differs from mapped output")
        staged_checksum = op_dir / f".top25k_handoff_{time.time_ns()}.sha256.tmp"
        staged_checksum.write_text(f"{netlist_hash}  top25k.json\n", encoding="ascii", newline="\n")
        temporary.append(staged_checksum)
        handoff = {
            "status": "QUALIFIED_FOR_OFFICIAL_ROUTE",
            "op": op,
            "top25k_json": "top25k.json",
            "top25k_sha256": netlist_hash,
            "top25k_bytes": source.stat().st_size,
            "frozen_manifest_sha256": record["frozen_manifest_sha256"],
            "qualified_synthesis_summary": record["evidence_dir"] + "/summary.json",
            "qualified_synthesis_status": record["status"],
            "warning_gate": record["warning_audit"]["status"],
            "structural_gate": record["structural_gate"]["status"],
        }
        staged_handoff = op_dir / f".top25k_handoff_{time.time_ns()}.json.tmp"
        staged_handoff.write_text(json.dumps(handoff, indent=2) + "\n", encoding="utf-8")
        temporary.append(staged_handoff)
        with destination.open("xb") as output:
            published.append(destination)
            with staged_netlist.open("rb") as mapped:
                shutil.copyfileobj(mapped, output)
        if sha256(destination) != netlist_hash:
            raise GateError("published route netlist SHA256 differs from mapped output")
        with checksum_path.open("x", encoding="ascii", newline="\n") as output:
            published.append(checksum_path)
            output.write(f"{netlist_hash}  top25k.json\n")
        with handoff_path.open("x", encoding="utf-8", newline="\n") as output:
            published.append(handoff_path)
            output.write(json.dumps(handoff, indent=2) + "\n")
    except Exception:
        # Do not leave a partly published route handoff if one of its sidecars fails.
        for path in (*published, *temporary):
            if path.exists():
                path.unlink()
        raise
    for path in temporary:
        if path.exists():
            path.unlink()
    record["retained_netlist"] = str(destination.relative_to(ROOT))
    record["retained_netlist_sha256"] = netlist_hash
    record["retained_netlist_bytes"] = destination.stat().st_size
    record["sha256_handoff"] = str(checksum_path.relative_to(ROOT))
    record["route_handoff"] = str(handoff_path.relative_to(ROOT))


def run_one(op: int, retain_netlist: bool, candidate_root: Path = CANDIDATE,
            expected_freeze: str = EXPECTED_FREEZE) -> dict[str, Any]:
    op_dir, manifest = validate_frozen_op(op, candidate_root, expected_freeze)
    if retain_netlist:
        occupied = [name for name in ("top25k.json", "top25k.json.sha256",
                                      "qualified_synthesis_handoff.json")
                    if (op_dir / name).exists()]
        if occupied:
            raise GateError("refusing to overwrite existing route handoff: " + ", ".join(occupied))
    evidence = HERE / "evidence" / f"qualified_synthesis_op{op}_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')}"
    evidence.mkdir(parents=True, exist_ok=False)
    record: dict[str, Any] = {"op": op, "status": "RUNNING",
                              "frozen_manifest_sha256": sha256(op_dir / "FREEZE_MANIFEST.json"),
                              "inputs": {}, "no_place_and_route": True,
                              "no_board_programming": True}
    try:
        import device_flow
        yosys = Path(device_flow.resolve("yosys"))
        if not yosys.is_file():
            raise GateError(f"Yosys executable not found: {yosys}")
        with tempfile.TemporaryDirectory(prefix=".qualified_synthesis_", dir=op_dir) as temp_raw:
            temp = Path(temp_raw)
            for rel in frozen_inputs_for_op(op):
                source = op_dir / rel
                target = temp / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
                record["inputs"][rel] = sha256(target)
            script = temp / "qualified_synthesis.ys"
            extra_cells = device_flow.cells_xtra_lib()
            script.write_text(make_yosys_script(op, extra_cells=extra_cells),
                              encoding="utf-8", newline="\n")
            shutil.copy2(script, evidence / "qualified_synthesis.ys")
            command = [str(yosys), "-s", script.name]
            record["command"] = command
            record["yosys_mode"] = "synth_gowin -noalu -noabc9 -family gw5a"
            log_temp = temp / "yosys_complete.log"
            try:
                return_code, log_text = run_streamed(
                    command, temp, log_temp, timeout_s=900, env=oss_tool_environment())
            finally:
                if log_temp.is_file():
                    shutil.copy2(log_temp, evidence / "yosys_complete.log")
                    record["complete_log_sha256"] = sha256(evidence / "yosys_complete.log")
            warning_audit = audit_warnings(log_text)
            error_lines = collect_yosys_errors(log_text)
            record["warning_audit"] = warning_audit
            record["yosys_error_lines"] = error_lines
            json_path = temp / "top25k.json"
            json_available = json_path.is_file() and json_path.stat().st_size > 0
            if json_available:
                record["netlist_sha256"] = sha256(json_path)
                record["netlist_bytes"] = json_path.stat().st_size
            if return_code != 0:
                if retain_netlist and json_available:
                    copy_to_evidence(json_path, evidence, record)
                raise GateError(f"Yosys exited with status {return_code}")
            if error_lines:
                if retain_netlist and json_available:
                    copy_to_evidence(json_path, evidence, record)
                raise GateError("Yosys log contains ERROR lines")
            if not json_available:
                raise GateError("Yosys returned success without a nonempty top25k.json")
            try:
                netlist = json.loads(json_path.read_text(encoding="utf-8"))
                structural = inspect_netlist(netlist)
            except Exception:
                if retain_netlist:
                    copy_to_evidence(json_path, evidence, record)
                raise
            record["structural_gate"] = structural
            if warning_audit["status"] != "PASS" or structural["status"] != "PASS":
                if retain_netlist:
                    copy_to_evidence(json_path, evidence, record)
                failures = []
                if warning_audit["status"] != "PASS":
                    failures.append("Yosys emitted unreviewed warnings")
                if structural["status"] != "PASS":
                    failures.append("mapped netlist failed structural/resource gates")
                raise GateError("; ".join(failures))
            if retain_netlist:
                # The qualified output is placed where the official router reads
                # it. Failed gates above keep a diagnostic copy only in evidence.
                record["status"] = "PASS"
                record["evidence_dir"] = display_path(evidence)
                publish_route_handoff(json_path, op_dir, op, record)
            record["status"] = "PASS"
    except Exception as exc:
        record["status"] = "FAIL"
        record["failure"] = f"{type(exc).__name__}: {exc}"
    record["completed_utc"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    record["evidence_dir"] = display_path(evidence)
    (evidence / "summary.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return record


def synthetic_netlist(*, lut_count: int = 1, mult_count: int = 0,
                      ram_type: str | None = None, blackbox: bool = False,
                      multi_driver: bool = False, undriven: bool = False,
                      extra_cells: dict[str, dict[str, Any]] | None = None) -> dict[str, Any]:
    cells: dict[str, Any] = {}
    cells["inverter"] = {"type": "LUT4", "port_directions": {"I": "input", "O": "output"},
                         "connections": {"I": [2], "O": [3]}}
    for index in range(lut_count - 1):
        cells[f"lut{index}"] = {"type": "LUT4", "port_directions": {"I": "input", "O": "output"},
                                "connections": {"I": [3], "O": [4 + index]}}
    for index in range(mult_count):
        cells[f"mult{index}"] = {"type": "MULT12X12", "port_directions": {"A": "input", "B": "input", "DOUT": "output"},
                                 "connections": {"A": [2], "B": [2], "DOUT": [20 + index]}}
    if ram_type:
        cells["memory"] = {"type": ram_type, "port_directions": {"D": "input", "Q": "output"},
                           "connections": {"D": [3], "Q": [30]}}
    if multi_driver:
        cells["driver2"] = {"type": "LUT4", "port_directions": {"I": "input", "O": "output"},
                            "connections": {"I": [2], "O": [3]}}
    if undriven:
        cells["sink"] = {"type": "LUT4", "port_directions": {"I": "input", "O": "output"},
                         "connections": {"I": [99], "O": [100]}}
    cells.update(extra_cells or {})
    module: dict[str, Any] = {
        "ports": {"A": {"direction": "input", "bits": [2]},
                  "Y": {"direction": "output", "bits": [3]}},
        "cells": cells,
    }
    if blackbox:
        module["attributes"] = {"blackbox": "1"}
    return {"modules": {TOP: module}}


def self_test() -> int:
    tests = 0
    primitives = official_primitive_types()

    tool_env = oss_tool_environment({"PATH": "fixture-system-path"})
    expected_prefix = [str(OSS_CAD_ROOT / "bin"), str(OSS_CAD_ROOT / "lib")]
    if tool_env.get("PATH", "").split(os.pathsep) != [*expected_prefix, "fixture-system-path"]:
        raise AssertionError("OSS child-tool PATH does not prepend bundled bin and lib directories")
    print("PASS gate child_tool_path=oss_bin_then_lib_before_system")
    tests += 1

    with tempfile.TemporaryDirectory(prefix=".candidate_root_selftest_", dir=HERE) as temp_raw:
        fixture_root = Path(temp_raw)
        op_dir = fixture_root / "op0"
        op_dir.mkdir()
        listed: dict[str, str] = {}
        for rel in frozen_inputs_for_op(0):
            path = op_dir / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("fixture:" + rel + "\n").encode("ascii"))
            listed[rel] = sha256(path)
        source_manifest = op_dir / "SOURCE_FREEZE_MANIFEST.json"
        source_manifest.write_bytes(b"candidate-root fixture source freeze\n")
        fixture_freeze = sha256(source_manifest)
        (op_dir / "FREEZE_MANIFEST.json").write_text(json.dumps({
            "op": 0, "parameters": {"OP": 0},
            "verification": {"result": "PASS", "source_freeze_sha256": fixture_freeze},
            "files_sha256": listed,
        }), encoding="utf-8")
        (op_dir / "build_status.json").write_text(json.dumps({
            "op": 0, "simulation": "PASS", "source_candidate_freeze_sha256": fixture_freeze,
        }), encoding="utf-8")
        selected, _ = validate_frozen_op(0, fixture_root, fixture_freeze)
        if selected != op_dir:
            raise AssertionError("qualified wrapper ignored its explicit candidate root")
        try:
            validate_frozen_op(0, fixture_root, "0" * 64)
        except GateError:
            pass
        else:
            raise AssertionError("qualified wrapper accepted an incorrect explicit freeze SHA")
    print("PASS gate explicit_candidate_root_and_freeze_sha")
    tests += 1

    error_fixture = (
        "ERROR: direct frontend error\n"
        "image_filter_frame_board_selftest_25k.v:48: ERROR: Can not open file\n"
        "Warning: an error code is mentioned here, not a Yosys error\n"
    )
    expected_errors = [
        "ERROR: direct frontend error",
        "image_filter_frame_board_selftest_25k.v:48: ERROR: Can not open file",
    ]
    if collect_yosys_errors(error_fixture) != expected_errors:
        raise AssertionError("Yosys error collector missed a filename-prefixed frontend error")
    print("PASS gate yosys_errors=direct-and-filename-prefixed")
    tests += 1

    def expect(name: str, document: dict[str, Any], accepted: bool) -> None:
        nonlocal tests
        result = inspect_netlist(document, primitive_types=primitives)
        actual = result["status"] == "PASS"
        if actual != accepted:
            raise AssertionError(f"{name}: expected accepted={accepted}, got {actual}; {result['issues']}")
        print(f"PASS gate {name}={'accept' if accepted else 'reject'}")
        tests += 1

    expect("clean_netlist", synthetic_netlist(), True)
    known_leaf = synthetic_netlist()
    known_leaf["modules"]["LUT4"] = {"attributes": {"blackbox": "1"}, "ports": {}, "cells": {}}
    expect("known_blackbox_primitive_leaf", known_leaf, True)
    expect("scopeinfo_metadata", synthetic_netlist(extra_cells={"scope": {"type": "$scopeinfo"}}), True)
    expect("lut_limit_exact", synthetic_netlist(lut_count=RESOURCE_LIMITS["lut4_class_max"]), True)
    expect("lut_limit_plus_one", synthetic_netlist(lut_count=RESOURCE_LIMITS["lut4_class_max"] + 1), False)
    expect("multiplier_limit_exact", synthetic_netlist(mult_count=RESOURCE_LIMITS["mult12_class_max"]), True)
    expect("multiplier_limit_plus_one", synthetic_netlist(mult_count=RESOURCE_LIMITS["mult12_class_max"] + 1), False)
    expect("ram16", synthetic_netlist(ram_type="RAM16SDP"), False)
    expect("blackbox", synthetic_netlist(blackbox=True), False)
    expect("multiple_driver", synthetic_netlist(multi_driver=True), False)
    expect("undriven_input", synthetic_netlist(undriven=True), False)
    unknown = synthetic_netlist()
    unknown["modules"][TOP]["cells"]["inverter"]["type"] = "MYSTERY_PRIMITIVE"
    expect("unknown_primitive", unknown, False)
    generic = synthetic_netlist()
    generic["modules"][TOP]["cells"]["inverter"]["type"] = "$add"
    expect("unmapped_generic_add", generic, False)

    if not all(is_dsp_class(name) for name in ("MULT12X12", "MULTADDALU12X12", "PADD9", "ALU54", "DSP23")):
        raise AssertionError("one or more DSP primitive families are missing from the DSP resource classifier")
    print("PASS gate dsp_classes=MULT*,PADD*,ALU54*,DSP*")
    tests += 1

    if not REAL_NETLIST_FIXTURE.is_file():
        raise AssertionError(f"real mapped-netlist positive fixture is missing: {REAL_NETLIST_FIXTURE}")
    real_document = json.loads(REAL_NETLIST_FIXTURE.read_text(encoding="utf-8"))
    real_result = inspect_netlist(real_document, REAL_NETLIST_TOP, primitives)
    if real_result["status"] != "PASS":
        raise AssertionError("real Gowin netlist was rejected: " + "; ".join(real_result["issues"][:8]))
    if (real_result["blackbox_definition_count"] != 170
            or real_result["metadata_counts"].get("$scopeinfo", 0) == 0
            or real_result["hardware_instance_count"] != 10894
            or real_result["lut4_class_count"] != 7427
            or real_result["dsp_class_count"] != 0):
        raise AssertionError(f"real Gowin netlist metadata/instance counts look wrong: {real_result}")
    print("PASS gate real_v89j_netlist=" + REAL_NETLIST_TOP
          + f" instances={real_result['hardware_instance_count']}"
          + f" primitive_definitions={real_result['blackbox_definition_count']}"
          + f" LUT4={real_result['lut4_class_count']} DSP={real_result['dsp_class_count']}")
    tests += 1

    exact_warning = ABC_COMBINATIONAL_WARNING
    exact_audit = audit_warnings(exact_warning)
    if (exact_audit["status"] != "PASS"
            or exact_audit["explicitly_reviewed"] != [{
                "warning": exact_warning,
                "review": "reviewed ABC notice: this network is combinational; exact line only",
            }] or collect_warnings(exact_warning) != [exact_warning]):
        raise AssertionError("the reviewed exact ABC combinational warning was not accepted")
    tests += 1

    changed_warning = exact_warning.replace("fraig_sweep", "fraig_sweepx")
    if audit_warnings(changed_warning)["status"] != "FAIL":
        raise AssertionError("warning allowlist accepted a one-word/character alteration")
    tests += 1

    other_abc_warning = "ABC: Warning: Wire foo is used but has no driver."
    other_audit = audit_warnings(other_abc_warning)
    if (other_audit["status"] != "FAIL"
            or other_audit["unreviewed_warnings"] != [other_abc_warning]):
        raise AssertionError("a different ABC warning was not rejected")
    tests += 1

    if audit_warnings(exact_warning + "\n" + other_abc_warning)["status"] != "FAIL":
        raise AssertionError("an unreviewed warning was accepted beside the exception")
    print("PASS gate warnings=exact-ABC-combinational-only altered-and-other-ABC-rejected")
    tests += 1

    scoreboard = RESULT_FRAME_SCOREBOARD_WARNING
    scoreboard_review = "reviewed frozen 12x8-bit board-test scoreboard; not a production engine frame buffer"
    exact_scoreboard = audit_warnings(scoreboard + "\n" + scoreboard)
    if (exact_scoreboard["status"] != "PASS"
            or exact_scoreboard["explicitly_reviewed"] != [
                {"warning": scoreboard, "review": scoreboard_review},
                {"warning": scoreboard, "review": scoreboard_review},
            ]):
        raise AssertionError("the exact repeated board-checker scoreboard warning was not accepted")
    print("PASS gate warnings=exact-frozen-result-frame-scoreboard-repeated-accepted")
    tests += 1

    scoreboard_mutations = {
        "wrong_object": scoreboard.replace("result_frame", "raw"),
        "wrong_source": scoreboard.replace("image_filter_frame_board_selftest_25k.v",
                                             "img_filter_frame_engine.v"),
        "wrong_line": scoreboard.replace(":133", ":134"),
        "one_character_change": scoreboard.replace("registers", "registerx"),
        "production_raw_memory": "Warning: Replacing memory \\raw with list of registers. "
                                "See img_filter_frame_engine.v:133",
    }
    for mutation, warning in scoreboard_mutations.items():
        audit = audit_warnings(warning)
        if audit["status"] != "FAIL" or audit["unreviewed_warnings"] != [warning]:
            raise AssertionError(f"scoreboard warning exception was too broad: {mutation}")
        print(f"PASS gate warnings=scoreboard_{mutation}_rejected")
        tests += 1

    with tempfile.TemporaryDirectory(prefix=".route_handoff_selftest_", dir=HERE) as temp_raw:
        temp = Path(temp_raw)
        op_dir = temp / "op1"
        op_dir.mkdir()
        mapped = temp / "mapped.json"
        mapped.write_bytes(b'{"modules":{"fixture":{"cells":{}}}}\n')
        handoff_record: dict[str, Any] = {
            "frozen_manifest_sha256": "a" * 64,
            "evidence_dir": "host-self-test",
            "status": "PASS",
            "warning_audit": {"status": "PASS"},
            "structural_gate": {"status": "PASS"},
        }
        publish_route_handoff(mapped, op_dir, 1, handoff_record)
        expected_hash = sha256(mapped)
        if (sha256(op_dir / "top25k.json") != expected_hash
                or (op_dir / "top25k.json.sha256").read_text(encoding="ascii")
                != f"{expected_hash}  top25k.json\n"):
            raise AssertionError("qualified route handoff JSON/SHA files do not match")
        try:
            publish_route_handoff(mapped, op_dir, 1, handoff_record)
        except GateError:
            pass
        else:
            raise AssertionError("route handoff overwrote an existing OP artifact")
    print("PASS gate retained_netlist_op_handoff_sha_no_clobber")
    tests += 1
    print(f"QUALIFIED SYNTHESIS HOST GATES PASS tests={tests}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--op", type=int, choices=(0, 1, 2), help="frozen operation to synthesize")
    parser.add_argument("--candidate-root", type=Path,
                        help="candidate directory containing op0/op1/op2; override requires an explicit freeze SHA256")
    parser.add_argument("--expected-freeze-sha256",
                        help="exact SHA256 of each OP SOURCE_FREEZE_MANIFEST.json")
    parser.add_argument("--execute", action="store_true", help="run Yosys; use only in the assigned synthesis slot")
    parser.add_argument("--retain-netlist", action="store_true",
                        help="retain failed netlists in evidence or publish a qualified OP route handoff")
    parser.add_argument("--self-test", action="store_true", help="run host-only positive/negative gate fixtures")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.candidate_root is not None and args.expected_freeze_sha256 is None:
        parser.error("--candidate-root requires --expected-freeze-sha256")
    expected_freeze = args.expected_freeze_sha256 or EXPECTED_FREEZE
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_freeze):
        parser.error("--expected-freeze-sha256 must be exactly 64 hexadecimal characters")
    candidate_root = args.candidate_root or DEFAULT_CANDIDATE
    if not candidate_root.is_absolute():
        candidate_root = ROOT / candidate_root
    candidate_root = candidate_root.resolve()
    if args.op is None:
        parser.error("--op is required unless --self-test is selected")
    try:
        op_dir, manifest = validate_frozen_op(args.op, candidate_root, expected_freeze.lower())
    except GateError as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    plan = {"op": args.op, "candidate_root": display_path(candidate_root),
            "expected_freeze_sha256": expected_freeze.lower(),
            "frozen_input": display_path(op_dir),
            "frozen_manifest_sha256": sha256(op_dir / "FREEZE_MANIFEST.json"),
            "no_apply": True, "execute": args.execute,
            "command_mode": "synth_gowin -noalu -noabc9 -family gw5a",
            "temporary_workspace": "candidate OP directory / TemporaryDirectory; removed on exit",
            "outputs": "timestamped evidence under the qualified wrapper directory",
            "limits": RESOURCE_LIMITS, "manifest_parameters": manifest.get("parameters", {})}
    print(json.dumps(plan, indent=2))
    if not args.execute:
        return 0
    try:
        result = run_one(args.op, args.retain_netlist, candidate_root, expected_freeze.lower())
    except GateError as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
