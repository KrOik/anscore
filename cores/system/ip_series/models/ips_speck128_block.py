"""Independent golden model for ips_speck128_block.

Two things are implemented here, and neither of them was read out of the RTL or
out of simulation output (docs/IP_CORE_SOP.md trap T1):

1. SPECK128/128 exactly as published in the NSA "SIMON and SPECK Implementation
   Guide" version 1.1 (https://nsacyber.github.io/simon-speck/), sections 6, 7
   and 16: the round function
       ER64(x, y, k):  x = ROTR64(x, 8); x = x + y; x = x ^ k;
                       y = ROTL64(y, 3); y = y ^ x
   and BOTH published ways of driving it: the table version of section 6
   (Speck128128KeySchedule, 31 fused ER64 steps with rk[0] = K[0], then
   Speck128128Encrypt), and section 7's on-the-fly expansion, which is the form the
   core implements -- one ER64 for the block plus one ER64 for the schedule per
   round, so round i uses the schedule word A that step i-1 produced and no rk[]
   entry is ever stored (``Speck128128EncryptExpandKey``):
       B = K[1]; A = K[0]; Ct = Pt;
       for (i = 0; i < 32; i++) { ER64(Ct[1], Ct[0], A); ER64(B, A, i); }
   32 rounds is SPECK128/128's published count (the guide's 128/192 and 128/256 use
   33 and 34), and the schedule needs 31 steps for 32 block rounds, which is what
   sched_cnt reports.
   The guide's published test vector is asserted below as an independent
   constant, never copied from the core:
       K[1],K[0] = 0f0e0d0c0b0a0908, 0706050403020100
       Pt[1],Pt[0] = 6c61766975716520, 7469206564616d20 ("lavique tidam" style
                      little-endian word bytes)
       Ct[1],Ct[0] = a65d985179783265, 7860fedf5c570d18
       ct bytes (guide order) 18 0d 57 5c df fe 60 78 65 32 78 79 51 98 5d a6
   The guide's rk[0..31] table and its 32 printed intermediate (Pt[1],Pt[0]) states
   are reproduced as PUB_RK / PUB_TRACE below and asserted against, so the cipher in
   this file is pinned to published numbers rather than to anything the core said.

2. A cycle model of the core's documented load/run protocol, used only to replay
   the beat schedule below.  Its rounds call the same published ``er64`` from (1)
   instead of a re-derived equation, and every clean operation is cross-checked
   round by round against (1) -- so the protocol replay cannot silently drift
   away from the cipher the guide defines.

Stimulus contract shared with sim/tb_ips_speck128_block.v:
    state = state * 1664525 + 1013904223 (mod 2**32), from 0x5E0C1280, advanced
      once at the head of every operation
    key word i  = state ^ (0xa0000000 + i)   (test-only LCG material)
    block word i = state ^ (0x50000000 + i)
    the published vector words and the chained vector words are guide constants
    ten operations, exactly the beat sequence in replay(), including all
    malformed-loading operations

Folding rule (identical to the testbench): every beat contributes nine 32-bit
words, MSB byte first into FNV-1a, narrower fields zero-extended on the left:
    1..3   ct_x[31:0], ct_x[63:32], ct_x[71:64] zero-extended (ct_x = high half,
    4..6   always WORD_BITS wide at the shipped geometry, so the third word is 0)
           ct_y[31:0], ct_y[63:32], ct_y[71:64] zero-extended
    7      {key_cnt[3:0], blk_cnt[3:0]}
    8      {round_cnt[7:0], sched_cnt[7:0]}
    9      {err_code[2:0], done, busy, err}
After the last beat the same nine words are folded once more, then a seven-word
configuration stamp: 32'd9, WORD_BITS, ROUNDS, LOAD_WORDS, IDX_BITS, ROT_X,
ROT_Y -- which is what makes every parameter reach the digest.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, u

NAME = 'ips_speck128_block'

SEED = 0x5E0C1280
WORD_BITS = 64
ROUNDS = 32
LOAD_WORDS = 4
IDX_BITS = 6
ROT_X = 8
ROT_Y = 3
BUS_BITS = 32

MASK64 = (1 << WORD_BITS) - 1
MASK128 = (1 << (LOAD_WORDS * BUS_BITS)) - 1

ERR_NONE, ERR_KWORD, ERR_BWORD, ERR_MIXED, ERR_SHORT, ERR_LATE = 0, 1, 2, 3, 4, 5

# ---- published test-only vectors (Implementation Guide 1.1, section 16) ----------
PUB_KW = (0x0f0e0d0c, 0x0b0a0908, 0x07060504, 0x03020100)   # K[1] then K[0]
PUB_BW = (0x6c617669, 0x75716520, 0x74692065, 0x64616d20)   # Pt[1] then Pt[0]
PUB_CT = (0xa65d9851, 0x79783265, 0x7860fedf, 0x5c570d18)   # Ct[1] then Ct[0]
# the same published ciphertext re-encrypted under the same published key
CHAIN_BW = PUB_CT
KAT_KEY = (0x0f0e0d0c0b0a0908, 0x0706050403020100)          # (K[1], K[0])
KAT_PT = (0x6c61766975716520, 0x7469206564616d20)           # (Pt[1], Pt[0])
KAT_CT = (0xa65d985179783265, 0x7860fedf5c570d18)           # (Ct[1], Ct[0])
KAT_CT_BYTES = bytes([0x18, 0x0d, 0x57, 0x5c, 0xdf, 0xfe, 0x60, 0x78,
                      0x65, 0x32, 0x78, 0x79, 0x51, 0x98, 0x5d, 0xa6])
# rk[0..31] of the published vector, guide section 16
PUB_RK = (
    0x0706050403020100, 0x37253b31171d0309, 0xf91d89cc90c4085c, 0xc6b1f07852cc7689,
    0x014fcdf4f9c2d6f0, 0xb5fae1e4fe24cfd6, 0xa36d6954b0737cfe, 0xf511691ea02f35f3,
    0x5374abb75a2b455d, 0x8dd5f6204ddcb2a5, 0xb243d7c9869cac18, 0x753e7a7c6660459e,
    0x78d648a3a5b0e63b, 0x87152b23cbc0a8d2, 0xa8ff8b8c54a3b6f2, 0x4873be3c43b3ea79,
    0x771ebffcbf05cb13, 0xe8a6bcaf25863d20, 0xe6c2ea8b5c520c93, 0x4d71b5c1ac5214f5,
    0xdc60b2ae253070dc, 0xb01d0abbe1fb9741, 0xd7987684a318b54a, 0xa22c5282e600d319,
    0xe029d67ebdf90048, 0x67559234c84efdbf, 0x65173cf0cb01695c, 0x24cf1f1879819519,
    0x38a36ed2dbafb72a, 0xded93cfe31bae304, 0xc53d18b91770b265, 0x2199c870db8ec93f,
)
# (Pt[1], Pt[0]) after rounds 1..32 of the published vector, guide section 16
PUB_TRACE = (
    (0x93d384dfced4df85, 0x309a87f4eddfb686), (0x810b6048dab3886c, 0x05df5fefb44e3c5d),
    (0x8b7de2836dece7b9, 0xa5871dfecf9d0551), (0x99a36b9901c684b1, 0xb59b846f7d2eae3c),
    (0x667aea2feff2a230, 0xcaa6c9540687d3d5), (0x4ef7a5dac85309a1, 0x1bc1ef7afc6d970f),
    (0x1e7d8e74674696e6, 0xc072f5a3842a2e9e), (0x53801a2f58be40c7, 0x5017b73379ef3431),
    (0x441f9cfaf36cb72c, 0xc4a225613c1516a6), (0x7d33b2de7ad431f8, 0x582299d79a7c84ce),
    (0xe2dc1a43fe6bf4e7, 0x23c8d4ff2d8fd295), (0x7e95cb6517ee7b17, 0x60d36c9c7b90efbe),
    (0x00844ac445183802, 0x061f2e27999f45f1), (0x8f0a99519624f6fb, 0xbff3e86d5aded973),
    (0x137d788af8d7489b, 0xece23be02e218306), (0xcf860764faa9b037, 0xa897d8658ba5a800),
    (0x9779e1904fa59aa3, 0xd3c722bc1288daa6), (0x9ff82032875ebd60, 0x01c135d213186856),
    (0x84a3c77919cdcb80, 0x8aaa69e9810e8930), (0x465eb871567a420e, 0x130df73d5e0e0b8a),
    (0xfd34e75bea54f510, 0x655b5eb11a24a940), (0xc645992397f56974, 0xec9f6cab46d02377),
    (0xb6fdc4c0c970adaa, 0xd206a19afff1b615), (0xde91cddd26bbf5db, 0x4ea4c10ad9364575),
    (0xcaaa84a60ba40122, 0xbf8c8cf0c2162a88), (0x8502a541a06f3336, 0x7966c2c7b0de6773),
    (0xcafcf99c397fbffa, 0x01caefa1bf8c8461), (0xd85af38322479139, 0xd60d8e8ede23b231),
    (0x37468750baea4ee8, 0x872af3264bf7df66), (0xb1bb0553ad082ab0, 0x88ec9c61f2b6d184),
    (0xfca34fde51136bcb, 0xbbc7acd1c4a5e7ef), (0xa65d985179783265, 0x7860fedf5c570d18),
)


def rotl(value, amount, bits=WORD_BITS):
    """ROTL64 from the guide."""
    m = (1 << bits) - 1
    a = amount % bits
    return ((value << a) | (value >> (bits - a))) & m


def rotr(value, amount, bits=WORD_BITS):
    """ROTR64 from the guide."""
    m = (1 << bits) - 1
    a = amount % bits
    return ((value >> a) | (value << (bits - a))) & m


def er64(x, y, k):
    """The guide's SPECK128 round function on two 64-bit words, written exactly as
    the guide states it (rotate, add, xor; rotate, xor).  Returns (x, y)."""
    m = MASK64
    x = rotr(x, ROT_X)
    x = (x + y) & m
    x ^= k
    y = rotl(y, ROT_Y)
    y ^= x
    return x, y


def speck128128_encrypt(Pt, K, per_round=False):
    """Speck128/128 encryption, the guide's section 7 on-the-fly expand-key code.

    ``Pt = (Pt[1], Pt[0])`` and ``K = (K[1], K[0])``, the guide's array layout.
    Returns (Ct[1], Ct[0]); with per_round it also returns the list of
    (Ct[1], Ct[0]) pairs after each round.
    """
    b, a = K
    x, y = Pt
    trace = []
    for i in range(ROUNDS):
        x, y = er64(x, y, a)
        if per_round:
            trace.append((x, y))
        b, a = er64(b, a, i)
    if per_round:
        return (x, y), trace
    return x, y


def speck128128_key_schedule(K):
    """The guide's Speck128128KeySchedule, transcribed literally: 31 fused ER64
    steps, rk[0] = K[0], rk[i] = the A word that step i-1 produced."""
    b, a = K
    rk = []
    i = 0
    while i < 31:
        rk.append(a)
        b, a = er64(b, a, i)
        i += 1
    rk.append(a)
    return rk


def speck128128_encrypt_rk(Pt, rk):
    """The guide's Speck128128Encrypt: 32 ER64 rounds driven from the rk table."""
    x, y = Pt
    trace = []
    for i in range(32):
        x, y = er64(x, y, rk[i])
        trace.append((x, y))
    return x, y, trace


