"""Root-approved, sealed, one-attempt runner. AUTHORED; NOT EXECUTED.

No stage can start without an external approval containing the exact argv list
and the SHA256 of SOURCE_SEAL.json. Windows children are created suspended,
assigned to a kill-on-close Job Object, and only then resumed. Each entire tree
is killed at 20 seconds. There is no alternate path, fallback or automatic retry.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
TIMEOUT = 20


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def windows_child(argv, stdout, stderr):
    from ctypes import wintypes as w
    import msvcrt
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    size_t = ctypes.c_size_t

    class BASIC(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64),
                    ("PerJobUserTimeLimit", ctypes.c_int64), ("LimitFlags", w.DWORD),
                    ("MinimumWorkingSetSize", size_t), ("MaximumWorkingSetSize", size_t),
                    ("ActiveProcessLimit", w.DWORD), ("Affinity", size_t),
                    ("PriorityClass", w.DWORD), ("SchedulingClass", w.DWORD)]

    class IO(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in
                    ["ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                     "ReadTransferCount", "WriteTransferCount", "OtherTransferCount"]]

    class EXTENDED(ctypes.Structure):
        _fields_ = [("BasicLimitInformation", BASIC), ("IoInfo", IO),
                    ("ProcessMemoryLimit", size_t), ("JobMemoryLimit", size_t),
                    ("PeakProcessMemoryUsed", size_t), ("PeakJobMemoryUsed", size_t)]

    class STARTUP(ctypes.Structure):
        _fields_ = [("cb", w.DWORD), ("lpReserved", w.LPWSTR), ("lpDesktop", w.LPWSTR),
                    ("lpTitle", w.LPWSTR), ("dwX", w.DWORD), ("dwY", w.DWORD),
                    ("dwXSize", w.DWORD), ("dwYSize", w.DWORD),
                    ("dwXCountChars", w.DWORD), ("dwYCountChars", w.DWORD),
                    ("dwFillAttribute", w.DWORD), ("dwFlags", w.DWORD),
                    ("wShowWindow", w.WORD), ("cbReserved2", w.WORD),
                    ("lpReserved2", ctypes.POINTER(w.BYTE)),
                    ("hStdInput", w.HANDLE), ("hStdOutput", w.HANDLE), ("hStdError", w.HANDLE)]

    class PROCESS(ctypes.Structure):
        _fields_ = [("hProcess", w.HANDLE), ("hThread", w.HANDLE),
                    ("dwProcessId", w.DWORD), ("dwThreadId", w.DWORD)]

    k.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
    k.CreateJobObjectW.restype = w.HANDLE
    k.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
    k.SetInformationJobObject.restype = w.BOOL
    k.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
    k.AssignProcessToJobObject.restype = w.BOOL
    k.CreateProcessW.argtypes = [w.LPCWSTR, w.LPWSTR, ctypes.c_void_p, ctypes.c_void_p,
                                w.BOOL, w.DWORD, ctypes.c_void_p, w.LPCWSTR,
                                ctypes.POINTER(STARTUP), ctypes.POINTER(PROCESS)]
    k.CreateProcessW.restype = w.BOOL
    k.ResumeThread.argtypes = [w.HANDLE]
    k.ResumeThread.restype = w.DWORD
    k.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
    k.WaitForSingleObject.restype = w.DWORD
    k.GetExitCodeProcess.argtypes = [w.HANDLE, ctypes.POINTER(w.DWORD)]
    k.GetExitCodeProcess.restype = w.BOOL
    k.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
    k.TerminateJobObject.restype = w.BOOL
    k.TerminateProcess.argtypes = [w.HANDLE, w.UINT]
    k.TerminateProcess.restype = w.BOOL
    k.CloseHandle.argtypes = [w.HANDLE]
    k.CloseHandle.restype = w.BOOL
    job = k.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    process = PROCESS()
    resumed = False
    started = time.monotonic()
    try:
        limits = EXTENDED()
        limits.BasicLimitInformation.LimitFlags = 0x2000  # KILL_ON_JOB_CLOSE
        if not k.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise ctypes.WinError(ctypes.get_last_error())
        with open(os.devnull, "rb") as stdin:
            handles = [msvcrt.get_osfhandle(x.fileno()) for x in (stdin, stdout, stderr)]
            for handle in handles:
                os.set_handle_inheritable(handle, True)
            startup = STARTUP()
            startup.cb = ctypes.sizeof(startup)
            startup.dwFlags = 0x100  # STARTF_USESTDHANDLES
            startup.hStdInput, startup.hStdOutput, startup.hStdError = handles
            command = ctypes.create_unicode_buffer(subprocess.list2cmdline(argv))
            try:
                ok = k.CreateProcessW(None, command, None, None, True,
                                      0x4 | 0x08000000, None, str(ROOT),
                                      ctypes.byref(startup), ctypes.byref(process))
            finally:
                for handle in handles:
                    os.set_handle_inheritable(handle, False)
            if not ok:
                raise ctypes.WinError(ctypes.get_last_error())
            if not k.AssignProcessToJobObject(job, process.hProcess):
                raise ctypes.WinError(ctypes.get_last_error())
            if k.ResumeThread(process.hThread) == 0xffffffff:
                raise ctypes.WinError(ctypes.get_last_error())
            resumed = True
            outcome = k.WaitForSingleObject(process.hProcess, TIMEOUT * 1000)
            timeout = outcome == 258
            if outcome not in (0, 258):
                raise ctypes.WinError(ctypes.get_last_error())
            if timeout:
                if not k.TerminateJobObject(job, 124):
                    raise ctypes.WinError(ctypes.get_last_error())
                k.WaitForSingleObject(process.hProcess, 1000)
            code = w.DWORD()
            if not k.GetExitCodeProcess(process.hProcess, ctypes.byref(code)):
                raise ctypes.WinError(ctypes.get_last_error())
            return {"returncode": code.value, "timeout": timeout,
                    "elapsed_seconds": round(time.monotonic() - started, 6),
                    "process_id": process.dwProcessId,
                    "tree_guard": "Windows suspended child assigned to kill-on-close Job Object"}
    finally:
        # Closing the job also kills any descendant left after its parent exits.
        if process.hProcess and not resumed:
            k.TerminateProcess(process.hProcess, 125)
        k.CloseHandle(job)
        if process.hThread:
            k.CloseHandle(process.hThread)
        if process.hProcess:
            k.CloseHandle(process.hProcess)


def child(argv, stdout_path, stderr_path):
    with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
        if os.name == "nt":
            return windows_child(argv, stdout, stderr)
        started = time.monotonic()
        process = subprocess.Popen(argv, cwd=ROOT, stdin=subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        timed_out = False
        try:
            process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=1)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return {"returncode": process.returncode, "timeout": timed_out,
                "elapsed_seconds": round(time.monotonic() - started, 6),
                "process_id": process.pid, "tree_guard": "dedicated POSIX process group"}


def format_argv(template, substitutions):
    return [part.format(**substitutions) for part in template]


def seal_check():
    seal_path = ROOT / "SOURCE_SEAL.json"
    seal = read_json(seal_path)
    for rel, expected in seal["files_sha256"].items():
        path = (ROOT / rel).resolve()
        if not path.is_relative_to(ROOT) or sha(path) != expected:
            raise ValueError("sealed source mismatch: " + rel)
    actual = {p.relative_to(ROOT).as_posix() for p in ROOT.rglob("*") if p.is_file()
              and p.relative_to(ROOT).parts[0] not in ("execution", "prepared", "artifacts")
              and p.relative_to(ROOT).as_posix() != "SOURCE_SEAL.json"}
    if actual != set(seal["files_sha256"]):
        raise ValueError("sealed source inventory changed")
    if sha(ROOT / "rtl/deps/cip_sync_sp_ram.v") != \
            "04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619":
        raise ValueError("local RAM reuse changed")
    return sha(seal_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", choices=("prepare", "hdl"), required=True)
    parser.add_argument("--approval", required=True)
    parser.add_argument("--iverilog")
    parser.add_argument("--vvp")
    args = parser.parse_args()
    seal_sha = seal_check()
    plan, raw = read_json(ROOT / "TEST_PLAN.json"), read_json(ROOT / "RAW_INPUTS.json")
    approval_path = Path(args.approval).resolve()
    if approval_path.is_relative_to(ROOT):
        raise ValueError("root approval must be external to the sealed package")
    approval = read_json(approval_path)
    required = {"schema": "anscore-root-specific-approval-v1", "stage": args.stage,
                "attempt": "attempt01", "source_seal_sha256": seal_sha,
                "child_timeout_seconds": 20, "process_tree_required": True,
                "stop_on_first_failure": True, "automatic_retry": False}
    if any(approval.get(k) != v for k, v in required.items()):
        raise ValueError("specific root approval does not match this stage/seal")
    substitutions = {"python": sys.executable}
    children = []
    if args.stage == "prepare":
        if (ROOT / "prepared/attempt01").exists():
            raise FileExistsError("preparation has already started; no retry")
        children.append(("prepare", format_argv(plan["prepare"]["argv"], substitutions), False))
    else:
        if not args.iverilog or not args.vvp:
            raise ValueError("HDL requires explicit absolute tool paths")
        for name in ("iverilog", "vvp"):
            tool = Path(getattr(args, name))
            if not tool.is_absolute() or not tool.is_file():
                raise ValueError("invalid absolute tool path: " + name)
            substitutions[name] = str(tool)
        prepared = ROOT / "prepared/attempt01"
        manifest = read_json(prepared / "prepared_manifest.json")
        if approval.get("prepared_manifest_sha256") != sha(prepared / "prepared_manifest.json"):
            raise ValueError("prepared manifest not approved")
        if manifest["source_seal_sha256"] != seal_sha or \
                manifest["raw_input_sha256"] != sha(ROOT / "RAW_INPUTS.json"):
            raise ValueError("prepared source/input binding mismatch")
        if sha(prepared / "oracle_expected.json") != manifest["oracle_expected_sha256"]:
            raise ValueError("prepared oracle bytes changed")
        for name, item in manifest["vectors"].items():
            if sha(prepared / name) != item["sha256"]:
                raise ValueError("prepared vector bytes changed")
        for spec in plan["positive_compile"]:
            children.append((spec["name"], format_argv(spec["argv"], substitutions), False))
        if [p["name"] for p in raw["profiles"]] != plan["profiles_from_raw"]:
            raise ValueError("profile order changed")
        for profile in raw["profiles"]:
            values = {**substitutions, **profile}
            children.append(("compile_" + profile["name"],
                             format_argv(plan["profile_compile_template"], values), False))
            children.append(("sim_" + profile["name"],
                             format_argv(plan["profile_sim_template"], values), False))
        for reject in plan["named_parameter_rejects"]:
            children.append(("reject_" + reject["name"],
                             format_argv(plan["named_reject_template"], {**substitutions, **reject}), True))
        children.append(("audit", format_argv(plan["audit"]["argv"], substitutions), False))
    if approval.get("approved_argv") != [entry[1] for entry in children] or \
            approval.get("max_invocations") != len(children):
        raise ValueError("root approval must enumerate every exact argv and child count")
    if len(children) != plan["planned_" + ("prepare" if args.stage == "prepare" else "hdl") + "_children"]:
        raise ValueError("fixed invocation count mismatch")
    execution = ROOT / ("execution/attempt01-" + args.stage)
    if execution.exists() or (args.stage == "hdl" and (ROOT / "artifacts/attempt01").exists()):
        raise FileExistsError("stage output exists; no retry or overwrite")
    execution.mkdir(parents=True, exist_ok=False)
    artifact = ROOT / "artifacts/attempt01" if args.stage == "hdl" else execution
    if args.stage == "hdl":
        artifact.mkdir(parents=True, exist_ok=False)
    receipt_path = execution / "verification.json"
    receipt = {"status": "RUNNING", "stage": args.stage, "attempt": "attempt01",
               "source_seal_sha256": seal_sha, "approval_sha256": sha(approval_path),
               "child_timeout_seconds": 20, "automatic_retry": False,
               "stop_on_first_failure": True, "children": [], "hardware": "HW_UNVERIFIED",
               "synthesis_invocations": 0, "pnr_invocations": 0, "sta_invocations": 0,
               "board_invocations": 0, "network_invocations": 0}

    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8", newline="\n")

    save()
    for name, argv, reject in children:
        stdout, stderr = artifact / (name + ".stdout.log"), artifact / (name + ".stderr.log")
        result = {"name": name, "argv": argv, "expected_named_reject": reject}
        try:
            if seal_check() != seal_sha:
                raise ValueError("source seal changed before child")
            result.update(child(argv, stdout, stderr))
            result.update({"stdout_sha256": sha(stdout), "stderr_sha256": sha(stderr),
                           "stdout_bytes": stdout.stat().st_size, "stderr_bytes": stderr.stat().st_size})
            error_text = stderr.read_text(encoding="utf-8", errors="replace")
            if seal_check() != seal_sha:
                raise ValueError("source seal changed during child")
            passed = not result["timeout"] and (
                (result["returncode"] != 0 and plan["named_reject_module"] in error_text
                 and "Unknown module type" in error_text and "syntax error" not in error_text.lower())
                if reject else (result["returncode"] == 0 and result["stderr_bytes"] == 0))
            result["status"] = "EXPECTED_REJECT" if passed and reject else "PASS" if passed else "FAIL"
        except Exception as exc:
            result.update({"status": "BLOCKED", "exception": type(exc).__name__, "reason": str(exc)})
            for label, path in [("stdout", stdout), ("stderr", stderr)]:
                if path.is_file():
                    result[label + "_sha256"] = sha(path)
                    result[label + "_bytes"] = path.stat().st_size
            passed = False
        receipt["children"].append(result)
        if not passed:
            receipt["status"] = "STOPPED_FIRST_FAILURE"
            receipt["not_run_children"] = [x[0] for x in children[len(receipt["children"]):]]
            save()
            print(json.dumps({"status": receipt["status"], "child": name, "receipt": str(receipt_path)}))
            return 1
        save()
    receipt["status"] = "PREPARATION_PASS_NOT_HDL" if args.stage == "prepare" else "FINITE_MATRIX_PASS"
    receipt["completed_children"] = len(children)
    save()
    print(json.dumps({"status": receipt["status"], "receipt": str(receipt_path),
                      "receipt_sha256": sha(receipt_path)}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print("BLOCKED_BEFORE_CHILD: " + type(error).__name__ + ": " + str(error), file=sys.stderr)
        raise SystemExit(2)
