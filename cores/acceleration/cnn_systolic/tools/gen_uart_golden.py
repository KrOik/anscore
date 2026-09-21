# Generates sim/expected_report.mem: the exact UART byte stream that top.v
# emits for one CNN16 selftest report (17 lines x 32 chars).
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UNITS = [
    ("PE  ", 0xb865ec67), ("PED ", 0xb865ec67), ("DM  ", 0x783b6c25),
    ("WM  ", 0x6a9e1ac5), ("RAM ", 0x2339d078), ("FIFO", 0xd0c7c975),
    ("COL ", 0xd149a670), ("PAGE", 0xc5bab594), ("POOL", 0x35a02396),
    ("ALUT", 0x830a5f5f), ("IL  ", 0x41c4c21f), ("OL  ", 0x46e9e19d),
    ("LAYR", 0x9a9aea61), ("EXTR", 0x931885aa), ("SSUM", 0x77330ec1),
    ("CTC ", 0xed74208a),
]

def pad32(s):
    assert len(s) <= 30
    return (s + " " * 30)[:30] + "\r\n"

def build(done_mask=0xffff, pass_mask=0xffff, unit_en=0xffff):
    msg = pad32("CNN16 M=%04X P=%04X" % (done_mask, pass_mask))
    for u, (name, dg) in enumerate(UNITS):
        if not (unit_en >> u) & 1:
            st, dg = "S", 0x811c9dc5        # skipped: seed digest
        else:
            st = "P" if (pass_mask >> u) & 1 else "F"
        msg += pad32("U%X %s %s D=%08X" % (u, name, st, dg))
    return msg

if __name__ == "__main__":
    mask = 0xffff
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
