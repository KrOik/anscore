#!/usr/bin/env python3
"""Host-only negative controls; all candidate-like bytes are disposable fixtures."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
VALIDATOR = HERE.parents[1] / "qualify_min_delay_report.py"
SPEC = importlib.util.spec_from_file_location("hold_report_validator", VALIDATOR)
assert SPEC and SPEC.loader
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)

ROLES = (
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


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2, allow_nan=True) + "\n", encoding="utf-8")


def snapshot(root: Path) -> dict[str, str]:
    return {str(p.relative_to(root)): digest(p) for p in root.rglob("*") if p.is_file()}


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.paths = {role: root / (role + ".json") for role in ROLES}
        for role, path in self.paths.items():
            path.write_text("HOST FIXTURE ONLY; NOT REAL " + role + "\n", encoding="utf-8")
        write_json(self.paths["report"], {"hold_timing": {
            "status": "PASS", "endpoints": 7, "candidate_paths": 9,
            "timed_paths": 9, "unknown_paths": 0, "violations": 0,
            "worst_hold_slack_ns": 0.125, "reason": "all_candidate_paths_timed",
        }})
        write_json(self.paths["source_freeze"], {"verification": {"result": "PASS"},
                                                  "fixture_only": True})
        write_json(self.paths["op_freeze"], {"op": 2, "parameters": {"OP": 2},
            "verification": {"result": "PASS", "source_freeze_sha256": digest(self.paths["source_freeze"])},
            "fixture_only": True})
        write_json(self.paths["model_qualification"], {
            "schema": "gw5a-min-delay-model-qualification-v1",
            "fixture_only": True, "status": "PASS", "reviewer": "HOST FIXTURE; NOT A REAL REVIEW",
            "capabilities": {name: True for name in CAPABILITIES},
            "artifact_sha256": {name: digest(self.paths[name]) for name in (
                "timing_binary", "chipdb", "producer_source_manifest",
                "qualification_review", "qualification_tests")},
        })
        self.binding_path = root / "bindings.json"
        self.binding = {
            "schema": "gw5a-min-delay-bindings-v1", "op": 2,
            "artifacts": {role: {"path": path.name, "sha256": digest(path)}
                          for role, path in self.paths.items()},
            "analysis": {"complete": True, "mode": "post_route", "with_clock_skew": True,
                "setup_only": False, "fast_pip_delays": False, "process_returncode": 0,
                "clock_domains": ["clk"], "command": ["HOST_FIXTURE_ONLY", "--not-executable"]},
        }
        self.rebind()

    def change(self, role: str, fn) -> None:
        data = json.loads(self.paths[role].read_text(encoding="utf-8"))
        fn(data)
        write_json(self.paths[role], data)

    def timing(self, **changes) -> None:
        self.change("report", lambda data: data["hold_timing"].update(changes))

    def rebind(self) -> None:
        for role, path in self.paths.items():
            if path.is_file() and role in self.binding["artifacts"]:
                self.binding["artifacts"][role]["sha256"] = digest(path)
        write_json(self.binding_path, self.binding)

    def call(self, **options) -> dict:
        arguments = {"artifact_root": self.root,
            "expected_binding_sha256": digest(self.binding_path) if self.binding_path.is_file() else None,
            "trusted_qualification_sha256": digest(self.paths["model_qualification"])
                if self.paths["model_qualification"].is_file() else None,
            "fixture_only": True}
        arguments.update(options)
        return GATE.qualify_report(self.paths["report"], self.binding_path, **arguments)


@contextmanager
def fixture(*, outside_temp: bool = False):
    with tempfile.TemporaryDirectory(prefix=".hold_qualification_fixture_",
                                     dir=HERE if outside_temp else None) as location:
        root = Path(location).resolve()
        try:
            yield Fixture(root)
        finally:
            # TemporaryDirectory is responsible for deleting this known root.
            pass
    assert not root.exists(), "fixture was not removed"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, help="small host-test receipt; no fixture artifacts retained")
    args = parser.parse_args()
    results: list[dict] = []

    def case(name, status, code, mutate=lambda f: None, *, rebind=True,
             options=None, outside_temp=False):
        record = {"name": name, "expected_status": status, "expected_blocker": code}
        try:
            with fixture(outside_temp=outside_temp) as f:
                mutate(f)
                if rebind:
                    f.rebind()
                before = snapshot(f.root)
                observed = f.call(**(options or {}))
                after = snapshot(f.root)
                record["observed_status"] = observed["status"]
                blockers = [v["code"] for v in observed["blockers"]]
                record["observed_blockers"] = blockers
                assert observed["status"] == status, observed
                assert (code in blockers) if code else not blockers, observed
                assert before == after, "validator modified evidence"
                assert observed["files_written"] is False
                assert observed["pack_performed"] is False
                assert observed["apply_performed"] is False
                assert observed["board_programming"] == "NOT_RUN"
                if status == "PASS":
                    assert observed["scope"] == "HOST_FIXTURE_ONLY"
                    assert observed["production_qualification"] == "NOT_AUTHORIZED"
                record["read_only"] = True
            record["temporary_artifacts_removed"] = True
            record["result"] = "PASS"
        except Exception:
            record["result"] = "FAIL"
            record["error"] = traceback.format_exc()
        results.append(record)

    case("complete_pinned_host_fixture", "PASS", None)
    case("known_negative_slack", "FAIL", "HOLD_FAIL", lambda f: f.timing(
        status="FAIL", reason="known_hold_violation", violations=2, worst_hold_slack_ns=-0.05))
    case("known_exact_zero_slack_is_violation", "FAIL", "HOLD_FAIL", lambda f: f.timing(
        status="FAIL", reason="known_hold_violation", violations=1, worst_hold_slack_ns=0))
    case("negative_slack_cannot_claim_no_violations", "FAIL", "SLACK_INCONSISTENCY",
         lambda f: f.timing(worst_hold_slack_ns=-0.01))
    case("zero_slack_cannot_claim_no_violations", "FAIL", "SLACK_INCONSISTENCY",
         lambda f: f.timing(worst_hold_slack_ns=0))
    case("positive_slack_cannot_claim_violation", "FAIL", "SLACK_INCONSISTENCY",
         lambda f: f.timing(violations=1))
    case("unknown_wire_all_paths", "UNPROVEN", "HOLD_UNPROVEN", lambda f: f.timing(
        status="UNPROVEN", reason="incomplete_delay_model", timed_paths=0, unknown_paths=9,
        worst_hold_slack_ns=None))
    case("one_unknown_candidate_blocks", "UNPROVEN", "HOLD_UNPROVEN", lambda f: f.timing(
        status="UNPROVEN", reason="incomplete_delay_model", timed_paths=8, unknown_paths=1))
    case("known_violation_precedes_unknown", "FAIL", "HOLD_FAIL", lambda f: f.timing(
        status="FAIL", reason="known_hold_violation", timed_paths=8, unknown_paths=1,
        violations=1, worst_hold_slack_ns=-0.2))
    case("endpoint_with_no_candidate_blocks", "UNPROVEN", "HOLD_UNPROVEN", lambda f: f.timing(
        status="UNPROVEN", reason="no_constrained_hold_paths", candidate_paths=0, timed_paths=0,
        unknown_paths=7, worst_hold_slack_ns=None))
    case("zero_endpoints_is_unproven", "UNPROVEN", "HOLD_UNPROVEN", lambda f: f.timing(
        status="UNPROVEN", reason="no_constrained_hold_paths", endpoints=0,
        candidate_paths=0, timed_paths=0, worst_hold_slack_ns=None))
    case("zero_endpoints_cannot_claim_pass", "FAIL", "STATUS_INCONSISTENCY", lambda f: f.timing(
        endpoints=0, candidate_paths=0, timed_paths=0, worst_hold_slack_ns=None))
    case("not_run_is_unproven", "UNPROVEN", "HOLD_NOT_RUN", lambda f: f.timing(
        status="NOT_RUN", reason="analysis_not_run", endpoints=0, candidate_paths=0,
        timed_paths=0, worst_hold_slack_ns=None))
    case("not_run_with_nonzero_counters_is_invalid", "FAIL", "STATUS_INCONSISTENCY",
         lambda f: f.timing(status="NOT_RUN", reason="analysis_not_run"))
    case("more_timed_than_candidates", "FAIL", "COUNT_INCONSISTENCY", lambda f: f.timing(timed_paths=10))
    case("more_violations_than_timed", "FAIL", "COUNT_INCONSISTENCY", lambda f: f.timing(violations=10))
    case("unaccounted_untimed_candidate", "FAIL", "COUNT_INCONSISTENCY", lambda f: f.timing(timed_paths=8))
    case("excess_unknown_count", "FAIL", "COUNT_INCONSISTENCY", lambda f: f.timing(unknown_paths=8))
    case("paths_without_endpoints", "FAIL", "COUNT_INCONSISTENCY", lambda f: f.timing(endpoints=0))
    case("incomplete_endpoint_coverage_claims_pass", "FAIL", "INCOMPLETE_ENDPOINTS",
         lambda f: f.timing(endpoints=10))
    case("negative_count", "FAIL", "INVALID_COUNT", lambda f: f.timing(endpoints=-1))
    case("boolean_count", "FAIL", "INVALID_COUNT", lambda f: f.timing(violations=False))
    case("fractional_count", "FAIL", "INVALID_COUNT", lambda f: f.timing(timed_paths=9.0))
    case("missing_count", "FAIL", "INVALID_COUNT", lambda f: f.change(
        "report", lambda d: d["hold_timing"].pop("candidate_paths")))
    case("null_slack_for_timed_path", "FAIL", "INVALID_SLACK", lambda f: f.timing(worst_hold_slack_ns=None))
    case("boolean_slack", "FAIL", "INVALID_SLACK", lambda f: f.timing(worst_hold_slack_ns=True))
    case("missing_slack_field", "FAIL", "MISSING_SLACK", lambda f: f.change(
        "report", lambda d: d["hold_timing"].pop("worst_hold_slack_ns")))
    case("nan_slack", "FAIL", "INVALID_REPORT", lambda f: f.timing(worst_hold_slack_ns=float("nan")))
    case("infinite_slack", "FAIL", "INVALID_REPORT", lambda f: f.timing(worst_hold_slack_ns=float("inf")))
    case("numeric_overflow_slack", "FAIL", "INVALID_SLACK", lambda f: f.paths["report"].write_text(
        f.paths["report"].read_text().replace("0.125", "1e999"), encoding="utf-8"))
    case("wrong_status", "FAIL", "STATUS_INCONSISTENCY", lambda f: f.timing(status="UNPROVEN"))
    case("wrong_reason", "FAIL", "STATUS_INCONSISTENCY", lambda f: f.timing(reason=""))
    case("duplicate_json_key", "FAIL", "INVALID_REPORT", lambda f: f.paths["report"].write_text(
        '{"hold_timing":{},"hold_timing":{}}', encoding="utf-8"))
    case("missing_hold_timing", "UNPROVEN", "MISSING_HOLD_TIMING", lambda f: write_json(f.paths["report"], {}))
    case("missing_report", "UNPROVEN", "MISSING_REPORT", lambda f: f.paths["report"].unlink())
    case("missing_bindings", "UNPROVEN", "MISSING_BINDINGS", lambda f: f.binding_path.unlink(),
         rebind=False, options={"expected_binding_sha256": "0" * 64})
    case("untrusted_bindings", "UNPROVEN", "UNPINNED_BINDINGS", options={"expected_binding_sha256": None})
    case("incorrect_binding_hash", "FAIL", "BINDING_HASH_MISMATCH", options={"expected_binding_sha256": "0" * 64})
    case("missing_qualification", "UNPROVEN", "MISSING_ARTIFACT", lambda f: f.paths["model_qualification"].unlink())
    case("no_qualification_trust_pin", "UNPROVEN", "UNTRUSTED_MODEL_QUALIFICATION",
         options={"trusted_qualification_sha256": None})
    case("wrong_qualification_trust_pin", "UNPROVEN", "UNTRUSTED_MODEL_QUALIFICATION",
         options={"trusted_qualification_sha256": "0" * 64})
    case("fixture_cannot_qualify_production", "UNPROVEN", "FIXTURE_QUALIFICATION_FORBIDDEN",
         options={"fixture_only": False})
    case("fixture_cannot_run_outside_system_temp", "FAIL", "FIXTURE_ROOT_FORBIDDEN", outside_temp=True)
    case("qualification_boolean_is_not_evidence", "FAIL", "INVALID_MODEL_QUALIFICATION",
         lambda f: write_json(f.paths["model_qualification"], True))
    case("qualification_unproven", "UNPROVEN", "UNQUALIFIED_MODEL", lambda f: f.change(
        "model_qualification", lambda d: d.update(status="UNPROVEN")))
    case("qualification_missing_reviewer", "UNPROVEN", "UNQUALIFIED_MODEL", lambda f: f.change(
        "model_qualification", lambda d: d.update(reviewer=" ")))
    case("qualification_capability_missing", "UNPROVEN", "UNQUALIFIED_MODEL", lambda f: f.change(
        "model_qualification", lambda d: d["capabilities"].pop("wire_unknown_propagation")))
    case("qualification_capability_boolean_required", "UNPROVEN", "UNQUALIFIED_MODEL", lambda f: f.change(
        "model_qualification", lambda d: d["capabilities"].update(sequential_hold_arcs=1)))
    case("qualification_artifact_hash_wrong", "FAIL", "QUALIFICATION_ARTIFACT_MISMATCH", lambda f: f.change(
        "model_qualification", lambda d: d["artifact_sha256"].update(timing_binary="0" * 64)))
    case("missing_clock", "UNPROVEN", "MISSING_CLOCK", lambda f: f.binding["analysis"].update(clock_domains=[]))
    case("async_clock_does_not_constrain_hold", "UNPROVEN", "MISSING_CLOCK", lambda f: f.binding[
        "analysis"].update(clock_domains=["<async>"]))
    case("duplicate_clock", "UNPROVEN", "MISSING_CLOCK", lambda f: f.binding[
        "analysis"].update(clock_domains=["clk", "clk"]))
    case("analysis_not_complete", "UNPROVEN", "INCOMPLETE_ANALYSIS", lambda f: f.binding[
        "analysis"].update(complete=False))
    case("setup_only_report", "UNPROVEN", "INCOMPLETE_ANALYSIS", lambda f: f.binding[
        "analysis"].update(setup_only=True))
    case("placement_only_report", "UNPROVEN", "INCOMPLETE_ANALYSIS", lambda f: f.binding[
        "analysis"].update(mode="placement"))
    case("clock_skew_missing", "UNPROVEN", "INCOMPLETE_ANALYSIS", lambda f: f.binding[
        "analysis"].update(with_clock_skew=False))
    case("fast_pip_approximation_forbidden", "UNPROVEN", "INCOMPLETE_ANALYSIS", lambda f: f.binding[
        "analysis"].update(fast_pip_delays=True))
    case("failed_tool_process", "UNPROVEN", "INCOMPLETE_ANALYSIS", lambda f: f.binding[
        "analysis"].update(process_returncode=1))
    case("boolean_returncode", "UNPROVEN", "INCOMPLETE_ANALYSIS", lambda f: f.binding[
        "analysis"].update(process_returncode=False))
    case("missing_command", "UNPROVEN", "MISSING_COMMAND", lambda f: f.binding["analysis"].update(command=[]))
    case("artifact_path_escape", "FAIL", "ARTIFACT_PATH", lambda f: f.binding["artifacts"][
        "run_log"].update(path="../outside.log"))
    case("windows_drive_path_escape", "FAIL", "ARTIFACT_PATH", lambda f: f.binding["artifacts"][
        "run_log"].update(path="C:\\outside.log"))
    case("artifact_not_bound", "UNPROVEN", "UNBOUND_ARTIFACT", lambda f: f.binding["artifacts"].pop("run_log"))
    case("empty_artifact", "UNPROVEN", "MISSING_ARTIFACT", lambda f: f.paths["run_log"].write_bytes(b""))
    case("missing_artifact", "UNPROVEN", "MISSING_ARTIFACT", lambda f: f.paths["run_log"].unlink())
    case("artifact_tampered_after_pin", "FAIL", "ARTIFACT_HASH_MISMATCH",
         lambda f: f.paths["run_log"].write_text("CHANGED\n", encoding="utf-8"), rebind=False)
    case("unqualified_source_freeze", "UNPROVEN", "UNQUALIFIED_FREEZE", lambda f: f.change(
        "source_freeze", lambda d: d["verification"].update(result="UNPROVEN")))
    case("freeze_op_mismatch", "FAIL", "FREEZE_OP_MISMATCH", lambda f: f.change(
        "op_freeze", lambda d: d["parameters"].update(OP=1)))
    case("freeze_lineage_mismatch", "FAIL", "FREEZE_LINEAGE_MISMATCH", lambda f: f.change(
        "op_freeze", lambda d: d["verification"].update(source_freeze_sha256="0" * 64)))

    def cli_case(name, expected_exit, expected_code, *, missing_report=False, trust=False):
        record = {"name": name, "expected_exit": expected_exit, "expected_blocker": expected_code}
        try:
            with fixture() as f:
                if missing_report:
                    f.paths["report"].unlink()
                command = [sys.executable, "-B", str(VALIDATOR), "--report", str(f.paths["report"]),
                    "--binding-manifest", str(f.binding_path), "--artifact-root", str(f.root),
                    "--expected-binding-sha256", digest(f.binding_path)]
                if trust:
                    command += ["--trusted-qualification-sha256", digest(f.paths["model_qualification"])]
                before = snapshot(f.root)
                completed = subprocess.run(command, text=True, capture_output=True, timeout=20, check=False)
                observed = json.loads(completed.stdout)
                assert completed.returncode == expected_exit, (completed.returncode, completed.stdout, completed.stderr)
                assert expected_code in [v["code"] for v in observed["blockers"]], observed
                assert snapshot(f.root) == before, "CLI modified evidence"
                record.update(observed_exit=completed.returncode, observed_status=observed["status"],
                    observed_blockers=[v["code"] for v in observed["blockers"]], read_only=True)
            record.update(result="PASS", temporary_artifacts_removed=True)
        except Exception:
            record.update(result="FAIL", error=traceback.format_exc())
        results.append(record)

    cli_case("cli_missing_report", 2, "MISSING_REPORT", missing_report=True)
    cli_case("cli_without_trusted_qualification", 2, "UNTRUSTED_MODEL_QUALIFICATION")
    cli_case("cli_fixture_trust_cannot_qualify_real_candidate", 2, "FIXTURE_QUALIFICATION_FORBIDDEN", trust=True)
    remaining = list(HERE.glob(".hold_qualification_fixture_*"))
    failures = [r["name"] for r in results if r["result"] != "PASS"]
    summary = {"schema": "host-hold-qualification-test-v1", "fixture_only": True,
        "production_qualification": "NOT_AUTHORIZED", "real_model_tool_qualification": "UNPROVEN",
        "utc": datetime.now(timezone.utc).isoformat(), "python": sys.version,
        "validator_sha256": digest(VALIDATOR), "test_runner_sha256": digest(Path(__file__)),
        "command": [sys.executable, "-B", str(Path(__file__).resolve()), *sys.argv[1:]],
        "tests": len(results), "passed": len(results) - len(failures), "failed": len(failures),
        "failure_names": failures, "remaining_workspace_fixture_roots": [str(p) for p in remaining],
        "result": "PASS" if not failures and not remaining else "FAIL",
        "synthesis": "NOT_RUN", "pnr": "NOT_RUN", "pack": "NOT_RUN",
        "board": "NOT_RUN", "production_apply": "NOT_RUN", "cases": results}
    if args.summary:
        target = args.summary.resolve()
        if not target.is_relative_to(HERE) or target.suffix.lower() != ".json":
            parser.error("summary must be a JSON receipt inside this host-test directory")
        write_json(target, summary)
    print(json.dumps(summary, indent=2, allow_nan=False))
    return 0 if summary["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
