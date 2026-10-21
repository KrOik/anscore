#!/usr/bin/env python3
# Generates sim/expected_report.mem: the exact UART byte stream that top.v
# emits for one CRYPT selftest report (6 lines x 32 chars).
# Digests come from the independent golden model (tools/golden_model.py).
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import compute

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UNITS = ["AESB", "SHAB", "CRC8", "CR16", "CR32"]


def pad32(s):
    assert len(s) <= 30
    return (s + " " * 30)[:30] + "\r\n"


def build(digests, unit_en=0x1F):
    # skipped units tie done=1 and pass by construction -> masks stay 0x1F
    done_mask = 0x1F
    pass_mask = 0x1F
    msg = pad32("CRYPT M=%04X P=%04X" % (done_mask, pass_mask))
    for u, name in enumerate(UNITS):
        if not (unit_en >> u) & 1:
            st, dg = "S", 0x811C9DC5        # skipped: FNV seed digest
        else:
            st, dg = "P", digests[name]
        msg += pad32("U%X %s %s D=%08X" % (u, name, st, dg))
    return msg


if __name__ == "__main__":
    mask = 0x1F
    out_name = "expected_report.mem"
    args = sys.argv[1:]
    if args:
        mask = int(args[0], 16)
    if len(args) > 1:
        out_name = args[1]
    digests = compute()["digests"]
    msg = build(digests, unit_en=mask)
    assert len(msg) == 192
    out = os.path.join(ROOT, "sim", out_name)
    with open(out, "w") as f:
        for ch in msg:
            f.write("%02x\n" % ord(ch))
    print("wrote %s (%d bytes, mask=%02x)" % (out, len(msg), mask))
    print(msg)
