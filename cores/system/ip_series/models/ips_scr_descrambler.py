"""Independent golden model for ips_scr_descrambler.

Written from the scrambler / descrambler contract, not from simulation output
(docs/IP_CORE_SOP.md trap T1).  The model is bit-stream algebra over its own
history queues; it never borrows the RTL's mask expression or next-value wires:

    scrambler    y[n] = d[n] ^ y[n-1] ^ y[n-43]      (IIR over its own output)
    link         a[n] = y[n] ^ c[n]                  (c = channel bit error)
    descrambler  r[n] = a[n] ^ a[n-1] ^ a[n-43]       (FIR over what it hears)

so the descrambler polynomial is the delay form of x^43 + x^42 + 1, exactly the
polynomial the scrambler divides by, and on a clean link r[n] == d[n]
identically.  That identity is asserted for every clean, synchronised beat,
which is the "self-synchronising pair never leaves the descrambler output
wrong" property.

Error multiplication is derived, not assumed: one injected bit enters r at lag 0
and at both tap lags, so it produces 1 + #taps = 3 output bit errors at
{t, t+1, t+43} -- 2 of them propagated.  Two injected bits one beat apart share a
tap and cancel mod 2, so they give 4 errors rather than 6; two bits 20 beats
apart give the full bound 2 * 3 = 6.  A receiver that restarts mid-stream is the
same algebra with one virtual error one beat back, so its output is wrong at
relative beats 0 and 42 and provably exact from relative beat 43 on -- the 43
channel bits its line has to flush.  Every one of those statements is asserted
below against the model's own stream.

Accounting the core reports (mirrored here from the definitions):
  chan_err   injected channel bits, saturated at ERR_CAP
  err_tot    descrambler bit errors, saturated at ERR_CAP
  scr_ones   scrambled ones, saturated at ONE_CAP
  burst_tot  bit errors attributed to the most recent injected channel bit (the
             direct one plus the propagated ones), counted while the
             BURST_WIN-beat attribution window is open, reset by the next
             injection
  burst_prop the propagated part of that count: it starts at 0 on an injection
             while burst_tot starts at the direct error, and both then step
             together while the window is open, so burst_prop equals burst_tot
             minus one whenever that direct error was itself an output error
  burst_max / prop_max  running maxima of those two per-event counters
  sync_pos   started beats since the last restart, saturating at 127
  resync_pos the largest sync_pos at which an output was still wrong, i.e. the
             flush bound actually measured (0 right after a restart)
  err_sticky bit0 any channel error, bit1 any output error, bit2 any restart

Stimulus contract shared with sim/tb_ips_scr_descrambler.v (LCG
state = state * 1664525 + 1013904223 mod 2**32 from 0x5C071A7E; rel is the beat
index inside the phase under measurement, 0-based):
    2 idle beats
    64 beats d = 0, clean link
    48 beats d = 1, clean link
    64 beats d = state[0], clean link
    3 events of 48 beats, d = state[3], c = 1 at rel 3
    52 beats d = state[5], c = 1 at rel 3 and rel 4
    70 beats d = state[7], c = 1 at rel 3 and rel 23
    2 events of 52 beats, d = state[11], restart at rel 3 from the transmitter's
      line with bit 0 flipped
    4 idle beats (the clk_en = 0 window between them advances nothing)
then the eight accounting words.

Folding rule -- the same eight 32-bit words per folded beat, MSB byte first, that
the testbench folds, all taken after the beat's clock edge:
    1  {21'd0, scr_state[42:32]}
    2  scr_state[31:0]
    3  {21'd0, desc_state[42:32]}
    4  desc_state[31:0]
    5  {11'd0, win, sync_pos, resync_pos}
    6  {8'd0, chan_err, err_tot, scr_ones}
    7  {16'd0, burst_max, prop_max, burst_tot, burst_prop}
    8  {26'd0, err_sticky, desc_bit, scr_bit, done}
Then once each: {24'd0, chan_err}, {24'd0, err_tot}, {24'd0, scr_ones},
{28'd0, burst_max}, {28'd0, prop_max}, {25'd0, resync_pos}, {29'd0, err_sticky}
and the folded beat total.
"""

from ips_model_common import emit, lcg32, u

WIDTH = 43
MASK43 = (1 << WIDTH) - 1

