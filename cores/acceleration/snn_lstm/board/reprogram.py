"""Program a 25K dock bitstream and capture the acceptance lines, without the
board lock (bringup_25k.py's capture step intermittently blocks).

    python board/reprogram.py <local.fs> [seconds]

Prints the remote loader tail, the byte count, and a per-line tally of the
streamed report lines.
"""
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]
                       / "dsp_isp_library" / "board" / "remote"))
import bringup_25k as B  # noqa: E402  (reuses HOST/USER/PASSWORD + run())

import paramiko  # noqa: E402

LINE = re.compile(rb"(SNN PASS \S+ \S+ \S+ \S+ \S+|LSTM PASS \S+ \S+ \S+ \S+"
                  rb"|25K SNNLSTM PASS \S+|SNNLSTM ALIVE|DIAG \S+ \S+)")


def main() -> int:
    fs = Path(sys.argv[1]).resolve()
    seconds = sys.argv[2] if len(sys.argv) > 2 else "25"
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(B.HOST, username=B.USER, password=B.PASSWORD, timeout=15,
                allow_agent=False, look_for_keys=False)
    sftp = cli.open_sftp()
    sftp.put(str(fs), "/tmp/tang25k/design.fs")
    sftp.close()
    print("uploaded", fs.name, fs.stat().st_size, "bytes")
    rc, out, err = B.run(cli, "openFPGALoader -b tangprimer25k /tmp/tang25k/design.fs 2>&1",
                         timeout=300)
    print("program rc=", rc, (out + err)[-160:].replace("\n", " "))
    cap = "/tmp/tang25k/uart2.bin"
    B.run(cli, "stty -F /dev/ttyUSB1 115200 raw -echo; timeout 3 cat /dev/ttyUSB1 > /dev/null;"
               " rm -f %s; stty -F /dev/ttyUSB1 115200 raw -echo; timeout %s cat /dev/ttyUSB1 > %s"
            % (cap, seconds, cap))
    sftp = cli.open_sftp()
    sftp.get(cap, str(Path(__file__).resolve().parent / "uart_last.log"))
    sftp.close()
    cli.close()
    text = (Path(__file__).resolve().parent / "uart_last.log").read_bytes()
    print("captured bytes:", len(text))
    tally = {}
    for m in LINE.finditer(text):
        tally[m.group(1).decode()] = tally.get(m.group(1).decode(), 0) + 1
    for k, v in sorted(tally.items(), key=lambda kv: -kv[1]):
        print("%3d  %s" % (v, k))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
