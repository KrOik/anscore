"""Independent golden model for ips_secded64_ecc.

Written from the SECDED(72,64) coding theory, not from simulation output
(docs/IP_CORE_SOP.md trap T1).  The model derives everything from the classic
Hamming position numbering -- codeword position p (1..72) carries a Hamming
check bit when p is a power of two, the 64 data bits fill the remaining
positions in ascending order, and position 72 is the overall parity extension.
The encoder solves the check bits out of the position coverage equations, the
decoder evaluates those same equations, and neither side uses the generator row
masks the RTL happens to store.

Coding-theory facts asserted below, independently of the RTL:
  * column(q) = {1 ^ parity(q), q} for q = 1..71 and column(72) = 0x80 are the
    72 H columns of the odd-weight basis the core reports;
  * they are all non-zero, all odd weight and pairwise distinct, so no double
    error can mimic a single one and three columns never XOR to zero
    (d_min >= 4); positions {1,2,4,7} do XOR to zero, so d_min == 4 exactly;
  * every single-bit flip decodes to its own position number and re-encodes to
    the transmitted codeword, and every double flip is flagged uncorrectable;
  * the odd-weight classification the core uses (odd popcount -> correctable,
    non-zero even -> uncorrectable) agrees with the textbook parity-charting
    rule (overall parity bad -> single, overall parity good with a non-zero
    Hamming syndrome -> double) on every beat.

Stimulus contract shared with sim/tb_ips_secded64_ecc.v:
    state = state * 1664525 + 1013904223 (mod 2**32), from 0x5EED1234
    NDW = 4 payload words: all-zero, all-ones, then {f, state} from two LCG
    draws; each word is encoded, decoded clean, decoded with all NPOS = 72
    single-bit flips in flat-codeword order, then NDBL = 8 LCG double flips
    (k = state % 72, q = (k + 1 + ((state >> 8) % 71)) % 72), then one idle
    beat; NMIX = 12 further encode beats with word = {state, ~state}, the
    fourth of them followed by a decode of flat bit 40 flipped, then two more
    idle beats and four accounting words.

Folding rule -- the same seven 32-bit words per beat, MSB byte first, that the
testbench folds; it folds the core's REGISTERED outputs, so an idle beat
repeats the previous beat's words with done = 0:
    1  {22'd0, err_pos, ce, ue, done}
    2  {24'd0, syndrome}
    3  {26'd0, syn_wt, err_sticky}
    4  {24'd0, ce_cnt, ue_cnt}
    5  code_out[31:0]
    6  code_out[63:32]
    7  {8'd0, chk_out}
then once each: {24'd0, ce_cnt}, {24'd0, ue_cnt}, {28'd0, err_sticky}, beats.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

NDW = 4
NPOS = 72
NDBL = 8
NMIX = 12
SEED = 0x5EED1234
PAR_POS = 72
CE_MAX = 0xF
UE_MAX = 0xF
NCHK = 7

POW2 = set(1 << j for j in range(NCHK))
POS_OF = [p for p in range(1, 72) if p not in POW2]
assert len(POS_OF) == 64, len(POS_OF)

FLAT_OF = {}
for _i, _p in enumerate(POS_OF):
    FLAT_OF[_p] = _i
for _j in range(NCHK):
    FLAT_OF[1 << _j] = 64 + _j
FLAT_OF[72] = 71
assert len(FLAT_OF) == 72

COVER = [[p for p in range(1, 72) if p & (1 << j)] for j in range(NCHK)]


def popcount(value):
    return bin(value).count("1")


def parity(value):
    return popcount(value) & 1


def column(pos):
    """The reported 8-bit H column of codeword position pos (odd-weight basis)."""
    if pos == 72:
        return 0x80
    return ((1 ^ parity(pos)) << 7) | pos


def get_bit(code, pos):
    return (code >> FLAT_OF[pos]) & 1


def flip_bit(code, pos):
    return code ^ (1 << FLAT_OF[pos])


def data_of(code):
    return code & ((1 << 64) - 1)


def encode(word):
    """Solve the coverage equations: the bit at position 2**j cancels the XOR of
    all bits whose position has bit j set, and position 72 cancels the XOR of
    all 72 bits."""
    code = 0
    for i in range(64):
        if (word >> i) & 1:
            code |= 1 << i
    for j in range(NCHK):
        acc = 0
        for i in range(64):
            if ((word >> i) & 1) and (POS_OF[i] & (1 << j)):
                acc ^= 1
        if acc:
            code |= 1 << (64 + j)
    par = 0
    for p in range(1, 72):
        if (code >> FLAT_OF[p]) & 1:
            par ^= 1
    if par:
        code |= 1 << 71
    return code


def analyse(code):
    """Evaluate the coverage equations and the overall parity of the received
    word: (extended syndrome, Hamming part, overall parity check)."""
    syn_h = 0
    for j in range(NCHK):
        acc = 0
        for p in COVER[j]:
            acc ^= get_bit(code, p)
        if acc:
            syn_h |= 1 << j
    pchk = 0
    for p in range(1, 73):
        pchk ^= get_bit(code, p)
    syn = ((pchk ^ parity(syn_h)) << 7) | syn_h
    return syn, syn_h, pchk


def classify(syn, syn_h, pchk):
    """Odd-weight rule (what the core reports) plus the textbook rule it must
    agree with: bad overall parity -> single error, good parity with a non-zero
    Hamming syndrome -> double error."""
    any_err = syn != 0
    ce = any_err and (popcount(syn) & 1) == 1
    ue = any_err and (popcount(syn) & 1) == 0
    assert ce == bool(pchk), (hex(syn), syn_h, pchk)
    assert ue == ((not pchk) and syn_h != 0), (hex(syn), syn_h, pchk)
    return ce, ue


def verify_code_geometry():
    cols = [column(p) for p in range(1, 73)]
    assert len(cols) == 72
    for c in cols:
        assert c != 0 and (popcount(c) & 1) == 1, hex(c)
    assert len(set(cols)) == 72, "duplicate H column: a double error would 'correct'"
    for a in range(72):
        for b in range(a + 1, 72):
            d = cols[a] ^ cols[b]
            assert d != 0 and (popcount(d) & 1) == 0
    for a in range(72):
        for b in range(a + 1, 72):
            for c in range(b + 1, 72):
                assert (cols[a] ^ cols[b] ^ cols[c]) != 0
    witness = column(1) ^ column(2) ^ column(4) ^ column(7)
    assert witness == 0, hex(witness)

    for payload in (0, MASK32, 0x0123456789ABCDEF):
        cw = encode(payload)
        assert analyse(cw)[0] == 0 and data_of(cw) == payload
        for p in range(1, 73):
            inj = flip_bit(cw, p)
            syn, syn_h, pchk = analyse(inj)
            ce, ue = classify(syn, syn_h, pchk)
            assert ce and not ue and syn == column(p), (p, hex(syn))
            assert (syn_h if syn_h else PAR_POS) == p
            # correcting that position returns exactly the transmitted codeword
            assert flip_bit(inj, (syn_h if syn_h else PAR_POS)) == cw
    zero = encode(0)
    for a in range(1, 73):
        for b in range(a + 1, 73):
            syn, syn_h, pchk = analyse(flip_bit(flip_bit(zero, a), b))
            ce, ue = classify(syn, syn_h, pchk)
            assert ue and not ce, (a, b, hex(syn))


class Core(object):
    """One started beat per call; holds the registered outputs the TB folds."""

    def __init__(self):
        self.done = 0
        self.ce = 0
        self.ue = 0
        self.syndrome = 0
        self.syn_wt = 0
        self.err_pos = 0
        self.code = 0
        self.ce_cnt = 0
        self.ue_cnt = 0
        self.sticky = 0
        self.beats = 0

    def operation(self, mode, code_in):
        if mode:
            syn, syn_h, pchk = analyse(code_in)
        else:
            # the encoder hands its own freshly solved check field to the
            # syndrome network, so an encode beat always self-checks clean
            syn, syn_h, pchk = analyse(encode(data_of(code_in)))
        ce, ue = classify(syn, syn_h, pchk)
        if ce:
            err_pos = syn_h if syn_h else PAR_POS
            out = encode(data_of(flip_bit(code_in, err_pos)))
        else:
            err_pos = 0
            out = code_in if mode else encode(data_of(code_in))
        self.done = 1
        self.ce = 1 if ce else 0
        self.ue = 1 if ue else 0
        self.syndrome = syn if mode else 0
        self.syn_wt = popcount(self.syndrome)
        self.err_pos = err_pos if mode else 0
        self.code = out
        if not mode:
            assert syn == 0 and not ce and not ue
        if ce:
            self.sticky |= 0x1
            if self.ce_cnt < CE_MAX:
                self.ce_cnt += 1
        if ue:
            self.sticky |= 0x2
            if self.ue_cnt < UE_MAX:
                self.ue_cnt += 1
        self.beats += 1
        return self.fold_words()

    def idle(self):
        self.done = 0
        self.beats += 1
        return self.fold_words()

    def fold_words(self):
        return [
            u((self.err_pos << 3) | (self.ce << 2) | (self.ue << 1) | self.done, 32),
            u(self.syndrome, 32),
            u((self.syn_wt << 2) | self.sticky, 32),
            u((self.ce_cnt << 4) | self.ue_cnt, 32),
            u(self.code, 32),
            u(self.code >> 32, 32),
            u((self.code >> 64) & 0xFF, 32),
        ]


def run():
    verify_code_geometry()
    core = Core()
    state = SEED
    words = []
    clean = 0

    for dw in range(NDW):
        if dw == 0:
            payload = 0
        elif dw == 1:
            payload = (1 << 64) - 1
        else:
            state = lcg32(state)
            hi = state
            state = lcg32(state)
            payload = (hi << 32) | state
        words += core.operation(0, payload)
        clean = core.code
        assert data_of(clean) == payload and analyse(clean)[0] == 0
        words += core.operation(1, clean)
        for k in range(NPOS):
            words += core.operation(1, clean ^ (1 << k))
        for _d in range(NDBL):
            state = lcg32(state)
            k = state % NPOS
            q = (k + 1 + ((state >> 8) % (NPOS - 1))) % NPOS
            words += core.operation(1, clean ^ (1 << k) ^ (1 << q))
        words += core.idle()

    for dw in range(NMIX):
        state = lcg32(state)
        payload = (state << 32) | ((~state) & MASK32)
        words += core.operation(0, payload)
        clean = core.code
        if dw == 3:
            words += core.operation(1, clean ^ (1 << 40))
        else:
            words += core.operation(1, clean)

    words += core.idle()
    words += core.idle()

    assert core.sticky == 0x3, bin(core.sticky)
    assert len(words) == 7 * core.beats
    assert core.beats >= 200, core.beats
    words += [u(core.ce_cnt, 32), u(core.ue_cnt, 32), u(core.sticky, 32),
              u(core.beats, 32)]
    return words


def main():
    emit("ips_secded64_ecc", run())


if __name__ == "__main__":
    main()
