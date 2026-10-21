#!/usr/bin/env python3
"""Run the v70 ROM and six-case arithmetic benches against production RTL."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
CANDIDATE = ROOT / "cores/system/common_scaffold/board/tang25k/build/image_window_filter8_selftest_25k_20261017_v70_meanrom"
RTL = ROOT / "cores/system/common_scaffold/image/filters/rtl"
SUITE = ROOT / "tools/oss-cad-suite/oss-cad-suite"


def tool(name: str) -> Path:
    bundled = SUITE / "bin" / f"{name}.exe"
    if bundled.is_file():
        return bundled
    located = shutil.which(name)
    if located:
        return Path(located)
    raise FileNotFoundError(f"{name} not found")


def main() -> int:
    iverilog, vvp = tool("iverilog"), tool("vvp")
    env = os.environ.copy()
    if SUITE.is_dir() and iverilog.parent == SUITE / "bin":
        env["YOSYSHQ_ROOT"] = str(SUITE) + os.sep
        env["PATH"] = os.pathsep.join((
            str(SUITE / "bin"), str(SUITE / "lib"),
            str(SUITE / "lib" / "ivl"), env.get("PATH", ""),
        ))

    cases = [
        (
            "mean9_rom",
            "tb_mean9_rom",
            [RTL / "img_filter_mean9_rom.v"],
            "MEAN9 EXHAUSTIVE PASS outputs=8192",
        ),
        (
            "arithmetic_six_cases",
            "tb_img_filter_arithmetic",
            [
                RTL / "img_filter_stream_register.v",
                RTL / "img_filter_kernel3x3.v",
                RTL / "img_filter_mean9_rom.v",
                RTL / "img_filter_median_sort3_segment.v",
                RTL / "img_edge_gradient3x3.v",
            ],
            "ARITH PIPELINE PASS cases=6 widths=1,8,12 masks=1ff,013 shifts=0,2 burst=32",
        ),
    ]
    results = []
    temporary_vvp_bytes = 0
    with tempfile.TemporaryDirectory(prefix="production_meanrom_v70_") as tmp_name:
        tmp = Path(tmp_name)
        for label, top, sources, required in cases:
            bench = CANDIDATE / f"{top}.sv"
            image = tmp / f"{top}.vvp"
            compile_result = subprocess.run(
                [str(iverilog), "-g2012", "-s", top, "-o", str(image), str(bench),
                 *(str(path) for path in sources)],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=180,
            )
            compile_text = compile_result.stdout + compile_result.stderr
            (HERE / f"{label}_compile.log").write_text(compile_text, encoding="utf-8")
            if compile_result.returncode:
                raise RuntimeError(f"{label} compile failed\n{compile_text}")
            temporary_vvp_bytes += image.stat().st_size
            simulation = subprocess.run(
                [str(vvp), str(image)], cwd=ROOT, env=env,
                capture_output=True, text=True, timeout=180,
            )
            output = simulation.stdout + simulation.stderr
            (HERE / f"{label}_simulation.log").write_text(output, encoding="utf-8")
            if simulation.returncode or required not in output:
                raise RuntimeError(f"{label} simulation failed\n{output}")
            results.append({
                "test": label,
                "top": top,
                "status": "PASS",
                "bench": str(bench.relative_to(ROOT)).replace("\\", "/"),
                "rtl_sources": [str(path.relative_to(ROOT)).replace("\\", "/") for path in sources],
                "output_sha256": hashlib.sha256(output.encode()).hexdigest(),
                "output": output,
            })

    summary = {
        "status": "PASS",
        "candidate_reference": CANDIDATE.name,
        "rtl_under_test": "production image/filters/rtl sources",
        "checks": results,
        "mean_rom_outputs_checked": 8192,
        "arithmetic_cases": 6,
        "temporary_vvp_files_created": 2,
        "temporary_vvp_bytes_created_then_removed": temporary_vvp_bytes,
        "temporary_directory_removed": True,
        "created_utc": datetime.now(timezone.utc).isoformat(),
    }
    (HERE / "production_rtl_regressions.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
