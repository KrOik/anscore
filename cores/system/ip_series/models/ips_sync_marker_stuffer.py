"""Independent golden model for ips_sync_marker_stuffer.

Written from the escape/framing contract in src/ips_sync_marker_stuffer.v, never from
simulation output (docs/IP_CORE_SOP.md trap T1).  Declared defaults, which the series
testbench exercises without any #() override:

  SYNC_BYTE = 0x7A (frame marker), ESC_BYTE = 0x7D (escape), XOR_MASK = 0x20,
  FRAME_ESC_MAX = 24, Q_DEPTH = 3 (FWFT output queue), counter ceilings
  LIM8 = 0xFF / LIM4 = 0xF.

Contract:

  * mode 0 INSERT: a data byte equal to SYNC_BYTE or ESC_BYTE leaves the core as the
    two-byte sequence ESC_BYTE, byte^XOR_MASK; any other data byte is forwarded
    untouched.  sync_req presented on a beat of its own (in_valid low) emits one
    SYNC_BYTE with out_sof set; sync_req presented together with a data byte is a
    requester error, latched in err_sticky[2] and counted, and the data byte is still
    forwarded.
  * mode 1 REMOVE: SYNC_BYTE is a frame boundary and is re-emitted with out_sof,
    ESC_BYTE is consumed and the byte behind it is unfolded (byte^XOR_MASK).  A marker
    that arrives while an escape is pending is a truncated escape (err_sticky[0]); two
    escapes in a row are ambiguous and an escaped byte whose unescaped value is not a
    control byte could not have been produced by this stuffer (either one latches
    err_sticky[1]); requester errors latch err_sticky[2].  A *legal* escape is fully
    transparent: the escaped form of SYNC_BYTE (0x5A) and of ESC_BYTE (0x5D) unfold
    back into exactly those control bytes and are never reported.
  * handshake: out_valid is the queue being non-empty, out_byte/out_sof are its head
    and hold while out_ready is low; the head only moves on an accepted output beat.
    in_ready reflects the room the beat would need (an escaping byte needs two free
    slots), so no accepted byte is ever dropped; a refused beat is re-presented.
  * accounting: cnt_in consumed data bytes, cnt_out emitted bytes, cnt_sync markers
    inserted or recognised, cnt_esc escapes inserted or consumed, cnt_spur the
    malformed events (saturating at 0xF), frame_esc escapes of the frame being streamed
    (cleared by a marker, clamped at FRAME_ESC_MAX with err_sticky[3]).  Every counter
    saturates at its ceiling and latches its cnt_sat bit: cnt_in[0], cnt_out[1],
    cnt_esc[2], cnt_sync[3], cnt_spur[4].
  * every register is gated by clk_en and rst_n is the active-low asynchronous reset
    that returns all of them to zero.

The schedule below replays sim/tb_ips_sync_marker_stuffer.v beat for beat.  One beat is
exactly one enabled posedge (clk_en is low on the intervening edge), a beat with ce = 0
leaves the core untouched and a beat with doret = 1 resets it.  The testbench reads the
control bytes from the DUT instance; this model uses the declared defaults.  The wire
stream the phase-A stuffer emits is recorded here and fed back in phase B, exactly as
the testbench does, so the escape/unescape transparency is checked against the model's
own two passes rather than against a constant copied from simulation output.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

SYNC = 0x7A
ESC = 0x7D
MASK = 0x20
FEM = 24
QD = 3
LIM8 = 0xFF
LIM4 = 0xF

SEED = 0x5A5C3D71
NPA = 48
MK_CAD = 6
ORDY_SLOT = 7
NSTALL = 4

REC_NONE, REC_WIRE, REC_DEC = 0, 1, 2


class Dut(object):
    """Cycle model of ips_sync_marker_stuffer, one enabled posedge per step()."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.s = [0, 0, 0]        # slot 0 is the queue head
        self.h = [0, 0, 0]        # its start-of-frame marks
        self.qcnt = 0
        self.esc_pend = 0
        self.cnt_in = 0
        self.cnt_out = 0
        self.cnt_esc = 0
        self.cnt_sync = 0
        self.cnt_spur = 0
        self.frame_esc = 0
        self.err = 0
        self.sat = 0

    # ---- combinational classification of the presented beat ------------------
    def _decode_beat(self, mode, v, d, srq):
        enc = 1 - mode
        ctl_look = 1 if (d == SYNC or d == ESC) else 0
        need_esc = 1 if (enc and v and ctl_look) else 0
        d_sync = 1 if (mode and v and d == SYNC) else 0
        d_esc = 1 if (mode and v and d == ESC) else 0
        d_unfold = 1 if (mode and self.esc_pend and v and not d_sync
                         and not d_esc) else 0
        unfolded_ctl = 1 if ((d ^ MASK) == SYNC or (d ^ MASK) == ESC) else 0
        unfold_bad = 1 if (d_unfold and not unfolded_ctl) else 0
        marker_out = 1 if (enc and srq and not v) else 0
        ev_malformed = 1 if (v and srq) else 0
        ev_trunc = 1 if (d_sync and self.esc_pend) else 0
        ev_ambig = 1 if (d_esc and self.esc_pend) else 0
        ev_esc = 1 if (need_esc or d_unfold) else 0
        ev_sync = 1 if (marker_out or d_sync) else 0

        ins, p, g = 0, [0, 0, 0], [0, 0, 0]
        if enc:
            if v:
                if need_esc:
                    ins, p = 2, [ESC, u(d ^ MASK, 8), 0]
                else:
                    ins, p = 1, [d, 0, 0]
            elif srq:
                ins, p, g = 1, [SYNC, 0, 0], [1, 0, 0]
        else:
            if d_sync:
                ins, p, g = 1, [SYNC, 0, 0], [1, 0, 0]
            elif v and not d_esc:
                ins, p = 1, [u(d ^ MASK, 8) if d_unfold else d, 0, 0]

        room = QD - self.qcnt
        irdy = 1 if room >= ins else 0
        acc = 1 if (irdy and (v or (srq and enc))) else 0
        return dict(enc=enc, need_esc=need_esc, d_sync=d_sync, d_esc=d_esc,
                    d_unfold=d_unfold, unfold_bad=unfold_bad, ev_malformed=ev_malformed,
                    ev_trunc=ev_trunc, ev_ambig=ev_ambig, ev_esc=ev_esc,
                    ev_sync=ev_sync, ins=ins, p=p, g=g, irdy=irdy, acc=acc)

    def pre(self, mode, v, d, srq, ordy):
        """The view the testbench samples while the beat is presented."""
        b = self._decode_beat(mode, v, d, srq)
        ov = 1 if self.qcnt != 0 else 0
        pop = 1 if (ov and ordy) else 0
        return b, b['irdy'], ov, self.s[0], self.h[0], pop, self.qcnt

    def _bump8(self, name, sat_bit):
        if getattr(self, name) < LIM8:
            setattr(self, name, u(getattr(self, name) + 1, 8))
        else:
            self.sat |= 1 << sat_bit

    def step(self, mode, v, d, srq, ordy):
        b = self._decode_beat(mode, v, d, srq)
        ov = 1 if self.qcnt != 0 else 0
        pop = 1 if (ov and ordy) else 0
        base = self.qcnt - 1 if pop else self.qcnt
        push = b['ins'] if b['acc'] else 0
        nc = base + push
        if nc > QD:
            nc = QD
        if pop:
            n = [self.s[1], self.s[2], self.s[2]]
            f = [self.h[1], self.h[2], self.h[2]]
        else:
            n = [self.s[0], self.s[1], self.s[2]]
            f = [self.h[0], self.h[1], self.h[2]]
        if push >= 1 and base < QD:
            slot = base if base <= 2 else 2
            n[slot] = b['p'][0]
            f[slot] = b['g'][0]
        if push >= 2:
            if base == 0:
                n[1], f[1] = b['p'][1], b['g'][1]
            elif base == 1:
                n[2], f[2] = b['p'][1], b['g'][1]
        if push >= 3 and base == 0:
            n[2], f[2] = b['p'][2], b['g'][2]
        self.s, self.h, self.qcnt = n, f, u(nc, 3)

        if b['acc']:
            if (b['ev_trunc'] or b['ev_ambig'] or b['unfold_bad']
                    or b['ev_malformed']):
                if self.cnt_spur < LIM4:
                    self.cnt_spur = u(self.cnt_spur + 1, 4)
                else:
                    self.sat |= 1 << 4
            if b['ev_trunc']:
                self.err |= 1
            if b['ev_ambig'] or b['unfold_bad']:
                self.err |= 2
            if b['ev_malformed']:
                self.err |= 4
            if v:
                self._bump8('cnt_in', 0)
            if b['ev_sync']:
                self._bump8('cnt_sync', 3)
            if b['ev_esc']:
                self._bump8('cnt_esc', 2)
            if b['ev_sync']:
                self.frame_esc = 0
            elif b['ev_esc']:
                if self.frame_esc >= FEM:
                    self.err |= 8
                    self.frame_esc = FEM
                else:
                    self.frame_esc = u(self.frame_esc + 1, 8)
            if b['d_esc']:
                self.esc_pend = 1
            elif b['d_unfold'] or b['d_sync']:
                self.esc_pend = 0
        if pop:
            self._bump8('cnt_out', 1)


