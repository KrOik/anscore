#!/usr/bin/env python3
# ============================================================================
# gen_report_golden.py -- build sim/expected_report_<mask>.mem by scraping the
# EXP digests out of the committed src/st_*.v cells and replaying the exact
# report_char() layout used by generated src/top.v.
# Run from cores/system/extended_library/:  python tools/gen_report_golden.py [maskhex]
# ============================================================================
import os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), "..")
SRC = os.path.join(ROOT, "src")
SIM = os.path.join(ROOT, "sim")

UNITS = []
for line in open(os.path.join(ROOT, "tools", "gen_harness.py")):
    m = re.match(r'\s*\(\s*(\d+),\s*"([^"]+)",\s*"st_([a-z0-9_]+)"\s*\)', line)
    if m:
        UNITS.append((int(m.group(1)), m.group(2), "st_" + m.group(3)))
UNITS.sort()

def scrape_exp(mod):
    f = os.path.join(SRC, mod + ".v")
    if not os.path.exists(f):
        return None
    txt = open(f, encoding="utf-8", errors="replace").read()
    m = re.search(r'EXP\s*=\s*32\'h([0-9A-Fa-f]{8})', txt)
    return int(m.group(1), 16) if m else None

def fmt(mask):
    done = mask          # cells that ran -> done
    passed = mask        # assume pass == golden (report shows digest itself)
    lines = []
    lines.append("W240 M=%010X P=%010X" % (done & 0xFFFFFFFFFF,
                                            passed & 0xFFFFFFFFFF))
    for idx, tag, mod in UNITS:
        dg = scrape_exp(mod)
        if not (mask >> idx) & 1:
            v = "S"; dg = 0
        elif dg is None:
            v = "X"; dg = 0xDEADBEEF
        else:
            v = "P"
        lines.append("U%02X %-4s %s D=%08X" % (idx, tag, v, dg))
    return "".join((l + " " * (30 - len(l)) + "\r\n") for l in lines)

def main():
    mask = int(sys.argv[1], 16) if len(sys.argv) > 1 else (1 << 40) - 1
    txt = fmt(mask)
    name = "expected_report_%010x.mem" % mask
    with open(os.path.join(SIM, name), "w", newline="\n") as f:
        for ch in txt:
            f.write("%02x\n" % ord(ch))
    print("wrote sim/%s (%d chars)" % (name, len(txt)))

if __name__ == "__main__":
    main()