def pack64(hi_word, lo_word):
    """Two 32-bit stream words, most significant first, into one 64-bit guide word."""
    return u((u(hi_word, 32) << 32) | u(lo_word, 32), WORD_BITS)


class Dut(object):
    """Cycle model of the core's documented protocol: one enabled posedge per step().

    Registers are 128-bit, addressed as (high half, low half) = (x side, y side) for
    the block and (B, A) for the schedule, which is the guide's own layout.
    """

    def __init__(self):
        self.key_reg = 0
        self.blk_reg = 0
        self.round_cnt = 0
        self.sched_cnt = 0
        self.key_cnt = 0
        self.blk_cnt = 0
        self.err_code = ERR_NONE
        self.done = 0
        self.busy = 0

    # outputs ---------------------------------------------------------------
    @property
    def ct_x(self):
        return self.blk_reg >> WORD_BITS

    @property
    def ct_y(self):
        return self.blk_reg & MASK64

    @property
    def err(self):
        return 1 if self.err_code != ERR_NONE else 0

    def _a(self):
        return self.key_reg & MASK64

    def _b(self):
        return self.key_reg >> WORD_BITS

    # one clock -------------------------------------------------------------
    def step(self, start, run_req, kw_valid, bw_valid, ld_word):
        busy, done = self.busy, self.done
        key_cnt, blk_cnt = self.key_cnt, self.blk_cnt
        err_code = self.err_code
        round_cnt, sched_cnt = self.round_cnt, self.sched_cnt
        blk, key = self.blk_reg, self.key_reg

        accepting = not (busy or done or start)
        mix_evt = bool(kw_valid and bw_valid and accepting)
        kw_evt = bool(kw_valid and not bw_valid and accepting)
        bw_evt = bool(bw_valid and not kw_valid and accepting)
        kw_ovf = bool(kw_evt and key_cnt >= LOAD_WORDS)
        kw_add = bool(kw_evt and key_cnt < LOAD_WORDS)
        bw_ovf = bool(bw_evt and blk_cnt >= LOAD_WORDS)
        bw_add = bool(bw_evt and blk_cnt < LOAD_WORDS)
        late_evt = bool((kw_valid or bw_valid or run_req) and (busy or done))
        run_evt = bool(run_req and not busy and not done and not start)
        run_bad = bool(run_evt and (err_code != ERR_NONE or key_cnt != LOAD_WORDS
                                    or blk_cnt != LOAD_WORDS))
        run_go = bool(run_evt and not run_bad)
        sched_now = bool(busy and round_cnt < ROUNDS - 1)
        round_last = bool(busy and round_cnt == ROUNDS - 1)

        if mix_evt:
            new_err = ERR_MIXED
        elif kw_ovf:
            new_err = ERR_KWORD
        elif bw_ovf:
            new_err = ERR_BWORD
        elif late_evt:
            new_err = ERR_LATE
        elif run_bad:
            new_err = ERR_SHORT
        else:
            new_err = ERR_NONE
        latch_err = bool(new_err != ERR_NONE and err_code == ERR_NONE)

        if start:
            self.round_cnt = 0
            self.sched_cnt = 0
            self.key_cnt = 0
            self.blk_cnt = 0
            self.err_code = ERR_LATE if (kw_valid or bw_valid or run_req) else ERR_NONE
            self.done = 0
            self.busy = 0
            return

        if latch_err:
            self.err_code = new_err

        if kw_add:
            self.key_reg = u((key << BUS_BITS) | u(ld_word, BUS_BITS), 128)
            self.key_cnt = u(key_cnt + 1, 4)
        if bw_add:
            self.blk_reg = u((blk << BUS_BITS) | u(ld_word, BUS_BITS), 128)
            self.blk_cnt = u(blk_cnt + 1, 4)

        if busy:
            x, y = er64(blk >> WORD_BITS, blk & MASK64, key & MASK64)
            self.blk_reg = u((x << WORD_BITS) | y, 128)
            self.round_cnt = u(round_cnt + 1, IDX_BITS)
            if sched_now:
                b, a = er64(key >> WORD_BITS, key & MASK64, sched_cnt)
                self.key_reg = u((b << WORD_BITS) | a, 128)
                self.sched_cnt = u(sched_cnt + 1, IDX_BITS)

        if run_go:
            self.busy = 1
        elif run_bad:
            self.done = 1
        elif round_last:
            self.busy = 0
            self.done = 1

    # folding ----------------------------------------------------------------
    def fold_words(self):
        cx, cy = self.ct_x, self.ct_y
        return [
            u(cx, 32), u(cx >> 32, 32), 0,
            u(cy, 32), u(cy >> 32, 32), 0,
            u((self.key_cnt << 4) | self.blk_cnt, 32),
            u((self.round_cnt << 8) | self.sched_cnt, 32),
            u((self.err_code << 3) | (self.done << 2) | (self.busy << 1) | self.err, 32),
        ]


