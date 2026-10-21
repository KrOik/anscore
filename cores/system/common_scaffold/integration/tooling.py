"""Local OSS tools, unique evidence directories, and bounded execution."""
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
PACKAGE = Path(__file__).resolve().parents[1]


def tool_env():
    env = os.environ.copy()
    oss = ROOT / "tools/oss-cad-suite/oss-cad-suite"
    env["PATH"] = os.pathsep.join([str(oss / "bin"), str(oss / "lib"), env.get("PATH", "")])
    return env


def evidence_dir(label):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    result = PACKAGE / "evidence" / f"{label}_{stamp}_{uuid.uuid4().hex[:8]}"
    result.mkdir(parents=True, exist_ok=False)
    return result


def execute(argv, cwd, log, timeout=120):
    env = tool_env()
    executable = shutil.which(str(argv[0]), path=env["PATH"])
    if not executable:
        raise RuntimeError(f"tool missing: {argv[0]}")
    command = [executable, *map(str, argv[1:])]
    try:
        run = subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        Path(log).write_bytes(exc.stdout or b"")
        raise RuntimeError(f"timeout: {argv[0]}; {log}") from exc
    Path(log).write_bytes(run.stdout)
    text = run.stdout.decode("utf-8", errors="replace")
    if run.returncode:
        raise RuntimeError(f"exit {run.returncode}: {' '.join(command)}\n{text[-4000:]}")
    return text


def sim(name, sources, folder, marker):
    vvp = folder / f"{name}.vvp"
    execute(["iverilog", "-g2012", "-s", name, "-o", vvp, *sources],
            ROOT, folder / f"{name}_compile.log")
    output = execute(["vvp", vvp], ROOT, folder / f"{name}_sim.log")
    if marker not in output:
        raise RuntimeError(f"missing explicit success marker {marker!r}")
    print(output.strip())


def write_json(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
