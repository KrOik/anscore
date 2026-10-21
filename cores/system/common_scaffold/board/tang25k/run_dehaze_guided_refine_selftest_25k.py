#!/usr/bin/env python3
"""Simulate and build the guided-refinement UART self-test for Tang 25K."""
from __future__ import annotations

import argparse
import datetime
import json
import shutil
import subprocess
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BUILD_ROOT = HERE / "build"
RTL = ROOT / "projects" / "common_ip_scaffold" / "image" / "dehaze" / "img_dh_guided_refine.v"
SELFTEST = HERE / "dehaze_guided_refine_selftest_25k.v"
TB = HERE / "tb_dehaze_guided_refine_selftest_25k.sv"
CST = HERE / "tang25k.cst"
FLOW_DIR = ROOT / "projects" / "dsp_isp_library" / "board" / "tang25k"


def run_logged(command: list[str], dest: Path, log_name: str, timeout: int,
               env: dict[str, str]) -> None:
    with (dest / log_name).open("w", encoding="utf-8") as log:
        log.write("$ " + " ".join(command) + "\n")
        log.flush()
        subprocess.run(command, cwd=dest, env=env, stdout=log, stderr=subprocess.STDOUT,
                       timeout=timeout, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dest", type=Path,
        help="new empty build directory under cores/system/common_scaffold/board/tang25k/build",
    )
    args = parser.parse_args()

    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dest = (args.dest if args.dest is not None else
            BUILD_ROOT / ("dehaze_guided_refine_selftest_25k_" + stamp)).resolve()
    try:
        dest.relative_to(BUILD_ROOT.resolve())
    except ValueError as exc:
        raise SystemExit("--dest must be inside %s" % BUILD_ROOT) from exc
    if dest.exists() and any(dest.iterdir()):
        raise SystemExit("refusing to overwrite existing evidence: %s" % dest)
    for source in (RTL, SELFTEST, TB, CST, FLOW_DIR / "device_flow.py"):
        if not source.is_file():
            raise SystemExit("required source is missing: %s" % source)

    dest.mkdir(parents=True, exist_ok=True)
    for source in (RTL, SELFTEST, TB, CST):
        shutil.copy2(source, dest / source.name)
    sys.path.insert(0, str(FLOW_DIR))
    import device_flow

    staged_rtl = dest / "img_dh_guided_refine.v"
    staged_top = dest / SELFTEST.name
    staged_tb = dest / TB.name
    compiler = device_flow.resolve("iverilog")
    runtime = device_flow.resolve("vvp")
    env = device_flow.tool_env()
    simulation_timeout = 120
    sim = dest / "simulation.vvp"
    status: dict[str, object] = {
        "top": "dehaze_guided_refine_selftest_25k",
        "board": "Tang Primer 25K GW5A-LV25MG121NES",
        "clock_hz": 50000000,
        "uart_baud": 115200,
        "phase": "simulation_compile",
        "board_programming": "not_run",
        "build_directory": str(dest),
    }
    (dest / "run_status.json").write_text(json.dumps(status, indent=2) + "\n",
                                           encoding="utf-8")
    try:
        compile_cmd = [compiler, "-g2012", "-s", "tb_dehaze_guided_refine_selftest_25k",
                       "-o", str(sim), str(staged_rtl), str(staged_top), str(staged_tb)]
        with (dest / "simulation_compile.log").open("w", encoding="utf-8") as log:
            log.write("$ " + " ".join(compile_cmd) + "\n")
            log.flush()
            subprocess.run(compile_cmd, cwd=dest, env=env, stdout=log,
                           stderr=subprocess.STDOUT, timeout=simulation_timeout, check=True)
        status["phase"] = "simulation_run"
        (dest / "run_status.json").write_text(json.dumps(status, indent=2) + "\n",
                                               encoding="utf-8")
        run_logged([runtime, str(sim)], dest, "simulation_run.log", simulation_timeout, env)
        status["simulation"] = "PASS"
        status["phase"] = "GW5A-25_full_build"
        (dest / "run_status.json").write_text(json.dumps(status, indent=2) + "\n",
                                               encoding="utf-8")
        summary = device_flow.build(
            dest,
            top="dehaze_guided_refine_selftest_25k",
            rtl=[RTL.name, SELFTEST.name],
            params={"CLK_HZ": 50000000, "BAUD": 115200},
            cst_name=CST.name,
            image="dehaze_guided_refine_selftest_25k.fs",
            synth_timeout=900,
            pnr_timeout=900,
        )
        status.update({"phase": "complete", "build": summary["status"],
                       "bitstream": summary["bitstream"],
                       "bitstream_sha256": summary["bitstream_sha256"]})
        (dest / "run_status.json").write_text(json.dumps(status, indent=2) + "\n",
                                               encoding="utf-8")
        print("simulation=PASS build=%s fs=%s" % (summary["status"], dest / summary["bitstream"]))
        print("resource counts: %s" % summary["util"])
        print("board programming=not_run")
        return 0
    except subprocess.TimeoutExpired as exc:
        phase = str(status.get("phase", "unknown"))
        if (dest / "pack_25k.log").exists():
            phase = "packing"
        elif (dest / "pnr_console_25k.log").exists():
            phase = "place_and_route"
        elif (dest / "synthesis_25k.log").exists():
            phase = "synthesis"
        status.update({"phase": phase, "status": "TIMEOUT",
                       "timeout_seconds": exc.timeout,
                       "timeout_command": exc.cmd,
                       "logs_retained": True})
        (dest / "run_status.json").write_text(json.dumps(status, indent=2) + "\n",
                                               encoding="utf-8")
        print("TIMEOUT phase=%s; logs retained under %s" % (phase, dest), file=sys.stderr)
        return 124
    except Exception as exc:  # preserve exact-stage evidence for tool/build failures
        logs = {"synthesis": "synthesis_25k.log", "place_and_route": "pnr_console_25k.log",
                "packing": "pack_25k.log"}
        if (dest / logs["packing"]).exists():
            phase = "packing_or_post_build_gate"
        elif (dest / logs["place_and_route"]).exists():
            phase = "place_and_route"
        elif (dest / logs["synthesis"]).exists():
            phase = "synthesis"
        else:
            phase = str(status.get("phase", "unknown"))
        fs = dest / "dehaze_guided_refine_selftest_25k.fs"
        status.update({"phase": phase, "status": "FAIL",
                       "error": repr(exc), "fs_generated": fs.is_file(),
                       "logs_retained": True})
        (dest / "run_status.json").write_text(json.dumps(status, indent=2) + "\n",
                                               encoding="utf-8")
        print("FAIL phase=%s error=%s; logs retained under %s" % (phase, exc, dest),
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
