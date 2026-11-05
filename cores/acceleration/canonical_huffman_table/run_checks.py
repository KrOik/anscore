#!/usr/bin/env python3
"""Finite compile/unit checks; no synthesis or implementation tools."""
# SPDX-License-Identifier: Apache-2.0
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
CONFIGS = [(1, 1), (8, 4), (19, 8), (256, 16)]


def vectors(symbols, bits):
    """Histogram/Kraft oracle, independent of RTL's ordered serial scan."""
    staging = [0] * symbols
    active = None
    records = []

    def command(op, symbol=0, length=0):
        nonlocal active
        status, code, olen = 0, 0, 0
        if op in (0, 2) and symbol >= symbols:
            status = 1
        elif op == 0:
            if length > bits:
                status = 2
            else:
                staging[symbol] = length
        elif op == 1:
            counts = [staging.count(i) for i in range(bits + 1)]
            left = 1
            for width in range(1, bits + 1):
                left = 2 * left - counts[width]
                if left < 0:
                    break
            if left < 0 or counts[0] == symbols:
                status = 3
            else:
                next_codes = [0] * (bits + 1)
                first = 0
                counts[0] = 0
                for width in range(1, bits + 1):
                    first = (first + counts[width-1]) * 2
                    next_codes[width] = first
                active = {}
                for sym, width in enumerate(staging):
                    if width:
                        active[sym] = (next_codes[width], width)
                        next_codes[width] += 1
        elif op == 2:
            if active is None:
                status = 4
            elif symbol not in active:
                status = 5
            else:
                code, olen = active[symbol]
        elif op == 3:
            staging[:] = [0] * symbols
            active = None
        records.append((op, symbol, length, len(records) % 256, status, code, olen))

    command(2)
    command(0, 0xffffffff, 0)
    command(2, 0xffffffff)
    command(0, 0, bits+1)
    command(0, 0, 0xffffffff)
    command(1)  # empty tree
    command(0, 0, bits)
    command(1)  # incomplete tree including maximum length
    command(2)
    for sym in range(1, symbols):
        command(2, sym)  # absent symbols
    if symbols >= bits + 1:
        # A complete comb tree reaches the largest MAX_BITS-bit code, including
        # 0xffff at the maximum profile; random shallow trees need not reach it.
        command(3)
        depths = list(range(1, bits)) + [bits, bits]
        for sym, depth in enumerate(reversed(depths)):
            command(0, sym, depth)
        command(1)
        for sym in range(symbols):
            command(2, sym)
    rng = random.Random(0xC31 + symbols)
    # Valid complete trees are formed by splitting leaves; random symbol order
    # exercises canonical ties and zeros. Also test full capacity at depth1.
    for iteration in range(12):
        command(3, 0xffffffff, 0xffffffff)
        depths = [1, 1] if symbols >= 2 else [1]
        while len(depths) < min(symbols, 2 + iteration):
            choices = [i for i, x in enumerate(depths) if x < bits]
            if not choices:
                break
            i = rng.choice(choices)
            d = depths.pop(i) + 1
            depths.extend([d, d])
        positions = rng.sample(range(symbols), len(depths))
        for sym, depth in zip(positions, depths):
            command(0, sym, depth)
        command(1)
        for sym in range(symbols):
            command(2, sym)
        if symbols >= 3:
            # Oversubscribe the staging tree; failed BUILD must preserve active.
            for sym in range(symbols):
                command(0, sym, 1)
            command(1)
            for sym in range(symbols):
                command(2, sym)
        # LOAD never changes active lookup before a successful BUILD.
        command(0, positions[0], 0)
        command(2, positions[0])
    command(3)
    command(2)
    return "".join(" ".join(map(str, row)) + "\n" for row in records), len(records)