# ---- test-only stimulus words, same generators as the testbench ------------------
def pub_kw(i):
    return PUB_KW[i]


def pub_bw(i):
    return PUB_BW[i]


def chan_bw(i):
    return CHAIN_BW[i]


def lcg_kw(state, i):
    return u(state ^ u(0xa0000000 + i, 32), 32)


def lcg_bw(state, i):
    return u(state ^ u(0x50000000 + i, 32), 32)


def pattern_kw(i):
    return 0xffffffff if i < 2 else 0x00000000


class Replay(object):
    """Replays the testbench beat schedule, folding the shared nine-word record."""

    def __init__(self):
        self.dut = Dut()
        self.words = []
        self.beats = 0
        self.state = SEED
        self.expect = None      # published per-round (x, y) list, or None
        self.round_seen = 0

    def beat(self, start, run_req, kw_valid, bw_valid, ld_word, check_round=True):
        self.dut.step(start, run_req, kw_valid, bw_valid, u(ld_word, 32))
        self.beats += 1
        self.words.extend(self.dut.fold_words())
        if check_round and self.expect is not None:
            # the engine runs exactly one round per enabled beat while busy, so every
            # round boundary must land on the published reference trace
            while self.round_seen < self.dut.round_cnt:
                want = self.expect[self.round_seen]
                got = (self.dut.ct_x, self.dut.ct_y)
                if got != want:
                    raise AssertionError('round %d: replay %016x,%016x != published '
                                         'reference %016x,%016x'
                                         % (self.round_seen + 1, got[0], got[1],
                                            want[0], want[1]))
                self.round_seen += 1

    # operation helpers ------------------------------------------------------
    def load_streams(self, kws, bws):
        """start beat, then the key and block streams.  Arms no expectation yet."""
        self.expect = None
        self.round_seen = 0
        self.beat(1, 0, 0, 0, 0, check_round=False)
        for w in kws:
            self.beat(0, 0, 1, 0, w, check_round=False)
        for w in bws:
            self.beat(0, 0, 0, 1, w, check_round=False)

    def run(self, expect_trace=True):
        """run_req beat; the engine then needs ROUNDS further beats."""
        self.expect = None
        self.round_seen = 0
        self.beat(0, 1, 0, 0, 0, check_round=False)
        if expect_trace:
            d = self.dut
            _, trace = speck128128_encrypt((d.blk_reg >> WORD_BITS, d.blk_reg & MASK64),
                                          (d.key_reg >> WORD_BITS, d.key_reg & MASK64),
                                          per_round=True)
            self.expect = trace

    def rounds(self, n, extra=None):
        for r in range(1, n + 1):
            if extra is not None and r == extra[0]:
                st, rn, kv, bv, wd = extra[1]
                self.beat(st, rn, kv, bv, wd)
            else:
                self.beat(0, 0, 0, 0, 0)

    def idle(self, n):
        for _ in range(n):
            self.beat(0, 0, 0, 0, 0, check_round=False)

    def stamp(self):
        self.words.extend(self.dut.fold_words())
        self.words.extend([9, WORD_BITS, ROUNDS, LOAD_WORDS, IDX_BITS, ROT_X, ROT_Y])


