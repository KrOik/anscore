#!/usr/bin/env python3
# Independent golden model for comm_20k selftest units (SOP trap T1: expected
# values must come from a model that does NOT read RTL simulation output).
#
# Computes, per unit:
#   * the exact byte stream folded by the RTL FNV-1a digest
#   * the expected digest value
#   * a reference dump file (sim/golden_*.txt) in the same format as the
#     testbench dumps, for byte-level diffing before trusting the digest.
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "sim")

FNV_SEED = 0x811C9DC5
FNV_PRIME = 0x01000193


def fnv(stream):
    h = FNV_SEED
    for b in stream:
        h ^= b
        h = (h * FNV_PRIME) & 0xFFFFFFFF
    return h


# --------------------------------------------------------------------------
# U0 uart_rx loopback
# --------------------------------------------------------------------------
def uart_stream():
    """8 loopback bytes p(i)=i*29+7 each folded with ferr=0, then a
    bit-banged good frame 0x3C (ferr=0) and a bad-stop frame 0x00 (ferr=1)."""
    stream = []
    dump = []
    for i in range(8):
        p = (i * 29 + 7) & 0xFF
        stream += [p, 0]
        dump.append("%02x 0" % p)
    stream += [0x3C, 0]
    dump.append("3c 0")
    stream += [0x00, 1]
    dump.append("00 1")
    return stream, dump


# --------------------------------------------------------------------------
# U1 spi_master vs LFSR loopback slave
# --------------------------------------------------------------------------
def lfsr8_seq(n, seed=0xB7):
    """MISO bit stream: s0=seed[7]; lfsr<={l[6:0],l[7]^l[5]^l[4]^l[3]} per bit."""
    l = seed
    out = []
    for _ in range(n):
        out.append((l >> 7) & 1)
        fb = ((l >> 7) ^ (l >> 5) ^ (l >> 4) ^ (l >> 3)) & 1
        l = ((l << 1) | fb) & 0xFF
    return out


def bits_to_word(bits):
    """MSB-first assembly: first bit ends up at the top of the n-bit field."""
    w = 0
    for b in bits:
        w = ((w << 1) | b) & 0xFFFFFFFF
    return w


def spi_stream():
    """transfers (nbits, tx): (8,0xA5),(16,0x3C5A),(32,0xC0FFEE11).
    Fold: master rx word bytes MSB->LSB, then slave captured word bytes."""
    stream = []
    dump = []
    for nbits, tx in [(8, 0x000000A5), (16, 0x00003C5A), (32, 0xC0FFEE11)]:
        miso = lfsr8_seq(nbits)
        rxw = bits_to_word(miso)                # master's received word
        cap = tx                                 # slave captures mosi verbatim
        nb = nbits // 8
        dump.append("rx %08x" % rxw)
        dump.append("cap %08x %d" % (cap, nbits))
        for k in range(nb - 1, -1, -1):
            stream.append((rxw >> (8 * k)) & 0xFF)
        for k in range(nb - 1, -1, -1):
            stream.append((cap >> (8 * k)) & 0xFF)
    return stream, dump


# --------------------------------------------------------------------------
# U2 i2c_master vs slave model
# --------------------------------------------------------------------------
def i2c_stream():
    """T0 write 0x42 {DE,AD,BE,EF} -> [st=0, cnt=4, DE,AD,BE,EF]
       T1 read  0x42 len=5          -> [r0..r4 as received, st=0]
       T2 write 0x55 {99} nacked    -> [st=1]
       T3 write 0x42 {11,22,33} str -> [st=0, cnt=3, 11,22,33]"""
    stream = []
    dump = []
    # T0
    stream += [0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]
    dump += ["st 0", "cnt 4 cap de", "cnt 4 cap ad", "cnt 4 cap be",
             "cnt 4 cap ef"]
    # T1 read pattern r(k)=k*41+0x17
    for k in range(5):
        b = (k * 41 + 0x17) & 0xFF
        stream.append(b)
        dump.append("rx %02x" % b)
    stream.append(0x00)
    dump.append("st 0")
    # T2 addr nack
    stream.append(0x01)
    dump.append("st 1")
    # T3 stretch write
    stream += [0x00, 0x03, 0x11, 0x22, 0x33]
    dump += ["st 0", "cnt 3 cap 11", "cnt 3 cap 22", "cnt 3 cap 33"]
    return stream, dump


# --------------------------------------------------------------------------
# U3 axil_slave reg bank
# --------------------------------------------------------------------------
def axil_stream():
    """ops: W 0x0C DEADBEEF/F, W 0x1C 12345678/5, R 0x0C, R 0x1C,
            W 0x80 (SLVERR), R 0x40 (SLVERR), R 0x05 (SLVERR), R 0x00."""
    regs = [0] * 16
    stream = []
    dump = []

    def wr(addr, data, strb):
        ok = (addr < 0x40) and (addr & 3) == 0
        if ok:
            for i in range(4):
                if (strb >> i) & 1:
                    idx = (addr >> 2) & 0xF
                    regs[idx] = (regs[idx] & ~(0xFF << (8 * i))) | \
                                (((data >> (8 * i)) & 0xFF) << (8 * i))
            resp = 0
        else:
            resp = 2
        stream.append(resp)
        dump.append("bresp %02x" % resp)

    def rd(addr):
        ok = (addr < 0x40) and (addr & 3) == 0
        data = regs[(addr >> 2) & 0xF] if ok else 0
        resp = 0 if ok else 2
        for i in range(4):
            stream.append((data >> (8 * i)) & 0xFF)
        stream.append(resp)
        dump.append("rdata %08x rresp %02x" % (data, resp))

    wr(0x0C, 0xDEADBEEF, 0xF)
    wr(0x1C, 0x12345678, 0x5)
    rd(0x0C)
    rd(0x1C)
    wr(0x80, 0x55, 0xF)
    rd(0x40)
    rd(0x05)
    rd(0x00)
    return stream, dump


# --------------------------------------------------------------------------
# U4 fifo_async dual-clock
# --------------------------------------------------------------------------
def fifo_stream():
    """40 bytes p(i)=i*29+5 then {7'd0, full_seen=1}."""
    stream = [(i * 29 + 5) & 0xFF for i in range(40)]
    stream.append(0x01)
    dump = ["%02x" % b for b in stream[:40]]
    return stream, dump


UNITS = [
    ("URX ", uart_stream),
    ("SPIM", spi_stream),
    ("I2CM", i2c_stream),
    ("AXIL", axil_stream),
    ("FIFO", fifo_stream),
]

DUMP_NAME = {"URX ": "golden_urx.txt", "SPIM": "golden_spi.txt",
             "I2CM": "golden_i2c.txt", "AXIL": "golden_axil.txt",
             "FIFO": "golden_fifo.txt"}


def main():
    digests = []
    for name, fn in UNITS:
        stream, dump = fn()
        d = fnv(stream)
        digests.append(d)
        print("%-4s stream=%3d bytes  digest=%08X" % (name.strip(), len(stream), d))
        with open(os.path.join(SIM, DUMP_NAME[name]), "w") as f:
            f.write("\n".join(dump) + "\n")
    return digests


if __name__ == "__main__":
    main()