def main():
    bindir = REPO / "tools/oss-cad-suite/oss-cad-suite/bin"
    compiler = str(bindir / "iverilog.exe") if (bindir / "iverilog.exe").is_file() else (shutil.which("iverilog") or "iverilog")
    simulator = str(bindir / "vvp.exe") if (bindir / "vvp.exe").is_file() else (shutil.which("vvp") or "vvp")
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(bindir), str(bindir.parent / "lib"), env.get("PATH", "")])
    reports = []
    stopped = False
    source_paths = ["rtl/canonical_huffman_table.sv", "sim/tb_canonical_huffman_table.sv",
                    "example/huffman_byte_table.sv", "files.f", "example/files.f", "run_checks.py"]
    hashes = {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in source_paths}

    def run(label, argv):
        nonlocal stopped
        if stopped:
            return False
        started = time.monotonic()
        try:
            proc = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                out, err = proc.communicate(timeout=20)
                status = "PASS" if proc.returncode == 0 else "FAIL"
            except subprocess.TimeoutExpired:
                cleanup_errors = []
                try:
                    if os.name == "nt":
                        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, timeout=5)
                    else:
                        proc.kill()
                except (OSError, subprocess.SubprocessError) as exc:
                    cleanup_errors.append(str(exc))
                    proc.kill()
                try:
                    out, err = proc.communicate(timeout=5)
                except subprocess.TimeoutExpired as exc:
                    out, err = exc.stdout or b"", exc.stderr or b""
                    cleanup_errors.append("output collection timed out after termination")
                if cleanup_errors:
                    err += ("\n"+"\n".join(cleanup_errors)).encode()
                status = "TIMEOUT"
            record = dict(label=label, argv=list(map(str, argv)), status=status,
                          returncode=proc.returncode, seconds=round(time.monotonic()-started, 4),
                          stdout=out.decode(errors="replace"), stderr=err.decode(errors="replace"))
        except OSError as exc:
            record = dict(label=label, argv=list(map(str, argv)), status="NOT_RUN", error=str(exc))
        reports.append(record)
        if record["status"] != "PASS":
            stopped = True
        return record["status"] == "PASS"

    with tempfile.TemporaryDirectory(prefix="b31_huffman_") as directory:
        directory = Path(directory)
        ok = run("rtl_syntax", [compiler, "-g2012", "-Wall", "-tnull", "-s", "canonical_huffman_table", "-f", "files.f"])
        ok = run("example_syntax", [compiler, "-g2012", "-Wall", "-tnull", "-s", "huffman_byte_table", "-f", "example/files.f"]) and ok
        vector_counts = []
        for symbols, bits in CONFIGS:
            if stopped:
                break
            data, count = vectors(symbols, bits)
            vector_counts.append(dict(symbols=symbols, max_bits=bits, vector_commands=count,
                                      vector_sha256=hashlib.sha256(data.encode()).hexdigest()))
            path = directory / f"vectors_{symbols}_{bits}.txt"
            path.write_text(data, encoding="ascii")
            binary = directory / f"sim_{symbols}_{bits}.vvp"
            label = f"s{symbols}_b{bits}"
            compiled = run(label+"_compile", [compiler, "-g2012", "-Wall", "-s", "tb_canonical_huffman_table",
                          f"-Ptb_canonical_huffman_table.SYMBOLS={symbols}",
                          f"-Ptb_canonical_huffman_table.MAX_BITS={bits}", "-o", str(binary),
                          "-f", "files.f", "sim/tb_canonical_huffman_table.sv"])
            if compiled:
                passed = run(label+"_simulate", [simulator, str(binary), f"+vectors={path.as_posix()}"])
                passed = passed and "PASS canonical_huffman_table" in reports[-1]["stdout"]
                if not passed:
                    reports[-1]["status"] = "FAIL"
                    stopped = True
                ok = passed and ok
            else:
                ok = False
    result = dict(schema=1, created_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  status=["LINT_PASS", "UNIT_SIM_PASS", "HW_UNVERIFIED"] if ok else ["CHECK_FAILED", "HW_UNVERIFIED"],
                  tool_scope="Icarus syntax and finite unit simulation only",
                  source_sha256=hashes, configs=vector_counts, checks=reports,
                  synthesis="NOT_RUN", pnr="NOT_RUN", sta="NOT_RUN", board="NOT_RUN")
    output = ROOT / "check_results.json"
    # Preserve earlier ordinary failure receipts if a corrected source is checked.
    if output.exists():
        archive = ROOT / "history"
        archive.mkdir(exist_ok=True)
        (archive / ("checks_" + hashlib.sha256(output.read_bytes()).hexdigest()[:12] + ".json")).write_bytes(output.read_bytes())
    output.write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "checks": len(reports), "result": str(output)}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