def check_published_vector():
    """Everything below is checked against the guide's printed numbers only."""
    rk = speck128128_key_schedule(KAT_KEY)
    assert len(rk) == 32
    assert tuple(rk) == PUB_RK, 'published round-key table mismatch'

    ct1, ct0, rk_trace = speck128128_encrypt_rk(KAT_PT, rk)
    assert (ct1, ct0) == KAT_CT, 'published SPECK128/128 vector mismatch'
    assert tuple(rk_trace) == PUB_TRACE, 'rk-driven trace != published states'

    onthefly = speck128128_encrypt(KAT_PT, KAT_KEY)
    assert onthefly == KAT_CT, 'on-the-fly schedule disagrees with the rk table'

    _, trace = speck128128_encrypt(KAT_PT, KAT_KEY, per_round=True)
    assert len(trace) == ROUNDS
    assert tuple(trace) == PUB_TRACE, 'published round-by-round states mismatch'

    # the guide's byte order: Words64ToBytes emits Ct[0] first, LSB first
    got = KAT_CT[1].to_bytes(8, 'little') + KAT_CT[0].to_bytes(8, 'little')
    assert got == KAT_CT_BYTES, 'published ciphertext byte order mismatch'


def replay():
    """The ten operations of sim/tb_ips_speck128_block.v, beat for beat."""
    rep = Replay()
    d = rep.dut
    lw = LOAD_WORDS

    # ---- operation 0: the published vector, round by round --------------------
    rep.state = lcg32(rep.state)
    rep.load_streams([pub_kw(i) for i in range(lw)], [pub_bw(i) for i in range(lw)])
    assert (d.key_reg >> WORD_BITS, d.key_reg & MASK64) == KAT_KEY
    assert (d.blk_reg >> WORD_BITS, d.blk_reg & MASK64) == KAT_PT
    rep.run()
    rep.rounds(ROUNDS)
    rep.idle(8)
    assert (d.ct_x, d.ct_y) == KAT_CT, 'core did not reach the published ciphertext'
    assert (d.err_code, d.done, d.busy) == (ERR_NONE, 1, 0)

    # ---- operation 1: chain -- re-encrypt the published ciphertext ------------
    rep.state = lcg32(rep.state)
    rep.load_streams([pub_kw(i) for i in range(lw)], [chan_bw(i) for i in range(lw)])
    rep.run()
    rep.rounds(ROUNDS)
    rep.idle(8)
    assert (d.ct_x, d.ct_y) != KAT_CT

    # ---- operation 2: one key word too many -> ERR_KWORD, no round runs -------
    rep.state = lcg32(rep.state)
    s = rep.state
    rep.load_streams([lcg_kw(s, i) for i in range(lw)], [])
    rep.beat(0, 0, 1, 0, lcg_kw(s, lw), check_round=False)
    for i in range(lw):
        rep.beat(0, 0, 0, 1, lcg_bw(s, i), check_round=False)
    rep.beat(0, 1, 0, 0, 0, check_round=False)
    assert d.err_code == ERR_KWORD and d.done == 1 and d.round_cnt == 0
    rep.idle(4)

    # ---- operation 2b: one block word too many -> ERR_BWORD -------------------
    rep.state = lcg32(rep.state)
    s = rep.state
    rep.load_streams([lcg_kw(s, i) for i in range(lw)],
                     [lcg_bw(s, i) for i in range(lw)])
    rep.beat(0, 0, 0, 1, lcg_bw(s, lw), check_round=False)
    rep.beat(0, 1, 0, 0, 0, check_round=False)
    assert d.err_code == ERR_BWORD and d.done == 1 and d.round_cnt == 0
    rep.idle(4)

    # ---- operation 3: key and block in one beat -> ERR_MIXED, nothing accepted
    rep.state = lcg32(rep.state)
    s = rep.state
    rep.beat(1, 0, 0, 0, 0, check_round=False)
    rep.beat(0, 0, 1, 1, lcg_kw(s, 0), check_round=False)
    assert d.err_code == ERR_MIXED and d.key_cnt == 0 and d.blk_cnt == 0
    for i in range(lw):
        rep.beat(0, 0, 1, 0, lcg_kw(s, i), check_round=False)
    for i in range(lw):
        rep.beat(0, 0, 0, 1, lcg_bw(s, i), check_round=False)
    rep.beat(0, 1, 0, 0, 0, check_round=False)
    assert d.err_code == ERR_MIXED and d.done == 1 and d.round_cnt == 0
    rep.idle(4)

    # ---- operation 4: run before the streams are complete -> ERR_SHORT -------
    rep.state = lcg32(rep.state)
    s = rep.state
    rep.beat(1, 0, 0, 0, 0, check_round=False)
    for i in range(lw - 1):
        rep.beat(0, 0, 1, 0, lcg_kw(s, i), check_round=False)
    for i in range(lw - 1):
        rep.beat(0, 0, 0, 1, lcg_bw(s, i), check_round=False)
    rep.beat(0, 1, 0, 0, 0, check_round=False)
    assert d.err_code == ERR_SHORT and d.done == 1 and d.round_cnt == 0
    rep.idle(4)

    # ---- operation 5: load while running -> ERR_LATE, the round is not derailed
    rep.state = lcg32(rep.state)
    s = rep.state
    rep.load_streams([pub_kw(i) for i in range(lw)], [pub_bw(i) for i in range(lw)])
    rep.run()
    rep.rounds(ROUNDS, extra=(ROUNDS // 2, (0, 0, 1, 0, lcg_kw(s, ROUNDS // 2))))
    assert d.err_code == ERR_LATE and d.done == 1
    assert (d.ct_x, d.ct_y) == KAT_CT, 'a refused load derailed the datapath'
    rep.idle(6)

    # ---- operation 6: load after the block finished -> ERR_LATE, result intact
    rep.state = lcg32(rep.state)
    s = rep.state
    rep.load_streams([pub_kw(i) for i in range(lw)], [pub_bw(i) for i in range(lw)])
    rep.run()
    rep.rounds(ROUNDS)
    assert (d.ct_x, d.ct_y) == KAT_CT
    rep.beat(0, 0, 0, 1, lcg_bw(s, 0), check_round=False)
    assert d.err_code == ERR_LATE and (d.ct_x, d.ct_y) == KAT_CT
    rep.idle(4)

    # ---- operation 7: load coincident with start -> ERR_LATE, streams reopen --
    rep.state = lcg32(rep.state)
    s = rep.state
    rep.beat(1, 0, 1, 0, lcg_kw(s, 0), check_round=False)
    assert d.err_code == ERR_LATE and d.key_cnt == 0 and d.blk_cnt == 0
    for i in range(lw):
        rep.beat(0, 0, 1, 0, lcg_kw(s, i), check_round=False)
    for i in range(lw):
        rep.beat(0, 0, 0, 1, lcg_bw(s, i), check_round=False)
    rep.beat(0, 1, 0, 0, 0, check_round=False)
    assert d.err_code == ERR_LATE and d.done == 1 and d.round_cnt == 0
    rep.idle(4)

    # ---- operation 8: test-only all-ones / all-zero key, LCG plaintext ---------
    rep.state = lcg32(rep.state)
    s = rep.state
    rep.load_streams([pattern_kw(i) for i in range(lw)],
                     [lcg_bw(s, i) for i in range(lw)])
    rep.run()
    rep.rounds(ROUNDS)
    assert d.done == 1 and d.err_code == ERR_NONE
    rep.idle(8)

    # ---- tail: two quiesced beats, then the final record and the stamp --------
    rep.idle(2)
    rep.stamp()
    return rep


def main():
    check_published_vector()
    rep = replay()
    assert rep.beats == 318, 'beat schedule drifted from the testbench: %d' % rep.beats
    emit(NAME, rep.words)


if __name__ == '__main__':
    main()
