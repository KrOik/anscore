#!/usr/bin/env python3
# ============================================================================
# golden_comm.py -- independent golden model for wave2 group F units:
#   can_ctrl (CAN), eth_mac_mii (MAC), pwm_gen (PWM), qei_dec (QEI),
#   step_drv (STP).
#
# Produces sim/golden_<unit>.txt (one %02x byte per line, the exact stream the
# st cell folds into its FNV-1a digest) and prints "<TAG> DIGEST=%08X".
#
# CRC15 (CAN, poly 0x4599) and CRC32 (ETH, poly 0xEDB88320) are implemented
# here from the polynomial definitions -- no RTL code is shared or copied.
# ============================================================================
import os
import sys

SIM = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', 'sim'))

def fnv(h, b):
    x = (h ^ b) & 0xFFFFFFFF
    return (x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24)) \
        & 0xFFFFFFFF

def fnv_stream(bs):
    h = 0x811C9DC5
    for b in bs:
        h = fnv(h, b)
    return h

def write_golden(name, bs):
    os.makedirs(SIM, exist_ok=True)
    p = os.path.join(SIM, 'golden_%s.txt' % name)
    with open(p, 'w') as f:
        for b in bs:
            f.write('%02x\n' % (b & 0xFF))
    return p

def pack_bits_msb(bits, pad=1):
    """Pack a bit list into bytes MSB-first; pad final byte with `pad`."""
    out = []
    for i in range(0, len(bits), 8):
        chunk = bits[i:i + 8]
        v = 0
        for j, b in enumerate(chunk):
            v |= (b & 1) << (7 - j)
        if len(chunk) < 8:
            v |= ((1 << (8 - len(chunk))) - 1) if pad else 0
        out.append(v)
    return out

# ============================================================================
# CAN -- CAN 2.0A frame model
# ============================================================================
CAN_FRAMES = [
    dict(fid=0x123, rtr=0, dlc=8,
         data=[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]),
    dict(fid=0x456, rtr=0, dlc=3, data=[0xA5, 0x5A, 0xC3]),
    dict(fid=0x7FF, rtr=1, dlc=0, data=[]),
    dict(fid=0x000, rtr=0, dlc=8,
         data=[0x00, 0xFF, 0x00, 0xFF, 0xAA, 0x55, 0xF0, 0x0F]),
]

def crc15_can(bits):
    """CAN CRC-15: poly x15+x14+x10+x8+x7+x4+x3+1 (0x4599), MSB-first."""
    crc = 0
    for b in bits:
        fb = (b ^ (crc >> 14)) & 1
        crc = ((crc << 1) & 0x7FFF) ^ (0x4599 if fb else 0)
    return crc

def can_stuff(bits):
    """Insert a complement bit after every run of 5 identical bits."""
    out, run, last = [], 0, 1
    for b in bits:
        if run == 5:
            out.append(1 - last)
            run = 0
        out.append(b)
        if run and b == last:
            run += 1
        else:
            run = 1
        last = b
    if run == 5:
        out.append(1 - last)
    return out

def can_frame_wire(f):
    """Return (wire_bits, crc15). wire_bits covers SOF..EOF incl. stuff bits;
    ACK slot is dominant on the wire (receiver drives it)."""
    logical = [0]                                            # SOF
    logical += [(f['fid'] >> (10 - i)) & 1 for i in range(11)]
    logical += [f['rtr'], 0, 0]                              # RTR, IDE, r0
    logical += [(f['dlc'] >> (3 - i)) & 1 for i in range(4)]
    nd = 0 if f['rtr'] else f['dlc']
    for d in f['data'][:nd]:
        logical += [(d >> (7 - i)) & 1 for i in range(8)]
    crc = crc15_can(logical)
    logical += [(crc >> (14 - i)) & 1 for i in range(15)]    # CRC seq
    wire = can_stuff(logical)
    wire += [1, 0, 1]                                        # CDEL, ACK, ADEL
    wire += [1] * 7                                          # EOF
    return wire, crc

def can_stream():
    bs = []
    for f in CAN_FRAMES:
        wire, crc = can_frame_wire(f)
        bs += pack_bits_msb(wire, pad=1)
        bs += [(f['fid'] >> 8) & 0x07, f['fid'] & 0xFF]
        bs += [(f['rtr'] << 4) | f['dlc']]
        nd = 0 if f['rtr'] else f['dlc']
        bs += f['data'][:nd]
        bs += [(crc >> 8) & 0x7F, crc & 0xFF]
        bs += [0x03]     # {form_err,stuff_err,crc_ok,tx_ack} = 0,0,1,1
    return bs

# ============================================================================
# ETH -- MII MAC model
# ============================================================================
def crc32_eth(crc, byte):
    """IEEE 802.3 CRC-32, reflected poly 0xEDB88320, init FFFFFFFF."""
    c = crc
    for i in range(8):
        fb = (c ^ (byte >> i)) & 1
        c = ((c >> 1) ^ (0xEDB88320 if fb else 0)) & 0xFFFFFFFF
    return c

OUR_MAC = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
SRC     = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
ETH_FRAMES = [
    dict(dest=OUR_MAC,                      typ=[0x08, 0x00], plen=46,
         pf=lambda i: (i * 7 + 3) & 0xFF),
    dict(dest=OUR_MAC,                      typ=[0x86, 0xDD], plen=100,
         pf=lambda i: (i * 9 + 0x42) & 0xFF),
    dict(dest=[0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC],
         typ=[0x08, 0x00], plen=46, pf=lambda i: (0xFF - i) & 0xFF),
    dict(dest=[0xFF] * 6,                   typ=[0x08, 0x00], plen=6,
         pf=lambda i: (i * 5 + 7) & 0xFF),
]

