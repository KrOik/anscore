#!/usr/bin/env python3
"""Simulate an ephemeral auto wrapper with only its solver identifier changed."""
from __future__ import annotations

import datetime as dt
import gzip
import hashlib
import json
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
ISP = HERE.parents[1]
DIV3 = HERE.parent / "awb_div3_20261017"
EXPECTED = {
    ISP / "img_isp_awb_auto.v": "1cea6ef12178e3d337671deefdbb39ca417443f23a57743672b597ddd581570b",
    ISP / "img_isp_awb_stats.v": "26aa23144444042085860068275b0bb4388d3e5785633e8213358ce29c3d5cc0",
    ISP / "img_isp_awb_gain.v": "005478055e088fd83b18dbc35403d6b7e11d336db1cdcba2cb4ce256cc3794bb",
    DIV3 / "awb_constant_div3_radix4.v": "565f370fa57163e42c6f831d1316ef2d5b8380d3590bcc586322111352299d1b",
    DIV3 / "img_isp_awb_autogain_div3_candidate.v": "ba73ff2aae17e8fa5fddf94d1f1f84cf8aa51ede96540d274295bdd94e786660",
}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command: list[str], log: Path, env: dict[str, str]) -> str:
    result = subprocess.run(command, cwd=HERE, env=env, text=True, capture_output=True,
                            check=False, timeout=180)
    output = result.stdout+result.stderr
    log.write_text(f"$ {shlex.join(command)}\nexit_code={result.returncode}\n{output}", encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"{log.name}: exit={result.returncode}\n{output}")
    return output


def main() -> int:
    from check_feedback import check_trace
    summary: dict[str, object] = {"status": "FAIL", "tests": [],
        "scope": "full AWB feedback simulation with independent raw-pixel/statistics/integer-gain and latest-mailbox/SOF-commit oracle",
        "production_apply": "NOT_RUN", "synthesis": "NOT_RUN", "place_and_route": "NOT_RUN", "board": "NOT_RUN"}
    temp_path = None
    try:
        for path, digest in EXPECTED.items():
            if sha(path) != digest:
                raise RuntimeError(f"read-only source changed: {path}")
        source = (ISP / "img_isp_awb_auto.v").read_text()
        old = "img_isp_awb_autogain #(.SUM_WIDTH(SUM_WIDTH)) gain_solver"
        new = "img_isp_awb_autogain_div3_candidate #(.SUM_WIDTH(SUM_WIDTH)) gain_solver"
        if source.count(old) != 1:
            raise RuntimeError("auto wrapper solver identifier boundary absent/ambiguous")
        wrapper_source = source.replace(old, new)
        summary["read_only_sources"] = {path.relative_to(ROOT).as_posix(): sha(path) for path in EXPECTED}
        summary["derived_wrapper"] = {"source_sha256": sha(ISP / "img_isp_awb_auto.v"),
            "derived_sha256": hashlib.sha256(wrapper_source.encode()).hexdigest(),
            "only_change": "unique gain_solver module identifier", "replacements": 1,
            "retained_after_run": False}
        sys.path.insert(0, str(ROOT / "cores/signal_processing/dsp_isp_library/board/tang25k"))
        import device_flow
        env = device_flow.tool_env()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        compiler, runtime = device_flow.resolve("iverilog"), device_flow.resolve("vvp")
        with tempfile.TemporaryDirectory(prefix="_tmp_auto_div3_", dir=HERE) as temp_name:
            temp_path = Path(temp_name).resolve()
            if temp_path.parent != HERE:
                raise RuntimeError("temporary directory escaped exclusive task boundary")
            wrapper = temp_path / "img_isp_awb_auto_div3_bind.v"
            wrapper.write_text(wrapper_source, encoding="utf-8")
            for width in (48, 8, 16):
                tag = f"feedback_w{width}"
                image, trace = temp_path / f"{tag}.vvp", temp_path / f"{tag}.csv"
                command = [compiler, "-g2012", "-Wall", "-s", "tb_awb_auto_feedback",
                    f"-Ptb_awb_auto_feedback.WIDTH={width}", "-o", str(image), str(wrapper),
                    str(ISP / "img_isp_awb_stats.v"), str(ISP / "img_isp_awb_gain.v"),
                    str(DIV3 / "awb_constant_div3_radix4.v"),
                    str(DIV3 / "img_isp_awb_autogain_div3_candidate.v"),
                    str(HERE / "tb_awb_auto_feedback.sv")]
                run(command, HERE / f"compile_{tag}.log", env)
                output = run([runtime, str(image), f"+TRACE_FILE={trace.as_posix()}"],
                             HERE / f"simulation_{tag}.log", env)
                if f"AWB_AUTO_FEEDBACK_TRACE_PASS WIDTH={width}" not in output:
                    raise RuntimeError("trace fixture completion token missing")
                # Keep a compact replayable evidence trace, not the raw CSV.
                archive = HERE / f"trace_{tag}.csv.gz"
                with trace.open("rb") as incoming, archive.open("wb") as outgoing:
                    with gzip.GzipFile(fileobj=outgoing, mode="wb", mtime=0) as compressed:
                        for chunk in iter(lambda: incoming.read(1 << 16), b""):
                            compressed.write(chunk)
                record = check_trace(trace, width)
                record.update(compile_log=f"compile_{tag}.log", simulation_log=f"simulation_{tag}.log",
                    trace_archive=archive.name, trace_uncompressed_bytes=trace.stat().st_size,
                    trace_uncompressed_sha256=sha(trace), trace_archive_bytes=archive.stat().st_size,
                    trace_archive_sha256=sha(archive))
                summary["tests"].append(record)
                print(f"AWB_AUTO_DIV3_FEEDBACK_PASS WIDTH={width} pixels={record['coverage']['output_pixels_checked']} stats={record['coverage']['stats_handshakes']} commits={record['coverage']['sof_gain_commits']} mailbox_overwrites={record['coverage']['latest_mailbox_overwrites']}", flush=True)
        for path, digest in EXPECTED.items():
            if sha(path) != digest:
                raise RuntimeError("read-only source changed during test")
        summary["status"] = "PASS"
        summary["owned_source_sha256"] = {path.name: sha(path) for path in HERE.iterdir() if path.suffix in (".py", ".sv")}
        print("AWB_AUTO_DIV3_FULL_FEEDBACK_REGRESSION_PASS no_production_changes=1 temporary_vvp_removed=1")
        return 0
    except Exception as exc:
        summary["error"] = str(exc)
        print(f"AWB_AUTO_DIV3_FULL_FEEDBACK_REGRESSION_FAIL: {exc}", file=sys.stderr)
        raise
    finally:
        summary["temporary_artifacts"] = {"path": str(temp_path) if temp_path else None,
            "removed": temp_path is not None and not temp_path.exists(),
            "retained_vvp": [path.relative_to(HERE).as_posix() for path in HERE.rglob("*.vvp")],
            "retained_pyc": [path.relative_to(HERE).as_posix() for path in HERE.rglob("*.pyc")]}
        summary["completed_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        (HERE / "feedback_summary.json").write_text(json.dumps(summary, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