# The shipped generator polynomial written as LAGS of the scrambled stream, which
# is how the contract states it; bit k of a line register holds lag 1 + k.
LAGS = (1, 43)
TAP_BITS = tuple(lag - 1 for lag in LAGS)
TAP_MASK = sum(1 << b for b in TAP_BITS)
EM_BOUND = 1 + len(TAP_BITS)          # output errors per injected channel bit

SEED = 0x1A7F0C3D5E9
BURST_WIN = 44
ERR_CAP = 0xFF
ONE_CAP = 0xFF
BURST_CAP = 0xF
SYNC_WIN = WIDTH                      # a restarted line flushes in 43 channel bits
CNT_FULL = 0x7F

N_IDL = 2
NA = 64
NB = 48
NC = 64
NEV = 3
ND = 48
NE1 = 52
NE2 = 70
NF = 52
LCSEED = 0x5C071A7E


def seed_history(seed):
    """The virtual bit history a seeded line implies.

    Line bit k holds lag 1 + k, so at beat 1 the line is y[-42] .. y[0] with
    y[-k] = bit k of the seed.  Oldest first: index i is the bit of beat i-WIDTH+1.
    """
    return [(seed >> k) & 1 for k in range(WIDTH)][::-1]


def history_at(queue, beat, lag):
    """The bit `lag` beats before `beat`, read out of an oldest-first queue."""
    return queue[beat - lag + WIDTH - 1]


def line_from(queue, beat):
    """Rebuild the 43-bit line register as it reads DURING `beat`.

    Slot k of the line holds the bit from lag 1 + k, i.e. the bit of beat
    `beat - 1 - k`; after `beat` the same expression evaluated at `beat + 1`.
    """
    value = 0
    for k in range(WIDTH):
        value |= history_at(queue, beat, 1 + k) << k
    return value


class Core(object):
    """Reference model of the scrambler / descrambler pair and its counters."""

    def __init__(self):
        self.yq = seed_history(SEED)          # emitted channel bits
        self.aq = seed_history(SEED)          # bits the receiver actually heard
        self.tx = SEED
        self.rx = SEED
        self.flush = 0                        # beats left with a desynced line
        self.beat_no = 0
        self.done = 0
        self.scr_bit = 0
        self.desc_bit = 0
        self.chan_err = 0
        self.err_tot = 0
        self.scr_ones = 0
        self.burst_tot = 0
        self.burst_prop = 0
        self.burst_max = 0
        self.prop_max = 0
        self.win = 0
        self.sync_pos = 0
        self.resync_pos = 0
        self.sticky = 0
        self.beats = 0
        self.errors = []                      # beat index of every output error
        self.injected = set()                 # beat index of every channel error

    def clean_link(self, n, joined=False):
        """True when nothing among the three bits beat n taps was corrupted: no
        injected channel error at lag 0 or at either tap lag, and no restart
        happening now or still aging out of the line."""
        if joined or self.flush:
            return False
        for beat_no in (n, n - LAGS[0], n - LAGS[1]):
            if beat_no in self.injected:
                return False
        return True

    # ---------------------------------------------------------------- contract
    def beat(self, d, inj=0, restart=False, seed=None):
        """One started beat; returns the eight folded words after its edge."""
        n = self.beat_no + 1
        stale = self.flush > 0
        if inj:
            self.injected.add(n)

        # transmitter: the payload plus its own tapped feedback
        y = d
        for lag in LAGS:
            y ^= history_at(self.yq, n, lag)
        a = y ^ inj                           # the link adds this beat's error

        # receiver: the same taps over the line it is holding right now
        hist = seed if restart else self.rx
        r = a
        for lag in LAGS:
            r ^= (hist >> (lag - 1)) & 1
        out_err = r ^ d

        # ---- cross-checks from the streams, not from the registers
        if restart:
            assert hist == self.tx ^ 1, n         # joined with bit 0 wrong
        elif not stale:
            # a synchronised receiver's line IS the stream it heard, bit for bit
            assert hist == line_from(self.aq, n), n
        if self.clean_link(n, joined=restart):
            # a channel that corrupted none of the three bits this tap reads
            # gives back the payload exactly -- the self-synchronising property
            assert r == d, n

        # ---- advance both lines.  The RTL shifts registers in; the model rebuilds
        # each line from its own bit stream, which is a different formulation of
        # the same contract.
        self.yq.append(y)
        self.aq.append(a)
        self.tx = line_from(self.yq, n + 1)
        self.rx = u((hist << 1) | a, WIDTH)
        if restart:
            self.flush = WIDTH - 1                # the virtual error ages out of
        elif self.flush:                          # bit 42 after 42 more beats
            self.flush -= 1
        self.scr_bit = y
        self.desc_bit = r
        self.done = 1
        self.beat_no = n

        # ---- attribution window: BURST_WIN beats of credit per injected bit
        credited = self.win != 0                  # window open during this beat
        if inj:
            self.burst_tot = out_err              # the direct error
            self.burst_prop = 0                   # propagated ones start next beat
        elif credited and out_err:
            if self.burst_tot < BURST_CAP:
                self.burst_tot += 1
            if self.burst_prop < BURST_CAP:
                self.burst_prop += 1
        self.win = BURST_WIN if inj else (self.win - 1 if self.win else 0)
        self.burst_max = max(self.burst_max, self.burst_tot)
        self.prop_max = max(self.prop_max, self.burst_prop)

        # ---- re-sync measurement
        if restart:
            self.sync_pos = 0
            self.resync_pos = 0
        else:
            if self.sync_pos < CNT_FULL:
                self.sync_pos += 1
            if out_err and self.sync_pos < SYNC_WIN and self.sync_pos > self.resync_pos:
                self.resync_pos = self.sync_pos

        # ---- sticky flags and saturating tallies
        if inj:
            self.sticky |= 0x1
            if self.chan_err < ERR_CAP:
                self.chan_err += 1
        if restart:
            self.sticky |= 0x4
        if out_err:
            self.sticky |= 0x2
            if self.err_tot < ERR_CAP:
                self.err_tot += 1
            self.errors.append(n)
        if y and self.scr_ones < ONE_CAP:
            self.scr_ones += 1

        self.beats += 1
        return self.fold()

    def idle(self):
        """start = 0: every register holds and done drops."""
        self.done = 0
        self.beats += 1
        return self.fold()

    # ----------------------------------------------------------------- folding
    def fold(self):
        return [
            u(self.tx >> 32, 32),
            u(self.tx, 32),
            u(self.rx >> 32, 32),
            u(self.rx, 32),
            u((self.win << 14) | (self.sync_pos << 7) | self.resync_pos, 32),
            u((self.chan_err << 16) | (self.err_tot << 8) | self.scr_ones, 32),
            u((self.burst_max << 12) | (self.prop_max << 8)
              | (self.burst_tot << 4) | self.burst_prop, 32),
            u((self.sticky << 3) | (self.desc_bit << 2) | (self.scr_bit << 1)
              | self.done, 32),
        ]


