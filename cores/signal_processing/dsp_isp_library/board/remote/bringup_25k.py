"""Bring-up / self-test runner for the Tang Primer 25K DOCK (GW5A-LV25MG121NES).

The 20K RMII UDP harness cannot be used on this board, so board acceptance on
the 25K goes over JTAG (volatile SRAM load) + the dock UART (/dev/ttyUSB1,
115200, FPGA TX on pin C3).  This script owns that path:

    python bringup_25k.py --fs <bitstream> --out <evidence-dir> \
                          [--expect '25K OK'] [--seconds 12]

The .fs is loaded into SRAM only (openFPGALoader default), so power-cycling the
board restores whatever is in flash; nothing here is persistent on the hardware.
"""
import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import paramiko

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from board_lock import BoardLock  # noqa: E402

HOST, USER, PASSWORD = "192.168.31.176", "bianbu", "bianbu"
RDIR = "/tmp/tang25k"


def run(cli, cmd, timeout=180):
    chan = cli.get_transport().open_session()
    chan.settimeout(timeout)
    chan.exec_command(cmd)
    out = b""
    err = b""
    end = time.time() + timeout
    while time.time() < end:
        while chan.recv_ready():
            out += chan.recv(65536)
        while chan.recv_stderr_ready():
            err += chan.recv(32768)
        if chan.exit_status_ready():
            break
        time.sleep(0.05)
    if not chan.exit_status_ready():
        chan.close()
        return 124, out.decode("utf-8", "replace"), "local timeout"
    return (chan.recv_exit_status(),
            out.decode("utf-8", "replace"),
            err.decode("utf-8", "replace"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--expect", default="25K OK")
    ap.add_argument("--uart", default="/dev/ttyUSB1")
    ap.add_argument("--baud", default="115200")
    ap.add_argument("--seconds", default="12")
    ap.add_argument("--board", default="tangprimer25k")
    a = ap.parse_args()

    fs = Path(a.fs).resolve()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    status = {
        "status": "FAIL",
        "started_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bitstream": str(fs),
        "expect": a.expect,
        "board": a.board,
        "uart": a.uart,
        "baud": int(a.baud),
    }

    with BoardLock(purpose="tang25k bringup/self-test", output=out, timeout=300) as lock:
        status["lock_token"] = lock.owner["token"]
        cli = paramiko.SSHClient()
        cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        cli.connect(HOST, username=USER, password=PASSWORD, timeout=15,
                    allow_agent=False, look_for_keys=False)
        try:
            sftp = cli.open_sftp()
            run(cli, "mkdir -p %s" % RDIR)
            rfs = "%s/design.fs" % RDIR
            sftp.put(str(fs), rfs)
            sftp.close()
            status["fs_remote"] = rfs
            status["fs_bytes"] = fs.stat().st_size

            rc, o, e = run(cli, "cd %s && openFPGALoader --detect -b %s 2>&1"
                           % (RDIR, a.board))
            status["detect_rc"] = rc
            status["detect"] = (o + e)[-600:]

            rc, o, e = run(cli, "cd %s && openFPGALoader -b %s design.fs 2>&1"
                           % (RDIR, a.board), timeout=300)
            status["program_rc"] = rc
            (out / "program.log").write_text("$ openFPGALoader -b %s design.fs\n%s%s"
                                             % (a.board, o, e), encoding="utf-8")

            cap = "%s/uart.bin" % RDIR
            rc, o, e = run(cli, "stty -F %s %s raw -echo && timeout %s "
                                "cat %s > %s 2>&1; echo rc=$?"
                                % (a.uart, a.baud, a.seconds, a.uart, cap))
            sftp = cli.open_sftp()
            sftp.get(cap, str(out / "uart_capture.log"))
            sftp.close()
            text = (out / "uart_capture.log").read_text(errors="replace")
            status["uart_bytes"] = len(text)
            hits = re.findall(re.escape(a.expect), text)
            status["expect_hits"] = len(hits)
            status["uart_excerpt"] = text[:400]
            status["status"] = "PASS" if (rc == 0 and status["program_rc"] == 0
                                          and len(hits) >= 3) else "FAIL"
        finally:
            cli.close()
        status["uart_capture"] = str(out / "uart_capture.log")

    (out / "verdict.json").write_text(json.dumps(status, indent=1,
                                                 ensure_ascii=False), encoding="utf-8")
    print(json.dumps(status, indent=1, ensure_ascii=False))
    return 0 if status["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
