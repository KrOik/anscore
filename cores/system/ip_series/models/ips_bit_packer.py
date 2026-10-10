"""Independent golden model for ips_bit_packer.

Written from the packing contract in src/ips_bit_packer.v, never from simulation
output (docs/IP_CORE_SOP.md trap T1):

  * fields concatenate MSB-first into a reservoir whose valid bits always sit in its
    top ``resid`` positions; an accepted field is inserted at the top and the old
    content sinks by FIELD_BITS positions (fixed shifts only);
  * while ``resid >= OUT_BITS`` the packer emits one full word per enabled edge,
    taking the top OUT_BITS bits and shifting the reservoir left by OUT_BITS;
  * a burst closed by in_last, or an explicit flush request, emits the leftover
    ``resid < OUT_BITS`` bits as the top-aligned partial word (the reservoir keeps
    its unused low positions at zero, so the byte needs no masking), with
    pad_bits = OUT_BITS - resid; a flush that finds nothing buffered emits nothing
    and is counted as a spurious flush;
  * in_ready is high only in the load state, so fields presented during a drain or
    a flush are not consumed;
  * bits are conserved exactly: bits_in = cnt_fields * FIELD_BITS and
    bits_out + resid == bits_in at every enabled edge;
  * cnt_fields / cnt_words / cnt_flush / cnt_spur / bits_in / bits_out saturate at
    255 / 255 / 15 / 15 / 4095 / 4095 and latch cnt_sat[0] / [1] / [2] / [3] / [4] /
    [5]; a burst longer than MAX_BURST fields latches err_sticky[0] and a
    buffered-empty flush latches err_sticky[1]; burst_len is a live pointer that
    stops at 63 rather than wrapping; max_resid records the widest residual flushed.

The schedule below replays sim/tb_ips_bit_packer.v beat for beat; one beat is exactly
one enabled posedge (a beat with ce = 0 leaves the core untouched, including the
one-cycle out_valid pulse).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

FIELD_BITS = 11
OUT_BITS = 8
MAX_BURST = 24
ACC_BITS = FIELD_BITS + OUT_BITS
MASK_ACC = (1 << ACC_BITS) - 1
SEED = 0x2B8E1F73

LIM8 = 0xFF
LIM4 = 0xF
LIM12 = 0xFFF
BURST_STOP = 0x3F

P_LOAD, P_DRAIN, P_FLUSH = 0, 1, 2


class Dut(object):
    """Cycle model of ips_bit_packer, one enabled posedge per step()."""

    def __init__(self):
        self.st = P_LOAD
        self.resv = 0
        self.last_r = 0
        self.resid = 0
        self.pad = 0
        self.burst_len = 0
        self.out_valid = 0
        self.out_last = 0
        self.out_word = 0
        self.cnt_fields = 0
        self.cnt_words = 0
        self.cnt_flush = 0
        self.cnt_spur = 0
        self.max_resid = 0
        self.bits_in = 0
        self.bits_out = 0
        self.err = 0
        self.sat = 0

    @property
    def in_ready(self):
        return 1 if self.st == P_LOAD else 0

    def _bump(self, field, limit, sat_bit):
        if getattr(self, field) < limit:
            setattr(self, field, getattr(self, field) + 1)
        else:
            self.sat |= 1 << sat_bit

    def _bump_bits(self, field, amount, sat_bit):
        """Saturating accumulation of a bit-count register (width 12)."""
        if getattr(self, field) < LIM12:
            setattr(self, field, u(getattr(self, field) + amount, 12))
        else:
            self.sat |= 1 << sat_bit

    def step(self, v, l, d, fl):
        self.out_valid = 0
        self.out_last = 0
        if self.st == P_LOAD:
            self._load(v, l, d, fl)
        elif self.st == P_DRAIN:
            self._drain()
        elif self.st == P_FLUSH:
            self._flush()
        else:
            self.st = P_LOAD

    def _load(self, v, l, d, fl):
        if v:
            self.resv = ((self.resv >> FIELD_BITS)
                         | u(d << OUT_BITS, ACC_BITS)) & MASK_ACC
            self.resid = u(self.resid + FIELD_BITS, 5)
            self.st = P_DRAIN
            self._bump('cnt_fields', LIM8, 0)
            self._bump_bits('bits_in', FIELD_BITS, 4)
            if self.burst_len >= MAX_BURST:
                self.err |= 1
            if l:
                self.burst_len = 0
                self.last_r = 1
            else:
                if self.burst_len < BURST_STOP:
                    self.burst_len = u(self.burst_len + 1, 6)
                self.last_r = 0
        elif fl:
            if self.resid != 0:
                self.st = P_FLUSH
            else:
                self.err |= 2
                self._bump('cnt_spur', LIM4, 3)

    def _drain(self):
        if self.resid >= OUT_BITS:
            self.out_word = u(self.resv >> (ACC_BITS - OUT_BITS), OUT_BITS)
            self.out_valid = 1
            self.resv = (self.resv << OUT_BITS) & MASK_ACC
            self.resid = u(self.resid - OUT_BITS, 5)
            self.st = P_DRAIN
            self._bump('cnt_words', LIM8, 1)
            self._bump_bits('bits_out', OUT_BITS, 5)
        else:
            self.st = P_FLUSH if self.last_r else P_LOAD

    def _flush(self):
        if self.resid != 0:
            self.out_word = u(self.resv >> (ACC_BITS - OUT_BITS), OUT_BITS)
            self.out_valid = 1
            self.out_last = 1
            self.pad = u(OUT_BITS - u(self.resid, 4), 4)
            if self.resid > self.max_resid:
                self.max_resid = self.resid
            self._bump('cnt_flush', LIM4, 2)
            self._bump_bits('bits_out', self.resid, 5)
        else:
            self.err |= 2
            self._bump('cnt_spur', LIM4, 3)
        self.resv = 0
        self.resid = 0
        self.burst_len = 0
        self.last_r = 0
        self.st = P_LOAD


class Runner(object):
    def __init__(self):
        self.dut = Dut()
        self.bi = 0
        self.words = []

    def beat(self, v, l, d, fl, ce):
        acc = bool(ce and v and self.dut.in_ready)
        if ce:
            self.dut.step(v, l, d, fl)
        s = self.dut
        w = self.words
        w.append((s.in_ready << 2) | (s.out_valid << 1) | s.out_last)
        w.append(s.out_word)
        w.append(s.resid)
        w.append(s.pad)
        w.append(s.burst_len)
        w.append(s.cnt_fields)
        w.append(s.cnt_words)
        w.append(s.cnt_flush)
        w.append(s.cnt_spur)
        w.append(s.max_resid)
        w.append(s.err)
        w.append(s.sat)
        w.append(s.bits_in)
        w.append(s.bits_out)
        self.bi += 1
        return acc

    def send_field(self, l, d):
        while not self.beat(1, l, d, 0, 1):
            pass

    def close_burst_flush(self):
        q = 0
        while self.dut.in_ready != 1 and q < 32:
            self.beat(0, 0, 0, 0, 1)
            q += 1
        self.beat(0, 0, 0, 1, 1)

    def idle(self, n):
        for _ in range(n):
            self.beat(0, 0, 0, 0, 1)


def main():
    r = Runner()
    dut = r.dut
    state = SEED

    # ---------------- Phase A: random short bursts closed by in_last ----------
    for _ in range(7):
        state = (state * 1664525 + 1013904223) & MASK32
        blen = 1 + (state % 6)
        for q in range(blen):
            state = (state * 1664525 + 1013904223) & MASK32
            r.send_field(q == blen - 1, state & 0x7FF)
        r.idle(2)

    # ---------------- Phase B: burst longer than MAX_BURST, constant pattern ----
    for q in range(30):
        r.send_field(q == 29, 0x55A)
    r.idle(1)

    # ---------------- Phase C: mid-burst flush with a non-zero residual --------
    r.send_field(0, 0x003)
    r.send_field(0, 0x7FF)
    r.beat(0, 0, 0, 1, 1)
    r.idle(1)

    # ---------------- Phase D: burst lengths 1..8, every residual flushed ------
    for blen in range(1, 9):
        for _ in range(blen):
            state = (state * 1664525 + 1013904223) & MASK32
            r.send_field(0, state & 0x7FF)
        r.close_burst_flush()

    # ---------------- Phase E: spurious flushes, saturating cnt_spur -----------
    for _ in range(20):
        r.beat(0, 0, 0, 1, 1)

    # ---------------- Phase F: field held while in_ready is low ---------------
    r.send_field(0, 0x111)
    for _ in range(3):
        r.beat(1, 0, 0x3AA, 0, 1)
    r.send_field(1, 0x3AA)
    r.idle(1)

    # ---------------- Phase G: disabled clock must freeze the packer ----------
    r.beat(1, 0, 0x155, 0, 0)
    r.send_field(0, 0x155)
    r.send_field(1, 0x600)

    # ---------------- Phase H: final burst closed by an explicit flush --------
    for _ in range(5):
        state = (state * 1664525 + 1013904223) & MASK32
        r.send_field(0, state & 0x7FF)
    r.close_burst_flush()
    r.idle(6)

    w = r.words
    w.extend([dut.cnt_fields, dut.cnt_words, dut.cnt_flush, dut.cnt_spur,
              dut.max_resid, dut.burst_len, dut.resid, dut.err, dut.sat,
              dut.out_word, dut.bits_in, dut.bits_out])

    emit('ips_bit_packer', w)


if __name__ == '__main__':
    main()