class Runner(object):
    def __init__(self):
        self.dut = Dut()
        self.mode = 0
        self.bi = 0
        self.beats = 0
        self.words = []
        self.rec_mode = REC_NONE
        self.xmem = []
        self.xsof = []
        self.emem = []
        self.esof = []
        self.dmem = []
        self.dsof = []

    @property
    def xn(self):
        return len(self.xmem)

    @property
    def en(self):
        return len(self.emem)

    @property
    def dn(self):
        return len(self.dmem)

    def _ordy(self):
        return 0 if (self.bi % ORDY_SLOT) == 4 else 1

    def beat(self, v, d, srq, ordy, ce, doret):
        if doret:
            self.dut.reset()
        _, p_irdy, p_ov, p_ob, p_os, p_pop, p_ql = self.dut.pre(
            self.mode, v, d, srq, ordy)
        # only an enabled, non-reset beat really consumes the head, even though
        # out_valid && out_ready is true for the whole disabled period
        if not (ce and not doret):
            p_pop = 0
        acc_l = bool(ce and not doret and (v or (srq and self.mode == 0)) and p_irdy)
        if ce and not doret:
            self.dut.step(self.mode, v, d, srq, ordy)
        s = self.dut
        out_valid = 1 if s.qcnt != 0 else 0
        w = self.words
        w.append((p_irdy << 3) | (p_ov << 2) | (p_pop << 1) | p_os)
        w.append(p_ob)
        w.append(p_ql)
        w.append((out_valid << 1) | s.h[0])
        w.append(s.s[0])
        w.append(s.qcnt)
        w.append(s.cnt_in)
        w.append(s.cnt_out)
        w.append(s.cnt_esc)
        w.append(s.cnt_sync)
        w.append(s.frame_esc)
        w.append(s.cnt_spur)
        w.append(s.err)
        w.append(s.sat)
        if p_pop:
            if self.rec_mode == REC_WIRE:
                self.emem.append(p_ob)
                self.esof.append(p_os)
            elif self.rec_mode == REC_DEC:
                self.dmem.append(p_ob)
                self.dsof.append(p_os)
        self.bi += 1
        self.beats += 1
        return acc_l

    def xlog(self, b, s):
        self.xmem.append(b)
        self.xsof.append(s)

    def send_data(self, d, srq):
        acc_l = False
        gi = 0
        while not acc_l and gi < 200:
            acc_l = self.beat(1, d, srq, self._ordy(), 1, 0)
            gi += 1

    def send_marker(self):
        # a marker is requested on a beat of its own: in_valid low, sync_req high
        acc_l = False
        gi = 0
        while not acc_l and gi < 200:
            acc_l = self.beat(0, 0, 1, self._ordy(), 1, 0)
            gi += 1

    def send_in(self, d):
        self.send_data(d, 0)

    def stall_burst(self, do_log, is_dec):
        for j in range(NSTALL):
            b2 = ((0x31 if is_dec else 0x11) + j) & 0xFF
            acc_l = False
            gi = 0
            while not acc_l and gi < 16:
                acc_l = self.beat(1, b2, 0, 0, 1, 0)
                gi += 1
            if acc_l:
                if do_log:
                    self.xlog(b2, 0)
            else:
                acc_l = False
                gi = 0
                while not acc_l and gi < 64:
                    acc_l = self.beat(1, b2, 0, 1, 1, 0)
                    gi += 1
                if do_log:
                    self.xlog(b2, 0)

    def drain_out(self):
        gi = 0
        while self.dut.qcnt != 0 and gi < 48:
            self.beat(0, 0, 0, 1, 1, 0)
            gi += 1

    def idle_beats(self, n):
        for _ in range(n):
            self.beat(0, 0, 0, 1, 1, 0)


