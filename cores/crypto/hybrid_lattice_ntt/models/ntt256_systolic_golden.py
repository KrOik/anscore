"""Golden behavioural model of ntt256_systolic_state_array.

The model is a bit-exact re-implementation of the array's *semantics* (stage
order, bank mapping, twiddle selection, butterfly arithmetic, inverse scaling
and the output digest fold).  It exists so the systolic array can be checked
against something other than digests recorded from the array itself:

  * it reproduces the four frozen op digests that the serial core, the
    scheduler and the array already agree on, which makes it a third,
    host-side leg of that contract;
  * it derives every twiddle from the primitive root instead of from the
    hardcoded table in the RTL, so a wrong table entry shows up here;
  * it answers structural questions the RTL-level benches cannot state,
    above all whether the INTT ops really invert the NTT ops.

Usage:  python ntt256_systolic_golden.py [--self-check]
"""

import argparse
import re
from pathlib import Path

RTL_PATH = Path(__file__).resolve().parents[1] / "src" / "ntt256_systolic_state_array.v"

OPS = {
    0: dict(name="KEM_NTT", dsa=False, inverse=False),
    1: dict(name="DSA_NTT", dsa=True, inverse=False),
    2: dict(name="KEM_INTT", dsa=False, inverse=True),
    3: dict(name="DSA_INTT", dsa=True, inverse=True),
}

FROZEN_DIGEST = {0: 0x1E664367, 1: 0x7FC8E2FC, 2: 0xB88A6C64, 3: 0xD23ECEF9}

STAGES = 8
POINTS = 256
DIGEST_SEED = 0x4E545432


def modulus(op):
    return 8380417 if OPS[op]["dsa"] else 3329


def root(op):
    return 3073009 if OPS[op]["dsa"] else 17


def n_inv(op):
    return 8347681 if OPS[op]["dsa"] else 3316


def init_vector(op):
    """The coefficient set S_INIT writes when auto_init is asserted."""
    q = modulus(op)
    out = []
    for index in range(POINTS):
        if OPS[op]["dsa"]:
            raw = (index << 16) + index + 12345
        else:
            raw = (index << 4) + index + 5
        out.append(raw - q if raw >= q else raw)
    return out


