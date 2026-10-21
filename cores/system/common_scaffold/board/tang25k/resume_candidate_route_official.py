#!/usr/bin/env python3
"""Retry a simulation-gated Tang25K candidate with the isolated official router.

The candidate's top25k.json and original tang25k.cst are read-only inputs.
Every retry gets its own derived explicit-IO CST, routed JSON, logs, status,
summary, and uncompressed SRAM bitstream. Packing is blocked unless resource,
50 MHz setup, and hold checks all pass.

The pinned official runtime predates the Gowin LUT1/2/3 timing-arc fix
(nextpnr PR #1850). Supply a corrected chipdb; its path and SHA256 are recorded.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any


sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "cores/signal_processing/dsp_isp_library/board/tang25k"))
import device_flow  # noqa: E402  (must use the shared device/GATE definitions)


OFFICIAL_TOOL_ROOT = ROOT / "scratch/nextpnr_official_20261016"
OFFICIAL_RUNTIME = OFFICIAL_TOOL_ROOT / "runtime"
BASELINE_CAD = Path(device_flow.CAD)
EXPECTED_PORTS = {"clk", "uart_rx_pin", "uart_tx", "dbg_uart"}
ATTEMPT_RE = re.compile(r"[A-Za-z0-9_-]{1,48}\Z")


class CandidateError(RuntimeError):
    """Raised when a candidate fails a preflight or implementation gate."""


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def json_read(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CandidateError(f"cannot read JSON {path.name}: {error}") from error
    if not isinstance(value, dict):
        raise CandidateError(f"JSON root must be an object: {path.name}")
    return value


def contained_file(candidate: Path, relative_name: str) -> Path:
    if not isinstance(relative_name, str) or not relative_name:
        raise CandidateError("source manifest contains an empty or non-string path")
    target = (candidate / relative_name).resolve()
    try:
        target.relative_to(candidate)
    except ValueError as error:
        raise CandidateError(f"manifest path escapes candidate directory: {relative_name}") from error
    if not target.is_file():
        raise CandidateError(f"candidate input is missing: {relative_name}")
    return target


def verify_hash_map(candidate: Path, hash_map: Any, label: str) -> dict[str, str]:
    if not isinstance(hash_map, dict) or not hash_map:
        raise CandidateError(f"{label} must be a non-empty filename-to-SHA256 map")
    verified: dict[str, str] = {}
    for name, expected in hash_map.items():
        path = contained_file(candidate, name)
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
            raise CandidateError(f"invalid SHA256 entry in {label}: {name}")
        actual = sha256_file(path)
        if actual.lower() != expected.lower():
            raise CandidateError(f"source changed since simulation/freeze: {name}")
        verified[name] = actual
    return verified


def verify_simulation_gate(candidate: Path) -> dict[str, Any]:
    status_path = candidate / "build_status.json"
    status = json_read(status_path)
    if status.get("simulation") != "PASS":
        raise CandidateError("build_status.json must record simulation=PASS")

    provenance: dict[str, Any] = {
        "build_status": status_path.name,
        "build_status_sha256": sha256_file(status_path),
        "build_status_overall_status": status.get("status"),
        "simulation": "PASS",
    }
    verified_any = False

    source_hashes = status.get("source_sha256")
    if source_hashes is not None:
        provenance["source_sha256_verified"] = verify_hash_map(
            candidate, source_hashes, "build_status source_sha256"
        )
        verified_any = True

    manifest_sha = status.get("freeze_manifest_sha256")
    if manifest_sha is not None:
        if not isinstance(manifest_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", manifest_sha):
            raise CandidateError("build_status freeze_manifest_sha256 is malformed")
        manifest_path = candidate / "FREEZE_MANIFEST.json"
        if not manifest_path.is_file():
            raise CandidateError("build_status references a missing FREEZE_MANIFEST.json")
        actual_manifest_sha = sha256_file(manifest_path)
        if actual_manifest_sha.lower() != manifest_sha.lower():
            raise CandidateError("FREEZE_MANIFEST.json hash differs from build_status.json")
        manifest = json_read(manifest_path)
        verification = manifest.get("verification")
        if not isinstance(verification, dict) or verification.get("result") != "PASS":
            raise CandidateError("freeze manifest does not record verification.result=PASS")
        provenance["freeze_manifest"] = manifest_path.name
        provenance["freeze_manifest_sha256"] = actual_manifest_sha
        provenance["freeze_files_sha256_verified"] = verify_hash_map(
            candidate, manifest.get("files_sha256"), "FREEZE_MANIFEST files_sha256"
        )
        verified_any = True

    if not verified_any:
        raise CandidateError("simulation gate has neither source_sha256 nor a verified freeze manifest")
    return provenance


def derive_explicitio33_cst(original_text: str) -> tuple[str, list[str]]:
    """Add only IO_TYPE=LVCMOS33 to the four existing 3.3 V IO_PORT lines."""
    output: list[str] = []
    seen: list[str] = []
    pattern = re.compile(r'^(?P<prefix>\s*IO_PORT\s+"(?P<port>[^"]+)"\s+)(?P<attrs>[^;]*)(?P<suffix>;.*)$')
    for line in original_text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        ending = line[len(content):]
        match = pattern.match(content)
        if not match:
            output.append(line)
            continue
        port = match.group("port")
        attrs = match.group("attrs")
        if port in seen:
            raise CandidateError(f"duplicate IO_PORT in original CST: {port}")
        if not re.search(r"(?:^|\s)BANK_VCCIO\s*=\s*3\.3(?:\s|$)", attrs, re.IGNORECASE):
            raise CandidateError(f"IO_PORT {port} is not explicitly on a 3.3 V bank")
        if re.search(r"(?:^|\s)IO_TYPE\s*=", attrs, re.IGNORECASE):
            raise CandidateError(f"original CST already has an IO_TYPE on {port}")
        output.append(match.group("prefix") + attrs + " IO_TYPE=LVCMOS33" +
                      match.group("suffix") + ending)
        seen.append(port)

    if set(seen) != EXPECTED_PORTS or len(seen) != 4:
        raise CandidateError(f"expected four 3.3 V board IO_PORTs {sorted(EXPECTED_PORTS)}, got {seen}")
    locations = set(re.findall(r'^\s*IO_LOC\s+"([^"]+)"\s+[^;]+;', original_text, re.MULTILINE))
    if locations != EXPECTED_PORTS:
        raise CandidateError(f"original CST IO_LOC ports do not match board ports: {sorted(locations)}")
    derived = "".join(output)
    # Removing exactly the four inserted tokens must recover the original text.
    if derived.count("IO_TYPE=LVCMOS33") != 4:
        raise CandidateError("derived CST did not add exactly four LVCMOS33 attributes")
    recovered = derived.replace(" IO_TYPE=LVCMOS33", "")
    if recovered != original_text:
        raise CandidateError("derived CST changed content beyond the four IO_TYPE attributes")
    return derived, seen


def route_environment(runtime: Path) -> dict[str, str]:
    env = dict(os.environ)
    old_path = env.get("PATH", "")
    env["PATH"] = os.pathsep.join((
        str(runtime / "bin"), str(runtime / "lib"),
        str(BASELINE_CAD / "bin"), str(BASELINE_CAD / "lib"), old_path,
    ))
    env["PYTHONHOME"] = str(BASELINE_CAD)
    env.pop("PYTHONPATH", None)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONNOUSERSITE"] = "1"
    return env


def pack_environment(runtime: Path) -> dict[str, str]:
    env = dict(os.environ)
    old_path = env.get("PATH", "")
    env["PATH"] = os.pathsep.join((
        str(runtime / "bin"), str(runtime / "lib"),
        str(BASELINE_CAD / "bin"), str(BASELINE_CAD / "lib"), old_path,
    ))
    env.pop("PYTHONHOME", None)
    env["PYTHONPATH"] = str(runtime / "lib/python3.11/site-packages")
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONNOUSERSITE"] = "1"
    return env


def validate_official_runtime() -> tuple[Path, Path, dict[str, Any]]:
    provenance_path = OFFICIAL_TOOL_ROOT / "provenance.json"
    provenance = json_read(provenance_path)
    if provenance.get("status") != "READY":
        raise CandidateError("official isolated tool provenance is not READY")
    declared_runtime = Path(provenance.get("runtime_directory", "")).resolve()
    if declared_runtime != OFFICIAL_RUNTIME.resolve():
        raise CandidateError("runtime path differs from the READY provenance record")

    nextpnr = OFFICIAL_RUNTIME / "bin/nextpnr-himbaechel.exe"
    packer_script = OFFICIAL_RUNTIME / "bin/gowin_pack-script.py"
    apycula_init = OFFICIAL_RUNTIME / "lib/python3.11/site-packages/apycula/__init__.py"
    if not nextpnr.is_file() or not packer_script.is_file() or not apycula_init.is_file():
        raise CandidateError("official runtime is missing nextpnr, packer script, or Apicula")

    python_name = provenance.get("baseline_python311")
    if not isinstance(python_name, str) or not python_name:
        raise CandidateError("official provenance has no baseline_python311")
    pack_python = Path(python_name)
    if not pack_python.is_file():
        raise CandidateError(f"baseline Python 3.11 is unavailable: {pack_python}")
    if not (BASELINE_CAD / "lib/python3.11/encodings/__init__.py").is_file():
        raise CandidateError("baseline CAD Python 3.11 standard library is missing")
    return nextpnr, packer_script, {
        "provenance": str(provenance_path.relative_to(ROOT)).replace("\\", "/"),
        "provenance_sha256": sha256_file(provenance_path),
        "runtime": str(OFFICIAL_RUNTIME),
        "runtime_nextpnr_sha256": sha256_file(nextpnr),
        "runtime_packer_sha256": sha256_file(packer_script),
        "runtime_apycula_init_sha256": sha256_file(apycula_init),
        "baseline_cad": str(BASELINE_CAD),
        "baseline_python311": str(pack_python),
        "pack_apicula_pythonpath": str(OFFICIAL_RUNTIME / "lib/python3.11/site-packages"),
    }


def parse_route_report(log_text: str, returncode: int) -> dict[str, Any]:
    utilization: dict[str, int | None] = {}
    for report_name, key in (("LUT4", "lut4"), ("DFF", "dff"),
                             ("BSRAM", "bsram"), ("MULT12X12", "mult12")):
        matches = re.findall(r"(?m)^Info:\s+%s:\s*(\d+)\s*/\s*\d+" % report_name, log_text)
        utilization[key] = int(matches[-1]) if matches else None

    frequencies = [float(value) for value in re.findall(
        r"Max frequency for clock[^\r\n]*?:\s*([\d.]+)\s*MHz", log_text
    )]
    error_lines = [line.strip() for line in log_text.splitlines()
                   if re.match(r"^\s*ERROR\b", line, re.IGNORECASE)]
    hold_violation_counts: list[int] = []
    hold_violation_lines: list[str] = []
    hold_slacks: list[float] = []
    number = r"([+-]?(?:\d+(?:\.\d*)?|\.\d+))"
    for line in log_text.splitlines():
        count_match = re.search(
            r"\b(\d+)\s+hold(?:/min)?(?:\s+min(?:imum)?)?(?:\s+time)?\s+violations?\b",
            line, re.IGNORECASE,
        ) or re.search(
            r"\bhold(?:/min)?(?:\s+time)?\s+violations?\s*[:=]\s*(\d+)\b",
            line, re.IGNORECASE,
        )
        if count_match:
            count = int(count_match.group(1))
            hold_violation_counts.append(count)
            if count > 0:
                hold_violation_lines.append(line.strip())

        # Do not interpret nextpnr's `hold -0.12 0.46` path fields as slack:
        # the first value is the hold requirement. Accept only explicit labels.
        for slack_pattern in (
            rf"\bhold\s+slack\s*(?:[:=]\s*)?{number}\b",
            rf"\bslack\s*(?:[:=]\s*)?{number}\b.{{0,48}}\bhold\b",
            rf"\bslack\b.{{0,48}}\bhold\b\s*(?:[:=]\s*)?{number}\b",
        ):
            hold_slacks.extend(float(value) for value in re.findall(slack_pattern, line, re.IGNORECASE))

        has_hold_violation = re.search(
            r"hold/min time violation|hold violation|min(?:imum)?\s+hold",
            line, re.IGNORECASE,
        )
        is_zero_summary = count_match and int(count_match.group(1)) == 0
        if has_hold_violation and not is_zero_summary:
            hold_violation_lines.append(line.strip())
    error_summary = [int(value) for value in re.findall(
        r"(?im)^\s*\d+\s+warnings?,\s*(\d+)\s+errors?\s*$", log_text
    )]
    reported_errors = max(error_summary, default=0)
    timing_fail_lines = [line.strip() for line in log_text.splitlines()
                         if re.search(r"(?:FAIL at\s+\d+(?:\.\d+)?\s*MHz|setup time violation|timing violation)",
                                      line, re.IGNORECASE)]
    route_complete = "Program finished normally" in log_text
    timing_pass = bool(frequencies) and min(frequencies) >= float(device_flow.CLK_MHZ) and not timing_fail_lines
    # Setup errors also appear in ERROR/error-count summaries. Keep them in
    # route_process/timing gates; they are not evidence of a hold violation.
    # An empty list proves no min-delay analysis. In particular, the pinned
    # runtime's setup-only presentation must not pass by all([]) == True.
    hold_evidence_complete = bool(hold_slacks) and bool(hold_violation_counts)
    hold_pass = (route_complete and hold_evidence_complete and not hold_violation_lines
                 and not any(value > 0 for value in hold_violation_counts)
                 and all(math.isfinite(value) and value >= 0 for value in hold_slacks))

    gates: dict[str, bool] = {
        "route_process": returncode == 0,
        "route_complete": route_complete,
        "lut4_device_gate": utilization["lut4"] is not None and utilization["lut4"] <= device_flow.GATE["lut4"],
        "dff_device_gate": utilization["dff"] is not None and utilization["dff"] <= device_flow.GATE["dff"],
        "bsram_device_gate": utilization["bsram"] is not None and utilization["bsram"] <= device_flow.GATE["bsram"],
        "mult12_device_gate": utilization["mult12"] is not None and utilization["mult12"] <= device_flow.GATE["mult12"],
        "lut_15k": utilization["lut4"] is not None and utilization["lut4"] <= 15000,
        "dsp_4": utilization["mult12"] is not None and utilization["mult12"] <= 4,
        "timing_50mhz": timing_pass,
        "hold": hold_pass,
        # This runner validates one pinned runtime whose min/RC path model is
        # known to collapse to slow-max. Explicit numbers alone cannot qualify
        # that model. A separate, artifact-bound qualification must precede
        # packing; never turn this into a pass from a quiet/numeric-only log.
        "hold_model_qualification": False,
    }
    return {
        "util": utilization,
        "fmax_mhz": frequencies,
        "hold_slacks_ns": hold_slacks,
        "hold_violation_counts": hold_violation_counts,
        "hold_violation_lines": hold_violation_lines[:50],
        "hold_evidence_status": ("EXPLICIT_VALUES_PRESENT_MODEL_REVIEW_REQUIRED"
                                 if hold_evidence_complete else "UNPROVEN_MISSING_EXPLICIT_MIN_DELAY_REPORT"),
        "hold_model_qualification": {
            "status": "UNPROVEN",
            "reason": "Pinned Himbaechel runtime lacks qualified fast-min routing and RC propagation",
            "review": "cores/system/common_scaffold/evidence/20261017_hold_capability_review.json",
        },
        "error_lines": error_lines[:50],
        "reported_error_count": reported_errors,
        "timing_fail_lines": timing_fail_lines[:50],
        "route_complete": route_complete,
        "gates": gates,
    }


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def run_attempt(candidate: Path, attempt: str, chipdb: Path | None = None, seed: int = 3,
                route_only: bool = False) -> int:
    candidate = candidate.resolve()
    if not candidate.is_dir():
        raise CandidateError(f"candidate directory not found: {candidate}")
    if not ATTEMPT_RE.fullmatch(attempt):
        raise CandidateError("attempt must contain 1-48 ASCII letters, digits, '_' or '-'")
    if not isinstance(seed, int) or not 1 <= seed <= 0xFFFFFFFF:
        raise CandidateError("seed must be an integer in 1..4294967295")
    chipdb_path: Path | None = None
    if chipdb is None:
        raise CandidateError("a corrected --chipdb is required: pinned Gowin runtime lacks LUT1/2/3 timing arcs (PR #1850)")
    if chipdb is not None:
        chipdb_path = chipdb.resolve()
        if not chipdb_path.is_file() or chipdb_path.stat().st_size == 0:
            raise CandidateError(f"chipdb must be an existing non-empty file: {chipdb_path}")

    tag = attempt
    names = {
        "status": f"route_{tag}_status.json",
        "summary": f"build_{tag}_summary.json",
        "cst": f"explicitio33_{attempt}.cst",
        "pnr": f"pnr25k_{tag}.json",
        "router_log": f"nextpnr_{tag}.log",
        "console_log": f"pnr_console_{tag}.log",
        "pack_log": f"pack_{tag}.log",
        "bitstream": f"candidate_{tag}.fs",
    }
    existing = [name for name in names.values() if (candidate / name).exists()]
    if existing:
        raise CandidateError("refusing to overwrite attempt artifacts: " + ", ".join(existing))

    top_json = candidate / "top25k.json"
    original_cst = candidate / "tang25k.cst"
    if not top_json.is_file() or top_json.resolve().parent != candidate:
        raise CandidateError("candidate must contain a local top25k.json")
    if not original_cst.is_file() or original_cst.resolve().parent != candidate:
        raise CandidateError("candidate must contain a local original tang25k.cst")

    status_path = candidate / names["status"]
    summary_path = candidate / names["summary"]
    state: dict[str, Any] = {
        "status": "RUNNING",
        "phase": "preflight",
        "board_programming": "NOT_RUN",
        "candidate": str(candidate),
        "attempt": attempt,
        "device": device_flow.DEVICE,
        "family": device_flow.FAMILY,
        "clk_mhz": device_flow.CLK_MHZ,
        "router": "router1",
        "seed": seed,
        "route_only": route_only,
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "artifacts": names,
    }
    summary: dict[str, Any] | None = None
    status_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")

    try:
        simulation_provenance = verify_simulation_gate(candidate)
        top_sha = sha256_file(top_json)
        cst_sha = sha256_file(original_cst)
        derived_text, io_ports = derive_explicitio33_cst(original_cst.read_text(encoding="utf-8"))
        cst_path = candidate / names["cst"]
        with cst_path.open("x", encoding="utf-8", newline="") as stream:
            stream.write(derived_text)
        runtime_nextpnr, packer_script, runtime_provenance = validate_official_runtime()

        state.update(
            phase="place_and_route",
            simulation_provenance=simulation_provenance,
            input_top25k_json=top_json.name,
            input_top25k_sha256=top_sha,
            original_cst=original_cst.name,
            original_cst_sha256=cst_sha,
            derived_cst=names["cst"],
            derived_cst_sha256=sha256_file(cst_path),
            explicit_io_type="LVCMOS33",
            io_type_ports=io_ports,
            runtime_provenance=runtime_provenance,
        )
        status_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")

        route_command = [
            str(runtime_nextpnr), "--json", top_json.name,
            "--write", names["pnr"],
            "--device", device_flow.DEVICE,
            "--vopt", "family=" + device_flow.FAMILY,
            "--vopt", "cst=" + names["cst"],
            "--vopt", "sspi_as_gpio",
            "--freq", str(device_flow.CLK_MHZ),
            "--seed", str(seed), "--router", "router1", "--threads", "1",
            "--log", names["router_log"],
        ]
        if chipdb_path is not None:
            route_command.extend(["--chipdb", str(chipdb_path)])
            state["chipdb"] = str(chipdb_path)
            state["chipdb_sha256"] = sha256_file(chipdb_path)
        route_env = route_environment(OFFICIAL_RUNTIME)
        state["route_command"] = route_command
        state["route_pythonhome"] = route_env["PYTHONHOME"]
        state["route_path_prefix"] = route_env["PATH"].split(os.pathsep)[:4]
        status_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")

        with (candidate / names["console_log"]).open("x", encoding="utf-8") as console:
            console.write("$ " + subprocess.list2cmdline(route_command) + "\n")
            console.flush()
            route_started = time.monotonic()
            try:
                route_result = subprocess.run(
                    route_command, cwd=candidate, env=route_env,
                    stdout=console, stderr=subprocess.STDOUT,
                    timeout=3600, check=False,
                )
            except subprocess.TimeoutExpired as error:
                state["route_elapsed_seconds"] = time.monotonic() - route_started
                raise CandidateError("official nextpnr timed out after 3600 seconds") from error
        state["route_elapsed_seconds"] = time.monotonic() - route_started

        route_log_path = candidate / names["router_log"]
        route_log_text = route_log_path.read_text(encoding="utf-8", errors="replace") if route_log_path.exists() else ""
        route_report = parse_route_report(route_log_text, route_result.returncode)
        state.update(route_returncode=route_result.returncode, route_report=route_report)
        route_pass = all(route_report["gates"].values())
        state["route_gates_pass"] = route_pass
        if route_only:
            # Keep implementation diagnostics useful while an independent
            # min-delay/hold review is pending. This status is deliberately
            # incompatible with every bitstream/board qualification gate.
            summary = {
                "status": "ROUTE_PASS_NOT_PACKED" if route_pass else "ROUTE_GATE_FAIL_NOT_PACKED",
                "device": device_flow.DEVICE,
                "family": device_flow.FAMILY,
                "clk_mhz": device_flow.CLK_MHZ,
                "util": route_report["util"],
                "gates": route_report["gates"],
                "gate": dict(device_flow.GATE, lut4=15000, mult12=4),
                "fmax_mhz": route_report["fmax_mhz"],
                "hold_slacks_ns": route_report["hold_slacks_ns"],
                "hold_violation_counts": route_report["hold_violation_counts"],
                "hold_violation_lines": route_report["hold_violation_lines"],
                "hold_evidence_status": route_report["hold_evidence_status"],
                "hold_evidence": ("EXPLICIT_ROUTER_VALUES" if route_report["hold_slacks_ns"]
                                  else "ROUTER_GATE_ONLY_NO_EXPLICIT_MIN_DELAY_PROOF"),
                "route_error_lines": route_report["error_lines"],
                "simulation": "PASS",
                "simulation_provenance": simulation_provenance,
                "input_top25k_json": top_json.name,
                "input_top25k_sha256": top_sha,
                "original_cst": original_cst.name,
                "original_cst_sha256": cst_sha,
                "derived_cst": names["cst"],
                "derived_cst_sha256": sha256_file(cst_path),
                "attempt": attempt,
                "route_command": route_command,
                "runtime_provenance": runtime_provenance,
                "chipdb": state.get("chipdb"),
                "chipdb_sha256": state.get("chipdb_sha256"),
                "routed_json": names["pnr"],
                "routed_json_sha256": (sha256_file(candidate / names["pnr"])
                                       if (candidate / names["pnr"]).is_file() else None),
                "bitstream": "NOT_CREATED_ROUTE_ONLY",
                "board": "NOT_RUN",
                "board_programming": "NOT_RUN",
            }
            write_json(summary_path, summary)
            state.update(status="PASS" if route_pass else "FAIL", phase="route_only_complete",
                         build=summary["status"], packing="NOT_RUN_ROUTE_ONLY")
            if not route_pass:
                state["error"] = "route/resource/setup/router hold gate failed; route-only mode never packs"
            print(json.dumps({"status": summary["status"], "attempt": attempt,
                              "summary_file": names["summary"], "fmax_mhz": summary["fmax_mhz"],
                              "gates": summary["gates"], "packing": "NOT_RUN_ROUTE_ONLY"},
                             indent=2), flush=True)
            return 0 if route_pass else 1
        if not route_pass:
            summary = {
                "status": "BUILD_GATE_FAIL",
                "device": device_flow.DEVICE,
                "clk_mhz": device_flow.CLK_MHZ,
                "util": route_report["util"],
                "gates": route_report["gates"],
                "gate": dict(device_flow.GATE, lut4=15000, mult12=4),
                "fmax_mhz": route_report["fmax_mhz"],
                "hold_slacks_ns": route_report["hold_slacks_ns"],
                "hold_violation_lines": route_report["hold_violation_lines"],
                "hold_evidence_status": route_report["hold_evidence_status"],
                "error_lines": route_report["error_lines"],
                "input_top25k_sha256": top_sha,
                "derived_cst": names["cst"],
                "board": "NOT_RUN",
            }
            raise CandidateError("resource/setup/hold/route gate failed; bitstream packing was blocked")

        state["phase"] = "packer_preflight"
        status_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        pack_env = pack_environment(OFFICIAL_RUNTIME)
        pack_python = Path(runtime_provenance["baseline_python311"])
        packages = pack_env["PYTHONPATH"]
        import_probe = subprocess.run(
            [str(pack_python), "-c", "import apycula.gowin_pack; print(apycula.gowin_pack.__file__)"],
            cwd=candidate, env=pack_env, capture_output=True, text=True, timeout=60, check=False,
        )
        import_output = import_probe.stdout + import_probe.stderr
        expected_package = str(Path(packages) / "apycula").lower()
        if import_probe.returncode or expected_package not in import_probe.stdout.lower():
            state["packer_import_probe"] = import_output
            raise CandidateError("packer did not import Apicula from the isolated official runtime")
        state["packer_import_probe"] = import_output.strip()

        pack_command = [
            str(pack_python), str(packer_script), "-d", device_flow.FAMILY,
            "--sspi_as_gpio", "-o", names["bitstream"], names["pnr"],
        ]
        state["pack_command"] = pack_command
        state["phase"] = "packing"
        status_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        pack_started = time.monotonic()
        with (candidate / names["pack_log"]).open("x", encoding="utf-8") as pack_log:
            pack_log.write("$ " + subprocess.list2cmdline(pack_command) + "\n")
            pack_log.flush()
            pack_result = subprocess.run(
                pack_command, cwd=candidate, env=pack_env,
                stdout=pack_log, stderr=subprocess.STDOUT,
                timeout=900, check=False,
            )
        state["pack_elapsed_seconds"] = time.monotonic() - pack_started
        if pack_result.returncode:
            raise CandidateError(f"official Apicula packer failed with exit code {pack_result.returncode}")
        bitstream = candidate / names["bitstream"]
        if not bitstream.is_file() or bitstream.stat().st_size <= 0:
            raise CandidateError("official packer returned success without a non-empty bitstream")

        final_gates = dict(route_report["gates"])
        final_gates["official_apicula_import"] = True
        summary = {
            "status": "BUILD_PASS_NOT_BOARD",
            "device": device_flow.DEVICE,
            "family": device_flow.FAMILY,
            "clk_mhz": device_flow.CLK_MHZ,
            "util": route_report["util"],
            "gates": final_gates,
            "gate": dict(device_flow.GATE, lut4=15000, mult12=4),
            "ceiling": device_flow.CEILING,
            "fmax_mhz": route_report["fmax_mhz"],
            "hold_slacks_ns": route_report["hold_slacks_ns"],
            "hold_violation_lines": route_report["hold_violation_lines"],
            "hold_evidence_status": route_report["hold_evidence_status"],
            "route_error_lines": route_report["error_lines"],
            "bitstream": names["bitstream"],
            "bitstream_bytes": bitstream.stat().st_size,
            "bitstream_sha256": sha256_file(bitstream),
            "board": "NOT_RUN",
            "board_programming": "NOT_RUN",
            "simulation": "PASS",
            "simulation_provenance": simulation_provenance,
            "input_top25k_json": top_json.name,
            "input_top25k_sha256": top_sha,
            "original_cst": original_cst.name,
            "original_cst_sha256": cst_sha,
            "derived_cst": names["cst"],
            "derived_cst_sha256": sha256_file(cst_path),
            "explicit_io_type": "LVCMOS33",
            "io_type_ports": io_ports,
            "attempt": attempt,
            "route_command": route_command,
            "pack_command": pack_command,
            "runtime_provenance": runtime_provenance,
            "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        state.update(status="PASS", phase="complete", build=summary["status"],
                     bitstream=names["bitstream"], bitstream_sha256=summary["bitstream_sha256"],
                     bitstream_bytes=summary["bitstream_bytes"])
        write_json(summary_path, summary)
    except Exception as error:
        state.update(status="FAIL", phase=state.get("phase", "preflight"), error=str(error))
        if summary is not None:
            write_json(summary_path, summary)
    finally:
        write_json(status_path, state)

    print(json.dumps({
        "status": state.get("status"),
        "phase": state.get("phase"),
        "candidate": str(candidate),
        "attempt": attempt,
        "status_file": names["status"],
        "summary_file": names["summary"] if summary is not None else None,
        "error": state.get("error"),
        "gates": (summary or {}).get("gates"),
        "bitstream": state.get("bitstream"),
        "bitstream_sha256": state.get("bitstream_sha256"),
    }, indent=2), flush=True)
    return 0 if state.get("status") == "PASS" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path, help="candidate directory containing build_status.json and top25k.json")
    parser.add_argument("--attempt", default="official_router1_seed3",
                        help="unique output tag (default: official_router1_seed3)")
    parser.add_argument("--seed", type=int, default=3,
                        help="placement/routing PRNG seed; all implementation gates remain required (default: 3)")
    parser.add_argument("--chipdb", type=Path, required=True,
                        help="corrected Gowin chip database including LUT1/2/3 timing arcs (PR #1850)")
    parser.add_argument("--route-only", action="store_true",
                        help="retain routing evidence without packing or board qualification")
    args = parser.parse_args()
    try:
        return run_attempt(args.candidate, args.attempt, args.chipdb, seed=args.seed,
                           route_only=args.route_only)
    except CandidateError as error:
        print(f"preflight failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