def main():
    r = Runner()
    dut = r.dut
    state = SEED

    # ------------------------- phase A: INSERT -------------------------------
    r.mode = 0
    r.rec_mode = REC_WIRE
    r.send_marker()
    r.xlog(SYNC, 1)
    for i in range(NPA):
        state = (state * 1664525 + 1013904223) & MASK32
        b2 = (state >> 8) & 0xFF
        if i % 4 == 1:
            b2 = SYNC
        elif i % 4 == 2:
            b2 = ESC
        elif i % 4 == 3:
            b2 = (SYNC ^ MASK) if (i % 2 == 0) else (ESC ^ MASK)
        if i == 7 or i == 23:
            r.send_data(b2, 1)          # requester error, byte still forwarded
            r.xlog(b2, 0)
        elif i == 11:
            r.beat(1, b2, 0, r._ordy(), 0, 0)   # clk_en low for a whole period
            r.send_data(b2, 0)
            r.xlog(b2, 0)
        elif i == 31:
            r.drain_out()
            r.stall_burst(True, False)
        else:
            r.send_data(b2, 0)
            r.xlog(b2, 0)
        if i % MK_CAD == MK_CAD - 1:
            r.send_marker()
            r.xlog(SYNC, 1)
    r.drain_out()                # drain while still recording: nothing may be dropped
    r.rec_mode = REC_NONE

    # ------------------------- phase B: REMOVE -------------------------------
    r.mode = 1
    r.rec_mode = REC_DEC
    for k in range(r.en):
        wire_byte = r.emem[k]
        if k == 25:
            r.beat(1, wire_byte, 0, r._ordy(), 0, 0)   # clk_en low
            r.send_in(wire_byte)
        else:
            r.send_in(wire_byte)
    r.drain_out()                # the destuffed tail belongs to the transparency stream
    r.rec_mode = REC_NONE

    r.stall_burst(False, True)
    r.drain_out()

    # a legal escape of the marker byte must be transparent
    r.send_in(ESC)
    r.send_in(SYNC ^ MASK)
    # truncated escape
    r.send_in(ESC)
    r.send_in(SYNC)
    # ambiguous escapes, then an escape this stuffer could not have produced
    r.send_in(ESC)
    r.send_in(ESC)
    r.send_in(0x41)
    # requester error in the remove direction
    r.send_data(0x31, 1)
    r.drain_out()

    # ---------------------- phase C: frame escape budget ---------------------
    r.mode = 0
    r.send_marker()
    go = 0
    while (dut.frame_esc != FEM or (dut.err & 8) == 0) and go < 200:
        r.send_data(SYNC if (go & 1) == 0 else ESC, 0)
        go += 1
    r.send_marker()
    r.drain_out()

    # ---------------------- phase D: saturating counters ---------------------
    r.mode = 1
    go = 0
    while ((dut.cnt_in != LIM8 or dut.cnt_out != LIM8
            or not (dut.sat & 1) or not (dut.sat & 2)) and go < 600):
        r.send_in(0x31 if (go & 1) == 0 else 0x52)
        go += 1

    r.mode = 0
    go = 0
    while (dut.cnt_sync != LIM8 or not (dut.sat & 8)) and go < 600:
        r.send_marker()
        go += 1

    go = 0
    while (dut.cnt_esc != LIM8 or not (dut.sat & 4)) and go < 1400:
        r.send_data(ESC if (go & 1) == 0 else SYNC, 0)
        go += 1

    go = 0
    while (dut.cnt_spur != LIM4 or not (dut.sat & 16)) and go < 80:
        r.send_data(0x61, 1)
        go += 1
    r.drain_out()

    # ---------------------- phase E: asynchronous reset ----------------------
    r.mode = 0
    for i in range(3):
        acc_l = False
        gi = 0
        while not acc_l and gi < 16:
            acc_l = r.beat(1, (0x70 + i) & 0xFF, 0, 0, 1, 0)
            gi += 1
    r.beat(1, 0x11, 0, 1, 1, 1)      # rst_n low, a byte still being presented
    r.beat(0, 0, 0, 1, 1, 1)         # rst_n low for a second period
    r.beat(0, 0, 0, 1, 1, 0)         # released
    r.send_marker()
    r.send_data(SYNC, 0)
    r.send_data(0x23, 0)
    r.drain_out()
    r.send_marker()              # the closing marker re-opens the frame
    r.drain_out()
    r.idle_beats(2)

    w = r.words
    w.extend([dut.cnt_in, dut.cnt_out, dut.cnt_esc, dut.cnt_sync, dut.cnt_spur,
              dut.frame_esc, dut.err, dut.sat, dut.s[0], dut.qcnt,
              r.xn, r.en, r.dn, r.beats])

    emit('ips_sync_marker_stuffer', w)


if __name__ == '__main__':
    main()
