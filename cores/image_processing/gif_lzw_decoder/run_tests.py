"""Fixed 20-child single-attempt runner. Preparation and HDL approvals are separate."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
PYTHON = Path(r"C:\Program Files\Python312\python.exe")
IVERILOG_HOME = Path(r"D:\anscore\tools\oss-cad-suite\oss-cad-suite")
IVERILOG = IVERILOG_HOME / "bin/iverilog.exe"
VVP = IVERILOG_HOME / "bin/vvp.exe"
TASKKILL = Path(os.environ.get("SystemRoot",r"C:\Windows")) / "System32/taskkill.exe"
PROFILES = [("p0",4,1,15,4),("p1",16,8,15,12),("p2",32,32,8,8)]
HARD_SECONDS = 20


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def json_write(path: Path, value: object) -> None:
    path.write_text(json.dumps(value,indent=2)+"\n",encoding="utf-8",newline="\n")


def verify_freeze() -> dict:
    seal = json.loads((ROOT/"SOURCE_SEAL.json").read_text())
    for group in ("sources","fixtures"):
        for rel, expected in seal[group].items():
            if sha(ROOT/rel) != expected:
                raise RuntimeError(f"frozen {group} changed: {rel}")
    assert seal["tools_sha256"]=={str(p):sha(p) for p in (PYTHON,IVERILOG,VVP,TASKKILL)},"frozen tool entry changed"
    assert seal["children"]==plan(Path("{ARTIFACT}")),"frozen 20-child description changed"
    prep = json.loads((ROOT/"PREPARATION_RECEIPT.json").read_text())
    assert prep["status"] == "PREPARED_ORACLE_ASSERTIONS_PASS_HW_NOT_RUN"
    assert prep["source_seal_sha256"] == sha(ROOT/"SOURCE_SEAL.json")
    return seal


def plan(out: Path) -> list[dict]:
    rtl = "rtl/gif_lzw_decoder.sv"
    tb = "sim/tb_gif_lzw_decoder.sv"
    def entry(name: str, argv: list, kind: str, expected: str = "") -> dict:
        return dict(name=name,argv=[str(v) for v in argv],kind=kind,expected=expected,
                    status="NOT_RUN",hard_seconds=HARD_SECONDS)
    slots = [entry("oracle_stored",[PYTHON,"-B","oracle.py","--verify-stored"],"exact","PASS ORACLE cases=38 certificates=3"),
             entry("tool_version",[IVERILOG,"-V"],"version"),
             entry("lint_core",[IVERILOG,"-g2012","-Wall","-tnull","-s","gif_lzw_decoder",rtl],"silent"),
             entry("lint_example",[IVERILOG,"-g2012","-Wall","-tnull","-s","gif_data",rtl,"example/gif_data.sv"],"silent")]
    for name,cw,tw,_,_ in PROFILES:
        slots.append(entry("compile_"+name,[IVERILOG,"-g2012","-Wall","-s","tb_gif_lzw_decoder",
            "-P",f"tb_gif_lzw_decoder.COUNT_W={cw}","-P",f"tb_gif_lzw_decoder.TAG_W={tw}",
            "-o",out/f"{name}.vvp",rtl,tb],"silent"))
    for name,_,_,packets,_ in PROFILES:
        for stalled in (0,1):
            slots.append(entry(f"main_{name}_{stalled}",[VVP,out/f"{name}.vvp",f"+PROFILE={name}","+MODE=main",f"+STALL={stalled}"],
                               "simulation",f"PASS MAIN profile={name} stall={stalled} packets={packets}"))
    for name,_,_,_,probes in PROFILES:
        slots.append(entry("reset_"+name,[VVP,out/f"{name}.vvp",f"+PROFILE={name}","+MODE=reset","+STALL=0"],
                           "simulation",f"PASS RESET profile={name} probes={probes} recoveries={probes}"))
    for param,value in (("COUNT_W",0),("COUNT_W",33),("TAG_W",0),("TAG_W",33)):
        slots.append(entry(f"reject_{param}_{value}",[IVERILOG,"-g2012","-tnull","-s","gif_lzw_decoder",
            "-P",f"gif_lzw_decoder.{param}={value}",rtl],"reject"))
    assert len(slots)==20
    return slots


def cleanup_child(process: subprocess.Popen, slot: dict, out: Path,
                  partial_out: bytes, partial_err: bytes) -> tuple[bytes,bytes]:
    """Tree cleanup and all drains are bounded; exceptions remain evidence."""
    cleanup={}
    kill_out,kill_err=b"",b""
    try:
        if os.name=="nt":
            assert TASKKILL.is_absolute()
            cleanup["argv"]=[str(TASKKILL),"/PID",str(process.pid),"/T","/F"]
            killed=subprocess.run([str(TASKKILL),"/PID",str(process.pid),"/T","/F"],
                                  executable=str(TASKKILL),stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                  timeout=3,creationflags=subprocess.CREATE_NO_WINDOW)
            kill_out,kill_err=killed.stdout,killed.stderr
            cleanup["returncode"]=killed.returncode
        else:
            cleanup["process_group"]=process.pid
            os.killpg(process.pid,signal.SIGKILL)
            cleanup["killpg_sent"]=True
    except subprocess.TimeoutExpired as exc:
        kill_out,kill_err=exc.output or b"",exc.stderr or b""
        cleanup.update(error_type=type(exc).__name__,error=str(exc),returncode=None)
    except Exception as exc:
        cleanup.update(error_type=type(exc).__name__,error=str(exc),returncode=None)
    for stream,raw in (("stdout",kill_out),("stderr",kill_err)):
        path=out/(slot["name"]+f".kill.{stream}.raw")
        path.write_bytes(raw)
        cleanup[stream+"_file"]=path.name
        cleanup[stream+"_sha256"]=sha(path)
    # Poll even when tree cleanup failed, then always attempt the needed fallback.
    parent_active=True
    try:
        cleanup["parent_poll_before_kill"]=process.poll()
        parent_active=cleanup["parent_poll_before_kill"] is None
    except Exception as exc:
        cleanup["parent_poll_error"]=str(exc)
    if parent_active:
        try:
            process.kill()
            cleanup["parent_kill_sent"]=True
        except Exception as exc:
            cleanup["parent_kill_error"]=str(exc)
    stdout,stderr=partial_out,partial_err
    try:
        stdout,stderr=process.communicate(timeout=3)
    except subprocess.TimeoutExpired as exc:
        stdout,stderr=exc.output or partial_out,exc.stderr or partial_err
        cleanup.update(bounded_drain_exhausted=True,drain_error_type=type(exc).__name__,drain_error=str(exc))
    except Exception as exc:
        cleanup.update(drain_error_type=type(exc).__name__,drain_error=str(exc))
    finally:
        for stream in (process.stdout,process.stderr):
            try:
                stream.close()
            except Exception as exc:
                cleanup.setdefault("pipe_close_errors",[]).append(str(exc))
    slot["process_tree_cleanup"]=cleanup
    return stdout,stderr


def run_child(slot: dict, out: Path, env: dict) -> None:
    start=time.monotonic()
    process=None
    stdout,stderr=b"",b""
    timed_out=False
    failure=None
    try:
        launch=dict(cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                    executable=slot["argv"][0])
        if os.name=="nt":
            launch["creationflags"]=subprocess.CREATE_NEW_PROCESS_GROUP|subprocess.CREATE_NO_WINDOW
        else:
            launch["start_new_session"]=True
        process=subprocess.Popen(slot["argv"],**launch)
        slot["pid"]=process.pid
        try:
            stdout,stderr=process.communicate(timeout=HARD_SECONDS)
        except subprocess.TimeoutExpired as exc:
            timed_out=True
            failure="hard20s process-tree timeout"
            stdout,stderr=cleanup_child(process,slot,out,exc.output or b"",exc.stderr or b"")
        except Exception as exc:
            failure=f"communicate {type(exc).__name__}: {exc}"
            stdout,stderr=cleanup_child(process,slot,out,stdout,stderr)
    except Exception as exc:
        failure=f"launch/cleanup {type(exc).__name__}: {exc}"
    # Exact byte streams are retained before any decoding, normalization or matching.
    stdout_path=out/(slot["name"]+".stdout.raw")
    stderr_path=out/(slot["name"]+".stderr.raw")
    stdout_path.write_bytes(stdout);stderr_path.write_bytes(stderr)
    slot.update(elapsed_seconds=round(time.monotonic()-start,6),returncode=process.poll() if process is not None else None,
                stdout_sha256=sha(stdout_path),stderr_sha256=sha(stderr_path),timed_out=timed_out)
    if failure:
        raise RuntimeError(failure)
    lines=[line for line in (stdout+stderr).decode("utf-8",errors="replace").splitlines() if line.strip()]
    kind=slot["kind"]
    if kind=="reject":
        if process.returncode==0 or not any(re.search(r"gif_lzw_decoder_invalid_parameters__see_README",line) for line in lines):
            raise RuntimeError("expected named invalid-parameter elaboration rejection")
    else:
        if process.returncode!=0:
            raise RuntimeError(f"child exit {process.returncode}")
        if kind=="silent" and lines:
            raise RuntimeError("unexpected compiler diagnostics")
        if kind=="version" and not any(re.fullmatch(r"Icarus Verilog version .+",line) for line in lines):
            raise RuntimeError("missing Icarus version line")
        if kind in ("exact","simulation"):
            matches=[line for line in lines if re.fullmatch(re.escape(slot["expected"]),line)]
            extras=[line for line in lines if not re.fullmatch(re.escape(slot["expected"]),line)]
            if kind=="simulation":
                extras=[line for line in extras if not re.fullmatch(r"sim[/\\]tb_gif_lzw_decoder\.sv:\d+: \$finish called at \d+ \(1ps\)",line)]
            if len(matches)!=1 or extras:
                raise RuntimeError("exact per-line PASS/diagnostic check failed")


def main() -> int:
    parser=argparse.ArgumentParser()
    parser.add_argument("--run",action="store_true")
    parser.add_argument("--check",action="store_true")
    args=parser.parse_args()
    assert args.run != args.check,"choose --run or --check"
    seal=verify_freeze()
    attempt=ROOT/"evidence/attempt_01"
    if args.check:
        receipt=json.loads((attempt/"receipt.json").read_text())
        assert receipt["status"]=="PASS" and len(receipt["children"])==20
        for slot in receipt["children"]:
            assert slot["status"]=="PASS"
            for stream in ("stdout","stderr"):
                assert sha(attempt/(slot["name"]+f".{stream}.raw"))==slot[stream+"_sha256"]
        assert receipt["source_seal_sha256"]==sha(ROOT/"SOURCE_SEAL.json")
        assert receipt["artifacts_deleted"] and len(receipt["compiled_artifacts_sha256"])==3
        for name in receipt["compiled_artifacts_sha256"]:
            assert name in ("p0.vvp","p1.vvp","p2.vvp") and not (attempt/name).exists()
        for group in ("sources","fixtures"):
            for rel,expected in seal[group].items():
                assert sha(attempt/"sources"/rel)==expected,rel
        for rel in ("SOURCE_SEAL.json","PREPARATION_RECEIPT.json"):
            assert sha(attempt/"sources"/rel)==sha(ROOT/rel),rel
        print("PASS CHECK children=20 main_packets=76 reset_probes=24")
        return 0
    assert Path(sys.executable).resolve()==PYTHON.resolve(),"use frozen absolute Python"
    assert TASKKILL.is_absolute()
    assert all(p.is_file() for p in (PYTHON,IVERILOG,VVP,TASKKILL))
    # No retry, replacement or adaptive split. Existing evidence is preserved.
    attempt.mkdir(parents=True,exist_ok=False)
    (attempt/"single_attempt.lock").write_text("B27 fixed first attempt; do not rerun\n",encoding="ascii")
    for group in ("sources","fixtures"):
        for rel in seal[group]:
            destination=attempt/"sources"/rel
            destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/rel,destination)
    for rel in ("SOURCE_SEAL.json","PREPARATION_RECEIPT.json"):
        shutil.copyfile(ROOT/rel,attempt/"sources"/rel)
    slots=plan(attempt)
    receipt=dict(status="RUNNING",children=slots,source_seal_sha256=sha(ROOT/"SOURCE_SEAL.json"),
                 main_packets=76,reset_probes=24,recovery_packets=24,hard_seconds=20,
                 python=str(PYTHON),iverilog=str(IVERILOG),vvp=str(VVP))
    receipt_path=attempt/"receipt.json"
    json_write(receipt_path,receipt)
    env=os.environ.copy()
    env["PATH"]=str(IVERILOG_HOME/"bin")+os.pathsep+str(IVERILOG_HOME/"lib")+os.pathsep+env.get("PATH","")
    env["PYTHONDONTWRITEBYTECODE"]="1"
    for slot in slots:
        try:
            verify_freeze()
            slot["status"]="RUNNING"
            json_write(receipt_path,receipt)
            run_child(slot,attempt,env)
            slot["status"]="PASS"
        except Exception as exc:
            slot["status"]="TIMEOUT" if slot.get("timed_out") else "FAIL"
            slot["failure"]=str(exc)
            receipt["status"]=slot["status"]
            json_write(receipt_path,receipt)
            print(f"{receipt['status']} {slot['name']}: {exc}")
            return 1
        json_write(receipt_path,receipt)
        print("PASS "+slot["name"],flush=True)
    try:
        artifact_paths=[(attempt/f"{name}.vvp").resolve() for name,_,_,_,_ in PROFILES]
        checked_attempt=attempt.resolve()
        assert len(artifact_paths)==3 and all(p.is_file() and p.parent==checked_attempt and p.name in ("p0.vvp","p1.vvp","p2.vvp") for p in artifact_paths)
        receipt["compiled_artifacts_sha256"]={p.name:sha(p) for p in artifact_paths}
        json_write(receipt_path,receipt)
        for path in artifact_paths:
            path.unlink()
        receipt["artifacts_deleted"]=True
    except Exception as exc:
        receipt.update(status="FAIL_FINALIZE",failure=str(exc))
        json_write(receipt_path,receipt)
        print(f"FAIL_FINALIZE: {exc}")
        return 1
    receipt["status"]="PASS"
    json_write(receipt_path,receipt)
    print("PASS MATRIX children=20 main_packets=76 reset_probes=24")
    return 0


if __name__=="__main__":
    raise SystemExit(main())
