#!/usr/bin/env python3
"""Check an explicit source snapshot; optionally compile only its exported files.

Reads committed blobs rather than trusting unrelated worktree files. Does not
invoke synthesis, timing, implementation or hardware tools.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = "docs/snapshots/source_20261104.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_evidence_rules(report, rules):
    """Check explicit finite evidence records, including expected rejections."""
    required_status = rules.get("required_status", "UNIT_SIM_PASS")
    require(required_status in ("UNIT_SIM_PASS", "LINT_PASS"), "unsupported evidence maturity")
    if "status_alias" in rules:
        # Preserve raw receipts. Only the explicit successful finite-tool label
        # may be normalized; failures/timeouts can never acquire maturity here.
        alias = rules["status_alias"]
        require(isinstance(alias, dict) and alias == {"raw": "PASS", "maturity": "UNIT_SIM_PASS"},
                "unsupported evidence status alias")
        require(required_status == "UNIT_SIM_PASS" and report["status"] == "PASS",
                "raw evidence status is not the declared successful label")
    else:
        require(required_status in report["status"], f"required evidence missing: {required_status}")
    for field, expected in rules.get("equal", {}).items():
        require(report[field] == expected, f"unexpected evidence summary: {field}")
    for rule in rules["collections"]:
        records = report[rule["field"]]
        require(len(records) == rule["count"], f"missing evidence records: {rule['field']}")
        if "status_field" in rule:
            require(all(r[rule["status_field"]] == rule["pass_value"] for r in records), "failed finite check")
        failures = 0
        for record in records:
            if "returncode_field" in rule and record[rule["returncode_field"]] != 0:
                combined = "\n".join(record.get(k, "") for k in ("stdout", "stderr", "output"))
                marker = rule.get("expected_failure_marker")
                require(record[rule["returncode_field"]] > 0 and marker and marker in combined,
                        "unexpected tool failure")
                failures += 1
        require(failures == rule.get("expected_failures", 0), "missing expected rejection evidence")
        for marker in rule.get("markers", []):
            count = sum(marker["text"] in "\n".join(r.get(k, "") for k in ("stdout", "stderr", "output")) for r in records)
            require(count == marker["count"], f"missing completion marker {marker['text']}")


def safe_path(value):
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value or ":" in value or any(c in value for c in "\r\n\0"):
        raise ValueError(f"unsafe snapshot path: {value}")
    return path


def dependency_path(root, relative):
    """Resolve a sibling reference; callers must also require export membership."""
    if (not relative or PurePosixPath(relative).is_absolute() or
            "\\" in relative or ":" in relative or any(c in relative for c in "\r\n\0")):
        raise ValueError(f"unsafe dependency path: {relative}")
    return safe_path(posixpath.normpath(root+"/"+relative)).as_posix()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD", help="committed Git ref to inspect")
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST)
    parser.add_argument("--compile", action="store_true", help="bounded Icarus checks of isolated export")
    args = parser.parse_args()

    def git_bytes(*command):
        return subprocess.run(["git", *command], cwd=REPO, capture_output=True, check=True, timeout=15).stdout

    commit = git_bytes("rev-parse", "--verify", args.ref+"^{commit}").decode().strip()
    safe_path(args.manifest)

    def blob(path):
        safe_path(path)
        return git_bytes("show", commit+":"+path)

    manifest = json.loads(blob(args.manifest))
    packages = manifest["packages"]
    # Fetch the explicit manifest closure in one Git process. The payloads are
    # still committed blobs; unrelated worktree files cannot satisfy a source.
    requested = []
    for package in packages:
        safe_path(package["path"])
        for relative in package["sha256"]:
            safe_path(relative)
            requested.append(package["path"]+"/"+relative)
    for path in manifest.get("support_files", {}):
        safe_path(path)
        requested.append(path)
    requested = list(dict.fromkeys(requested))
    batch = subprocess.run(["git", "cat-file", "--batch"], cwd=REPO,
                           input="".join(commit+":"+p+"\n" for p in requested).encode(),
                           capture_output=True, check=True, timeout=15).stdout
    committed = {}
    offset = 0
    for path in requested:
        end = batch.index(b"\n", offset)
        header = batch[offset:end].split()
        require(len(header) == 3 and header[1] == b"blob", f"missing committed file {path}")
        size = int(header[2])
        start = end+1
        require(len(batch) > start+size and batch[start+size] == 10, "incomplete Git blob response")
        committed[path] = batch[start:start+size]
        offset = start+size+1
    exports, source_paths, tops = {}, [], []
    # Assemble the entire approved closure before resolving cross-package use.
    # No worktree file or unlisted sibling can satisfy a dependency.
    for path, digest in manifest.get("support_files", {}).items():
        data = committed[path]
        require(hashlib.sha256(data).hexdigest() == digest, f"support digest mismatch: {path}")
        exports[path] = data
    for package in packages:
        root = safe_path(package["path"]).as_posix()
        require(package["hardware_status"] == "HW_UNVERIFIED", "unexpected hardware claim")
        for relative, digest in package["sha256"].items():
            safe_path(relative)
            path = root+"/"+relative
            data = committed[path]
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"snapshot digest mismatch: {path}")
            exports[path] = data
    for package in packages:
        root = safe_path(package["path"]).as_posix()
        report = json.loads(exports[root+"/"+package["evidence"]])
        for field in ["source_sha256", *package.get("evidence_dependency_fields", [])]:
            for relative, digest in report[field].items():
                full = dependency_path(root, relative.replace("\\", "/"))
                require(full in exports, f"evidence dependency not exported: {full}")
                if hashlib.sha256(exports[full]).hexdigest() != digest:
                    raise ValueError(f"stale unit evidence: {full}")
        # Check success records as well as the label; no missing record is PASS.
        if "evidence_rules" in package:
            check_evidence_rules(report, package["evidence_rules"])
        elif package["evidence_kind"] == "multicast":
            require(len(report["checks"]) == 8 and all(c["status"] == "PASS" for c in report["checks"]), "incomplete multicast evidence")
            require(sum("PASS stream_multicast" in c["output"] for c in report["checks"]) == 3, "missing multicast simulation completions")
        elif package["evidence_kind"] == "heap":
            require(len(report["cases"]) == 8 and all(c["status"] == "UNIT_SIM_PASS" for c in report["cases"]), "incomplete heap cases")
            require(len(report["commands"]) == 19 and all(c["exit_code"] == 0 for c in report["commands"]), "failed heap command")
        elif package["evidence_kind"] == "cdf53":
            require(len(report["checks"]) == 25 and all(c["status"] == "PASS" for c in report["checks"]), "incomplete CDF53 evidence")
            require(sum("sample_w" in c for c in report["checks"]) == 18, "missing CDF53 numerical cases")
            require(any("PASS roundtrip samples=64" in c.get("result", "") for c in report["checks"]), "missing CDF53 connected test")
        elif package["evidence_kind"] == "ssim":
            require(report["blocks"] == 66 and "UNIT_SIM_PASS" in report["status"], "incomplete SSIM evidence")
            require(len(report["commands"]) == 16, "missing SSIM commands")
            numerical, rejected = 0, 0
            for command in report["commands"]:
                text = command["stdout"] + command["stderr"]
                if command["returncode"] != 0:
                    require(command["returncode"] == 1 and "invalid stream_ssim parameters" in text and
                            "invalid_" in command["command"][-1], "unexpected SSIM command failure")
                    rejected += 1
                if "PASS SSIM" in text:
                    require("blocks=22" in text, "incomplete SSIM numerical run")
                    numerical += 1
            require(numerical == 3 and rejected == 4, "missing SSIM completions/rejections")
        else:
            raise ValueError("unsupported evidence kind")
        for source_list in ["files.f", *package.get("additional_source_lists", [])]:
            list_path = dependency_path(root, source_list)
            require(list_path in exports, f"source list not exported: {list_path}")
            for line in exports[list_path].decode().splitlines():
                line = line.strip()
                if not line or line.startswith(("#", "//")):
                    continue
                full = dependency_path(root, line)
                if full not in exports:
                    raise ValueError(f"dependency not exported: {full}")
                source_paths.append(full)
        for example in package["examples"]:
            path = dependency_path(root, example["file"])
            if path not in exports:
                raise ValueError(f"missing example {path}")
            source_paths.append(path)
            tops.append(example["top"])
        tops.append(package["top"])
        maturity = package.get("evidence_rules", {}).get("required_status", "UNIT_SIM_PASS")
        numeric = f"; numeric={report['numeric_status']}" if "numeric_status" in report else ""
        print(f"PASS {package['top']}: committed files, offline closure, current {maturity} evidence{numeric}", flush=True)

    # Reuse of the same approved source is legal; conflicting declarations in
    # different files remain errors. Pass shared modules to the compiler once.
    source_paths = list(dict.fromkeys(source_paths))
    declarations = {}
    for path in source_paths:
        for name in re.findall(rb"(?m)^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)", exports[path]):
            key = name.decode()
            if key in declarations:
                raise ValueError(f"module collision {key}: {declarations[key]}, {path}")
            declarations[key] = path

    if args.compile:
        suite = REPO / "tools/oss-cad-suite/oss-cad-suite"
        env = os.environ.copy()
        env["PATH"] = os.pathsep.join([str(suite/"bin"),str(suite/"lib"),env.get("PATH", "")])
        compiler = os.environ.get("IVERILOG") or shutil.which("iverilog", path=env["PATH"])
        if not compiler:
            raise RuntimeError("NOT_RUN: Icarus Verilog is unavailable")
        with tempfile.TemporaryDirectory(prefix="anscore_source_snapshot_") as temporary:
            target = Path(temporary)
            for path, data in exports.items():
                destination = target/path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            command = [compiler,"-g2012","-Wall","-tnull"]
            for top in tops:
                command.extend(["-s", top])
            command.extend(source_paths)
            result = subprocess.run(command,cwd=target,env=env,capture_output=True,text=True,timeout=20)
            if result.returncode:
                raise RuntimeError(result.stdout+result.stderr)
            # Keep successful compiler diagnostics visible in the frozen log.
            # Reused delay-free RTL can legitimately lack a timescale.
            for diagnostic in (result.stdout, result.stderr):
                if diagnostic:
                    print(diagnostic, end="" if diagnostic.endswith("\n") else "\n")
            print(f"PASS isolated export compile: {len(tops)} tops, {len(source_paths)} source files")
    print(f"PASS source snapshot {commit}; HW_UNVERIFIED")


if __name__ == "__main__":
    main()
