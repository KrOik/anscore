"""Independent golden model for ips_rle_codec.

Derived from the core's written token contract, never from simulation output
(docs/IP_CORE_SOP.md trap T1): ctrl = {REP, RUN[6:0]} with RUN holding run-1, so a
token carries 1..128 payload bytes; a literal token (REP = 0) carries RUN = 0.
MAX_RUN = 20 is the capacity this configuration advertises, so

  * the encoder packs a longer run as consecutive full-20-byte repeat tokens,
    latches err_sticky[0] once per byte that continued a full-field token and
    counts it in run_ovf;
  * the decoder expands a token asking for more than MAX_RUN bytes anyway, but
    latches err_sticky[1] and counts it in tok_ovf;
  * a direction change or an in_last marker that lands while work is in flight, and
    a literal token with a non-zero run field, latch err_sticky[2] and count in
    err_proto.

The stimulus schedule below mirrors sim/tb_ips_rle_codec.v beat for beat.  One beat
is exactly one enabled posedge (clk_en is low on the intervening edge); a beat with
ce = 0 leaves the core untouched.  out_ready follows the testbench pattern
``low when beat_index % 3 == 2``, and a byte is re-presented until in_ready accepts
it, which the model reproduces with its own accept flag.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

NPACK = 6
NRUNS = 5
NPENC2 = 3
SEED = 0x13579BDF
ORDY_SLOT = 3

TOK_LIT = 0x00
TOK_REP = 0x80
RUN_ONE = 1
EXP_LIT_N = 1
EXP_LAST = 1
MAX_RUN = 20
CAP_MAX = MAX_RUN
CAP_FIELD = MAX_RUN - 1

E_RUN, E_TOKC, E_TOKD = 0, 1, 2
D_CTRL, D_DATA, D_EXP = 0, 1, 2

TOKTAB = {0: 0x00, 1: 0x80, 2: 0x81, 3: 0x82, 4: 0x87, 5: 0x93,
          6: 0x98, 7: 0x9E, 8: 0x05, 9: 0x81, 10: 0x93, 11: 0x93}


def tok_ctrl_at(t):
    return TOKTAB.get(t, 0x93)


def tok_data_at(t):
    return u(0x90 ^ t, 8)


class Dut(object):
    """Cycle model of ips_rle_codec, one enabled posedge per step()."""

    def __init__(self):
        self.dir_r = 0
        self.est = E_RUN
        self.dst = D_CTRL
        self.have = 0
        self.cont_r = 0
        self.tail_pend = 0
        self.rep_r = 0
        self.prev = 0
        self.ctrl_r = 0
        self.dbyte = 0
        self.exp_len = 0
        self.tok_ctrl = 0
        self.tok_data = 0
        self.out_valid = 0
        self.out_byte = 0
        self.run_len = 0
        self.tok_cnt = 0
        self.lit_cnt = 0
        self.run_ovf = 0
        self.tok_ovf = 0
        self.exp_cnt = 0
        self.err_proto = 0
        self.err_sticky = 0
        self.cnt_sat = 0

    # ---- combinational helpers (pre-edge and post-edge share these) ----------
    def _flags(self, dir_, ordy):
        slot_free = (not self.out_valid) or bool(ordy)
        enc_infl = bool(self.est != E_RUN or self.tail_pend)
        dec_infl = bool(self.dst != D_CTRL)
        if dir_:
            rx_state = bool(self.dst in (D_CTRL, D_DATA))
        else:
            rx_state = bool(self.est == E_RUN and not self.tail_pend)
        in_ready = slot_free and rx_state
        busy = bool(self.out_valid or enc_infl or dec_infl or self.cont_r or self.have)
        tok_infl = bool(enc_infl or (self.rep_r and self.dst == D_EXP))
        return in_ready, busy, tok_infl

    def in_ready(self, dir_, ordy):
        return self._flags(dir_, ordy)[0]

    def _bump(self, field, limit, sat_bit):
        if getattr(self, field) < limit:
            setattr(self, field, getattr(self, field) + 1)
        else:
            self.cnt_sat |= 1 << sat_bit

    def step(self, dir_, v, l, d, ordy):
        old = dict(out_valid=self.out_valid, est=self.est, dst=self.dst, have=self.have,
                   cont_r=self.cont_r, tail_pend=self.tail_pend, rep_r=self.rep_r,
                   prev=self.prev, ctrl_r=self.ctrl_r, dbyte=self.dbyte,
                   exp_len=self.exp_len, run_len=self.run_len, dir_r=self.dir_r)
        ov = old['out_valid']
        slot_free = (not ov) or bool(ordy)

        # an untouched byte leaves the output register when out_ready takes it
        if ov and ordy:
            self.out_valid = 0
            self._bump('exp_cnt', 0xFF, 4)

        # the direction-change guard is the in-flight-token flag, not busy: a run
        # merely gathered in the encoder register is not a token in flight.
        busy_old = bool(ov or old['est'] != E_RUN or old['tail_pend']
                        or old['dst'] != D_CTRL)

        if dir_ != old['dir_r']:
            self.dir_r = dir_
            if busy_old:
                self.err_sticky |= 1 << 2
                self._bump('err_proto', 0xF, 3)
            self.est = E_RUN
            self.dst = D_CTRL
            self.have = 0
            self.cont_r = 0
            self.tail_pend = 0
            self.rep_r = 0
            self.run_len = 0
            self.out_valid = 0
        elif dir_ == 0:
            self._encode(v, l, d, slot_free, old)
        else:
            self._decode(v, l, d, slot_free, old)

    def _encode(self, v, l, d, slot_free, old):
        if old['tail_pend'] and slot_free:
            self.tok_ctrl = TOK_LIT
            self.tok_data = old['prev']
            self.tail_pend = 0
            self.est = E_TOKC
        elif old['est'] == E_RUN:
            if v and slot_free:
                if not old['have']:
                    self.prev = d
                    self.run_len = RUN_ONE
                    self.have = 1
                    self.cont_r = 0
                    if old['cont_r'] and d == old['prev']:
                        self.err_sticky |= 1 << 0
                        self._bump('run_ovf', 0x1F, 2)
                    if l:
                        self.tail_pend = 1
                        self.have = 0
                elif d == old['prev']:
                    if old['run_len'] == CAP_FIELD:
                        self.tok_ctrl = u(TOK_REP | CAP_FIELD, 8)
                        self.tok_data = old['prev']
                        self.run_len = u(old['run_len'] + RUN_ONE, 8)
                        self.have = 0
                        self.cont_r = 0 if l else 1
                        self.est = E_TOKC
                    else:
                        self.run_len = u(old['run_len'] + RUN_ONE, 8)
                        if l:
                            self.tok_ctrl = u(TOK_REP | (old['run_len'] & 0x7F), 8)
                            self.tok_data = old['prev']
                            self.have = 0
                            self.cont_r = 0
                            self.est = E_TOKC
                else:
                    if old['run_len'] > RUN_ONE:
                        self.tok_ctrl = u(TOK_REP | ((old['run_len'] & 0x7F) - RUN_ONE), 8)
                    else:
                        self.tok_ctrl = TOK_LIT
                    self.tok_data = old['prev']
                    self.prev = d
                    self.run_len = RUN_ONE
                    self.have = 1
                    self.cont_r = 0
                    self.est = E_TOKC
                    if l:
                        self.tail_pend = 1
        elif old['est'] == E_TOKC:
            if slot_free:
                self.out_byte = self.tok_ctrl
                self.out_valid = 1
                self.est = E_TOKD
        elif old['est'] == E_TOKD:
            if slot_free:
                self.out_byte = self.tok_data
                self.out_valid = 1
                self.est = E_RUN
                self._bump('tok_cnt', 0x3F, 0)
                if not (self.tok_ctrl & 0x80):
                    self._bump('lit_cnt', 0x1F, 1)

    def _decode(self, v, l, d, slot_free, old):
        if old['dst'] == D_CTRL:
            if v and slot_free:
                self.ctrl_r = d
                self.rep_r = 1 if (d & 0x80) else 0
                if l:
                    self.err_sticky |= 1 << 2
                    self._bump('err_proto', 0xF, 3)
                    self.dst = D_CTRL
                else:
                    self.dst = D_DATA
        elif old['dst'] == D_DATA:
            if v and slot_free:
                self.dbyte = d
                self.dst = D_EXP
                if old['ctrl_r'] & 0x80:
                    run_req = u((old['ctrl_r'] & 0x7F) + RUN_ONE, 8)
                    self.exp_len = run_req
                    if run_req > CAP_MAX:
                        self.err_sticky |= 1 << 1
                        self._bump('tok_ovf', 0x1F, 2)
                else:
                    self.exp_len = EXP_LIT_N
                    if (old['ctrl_r'] & 0x7F) != 0:
                        self.err_sticky |= 1 << 2
                        self._bump('err_proto', 0xF, 3)
        elif old['dst'] == D_EXP:
            if slot_free:
                self.out_byte = old['dbyte']
                self.out_valid = 1
                self.exp_len = u(old['exp_len'] - RUN_ONE, 8)
                if old['exp_len'] == EXP_LAST:
                    self.dst = D_CTRL
                    self.rep_r = 0


class Runner(object):
    def __init__(self):
        self.dut = Dut()
        self.bi = 0
        self.dir = 0
        self.words = []

    def _ordy(self):
        return 0 if (self.bi % ORDY_SLOT) == 2 else 1

    def beat(self, v, l, d, ce):
        ordy = self._ordy()
        acc = bool(ce and v and self.dut.in_ready(self.dir, ordy))
        if ce:
            self.dut.step(self.dir, 1 if v else 0, 1 if l else 0, d, ordy)
        in_ready, busy, tok_infl = self.dut._flags(self.dir, ordy)
        w = self.words
        w.append((self.dut.out_valid << 3) | (tok_infl << 2) | (busy << 1) | in_ready)
        w.append(self.dut.out_byte)
        w.append(self.dut.run_len)
        w.append(self.dut.lit_cnt)
        w.append(self.dut.tok_cnt)
        w.append(self.dut.run_ovf)
        w.append(self.dut.tok_ovf)
        w.append(self.dut.exp_cnt)
        w.append(self.dut.err_proto)
        w.append(self.dut.err_sticky)
        w.append(self.dut.cnt_sat)
        self.bi += 1
        return acc

    def send_byte(self, l, d):
        while not self.beat(1, l, d, 1):
            pass


def main():
    r = Runner()
    dut = r.dut
    state = SEED

    # ---------------- encode phase ----------------
    for pk in range(NPACK):
        for run in range(NRUNS):
            state = (state * 1664525 + 1013904223) & MASK32
            rlen = 1 + (state & 31)
            if pk == 3 and run == 2:
                # a run deliberately longer than the encoded field
                rlen = 45
            bval = u(0x30 ^ run, 8) if run % 2 == 0 else u(0xC0 ^ run, 8)
            for q in range(rlen):
                r.send_byte(1 if (q == rlen - 1 and run == NRUNS - 1) else 0, bval)
        for _ in range(3):
            r.beat(0, 0, 0, 1)

    # ---------------- flip to decode with a token queued ----------------
    state = (state * 1664525 + 1013904223) & MASK32
    rlen = 1 + (state & 31)
    for q in range(rlen):
        r.send_byte(1 if q == rlen - 1 else 0, 0x5A)
    r.dir = 1
    r.beat(0, 0, 0, 1)

    # ---------------- decode phase ----------------
    for t in range(8):
        r.send_byte(0, tok_ctrl_at(t))
        r.send_byte(0, tok_data_at(t))
        for _ in range(2):
            r.beat(0, 0, 0, 1)

    r.send_byte(0, tok_ctrl_at(8))
    r.beat(0, 0, 0, 0)
    r.send_byte(0, tok_data_at(8))

    r.send_byte(0, tok_ctrl_at(7))
    r.send_byte(0, tok_data_at(7))
    r.dir = 0
    r.beat(0, 0, 0, 1)

    # ---------------- back to encode ----------------
    for pk in range(NPENC2):
        for run in range(NRUNS):
            state = (state * 1664525 + 1013904223) & MASK32
            rlen = 1 + (state & 31)
            if pk == 1 and run == 0:
                rlen = 60
            bval = u(0x12 ^ run, 8) if run % 2 == 0 else u(0xE1 ^ run, 8)
            for q in range(rlen):
                r.send_byte(1 if (q == rlen - 1 and run == NRUNS - 1) else 0, bval)
        for _ in range(2):
            r.beat(0, 0, 0, 1)

    # ---------------- decode tail with a dangling control byte ----------------
    r.dir = 1
    r.beat(0, 0, 0, 1)
    for t in range(9, 12):
        r.send_byte(0, tok_ctrl_at(t))
        r.send_byte(0, tok_data_at(t))
    r.send_byte(1, tok_ctrl_at(4))
    for _ in range(4):
        r.beat(0, 0, 0, 1)

    w = r.words
    w.extend([dut.tok_cnt, dut.lit_cnt, dut.run_ovf, dut.tok_ovf, dut.exp_cnt,
              dut.err_proto, dut.err_sticky, dut.cnt_sat])

    emit('ips_rle_codec', w)


if __name__ == '__main__':
    main()
