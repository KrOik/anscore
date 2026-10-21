#!/usr/bin/env python3
"""Read-only qualification of a pinned nextpnr hold_timing report.

No tool/model qualification is trusted by default. A caller must explicitly pin
the reviewed qualification SHA, the binding manifest SHA and all artifact bytes.
This program does not pack, program, apply RTL, or modify any input/output file.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path, PureWindowsPath
import re
import sys
import tempfile
from typing import Any

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BINDING_SCHEMA = "gw5a-min-delay-bindings-v1"
QUALIFICATION_SCHEMA = "gw5a-min-delay-model-qualification-v1"
ARTIFACT_ROLES = (
    "report", "source_freeze", "op_freeze", "input_netlist", "routed_json",
    "original_cst", "derived_cst", "chipdb", "timing_binary",
    "producer_source_manifest", "run_log", "model_qualification",
    "qualification_review", "qualification_tests",
)
CAPABILITIES = (
    "fast_min_routing", "slow_max_routing", "dual_corner_rc",
    "wire_unknown_propagation", "clock_skew_minmax",
    "sequential_hold_arcs", "unknown_paths_fail_closed",
)
QUALIFIED_ROLES = (
    "timing_binary", "chipdb", "producer_source_manifest",
    "qualification_review", "qualification_tests",
)
COUNT_FIELDS = ("endpoints", "candidate_paths", "timed_paths", "unknown_paths", "violations")


class GateError(ValueError):
    def __init__(self, status: str, code: str, message: str):
        super().__init__(message)
        self.status, self.code = status, code


def require(condition: bool, code: str, message: str, status: str = "FAIL") -> None:
    if not condition:
        raise GateError(status, code, message)


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def valid_hash(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{64}", value) is not None


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def _nonfinite_constant(value: str) -> Any:
    raise ValueError("non-finite JSON constant: " + value)


def load_object(path: Path, label: str) -> dict[str, Any]:
    require(path.is_file(), "MISSING_" + label.upper(), label + " is missing", "UNPROVEN")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"),
                           object_pairs_hook=_unique_object, parse_constant=_nonfinite_constant)
    except (OSError, ValueError) as exc:
        raise GateError("FAIL", "INVALID_" + label.upper(), f"{label}: {exc}") from exc
    require(isinstance(value, dict), "INVALID_" + label.upper(), label + " must be an object")
    return value


def safe_artifact(root: Path, name: Any) -> Path:
    require(isinstance(name, str) and bool(name), "ARTIFACT_PATH", "artifact path must be nonempty")
    relative = Path(name)
    require(not relative.is_absolute() and not PureWindowsPath(name).drive
            and ".." not in relative.parts and ".." not in PureWindowsPath(name).parts,
            "ARTIFACT_PATH", "artifact path must remain relative to the artifact root")
    path = (root / relative).resolve()
    require(path.is_relative_to(root), "ARTIFACT_PATH", "artifact resolves outside its root")
    return path


def inspect_hold_timing(report: dict[str, Any]) -> dict[str, Any]:
    """Validate counts against the frozen producer's aggregation semantics."""
    timing = report.get("hold_timing")
    require(isinstance(timing, dict), "MISSING_HOLD_TIMING", "report has no hold_timing object", "UNPROVEN")
    for field in COUNT_FIELDS:
        value = timing.get(field)
        require(type(value) is int and value >= 0, "INVALID_COUNT", field + " must be a nonnegative integer")
    endpoints, candidates, timed, unknown, violations = (timing[k] for k in COUNT_FIELDS)
    require(timed <= candidates and violations <= timed, "COUNT_INCONSISTENCY",
            "timed_paths/candidate_paths/violations are inconsistent")
    # An untimed candidate adds one unknown; an endpoint without a candidate
    # adds another. Hence unknown may exceed candidates, but not this bound.
    require(candidates - timed <= unknown <= candidates - timed + endpoints,
            "COUNT_INCONSISTENCY", "unknown_paths is inconsistent with timed/candidate/endpoint counts")
    require(endpoints > 0 or candidates == 0, "COUNT_INCONSISTENCY", "paths reported without endpoints")
    require("worst_hold_slack_ns" in timing, "MISSING_SLACK", "worst_hold_slack_ns is required")
    slack = timing["worst_hold_slack_ns"]
    if timed == 0:
        require(slack is None, "SLACK_INCONSISTENCY", "untimed reports must have null worst_hold_slack_ns")
    else:
        require(type(slack) in (int, float) and math.isfinite(float(slack)),
                "INVALID_SLACK", "timed reports require finite numeric worst_hold_slack_ns")
        # This producer counts <=0 as a violation, including exactly zero.
        require((violations > 0) == (slack <= 0), "SLACK_INCONSISTENCY",
                "worst slack and violation count disagree with producer <=0 semantics")
    if timing.get("status") == "NOT_RUN":
        require(all(timing[k] == 0 for k in COUNT_FIELDS) and slack is None
                and timing.get("reason") == "analysis_not_run",
                "STATUS_INCONSISTENCY", "NOT_RUN requires the producer's zero/null initial state")
        return dict(timing)
    if violations:
        status, reason = "FAIL", "known_hold_violation"
    elif candidates == 0 or unknown > 0 or timed != candidates:
        status = "UNPROVEN"
        reason = "no_constrained_hold_paths" if candidates == 0 else "incomplete_delay_model"
    else:
        status, reason = "PASS", "all_candidate_paths_timed"
    require(timing.get("status") == status and timing.get("reason") == reason,
            "STATUS_INCONSISTENCY", "hold_timing status/reason does not match its numbers")
    if status == "PASS":
        require(endpoints > 0 and candidates >= endpoints and timed == candidates and unknown == 0,
                "INCOMPLETE_ENDPOINTS", "PASS requires nonempty complete endpoint coverage")
    return dict(timing)