def errors_since(core, base):
    """Output-error beat indices of one phase as the testbench numbers them: the
    phase's first beat is relative beat 0, so `base` is the last beat before it."""
    return [e - base - 1 for e in core.errors if e > base]


def run():
    core = Core()
    words = []
    state = LCSEED

    # polynomial facts the measured bounds are read against
    assert TAP_BITS == (0, WIDTH - 1), TAP_BITS
    assert TAP_MASK == (1 << 0) | (1 << (WIDTH - 1))
    assert EM_BOUND == 3
    assert seed_history(SEED)[WIDTH - 1] == SEED & 1        # index 42 is y[0]

    for _i in range(N_IDL):
        words += core.idle()

    # ---- all-zero payload: an additive scrambler still emits a random run
    base = core.beat_no
    seen = set()
    for k in range(NA):
        words += core.beat(0)
        assert core.desc_bit == 0, k                      # clean link round trips
        assert core.tx not in seen and core.tx != 0, k    # no short cycle, no lock
        seen.add(core.tx)
    ones = sum(core.yq[WIDTH:WIDTH + NA])
    assert 0 < ones < NA, ones
    assert errors_since(core, base) == []
    assert core.chan_err == 0 and core.err_tot == 0

    # ---- all-ones payload round trips too
    base = core.beat_no
    for k in range(NB):
        words += core.beat(1)
        assert core.desc_bit == 1, k
    ones_b = sum(core.yq[WIDTH + NA:WIDTH + NA + NB])
    assert 0 < ones_b < NB, ones_b
    assert errors_since(core, base) == []

    # ---- random payload, clean link
    base = core.beat_no
    for _c in range(NC):
        state = lcg32(state)
        words += core.beat(state & 1)
    assert errors_since(core, base) == []

    # ---- one injected channel bit: EM_BOUND errors, EM_BOUND - 1 propagated
    for _e in range(NEV):
        base = core.beat_no
        for p in range(ND):
            state = lcg32(state)
            words += core.beat((state >> 3) & 1, 1 if p == 3 else 0)
            if p == ND - 1:
                assert core.burst_tot == EM_BOUND, core.burst_tot
                assert core.burst_prop == EM_BOUND - 1, core.burst_prop
        assert errors_since(core, base) == [3, 3 + LAGS[0], 3 + LAGS[1]]
        assert core.burst_max == EM_BOUND
        assert core.prop_max == EM_BOUND - 1

    # ---- two adjacent injections share a tap and cancel mod 2
    base = core.beat_no
    for p in range(NE1):
        state = lcg32(state)
        words += core.beat((state >> 5) & 1, 1 if p in (3, 4) else 0)
    assert errors_since(core, base) == [3, 5, 3 + LAGS[1], 4 + LAGS[1]]
    # The window the rel-4 injection opens stays open through rel 47, so it also
    # collects rel 46 -- the propagated error of the PREVIOUS injection.  That
    # window therefore attributes 3 output errors, and because the direct error of
    # rel 4 cancelled mod 2 all three of them are counted as propagated.
    assert (core.burst_tot, core.burst_prop) == (EM_BOUND, EM_BOUND), (
        core.burst_tot, core.burst_prop)
    assert core.burst_max == EM_BOUND and core.prop_max == EM_BOUND

    # ---- two injections 20 beats apart: the full multiplication bound
    base = core.beat_no
    for p in range(NE2):
        state = lcg32(state)
        words += core.beat((state >> 7) & 1, 1 if p in (3, 23) else 0)
    assert errors_since(core, base) == [3, 4, 23, 24, 46, 66]
    # rel 23's own 44-beat window covers rel 24 (propagated), rel 46 (the rel-3
    # error at lag 43) and rel 66 (its own lag-43 error): 4 attributed, 3 of them
    # not the direct one.  This is the widest window the sweep produces.
    assert (core.burst_tot, core.burst_prop) == (EM_BOUND + 1, EM_BOUND), (
        core.burst_tot, core.burst_prop)
    assert core.burst_max == EM_BOUND + 1 and core.prop_max == EM_BOUND

    # ---- receiver joins mid-stream: wrong twice, exact from relative beat 43 on
    for _g in range(2):
        base = core.beat_no
        for p in range(NF):
            state = lcg32(state)
            restart = (p == 3)
            seed = (core.tx ^ 1) if restart else None
            words += core.beat((state >> 11) & 1, 0, restart, seed)
            if p == NF - 2:
                assert core.resync_pos == SYNC_WIN - 1, core.resync_pos
        assert errors_since(core, base) == [3, 3 + WIDTH - 1]
        assert core.resync_pos == WIDTH - 1
        assert core.flush == 0                      # line is the stream again

    for _h in range(N_IDL):
        words += core.idle()
    # the clk_en = 0 window advances no register and is not folded
    for _i in range(N_IDL):
        words += core.idle()

    # ---- accounting the testbench also checks structurally
    injected = NEV + 2 + 2
    assert core.chan_err == injected, core.chan_err
    assert core.err_tot == len(core.errors), core.err_tot
    assert len(core.errors) == NEV * EM_BOUND + 4 + 6 + 2 * 2, len(core.errors)
    assert core.scr_ones == ONE_CAP, core.scr_ones            # saturated by design
    # burst_max / prop_max are MEASUREMENTS over the attribution window a burst
    # counter has, not restatements of the bound: the isolated single-injection
    # events above prove the bound itself is 3 output errors of which 2 are
    # propagated, and the two multi-injection phases widen one counter's window to
    # 4 / 3 because an earlier error's lag-43 copy lands inside it.
    assert core.burst_max == EM_BOUND + 1, core.burst_max
    assert core.prop_max == EM_BOUND, core.prop_max
    assert core.sticky == 0x7, bin(core.sticky)
    expected_beats = (N_IDL + NA + NB + NC + NEV * ND + NE1 + NE2 + 2 * NF
                      + 2 * N_IDL)
    assert core.beats == expected_beats, (core.beats, expected_beats)
    assert 200 <= core.beats <= 600, core.beats
    assert len(words) == 8 * core.beats

    words += [u(core.chan_err, 32), u(core.err_tot, 32), u(core.scr_ones, 32),
              u(core.burst_max, 32), u(core.prop_max, 32),
              u(core.resync_pos, 32), u(core.sticky, 32), u(core.beats, 32)]
    return words


def main():
    emit("ips_scr_descrambler", run())


if __name__ == "__main__":
    main()