def eth_stream():
    bs = []
    for f in ETH_FRAMES:
        body = list(f['dest']) + SRC + list(f['typ']) + \
               [f['pf'](i) for i in range(f['plen'])]
        while len(body) < 60:
            body.append(0)                       # pad to min frame
        crc = 0xFFFFFFFF
        for b in body:
            crc = crc32_eth(crc, b)
        fcs = (~crc) & 0xFFFFFFFF
        fcs_b = [fcs & 0xFF, (fcs >> 8) & 0xFF,
                 (fcs >> 16) & 0xFF, (fcs >> 24) & 0xFF]
        rx = body + fcs_b                        # post-SFD byte stream
        # residue check: same CRC over frame+FCS must be 0xDEBB20E3
        rc = 0xFFFFFFFF
        for b in rx:
            rc = crc32_eth(rc, b)
        assert rc == 0xDEBB20E3, 'FCS residue check failed: %08X' % rc
        match = (f['dest'] == OUR_MAC) or (f['dest'] == [0xFF] * 6)
        bs += rx
        bs += [len(rx) & 0xFF]
        bs += [(1 if match else 0) << 2 | 0b011]   # match,len_ok,crc_ok
    return bs

# ============================================================================
# PWM -- counter/compare model
# ============================================================================
def pwm_stream():
    bs = []
    for (period, duties, wlen) in [(24, [0, 7, 13, 24], 72),
                                   (16, [5, 12, 16, 0], 32)]:
        rise = [0] * 4
        high = [0] * 4
        prev = [0] * 4
        for k in range(wlen):
            cnt = k % period
            cur = [1 if cnt < duties[ch] else 0 for ch in range(4)]
            for ch in range(4):
                if cur[ch] and not prev[ch]:
                    rise[ch] += 1
                high[ch] += cur[ch]
            prev = cur
        for ch in range(4):
            bs += [rise[ch] & 0xFF, (high[ch] >> 8) & 0xFF, high[ch] & 0xFF]
        bs += [sum(prev[ch] << ch for ch in range(4))]
    return bs

# ============================================================================
# QEI -- x4 quadrature decode model
# ============================================================================
def qei_stream():
    # emitted quadrature values per cycle (each yields exactly 4 edges)
    tab = {1: [0b10, 0b11, 0b01, 0b00],    # fwd: 00->10->11->01->00
           0: [0b01, 0b11, 0b10, 0b00]}    # rev: 00->01->11->10->00
    segs = [(1, 20), (1, 5), (0, 7), (1, 3)]
    idx_after = {0: 1, 2: 0}               # seg index -> idx_rst flag
    count = 0
    steps = 0
    pa = pb = 0
    bs = []

    def emit(ab):
        nonlocal count, steps, pa, pb
        a, b = (ab >> 1) & 1, ab & 1
        ar = a and not pa
        af = (not a) and pa
        br = b and not pb
        bf = (not b) and pb
        up = (ar and not b) or (af and b) or (br and a) or (bf and not a)
        dn = (ar and b) or (af and not b) or (br and not a) or (bf and a)
        if up:
            count += 1
            steps += 1
        elif dn:
            count -= 1
            steps += 1
        pa, pb = a, b

    last_dir = 1
    for si, (d, nc) in enumerate(segs):
        for _ in range(nc):
            for ph in range(4):
                emit(tab[d][ph])
            bs += [(count >> 8) & 0xFF, count & 0xFF]
        last_dir = d
        if si in idx_after:
            latch = count & 0xFFFFFFFF
            if idx_after[si]:
                count = 0
            bs += [(latch >> 8) & 0xFF, latch & 0xFF, idx_after[si]]
    bs += [last_dir, steps & 0xFF]
    assert steps == 140
    return bs

# ============================================================================
# STP -- step/dir trapezoidal profile model
# ============================================================================
def step_stream():
    bs = []
    # (tgt, tstart, tmin, tdec, dir)
    for (tgt, ts, tmin, tdec, dr) in [(30, 24, 6, 4, 1), (12, 20, 8, 5, 0)]:
        iv = ts
        acnt = 0
        # cur_interval during step pulse k (1..tgt-1) already holds the
        # interval governing gap k -> k+1 (register updated on the eval beat
        # that raises `step`), i.e. the folded stream is i_2 .. i_tgt.
        for k in range(1, tgt):
            rem = tgt - k
            if rem <= acnt:
                iv = iv + tdec                     # decelerate
            elif iv > tmin:
                iv = max(iv - tdec, tmin)          # accelerate
                acnt += 1
            # else cruise
            bs.append(iv & 0xFF)
        bs += [tgt & 0xFF, dr]
    return bs

# ============================================================================
def main():
    streams = {
        'CAN': ('can_ctrl',    can_stream()),
        'MAC': ('eth_mac_mii', eth_stream()),
        'PWM': ('pwm_gen',     pwm_stream()),
        'QEI': ('qei_dec',     qei_stream()),
        'STP': ('step_drv',    step_stream()),
    }
    for tag, (name, bs) in streams.items():
        write_golden(name, bs)
        print('%s DIGEST=%08X' % (tag, fnv_stream(bs)))
    return 0

if __name__ == '__main__':
    sys.exit(main())