def stage_pairs(op, stage):
    """(addr_a, addr_b) for butterflies 0..127, exactly as the bank mapper does."""
    gap_log = (STAGES - 1 - stage) if OPS[op]["inverse"] else stage
    gap = 1 << gap_log
    low = gap - 1
    pairs = []
    for bfly in range(POINTS // 2):
        j = bfly & low
        base = ((bfly >> gap_log) << (gap_log + 1))
        pairs.append((base + j, base + j + gap))
    return pairs


def slot_exponent(op, stage, bfly):
    gap_log = (STAGES - 1 - stage) if OPS[op]["inverse"] else stage
    j = bfly & ((1 << gap_log) - 1)
    return (j << (STAGES - 1 - gap_log)) & 0xFF


def twiddle(op, stage, bfly):
    """Derived from the primitive root, never from the RTL table."""
    exponent = slot_exponent(op, stage, bfly)
    if OPS[op]["inverse"] and exponent:
        exponent = (0 - exponent) & 0xFF
    return pow(root(op), exponent, modulus(op))


def run_stage(op, stage, src):
    q = modulus(op)
    dst = list(src)
    for bfly, (addr_a, addr_b) in enumerate(stage_pairs(op, stage)):
        a = src[addr_a]
        b = src[addr_b]
        w = twiddle(op, stage, bfly)
        if OPS[op]["inverse"]:
            dst[addr_a] = (a + b) % q
            dst[addr_b] = ((a - b) * w) % q
        else:
            product = (b * w) % q
            dst[addr_a] = (a + product) % q
            dst[addr_b] = (a - product) % q
    return dst


def transform(op, src):
    """One op, in natural (numerical-address) order, over the given coefficients."""
    coeffs = list(src)
    for stage in range(STAGES):
        coeffs = run_stage(op, stage, coeffs)
    if OPS[op]["inverse"]:
        q = modulus(op)
        scale = n_inv(op)
        coeffs = [(value * scale) % q for value in coeffs]
    return coeffs


def rotl5(value):
    return ((value << 5) | (value >> 27)) & 0xFFFFFFFF


def digest(coeffs):
    """The fold the S_DIGEST_* states perform over the active bank."""
    acc = DIGEST_SEED
    for index, value in enumerate(coeffs):
        acc = rotl5(acc) ^ value ^ index
    return acc


def run_op(op, coeffs):
    return digest(transform(op, coeffs))


TABLE_RE = re.compile(
    r"8'd(\d+):\s*twiddle_value\s*=\s*(?:mode_dsa\s*\?\s*23'd(\d+)\s*:\s*)?23'd(\d+);"
)
DEFAULT_RE = re.compile(
    r"default:\s*twiddle_value\s*=\s*mode_dsa\s*\?\s*23'd(\d+)\s*:\s*23'd(\d+);"
)


def rtl_tables():
    """The hardcoded twiddle tables lifted out of the RTL function."""
    text = RTL_PATH.read_text(encoding="utf-8")
    body = text[text.index("function [22:0] twiddle_value;"):
                text.index("function [7:0] twiddle_exponent;")]
    kem, dsa = {}, {}
    for index, second, third in TABLE_RE.findall(body):
        index = int(index)
        if second:
            dsa[index] = int(second)
            kem[index] = int(third)
        else:
            dsa[index] = kem[index] = int(third)
    default_dsa, default_kem = (int(v) for v in DEFAULT_RE.search(body).groups())
    for index in range(POINTS):
        kem.setdefault(index, default_kem)
        dsa.setdefault(index, default_dsa)
    return {"kem": kem, "dsa": dsa}


def forward_table_index(stage, bfly):
    """The RTL's level-order table slot for a forward butterfly."""
    return ((1 << stage) - 1 + (bfly & ((1 << stage) - 1))) & 0xFF


def inverse_table_value(mode, exponent, table):
    q = 3329 if mode == "kem" else 8380417
    return 1 if exponent == 0 else (q - table[(255 - exponent) & 0xFF]) % q


def check_tables():
    """Every RTL table entry must equal the root power the datapath expects."""
    tables = rtl_tables()
    bad = []
    for mode, op in (("kem", 0), ("dsa", 1)):
        table = tables[mode]
        q = modulus(op)
        for stage in range(STAGES):
            for bfly in range(POINTS // 2):
                exponent = slot_exponent(op, stage, bfly)
                want = pow(root(op), exponent, q)
                got = table[forward_table_index(stage, bfly)]
                if got != want:
                    bad.append(("forward", mode, stage, bfly, got, want))
    for mode, op in (("kem", 2), ("dsa", 3)):
        table = tables[mode]
        q = modulus(op)
        for stage in range(STAGES):
            for bfly in range(POINTS // 2):
                exponent = slot_exponent(op, stage, bfly)
                want = pow(root(op), (-exponent) % 256, q)
                got = inverse_table_value(mode, exponent, table)
                if got != want:
                    bad.append(("inverse", mode, stage, bfly, got, want))
    return bad


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()

    bad_tables = check_tables()
    print("twiddle table entries inconsistent with the primitive root: %d"
          % len(bad_tables))
    for entry in bad_tables[:8]:
        print("   ", entry)

    ok = True
    for op in sorted(OPS):
        got = run_op(op, init_vector(op))
        want = FROZEN_DIGEST[op]
        flag = "ok" if got == want else "MISMATCH"
        ok = ok and got == want
        print("%-9s digest=%08x frozen=%08x %s" % (OPS[op]["name"], got, want, flag))

    print("root^128 == -1:", all(pow(root(op), 128, modulus(op)) == modulus(op) - 1
                                 for op in (0, 1)))
    print("256 * n_inv == 1 mod q:",
          all((256 * n_inv(op)) % modulus(op) == 1 for op in (0, 1)))

    for op in (0, 1):
        inv = op + 2
        vector = init_vector(op)
        round_trip = transform(inv, transform(op, vector))
        same = round_trip == vector
        print("%s -> %s round trip is the identity: %s"
              % (OPS[op]["name"], OPS[inv]["name"], same))
        if not same:
            diff = [i for i, (a, b) in enumerate(zip(round_trip, vector)) if a != b]
            print("      first differing indices:", diff[:8], "of", len(diff))

    if args.self_check and (not ok or bad_tables):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
