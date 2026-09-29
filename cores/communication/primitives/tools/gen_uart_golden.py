#!/usr/bin/env python3
# Generates sim/expected_report*.mem: the exact UART byte stream top.v emits
# for one COMM5 selftest report (17 lines x 32 chars).
# Usage: gen_uart_golden.py [unit_en_hex [out_name]]
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import UNITS, fnv, FNV_SEED

DIGESTS = [fnv(fn()[0]) for _, fn in UNITS]          # units 0..4
NAMES = [n for n, _ in UNITS] + ["----"] * 11


def pad32(s):
    assert len(s) <= 30
    return (s + " " * 30)[:30] + "\r\n"


def build(unit_en=0x001F):
    done_mask = 0xFFFF
    pass_mask = 0xFFFF                                # all enabled units pass
    msg = pad32("COMM5 M=%04X P=%04X" % (done_mask, pass_mask))
    for u in range(16):
        if not (unit_en >> u) & 1:
            st, dg = "S", FNV_SEED
        else:
            st, dg = "P", DIGESTS[u] if u < 5 else FNV_SEED
        msg += pad32("U%X %s %s D=%08X" % (u, NAMES[u], st, dg))
    return msg


if __name__ == "__main__":
    mask = 0x001F
    out_name = "expected_report.mem"
    args = sys.argv[1:]
    if args:
        mask = int(args[0], 16)
    if len(args) > 1:
        out_name = args[1]
    msg = build(unit_en=mask)
    assert len(msg) == 544
    out = os.path.join(ROOT, "sim", out_name)
    with open(out, "w") as f:
        for ch in msg:
            f.write("%02x\n" % ord(ch))
    print("wrote %s (%d bytes, mask=%04x)" % (out, len(msg), mask))
    print(msg)
