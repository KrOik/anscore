"""Independent golden model for ips_spi_slave_reg.

Written from the core's documented protocol contract (see the header comment of
src/ips_spi_slave_reg.v), never from simulation output (docs/IP_CORE_SOP.md
trap T1).  The bench bit-bangs mosi/sclk/ss_n and observes the tri-state miso net
from a fixed half-period SP, so this model replays the identical per-cycle pin
vector and mirrors the core's sample chains, filtered edges, CS-edge realignment
and per-state frame actions cycle by cycle.

Stimulus contract shared with sim/tb_ips_spi_slave_reg.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x3A9C77D5
    d0..d2 = state bytes, d3 = (state & 0xFF) ^ 0x5A
    transaction kind = t % 8, 224 transactions, 8 idle cycles before the first
Observed word order per transaction (DUT outputs only), matching the bench fold:
    {state,rw,drive,txb}, ptr, o_rx, o_tx, mrx (received miso pin),
    {err_no_cs,err_short,rem}, o_xfer
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

SPI_MODE = 0
FRAME = 8
REG_BITS = 3
RF_SIZE = 1 << REG_BITS
RF_MASK = RF_SIZE - 1

CPOL = (SPI_MODE >> 1) & 1
CPHA = SPI_MODE & 1
SAMP_HI = 1 if not (CPOL ^ CPHA) else 0

S_IDLE, S_CMD, S_WR, S_RD = range(4)

SP = 4
NTR = 224
SEED = 0x3A9C77D5
FMASK = (1 << FRAME) - 1


class Core(object):
    """Cycle-exact replica of the RTL register set."""

    def __init__(self):
        self.ss_d1 = 1
        self.ss_d2 = 1
        self.sck_d1 = 0
        self.sck_d2 = 0
        self.sck_d3 = 0
        self.mosi_d1 = 1
        self.mosi_d2 = 1
        self.hi_r = 0
        self.lo_r = 1
        self.st = S_IDLE
        self.bit_cnt = 0
        self.rx_sh = 0
        self.o_rx = 0
        self.o_tx = 0
        self.ptr = 0
        self.err_no_cs = 0
        self.err_short = 0
        self.xfer = 0
        self.rem = 0
        self.drive = 0
        self.txb = 1
        self.rw = 0
        self.rf = [0] * RF_SIZE

    def miso(self):
        # pullup on the bench net: released means a logic 1
        return self.txb if self.drive else 1

    def step(self, mosi_pin, sclk_pin, ss_pin):
        rxf = u((self.rx_sh << 1) | mosi_pin, FRAME)
        cptr = rxf & 0x7F
        cidx = cptr & RF_MASK
        idx = self.ptr & RF_MASK
        nptr = u(self.ptr + 1, 8)
        nidx = nptr & RF_MASK
        rsel = cidx if self.st == S_CMD else nidx
        rdata = self.rf[rsel]
        hi3 = 1 if (self.sck_d1 and self.sck_d2 and self.sck_d3) else 0
        lo3 = 1 if (not self.sck_d1 and not self.sck_d2 and not self.sck_d3) else 0
        evt_hi = 1 if (hi3 and not self.hi_r) else 0
        evt_lo = 1 if (lo3 and not self.lo_r) else 0
        evt_samp = evt_hi if SAMP_HI else evt_lo
        evt_shift = evt_lo if SAMP_HI else evt_hi
        cs_act = 1 if not self.ss_d1 else 0
        ev_cs_lo = 1 if (not self.ss_d1 and self.ss_d2) else 0
        ev_cs_hi = 1 if (self.ss_d1 and not self.ss_d2) else 0
        last_bit = 1 if self.bit_cnt == (FRAME - 1) else 0

        if ev_cs_lo:
            self.bit_cnt = 0
            self.rx_sh = 0
            self.st = S_CMD
        elif ev_cs_hi:
            if self.bit_cnt != 0:
                self.err_short = u(self.err_short + 1, 4)
                self.rem = self.bit_cnt & 0x0F
            self.st = S_IDLE
            self.drive = 0
        elif evt_samp:
            if not cs_act:
                self.err_no_cs = u(self.err_no_cs + 1, 4)
            else:
                self.rx_sh = rxf
                self.bit_cnt = u(self.bit_cnt + 1, 8)
                if last_bit:
                    self.o_rx = rxf
                    self.xfer = u(self.xfer + 1, 8)
                    self.bit_cnt = 0
                    if self.st == S_CMD:
                        self.ptr = cptr
                        self.rw = (rxf >> (FRAME - 1)) & 1
                        self.txb = (rdata >> (FRAME - 1)) & 1
                        self.o_tx = rdata
                        self.drive = (rxf >> (FRAME - 1)) & 1
                        self.st = S_RD if self.rw else S_WR
                    elif self.st == S_WR:
                        self.rf[idx] = rxf
                        self.ptr = nptr
                        self.drive = 0
                    elif self.st == S_RD:
                        self.txb = (rdata >> (FRAME - 1)) & 1
                        self.o_tx = rdata
                        self.ptr = nptr
                    else:
                        self.drive = 0
        elif evt_shift:
            if cs_act and self.drive:
                self.txb = (self.o_tx >> (FRAME - 1)) & 1
                self.o_tx = u((self.o_tx << 1) | 1, FRAME)

        self.ss_d2 = self.ss_d1
        self.ss_d1 = ss_pin
        self.sck_d3 = self.sck_d2
        self.sck_d2 = self.sck_d1
        self.sck_d1 = sclk_pin
        self.mosi_d2 = self.mosi_d1
        self.mosi_d1 = mosi_pin
        self.hi_r = hi3
        self.lo_r = lo3


def build_pins():
    pins = []

    def ph(m, c, s, n):
        for _ in range(n):
            pins.append((m, c, s, 0))

    def phs(m, samp):
        pins.append((m, 1, 0, 1 if samp else 0))

    def spbit(m, samp):
        ph(m, 0, 0, SP)
        ph(m, 1, 0, SP - 2)
        phs(m, samp)
        ph(m, 1, 0, 1)

    def frame_w(val):
        for i in range(7, -1, -1):
            spbit((val >> i) & 1, 0)

    def frame_r():
        for _ in range(8):
            spbit(1, 1)

    def cs_low():
        ph(1, 0, 0, 4)

    def cs_high():
        ph(1, 0, 0, 3)
        ph(1, 0, 1, 3)

    def idle_sym():
        ph(1, 0, 1, 6)

    def noclock(n):
        for _ in range(n):
            ph(1, 0, 1, SP)
            ph(1, 1, 1, SP)
        ph(1, 0, 1, 2)

    folds = []
    ph(1, 0, 1, 8)
    state = SEED
    for t in range(NTR):
        state = lcg32(state)
        d0 = (state >> 8) & 0xFF
        d1 = (state >> 16) & 0xFF
        d2 = (state >> 24) & 0xFF
        d3 = (state & 0xFF) ^ 0x5A
        kind = t % 8

        if kind == 0:
            cs_low()
            frame_w(0x80 | (d3 & 0x07))
            frame_r(); frame_r(); frame_r()
            cs_high(); idle_sym()
        elif kind == 1:
            cs_low()
            frame_w(d3 & 0x07)
            frame_w(d0); frame_w(d1); frame_w(d2)
            cs_high(); idle_sym()
            cs_low()
            frame_w(0x80 | (d3 & 0x07))
            frame_r(); frame_r(); frame_r()
            cs_high(); idle_sym()
        elif kind == 2:
            cs_low()
            frame_w(d0)
            for i in range(7, 2, -1):
                spbit((d1 >> i) & 1, 0)
            cs_high(); idle_sym()
        elif kind == 3:
            idle_sym()
            noclock(3)
            idle_sym()
        elif kind == 4:
            cs_low(); frame_w(0x02); frame_w(d0); cs_high(); idle_sym()
            cs_low(); frame_w(0x82); frame_r(); cs_high(); idle_sym()
        elif kind == 5:
            cs_low(); frame_w(0x05); frame_w(d1); cs_high(); idle_sym()
            cs_low(); frame_w(0x84); frame_r(); cs_high(); idle_sym()
        elif kind == 6:
            cs_low(); frame_w(0x0C); frame_w(d2); cs_high(); idle_sym()
            cs_low(); frame_w(0x84); frame_r(); cs_high(); idle_sym()
        else:
            cs_low()
            frame_w(0x84)
            frame_r(); frame_r(); frame_r(); frame_r()
            cs_high(); idle_sym()
            cs_low(); frame_w(0x04); frame_w(d3); frame_w(d0)
            cs_high(); idle_sym()
        folds.append(len(pins) - 1)
    return pins, folds


def main():
    pins, folds = build_pins()
    core = Core()
    words = []
    mrx = 0
    idx = 0
    n = len(pins)

    for k in range(n):
        mosi_pin, sclk_pin, ss_pin, samp = pins[k]
        if samp:
            mrx = ((mrx << 1) | core.miso()) & 0xFFFF
        core.step(mosi_pin, sclk_pin, ss_pin)
        if idx < len(folds) and k == folds[idx]:
            words.append(((core.st & 7) << 3) | ((core.rw & 1) << 2)
                         | ((core.drive & 1) << 1) | (core.txb & 1))
            words.append(core.ptr)
            words.append(core.o_rx & FMASK)
            words.append(core.o_tx & FMASK)
            words.append(mrx)
            words.append(((core.err_no_cs & 0xF) << 8)
                         | ((core.err_short & 0xF) << 4) | (core.rem & 0xF))
            words.append(core.xfer)
            idx += 1
            mrx = 0

    if idx != NTR:
        raise SystemExit('fold point count mismatch: %d' % idx)
    if os.environ.get('IPS_MODEL_DUMP'):
        for w in words:
            print("W %08X" % (w & 0xFFFFFFFF))
    emit('ips_spi_slave_reg', words)


if __name__ == '__main__':
    main()
