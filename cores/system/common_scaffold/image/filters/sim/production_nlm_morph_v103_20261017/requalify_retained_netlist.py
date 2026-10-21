#!/usr/bin/env python3
"""Re-audit a retained v103 Yosys netlist without invoking Yosys.

By default this performs a read-only check of the specified failed synthesis
evidence. ``--execute`` creates a separate PASS review record and publishes the
retained JSON through the qualified wrapper's no-clobber handoff routine. It
never edits frozen inputs, starts synthesis, runs PNR, or programs hardware.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
from typing import Any

import run_qualified_synthesis as qualified

HERE = Path(__file__).resolve().parent
ROOT = qualified.ROOT
EVIDENCE_ROOT = HERE / "evidence"
ORIGINAL_EVIDENCE = EVIDENCE_ROOT / "qualified_synthesis_op0_20261016T225117_032118Z"
OP = 0
EXPECTED_FAILURE = "GateError: Yosys emitted unreviewed warnings"


class ReviewError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ReviewError(f"expected a JSON object: {path}")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReviewError(message)


def check_assert_contract(script_text: str, log_text: str) -> dict[str, Any]:
    """Require the explicit final Yosys ``check -assert`` to report zero issues."""
    script_commands = [line.strip() for line in script_text.splitlines()
                      if line.strip() and not line.lstrip().startswith("#")]
    require(script_commands.count("check -assert") == 1,
            "Yosys script must contain exactly one explicit check -assert")
    require(not qualified.collect_yosys_errors(log_text),
            "Yosys log contains an ERROR line")
    checks = list(re.finditer(
        r"(?m)^\s*\d+(?:\.\d+)?\. Executing CHECK pass \(checking for obvious problems\)\.",
        log_text,
    ))
    require(bool(checks), "Yosys log has no completed CHECK pass")
    tail = log_text[checks[-1].end():]
    result = re.search(r"(?m)^Found and reported (\d+) problems\.$", tail)
    require(result is not None, "last CHECK pass has no problem-count result")
    problem_count = int(result.group(1))
    require(problem_count == 0,
            f"last CHECK pass reported {problem_count} problems, expected 0")
    end = re.search(r"(?m)^End of script\. Logfile hash: [0-9a-fA-F]+", tail)
    require(end is not None, "Yosys log did not reach End of script after the final CHECK pass")
    return {"status": "PASS", "explicit_check_assert_count": 1,
            "check_pass_count": len(checks), "final_check_problem_count": problem_count,
            "script_completed": True}


def safe_retained_netlist(original_evidence: Path, summary: dict[str, Any]) -> Path:
    rel = summary.get("retained_netlist")
    require(isinstance(rel, str) and bool(rel), "retained netlist path is absent")
    rel_path = Path(rel)
    require(not rel_path.is_absolute() and not rel_path.drive and ".." not in rel_path.parts,
            "retained netlist path is not a safe repository-relative path")
    path = (ROOT / rel_path).resolve()
    require(path.is_relative_to(original_evidence.resolve()),
            "retained netlist resolves outside its original evidence directory")
    require(path.is_file() and path.stat().st_size > 0,
            "retained netlist is missing or empty")
    return path


def review_retained_evidence() -> dict[str, Any]:
    original_dir = ORIGINAL_EVIDENCE.resolve()
    require(original_dir.is_relative_to(EVIDENCE_ROOT.resolve()),
            "original evidence directory is outside the qualified evidence root")
    original_summary_path = original_dir / "summary.json"
    log_path = original_dir / "yosys_complete.log"
    script_path = original_dir / "qualified_synthesis.ys"
    for path in (original_summary_path, log_path, script_path):
        require(path.is_file(), f"required original evidence is missing: {path.name}")

    op_dir, manifest = qualified.validate_frozen_op(OP)
    original = load_json(original_summary_path)
    require(original.get("op") == OP and original.get("status") == "FAIL",
            "original synthesis summary is not the expected failed OP0 record")
    require(original.get("failure") == EXPECTED_FAILURE,
            "original record failed for a reason other than the reviewed warning gate")
    require(original.get("no_place_and_route") is True
            and original.get("no_board_programming") is True,
            "original run does not preserve the no-PNR/no-board boundary")
    require(original.get("yosys_error_lines") == [],
            "original summary reports Yosys errors")

    manifest_sha = sha256(op_dir / "FREEZE_MANIFEST.json")
    require(original.get("frozen_manifest_sha256") == manifest_sha,
            "original synthesis record is bound to a different frozen manifest")
    expected_inputs = {rel: manifest.get("files_sha256", {}).get(rel)
                       for rel in qualified.frozen_inputs_for_op(OP)}
    require(all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
                for value in expected_inputs.values()),
            "frozen manifest lacks one or more required source/memory digests")
    require(original.get("inputs") == expected_inputs,
            "original synthesis input digests do not exactly match the frozen OP0 inputs")

    expected_script = qualified.make_yosys_script(
        OP, extra_cells=qualified.PRIMITIVE_LIB_DIR / "cells_xtra_gw5a.v")
    script_text = script_path.read_text(encoding="utf-8")
    require(script_text == expected_script,
            "original Yosys script differs from the qualified frozen-input script")
    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    log_sha = sha256(log_path)
    require(original.get("complete_log_sha256") == log_sha,
            "original complete Yosys log digest mismatch")
    check_record = check_assert_contract(script_text, log_text)

    # The original runner rejects a nonzero Yosys exit before it reaches the
    # warning gate. Its exact recorded failure therefore proves exit status 0.
    # The completed log, zero final check count, valid JSON, and clean error
    # list independently corroborate that classification.
    require("End of script. Logfile hash:" in log_text,
            "Yosys did not reach its normal completed-script marker")
    warning_audit = qualified.audit_warnings(log_text)
    require(warning_audit.get("status") == "PASS"
            and warning_audit.get("unreviewed_warnings") == [],
            "complete Yosys log does not pass the current exact warning allowlist")
    previous_warning_audit = original.get("warning_audit", {})
    scoreboard_line = qualified.RESULT_FRAME_SCOREBOARD_WARNING
    previous_warnings = previous_warning_audit.get("warnings")
    previous_unreviewed = previous_warning_audit.get("unreviewed_warnings")
    require(previous_warning_audit.get("status") == "FAIL"
            and previous_warnings == [scoreboard_line] * 7
            + [qualified.ABC_COMBINATIONAL_WARNING]
            and previous_unreviewed == [scoreboard_line] * 7,
            "original synthesis failed for additional or different warnings")

    retained = safe_retained_netlist(original_dir, original)
    net_hash = sha256(retained)
    require(original.get("netlist_sha256") == net_hash
            and original.get("retained_netlist_sha256") == net_hash,
            "retained netlist SHA256 differs from original synthesis record")
    require(original.get("netlist_bytes") == retained.stat().st_size
            and original.get("retained_netlist_bytes") == retained.stat().st_size,
            "retained netlist size differs from original synthesis record")
    try:
        netlist = json.loads(retained.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ReviewError(f"retained Gowin JSON is invalid: {exc}") from exc
    structural = qualified.inspect_netlist(netlist)
    require(structural.get("status") == "PASS",
            "retained mapped netlist fails the current structural/resource gate")
    require(structural == original.get("structural_gate"),
            "recomputed structure/resource report differs from original synthesis summary")
    require(structural.get("primitive_definition_count") == 170
            and structural.get("blackbox_definition_count") == 170,
            "retained design does not contain the expected 170 official primitive definitions")
    require(structural.get("lut4_class_count", qualified.RESOURCE_LIMITS["lut4_class_max"] + 1)
            <= qualified.RESOURCE_LIMITS["lut4_class_max"],
            "retained design exceeds the LUT-class limit")
    require(structural.get("dsp_class_count", qualified.RESOURCE_LIMITS["mult12_class_max"] + 1)
            <= qualified.RESOURCE_LIMITS["mult12_class_max"],
            "retained design exceeds the DSP-class limit")

    op_dir = op_dir.resolve()
    publish_paths = [op_dir / name for name in
                     ("top25k.json", "top25k.json.sha256", "qualified_synthesis_handoff.json")]
    conflicts = [path.name for path in publish_paths if path.exists()]
    require(not conflicts, "refusing to overwrite existing OP0 handoff: " + ", ".join(conflicts))

    return {
        "status": "PASS",
        "op": OP,
        "original_failure": original.get("failure"),
        "original_evidence": str(original_dir.relative_to(ROOT)),
        "original_summary_sha256": sha256(original_summary_path),
        "qualified_yosys_exit_code": 0,
        "yosys_exit_code_basis": "original wrapper reaches this exact warning-gate failure only after zero return code, no ERROR lines, nonempty valid netlist, and passing structure gate",
        "complete_log": str(log_path.relative_to(ROOT)),
        "complete_log_sha256": log_sha,
        "check_assert": check_record,
        "frozen_manifest_sha256": manifest_sha,
        "inputs": expected_inputs,
        "warning_audit": warning_audit,
        "yosys_error_lines": [],
        "retained_netlist": str(retained.relative_to(ROOT)),
        "netlist_sha256": net_hash,
        "netlist_bytes": retained.stat().st_size,
        "structural_gate": structural,
        "no_place_and_route": True,
        "no_board_programming": True,
        "publish_destination": str(op_dir.relative_to(ROOT)),
        "publish_paths_available": True,
    }


def self_test() -> int:
    valid_script = "read_verilog top.v\ncheck -assert\nstat\n"
    valid_log = (
        "10. Executing CHECK pass (checking for obvious problems).\n"
        "Found and reported 0 problems.\n"
        "End of script. Logfile hash: abc123\n"
    )
    result = check_assert_contract(valid_script, valid_log)
    if result.get("status") != "PASS" or result.get("final_check_problem_count") != 0:
        raise AssertionError("clean check -assert evidence was not accepted")
    print("PASS requalify selftest explicit_check_assert_zero")

    negative_cases = (
        ("missing-script-command", "read_verilog top.v\nstat\n", valid_log),
        ("nonzero-check-count", valid_script, valid_log.replace("reported 0", "reported 1")),
        ("missing-completion", valid_script, valid_log.replace("End of script. Logfile hash: abc123\n", "")),
        ("yosys-error-line", valid_script, valid_log + "top.v:1: ERROR: fixture\n"),
    )
    for name, script_text, log_text in negative_cases:
        try:
            check_assert_contract(script_text, log_text)
        except ReviewError:
            print(f"PASS requalify selftest {name}_rejected")
        else:
            raise AssertionError(f"invalid check -assert fixture was accepted: {name}")
    print("REQUALIFY RETAINED NETLIST SELF-TEST PASS checks=5")
    return 0


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def execute_review(review: dict[str, Any]) -> dict[str, Any]:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    review_dir = EVIDENCE_ROOT / f"requalified_synthesis_op{OP}_{stamp}"
    review_dir.mkdir(parents=True, exist_ok=False)
    original_log = ROOT / review["complete_log"]
    copied_log = review_dir / "yosys_complete.log"
    shutil.copy2(original_log, copied_log)
    require(sha256(copied_log) == review["complete_log_sha256"],
            "copied Yosys log digest differs from original evidence")

    summary_path = review_dir / "summary.json"
    review.update({
        "status": "PASS",
        "qualified_by": "requalify_retained_netlist.py",
        "reviewed_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "complete_log_sha256": review["complete_log_sha256"],
        "evidence_dir": str(review_dir.relative_to(ROOT)),
        "route_handoff_publication": "PENDING",
        "apply_performed": False,
    })
    write_json(summary_path, review)

    op_dir = qualified.CANDIDATE / f"op{OP}"
    handoff_record = {
        "frozen_manifest_sha256": review["frozen_manifest_sha256"],
        "evidence_dir": str(review_dir.relative_to(ROOT)),
        "status": "PASS",
        "warning_audit": review["warning_audit"],
        "structural_gate": review["structural_gate"],
    }
    netlist = ROOT / review["retained_netlist"]
    qualified.publish_route_handoff(netlist, op_dir, OP, handoff_record)
    review["route_handoff_publication"] = "PASS"
    review["published"] = {
        "top25k_json": handoff_record["retained_netlist"],
        "top25k_sha256": handoff_record["retained_netlist_sha256"],
        "sha256_handoff": handoff_record["sha256_handoff"],
        "qualified_synthesis_handoff": handoff_record["route_handoff"],
    }
    write_json(summary_path, review)
    return review


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="run disposable review-schema checks")
    parser.add_argument("--check-only", action="store_true",
                        help="audit existing evidence without writing files (default)")
    parser.add_argument("--execute", action="store_true",
                        help="write a separate PASS review and publish the retained netlist handoff")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.execute and args.check_only:
        parser.error("--execute and --check-only are mutually exclusive")
    try:
        review = review_retained_evidence()
        if args.execute:
            review = execute_review(review)
        print(json.dumps(review, indent=2, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"status": "BLOCKED", "reason": f"{type(exc).__name__}: {exc}",
                          "apply_performed": False, "synthesis_run": False,
                          "place_and_route_run": False, "hardware_run": False},
                         indent=2, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
