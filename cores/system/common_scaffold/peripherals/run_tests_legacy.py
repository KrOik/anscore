#!/usr/bin/env python3
"""Compile the peripheral scaffold and run bounded, assertion-driven simulation."""
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
import time

BASE = Path(__file__).resolve().parent
REPO = BASE.parents[2]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=60, help="Seconds per subprocess (default 60)")
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    evidence = BASE / "evidence" / stamp
    evidence.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    suite = REPO / "tools" / "oss-cad-suite" / "oss-cad-suite"
    env["PATH"] = os.pathsep.join((str(suite / "bin"), str(suite / "lib"), env.get("PATH", "")))
    sources = sorted((BASE / "rtl").glob("*.v"))
    testbench = BASE / "sim" / "tb_common_peripherals.sv"
    report = {
        "status": "RUNNING", "utc": stamp,
        "verification": "Icarus compilation and RTL assertion simulation only",
        "board_verified": False, "synthesis_run": False,
        "sources_sha256": {
            str(path.relative_to(BASE)).replace("\\", "/"): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sources + [testbench, Path(__file__).resolve()]
        },
        "steps": [],
    }

    def execute(label: str, command: list[str]) -> str:
        start = time.monotonic()
        log = evidence / (label + ".log")
        step = {"name": label, "command": command, "timeout_seconds": args.timeout}
        try:
            result = subprocess.run(command, cwd=REPO, env=env, capture_output=True,
                                    text=True, encoding="utf-8", errors="replace", timeout=args.timeout)
            output = result.stdout + result.stderr
            step["exit_code"] = result.returncode
            step["timed_out"] = False
        except subprocess.TimeoutExpired as exc:
            def decode(value):
                return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")
            output = decode(exc.stdout) + decode(exc.stderr) + "\nTIMEOUT\n"
            step["exit_code"] = None
            step["timed_out"] = True
        step["elapsed_seconds"] = round(time.monotonic() - start, 3)
        step["log"] = str(log.relative_to(BASE)).replace("\\", "/")
        log.write_text(output, encoding="utf-8")
        report["steps"].append(step)
        print(f"{label}: exit={step['exit_code']} elapsed={step['elapsed_seconds']}s")
        if step["timed_out"] or step["exit_code"] != 0:
            print(output, file=sys.stderr)
            raise RuntimeError(f"{label} failed; see {log}")
        return output

    try:
        # Resolve paths explicitly: Windows executable search does not consistently
        # honor a child-only PATH when an installed Chocolatey shim also exists.
        iverilog = shutil.which("iverilog", path=env["PATH"])
        vvp = shutil.which("vvp", path=env["PATH"])
        if not iverilog or not vvp:
            raise RuntimeError("iverilog and vvp are required; install OSS CAD Suite or add them to PATH")
        report["tools"] = {"iverilog": iverilog, "vvp": vvp}
        manifest = json.loads((BASE / "manifest.json").read_text(encoding="utf-8"))
        for unit in manifest["modules"]:
            name = unit["name"]
            execute("compile_" + name, [iverilog, "-g2012", "-s", name, "-o",
                    str(evidence / (name + ".vvp"))] + [str(p) for p in sources])
        # Width boundaries are elaboration checks, not claims of waveform coverage.
        for name, parameter in (("common_gpio", "WIDTH"), ("common_irq", "WIDTH"),
                                ("common_pwm", "COUNTER_WIDTH"), ("common_timer", "COUNTER_WIDTH")):
            for width in (1, 32):
                extra = [f"-P{name}.{parameter}={width}"]
                if name == "common_pwm":
                    extra += [f"-P{name}.RESET_PERIOD=1"]
                execute(f"width_{name}_{width}", [iverilog, "-g2012", "-s", name] + extra +
                        ["-o", str(evidence / f"{name}_{width}.vvp")] + [str(p) for p in sources])
        executable = evidence / "tb_common_peripherals.vvp"
        execute("compile_testbench", [iverilog, "-g2012", "-s", "tb_common_peripherals", "-o",
                str(executable)] + [str(p) for p in sources] + [str(testbench)])
        output = execute("simulation", [vvp, str(executable)])
        marker = "COMMON_PERIPHERALS PASS transactions=76 modules=9 functional=4 placeholder=5"
        if marker not in output:
            raise RuntimeError("Simulation returned zero without the complete assertion PASS marker")
        report["status"] = "PASS"
        report["checked_transactions"] = 76
        report["modules"] = [{"name": m["name"], "status": m["status"]} for m in manifest["modules"]]
        print(marker)
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = str(exc)
        print(str(exc), file=sys.stderr)
    finally:
        summary = evidence / "summary.json"
        summary.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"Evidence: {summary}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
