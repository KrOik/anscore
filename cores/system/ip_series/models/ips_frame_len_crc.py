"""Independent golden model for ips_frame_len_crc.

Written from the core's documented framing contract, not from simulation output
(docs/IP_CORE_SOP.md trap T1): a length-prefixed frame is
``[LEN][P0 .. P(LEN-1)][CRC]`` with CRC-8 (poly 0x07, seed 0xFF, MSB first, no
reflection, no final xor) accumulated over LEN and the payload only.  The model
runs that state machine over the stimulus stream below and folds the same words,
in the same order, as sim/tb_ips_frame_len_crc.v.

Stimulus contract shared with the testbench:
    state = state * 1664525 + 1013904223 (mod 2**32), from 0x5A17C0DE
    kind = state[1:0], lb = state[4:2], gap = 2 + state[7:6]
    len  = 21 (kind 2, over-length) | 20 (kind 0 and lb 0) | lb+1 (kind 3) | lb
    payload byte p = state[7:0] ^ p ^ 0x3D
    in_start injected at payload index 2 for kind 0 with lb >= 5 (restart)
    in_last  injected at payload index min(1, len-1) for kind 3 (truncation),
             and on the length byte when kind 3 has len == 1
    check byte = frame CRC, xored with 0x5A for kind 1 (corrupted)
    frame 7's third gap beat is a clk_en-disabled beat carrying a byte the core
    must not consume
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

NFRAMES = 96
SEED = 0x5A17C0DE
LEN_MAX_TB = 20
FLIP_TB = 0x5A

CRC_POLY = 0x07
CRC_SEED = 0xFF
MAX_LEN = 20
CNT_MAX = 0xF

S_IDLE, S_DATA, S_CRC = 0, 1, 2


def crc_step(c_in, d_in, poly=CRC_POLY):
    c = (c_in ^ d_in) & 0xFF
    for _ in range(8):
        if c & 0x80:
            c = (((c << 1) & 0xFF) ^ poly) & 0xFF
        else:
            c = (c << 1) & 0xFF
    return c


def frame_crc(len_field, fst, nf):
    c = crc_step(CRC_SEED, len_field & 0xFF)
    for j in range(nf):
        c = crc_step(c, (fst & 0xFF) ^ (j & 0xFF) ^ 0x3D)
    return c


class Dut(object):
    """Cycle model of ips_frame_len_crc, one accepted byte per step()."""

    def __init__(self):
        self.st = S_IDLE
        self.rem = 0
        self.len_r = 0
        self.crc_run = 0
        self.out_valid = 0
        self.out_ok = 0
        self.out_len = 0
        self.out_crc = 0
        self.out_recv_crc = 0
        self.err_sticky = 0
        self.cnt = [0, 0, 0, 0, 0]      # good, bad_crc, over_len, trunc, restart
        self.cnt_sat = 0

    @property
    def in_ready(self):
        return 1 if self.st == S_IDLE else 0

    def _inc(self, idx, sat_bit, sticky_bit):
        if sticky_bit is not None:
            self.err_sticky |= 1 << sticky_bit
        if self.cnt[idx] < CNT_MAX:
            self.cnt[idx] += 1
        else:
            self.cnt_sat |= 1 << sat_bit

    def _report(self, ok, length, crc, recv):
        self.out_valid = 1
        self.out_ok = ok
        self.out_len = length
        self.out_crc = crc
        self.out_recv_crc = recv

    def step(self, valid, start, last, byte):
        self.out_valid = 0
        if not valid:
            return
        if start and self.st != S_IDLE:
            self._inc(4, 4, 3)
        if start:
            if last:
                self._report(0, byte & 0xFF, 0, 0)
                self.st = S_IDLE
                self.rem = 0
                self._inc(3, 2, 2)
            elif byte > MAX_LEN:
                self._report(0, byte & 0xFF, 0, 0)
                self.st = S_IDLE
                self.rem = 0
                self._inc(2, 1, 1)
            else:
                self.len_r = byte
                self.crc_run = crc_step(CRC_SEED, byte)
                if byte == 0:
                    self.st = S_CRC
                    self.rem = 0
                else:
                    self.st = S_DATA
                    self.rem = byte
        elif self.st == S_DATA:
            self.crc_run = crc_step(self.crc_run, byte)
            if last:
                self._report(0, self.len_r, self.crc_run, 0)
                self.st = S_IDLE
                self.rem = 0
                self._inc(3, 2, 2)
            elif self.rem == 1:
                self.st = S_CRC
                self.rem = 0
            else:
                self.rem -= 1
        elif self.st == S_CRC:
            good = 1 if self.crc_run == byte else 0
            self._report(good, self.len_r, self.crc_run, byte)
            self.st = S_IDLE
            self.rem = 0
            if good:
                self._inc(0, 0, None)
            else:
                self._inc(1, 3, 0)

    def fold_words(self):
        return [
            ((self.out_valid & 1) << 1) | (self.out_ok & 1),
            u(self.out_len, 32),
            u(self.out_crc, 32),
            u(self.out_recv_crc, 32),
            u(self.crc_run, 32),
            u(self.err_sticky, 32),
            self.in_ready,
        ]


def main():
    dut = Dut()
    state = SEED
    words = []

    for f in range(NFRAMES):
        state = (state * 1664525 + 1013904223) & MASK32
        kind = (state >> 0) & 3
        lb = (state >> 2) & 7
        gap = 2 + ((state >> 6) & 3)
        inj = 1 if (kind == 0 and lb >= 5) else 0

        if kind == 2:
            length = LEN_MAX_TB + 1
        elif kind == 0 and lb == 0:
            length = LEN_MAX_TB
        elif kind == 3:
            length = lb + 1
        else:
            length = lb
        tpos = 1 if length >= 2 else 0

        crcb = frame_crc(length, state, length)
        if kind == 1:
            crcb ^= FLIP_TB

        for g in range(gap):
            ce = not (f == 7 and g == 2)
            v = 1 if not ce else 0
            d = 0x2F if not ce else 0
            if ce:
                dut.step(v, 0, 0, d)
            words.extend(dut.fold_words())

        dut.step(1, 1, 1 if (kind == 3 and length == 1) else 0, length)
        words.extend(dut.fold_words())

        for p in range(length):
            dbyte = ((state >> 0) & 0xFF) ^ (p & 0xFF) ^ 0x3D
            bstart = 1 if (inj == 1 and p == 2) else 0
            blast = 1 if (kind == 3 and p == tpos) else 0
            dut.step(1, bstart, blast, dbyte)
            words.extend(dut.fold_words())

        if kind != 3:
            dut.step(1, 0, 1, crcb)
            words.extend(dut.fold_words())

    words.extend([
        dut.cnt[0], dut.cnt[1], dut.cnt[2], dut.cnt[3], dut.cnt[4],
        dut.cnt_sat, dut.err_sticky, dut.crc_run, dut.in_ready,
    ])

    emit('ips_frame_len_crc', words)


if __name__ == '__main__':
    main()
