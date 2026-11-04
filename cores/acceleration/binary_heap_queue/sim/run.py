#!/usr/bin/env python3
"""Bounded source checks and finite unit simulations; no synthesis invocation."""
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]


def tools():
    env = os.environ.copy()
    suite = REPO / "tools/oss-cad-suite/oss-cad-suite"
    suffix = ".exe" if os.name == "nt" else ""
    if (suite / f"bin/iverilog{suffix}").is_file():
        env["PATH"] = os.pathsep.join([str(suite / "bin"), str(suite / "lib"), env.get("PATH", "")])
    iv = os.environ.get("IVERILOG") or shutil.which("iverilog", path=env["PATH"])
    vvp = os.environ.get("VVP") or shutil.which("vvp", path=env["PATH"])
    if not iv or not vvp:
        raise RuntimeError("NOT_RUN: Icarus Verilog and vvp required")
    return iv, vvp, env


def vectors(capacity, key_w, data_w, signed):
    rng = random.Random(0x48454150 + capacity + key_w)
    mask_k, mask_d = (1 << key_w) - 1, (1 << data_w) - 1
    entries, lines = [], []

    def order(entry):
        key, data = entry
        if signed and key & (1 << (key_w - 1)):
            key -= 1 << key_w
        return key, data

    def command(op, key=0, data=0):
        key, data = key & mask_k, data & mask_d
        status, result = 0, (0, 0)
        if op == 0:
            result = key, data
            if len(entries) == capacity:
                status = 1
            else:
                entries.append(result)
        elif op in (1, 2):
            if not entries:
                status = 2
            else:
                result = min(entries, key=order)
                if op == 1:
                    entries.remove(result)
        else:
            entries.clear()
        lines.append(f"{op} {key:x} {data:x} {status} {result[0]:x} {result[1]:x} {len(entries)}\n")

    command(1)
    command(2)
    # Fill/reject, equal-key payload ties, negative extrema, non-power-of-two
    # capacities, clear/reuse and exact drain under interleaved commands.
    for variant in range(4):
        command(3)
        for i in range(capacity + 2):
            key = [i, capacity-i, 1 << (key_w-1), mask_k][variant]
            command(0, key, capacity-i)
            command(2)
        for _ in range(capacity + 2):
            command(1)
    for _ in range(400):
        op = rng.choices([0, 1, 2, 3], [48, 35, 15, 2])[0]
        command(op, rng.getrandbits(key_w), rng.getrandbits(data_w))
    while entries:
        command(1)
    command(1)
    return "".join(lines), len(lines)


def main():
    report_path = ROOT / "reports/validation.json"
    if report_path.exists():
        report_path.unlink()  # stale PASS is never retained after a failed rerun
    iv, vvp, env = tools()
    commands, cases = [], []

    def run(args, cwd=ROOT):
        result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, timeout=15)
        commands.append({"argv": [str(x) for x in args], "exit_code": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout

    version = run([iv, "-V"]).splitlines()[0]
    with tempfile.TemporaryDirectory(prefix="anscore_heap_") as temporary:
        work = Path(temporary)
        run([iv, "-g2012", "-Wall", "-tnull", "-s", "binary_heap_queue", "-f", "files.f"])
        run([iv, "-g2012", "-Wall", "-tnull", "-s", "binary_heap_queue_example", "-f", "files.f",
             "examples/binary_heap_queue_example.sv"])
        for capacity, key_w, data_w, signed in [(1,1,1,0),(2,4,8,1),(3,8,8,0),
                (5,8,16,1),(8,16,1,1),(17,5,9,0),(32,16,32,1),(32,16,32,0)]:
            config = dict(CAPACITY=capacity, KEY_W=key_w, DATA_W=data_w, SIGNED_KEY=signed)
            content, n = vectors(capacity, key_w, data_w, signed)
            vector_path, image = work / "vectors.txt", work / "sim.vvp"
            vector_path.write_text(content, encoding="ascii")
            run([iv, "-g2012", "-Wall", "-s", "tb_binary_heap_queue", "-o", str(image),
                 *[f"-Ptb_binary_heap_queue.{k}={v}" for k,v in config.items()],
                 "-f", "files.f", "sim/tb_binary_heap_queue.sv"])
            output = run([vvp, str(image), f"+VECTORS={vector_path.as_posix()}"])
            if f"PASS commands={n} reset_cancellation_cases=26" not in output:
                raise RuntimeError("simulation did not emit its completion marker")
            cases.append({"parameters": config, "vector_commands": n, "reset_cases": 26,
                          "status": "UNIT_SIM_PASS", "stdout": output.strip(),
                          "vectors_sha256": hashlib.sha256(content.encode("ascii")).hexdigest()})
            print(config, output.strip(), flush=True)
    files = ["rtl/binary_heap_queue.sv", "examples/binary_heap_queue_example.sv",
             "files.f", "sim/run.py", "sim/tb_binary_heap_queue.sv"]
    report = {"date": "2026-11-04", "tool": version, "status": ["LINT_PASS","UNIT_SIM_PASS","HW_UNVERIFIED"],
              "scope": "Icarus syntax/elaboration and finite deterministic RTL tests only",
              "source_sha256": {p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files},
              "cases":cases, "commands":commands,
              "not_run":["synthesis","place_and_route","STA","hardware"]}
    for command in commands:
        command["argv"] = [arg.replace(str(work), "<temporary>").replace(work.as_posix(), "<temporary>")
                           for arg in command["argv"]]
    report_path.parent.mkdir(exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError) as exc:
        failed = ROOT / "reports/validation.json"
        failed.parent.mkdir(exist_ok=True)
        status = "NOT_RUN_TIMEOUT" if isinstance(exc, subprocess.TimeoutExpired) else "CHECK_FAILED_OR_NOT_RUN"
        failed.write_text(json.dumps({"status":status,"detail":str(exc),"hardware":"HW_UNVERIFIED"},indent=2)+"\n",encoding="utf-8")
        print(f"CHECK_FAILED_OR_NOT_RUN: {exc}", file=sys.stderr)
        sys.exit(1)
