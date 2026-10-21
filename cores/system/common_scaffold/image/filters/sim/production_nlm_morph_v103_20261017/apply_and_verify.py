#!/usr/bin/env python3
"""Fail-closed v103-family production integration runner.

Default invocation is read-only: it runs the isolated candidate regression and
audits the three frozen OP release gates. Production RTL and manifests are
written only with --apply, after every independent route/board gate passes.
An apply snapshots exact old bytes, installs only the engine and weight helper,
runs the complete image/filter regression, and rolls all bytes back on error.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
DEFAULT_CANDIDATE = ROOT / (
    "cores/system/common_scaffold/board/tang25k/build/"
    "image_filter_frame_selftest_25k_20261017_v103_nlm_morph"
)
EXPECTED_FREEZE = "a18e341165205f1a87332bd99e0a6f496b8dd210ae8d4f1123c3c2296e34bb5a"
PRODUCTION = ROOT / "cores/system/common_scaffold/image/filters/rtl"
FILTER_MANIFEST = ROOT / "cores/system/common_scaffold/image/filters/manifest.json"
PREFLIGHT_SCRIPT = HERE / "run_preflight.py"
INTEGRATION_SCRIPT = HERE / "run_final_integration.py"
ENGINE_NAME = "img_filter_frame_engine.v"
WEIGHT_NAME = "img_filter_exp_weight.v"
PRODUCTION_FILES = (ENGINE_NAME, WEIGHT_NAME)


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import local gate module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


INTEGRATION = load_module("v103_apply_integration_gate", INTEGRATION_SCRIPT)


class ApplyFailure(RuntimeError):
    def __init__(self, message: str, rollback_status: str):
        super().__init__(message)
        self.rollback_status = rollback_status


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def display_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(ROOT.resolve()))
    except ValueError:
        return str(resolved)


def resolve_candidate(candidate_arg: Path | None, expected_freeze: str | None,
                      parser: argparse.ArgumentParser) -> tuple[Path, str]:
    if candidate_arg is not None and expected_freeze is None:
        parser.error("--candidate-root requires --expected-freeze-sha256")
    freeze = expected_freeze or EXPECTED_FREEZE
    if not re.fullmatch(r"[0-9a-fA-F]{64}", freeze):
        parser.error("--expected-freeze-sha256 must be exactly 64 hexadecimal characters")
    candidate_root = candidate_arg or DEFAULT_CANDIDATE
    if not candidate_root.is_absolute():
        candidate_root = ROOT / candidate_root
    return candidate_root.resolve(), freeze.lower()


def selected_candidate_rtl(candidate_root: Path) -> tuple[Path, dict[str, str]]:
    """Require OP0/1/2 to carry identical original-byte engine/helper files."""
    source_root = candidate_root / "op0" / "rtl"
    hashes: dict[str, str] = {}
    for name in PRODUCTION_FILES:
        source = source_root / name
        if not source.is_file():
            raise FileNotFoundError(f"candidate source is missing: {source}")
        data = source.read_bytes()
        module_name = "img_filter_frame_engine" if name == ENGINE_NAME else "img_filter_exp_weight"
        if re.search(rb"\bmodule\s+" + module_name.encode("ascii") + rb"\b", data) is None:
            raise ValueError(f"candidate {name} does not declare production module {module_name}")
        digest = sha256_bytes(data)
        for op in range(1, 3):
            other = candidate_root / f"op{op}" / "rtl" / name
            if not other.is_file() or sha256_file(other) != digest:
                raise ValueError(f"OP0/1/2 source bytes differ or are missing for {name}")
        hashes[name] = digest
    return source_root, hashes


def atomic_write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(prefix=f".{path.name}.", suffix=".tmp",
                                         dir=path.parent, delete=False) as stream:
            temp_path = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
        temp_path = None
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def make_manifest_bytes(original: bytes, source_hashes: dict[str, str],
                        evidence_ref: str, pixel_width_max: int) -> bytes:
    manifest = json.loads(original.decode("utf-8-sig"))
    modules = manifest.get("modules")
    if not isinstance(modules, list):
        raise ValueError("filter manifest has no modules list")
    by_name = {record.get("name"): record for record in modules if isinstance(record, dict)}
    for name, record in ((ENGINE_NAME, by_name.get("img_filter_frame_engine")),
                         (WEIGHT_NAME, by_name.get("img_filter_exp_weight"))):
        if record is None:
            raise ValueError(f"filter manifest lacks module record for {name}")
        record["source_sha256"] = source_hashes[name]
        record["production_evidence"] = evidence_ref
    engine_record = by_name["img_filter_frame_engine"]
    limitations = engine_record.get("limitations")
    if not isinstance(limitations, list):
        raise ValueError("img_filter_frame_engine manifest limitations are not a list")
    width_items = [item for item in limitations
                   if isinstance(item, str) and "PIXEL_W" in item]
    if len(width_items) != 1:
        raise ValueError("expected exactly one PIXEL_W limitation for img_filter_frame_engine")
    old_width_item = width_items[0]
    updated = re.sub(r"PIXEL_W\s+1\.\.\d+", f"PIXEL_W 1..{pixel_width_max}", old_width_item)
    if updated == old_width_item and f"PIXEL_W 1..{pixel_width_max}" not in old_width_item:
        raise ValueError("could not update PIXEL_W limitation without changing unrelated wording")
    limitations[limitations.index(old_width_item)] = updated
    return (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def run_preflight(evidence_dir: Path, candidate_root: Path, expected_freeze: str,
                  source_rtl_root: Path, label: str) -> dict[str, Any]:
    task_evidence = HERE / "evidence"
    prior = {path.resolve() for path in task_evidence.glob("preflight_*") if path.is_dir()}
    command = [sys.executable, "-B", str(PREFLIGHT_SCRIPT),
               "--candidate-root", str(candidate_root),
               "--expected-freeze-sha256", expected_freeze,
               "--source-rtl-root", str(source_rtl_root)]
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True,
                               timeout=2400, check=False)
    (evidence_dir / f"{label}_preflight_launcher.log").write_text(
        completed.stdout + completed.stderr, encoding="utf-8")
    new_dirs = [path for path in task_evidence.glob("preflight_*")
                if path.is_dir() and path.resolve() not in prior]
    if len(new_dirs) != 1:
        return {"status": "FAIL", "exit_code": completed.returncode,
                "reason": f"expected exactly one {label} preflight evidence directory; found {len(new_dirs)}",
                "command": command}
    summary_path = new_dirs[0] / "summary.json"
    if not summary_path.is_file():
        return {"status": "FAIL", "exit_code": completed.returncode,
                "reason": f"{label} preflight did not write summary.json", "command": command}
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    passed = (summary.get("frozen_candidate_audit") == "PASS"
              and summary.get("local_regressions") == "PASS"
              and summary.get("production_sources_unchanged") is True
              and summary.get("failure") is None)
    return {"status": "PASS" if passed else "FAIL", "exit_code": completed.returncode,
            "preflight_status": summary.get("status"),
            "frozen_candidate_audit": summary.get("frozen_candidate_audit"),
            "local_regressions": summary.get("local_regressions"),
            "integration_gates": summary.get("integration_gates"),
            "production_sources_unchanged": summary.get("production_sources_unchanged"),
            "summary": display_path(summary_path), "command": command}


def run_candidate_gate(evidence_dir: Path, candidate_root: Path, expected_freeze: str,
                       source_root: Path) -> dict[str, Any]:
    preflight = run_preflight(evidence_dir, candidate_root, expected_freeze, source_root, "candidate")
    audit = INTEGRATION.audit_three_ops(candidate_root, ROOT, expected_freeze, preflight)
    return {"status": "PASS" if preflight.get("status") == "PASS"
            and three_op_gate_passes(audit) else "BLOCKED",
            "candidate_preflight": preflight, "three_op_release_audit": audit}


def three_op_gate_passes(audit: dict[str, Any]) -> bool:
    operations = audit.get("ops")
    return (audit.get("apply_gate") == "PASS" and isinstance(operations, list)
            and len(operations) == 3
            and [record.get("op") for record in operations] == [0, 1, 2]
            and all(record.get("status") == "PASS" for record in operations))


def backup_production(evidence_dir: Path) -> dict[str, bytes]:
    files = {name: (PRODUCTION / name).read_bytes() for name in PRODUCTION_FILES}
    files[FILTER_MANIFEST.name] = FILTER_MANIFEST.read_bytes()
    backup_dir = evidence_dir / "production_backup"
    backup_dir.mkdir(parents=True, exist_ok=False)
    records: dict[str, Any] = {}
    for name, payload in files.items():
        target = backup_dir / name
        target.write_bytes(payload)
        if target.read_bytes() != payload:
            raise IOError(f"backup byte comparison failed for {name}")
        records[name] = {"sha256": sha256_bytes(payload), "bytes": len(payload)}
    (backup_dir / "backup_manifest.json").write_text(json.dumps({
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "purpose": "exact-byte rollback source for guarded production integration",
        "apply_performed": False, "files": records,
    }, indent=2) + "\n", encoding="utf-8")
    return files


def restore_production(old_files: dict[str, bytes]) -> None:
    for name, payload in old_files.items():
        target = FILTER_MANIFEST if name == FILTER_MANIFEST.name else PRODUCTION / name
        atomic_write_bytes(target, payload)
        if target.read_bytes() != payload:
            raise IOError(f"rollback byte verification failed for {target}")


def install_sources(source_root: Path, expected_hashes: dict[str, str]) -> None:
    for name in PRODUCTION_FILES:
        payload = (source_root / name).read_bytes()
        if sha256_bytes(payload) != expected_hashes[name]:
            raise ValueError(f"candidate changed after gate audit: {name}")
        atomic_write_bytes(PRODUCTION / name, payload)
        if sha256_file(PRODUCTION / name) != expected_hashes[name]:
            raise IOError(f"production source did not retain candidate bytes: {name}")


def pixel_width_limit(engine_path: Path) -> int:
    source = engine_path.read_text(encoding="utf-8")
    source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    values = re.findall(r"\bPIXEL_W\s*>\s*(\d+)\b", source)
    if not values:
        raise ValueError("candidate engine has no recognizable PIXEL_W upper bound")
    return max(int(value) for value in values)


def apply_and_verify(evidence_dir: Path, candidate_root: Path, expected_freeze: str,
                     source_root: Path, source_hashes: dict[str, str],
                     expected_original_hashes: dict[str, str | None],
                     expected_manifest_hash: str) -> dict[str, Any]:
    current_hashes = {name: sha256_file(PRODUCTION / name) for name in PRODUCTION_FILES}
    if (current_hashes != expected_original_hashes
            or sha256_file(FILTER_MANIFEST) != expected_manifest_hash):
        raise ApplyFailure("production RTL or manifest changed while release evidence was being audited",
                           "NOT_NEEDED_NO_WRITE_OCCURRED")
    old_files = backup_production(evidence_dir)
    backup_summary = {name: {"sha256": sha256_bytes(data), "bytes": len(data)}
                      for name, data in old_files.items()}
    result: dict[str, Any] = {"apply_performed": False,
                              "production_backup": backup_summary}
    try:
        install_sources(source_root, source_hashes)
        production_preflight = run_preflight(
            evidence_dir, candidate_root, expected_freeze, PRODUCTION, "post_apply_production")
        result["post_apply_preflight"] = production_preflight
        if production_preflight.get("status") != "PASS":
            raise RuntimeError("post-apply production-source regression failed")

        evidence_ref = str((evidence_dir / "apply_summary.json").relative_to(
            ROOT / "cores/system/common_scaffold/image/filters"))
        updated_manifest = make_manifest_bytes(
            old_files[FILTER_MANIFEST.name], source_hashes, evidence_ref,
            pixel_width_limit(source_root / ENGINE_NAME))
        atomic_write_bytes(FILTER_MANIFEST, updated_manifest)
        manifest_check = json.loads(FILTER_MANIFEST.read_text(encoding="utf-8"))
        records = {item.get("name"): item for item in manifest_check.get("modules", [])
                   if isinstance(item, dict)}
        if any(records.get(module, {}).get("source_sha256") != source_hashes[filename]
               for filename, module in ((ENGINE_NAME, "img_filter_frame_engine"),
                                        (WEIGHT_NAME, "img_filter_exp_weight"))):
            raise RuntimeError("updated production manifest source hashes did not verify")
        if any(sha256_file(PRODUCTION / name) != source_hashes[name] for name in PRODUCTION_FILES):
            raise RuntimeError("production bytes changed after manifest update")
        result["apply_performed"] = True
        result["production_source_sha256"] = source_hashes
        result["manifest_sha256"] = sha256_file(FILTER_MANIFEST)
        result["manifest_evidence_reference"] = evidence_ref
        result["rollback"] = "NOT_NEEDED"
        return result
    except Exception as original_error:
        try:
            restore_production(old_files)
        except Exception as rollback_error:
            raise ApplyFailure(f"{original_error}; rollback also failed: {rollback_error}",
                               "FAIL_ROLLBACK_VERIFICATION") from original_error
        raise ApplyFailure(str(original_error), "PASS_EXACT_OLD_BYTES_RESTORED") from original_error


def self_test() -> int:
    checks = 0
    with tempfile.TemporaryDirectory(prefix="apply_verify_host_") as temp_raw:
        temp = Path(temp_raw)
        old_file = temp / "old.bin"
        updated_file = temp / "updated.bin"
        original = b"old production bytes\x00\xff"
        replacement = b"candidate source bytes\x01\xfe"
        atomic_write_bytes(old_file, original)
        atomic_write_bytes(updated_file, replacement)
        if old_file.read_bytes() != original or updated_file.read_bytes() != replacement:
            raise AssertionError("atomic byte write changed source contents")
        atomic_write_bytes(updated_file, old_file.read_bytes())
        if updated_file.read_bytes() != original:
            raise AssertionError("byte restoration failed")
        checks += 1

        fixture_manifest = {"modules": [
            {"name": "img_filter_frame_engine", "limitations": ["PIXEL_W 1..12"]},
            {"name": "img_filter_exp_weight", "limitations": []},
        ]}
        original_manifest = json.dumps(fixture_manifest).encode("utf-8")
        fixture_hashes = {ENGINE_NAME: "a" * 64, WEIGHT_NAME: "b" * 64}
        updated = json.loads(make_manifest_bytes(original_manifest, fixture_hashes,
                                                 "sim/evidence/apply_summary.json", 16))
        records = {record["name"]: record for record in updated["modules"]}
        if (records["img_filter_frame_engine"]["limitations"] != ["PIXEL_W 1..16"]
                or records["img_filter_frame_engine"]["source_sha256"] != "a" * 64
                or records["img_filter_exp_weight"]["source_sha256"] != "b" * 64):
            raise AssertionError("candidate hashes or width update were not applied to manifest fixture")
        checks += 1

    good_gate = {"apply_gate": "PASS", "ops": [{"op": op, "status": "PASS"} for op in range(3)]}
    bad_gate = {"apply_gate": "BLOCKED", "ops": [{"op": 0, "status": "PASS"},
                                                   {"op": 1, "status": "BLOCKED"}]}
    if not three_op_gate_passes(good_gate):
        raise AssertionError("three-OP release gate fixture should allow guarded apply")
    if three_op_gate_passes(bad_gate):
        raise AssertionError("incomplete three-OP evidence must remain blocked")
    checks += 1
    print(f"APPLY AND VERIFY HOST SELF-TEST PASS checks={checks}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-root", type=Path,
                        help="frozen candidate directory containing op0/op1/op2")
    parser.add_argument("--expected-freeze-sha256",
                        help="exact SOURCE_FREEZE_MANIFEST SHA256 (required when overriding candidate root)")
    parser.add_argument("--apply", action="store_true",
                        help="after all three OP gates and full regressions PASS, atomically update production")
    parser.add_argument("--self-test", action="store_true", help="run host-only byte/manifest fixtures")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    candidate_root, expected_freeze = resolve_candidate(
        args.candidate_root, args.expected_freeze_sha256, parser)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    evidence_dir = HERE / "evidence" / f"apply_verify_{stamp}_{os.getpid()}"
    evidence_dir.mkdir(parents=True, exist_ok=False)
    try:
        source_root, source_hashes = selected_candidate_rtl(candidate_root)
        gates = run_candidate_gate(evidence_dir, candidate_root, expected_freeze, source_root)
    except Exception as exc:
        gates = {"status": "BLOCKED", "error": f"{type(exc).__name__}: {exc}"}
        source_hashes = {}
        source_root = candidate_root / "op0" / "rtl"
    summary: dict[str, Any] = {
        "runner": display_path(Path(__file__)),
        "started_utc": stamp,
        "candidate_root": display_path(candidate_root),
        "expected_candidate_freeze_sha256": expected_freeze,
        "candidate_source_sha256": source_hashes,
        "mode": "GUARDED_APPLY" if args.apply else "READ_ONLY_CHECK_ONLY",
        "apply_requested": bool(args.apply),
        "apply_performed": False,
        "candidate_gate": gates,
        "production_rtl_before_sha256": {
            name: sha256_file(PRODUCTION / name) if (PRODUCTION / name).is_file() else None
            for name in PRODUCTION_FILES
        },
        "production_manifest_before_sha256": sha256_file(FILTER_MANIFEST),
        "temporary_workspaces": "TemporaryDirectory cleanup is automatic; only timestamped small logs/summaries persist",
    }
    if args.apply and gates.get("status") == "PASS":
        try:
            applied = apply_and_verify(evidence_dir, candidate_root, expected_freeze,
                                       source_root, source_hashes,
                                       summary["production_rtl_before_sha256"],
                                       summary["production_manifest_before_sha256"])
            summary.update(applied)
        except Exception as exc:
            summary["apply_error"] = f"{type(exc).__name__}: {exc}"
            summary["rollback"] = getattr(exc, "rollback_status", "NOT_CONFIRMED")
    elif args.apply:
        summary["apply_blocked"] = "three-OP board/route/synthesis and candidate regression gates must all PASS"
    else:
        summary["read_only"] = True
    summary["production_rtl_after_sha256"] = {
        name: sha256_file(PRODUCTION / name) for name in PRODUCTION_FILES
    }
    if not args.apply and summary["production_rtl_after_sha256"] != summary["production_rtl_before_sha256"]:
        summary["status"] = "FAIL_READ_ONLY_MUTATION_DETECTED"
    elif args.apply and summary.get("apply_error"):
        summary["status"] = "APPLY_FAILED_ROLLED_BACK"
    elif args.apply and summary.get("apply_performed"):
        summary["status"] = "APPLY_PASS"
    else:
        summary["status"] = "READY_FOR_REVIEW" if gates.get("status") == "PASS" else "BLOCKED"
    summary["completed_utc"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    summary_path = evidence_dir / "apply_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"Evidence: {display_path(evidence_dir)}")
    return 0 if summary["status"] in ("READY_FOR_REVIEW", "APPLY_PASS") else 2


if __name__ == "__main__":
    raise SystemExit(main())
