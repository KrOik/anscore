#!/usr/bin/env python3
"""Generate the expected ip25k_top UART report from the golden digest tables.

Sources of truth (independent of the RTL, per SOP trap T1):
  cores/system/extended_library/doc/VALIDATION_LOG.md   unit/digest table
  cores/crypto/primitives/doc/VALIDATION_LOG.md     AESB/SHAB/CRC8/CR16/CR32

Writes sim/expected_report.hex (space separated bytes) and
      sim/expected_report.txt  (raw bytes) for one full report cycle.
"""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "sim"

# (line index shown, tag, golden digest) -- wave2 units, then crypto units
W2 = [
    (0x13, "CRP ",  "450E7855"),
    (0x1B, "PWM ",  "89356055"),
    (0x1C, "QEI ",  "6E057083"),
    (0x20, "CRC ",  "CE9832E0"),
    (0x21, "PRBS",  "DBA2F926"),
    (0x25, "TMR ",  "DCA39FBD"),
    (0x26, "WDT ",  "B93E6C10"),
    (0x27, "LFSR",  "9867D947"),
]
CR = [
    (0x0, "AESB", "61C7D1CF"),
    (0x1, "SHAB", "566ACEA2"),
    (0x2, "CRC8", "FD957A4B"),
    (0x3, "CR16", "D0771E60"),
    (0x4, "CR32", "720D8B44"),
]


def unit_line(prefix: str, idx: int, tag: str, digest: str) -> str:
    s = f"{prefix}{idx >> 4:X}{idx & 0xF:X} {tag} P D={digest}"
    assert len(s) == 21, (s, len(s))
    return s + "  \r\n"


def main() -> None:
    lines = [unit_line("U", i, t, d) for i, t, d in W2]
    lines += [unit_line("C", i, t, d) for i, t, d in CR]
    n = len(W2) + len(CR)
    summary = f"IP25K DONE {n:02X} p{n:02X} PASS \r\n"
    lines.append(summary)
    assert len(summary) == 25, (repr(summary), len(summary))
    for ln in lines:
        assert len(ln) == 25, (repr(ln), len(ln))
    blob = "".join(lines).encode("ascii")

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "expected_report.txt").write_bytes(blob)
    (OUT / "expected_report.hex").write_text(
        " ".join(f"{b:02x}" for b in blob) + "\n", encoding="ascii"
    )
    print(f"wrote {len(blob)} bytes, {len(lines)} lines")
    print("".join(lines).replace("\r\n", "\\r\\n\n"), end="")


if __name__ == "__main__":
    main()
