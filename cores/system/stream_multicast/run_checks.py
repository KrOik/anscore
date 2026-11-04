"""Offline compile and bounded deterministic tests; no synthesis commands."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def main():
    suite = ROOT.parents[2]/"tools"/"oss-cad-suite"/"oss-cad-suite"
    tool_paths = {}
    for name in ("iverilog", "vvp"):
        local = suite/"bin"/(name + (".exe" if os.name == "nt" else ""))
        tool_paths[name] = os.environ.get(name.upper()) or (str(local) if local.is_file() else shutil.which(name))
    if not all(tool_paths.values()):
        raise SystemExit("NOT_RUN: iverilog and vvp must be on PATH")
    records = []
    tmp = ""
    env = os.environ.copy()
    env["PATH"] = str(suite/"bin") + os.pathsep + str(suite/"lib") + os.pathsep + env.get("PATH", "")

    def run(args):
        record = {"command": args, "timeout_seconds": 20}
        try:
            result = subprocess.run([tool_paths[args[0]], *args[1:]], cwd=ROOT, text=True,
                                    capture_output=True, timeout=20, env=env)
        except subprocess.TimeoutExpired:
            record["status"] = "NOT_RUN_TIMEOUT"
            records.append(record)
            raise SystemExit("NOT_RUN_TIMEOUT: lightweight check stopped")
        except OSError as exc:
            record.update(status="NOT_RUN",output=str(exc))
            records.append(record)
            raise SystemExit("NOT_RUN: local tool could not start")
        record.update(status="PASS" if result.returncode == 0 else "FAIL",
                      output=(result.stdout + result.stderr).strip())
        records.append(record)
        if result.returncode:
            raise SystemExit(record["output"])
        print(record["output"] or "PASS compile")

    try:
        run(["iverilog", "-g2012", "-Wall", "-tnull", "-s", "stream_multicast", "-c", "files.f"])
        run(["iverilog", "-g2012", "-Wall", "-tnull", "-s", "multicast_2way", "-c", "files.f",
             "examples/multicast_2way.v"])
        with tempfile.TemporaryDirectory(prefix="anscore_multicast_") as tmp:
            for ports,width in ((1,8),(3,16),(5,32)):
                compiled = str(Path(tmp)/"tb.vvp")
                run(["iverilog", "-g2012", "-Wall", "-s", "tb_stream_multicast",
                     f"-Ptb_stream_multicast.PORTS={ports}",
                     f"-Ptb_stream_multicast.DATA_WIDTH={width}",
                     "-o", compiled, "-c", "files.f", "sim/tb_stream_multicast.sv"])
                run(["vvp", compiled])
    finally:
        sources = ("files.f", "rtl/stream_multicast.v", "examples/multicast_2way.v",
                   "sim/tb_stream_multicast.sv", "run_checks.py")
        for record in records:
            record["command"] = [arg.replace(tmp, "<temporary>") if tmp else arg
                                 for arg in record["command"]]
        report = {"tools":tool_paths, "checks":records,
                  "source_sha256":{s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources},
                  "hardware":"HW_UNVERIFIED; synthesis/PnR/STA/board NOT_RUN"}
        (ROOT/"check_results.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__ == "__main__":
    main()
