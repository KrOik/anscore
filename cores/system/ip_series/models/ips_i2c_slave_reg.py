"""Independent golden model for ips_i2c_slave_reg.

Written from the core's documented protocol contract (see the header comment of
src/ips_i2c_slave_reg.v), never from simulation output (docs/IP_CORE_SOP.md
trap T1).  The bench bit-bangs the two open-drain pins from a fixed half-bit
period H, so this model replays the identical per-cycle pin list and mirrors the
core's three-stage sample chain, filtered data clock, falling-edge byte actions
and start/stop priority cycle by cycle.

Stimulus contract shared with sim/tb_ips_i2c_slave_reg.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x51E2B17C
    pbyte = (state & 0xFF) | 0x0C, d0..d2 = state bytes, d3 = d0+d1, d4 = d2^0x5A
    transaction kind = t % 8, 224 transactions, 8 idle cycles before the first
Observed word order per transaction (DUT outputs only), matching the bench fold:
    {state,ack,lo}, ptr, o_rdata, o_last, {err_nam,err_fmt}, o_txn
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

SLAVE_ADDR = 0x34
REG_BITS = 3
RF_SIZE = 1 << REG_BITS
RF_MASK = RF_SIZE - 1

S_IDLE, S_ADR, S_RX, S_TX, S_IGN, S_END = range(6)

H = 4
NTR = 224
SEED = 0x51E2B17C


class Core(object):
    """Cycle-exact replica of the RTL register set."""

    def __init__(self):
        self.scl_d1 = 0
        self.scl_d2 = 0
        self.scl_d3 = 0
        self.sda_d1 = 0
        self.sda_d2 = 0
        self.hi_r = 0
        self.lo_r = 0
        self.st = S_IDLE
        self.bits = 0
        self.shift = 0
        self.byte_r = 0
        self.tx_sh = 0xFF
        self.matched = 0
        self.rw = 0
        self.first_b = 1
        self.nack = 0
        self.ptr = 0
        self.o_rdata = 0
        self.o_last = 0
        self.o_ack = 0
        self.o_lo = 0
        self.err_nam = 0
        self.err_fmt = 0
        self.txn = 0
        self.rf = [0] * RF_SIZE

    def step(self, scl_pin, tb_low):
        sda_pin = 0 if (tb_low or self.o_lo) else 1

        nb = u((self.shift << 1) | sda_pin, 8)
        scl_hi3 = 1 if (self.scl_d1 and self.scl_d2 and self.scl_d3) else 0
        clk_bit = 1 if (scl_hi3 and not self.hi_r) else 0
        scl_lo2 = 1 if (not self.scl_d1 and not self.scl_d2) else 0
        evt_lo = 1 if (scl_lo2 and not self.lo_r) else 0
        scl_hs = 1 if (self.scl_d1 and self.scl_d2) else 0
        ev_st = 1 if (scl_hs and not self.sda_d1 and self.sda_d2) else 0
        ev_sp = 1 if (scl_hs and self.sda_d1 and not self.sda_d2) else 0

        # snapshot of every register the branches may read
        st = self.st
        bits = self.bits
        matched = self.matched
        first_b = self.first_b
        nack = self.nack
        rw = self.rw
        byte_r = self.byte_r
        tx_sh = self.tx_sh
        ptr = self.ptr
        err_nam = self.err_nam
        err_fmt = self.err_fmt
        txn = self.txn

        if ev_st:
            if st != S_IDLE and bits != 0:
                self.err_fmt = u(err_fmt + 1, 4)
            self.bits = 0
            self.shift = 0
            self.byte_r = 0
            self.matched = 0
            self.nack = 0
            self.o_ack = 0
            self.o_lo = 0
            self.first_b = 1
            self.st = S_ADR
        elif ev_sp:
            if st != S_IDLE and bits != 0:
                self.err_fmt = u(err_fmt + 1, 4)
            if matched:
                self.txn = u(txn + 1, 8)
            self.bits = 0
            self.matched = 0
            self.o_lo = 0
            self.st = S_IDLE
        elif clk_bit:
            if st == S_ADR or st == S_RX:
                self.shift = nb
                self.bits = u(bits + 1, 4)
                if bits == 7:
                    self.byte_r = nb
                    self.o_last = nb
                    if st == S_ADR:
                        self.matched = 1 if ((nb >> 1) == SLAVE_ADDR) else 0
                        self.rw = nb & 1
            elif st == S_TX:
                self.bits = u(bits + 1, 4)
                if bits == 8:
                    self.nack = sda_pin
        elif evt_lo:
            if bits == 8:
                self.o_lo = matched
                self.o_ack = matched
            elif bits == 9:
                self.bits = 0
                self.o_lo = 0
                if st == S_ADR:
                    if not matched:
                        self.st = S_IGN
                        self.err_nam = u(err_nam + 1, 4)
                    elif rw:
                        self.st = S_TX
                        self.tx_sh = self.rf[ptr & RF_MASK]
                        self.o_rdata = self.rf[ptr & RF_MASK]
                    else:
                        self.st = S_RX
                elif st == S_RX:
                    if first_b:
                        self.ptr = byte_r
                        self.first_b = 0
                    else:
                        self.rf[ptr & RF_MASK] = byte_r
                        self.ptr = u(ptr + 1, 8)
                elif st == S_TX:
                    if nack:
                        self.st = S_END
                    else:
                        nptr = u(ptr + 1, 8)
                        self.ptr = nptr
                        self.tx_sh = self.rf[nptr & RF_MASK]
                        self.o_rdata = self.rf[nptr & RF_MASK]
            elif st == S_TX:
                self.o_lo = 1 if tx_sh >> 7 == 0 else 0
                self.tx_sh = u((tx_sh << 1) | 1, 8)

        self.scl_d3 = self.scl_d2
        self.scl_d2 = self.scl_d1
        self.scl_d1 = scl_pin
        self.sda_d2 = self.sda_d1
        self.sda_d1 = sda_pin
        self.hi_r = scl_hi3
        self.lo_r = scl_lo2


def build_pins():
    pins = []

    def ph(v, c, n):
        for _ in range(n):
            pins.append((0 if v else 1, c))

    def bit_sym(v):
        ph(v, 0, H)
        ph(v, 1, H)

    def byte_sym(val):
        for i in range(7, -1, -1):
            bit_sym((val >> i) & 1)

    def start_sym():
        ph(1, 1, 3)
        ph(0, 1, 1)

    def restart_sym():
        ph(1, 0, 2)
        ph(1, 1, 2)
        ph(0, 1, 1)

    def stop_sym():
        ph(0, 0, H)
        ph(0, 1, 2)
        ph(1, 1, 1)

    def idle_sym():
        ph(1, 1, 6)

    def recv_ack():
        # the bench samples sda two cycles into the high phase and then keeps the
        # line released: 4 low + 2 high + 1 un-driven high + 1 high = one bit
        bit_sym(1)

    def addr_phase(ab):
        byte_sym(ab)
        recv_ack()

    def mack(a):
        bit_sym(a)

    def read_byte():
        for i in range(7, -1, -1):
            bit_sym(1)

    folds = []
    ph(1, 1, 8)
    state = SEED
    for t in range(NTR):
        state = lcg32(state)
        pbyte = (state & 0xFF) | 0x0C
        d0 = (state >> 8) & 0xFF
        d1 = (state >> 16) & 0xFF
        d2 = (state >> 24) & 0xFF
        d3 = (d0 + d1) & 0xFF
        d4 = d2 ^ 0x5A
        kind = t % 8

        if kind == 0:
            start_sym()
            addr_phase((SLAVE_ADDR << 1) | 0)
            byte_sym(pbyte); recv_ack()
            byte_sym(d0); recv_ack()
            byte_sym(d1); recv_ack()
            stop_sym(); idle_sym()
        elif kind == 1:
            start_sym()
            addr_phase((SLAVE_ADDR << 1) | 0)
            byte_sym(pbyte); recv_ack()
            restart_sym()
            addr_phase((SLAVE_ADDR << 1) | 1)
            read_byte(); mack(0)
            read_byte(); mack(0)
            read_byte(); mack(1)
            stop_sym(); idle_sym()
        elif kind == 2:
            start_sym()
            addr_phase((SLAVE_ADDR << 1) | 0)
            byte_sym(0x0C); recv_ack()
            byte_sym(d0); recv_ack()
            stop_sym(); idle_sym()
        elif kind == 3:
            start_sym()
            addr_phase((SLAVE_ADDR << 1) | 0)
            byte_sym(0x05); recv_ack()
            byte_sym(d1); recv_ack()
            restart_sym()
            addr_phase((SLAVE_ADDR << 1) | 0)
            byte_sym(0x04); recv_ack()
            restart_sym()
            addr_phase((SLAVE_ADDR << 1) | 1)
            read_byte(); mack(1)
            stop_sym(); idle_sym()
        elif kind == 4:
            start_sym()
            addr_phase(((SLAVE_ADDR << 1) | 0) + 8)
            read_byte(); mack(1)
            stop_sym(); idle_sym()
        elif kind == 5:
            start_sym()
            bit_sym((pbyte >> 7) & 1)
            bit_sym((pbyte >> 6) & 1)
            bit_sym((pbyte >> 5) & 1)
            stop_sym(); idle_sym()
        elif kind == 6:
            start_sym()
            addr_phase((SLAVE_ADDR << 1) | 0)
            byte_sym(pbyte); recv_ack()
            byte_sym(d0); recv_ack()
            byte_sym(d1); recv_ack()
            byte_sym(d2); recv_ack()
            byte_sym(d3); recv_ack()
            byte_sym(d4); recv_ack()
            stop_sym(); idle_sym()
        else:
            start_sym()
            addr_phase((SLAVE_ADDR << 1) | 1)
            read_byte(); mack(0)
            restart_sym()
            addr_phase((SLAVE_ADDR << 1) | 0)
            byte_sym(0x04); recv_ack()
            restart_sym()
            addr_phase((SLAVE_ADDR << 1) | 1)
            read_byte(); mack(1)
            stop_sym(); idle_sym()
        folds.append(len(pins) - 1)
    return pins, folds


def main():
    pins, folds = build_pins()
    core = Core()
    words = []
    idx = 0
    n = len(pins)

    for k in range(n):
        tb_low, scl_pin = pins[k]
        core.step(scl_pin, tb_low)
        if idx < len(folds) and k == folds[idx]:
            words.append(((core.st & 7) << 2) | ((core.o_ack & 1) << 1) | (core.o_lo & 1))
            words.append(core.ptr)
            words.append(core.o_rdata)
            words.append(core.o_last)
            words.append(((core.err_nam & 0xF) << 4) | (core.err_fmt & 0xF))
            words.append(core.txn)
            idx += 1

    if idx != NTR:
        raise SystemExit('fold point count mismatch: %d' % idx)
    if os.environ.get('IPS_MODEL_DUMP'):
        for w in words:
            print("W %08X" % (w & 0xFFFFFFFF))
    emit('ips_i2c_slave_reg', words)


if __name__ == '__main__':
    main()
