"""Independent golden model for ips_irq_priority_ctrl.

This replay is written from the WRITTEN CONTRACT at the top of
src/ips_irq_priority_ctrl.v (priority convention, candidate word, 16-line
early-exit encoder, ceiling/blocking/nesting rules, EOI legality, register map,
error precedence, synchroniser) and from the stimulus contract of
sim/tb_ips_irq_priority_ctrl.v.  It never reads simulation output and digests
are never back-filled (docs/IP_CORE_SOP.md trap T1).

CONTRACT RESTATEMENT USED BY THIS REPLAY
  * Line 0 is the HIGHEST priority, line 15 the LOWEST; a line's priority IS
    its index, so the controller vectors the LOWEST SET INDEX of the candidate
    word cand = (pend | swtrig) & ~mask_r and a request is servable only while
    its index is below the ceiling cur_pri in force.
  * ge = (sel >= cur_pri), irq_req = has_cand && !ge, blocked = has_cand && ge.
    Those three, plus sel and its one-hot, are the registered images of the
    candidate evaluation of the PREVIOUS beat, so the accept path always uses
    the vector published in the beat in progress.
  * cur_pri starts at IDLE_PRI, so with IDLE_PRI = 16 every line - line 15
    included - is servable at idle.
  * accept (svc_ack, no eoi, irq_req, nest_depth < NEST_MAX):
        lane nest_depth of the flat stack takes cur_pri;
        cur_pri = irq_pri;  nest_depth += 1;  nested = (nest_depth != 0);
        svc_cnt += 1;  pend and swtrig lose the accepted one-hot line.
    accept at nest_depth == NEST_MAX: refused, code ERR_BASE + 3, NO state move.
    accept without irq_req: no-op.
  * eoi is legal only while nest_depth != 0 and eoi_idx == cur_pri[3:0]; then
        cur_pri = lane (nest_depth - 1);  nest_depth -= 1;  nested = 0;
        eoi_cnt += 1.
    nest_depth == 0 -> code ERR_BASE + 1;  non-active index -> code ERR_BASE + 2;
    both leave stack, ceiling, pend and swtrig untouched.  A popped lane keeps
    its old value until the next push at that level.
  * pend arms on the pin rising edge of the two-flop synchroniser (rise =
    sync_q & ~sync_d, newly = rise & ~pend) and is sticky until accepted or
    write-1-cleared; swtrig is write-1-to-set.  A masked line still latches
    pend, and inact = pend & mask_r is that set.  arm-before-clear ordering:
    pend = (pend | newly) & ~clr, swtrig = (swtrig | set) & ~clr.
  * Register map 0 MASK / 1 SWTRIG / 2 PEND / 3 INACT / 4 VEC / 5 STAT are legal,
    6..15 illegal.  Reads return the images HELD AT THE START of the beat; VEC
    reads {8'h00, VECTOR_BASE, irq_pri}; STAT reads {1'b0, |inact, cur_pri,
    nest_depth, err_code, irq_req, blocked}; illegal reads INVALID_RD.  An
    illegal write steps err_count with code ERR_BASE + 0 and touches nothing.
    bus_ack = bus_we && !illegal.  Every error code is compared with the
    documented precedence illegal address > EOI at idle > EOI non-active >
    overflow, so in one beat the last-listed arm that fires wins.
  * err_count / svc_cnt / eoi_cnt count BEATS and saturate at CNT_SAT.

Folding rule -- identical to the rule stated in the testbench header: nine
32-bit words per ENABLED beat, MSB byte first, then the five-word tail.
    W0 = {16'd0, bus_rdata}
    W1 = {       mask_r,        pend}
    W2 = {       swtrig,        inact}
    W3 = {19'd0, bus_ack, nest_depth, cur_pri, irq_pri}
    W4 = {24'd0, irq_vec}
    W5 = {24'd0, err_code, irq_req, blocked, nested, ge}
    W6 = {11'd0, err_count, svc_cnt, eoi_cnt}
    W7 = stk_flat[63:32]
    W8 = stk_flat[31:0]
    tail: {25'd0, err_count}, {25'd0, svc_cnt}, {25'd0, eoi_cnt},
           {20'd0, nest_depth, cur_pri, err_code}, BEATS
Only DUT outputs are folded.  The words are taken from the state AFTER each
enabled posedge, which is the moment the testbench samples them.

Stimulus contract shared with the testbench (beat i is the (i+1)-th enabled
posedge after reset; clk_en is a free-running 5-state divisor so one enabled
posedge happens per loop iteration; one LCG step per beat, seed 0x0BADC0DE):
    A  i <   8 : all inputs 0.
    B  i <  72 : slot = (i-8)/4 = 0..15, s = (i-8)%4.  s<2 drives
                 irq_in = 1<<slot, s==2 idle, s==3 writes PEND = 1<<slot.
                 No svc_ack and no eoi.
    C  i < 112 : i==72 writes MASK=0xFFFF; 73<=i<89 drives 1<<((i-73)%16);
                 i==90 writes MASK=0x00FF; 91<=i<107 drives 1<<((i-91)%8);
                 i==108 writes MASK=0x0000; i==109 writes PEND=0xFFFF;
                 i==110,111 idle.
    D  i < 240 : hold word OR-accumulates 0x8000,0x4000,...,0x0200 at
                 i=112,120,...,160 and 0x0100 at 168, cleared at 178;
                 irq_in = hold for 112<=i<178, 0 afterwards.  svc_ack at
                 174, 216, 228 and at 118,126,...,166.  eoi at
                 180,184,...,204 naming 9,10,...,15, wrongly at 198 (index 0)
                 and 232 (index 4), at 208 (empty stack), at 220 (index 6) and
                 at 236 (index 5).  Writes: 176 PEND=0xFF00, 206 ILLEGAL
                 address 0xC, 212 SWTRIG=0x0040, 224 SWTRIG=0x0020,
                 232 SWTRIG=0x0080.
    E  i >= 240: LCG fuzz -- irq_in = r[15:0], bus_addr = r[19:16],
                 bus_we = r[20], svc_ack = r[21], eoi = r[22],
                 eoi_idx = r[26:23], bus_wdata = r[31:16].
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

# --- shipped parameter defaults (no override in the testbench) ----------------
BEATS = 600
VECTOR_BASE = 0x8          # parameter [3:0]  VECTOR_BASE
NEST_MAX = 7               # parameter [2:0]  NEST_MAX
IDLE_PRI = 16              # parameter [4:0]  IDLE_PRI
RESET_MASK = 0x0300        # parameter [15:0] RESET_MASK
INVALID_RD = 0xDEAD        # localparam
ERR_BASE = 0x8             # localparam
CNT_SAT = 100              # localparam
A_MASK, A_SWTRIG, A_PEND, A_INACT, A_VEC, A_STAT = range(6)
M16 = 0xFFFF
M64 = (1 << 64) - 1
SEED = 0x0BADC0DE


def low_index(cand):
    """The 16-line early-exit chain: the first arm set from index 0 upward wins.

    Returns (sel, sel_oh, has_cand).  With no candidate the chain leaves its
    defaults sel = 0 and sel_oh = one-hot 0 in place.
    """
    if cand == 0:
        return 0, 1, False
    sel = (cand & -cand).bit_length() - 1
    return sel, 1 << sel, True


def bump(value):
    """A beat counter that saturates at CNT_SAT."""
    return value if value >= CNT_SAT else value + 1


def stimulus(i, rstate):
    """The directed/fuzz input vector of beat i, exactly as the contract lists
    phases A..E.  Returns (pin, addr, we, wdata, svc, eoi, eidx)."""
    pin = addr = we = wdata = svc = eoi = eidx = 0

    if i < 8:
        pass                                            # phase A: quiet
    elif i < 72:                                        # phase B
        slot = (i - 8) // 4
        s = (i - 8) % 4
        if s == 3:
            addr, we, wdata = A_PEND, 1, 1 << slot
        elif s < 2:
            pin = 1 << slot
    elif i < 112:                                       # phase C
        if i == 72:
            addr, we, wdata = A_MASK, 1, 0xFFFF
        elif 73 <= i < 89:
            pin = 1 << ((i - 73) % 16)
        elif i == 90:
            addr, we, wdata = A_MASK, 1, 0x00FF
        elif 91 <= i < 107:
            pin = 1 << ((i - 91) % 8)
        elif i == 108:
            addr, we, wdata = A_MASK, 1, 0x0000
        elif i == 109:
            addr, we, wdata = A_PEND, 1, M16
    elif i < 240:                                       # phase D (table below)
        pin, addr, we, wdata, svc, eoi, eidx = phase_d(i)
    else:                                               # phase E: LCG fuzz
        pin = rstate & M16
        addr = (rstate >> 16) & 0xF
        we = (rstate >> 20) & 1
        wdata = (rstate >> 16) & M16
        svc = (rstate >> 21) & 1
        eoi = (rstate >> 22) & 1
        eidx = (rstate >> 23) & 0xF

    return pin, addr, we, wdata, svc, eoi, eidx


# Phase D is a plain function of the beat index, spelled out rather than derived
# so that the replay cannot drift from the contract.
HOLD_OR = {112: 0x8000, 120: 0x4000, 128: 0x2000, 136: 0x1000,
           144: 0x0800, 152: 0x0400, 160: 0x0200, 168: 0x0100}
HOLD_CLR = 178
SVC_ONE = (174, 216, 228)
EOI_LIFO_FIRST, EOI_LIFO_LAST, EOI_LIFO_STEP = 180, 204, 4
EOI_LIFO_BASE = 9


def phase_d(i):
    """Inputs of one phase-D beat: (pin, addr, we, wdata, svc, eoi, eidx)."""
    hold = 0
    for beat in sorted(HOLD_OR):
        if i >= beat:
            hold |= HOLD_OR[beat]
    if i >= HOLD_CLR:
        hold = 0

    pin = hold if 112 <= i < 178 else 0

    svc = 1 if (i in SVC_ONE or
                 (118 <= i < 168 and (i - 118) % 8 == 0)) else 0

    eoi, eidx = 0, 0
    if EOI_LIFO_FIRST <= i <= EOI_LIFO_LAST and \
            (i - EOI_LIFO_FIRST) % EOI_LIFO_STEP == 0:
        eoi, eidx = 1, EOI_LIFO_BASE + (i - EOI_LIFO_FIRST) // EOI_LIFO_STEP
    elif i in (198, 208):
        eoi, eidx = 1, 0
    elif i == 220:
        eoi, eidx = 1, 6
    elif i == 232:
        eoi, eidx = 1, 4
    elif i == 236:
        eoi, eidx = 1, 5

    addr, we, wdata = 0, 0, 0
    if i == 176:
        addr, we, wdata = A_PEND, 1, 0xFF00
    elif i == 206:
        addr, we, wdata = 0xC, 1, 0x5A5A
    elif i == 212:
        addr, we, wdata = A_SWTRIG, 1, 0x0040
    elif i == 224:
        addr, we, wdata = A_SWTRIG, 1, 0x0020
    elif i == 232:
        addr, we, wdata = A_SWTRIG, 1, 0x0080

    return pin, addr, we, wdata, svc, eoi, eidx


class Ctrl(object):
    """Behavioural image of the register file plus the combinational core."""

    def __init__(self):
        self.sync_meta = 0
        self.sync_q = 0
        self.sync_d = 0
        self.pend = 0
        self.mask_r = RESET_MASK
        self.swtrig = 0
        self.stk = 0
        self.irq_oh = 1
        self.nest_depth = 0
        self.cur_pri = IDLE_PRI
        self.irq_pri = 0
        self.irq_req = 0
        self.blocked = 0
        self.ge = 0
        self.nested = 0
        self.err_code = 0
        self.err_count = 0
        self.svc_cnt = 0
        self.eoi_cnt = 0
        self.bus_rdata = 0
        self.bus_ack = 0

    # flat-stack lane access: entry j lives at bits 8j +: 5
    def lane_read(self, j):
        return (self.stk >> (8 * j)) & 0x1F

    def lane_write(self, j, value):
        shift = 8 * j
        self.stk = u((self.stk & ~(0x1F << shift)) | (u(value, 5) << shift), 64)

    def step(self, pin, addr, we, wdata, svc, eoi, eidx):
        """Advance one enabled beat; every right-hand side below is the value
        the beat BEGAN with, as non-blocking assignment requires."""
        # ---- combinational core ---------------------------------------------
        cand = u((self.pend | self.swtrig) & ~self.mask_r, 16)
        rise = u(self.sync_q & ~self.sync_d, 16)
        newly = u(rise & ~self.pend, 16)
        inact = u(self.pend & self.mask_r, 16)
        inact_hit = 1 if inact else 0
        irq_vec_pre = u((VECTOR_BASE << 4) | self.irq_pri, 8)

        sel, sel_oh, has_cand = low_index(cand)
        ge_n = 1 if (u(sel, 5) >= self.cur_pri) else 0
        req_n = 1 if (has_cand and not ge_n) else 0
        blk_n = 1 if (has_cand and ge_n) else 0

        depth0 = (self.nest_depth == 0)
        active = 0 if depth0 else 1
        eoi_ok = 1 if (eoi and active and eidx == u(self.cur_pri, 4)) else 0
        eoi_idle = 1 if (eoi and not active) else 0
        eoi_bad = 1 if (eoi and active and not eoi_ok) else 0
        acc_go = 1 if (svc and not eoi and self.irq_req and
                       self.nest_depth < NEST_MAX) else 0
        acc_of = 1 if (svc and not eoi and self.irq_req and
                       self.nest_depth == NEST_MAX) else 0
        rd_idx = 0 if depth0 else self.nest_depth - 1

        w_mask = 1 if (we and addr == A_MASK) else 0
        w_sw = 1 if (we and addr == A_SWTRIG) else 0
        w_pend = 1 if (we and addr == A_PEND) else 0
        w_ill = 1 if (we and addr > A_STAT) else 0
        sw_set = wdata if w_sw else 0
        p_clr = u((self.irq_oh if acc_go else 0) | (wdata if w_pend else 0), 16)
        s_clr = self.irq_oh if acc_go else 0

        # ---- register image written at the end of the beat ------------------
        bus_rdata = self.read_bus(addr, inact, inact_hit, irq_vec_pre)
        self.bus_rdata = bus_rdata
        self.bus_ack = 1 if (we and not w_ill) else 0

        # ---- one-beat flags --------------------------------------------------
        self.nested = 0

        # ---- two-flop synchroniser ------------------------------------------
        self.sync_meta, self.sync_q, self.sync_d = pin, self.sync_meta, self.sync_q

        # ---- pending latch and software trigger, arm before clear -----------
        self.pend = u((self.pend | newly) & ~p_clr, 16)
        self.swtrig = u((self.swtrig | sw_set) & ~s_clr, 16)
        if w_mask:
            self.mask_r = wdata

        # ---- accept the published vector ------------------------------------
        if acc_go:
            self.lane_write(self.nest_depth, self.cur_pri)
            self.cur_pri = u(self.irq_pri, 5)
            self.nest_depth = u(self.nest_depth + 1, 3)
            self.nested = active
            self.svc_cnt = bump(self.svc_cnt)

        # ---- end of interrupt ----------------------------------------------
        if eoi_ok:
            self.cur_pri = self.lane_read(rd_idx)
            self.nest_depth = u(self.nest_depth - 1, 3)
            self.nested = 0
            self.eoi_cnt = bump(self.eoi_cnt)

        # ---- error reporting, documented precedence -------------------------
        nxt = 0
        if acc_of:
            nxt = u(ERR_BASE + 3, 4)
        if eoi_bad:
            nxt = u(ERR_BASE + 2, 4)
        if eoi_idle:
            nxt = u(ERR_BASE + 1, 4)
        if w_ill:
            nxt = u(ERR_BASE + 0, 4)
        if nxt != 0:
            self.err_code = nxt
            self.err_count = bump(self.err_count)

        # ---- published vector images for the next beat ----------------------
        self.irq_pri = sel
        self.irq_oh = sel_oh
        self.irq_req = req_n
        self.ge = ge_n
        self.blocked = blk_n

    def read_bus(self, addr, inact, inact_hit, irq_vec):
        """Register map read, always from the start-of-beat images."""
        if addr == A_MASK:
            return self.mask_r
        if addr == A_SWTRIG:
            return self.swtrig
        if addr == A_PEND:
            return self.pend
        if addr == A_INACT:
            return inact
        if addr == A_VEC:
            return irq_vec
        if addr == A_STAT:
            # {1'b0, inact_hit, cur_pri, nest_depth, err_code, irq_req, blocked}
            # read from the LSB upward: blocked 0, irq_req 1, err_code 5:2,
            # nest_depth 8:6, cur_pri 13:9, inact_hit 14, spare 15.
            return u((inact_hit << 14) | (self.cur_pri << 9) |
                     (self.nest_depth << 6) | (self.err_code << 2) |
                     (self.irq_req << 1) | self.blocked, 16)
        return INVALID_RD

    def words(self):
        """The nine folded output words of the state just reached."""
        inact = u(self.pend & self.mask_r, 16)
        irq_vec = u((VECTOR_BASE << 4) | self.irq_pri, 8)
        return [
            u(self.bus_rdata, 32),
            u((self.mask_r << 16) | self.pend, 32),
            u((self.swtrig << 16) | inact, 32),
            u((self.bus_ack << 12) | (self.nest_depth << 9) |
              (self.cur_pri << 4) | self.irq_pri, 32),
            u(irq_vec, 32),
            u((self.err_code << 4) | (self.irq_req << 3) |
              (self.blocked << 2) | (self.nested << 1) | self.ge, 32),
            u((self.err_count << 14) | (self.svc_cnt << 7) | self.eoi_cnt, 32),
            u(self.stk >> 32, 32),
            u(self.stk, 32),
        ]

    def tail(self):
        return [
            u(self.err_count, 32),
            u(self.svc_cnt, 32),
            u(self.eoi_cnt, 32),
            u((self.nest_depth << 9) | (self.cur_pri << 4) | self.err_code, 32),
            u(BEATS, 32),
        ]


def run():
    core = Ctrl()
    words = []
    rstate = SEED
    for i in range(BEATS):
        rstate = lcg32(rstate)
        pin, addr, we, wdata, svc, eoi, eidx = stimulus(i, rstate)
        core.step(pin, addr, we, wdata, svc, eoi, eidx)
        words.extend(core.words())
    words.extend(core.tail())
    return words


def main():
    emit("ips_irq_priority_ctrl", run())


if __name__ == "__main__":
    main()
