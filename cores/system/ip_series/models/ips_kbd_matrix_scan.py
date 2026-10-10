"""Independent golden model for ips_kbd_matrix_scan.

This replay is written from the WRITTEN CONTRACT at the top of
src/ips_kbd_matrix_scan.v (pad interface, flattened rotating-ring matrix, three
phase scan calendar, phantom-corner rule, roll-over walk, code arithmetic) and
from the stimulus contract of sim/tb_ips_kbd_matrix_scan.v.  It never reads
simulation output and digests are never back-filled
(docs/IP_CORE_SOP.md trap T1).

Folding rule -- identical to the rule stated in the testbench header: four
32-bit words per enabled beat, MSB byte first, then the five-word tail.
    W0 = {17'd0, code_slot,  key_code}
    W1 = {16'd0, rel_code,   press_code}
    W2 = { 5'd0, rel_cnt,  press_cnt, key_count, phantom_code}
    W3 = {11'd0, scan_cnt, scan_col, phase, stuck_flag, nk_over, ghost_flag,
          report_done, code_valid, press_col, rel_col}
    tail: {25'd0, key_count}, {20'd0, rel_cnt, press_cnt}, {24'd0, scan_cnt},
          {29'd0, ghost_flag, nk_over, stuck_flag}, BEATS
Only DUT outputs are folded.  The words come from the state AFTER each enabled
posedge, which is the moment the testbench samples them (following negedge).

Stimulus contract shared with the testbench:
  * clk_en is a free-running 5-state divisor, so loop iteration i is exactly the
    (i+1)-th enabled posedge after reset; the two enabled posedges that happen
    while rst_n is still low leave the core in its reset state.
  * the key map is a 64-bit column-major closure map, byte c = rows closed in
    column c; the sensed row byte is byte (driven column) of that map.
  * episode e is applied for exactly one scan cycle: the map advances on the
    beat that published report_done.  Episodes 0..11 are directed, episode 12
    and later come from the LCG.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

# --- parameters / localparams / testbench constants ---------------------------
BEATS = 600
CODE_BASE = 0x21      # parameter CODE_BASE
NKR_MAX = 6           # parameter NKR_MAX
ROW_POL = 0x00        # parameter ROW_POL
PASS_WRAP = 7         # localparam PASS_WRAP
STUCK_PAT = 0xFF      # localparam STUCK_PAT
NO_CODE = 0x00        # localparam NO_CODE
SUB_EVAL = 2          # localparam SUB_EVAL
EMIT_WRAP = 7         # localparam EMIT_WRAP
P_SCAN, P_ANALZ, P_EMIT = 0, 1, 2
SEED = 0xBADCAFE0
M8 = 0xFF
M64 = (1 << 64) - 1

# Directed episodes -- the same map values as the testbench table.
DIRECTED = [
    0x0000000000000000,   # EP0  no key
    0x0000000004000000,   # EP1  (row 2, col 3) pressed
    0x0000000004000000,   # EP2  same key held
    0x0000000000000000,   # EP3  released
    0x2000000000000200,   # EP4  (1,1) + (5,7), no ghost
    0x0000000100000009,   # EP5  3-key L -> phantom corner (row 3, col 4)
    0x0000000900000009,   # EP6  full rectangle, no phantom
    0x0000000100000009,   # EP7  3-key L again, over the rectangle
    0x0000201008040201,   # EP8  six diagonal keys == NKR_MAX
    0x0040201008040201,   # EP9  seven keys -> roll-over exceeded
    0x0000000000000000,   # EP10 all released
    0x0000FF0000000000,   # EP11 column 5 shorted (stuck)
]


def episode(ep, state):
    """Key map of episode ep plus the generator state after producing it."""
    if ep < len(DIRECTED):
        return DIRECTED[ep], state
    state = lcg32(state)
    ngen = 1 + ((state >> 6) & 3)
    kmap = 0
    for _ in range(ngen):
        state = lcg32(state)
        row = state & 7
        col = (state >> 4) & 7
        kmap |= 1 << (col * 8 + row)
    return kmap, state


def enc3(one_hot):
    """Index named by a one-hot byte: the three OR trees of the contract."""
    v = one_hot & M8
    return (((1 if (v & 0xF0) else 0) << 2) |
            ((1 if (v & 0xCC) else 0) << 1) |
            (1 if (v & 0xAA) else 0))


def lsb3(value):
    """Lowest set bit index of an 8-bit word.  A zero word returns 0, the same
    value the core's lsb3 function produces; every caller gates on a non-zero
    word, so that value never reaches a code."""
    v = value & M8
    for k in range(8):
        if (v >> k) & 1:
            return k
    return 0


class Scanner(object):
    """Cycle-accurate replay of the rotating-ring scan calendar.

    ring byte s carries column (head - 1 - s) mod 8, head = enc3(tok), and a
    rotating beat moves every byte one slot up while a one-hot tok names the
    column parked in the top byte.
    """

    def __init__(self):
        self.phase = P_SCAN
        self.ring = 0
        self.tok = 0x01
        self.ap = 0
        self.sub = 0
        self.ew = 0
        self.tgt = 0
        self.tgtc = 0
        self.orv = 0
        self.rem = 0
        self.ghost_seen = 0
        self.stuck_seen = 0
        self.ph_idx = 0
        self.slot_n = 0
        self.key_code = NO_CODE
        self.code_valid = 0
        self.code_slot = 0
        self.key_count = 0
        self.press_col = 0
        self.rel_col = 0
        self.press_code = NO_CODE
        self.rel_code = NO_CODE
        self.press_cnt = 0
        self.rel_cnt = 0
        self.ghost_flag = 0
        self.phantom_code = NO_CODE
        self.nk_over = 0
        self.stuck_flag = 0
        self.report_done = 0
        self.scan_cnt = 0

    def byte(self, s):
        return (self.ring >> (8 * s)) & M8

    # --- one enabled clock edge ----------------------------------------------
    def step(self, row_in):
        head = enc3(self.tok)
        tok_nx = u((self.tok << 1) | (self.tok >> 7), 8)
        rin = u(row_in ^ ROW_POL, 8)
        b1, b3, b5, b6, b7 = self.byte(1), self.byte(3), self.byte(5), \
            self.byte(6), self.byte(7)
        inject = rin if self.phase == P_SCAN else b7
        ring_nx = u((self.ring << 8) | inject, 64) & M64

        # analyser union of the four fixed comparison slots
        orv_u = 0
        for slot in (b1, b3, b5, b7):
            if (slot & self.tgt) != 0:
                orv_u = u(orv_u | slot, 8)
        orv_nx = u(self.orv | orv_u, 8)
        ph_nx = u(self.orv & (self.tgt ^ M8), 8)
        ghost_nx = 1 if (self.ghost_seen != 0 or ph_nx != 0) else 0
        if self.ghost_seen:
            ph_idx_nx = self.ph_idx
        else:
            ph_idx_nx = u((self.tgtc << 3) | lsb3(ph_nx), 6)

        press8 = u(rin & (b7 ^ M8), 8)
        rel8 = u(b7 & (rin ^ M8), 8)
        onehot = u(self.rem & u(1 + (~self.rem), 8), 8)
        eidx = u((head << 3) | enc3(onehot), 6)

        # outputs that this edge does not talk about return to idle
        self.report_done = 0
        self.code_valid = 0
        self.key_code = NO_CODE
        self.press_col = 0
        self.rel_col = 0

        if self.phase == P_SCAN:
            self.ring = ring_nx
            self.tok = tok_nx
            self.tgt = b6
            self.tgtc = enc3(tok_nx)
            self.orv = 0
            if rin == STUCK_PAT:
                self.stuck_seen = 1
            if press8 != 0:
                self.press_col = 1
                self.press_code = u(CODE_BASE + (head << 3) + lsb3(press8), 8)
                self.press_cnt = u(self.press_cnt + 1, 6)
            if rel8 != 0:
                self.rel_col = 1
                self.rel_code = u(CODE_BASE + (head << 3) + lsb3(rel8), 8)
                self.rel_cnt = u(self.rel_cnt + 1, 6)
            if self.ap == PASS_WRAP:
                self.ap = 0
                self.sub = 0
                self.phase = P_ANALZ
            else:
                self.ap = u(self.ap + 1, 3)

        elif self.phase == P_ANALZ:
            self.ring = ring_nx
            self.tok = tok_nx
            if self.sub < SUB_EVAL:
                self.orv = orv_u if self.sub == 0 else orv_nx
                self.sub = u(self.sub + 1, 2)
            else:
                if ph_nx != 0 and self.ghost_seen == 0:
                    self.ghost_seen = 1
                    self.ph_idx = ph_idx_nx
                self.tgt = b6
                self.tgtc = enc3(tok_nx)
                self.orv = 0
                self.sub = 0
                if self.ap == PASS_WRAP:
                    self.ap = 0
                    self.phase = P_EMIT
                    self.rem = b6
                    self.ew = 0
                    self.slot_n = 0
                    self.key_count = 0
                    self.ghost_flag = ghost_nx
                    self.phantom_code = (u(CODE_BASE + ph_idx_nx, 8)
                                         if ghost_nx else NO_CODE)
                    self.stuck_flag = self.stuck_seen
                    self.ghost_seen = 0
                    self.stuck_seen = 0
                else:
                    self.ap = u(self.ap + 1, 3)

        elif self.phase == P_EMIT:
            if self.rem != 0:
                self.code_valid = 1
                self.key_code = u(CODE_BASE + eidx, 8)
                self.code_slot = self.slot_n
                self.slot_n = u(self.slot_n + 1, 7)
                self.key_count = u(self.key_count + 1, 7)
                self.rem = u(self.rem & (onehot ^ M8), 8)
            else:
                self.ring = ring_nx
                self.tok = tok_nx
                self.rem = b6
                if self.ew == EMIT_WRAP:
                    self.phase = P_SCAN
                    self.ew = 0
                    self.report_done = 1
                    self.nk_over = 1 if self.key_count > NKR_MAX else 0
                    self.scan_cnt = u(self.scan_cnt + 1, 8)
                    self.press_cnt = 0
                    self.rel_cnt = 0
                    self.press_code = NO_CODE
                    self.rel_code = NO_CODE
                else:
                    self.ew = u(self.ew + 1, 3)

        else:
            self.phase = P_SCAN
            self.ap = 0
            self.sub = 0

    def scan_col(self):
        return enc3(self.tok)

    # --- the four folded words of the beat that just ran ---------------------
    def words(self):
        w0 = u((self.code_slot << 8) | self.key_code, 32)
        w1 = u((self.rel_code << 8) | self.press_code, 32)
        w2 = u((self.rel_cnt << 21) | (self.press_cnt << 15) |
               (self.key_count << 8) | self.phantom_code, 32)
        w3 = u((self.scan_cnt << 13) | (self.scan_col() << 9) |
               (self.phase << 7) | (self.stuck_flag << 6) |
               (self.nk_over << 5) | (self.ghost_flag << 4) |
               (self.report_done << 3) | (self.code_valid << 2) |
               (self.press_col << 1) | self.rel_col, 32)
        return (w0, w1, w2, w3)


def run():
    core = Scanner()
    words = []
    kmap, state = episode(0, SEED)
    ep = 0

    for _ in range(BEATS):
        row_in = (kmap >> (8 * enc3(core.tok))) & M8
        core.step(row_in)
        words.extend(core.words())
        if core.report_done:
            ep += 1
            kmap, state = episode(ep, state)

    words.append(u(core.key_count, 32))
    words.append(u((core.rel_cnt << 6) | core.press_cnt, 32))
    words.append(u(core.scan_cnt, 32))
    words.append(u((core.ghost_flag << 2) | (core.nk_over << 1) |
                   core.stuck_flag, 32))
    words.append(u(BEATS, 32))
    return words


def main():
    emit("ips_kbd_matrix_scan", run())


if __name__ == "__main__":
    main()
