"""Run the narrow stream/bus scaffold regression using only Python stdlib."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, help="New directory; existing directories are rejected")
    parser.add_argument("--iverilog", type=Path)
    parser.add_argument("--vvp", type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    suite = root / "tools/oss-cad-suite/oss-cad-suite"
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join([str(suite / "bin"), str(suite / "lib"), env.get("PATH", "")])

    def executable(explicit: Path | None, name: str) -> str:
        if explicit:
            return str(explicit.resolve())
        bundled = suite / "bin" / (name + (".exe" if os.name == "nt" else ""))
        found = str(bundled) if bundled.is_file() else shutil.which(name, path=env["PATH"])
        if not found:
            raise FileNotFoundError(f"{name} is not available")
        return found

    iverilog = executable(args.iverilog, "iverilog")
    vvp = executable(args.vvp, "vvp")
    output = args.output_dir or here / "evidence" / datetime.now(timezone.utc).strftime("sim_%Y%m%dT%H%M%S_%fZ")
    output = output.resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error(f"output directory already exists; choose a new path: {output}")
    sources = sorted((here / "rtl").glob("*.v"))
    cases = [("stream", "tb_sb_stream", []), ("width", "tb_sb_width", []),
             ("arbiter", "tb_sb_arbiter", []), ("axil_registers", "tb_sb_axil", []),
             ("axil_crossbar", "tb_sb_crossbar", []),
             ("axi4_ram", "tb_sb_axi4_memory", []),
             ("axi4_native", "tb_sb_axi4_memory", ["-Ptb_sb_axi4_memory.EXTERNAL_NATIVE=1"]),
             ("invalid_width_rejected", "tb_sb_invalid_width", [])]
    results = []
    for name, top, params in cases:
        binary = output / f"{name}.vvp"
        compile_cmd = [iverilog, "-g2012", "-s", top, *params, "-o", str(binary),
                       *map(str, sources), str(here / "sim" / f"{top}.sv")]
        commands = [compile_cmd, [vvp, str(binary)]]
        steps = []
        for label, cmd in zip(("compile", "simulate"), commands):
            try:
                result = subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True, timeout=60)
                log = result.stdout + result.stderr
                if name == "invalid_width_rejected" and label == "simulate":
                    passed = result.returncode != 0 and "byte widths with integer ratio required" in log
                else:
                    passed = result.returncode == 0 and (label == "compile" or "PASS " in result.stdout)
                code = result.returncode
            except subprocess.TimeoutExpired as exc:
                log, passed, code = str(exc), False, None
            (output / f"{name}_{label}.log").write_text(log, encoding="utf-8")
            steps.append({"stage": label, "command": cmd, "returncode": code, "passed": passed})
            if not passed:
                break
        passed = len(steps) == 2 and all(step["passed"] for step in steps)
        results.append({"name": name, "passed": passed, "steps": steps})
        print(f"{'PASS' if passed else 'FAIL'} {name}")
    source_hashes = {p.relative_to(here).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [*sources, *sorted((here / "sim").glob("*.sv"))]}
    summary = {"scope": "local stream, AXI-Lite routing and AXI4 memory group simulation only", "status": "pass" if all(r["passed"] for r in results) else "fail",
               "source_sha256": source_hashes,
               "synthesis": "not_run", "board": "not_run", "results": results}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"Evidence: {output}")
    return 0 if summary["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