def inspect_bindings(report_path: Path, binding_path: Path, artifact_root: Path,
                     expected_binding_sha256: str | None,
                     trusted_qualification_sha256: str | None,
                     fixture_only: bool) -> dict[str, Any]:
    require(valid_hash(expected_binding_sha256), "UNPINNED_BINDINGS",
            "an explicit expected binding-manifest SHA256 is required", "UNPROVEN")
    binding = load_object(binding_path, "bindings")
    require(sha256_file(binding_path) == expected_binding_sha256.lower(),
            "BINDING_HASH_MISMATCH", "binding-manifest SHA256 differs from the explicit pin")
    require(binding.get("schema") == BINDING_SCHEMA, "BINDING_SCHEMA", "unsupported binding schema")
    require(type(binding.get("op")) is int and binding["op"] in (0, 1, 2),
            "BINDING_OP", "bindings must explicitly select OP0, OP1 or OP2")
    artifacts = binding.get("artifacts")
    require(isinstance(artifacts, dict), "MISSING_ARTIFACTS", "bindings lack artifact descriptors", "UNPROVEN")
    root = artifact_root.resolve()
    paths: dict[str, Path] = {}
    hashes: dict[str, str] = {}
    for role in ARTIFACT_ROLES:
        entry = artifacts.get(role)
        require(isinstance(entry, dict) and valid_hash(entry.get("sha256")),
                "UNBOUND_ARTIFACT", "missing or invalid artifact binding: " + role, "UNPROVEN")
        path = safe_artifact(root, entry.get("path"))
        require(path.is_file() and path.stat().st_size > 0,
                "MISSING_ARTIFACT", "missing or empty artifact: " + role, "UNPROVEN")
        actual = sha256_file(path)
        require(actual == entry["sha256"].lower(), "ARTIFACT_HASH_MISMATCH", "artifact changed: " + role)
        paths[role], hashes[role] = path, actual
    require(paths["report"] == report_path.resolve(), "REPORT_BINDING_MISMATCH",
            "the binding manifest selects a different report file")
    source_freeze = load_object(paths["source_freeze"], "source_freeze")
    op_freeze = load_object(paths["op_freeze"], "op_freeze")
    require(source_freeze.get("verification", {}).get("result") == "PASS"
            and op_freeze.get("verification", {}).get("result") == "PASS",
            "UNQUALIFIED_FREEZE", "source and OP freeze must record simulation PASS", "UNPROVEN")
    require(op_freeze.get("op") == binding["op"]
            and op_freeze.get("parameters", {}).get("OP") == binding["op"],
            "FREEZE_OP_MISMATCH", "OP freeze differs from the selected operation")
    require(op_freeze.get("verification", {}).get("source_freeze_sha256") == hashes["source_freeze"],
            "FREEZE_LINEAGE_MISMATCH", "OP freeze does not bind this source freeze")
    analysis = binding.get("analysis")
    require(isinstance(analysis, dict), "MISSING_ANALYSIS", "analysis provenance is missing", "UNPROVEN")
    require(analysis.get("complete") is True and analysis.get("mode") == "post_route"
            and analysis.get("with_clock_skew") is True and analysis.get("setup_only") is False
            and analysis.get("fast_pip_delays") is False and type(analysis.get("process_returncode")) is int
            and analysis["process_returncode"] == 0,
            "INCOMPLETE_ANALYSIS", "complete post-route min/max/clock-skew analysis was not recorded", "UNPROVEN")
    clocks = analysis.get("clock_domains")
    require(isinstance(clocks, list) and bool(clocks)
            and all(isinstance(c, str) and c.strip() and c != "<async>" for c in clocks)
            and len(set(clocks)) == len(clocks),
            "MISSING_CLOCK", "nonempty explicit clock domains are required", "UNPROVEN")
    command = analysis.get("command")
    require(isinstance(command, list) and bool(command) and all(isinstance(v, str) and v for v in command),
            "MISSING_COMMAND", "the actual timing command must be recorded", "UNPROVEN")
    require(valid_hash(trusted_qualification_sha256), "UNTRUSTED_MODEL_QUALIFICATION",
            "root must independently review and explicitly pin the tool/model qualification SHA256", "UNPROVEN")
    require(hashes["model_qualification"] == trusted_qualification_sha256.lower(),
            "UNTRUSTED_MODEL_QUALIFICATION", "qualification is not the caller's explicit trusted SHA", "UNPROVEN")
    qualification = load_object(paths["model_qualification"], "model_qualification")
    require(qualification.get("schema") == QUALIFICATION_SCHEMA,
            "QUALIFICATION_SCHEMA", "unsupported model-qualification schema")
    require(qualification.get("fixture_only") is fixture_only,
            "FIXTURE_QUALIFICATION_FORBIDDEN", "fixture qualification cannot qualify a real candidate", "UNPROVEN")
    if fixture_only:
        temporary_root = Path(tempfile.gettempdir()).resolve()
        require(root.is_relative_to(temporary_root) and root.name.startswith(".hold_qualification_fixture_"),
                "FIXTURE_ROOT_FORBIDDEN", "fixture qualification is restricted to disposable system-temp roots")
    require(qualification.get("status") == "PASS" and isinstance(qualification.get("reviewer"), str)
            and bool(qualification["reviewer"].strip()),
            "UNQUALIFIED_MODEL", "tool/model qualification is not independently reviewed PASS", "UNPROVEN")
    capabilities = qualification.get("capabilities")
    require(isinstance(capabilities, dict) and all(capabilities.get(k) is True for k in CAPABILITIES),
            "UNQUALIFIED_MODEL", "tool/model qualification does not cover every required min-delay capability", "UNPROVEN")
    qualified_hashes = qualification.get("artifact_sha256")
    require(isinstance(qualified_hashes, dict)
            and all(qualified_hashes.get(role) == hashes[role] for role in QUALIFIED_ROLES),
            "QUALIFICATION_ARTIFACT_MISMATCH", "reviewed model/tool provenance does not match the actual artifacts")
    return {"op": binding["op"], "binding_sha256": sha256_file(binding_path),
            "artifact_sha256": hashes, "clock_domains": clocks,
            "model_tool_qualification": "PASS", "reviewer": qualification["reviewer"]}


