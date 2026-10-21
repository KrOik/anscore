#!/usr/bin/env python3
# Generates sim/expected_report*.mem: the exact UART byte stream top.v emits
# for one DSP5 selftest report (6 lines x 32 chars).
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import STREAMS, digest

UNITS = [(name.ljust(4), digest(fn())) for name, fn in STREAMS.items()]

def pad32(s):
    assert len(s) <= 30
    return (s + " " * 30)[:30] + "\r\n"

def build(done_mask=0x001f, pass_mask=0x001f, unit_en=0x001f):
    msg = pad32("DSP5 M=%04X P=%04X" % (done_mask, pass_mask))
    for u, (name, dg) in enumerate(UNITS):
        if not (unit_en >> u) & 1:
            st, dg = "S", 0x811c9dc5        # skipped: seed digest
        else:
            st = "P" if (pass_mask >> u) & 1 else "F"
        msg += pad32("U%X %s %s D=%08X" % (u, name, st, dg))
    return msg

if __name__ == "__main__":
    mask = 0x001f
    out_name = "expected_report.mem"
    args = sys.argv[1:]
    if args:
        mask = int(args[0], 16)
    if len(args) > 1:
        out_name = args[1]
    msg = build(unit_en=mask)
    assert len(msg) == 192
    out = os.path.join(ROOT, "sim", out_name)
    with open(out, "w") as f:
        for ch in msg:
            f.write("%02x\n" % ord(ch))
    print("wrote %s (%d bytes, mask=%04x)" % (out, len(msg), mask))
    print(msg)
