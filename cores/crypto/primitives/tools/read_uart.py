#!/usr/bin/env python3
# Capture the CRYPT selftest UART report from COM24 @115200.
# usage: python tools/read_uart.py <outfile> [seconds]
import sys
import time

import serial


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "doc/board_uart.txt"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
    port = serial.Serial("COM24", 115200, timeout=0.5)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < secs:
        chunk = port.read(4096)
        if chunk:
            buf += chunk
    port.close()
    with open(out, "wb") as f:
        f.write(buf)
    sys.stdout.write(buf.decode("ascii", "replace"))
    print("---\nwrote %s (%d bytes)" % (out, len(buf)))


if __name__ == "__main__":
    main()
