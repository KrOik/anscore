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
import re
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = "docs/snapshots/source_20261104.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(value):
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value or ":" in value:
        raise ValueError(f"unsafe snapshot path: {value}")
    return path


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
    exports, source_paths, tops = {}, [], []
    for package in packages:
        root = safe_path(package["path"]).as_posix()
        require(package["hardware_status"] == "HW_UNVERIFIED", "unexpected hardware claim")
        for relative, digest in package["sha256"].items():
            safe_path(relative)
            path = root+"/"+relative
            data = blob(path)
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"snapshot digest mismatch: {path}")
            exports[path] = data
        report = json.loads(exports[root+"/"+package["evidence"]])
        for relative, digest in report["source_sha256"].items():
            relative = relative.replace("\\", "/")
            if hashlib.sha256(exports[root+"/"+relative]).hexdigest() != digest:
                raise ValueError(f"stale unit evidence: {root}/{relative}")
        # Check success records as well as the label; no missing record is PASS.
        if package["evidence_kind"] == "multicast":
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
        closure = exports[root+"/files.f"].decode().splitlines()
        for line in closure:
            line = line.strip()
            if not line or line.startswith(("#", "//")):
                continue
            safe_path(line)
            full = root+"/"+line
            if full not in exports:
                raise ValueError(f"dependency not exported: {full}")
            source_paths.append(full)
        for example in package["examples"]:
            path = root+"/"+example["file"]
            if path not in exports:
                raise ValueError(f"missing example {path}")
            source_paths.append(path)
            tops.append(example["top"])
        tops.append(package["top"])
        print(f"PASS {package['top']}: committed files, offline closure, current unit evidence", flush=True)

    # New production modules must be unique across all four isolated packages.
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
            print(f"PASS isolated export compile: {len(tops)} tops, {len(source_paths)} source files")
    print(f"PASS source snapshot {commit}; HW_UNVERIFIED")


if __name__ == "__main__":
    main()