def qualify_report(report_path: Path, binding_path: Path, *, artifact_root: Path,
                   expected_binding_sha256: str | None,
                   trusted_qualification_sha256: str | None = None,
                   fixture_only: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {"status": "UNPROVEN", "fixture_only": fixture_only,
        "scope": "HOST_FIXTURE_ONLY" if fixture_only else "READ_ONLY_HOLD_ARTIFACT_QUALIFICATION",
        "production_qualification": "NOT_AUTHORIZED" if fixture_only else "UNPROVEN",
        "model_tool_qualification": "UNPROVEN", "pack_performed": False,
        "board_programming": "NOT_RUN", "apply_performed": False, "files_written": False,
        "report": str(report_path), "blockers": []}
    try:
        report = load_object(report_path, "report")
        result["report_sha256"] = sha256_file(report_path)
        timing = inspect_hold_timing(report)
        result["hold_timing"] = timing
        # Incomplete or violated reports cannot be promoted by any sidecar.
        require(timing["status"] == "PASS", "HOLD_" + timing["status"],
                "hold timing remains " + timing["status"] + ": " + timing["reason"],
                "UNPROVEN" if timing["status"] == "NOT_RUN" else timing["status"])
        verified = inspect_bindings(report_path, binding_path, artifact_root,
                                    expected_binding_sha256, trusted_qualification_sha256, fixture_only)
        result.update(verified)
        result["status"] = "PASS"
        if not fixture_only:
            result["production_qualification"] = "HOLD_ARTIFACTS_PASS_OTHER_RELEASE_GATES_REQUIRED"
    except GateError as exc:
        result["status"] = exc.status
        result["blockers"].append({"code": exc.code, "message": str(exc)})
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError) as exc:
        result["status"] = "FAIL"
        result["blockers"].append({"code": "INVALID_EVIDENCE", "message": f"{type(exc).__name__}: {exc}"})
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--binding-manifest", type=Path, required=True)
    parser.add_argument("--expected-binding-sha256", required=True)
    parser.add_argument("--trusted-qualification-sha256",
                        help="explicit SHA of independently root-reviewed tool/model qualification; none is trusted by default")
    parser.add_argument("--artifact-root", type=Path, default=ROOT)
    args = parser.parse_args()
    result = qualify_report(args.report, args.binding_manifest, artifact_root=args.artifact_root,
                            expected_binding_sha256=args.expected_binding_sha256,
                            trusted_qualification_sha256=args.trusted_qualification_sha256)
    print(json.dumps(result, indent=2, allow_nan=False))
    return {"PASS": 0, "FAIL": 1, "UNPROVEN": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
