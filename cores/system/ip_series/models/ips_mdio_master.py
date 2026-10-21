#!/usr/bin/env python3
"""Independent golden model of ips_mdio_master (IEEE 802.3 Clause 22 MDIO).

Written from the contract in src/ips_mdio_master.v's header comment, not from
simulation output (docs/IP_CORE_SOP.md trap T1):

  * one explicit tick per MDC half period; drive is presented on the rising
    tick, the line is sampled on the falling tick,
  * frame = PRE_BITS ones, ST = 01, OP = OP_RD/OP_WR, PA = phy_addr, TA,
    DATA_BITS data, then one released hand-back bit-time,
  * the first turnaround bit-time is always released; a write master sinks the
    following one itself, a read master waits for the PHY to pull it low and
    counts every still-high wait bit-time in o_waits, giving up after
    TMO_LIMIT turnaround bit-times (o_err_to, sticky, no data phase),
  * start is ignored while a frame is in flight.

The bench (sim/tb_ips_mdio_master.v) drives mdio through a pull-up with the
core and a reference PHY as open-drain sinks.  The PHY's schedule is expressed
in bit-times counted from the start pulse, exactly as the bench counts mdc
falls, so this file can replay the same pins and reach the same digest.
"""
import os

from ips_model_common import MASK32, emit, lcg32, u

PRE_BITS = 32
TMO_LIMIT = 3
DATA_BITS = 16

S_IDLE, S_PRE, S_ST, S_OP, S_PA, S_TA, S_DAT, S_END = range(8)
ST_FLD = 0b01
OP_RD = 0b01
OP_WR = 0b10
DMASK = (1 << DATA_BITS) - 1

TK = 3
NTB = 64
NTR = 224
SEED = 0x6D2F7A13


class Core(object):
    """Cycle-exact replica of the ips_mdio_master register transfer."""

    def __init__(self):
        self.mdc = 0
        self.state = S_IDLE
        self.bc = 0
        self.pos = 0
        self.waits = 0
        self.rdata = 0
        self.sh = 0
        self.ash = 0x1FF
        self.cmd = 0x1FF
        self.txn = 0
        self.err = 0
        self.own = 0
        self.busy = 0
        self.lo = 0
        self.rnw_l = 0
        self.ta_cnt = 0

    def step(self, tick, start, rnw, pa, wd, mdio):
        if start and not self.busy:
            cmd = u((ST_FLD << 7) | ((OP_RD if rnw else OP_WR) << 5) | pa, 9)
            self.state = S_PRE
            self.bc = 0
            self.pos = 0
            self.waits = 0
            self.ta_cnt = 0
            self.ash = cmd
            self.cmd = cmd
            self.sh = u(wd, DATA_BITS)
            self.rdata = 0
            self.own = 0
            self.lo = 0
            self.busy = 1
            self.rnw_l = rnw
            return
        if not (self.busy and tick):
            return
        if not self.mdc:
            # rising tick: present this bit-time's drive
            self.mdc = 1
            is_wr = 1 - self.rnw_l
            if self.state == S_PRE:
                self.own = 1
                self.lo = 0
            elif self.state in (S_ST, S_OP, S_PA):
                self.own = 1
                self.lo = 1 - ((self.ash >> 8) & 1)
                self.ash = u((self.ash << 1) | 1, 9)
            elif self.state == S_TA:
                self.own = is_wr
                self.lo = 1 if (is_wr and self.ta_cnt != 0) else 0
            elif self.state == S_DAT:
                self.own = 1 - is_wr
                msb = (self.sh >> (DATA_BITS - 1)) & 1
                self.lo = 1 if (is_wr and msb == 0) else 0
                self.sh = u((self.sh << 1) | 1, DATA_BITS)
            else:
                self.own = 0
                self.lo = 0
            return
        # falling tick: capture the line and advance the frame
        self.mdc = 0
        self.pos = u(self.pos + 1, 7)
        if self.state != S_END:
            self.rdata = u((self.rdata << 1) | mdio, DATA_BITS)
        st = self.state
        if st == S_PRE:
            if self.bc == (PRE_BITS - 1):
                self.bc = 0
                self.state = S_ST
            else:
                self.bc = u(self.bc + 1, 6)
        elif st in (S_ST, S_OP):
            nxt = S_OP if st == S_ST else S_PA
            if self.bc == 1:
                self.bc = 0
                self.state = nxt
            else:
                self.bc = u(self.bc + 1, 6)
        elif st == S_PA:
            if self.bc == 4:
                self.bc = 0
                self.state = S_TA
            else:
                self.bc = u(self.bc + 1, 6)
        elif st == S_TA:
            old = self.ta_cnt
            self.ta_cnt = u(old + 1, 6)
            if old == 0:
                self.bc = 0
            elif mdio == 0:
                self.bc = 0
                self.state = S_DAT
            elif old >= TMO_LIMIT:
                self.err = u(self.err + 1, 4)
                self.bc = 0
                self.state = S_END
            else:
                self.waits = u(self.waits + 1, 3)
                self.bc = u(self.bc + 1, 6)
        elif st == S_DAT:
            if self.bc == (DATA_BITS - 1):
                self.bc = 0
                self.state = S_END
            else:
                self.bc = u(self.bc + 1, 6)
        else:
            self.state = S_IDLE
            self.busy = 0
            self.own = 0
            self.lo = 0
            self.txn = u(self.txn + 1, 8)


