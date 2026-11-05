"""Execute only the separately approved twenty-child continuation of attempt01.

Authoring this file and its metadata is not approval to execute it.  No --seal,
preparation, oracle, version, production-lint or automatic-retry entrypoint exists.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile


P = Path(__file__).resolve().parent
R = P.parents[2]
SELF = P / "run_repair_attempt02.py"
PLAN = P / "REPAIR_PLAN_ATTEMPT02.json"
SEAL = P / "REPAIR_SEAL_ATTEMPT02.json"
RECEIPT = P / "verification_attempt02.json"
REPORTS = P / "reports/attempt02"
ARCHIVE = P / "failure_archive/attempt_02"
MARKER = b"general_weighted_matching_invalid_parameters__see_README"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_bytes())


def exclusive_json(path, value):
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def mutable_attempt02_path(relative):
    return (relative == "verification_attempt02.json"
            or relative.startswith("reports/attempt02/")
            or relative.startswith("failure_archive/attempt_02/"))


def validate_inputs(seal, plan):
    """Hash and JSON provenance checks only; never calculate an optimum."""
    expected = set(seal["pre_execution_sha256"]) | {SEAL.name}
    actual = {path.relative_to(P).as_posix() for path in P.rglob("*")
              if path.is_file()
              and not mutable_attempt02_path(path.relative_to(P).as_posix())}
    require(actual == expected, "sealed pre-execution inventory changed")
    for relative, digest in seal["pre_execution_sha256"].items():
        path = P / relative
        require(not path.is_symlink() and sha(path) == digest,
                "sealed bytes changed: " + relative)
    for relative, digest in seal["external_sha256"].items():
        require(sha(R / relative) == digest, "external history bytes changed: " + relative)
    require(seal["runner_sha256"] == sha(SELF), "repair runner hash changed")
    require(seal["repair_plan_sha256"] == sha(PLAN), "repair plan hash changed")
    original_seal = read(P / "SOURCE_SEAL.json")
    original_plan = read(P / "TEST_PLAN.json")
    original_receipt = read(P / "verification.json")
    original_archive = read(P / "failure_archive/attempt_01/ARCHIVE.json")
    require(seal["original_bindings"] == {
        "source_seal_sha256": sha(P / "SOURCE_SEAL.json"),
        "test_plan_sha256": sha(P / "TEST_PLAN.json"),
        "receipt_sha256": sha(P / "verification.json"),
        "archive_manifest_sha256": sha(P / "failure_archive/attempt_01/ARCHIVE.json"),
        "preparation_receipt_sha256": sha(P / "preparation/receipt.json"),
    }, "original provenance bindings changed")
    require(len(original_seal["source_sha256"]) == 43, "original input count")
    current = {relative: sha(P / relative)
               for relative in original_seal["source_sha256"]}
    require(current == seal["current_43_input_sha256"], "current input mapping")
    changed = [relative for relative in current
               if current[relative] != original_seal["source_sha256"][relative]]
    require(changed == ["example/general_match8.sv"], "repair exceeds example")
    before = (P / "failure_archive/attempt_01/sources/example/general_match8.sv").read_bytes()
    first, separator, rest = before.partition(b"\n")
    require(separator and first == b"// SPDX-License-Identifier: Apache-2.0",
            "unexpected original example prefix")
    after = first + separator + b"`timescale 1ns/1ps\n" + rest
    require((P / "example/general_match8.sv").read_bytes() == after,
            "example is not the one-line LF timescale insertion")
    require(original_receipt["status"] == "FAIL_STOPPED"
            and original_receipt["terminal_timeout"] is False,
            "original attempt is not the preserved non-timeout failure")
    require([record["status"] for record in original_receipt["records"]]
            == ["PASS"] * 3 + ["FAIL"] + ["NOT_RUN"] * 19,
            "original child outcomes changed")
    require(original_receipt["results"] == [], "original simulation inventory")
    require(original_receipt["source_sha256"] == original_seal["source_sha256"],
            "original receipt/source binding")
    require(original_archive["original_receipt_sha256"] == sha(P / "verification.json"),
            "original archive/receipt binding")
    for relative, digest in original_archive["files_sha256"].items():
        require(sha(P / "failure_archive/attempt_01" / relative) == digest,
                "original archive payload changed: " + relative)
    require(plan["children"] == original_plan["children"][3:]
            == seal["children"], "repair children differ from original suffix")
    require(len(plan["children"]) == 20
            and [child["name"] for child in original_plan["children"][:3]]
            == ["stored_enumeration", "tool_version", "production_lint"],
            "fixed continuation origin changed")
    require([child["kind"] for child in plan["children"]].count("simulation") == 8
            and all(child["kind"] in ("lint", "compile", "simulation", "reject")
                    and child["timeout_seconds"] == 20 for child in plan["children"]),
            "forbidden child or timeout in repair plan")
    require(plan["profiles"] == original_plan["profiles"]
            and plan["totals"] == original_plan["totals"]
            and plan["carried_forward_records"] == original_receipt["records"][:3],
            "fixed numerical metadata changed")
    paths = {name: str(Path(value)) for name, value in seal["tool_paths"].items()}
    require({name: sha(Path(value)) for name, value in paths.items()}
            == seal["tools_sha256"] == original_seal["tools_sha256"],
            "tool bytes changed")
    return paths


def validate_approval(path, digest, approved_seal, seal, plan):
    path = path.resolve(strict=True)
    require(not path.is_relative_to(P), "approval must be external to package")
    require(sha(path) == digest, "external approval hash mismatch")
    require(approved_seal == sha(SEAL), "approved repair seal mismatch")
    approval = read(path)
    required = {
        "schema": "anscore-b28-root-repair-approval-v1",
        "approved_by": "root",
        "stage": "hdl_repair_attempt02",
        "repair_seal_sha256": approved_seal,
        "repair_plan_sha256": sha(PLAN),
        "runner_sha256": sha(SELF),
        "original_receipt_sha256": sha(P / "verification.json"),
        "original_archive_sha256": sha(P / "failure_archive/attempt_01/ARCHIVE.json"),
        "children": plan["children"],
        "tools_sha256": seal["tools_sha256"],
        "max_children": 20,
        "simulations": 8,
        "timeout_seconds_per_tree": 20,
        "stop_on_first_failure": True,
        "automatic_retry": False,
        "no_preparation_or_oracle_rerun": True,
    }
    for key, value in required.items():
        require(approval.get(key) == value, "external approval field: " + key)
    return path


def import_reviewed_helpers():
    """Called only after raw-hash approval validation and the exclusive claim."""
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(
        "_anscore_matching_attempt01_reviewed_helpers", P / "run_tests.py")
    require(spec is not None and spec.loader is not None, "helper import specification")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def copy_exclusive(source, destination):
    require(source.is_file() and not source.is_symlink(), "unsafe archive source")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as incoming, destination.open("xb") as outgoing:
        while True:
            block = incoming.read(1024 * 1024)
            if not block:
                break
            outgoing.write(block)


def preserve_failure(seal, temporary):
    """Copy evidence; keep the original raw streams and temporary VVPs intact."""
    ARCHIVE.mkdir(parents=True, exist_ok=False)
    for relative in [*seal["pre_execution_sha256"], SEAL.name]:
        copy_exclusive(P / relative, ARCHIVE / "sources" / relative)
    copy_exclusive(RECEIPT, ARCHIVE / "verification_attempt02.json")
    for source in REPORTS.iterdir():
        require(source.is_file(), "unexpected nested attempt02 report")
        copy_exclusive(source, ARCHIVE / "reports" / source.name)
    if temporary is not None:
        for source in temporary.iterdir():
            require(source.name in {f"p{index}.vvp" for index in range(5)},
                    "unexpected temporary artifact")
            copy_exclusive(source, ARCHIVE / "artifacts" / source.name)
    exclusive_json(ARCHIVE / "ARCHIVE.json", {
        "schema": "anscore-b28-repair-attempt02-failure-archive-v1",
        "status": read(RECEIPT)["status"],
        "receipt_sha256": sha(RECEIPT),
        "original_receipt_sha256": sha(P / "verification.json"),
        "repair_seal_sha256": sha(SEAL),
        "automatic_retry": False,
        "original_temporary_artifacts_retained": True,
        "files_sha256": {path.relative_to(ARCHIVE).as_posix(): sha(path)
                         for path in sorted(ARCHIVE.rglob("*")) if path.is_file()},
    })


def run(args):
    require(os.name == "nt", "this approved Job Object workflow requires Windows")
    require(sys.flags.optimize == 0, "reviewed helper assertions require normal Python")
    seal, plan = read(SEAL), read(PLAN)
    paths = validate_inputs(seal, plan)
    approval = validate_approval(Path(args.approval), args.approval_sha256,
                                 args.approved_seal, seal, plan)
    require(not RECEIPT.exists() and not REPORTS.exists() and not ARCHIVE.exists(),
            "attempt02 was already claimed; no retry permitted")
    REPORTS.mkdir(parents=False, exist_ok=False)
    exclusive_json(REPORTS / "claim.json", {
        "status": "CLAIMED_NO_RETRY", "approval": str(approval),
        "approval_sha256": args.approval_sha256,
        "repair_seal_sha256": sha(SEAL), "repair_plan_sha256": sha(PLAN),
        "cwd": str(P), "fixed_children": 20, "automatic_retry": False,
    })
    receipt = {
        "schema": "anscore-b28-repair-attempt02-receipt-v1",
        "attempt": "attempt02", "status": "IN_PROGRESS", "hardware": "HW_UNVERIFIED",
        "baseline": plan["baseline"], "approval_sha256": args.approval_sha256,
        "repair_seal_sha256": sha(SEAL), "repair_plan_sha256": sha(PLAN),
        "original_receipt_sha256": sha(P / "verification.json"),
        "original_archive_sha256": sha(P / "failure_archive/attempt_01/ARCHIVE.json"),
        "source_sha256": seal["current_43_input_sha256"],
        "carried_forward_original_indices": [0, 1, 2],
        "carried_forward_names": ["stored_enumeration", "tool_version", "production_lint"],
        "carried_forward_reexecuted": False,
        "timeout_seconds": 20, "terminal_timeout": False, "automatic_retry": False,
        "first_failure_stops": True, "records": [
            {"name": child["name"], "original_index": index + 3, "status": "NOT_RUN"}
            for index, child in enumerate(plan["children"])],
        "results": [], "temporary_artifacts_deleted": False,
        "claim_sha256": sha(REPORTS / "claim.json"),
    }
    temporary = None
    record = None
    with RECEIPT.open("x", encoding="utf-8", newline="\n") as stream:
        def persist():
            stream.seek(0)
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.truncate()
            stream.flush()
            os.fsync(stream.fileno())

        persist()
        try:
            temporary = Path(tempfile.mkdtemp(prefix="b28-root-matching-attempt02-", dir=R / ".git"))
            receipt["path_expansion"] = {**paths, "{TMP}": temporary.as_posix()}
            persist()
            helpers = import_reviewed_helpers()
            environment = os.environ.copy()
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            bundle = R / "tools/oss-cad-suite/oss-cad-suite"
            environment["PATH"] = (str(bundle / "bin") + os.pathsep + str(bundle / "lib")
                                   + os.pathsep + environment.get("PATH", ""))
            for index, child in enumerate(plan["children"]):
                require(sha(SEAL) == args.approved_seal, "approved repair seal changed before child")
                validate_inputs(seal, plan)
                record = receipt["records"][index]
                argv = [paths.get(value, value).replace("{TMP}", temporary.as_posix())
                        for value in child["argv"]]
                record.update(argv=argv, status="RUNNING", timeout_seconds=20)
                persist()
                metadata, stdout, stderr = helpers.run_child({"argv": argv, "cwd": str(P)}, environment)
                record.update(returncode=metadata["exit_code"], elapsed_seconds=metadata["elapsed_seconds"],
                              supervision=metadata["supervision"], launch_error=metadata["launch_error"],
                              timeout=metadata["timed_out"], status="OBSERVED")
                if metadata["timed_out"]:
                    receipt["terminal_timeout"] = True
                    record["status"] = "TIMEOUT"
                for name, data in (("stdout", stdout), ("stderr", stderr)):
                    path = REPORTS / f"{index:02d}_{child['name']}.{name}"
                    with path.open("xb") as raw:
                        raw.write(data)
                    record[name] = path.relative_to(P).as_posix()
                    record[name + "_sha256"] = sha(path)
                    record[name + "_bytes"] = len(data)
                persist()
                require(sha(SEAL) == args.approved_seal, "approved repair seal changed during child")
                validate_inputs(seal, plan)
                require(not record["timeout"], "terminal 20s process-tree timeout")
                require(record["launch_error"] is None, "child launch or supervision error")
                require(record["supervision"].get("contained_before_resume") is True,
                        "child was not contained before resume")
                require(record["elapsed_seconds"] < 20, "terminal 20s elapsed-time gate")
                if child["kind"] == "reject":
                    require(record["returncode"] is not None and record["returncode"] > 0
                            and MARKER in stdout + stderr, "named parameter rejection failed")
                else:
                    require(record["returncode"] == 0 and stderr == b"",
                            "positive child returncode or empty-stderr gate failed")
                    if child["kind"] == "simulation":
                        receipt["results"].append(helpers.summarize(child, stdout.decode("utf-8"), plan))
                    else:
                        require(stdout == b"", "positive compilation stdout was not empty")
                if child["kind"] == "compile":
                    record["artifact_sha256"] = sha(temporary / f"p{child['profile']}.vvp")
                record["status"] = "EXPECTED_REJECT" if child["kind"] == "reject" else "PASS"
                persist()
            require(len(receipt["results"]) == 8, "simulation result inventory")
            report_names = {"claim.json"}
            require(sha(REPORTS / "claim.json") == receipt["claim_sha256"], "claim bytes changed")
            for completed in receipt["records"]:
                for name in ("stdout", "stderr"):
                    path = P / completed[name]
                    require(sha(path) == completed[name + "_sha256"]
                            and path.stat().st_size == completed[name + "_bytes"],
                            "actual raw stream changed")
                    report_names.add(path.name)
            require({path.name for path in REPORTS.iterdir()} == report_names,
                    "unexpected attempt02 raw report inventory")
            require(sha(SEAL) == args.approved_seal, "approved repair seal changed at completion")
            validate_inputs(seal, plan)
            require(temporary.resolve().parent == (R / ".git").resolve()
                    and temporary.name.startswith("b28-root-matching-attempt02-"),
                    "temporary artifacts outside intended workspace")
            artifacts = {f"p{child['profile']}.vvp": rec["artifact_sha256"]
                         for child, rec in zip(plan["children"], receipt["records"], strict=True)
                         if child["kind"] == "compile"}
            require({path.name for path in temporary.iterdir()} == set(artifacts),
                    "unexpected temporary artifact inventory")
            for name, digest in artifacts.items():
                path = temporary / name
                require(path.is_file() and not path.is_symlink() and sha(path) == digest,
                        "compiled artifact changed before cleanup")
            receipt["temporary_artifact_sha256"] = artifacts
            persist()
            for name in artifacts:
                (temporary / name).unlink()
            temporary.rmdir()
            receipt.update(status="UNIT_SIM_PASS", completed_children=20,
                           max_child_seconds=max(item["elapsed_seconds"] for item in receipt["records"]),
                           totals=plan["totals"], temporary_artifacts_deleted=True)
            persist()
        except BaseException as error:
            receipt["status"] = "TIMEOUT_TERMINAL" if receipt["terminal_timeout"] else "FAIL_STOPPED"
            receipt["failure"] = {"type": type(error).__name__, "message": str(error)}
            if record is not None and record["status"] not in ("TIMEOUT", "PASS", "EXPECTED_REJECT"):
                record["status"] = "FAIL"
            persist()
            try:
                preserve_failure(seal, temporary)
            except BaseException as archive_error:
                receipt["archive_error"] = {"type": type(archive_error).__name__, "message": str(archive_error)}
                persist()
            raise
    print("UNIT_SIM_PASS attempt=02 children=20 simulations=8 carried_forward=3")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--approval", required=True)
    parser.add_argument("--approval-sha256", required=True)
    parser.add_argument("--approved-seal", required=True)
    run(parser.parse_args())
