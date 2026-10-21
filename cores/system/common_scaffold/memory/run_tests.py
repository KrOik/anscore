#!/usr/bin/env python3
"""Run memory regressions including real DMA; optionally synthesize all modules."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
OSS = REPO / "tools/oss-cad-suite/oss-cad-suite"
TOPS = ["tb_cip_sync_ram", "tb_cip_sync_fifo", "tb_cip_dma_e2e"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--synth", action="store_true", help="also run isolated synth_gowin -noalu")
    parser.add_argument("--dma-only", action="store_true", help="run the new DMA group regression only")
    args = parser.parse_args()
    run = HERE / "build" / datetime.now().strftime("run_%Y%m%d_%H%M%S_%f")
    run.mkdir(parents=True)
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join([str(OSS / "bin"), str(OSS / "lib"), env.get("PATH", "")])

    def tool(name: str) -> str:
        candidate = OSS / "bin" / (name + (".exe" if os.name == "nt" else ""))
        found = str(candidate) if candidate.is_file() else shutil.which(name, path=env["PATH"])
        if not found:
            raise RuntimeError(f"Missing tool {name}")
        return found

    steps: list[dict] = []

    def execute(label: str, cmd: list[str], timeout: int = 120) -> str:
        result = subprocess.run(cmd, cwd=REPO, env=env, text=True, encoding="utf-8", errors="replace",
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        (run / f"{label}.log").write_text(result.stdout, encoding="utf-8")
        steps.append({"name": label, "command": cmd, "returncode": result.returncode})
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n{result.stdout[-6000:]}")
        return result.stdout

    sources = sorted((HERE / "src").glob("*.v"))
    summary: dict = {"scope": "isolated memory RTL and native DMA; no board integration", "steps": steps,
                     "source_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                     "test_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in (HERE / "sim").glob("tb*.v")},
                     "synthesis": {}, "board_verified": False}
    try:
        for top in (["tb_cip_dma_e2e"] if args.dma_only else TOPS):
            binary = run / f"{top}.vvp"
            execute(top + "_compile", [tool("iverilog"), "-g2012", "-Wall", "-s", top,
                                       "-o", str(binary), *map(str, sources), str(HERE / "sim" / f"{top}.v")])
            output = execute(top, [tool("vvp"), str(binary)])
            if "PASS" not in output or "FAIL" in output or "FATAL" in output:
                raise RuntimeError(f"{top} did not produce an unambiguous PASS")
            print(output.strip())
        if args.synth:
            for src in sources:
                top = src.stem
                netlist = run / f"{top}.json"
                source_args = " ".join(f'"{p.as_posix()}"' for p in sources)
                script = (f'read_verilog -sv {source_args}; '
                          f'synth_gowin -family gw2a -noalu -noiopads -top {top} -json "{netlist.as_posix()}"; stat')
                execute(top + "_synth", [tool("yosys"), "-p", script], timeout=600)
                design = json.loads(netlist.read_text(encoding="utf-8"))
                cells = Counter(cell["type"] for cell in design["modules"][top]["cells"].values())
                lut = sum(v for k, v in cells.items() if k.startswith("LUT"))
                mux = sum(v for k, v in cells.items() if k.startswith("MUX"))
                distributed_lut_estimate = sum(v * {"RAM16S1": 1, "RAM16S2": 2, "RAM16S4": 4,
                                                    "RAM16SDP1": 1, "RAM16SDP2": 2,
                                                    "RAM16SDP4": 4}.get(k, 0) for k, v in cells.items())
                dsp = sum(v for k, v in cells.items() if k.startswith(("MULT", "PADD", "ALU54")))
                data = {"cells": dict(sorted(cells.items())), "lut_primitives": lut,
                        "mux_primitives": mux, "lut_plus_mux_conservative": lut + mux,
                        "distributed_ram_lut_estimate": distributed_lut_estimate,
                        "lut_class_budget_estimate": lut + mux + distributed_lut_estimate,
                        "dsp_primitives": dsp, "pnr_run": False}
                summary["synthesis"][top] = data
                if lut + mux + distributed_lut_estimate > 15000 or dsp > 4:
                    raise RuntimeError(f"{top} exceeds isolated resource budget")
                print(f"PASS SYNTH {top}: LUT={lut} MUX={mux} DSP={dsp}")
        summary["result"] = "pass"
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        summary["result"] = "fail"
        summary["error"] = str(exc)
        print(str(exc), file=sys.stderr)
    (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"Evidence: {run.relative_to(REPO)}")
    return 0 if summary["result"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
