"""Independent golden model for ips_key_slot_kmu.

Derived from the core's published slot-policy contract, not from the RTL and never
from simulation output (docs/IP_CORE_SOP.md trap T1):

  * SLOTS slots each hold one WORD_BITS key word, loaded in one beat;
  * a slot is write-once -- rewriting a loaded word is rejected with the write-once
    code, the slot is flagged and the stored word is kept;
  * a load into a locked or poisoned slot is rejected with the lock code;
  * lock only succeeds on a loaded slot;
  * unlock succeeds only when the caller presents key ^ (KEY_SALT ^ slot) AND the
    privilege tag bound at load time.  A failed unlock zeroises the slot, clears
    its bound tag, leaves it locked, poisons it and records ERR_ATT (bad
    attestation) or ERR_PRIV (bad tag); an unlock on a slot that is not loaded and
    locked records ERR_STATE;
  * a read is granted only for a loaded, unlocked, unpoisoned slot whose bound tag
    equals the presented tag; otherwise rd_data is driven to zero and rd_denied
    rises with ERR_LOCK (slot not usable) or ERR_PRIV (tag mismatch).  A locked
    slot therefore never reads back its value;
  * every denial or policy violation bumps the sticky per-slot tamper bit and the
    global tamper counter, which saturates at TAMPER_MAX;
  * clr purges key material and the lock/load/poison flags but keeps the sticky
    tamper bits, so the slot can be loaded again;
  * two operations in one beat are rejected with ERR_BUSY and change nothing.

Stimulus contract shared with sim/tb_ips_key_slot_kmu.v (test-only patterns, no
real keys): for every round and slot one LCG step gives the key word
    state = state * 1664525 + 1013904223 (mod 2**32), seed 0x1CEB00B0,
    key   = (state mod 2**16) ^ 0xA55A ^ (rnd * 8 + sl)   (kept to WORD_BITS bits),
privilege tag pof = (rnd ^ sl) & 15, attestation word correct when
(rnd + sl) & 1 == 0 and tag correct when (rnd + sl) & 2 == 0.  Per slot the beats
are clr, load, rewrite-attempt, [two-ops beat for slot 3], lock, load-while-locked,
read-while-locked, unlock, read-after-unlock, second unlock, read-with-wrong-tag;
then one idle beat.  Folded words per beat: rd_data, tamper_cnt, locked, loaded,
poisoned, slot_tamper, err_code, {rd_valid, rd_denied}, err_any; finally ROUNDS,
NSLOT and the DUT geometry stamp (SLOTS, WORD_BITS).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

SLOTS = 8
WORD_BITS = 16
PRIV_BITS = 4
KEY_SALT = 0xA534
TAMPER_MAX = 0xFF

ERR_NONE = 0
ERR_ONCE = 1
ERR_BUSY = 2
ERR_LOCK = 3
ERR_PRIV = 5
ERR_ATT = 6
ERR_STATE = 7

ROUNDS = 3
NSLOT = 8
SEED = 0x1CEB00B0
TB_SALT = 0xA534


class Kmu(object):
    def __init__(self):
        self.key = [0] * SLOTS
        self.priv = [0] * SLOTS
        self.locked = 0
        self.loaded = 0
        self.poisoned = 0
        self.slot_tamper = 0
        self.tamper = 0
        self.err = ERR_NONE
        self.err_any = 0
        self.rd_data = 0
        self.rd_valid = 0
        self.rd_denied = 0

    def bump(self, slot):
        self.slot_tamper |= (1 << slot)
        if self.tamper < TAMPER_MAX:
            self.tamper = (self.tamper + 1) & 0xFF

    def fail(self, code):
        self.err = code
        self.err_any = 1

    def bit(self, mask, slot):
        return (mask >> slot) & 1

    def beat(self, ld=0, lk=0, un=0, rd=0, cl=0, slot=0, data=0, att=0,
             ldp=0, attp=0, rdp=0):
        self.rd_valid = 0
        self.rd_denied = 0
        if (ld + lk + un + rd + cl) > 1:
            self.fail(ERR_BUSY)
            return

        if ld:
            if self.bit(self.locked, slot) or self.bit(self.poisoned, slot):
                self.fail(ERR_LOCK)
                self.bump(slot)
            elif self.bit(self.loaded, slot):
                self.fail(ERR_ONCE)
                self.bump(slot)
            else:
                self.key[slot] = u(data, WORD_BITS)
                self.priv[slot] = u(ldp, PRIV_BITS)
                self.loaded |= (1 << slot)
                self.err = ERR_NONE

        if lk:
            if not self.bit(self.loaded, slot):
                self.fail(ERR_STATE)
            else:
                self.locked |= (1 << slot)
                self.err = ERR_NONE

        if un:
            if not self.bit(self.loaded, slot) or not self.bit(self.locked, slot):
                self.fail(ERR_STATE)
            else:
                expect = self.key[slot] ^ u(KEY_SALT ^ slot, WORD_BITS)
                key_ok = (att == expect)
                pri_ok = (attp == self.priv[slot])
                if key_ok and pri_ok:
                    self.locked &= ~(1 << slot)
                    self.err = ERR_NONE
                else:
                    self.key[slot] = 0
                    self.priv[slot] = 0
                    self.loaded &= ~(1 << slot)
                    self.locked |= (1 << slot)
                    self.poisoned |= (1 << slot)
                    self.fail(ERR_ATT if pri_ok else ERR_PRIV)
                    self.bump(slot)

        if rd:
            ready = (self.bit(self.loaded, slot) and not self.bit(self.locked, slot)
                     and not self.bit(self.poisoned, slot))
            if not ready:
                self.rd_data = 0
                self.rd_denied = 1
                self.fail(ERR_LOCK)
                self.bump(slot)
            elif rdp != self.priv[slot]:
                self.rd_data = 0
                self.rd_denied = 1
                self.fail(ERR_PRIV)
                self.bump(slot)
            else:
                self.rd_data = self.key[slot]
                self.rd_valid = 1
                self.err = ERR_NONE

        if cl:
            self.key[slot] = 0
            self.locked &= ~(1 << slot)
            self.loaded &= ~(1 << slot)
            self.poisoned &= ~(1 << slot)
            self.err = ERR_NONE

    def words(self):
        return [u(self.rd_data, 32), u(self.tamper, 32), u(self.locked, 32),
                u(self.loaded, 32), u(self.poisoned, 32), u(self.slot_tamper, 32),
                u(self.err, 32),
                ((self.rd_valid & 1) << 1) | (self.rd_denied & 1),
                u(self.err_any, 32)]


def main():
    dut = Kmu()
    state = SEED
    words = []

    for rnd in range(ROUNDS):
        for sl in range(NSLOT):
            pof = (rnd ^ sl) & 0xF
            keyok = ((rnd + sl) & 1) == 0
            priok = ((rnd + sl) & 2) == 0

            state = lcg32(state)
            key_word = (u(state, WORD_BITS) ^ 0xA55A
                        ^ ((rnd * 8 + sl) & MASK32)) & MASK32

            dut.beat(cl=1, slot=sl, ldp=pof, attp=pof, rdp=pof)
            words += dut.words()

            dut.beat(ld=1, slot=sl, data=key_word, ldp=pof)
            words += dut.words()

            dut.beat(ld=1, slot=sl, data=key_word ^ 0x00F5, ldp=pof)
            words += dut.words()

            if sl == 3:
                dut.beat(ld=1, rd=1, slot=sl, data=key_word, ldp=pof)
                words += dut.words()

            dut.beat(lk=1, slot=sl)
            words += dut.words()

            dut.beat(ld=1, slot=sl, data=key_word ^ 0x5A00, ldp=pof)
            words += dut.words()

            dut.beat(rd=1, slot=sl, rdp=pof)
            words += dut.words()

            att = key_word ^ ((TB_SALT ^ sl) & MASK32)
            if not keyok:
                att = (att ^ 1) & MASK32
            upriv = pof if priok else (pof ^ 0x7)
            dut.beat(un=1, slot=sl, att=att, attp=upriv, ldp=pof, rdp=pof)
            words += dut.words()

            dut.beat(rd=1, slot=sl, rdp=pof)
            words += dut.words()

            dut.beat(un=1, slot=sl, att=key_word ^ ((TB_SALT ^ sl) & MASK32),
                     attp=pof, ldp=pof, rdp=pof)
            words += dut.words()

            dut.beat(rd=1, slot=sl, rdp=pof ^ 0x5)
            words += dut.words()

    # idle beat: the read pulses fall, the state registers hold
    dut.beat()
    words += dut.words()

    words.append(ROUNDS)
    words.append(NSLOT)
    words.append(SLOTS)
    words.append(WORD_BITS)

    emit('ips_key_slot_kmu', words)


if __name__ == '__main__':
    main()
