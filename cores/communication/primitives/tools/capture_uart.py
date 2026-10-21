#!/usr/bin/env python3
# Capture the COMM5 UART report from COM24 (115200 8N1) for `seconds` seconds.
# Usage: python tools/capture_uart.py [seconds] [outfile] [port]
import sys
import time
import serial

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0
outfile = sys.argv[2] if len(sys.argv) > 2 else "doc/board_uart_com24.txt"
port    = sys.argv[3] if len(sys.argv) > 3 else "COM24"

ser = serial.Serial(port, 115200, timeout=0.5)
t0 = time.time()
data = b""
while time.time() - t0 < seconds:
    chunk = ser.read(4096)
    if chunk:
        data += chunk
ser.close()
with open(outfile, "wb") as f:
    f.write(data)
sys.stdout.write("captured %d bytes -> %s\n" % (len(data), outfile))
sys.stdout.write(data.decode("ascii", "replace"))