class Phy(object):
    """Reference open-drain PHY: sinks the line on its own bit-time schedule."""

    def __init__(self):
        self.bt = 0
        self.dl = 0
        self.data = 0
        self.ack = 0
        self.ta = 42
        self.first = 43
        self.pw = 0

    def program(self, dly, data, ack, pw):
        self.bt = 0
        self.dl = 0
        self.data = data
        self.ack = ack
        self.ta = u(42 + dly, 8)
        self.first = u(43 + dly, 8)
        self.pw = pw

    def drive(self, b):
        if self.data and (b >= self.first) and (b < self.first + 16):
            idx = b - self.first
            return 1 if (((self.pw >> (15 - idx)) & 1) == 0) else 0
        if self.ack and b == self.ta:
            return 1
        return 0


class Bench(object):
    """Bench side of the bench: tick cadence, PHY schedule, wire resolution."""

    def __init__(self, core, phy):
        self.core = core
        self.phy = phy
        self.mdc_d = 0

    def cycle(self, pin):
        tick, start, rnw, pa, wd = pin
        core = self.core
        phy = self.phy
        # the bench's negedge watcher runs before the DUT's posedge
        if self.mdc_d == 1 and core.mdc == 0:
            phy.bt = u(phy.bt + 1, 6)
            phy.dl = phy.drive(phy.bt)
        self.mdc_d = core.mdc
        mdio = 0 if (core.lo or phy.dl) else 1
        core.step(tick, start, rnw, pa, wd, mdio)

    def run(self, pins):
        for pin in pins:
            self.cycle(pin)


def half(periods, st, rnw, a, d):
    """tk/start held for a whole half period: one tick cycle then TK-1 gaps."""
    return [(1 if k == 0 else 0, st, rnw, a, d) for k in range(TK)] * periods


def txn_pins(r, a, d, inj, a2):
    """One frame: launch, 2 ticks with start, then 2*NTB-4 half periods."""
    pins = [(0, 1, r, a, d)]                 # set_req(start = 1)
    pins += half(2, 1, r, a, d)              # the two launch half periods
    pins += [(0, 0, r, a, d)]                # set_req(start = 0)
    for j in range(2 * NTB - 4):
        if inj and j in (20, 21):
            pins += half(1, 1, r, a2, d)     # spurious start, must be ignored
        else:
            pins += half(1, 0, r, a, d)
    pins += [(0, 0, r, a, d)] * 16           # idle tail
    return pins


# kind -> (rnw, wdata source, phy_addr, turnaround delay, phy data, phy ack,
#          inject a second start)
KINDS = [
    (1, 'zero', None, 0, 1, 1, 0),
    (1, 'zero', None, 1, 1, 1, 0),
    (1, 'zero', None, 3, 0, 1, 0),
    (0, 'hi', 13, 0, 0, 0, 0),
    (1, 'zero', None, 2, 1, 1, 0),
    (1, 'zero', None, 0, 1, 1, 1),
    (1, 'zero', None, 99, 0, 0, 0),
    (0, 'ones', None, 1, 1, 0, 0),
]


def fold8(core):
    return [
        ((core.state & 7) << 2) | ((core.own & 1) << 1) | (core.lo & 1),
        core.rdata & DMASK,
        core.sh & DMASK,
        ((core.bc & 0x3F) << 3) | (core.waits & 7),
        core.pos & 0x7F,
        core.txn & 0xFF,
        core.err & 0xF,
        ((core.cmd & 0x1FF) << 1) | (core.busy & 1),
    ]


def main():
    core = Core()
    phy = Phy()
    bench = Bench(core, phy)
    words = []

    bench.run([(0, 0, 0, 0, 0)] * 8)         # the bench's warm-up idle cycles
    state = SEED
    for t in range(NTR):
        state = lcg32(state)
        d0 = (state >> 8) & 0xFF
        d1 = (state >> 16) & 0xFF
        pab = (state >> 3) & 0x1F
        pw = (d0 << 8) | d1
        kind = t % 8
        rnw, src, paddr, dly, dat, ack, inj = KINDS[kind]
        wdata = {'zero': 0, 'hi': d1, 'ones': DMASK}[src]
        a = pab if paddr is None else paddr
        phy.program(dly, dat, ack, pw)
        bench.run(txn_pins(rnw, a, wdata, inj, 21))
        words += fold8(core)

    if os.environ.get('IPS_MODEL_DUMP'):
        for w in words:
            print("W %08X" % (w & MASK32))
    emit('ips_mdio_master', words)


if __name__ == '__main__':
    main()
