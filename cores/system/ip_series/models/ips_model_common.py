"""Shared helpers for the ip_series_20k independent golden models.

Every core ships models/ips_<name>.py.  That file is the golden side of the
production line: it computes the reference output stream from the core's
written contract (not from simulation output, docs/IP_CORE_SOP.md trap T1) and
folds it with the same FNV-1a byte order the testbench uses, so
scripts/ip_series_harness.ps1 can compare the two digests directly.

Print the last line as:  MODEL ips_<name> D=<8 hex>
"""

MASK32 = 0xFFFFFFFF
FNV_BASIS = 0x811C9DC5
FNV_PRIME = 0x01000193


def fnv_word(h, word):
    """Fold one 32-bit word, MSB byte first -- mirrors ips_fnv_word()."""
    word &= MASK32
    for shift in (24, 16, 8, 0):
        h = ((h ^ ((word >> shift) & 0xFF)) * FNV_PRIME) & MASK32
    return h


def digest(words):
    h = FNV_BASIS
    for w in words:
        h = fnv_word(h, w)
    return h


def emit(name, words, cycles=None):
    d = digest(words)
    if cycles is None:
        print("MODEL %s D=%08X" % (name, d))
    else:
        print("MODEL %s D=%08X C=%d" % (name, d, cycles))
    return d


def u(value, bits):
    """Truncate to an unsigned bit vector."""
    return value & ((1 << bits) - 1)


def s(value, bits):
    """Interpret the low `bits` of value as two's complement."""
    v = u(value, bits)
    if bits > 0 and (v >> (bits - 1)) & 1:
        v -= (1 << bits)
    return v


def sat_clamp(value, bits):
    """Signed saturation to `bits` wide Q-format.  Returns (clamped, overflow)."""
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if value < lo:
        return lo, True
    if value > hi:
        return hi, True
    return value, False


def headroom_bits(value, width, guard):
    """The guard bits above bit width-1 of the two's-complement sum, as the RTL
    slice sum[width+guard-1:width] would report them."""
    return (value >> width) & ((1 << guard) - 1)


def lcg32(state):
    """The shared deterministic stimulus generator used by the series TBs."""
    return (state * 1664525 + 1013904223) & MASK32
