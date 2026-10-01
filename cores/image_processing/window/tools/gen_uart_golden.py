#!/usr/bin/env python3
# Generate sim/expected_report*.mem: the exact UART byte stream top.v emits
# for one imgwin selftest report (7 lines x 32 chars) for a given UNIT_EN
# mask.  Digests come from the independent golden model (golden_model.py).
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from golden_model import digests, NAMES, FNV_SEED

DG = digests()


def pad32(s):
    assert len(s) <= 30
    return (s + " " * 30)[:30] + "\r\n"


def build(unit_en=0x3F):
    done_mask = 0x3F
    pass_mask = 0x3F
    msg = pad32("IMG6 M=%02X P=%02X" % (done_mask, pass_mask))
    for u, n in enumerate(NAMES):
        if not (unit_en >> u) & 1:
            st, d = "S", FNV_SEED        # skipped: seed digest
        else:
            st, d = "P", DG[n]
        msg += pad32("U%d %-4s %s D=%08X" % (u, n, st, d))
    return msg


if __name__ == "__main__":
    masks = sys.argv[1:] or ["3f"]
    for m in masks:
        mask = int(m, 16)
        out_name = "expected_report.mem" if mask == 0x3F else \
                   "expected_report_%02x.mem" % mask
        msg = build(unit_en=mask)
        assert len(msg) == 224
        out = os.path.join(ROOT, "sim", out_name)
        with open(out, "w") as f:
            for ch in msg:
                f.write("%02x\n" % ord(ch))
        print("wrote %s (%d bytes, mask=%02x)" % (out, len(msg), mask))
    print(build())
