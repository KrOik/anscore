"""Audio / multimedia fixed-point kernels for the enabled-ready-valid interface.

Family reference for the accelerator catalog: every core here is a real
signal-processing block (biquads, CIC, fractional-delay interpolation,
Goertzel, Karplus-Strong, sigma-delta, envelope, companded TDM) computed in
small fixed-point formats.

Arithmetic rule for this family, and the reason it is a rule rather than a
style preference: on GW5A the fabric `$mul` primitive is unsigned, so any
operand with the top design bit set is silently corrupted.  These kernels
therefore contain no `*` operator at all.  Every "multiply" is a hardwired
sum of arithmetic left shifts by a coefficient that was precomputed offline in
Q14 and then decomposed into signed powers of two.  The Python model below may
use `*` because it only ever names the same integer the shift list produces.

Body vocabulary (declared by the template, reset each evaluation):
    r x                       result/aux registers, 32 bit
    f                         fault flag
    temp mask pa pb pc ph pl  32-bit unsigned temporaries
    ext                       33-bit unsigned (carry capture)
    wide wide2                64-bit unsigned
    swide swide2              64-bit signed
    sa sb sc                  $signed(a), $signed(b), $signed(c)
    data                      {a,b,c} as one 96-bit word
    i j idx lane sh           integers
    state_r state_n           256-bit state; only accepted beats commit it

Conventions shared by every core in this family:
  * `c[31]` is the restart strobe for stateful cores: it zeroes the state
    before the current beat is processed, never after.
  * Non-restart, non-selector control bits are reserved.  A beat that sets a
    reserved bit is a malformed control word: result=aux=0, fault=1 and the
    state is zeroed, so a bad frame cannot smear into the next one.
  * Output registers carry the sign-extended value of the narrow result, so a
    negative s12 output reads as 0xFFFFFxxx.
"""
from random import Random

FAMILY = 'audio'
MASK = (1 << 32) - 1
PENDING = 'r=0; x=0; f=0;'

CORES = []
MODELS = {}
GENS = {}


def core(name, spec, body, advantage, lanes, decl='', stateful=False,
         faultless=False, **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body, decl=decl,
                      advantage=advantage, lanes=lanes, stateful=stateful,
                      faultless=faultless, **kwargs))


def model(name):
    def wrap(fn):
        MODELS[name] = fn
        return fn
    return wrap


def gen(name):
    def wrap(fn):
        GENS[name] = fn
        return fn
    return wrap


def step(name, a, b, c, state=0):
    fn = MODELS.get(name)
    if fn is None:
        raise ValueError(f'no audio model for {name}')
    r, x, f, new_state = fn(a, b, c, state)
    return r & MASK, x & MASK, int(bool(f)), new_state


def pad(rows, count, name):
    """Top a hand-built board set up with seeded rows so the count is honest."""
    rng = Random(0xA0D10 + sum(name.encode()))
    while len(rows) < count:
        rows.append((rng.getrandbits(32) & 0xfff, rng.getrandbits(8),
                     rng.getrandbits(2)))
    return rows[:count]


def s_bits(value, width):
    value &= (1 << width) - 1
    return value - (1 << width) if value >> (width - 1) else value


def s12(value):
    return s_bits(value, 12)


def s16(value):
    return s_bits(value, 16)


def field(state, index, width):
    """Signed field `index` of `width` bits, packed LSB-first into the state."""
    return s_bits(state >> (width * index), width)


def clamp(value, low, high):
    return low if value < low else (high if value > high else value)


def tri(n, peak=2047):
    """Bipolar full-range triangle: +peak down to -peak, then back up."""
    half = max(2, n // 2)
    rest = max(2, n - half)
    out = [peak - (2 * peak * i) // (half - 1) for i in range(half)]
    out += [-peak + (2 * peak * i) // (rest - 1) for i in range(rest)]
    return [clamp(v, -peak, peak) for v in out][:max(2, n)]


def ramp(n, span=4096, stride=137):
    """`n` distinct raw 12-bit patterns; stride odd => full period, no repeats."""
    return [(i * stride) & (span - 1) for i in range(n)]


def vectors(name, count=320):
    fn = GENS.get(name)
    if fn is None:
        raise ValueError(f'no audio vector source for {name}')
    return pad(fn(count), count, name)


# --------------------------------------------------------------------------
# 1. biquad_df1_s12 -- Direct Form I biquad, four hardwired Q14 sections.
# --------------------------------------------------------------------------
# Coefficient sets, Q14 (value x 16384), each written as the signed power-of-two
# list the RTL emits.  Nothing here is a runtime multiply.
#   P0 low-pass    b = 0.125, 0.25, 0.125   a' = +0.75, -0.5   DC gain 2/3
#   P1 DC blocker  b = 0.5, -0.5, 0         a' = +0.5,  0      DC gain 0
#   P2 high-gain   b = 0.0625, 0.125, 0.0625 a' = +1.375, -0.4375  DC gain 4
#   P3 resonator   b = 0, 0.25, 0            a' = +1.25, -0.75  radius sqrt(.75)
# Poles: P0 0.707+-j0; P1 single 0.5; P2 real 0.875 and 0.5; P3 complex pair of
# radius 0.866.  DC gain of a DF1 section is sum(b) / (1 - a1' - a2'), so P2 is
# 0.25/0.0625 = 4 and is the section that clamps a steady input.
BIQUAD_DF1_BODY = '''
x0 = $signed(a[11:0]);
x1 = c[31] ? 64'sd0 : $signed(state_r[11:0]);
x2 = c[31] ? 64'sd0 : $signed(state_r[23:12]);
y1 = c[31] ? 64'sd0 : $signed(state_r[35:24]);
y2 = c[31] ? 64'sd0 : $signed(state_r[47:36]);
case (c[1:0])
    2'd0: acc = (x0<<<11) + (x1<<<12) + (x2<<<11) + (y1<<<13) + (y1<<<12) - (y2<<<13);
    2'd1: acc = (x0<<<13) - (x1<<<13) + (y1<<<13);
    2'd2: acc = (x0<<<10) + (x1<<<11) + (x2<<<10) + (y1<<<14) + (y1<<<12) + (y1<<<11) - (y2<<<13) + (y2<<<10);
    2'd3: acc = (x1<<<12) + (y1<<<14) + (y1<<<12) - (y2<<<13) - (y2<<<12);
endcase
acc = (acc + 64'sd8192) >>> 14;
cl = (acc > 64'sd2047) || (acc < -64'sd2048);
ys = acc > 64'sd2047 ? 12'h7ff : (acc < -64'sd2048 ? 12'h800 : acc[11:0]);
bad = (c[30:2] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    r = {{20{ys[11]}}, ys};
    x[11:0] = state_r[35:24];
    x[23:12] = state_r[11:0];
    x[24] = cl;
    x[25] = c[31];
    f = cl;
    state_n = 0;
    state_n[11:0] = a[11:0];
    state_n[23:12] = state_r[11:0];
    state_n[35:24] = ys;
    state_n[47:36] = state_r[35:24];
end'''

BIQUAD_DF1_DECL = ('reg signed [63:0] x0, x1, x2, y1, y2, acc;\n'
                   'reg [11:0] ys;\nreg cl, bad;')

core('biquad_df1_s12',
     'Direct Form I biquad over one s12 sample per accepted beat. a[11:0] is the '
     'input, c[1:0] selects one of four hardwired Q14 coefficient sets (P0 lowpass, '
     'P1 DC blocker, P2 high-gain lowpass (DC gain 4), P3 resonator), c[31] restarts by zeroing the '
     'x1/x2/y1/y2 history before this beat, c[30:2] must be zero. result = '
     'sign-extended s12 clamp of round(sum(q14 terms)/16384) to [-2048,2047]. '
     'aux[11:0]=previous output y1, aux[23:12]=previous input x1, aux[24]=clamped, '
     'aux[25]=restart. fault = clamp or malformed control.',
     BIQUAD_DF1_BODY,
     'A four-tap history read, five Q14 coefficient products and a saturating '
     'round all retire in one enabled beat at II=1; a DSP does the same with five '
     'multiply-accumulates plus a branch for the clamp and no clamped-sample flag.',
     1, BIQUAD_DF1_DECL, stateful=True)


@model('biquad_df1_s12')
def biquad_df1(a, b, c, state):
    if c >> 2 & ((1 << 29) - 1):
        return 0, 0, 1, 0
    restart = bool(c >> 31)
    x0 = s12(a)
    x1 = 0 if restart else field(state, 0, 12)
    x2 = 0 if restart else field(state, 1, 12)
    y1 = 0 if restart else field(state, 2, 12)
    y2 = 0 if restart else field(state, 3, 12)
    bank = (
        [(x0, 11), (x1, 12), (x2, 11), (y1, 13), (y1, 12), (-y2, 13)],
        [(x0, 13), (-x1, 13), (y1, 13)],
        [(x0, 10), (x1, 11), (x2, 10), (y1, 14), (y1, 12), (y1, 11),
         (-y2, 13), (y2, 10)],
        [(x1, 12), (y1, 14), (y1, 12), (-y2, 13), (-y2, 12)],
    )[c & 3]
    acc = sum(v << s for v, s in bank)
    acc = (acc + 8192) >> 14
    clamped = acc > 2047 or acc < -2048
    ys = clamp(acc, -2048, 2047)
    r = ys & MASK
    x = (state >> 24 & 0xfff) | ((state & 0xfff) << 12) | \
        (int(clamped) << 24) | (int(restart) << 25)
    new = (a & 0xfff) | ((state & 0xfff) << 12) | \
        ((ys & 0xfff) << 24) | ((state >> 24 & 0xfff) << 36)
    return r, x, int(clamped), new


@gen('biquad_df1_s12')
def biquad_df1_rows(count):
    rows = []
    for preset in range(4):
        for i, value in enumerate(tri(30)):
            c = preset | (1 << 31) if i == 0 else preset
            rows.append((value & 0xfff, 0, c))
        rows.append((2047, 0, preset))                  # positive rail
        rows.append((-2048 & 0xfff, 0, preset))         # negative rail
        if preset < 2:
            # Malformed control is exercised early enough to sit inside the
            # 128 board rows, once per section selector.
            rows.append((1000, 0, preset | 4))
            rows.append((0, 0, preset | (1 << 20)))
    for i, value in enumerate(ramp(count - len(rows))):
        rows.append((value, 0, i & 3))                 # all four sections, no repeats
    return rows


def selftest():
    """Independent-model checks; constants hand-derived from the Q14 tables."""
    checks = 0
    # P1 is the DC blocker y = 0.5*x - 0.5*x1 + 0.5*y1 with every coefficient an
    # exact power of two (Q14 8192), so from restart the first output is
    # round(0.5*2047) = 1024 and x1 history is the input we just fed.
    r, x, f, st = step('biquad_df1_s12', 2047, 0, 1 | (1 << 31))
    assert r == 1024 and f == 0, (r, f)
    assert x & 0xfff == 0 and (x >> 12 & 0xfff) == 0, hex(x)
    checks += 2
    # A constant input through the DC blocker must decay to zero, and the second
    # beat is 0.5*2047 - 0.5*2047 + 0.5*1024 = 512 exactly.
    r, x, f, st = step('biquad_df1_s12', 2047, 0, 1, st)
    assert r == 512 and f == 0, (r, f)
    assert x & 0xfff == 1024, hex(x)                    # aux echoes y1 = 1024
    checks += 2
    # P0 DC gain: b0+b1+b2 = 0.5, 1-a1-a2 = 1-0.75+0.5 = 0.75, so the settled
    # gain of the section is 2/3; a full-scale step must stay inside the rails
    # and never flag.
    state = 0
    for _ in range(40):
        r, x, f, state = step('biquad_df1_s12', 1000, 0, 0, state)
    assert f == 0 and 600 < s12(r) < 700, (s12(r), f)
    checks += 1
    # P2 has b sum 0.25 and 1-a1'-a2' = 1-1.375+0.4375 = 0.0625, so its DC gain
    # is exactly 4. A DC input of 600 therefore wants 2400, which must land on
    # the positive rail with the clamp flag raised on every settled beat.
    state = 0
    for _ in range(60):
        r, x, f, state = step('biquad_df1_s12', 600, 0, 2, state)
    assert f == 1 and s12(r) == 2047, (s12(r), f)
    assert x >> 24 & 1 == 1, hex(x)
    checks += 2
    # P3 is a resonator of pole radius sqrt(0.75) = 0.866 < 1, so an impulse
    # burst rings and then decays to zero instead of running away.
    state = 0
    r, x, f, state = step('biquad_df1_s12', 2047, 0, 3 | (1 << 31), state)
    assert (r, f) == (0, 0)                             # x arrives one beat late
    peak = 0
    for _ in range(120):
        r, x, f, state = step('biquad_df1_s12', 0, 0, 3, state)
        peak = max(peak, abs(s12(r)))
        assert f == 0
    assert 400 < peak < 2048, peak
    checks += 2
    # Malformed control is the second, independent fault path: zeroed result and
    # zeroed state, whatever the history was.
    r, x, f, state = step('biquad_df1_s12', 1234, 0, 1 | 4, 0x5a5a5a)
    assert (r, x, f, state) == (0, 0, 1, 0)
    r, x, f, state = step('biquad_df1_s12', 1234, 0, 1 << 20)
    assert (r, x, f, state) == (0, 0, 1, 0)
    checks += 2
    # Restart is a pre-charge, not a drain: after c[31] the section behaves as if
    # never used, so the same input gives the same first output again.
    r1 = step('biquad_df1_s12', 300, 0, 1 | (1 << 31), 0xffffffffff)[0]
    r2 = step('biquad_df1_s12', 300, 0, 1 | (1 << 31), 0)[0]
    assert r1 == r2 == ((300 << 13) + 8192) >> 14, (r1, r2)
    checks += 2
    # --- biquad_df2_s12 -----------------------------------------------------
    # The Q14 lists the RTL emits, checked as plain integers: b = 2560, 5120,
    # 2560 (sum 10240) and -a1 = 17408, -a2 = -6144, so the denominator at z=1 is
    # 16384 - 17408 + 6144 = 5120 and the DC gain is 10240/5120 = 2 exactly.
    assert (1 << 11) + (1 << 9) == 2560
    assert (1 << 12) + (1 << 10) == 5120
    assert (1 << 14) + (1 << 10) == 17408
    assert -(1 << 13) + (1 << 11) == -6144
    assert 10240 == 2 * (16384 - 17408 + 6144)
    checks += 5
    # From restart the first output is round(0.15625*2047) = round(319.84) = 320,
    # and aux is the echoed (zero) state.
    r, x, f, st = step('biquad_df2_s12', 2047, 0, 0 | (1 << 31))
    assert (r, x, f) == (320, 0, 0), (r, x, f)
    # Second beat with the input back at zero: s1 = 5120*2047 + 17408*320, so the
    # output is 0.3125*2047 + 1.0625*320 = 639.69 + 340 = 979.69 -> 980.
    r, x, f, st = step('biquad_df2_s12', 0, 0, 0, st)
    assert (r, f) == (980, 0), (r, f)
    assert x & 0xffff == (16051200 & 0xffff), hex(x)   # s1 low bits echoed
    checks += 3
    # Exact fixed point: DC 1000 with gain 2 must settle on 2000 and never flag.
    state = 0
    for _ in range(60):
        r, x, f, state = step('biquad_df2_s12', 1000, 0, 0, state)
    assert (s12(r), f) == (2000, 0), (s12(r), f)
    checks += 1
    # DC 1500 wants 3000, so it must sit on the positive rail with the clamp set.
    state = 0
    for _ in range(60):
        r, x, f, state = step('biquad_df2_s12', 1500, 0, 0, state)
    assert (s12(r), f) == (2047, 1), (s12(r), f)
    checks += 1
    # P1 DC blocker: y = 0.5*x + s1, s1 = -0.5*x + 0.5*y, so 2047 -> 1024 -> 512.
    r, x, f, st = step('biquad_df2_s12', 2047, 0, 1 | (1 << 31))
    assert (r, f) == (1024, 0), (r, f)
    r, x, f, st = step('biquad_df2_s12', 2047, 0, 1, st)
    assert (r, f) == (512, 0), (r, f)
    checks += 2
    # Two independent malformed-control paths.
    assert step('biquad_df2_s12', 100, 0, 2, 0xdeadbeef) == (0, 0, 1, 0)
    assert step('biquad_df2_s12', 100, 0, 1 << 3, 0xdeadbeef) == (0, 0, 1, 0)
    checks += 2
    # --- biquad_cascade_step --------------------------------------------------
    # Stage 1 gain 2 times stage 2 gain 0: with a DC input of 500 and the DC
    # blocker in circuit, stage 1 must sit on exactly 1000 (aux[11:0]).  Once
    # stage 1 has settled, ys == qx1 and the blocker reduces to
    # out' = floor((out + 1) / 2), whose positive fixed point is 1 LSB, so the
    # cascade idles at exactly 1 rather than at 0.
    state = 0
    for _ in range(80):
        r, x, f, state = step('biquad_cascade_step', 500, 0, 0, state)
    assert (s12(r), x & 0xfff, f) == (1, 1000, 0), (s12(r), hex(x), f)
    r2, x2, f2, state = step('biquad_cascade_step', 500, 0, 0, state)
    assert s12(r2) == (s12(r) + 1) >> 1, (s12(r), s12(r2))
    checks += 2
    # A negative DC input decays through the same map to the other fixed point:
    # floor((-1 + 1)/2) = 0, so -500 idles the blocker on exactly 0.
    state = 0
    for _ in range(80):
        r, x, f, state = step('biquad_cascade_step', -500, 0, 0, state)
    assert (s12(r), x & 0xfff, f) == (0, 4096 - 1000, 0), (s12(r), hex(x), f)
    checks += 1
    # Bypassing stage 2 leaves the exact-gain-2 section alone: 2*500 = 1000.
    state = 0
    for _ in range(80):
        r, x, f, state = step('biquad_cascade_step', 500, 0, 1, state)
    assert (s12(r), f) == (1000, 0), (s12(r), f)
    checks += 1
    # Stage 1 wants 2*1500 = 3000, so it rails at 2047 with aux[12] set while the
    # DC blocker still pulls the final output down to its 1 LSB idle point.
    state = 0
    for _ in range(80):
        r, x, f, state = step('biquad_cascade_step', 1500, 0, 0, state)
    assert (s12(r), f) == (1, 1) and x >> 12 & 1 == 1, (s12(r), hex(x), f)
    checks += 2
    # First beat after a restart from a dirty state: only b0 acts, so stage 1 is
    # round(0.15625*2047) = 320 and stage 2 is round(0.5*320) = 160.
    r, x, f, st = step('biquad_cascade_step', 2047, 0, 1 << 31, 0xabcdef01)
    assert (r, x & 0xfff, f) == (160, 320, 0), (r, hex(x), f)
    assert x >> 15 & 1 == 1, hex(x)
    checks += 2
    # Malformed control (c[5] is reserved) zeroes result, aux and state.
    assert step('biquad_cascade_step', 100, 0, 1 << 5, 0x12345) == (0, 0, 1, 0)
    checks += 1
    # --- poly2_interp -------------------------------------------------------
    # The signed power-of-two lists the kernel emits must rebuild the published
    # Q14 Lagrange weights, and each triple must sum to 16384 (unity DC gain).
    for phase, terms in POLY2_TERMS.items():
        rebuilt = [0, 0, 0]
        for tap, shift, sign in terms:
            rebuilt[tap] += (1 << shift) if sign > 0 else -(1 << shift)
        assert tuple(rebuilt) == POLY2_Q14[phase], (phase, rebuilt)
        assert sum(rebuilt) == 16384, phase
        checks += 2
    # The same weights as exact rationals of 16384, checked as integer identities.
    assert 32 * POLY2_Q14[1][0] == -3 * 16384
    assert 16 * POLY2_Q14[1][1] == 15 * 16384
    assert 32 * POLY2_Q14[1][2] == 5 * 16384
    assert 8 * POLY2_Q14[2][0] == -1 * 16384
    assert 4 * POLY2_Q14[2][1] == 3 * 16384
    assert 8 * POLY2_Q14[2][2] == 3 * 16384
    assert 32 * POLY2_Q14[3][0] == -3 * 16384
    assert 16 * POLY2_Q14[3][1] == 7 * 16384
    assert 32 * POLY2_Q14[3][2] == 21 * 16384
    checks += 9
    # Unity DC gain: a flat pair of inputs (100, -60) reproduces itself at every
    # one of the sixteen phase combinations, on both lanes, with no clamp.
    for combo in range(16):
        r, x, f, st = step('poly2_interp', 0x00646464, 0x00c4c4c4, combo, 0x55)
        assert (r, x, f) == (0x0000c464, 0x00c46400, 0), (hex(r), hex(x), f)
        assert st == 0x55, hex(st)            # not stateful: state untouched
        checks += 1
    # (-128, 127, 127) at mu=1/4 is -3/32*-128 + 15/16*127 + 5/32*127
    # = 12 + 119.0625 + 19.84375 = 150.9 -> 151, so lane 0 clamps to +127 and the
    # pre-clamp residue 151 stays visible in aux[15:8]. Lane 1 is the flat 100.
    r, x, f, _ = step('poly2_interp', 0x007f7f80, 0x00646464, 1 | (2 << 2))
    assert (r, x, f) == (0x0000647f, 0x00649701, 1), (hex(r), hex(x), f)
    checks += 3
    # Reserved control bits fault on their own.
    assert step('poly2_interp', 0x12345678, 0, 1 << 4)[:3] == (0, 0, 1)
    assert step('poly2_interp', 0, 0, 1 << 31)[:3] == (0, 0, 1)
    checks += 2
    # --- cic_comp_s12 -------------------------------------------------------
    # R = 8 with a constant input of 64.  The second integrator holds
    # v*(k+1)(k+2)/2 after beat k, so the first group (beat 7) differs to 36v and
    # round(36*64/64) = 36; the second group (beat 15) differs to R^2*v = 64v, so
    # the shift-compensated output is exactly the input again.
    state = 0
    for k in range(8):
        cc = 3 | (1 << 31) if k == 0 else 3
        r, x, f, state = step('cic_comp_s12', 64, 0, cc, state)
    assert (s12(r), f, x >> 5 & 1) == (36, 0, 1), (s12(r), f, hex(x))
    for k in range(8, 15):
        r, x, f, state = step('cic_comp_s12', 64, 0, 3, state)
    assert (s12(r), f) == (36, 0), (s12(r), f)         # held between groups
    assert x >> 5 & 1 == 0, hex(x)
    r, x, f, state = step('cic_comp_s12', 64, 0, 3, state)   # beat 15: group 2
    assert (s12(r), f) == (64, 0), (s12(r), f)         # exact unity DC gain
    checks += 4
    # R = 4: the first group (beat 3) is 10v/16 and the second (beat 7) is 16v.
    state = 0
    for k in range(4):
        cc = 2 | (1 << 31) if k == 0 else 2
        r, x, f, state = step('cic_comp_s12', 16, 0, cc, state)
    assert (s12(r), f) == (10, 0), (s12(r), f)
    for k in range(3, 8):
        r, x, f, state = step('cic_comp_s12', 16, 0, 2, state)
    assert (s12(r), f) == (16, 0), (s12(r), f)
    checks += 2
    # A 2047 DC run must overload the 20-bit second integrator (2047*23*24/2 =
    # 564972 > 524287) and raise integrator-2's own flag, without wrapping.
    state = 0
    for k in range(40):
        cc = 3 | (1 << 31) if k == 0 else 3
        r, x, f, state = step('cic_comp_s12', 2047, 0, cc, state)
    assert f == 1 and x >> 1 & 1 == 1, hex(x)
    assert field(state, 1, 20) == (1 << 19) - 1, hex(state)   # clamped, not wrapped
    checks += 2
    # Two independent malformed-control paths.
    assert step('cic_comp_s12', 0, 0, 1, 0x123456) == (0, 0, 1, 0)
    assert step('cic_comp_s12', 0, 0, 3 | (1 << 10), 0x123456) == (0, 0, 1, 0)
    checks += 2
    # --- goertzel_dtmf ------------------------------------------------------
    # Published anchor: the ITU-T Q.23 DTMF tone plan at fs = 8000 Hz.  c1 is
    # recomputed here from math.cos (system libm, independent of the shift-add
    # lists the RTL actually uses) and every pasted list must sum to it.
    from math import cos, pi
    for i, freq in enumerate(GOERTZEL_F):
        q = round(2 * cos(2 * pi * freq / 8000) * 16384)
        naf = sum((1 << k) if d > 0 else -(1 << k)
                  for k, d in GOERTZEL_NAF[i])
        assert q == GOERTZEL_Q14[i] == naf, (freq, q, naf)
        checks += 1
    # Restart clears both accumulators, so acc = x << 26 exactly, sv = x << 12,
    # s2 = 0 and r = ((|x| << 12) + 4096) >> 13 = (|x| + 1) // 2.
    r, x, f, st = step('goertzel_dtmf', 2047, 0, 1 << 31, 0x7eed)
    assert (r, f) == (1024, 0) and x == (1 | (511 << 16))
    r, x, f, st = step('goertzel_dtmf', -2048, 0, (1 << 31) | 7, 0x7eed)
    assert (r, f) == (1024, 0) and x == ((7 << 28) | 1 | (512 << 16))
    checks += 3
    # Next beat at bin 7 with a zero sample: s(2) = c1*s(1), and the published
    # cosine gives c1 = 0.56853, so the energy proxy is (1000 + 568.5) / 2.
    _, _, _, st = step('goertzel_dtmf', 1000, 0, (1 << 31) | 7, 0)
    r2, x2, f2, st = step('goertzel_dtmf', 0, 0, 7, st)
    oracle = 1000 * 2 * cos(2 * pi * 1633 / 8000)
    assert f2 == 0 and abs(r2 - round((1000 + oracle) / 2)) <= 1
    assert ((x2 >> 4) & 0xfff) == 250 and (x2 & 1) == 0   # |s(1)|>>14, no restart
    assert abs(((x2 >> 16) & 0xfff) - round(oracle / 4)) <= 1
    checks += 3
    # Three beats of full-scale DC into bin 0: s(1) = 2047, s(2) = 2047*(1 + c1)
    # = 5542.7 and s(3) = c1*s(2) = 9466 signal units, past the +/-8191.99 Q12
    # field, so the accumulator rails and both clamps fire.
    st = 0
    for k in range(3):
        r, x, f, st = step('goertzel_dtmf', 2047, 0,
                           (1 << 31) if k == 0 else 0, st)
    assert f == 1 and ((x >> 16) & 0xfff) == 2047 and r == 2047
    checks += 3
    # Malformed control: a bin change without a restart, and any reserved bit.
    st = step('goertzel_dtmf', 0, 0, 0, 0)[3]
    assert step('goertzel_dtmf', 0, 0, 1, st) == (0, 0, 1, 0)
    assert step('goertzel_dtmf', 0, 0, 1 | (1 << 20), st) == (0, 0, 1, 0)
    assert step('goertzel_dtmf', 0, 0, 0 | (1 << 3), st) == (0, 0, 1, 0)
    assert step('goertzel_dtmf', 0, 0, 0 | (1 << 30), st) == (0, 0, 1, 0)
    checks += 4
    # --- karplus_strong -----------------------------------------------------
    # Beat 1 of a fresh pluck: the line, the pointer and the previous output are
    # all cleared, so ssum = 0 and y(1) = ((0 - 0) >> 1) + 2047 = 2047.  Every
    # number below is hand arithmetic on the loop formula, not model output.
    r, x, f, st = step('karplus_strong', 2047, 0, 1 << 31, 0xbeef)
    assert (r, f) == (2047, 0) and x == (2047 << 8) | 0x80 | 1
    # Beat 2 reads cell 1, still empty, so ssum = 2047 and the dark damping
    # exponent E = 7 gives y(2) = (2047 - (2047 >> 7)) >> 1 = (2047-15)>>1.
    assert (2047 - (2047 >> 7)) >> 1 == 1016
    r, x, f, st = step('karplus_strong', 0, 0, 0, st)
    assert (r, f) == (1016, 0) and x == (1016 << 8) | 2
    # The bright exponent E = 4 subtracts 2047 >> 4 = 127 instead.
    assert (2047 - (2047 >> 4)) >> 1 == 960
    _, _, _, st2 = step('karplus_strong', 2047, 0, (1 << 31) | 4, 0)
    r, x, f, st2 = step('karplus_strong', 0, 0, 4, st2)
    assert (r, f) == (960, 0) and x == (960 << 8) | 2      # c = 4: E = 4, M = 4
    checks += 5
    # Full-scale excitation on top of a still-sounding loop overflows s12:
    # beat 3 has ssum = 1016 (cell 2 is empty), so
    # y = ((1016 - (1016 >> 7)) >> 1) + 2047 = 504 + 2047 = 2551, clamped to
    # 2047 with the pre-clamp value carried in aux[21:8].
    assert (1016 - (1016 >> 7)) >> 1 == 504
    r, x, f, st = step('karplus_strong', 2047, 0, 0, st)
    assert (r, f) == (2047, 1) and ((x >> 8) & 0x3fff) == 2551 and x & 0x40
    checks += 2
    # Four-cell loop closes: with M = 4 the pointer wraps after beats 1..4 and
    # beat 5 reads back cell 0 = 2047, giving (250 + 2047 - ((250+2047) >> 7)) >> 1
    # = (2297 - 17) >> 1 = 1140.  That value only exists if the line wrapped.
    assert (2297 - (2297 >> 7)) >> 1 == 1140
    st = 0
    for k, sample in enumerate((2047, 0, 0, 0, 0)):
        r, x, f, st = step('karplus_strong', sample, 0,
                           (1 << 31) if k == 0 else 0, st)
        assert ((x & 0xf) == ((k + 1) % 4)) and f == 0
    assert r == 1140
    checks += 6
    # Reserved control bits are malformed and wipe the string.
    assert step('karplus_strong', 0, 0, 3 | (1 << 3), st) == (0, 0, 1, 0)
    assert step('karplus_strong', 0, 0, 3 | (1 << 20), st) == (0, 0, 1, 0)
    checks += 2
    # --- dsm2_mod -----------------------------------------------------------
    # Idle limit cycle, worked out by hand from the documented CIFB equations
    # with x = 0, starting from cleared integrators, four sub-steps:
    #   v(1) = 0 + 0 = 0 >= 0  -> pdm 1, y = +2046,
    #          x1 = 0 + ((0-2046) >> 1) = -1023, x2 = 0 + 0 - 1023 = -1023
    #   v(2) = -1023 + (-1023 >> 1) = -1023 - 512 = -1535 -> pdm 0, y = -2046,
    #          x1 = -1023 + 1023 = 0, x2 = -1023 - 512 + 1023 = -512
    #   v(3) = -512 + (0 >> 1) = -512 -> pdm 0,
    #          x1 = 0 + 1023 = 1023,  x2 = -512 + 0 + 1023 = 511
    #   v(4) = 511 + (1023 >> 1) = 511 + 511 = 1022 -> pdm 1,
    #          x1 = 1023 - 1023 = 0,  x2 = 511 + 511 - 1023 = -1
    assert -2046 >> 1 == -1023 and 2046 >> 1 == 1023
    assert (-1023 >> 1) == -512 and -1023 - 512 + 1023 == -512
    assert 511 + 511 - 1023 == -1
    r, x, f, st = step('dsm2_mod', 0, 0, (1 << 31) | 3, 0xabcd)
    assert r == 2046 and f == 0
    assert ((x >> 8) & 0xfff) == 0 and s_bits((x >> 20) & 0xfff, 12) == -1
    assert ((x >> 1) & 7) == 2 and (x & 1) == 1 and (x >> 5) & 1
    checks += 5
    # Loop gain: the mean of the two +/-2046 levels has to track the input, so
    # the long-run density is (x + 2046) / 4092.  Half a LSB of floor bias per
    # step is allowed; nothing here comes out of the model.
    st = 0
    high = 0
    for k in range(200):
        r, x, f, st = step('dsm2_mod', 500, 0, (1 << 31) if k == 0 else 0, st)
        assert not f
        if k >= 5:
            high += (x >> 1) & 7
    assert abs(high / 195 - (500 + 2046) / 4092) <= 0.01
    checks += 2
    # Idle at four sub-steps per beat is exactly 50% by the hand chain above.
    st = 0
    high = 0
    for k in range(200):
        r, x, f, st = step('dsm2_mod', 0, 0, (1 << 31) | 3 if k == 0 else 3, st)
        assert not f
        high += (x >> 1) & 7
    assert high * 2 == 200 * 4
    checks += 2
    # An input at the negative rail is outside the stable range: the s12 clamp
    # has to fire within a handful of beats instead of wrapping silently.
    st = 0
    seen = None
    for k in range(6):
        r, x, f, st = step('dsm2_mod', -2048, 0, (1 << 31) if k == 0 else 0, st)
        if f and seen is None:
            seen = k
    assert seen is not None and seen <= 4
    # Reserved control bits wipe the loop.
    assert step('dsm2_mod', 0, 0, (1 << 2), 0x55) == (0, 0, 1, 0)
    assert step('dsm2_mod', 0, 0, (1 << 12), 0x55) == (0, 0, 1, 0)
    checks += 3
    # --- envelope_ar --------------------------------------------------------
    # A magnitude is one unit wider than the positive s12 rail: from an empty
    # envelope, |(-2048)| << 8 = 2^19 in Q8, so the level is 2048 and x1 rails.
    assert 2048 << 8 == 1 << 19 and (1 << 19) >> 8 == 2048
    r, x, f, st = step('envelope_ar', -2048, 0, 1 << 31, 0x1234)
    assert (r, f) == (2047, 1) and x == (1 << 29) | 13 and (x >> 10) == 1 << 19
    checks += 3
    # The four meter ranges are pure shifts: 200 -> 200, 400, 800, 1600.
    assert 200 << 8 >> 8 == 200
    for gg, want in ((0, 200), (1, 400), (2, 800), (3, 1600)):
        r, x, f, st = step('envelope_ar', 200, 0, (1 << 31) | (gg << 4), 0)
        assert (r, f, st) == (want, 0, 200 << 8)
        checks += 1
    # 1024 on x8 would be 8192, so it clamps instead of silently wrapping.
    r, x, f, st = step('envelope_ar', 1024, 0, (1 << 31) | (3 << 4), 0)
    assert (r, f) == (2047, 1) and st == 1024 << 8
    checks += 2
    # Release with K = 2 (c[2:0] = 1): e = e - (e >> 2), so 1024 -> 768 -> 576
    # exactly, and the release flag is the only one of the pair set.
    r, x, f, st = step('envelope_ar', 1024, 0, (1 << 31) | 1, 0)
    assert st == 1024 << 8
    r, x, f, st = step('envelope_ar', 0, 0, 1, st)
    assert (r, f, (x >> 10), (x & 6)) == (768, 0, 196608, 2)
    r, x, f, st = step('envelope_ar', 0, 0, 1, st)
    assert (r, f, (x >> 10)) == (576, 0, 147456)
    checks += 3
    # Floor-shift stall: 1/2048 of full scale attacks to Q8 = 256, then with
    # K = 8 the release subtracts 1 once and 0 forever, so the envelope sticks
    # at 255 while the reported level reads 0.
    assert 256 >> 8 == 1 and 255 >> 8 == 0
    r, x, f, st = step('envelope_ar', 1, 0, (1 << 31) | 7, 0)
    for _ in range(5):
        r, x, f, st = step('envelope_ar', 0, 0, 7, st)
    assert (r, f, st) == (0, 0, 255)
    checks += 2
    # Peak hold (c[3]) disables the release branch: neither flag is taken and
    # the envelope is unchanged after four silent beats.
    r, x, f, st = step('envelope_ar', 1024, 0, (1 << 31) | 8, 0)
    for _ in range(4):
        r, x, f, st = step('envelope_ar', 0, 0, 8, st)
    assert (r, f, st, (x & 6), (x >> 9) & 1) == (1024, 0, 1024 << 8, 0, 1)
    checks += 2
    # Reserved control bits.
    assert step('envelope_ar', 0, 0, (1 << 6), 0x9) == (0, 0, 1, 0)
    assert step('envelope_ar', 0, 0, (1 << 20), 0x9) == (0, 0, 1, 0)
    checks += 2
    # --- tdm8_demux ---------------------------------------------------------
    # A legal audio slot is s12 inside the s16 wire word, so bits 15:12 have to
    # read as bit 11 repeated four times.  Worked out on the raw patterns: both
    # rails are clean, the first values outside them are not.
    assert 2047 == 0x07ff and 0x07ff >> 12 == 0 and (0x07ff >> 11) & 1 == 0
    assert (-2048) & 0xffff == 0xf800 and 0xf800 >> 12 == 0xf
    assert (0xf800 >> 11) & 1 == 1
    assert 2048 == 0x0800 and 0x0800 >> 12 == 0 and (0x0800 >> 11) & 1 == 1
    assert (-2049) & 0xffff == 0xf7ff and 0xf7ff >> 12 == 0xf
    assert (0xf7ff >> 11) & 1 == 0
    checks += 6
    # So the rails route with no fault and 2400 / -2500 (the values the board set
    # uses) route the raw word with over-range raised.
    r, x, f, st = step('tdm8_demux', 2047, 0, 1 << 31, 0x5555)
    assert (r, f, (x >> 27) & 1) == (2047, 0, 0)
    r, x, f, st = step('tdm8_demux', -2048, 0, (1 << 31) | 1, 0)
    assert (r & 0xffff, f, (x >> 27) & 1) == (0xf800, 0, 0)
    r, x, f, st = step('tdm8_demux', 2400, 0, (1 << 31) | 2, 0)
    assert (r, f, (x >> 27) & 1) == (2400, 1, 1)
    r, x, f, st = step('tdm8_demux', -2500, 0, (1 << 31) | 3, 0)
    assert (r & 0xffff, f, (x >> 27) & 1) == (0xf63c, 1, 1)
    checks += 4
    # One clean frame writes slot s with the value s, so after slot s the
    # fold-down is s(s+1)/2, the seen bitmap is (1<<(s+1))-1, the expected slot
    # counter is s+1 and lock arrives only on the last slot: 7*8/2 = 28.
    st = 0
    for s in range(8):
        r, x, f, st = step('tdm8_demux', s, 0,
                           s | ((1 << 31) if s == 0 else 0), st)
        assert (r, f, (x & 0xffff), ((x >> 16) & 0xff)) == \
            (s, 0, s * (s + 1) // 2, (1 << (s + 1)) - 1)
        assert ((x >> 29) & 1) == (1 if s == 7 else 0)
        assert ((st >> 136) & 7) == ((s + 1) & 7)
    assert 7 * 8 // 2 == 28 and (1 << 8) - 1 == 0xff
    checks += 25
    # The same frame with every slot negated: -(0+1+...+7) = -28, which the
    # 16-bit fold-down field shows as 65536 - 28 = 0xffe4.
    st = 0
    for s in range(8):
        r, x, f, st = step('tdm8_demux', -s, 0,
                           s | ((1 << 31) if s == 0 else 0), st)
    assert (-28) & 0xffff == 0xffe4
    assert (f, (x & 0xffff), (r & 0xffff)) == (0, 0xffe4, 0xfff9)
    checks += 2
    # Linearity of the fold-down: 100 * (0+1+...+7) = 2800, and slot 7 carries
    # 700, so the beat reports the whole bus at once.
    st = 0
    for s in range(8):
        r, x, f, st = step('tdm8_demux', 100 * s, 0,
                           s | ((1 << 31) if s == 0 else 0), st)
    assert (f, r, (x & 0xffff)) == (0, 700, 2800)
    assert 100 * 28 == 2800 and 2800 < 32768
    checks += 2
    # Worst case for that field over in-range slots is eight at the negative
    # rail: 8 * 2048 = 16384, which still fits s16, so a clean bus never wraps.
    assert 8 * 2048 == 16384 and 16384 < 32768
    checks += 1
    # From a reset receiver the expected slot is 0, so claiming slot 3 raises
    # the sequence bit and the fault while still routing the word and re-basing
    # the counter on what was actually seen; slot 4 then continues in step.
    r, x, f, st = step('tdm8_demux', 3, 0, 3, 0)
    assert (r, f, (x >> 28) & 1, ((x >> 16) & 0xff), ((st >> 136) & 7)) == \
        (3, 1, 1, 1 << 3, 4)
    r, x, f, st = step('tdm8_demux', 4, 0, 4, st)
    assert (r, f, (x >> 28) & 1, ((x >> 16) & 0xff), (x & 0xffff)) == \
        (4, 0, 0, 0x18, 7)
    checks += 2
    # c[31] re-synchronises instead of faulting: slot 6 is accepted from a bare
    # state, the bitmap starts from that slot alone and the restart echo is set.
    r, x, f, st = step('tdm8_demux', 6, 0, (1 << 31) | 6, 0)
    assert (r, f, (x >> 30) & 1, (x >> 28) & 1, ((x >> 16) & 0xff),
            (x & 0xffff)) == (6, 0, 1, 0, 1 << 6, 6)
    # Lock is just the bitmap compare, so a mid-frame re-sync drops it at once.
    r, x, f, st = step('tdm8_demux', 1, 0, (1 << 31) | 1, st)
    assert (f, (x >> 29) & 1, ((x >> 16) & 0xff)) == (0, 0, 1 << 1)
    checks += 2
    # Reserved control bits: bit 3 and bit 30 are both inside c[30:3], so the
    # beat is malformed, the word is dropped and the state loses lock.
    assert step('tdm8_demux', 2047, 0, 1 << 10, 0x5555) == (0, 0, 1, 0)
    assert step('tdm8_demux', 0, 0, (1 << 31) | (1 << 3), 0x5555) == (0, 0, 1, 0)
    assert step('tdm8_demux', 0, 0, 1 << 30, 0x5555) == (0, 0, 1, 0)
    checks += 3
    checks += theory_checks()
    return checks


def theory_checks():
    """Kernels compared against signal-processing theory computed elsewhere.

    Everything in selftest() above is arithmetic the kernels themselves
    document.  These checks re-derive the answers somewhere else -- textbook
    difference equations in exact rational arithmetic, a direct complex DFT sum
    with libm sines and cosines, the closed-form CIC and Lagrange identities --
    and require the kernels to agree.  A kernel that implements the wrong
    transfer function cannot pass this, and no expectation here was read back
    out of a model run.
    """
    from fractions import Fraction as Fr
    from math import cos, pi, sin, sqrt
    checks = 0
    FS = 8000

    # --- biquad: the two forms of ONE transfer function ---------------------
    # Section P1 carries the identical Q14 coefficients in both cores, so
    # direct form I and transposed direct form II must produce the same sample
    # stream, beat for beat, and both must track the exact rational recurrence
    # y(n) = x(n)/2 - x(n-1)/2 + y(n-1)/2 written here from the difference
    # equation alone.
    seq = (200, -145, 63, 512, -777, 900, -1024, 333, 77, -200, 1500,
           -50, 600, -900, 250, 0, -301, 844, -12, 500)
    s_df1 = s_df2 = 0
    ox1 = oy1 = 0
    for k, v in enumerate(seq):
        cb = (1 << 31) if k == 0 else 0
        r1, _, f1, s_df1 = step('biquad_df1_s12', v, 0, 1 | cb, s_df1)
        r2, _, f2, s_df2 = step('biquad_df2_s12', v, 0, 1 | cb, s_df2)
        want = (Fr(v) - Fr(ox1) + Fr(oy1)) / 2
        assert s12(r1) == s12(r2) and f1 == f2 == 0, (k, s12(r1), s12(r2), f1)
        assert abs(s12(r1) - round(want)) <= 1, (k, s12(r1), float(want))
        ox1, oy1 = v, round(want)
        checks += 2
    # Section P0 only exists in the DF2 core, so its own state equations are
    # folded into DF1 by hand and the resulting biconvert is what gets checked:
    #   y(n) = 2560/16384 x(n) + 5120/16384 x(n-1) + 2560/16384 x(n-2)
    #          + 17408/16384 y(n-1) - 6144/16384 y(n-2)
    # which has DC gain 2 and a complex pole pair of radius sqrt(3/8) < 1.
    b0, b1, b2 = Fr(2560, 16384), Fr(5120, 16384), Fr(2560, 16384)
    a1, a2 = Fr(-17408, 16384), Fr(6144, 16384)
    assert b0 + b1 + b2 == 2 * (1 + a1 + a2)          # exact DC gain of 2
    assert a1 * a1 - 4 * a2 < 0 and 0 < a2 < 1        # complex, inside |z| = 1
    assert abs(sqrt(float(a2))) < Fr(1) ** 1          # radius sqrt(3/8) = 0.612
    state = 0
    hx = [0, 0, 0]
    hy = [Fr(0), Fr(0), Fr(0)]
    for k in range(-260, 261, 17):
        v = k + (k * 7) % 61 - 30
        r, _, f, state = step('biquad_df2_s12', v, 0, (1 << 31) if k == -260 else 0,
                              state)
        hx[2] = hx[1]
        hx[1] = hx[0]
        hx[0] = v
        hy[2] = hy[1]
        hy[1] = hy[0]
        hy[0] = (b0 * hx[0] + b1 * hx[1] + b2 * hx[2]
                 - a1 * hy[1] - a2 * hy[2])
        assert f == 0 and abs(s12(r) - round(hy[0])) <= 1, (k, s12(r), float(hy[0]))
        checks += 1
    # A stable section must settle to its DC gain exactly: a constant input of
    # 300 through gain 2 converges to 600, and the 1/16384 quantisation of the
    # state can leave at most the documented one LSB of rounding, never a bias.
    state = 0
    for _ in range(120):
        r, _, f, state = step('biquad_df2_s12', 300, 0, 0, state)
    assert (s12(r), f) == (600, 0), (s12(r), f)
    checks += 2

    # --- CIC: closed-form DC gain R^N, and the compensator's job is to undo it
    # A CIC of rate R and order N has DC gain R^N, so an N-stage decimator fed a
    # constant v must produce v*R^N before compression.  The kernel compresses by
    # exactly that shift, so the settled output is v again on both rates, while
    # the first integrator (which is the running sum) must read v*(k+1) after k
    # beats -- the closed form of a single accumulator -- before any clamp.
    for l2, rate in ((2, 4), (3, 8)):
        state = 0
        for k in range(3 * rate):
            r, x, f, state = step('cic_comp_s12', 25, 0,
                                  l2 | ((1 << 31) if k == 0 else 0), state)
            assert f == 0
            assert s_bits(field(state, 0, 20), 20) == 25 * (k + 1), (k, state)
            checks += 1
        assert s12(r) == 25, (rate, s12(r))            # v*R^2 / R^2 = v exactly
        checks += 1
    # The compensator is the exact R^N normalization and nothing more, so the
    # droop the decimator leaves behind must be the closed-form comb response
    # |sin(pi f R / fs) / sin(pi f / fs)|^N / R^N -- but sampled where the
    # decimator actually samples it: one group end every R beats.  Two
    # integrators at z = e^{jw} followed by two differences at the group rate
    # z_c = e^{jwR} give the settled complex response
    #       H(w) = ((1 - e^{-jwR}) / (1 - e^{-jw}))^N / R^N,
    #       y(m) = A * Im{ H(w) e^{j w k_m} },   k_m = (m + 1) R - 1,
    # because (1 - e^{-jt}) = 2j sin(t/2) e^{-jt/2}.  The magnitude of H is the
    # sin/sin formula, and that identity is asserted here as pure mathematics
    # before H is used as an oracle, so the amplitude claim stays on the hook.
    def cic_gain(freq, rate, order):
        return abs(sin(pi * freq * rate / FS) / sin(pi * freq / FS)) ** order \
            / rate ** order

    def comb_response(freq, rate, order):
        w = 2 * pi * freq / FS
        num = (1 - cos(w * rate)) + 1j * sin(w * rate)
        den = (1 - cos(w)) + 1j * sin(w)
        return (num / den) ** order / rate ** order

    for freq, rate in ((125, 8), (250, 8), (375, 8), (125, 4), (250, 4)):
        assert abs(abs(comb_response(freq, rate, 2))
                   - cic_gain(freq, rate, 2)) < 1e-12, (freq, rate)
    checks += 5
    # What is left is the bias of measuring that response with a finite peak to
    # peak, and it has exactly two terms, both derived rather than tuned:
    #   * the stimulus is an integer: x(k) = round(A sin(wk)) = A sin(wk) + eps,
    #     |eps| <= 1/2.  Settled, this decimator is the two-fold boxcar
    #     convolution g = (1, 2, .., R, .., 2, 1), sum(g) = R^2, so its gain on
    #     eps is (1/2) sum(g) / R^2 = 1/2 of a report count per group;
    #   * the group is reported as that exact value rounded to the nearest s12
    #     count, a further 1/2 per group.
    # So every group sits within 1 count of y(m); a peak-to-peak takes one
    # extreme each way and so sits within 2 counts, and nothing else can move
    # it because f == 0 rules out both the 20-bit rails and the s12 clamp.
    # Normalised that is 2 / (2A) = 1/A = 1.6e-2 at A = 64 -- for scale, one LSB
    # of the 12-bit signed lane against a span of 122 counts is 8.2e-3, and the
    # 4.6e-5 relative gap that first made this block complain is 13x under even
    # that, which is why it could only ever have been the measurement, not H.
    win = 16
    droop = []
    for l2, rate, amp, freq, groups in ((3, 8, 64, 125, 48), (3, 8, 64, 250, 48),
                                        (3, 8, 64, 375, 48), (2, 4, 64, 125, 48),
                                        (2, 4, 64, 250, 48)):
        state = 0
        outs = []
        for k in range(groups * rate):
            v = round(amp * sin(2 * pi * freq * k / FS))
            r, x, f, state = step('cic_comp_s12', v & 0xfff, 0,
                                  l2 | ((1 << 31) if k == 0 else 0), state)
            assert f == 0, (freq, k, hex(x))
            if (x >> 5) & 1:
                outs.append(s12(r))
        assert len(outs) == groups, (freq, rate, len(outs))
        # Window starts at group 32, so the 2R-1-tap settled support (group 1)
        # and the restart transient are far behind the samples taken here.
        span = max(outs[-win:]) - min(outs[-win:])
        h = comb_response(freq, rate, 2)
        w = 2 * pi * freq / FS
        theory = [amp * (h.real * sin(w * ((m + 1) * rate - 1))
                         + h.imag * cos(w * ((m + 1) * rate - 1)))
                  for m in range(groups)]
        tspan = max(theory[-win:]) - min(theory[-win:])
        assert abs(span - tspan) <= 2, (freq, rate, span, tspan)
        checks += 1
        # A span alone is blind to *when* the groups are taken, so the same
        # closed form is checked group by group as well: every group from the
        # first one whose 2R-1-tap window lies wholly inside the record (group
        # 1; the measured error at group 0 is 4 to 19 counts of restart
        # transient, at group 1 and after it is under half a count) has to sit
        # within the derived 1 count of y(m).  This pins phase and settling as
        # well as amplitude, so a re-aligned or half-group-late decimator that
        # kept the right droop still fails here.
        assert all(abs(o - t) <= 1 for o, t in zip(outs[1:], theory[1:])), \
            (freq, rate, outs[1], theory[1])
        checks += 1
        # Discrete group samples can never exceed the continuous envelope, and
        # -- with the window an exact whole number of periods, asserted rather
        # than assumed -- can never fall below the crest and trough nearest the
        # phase extremes, 2*A*|H|*cos(pi f R / fs).  A response built from f
        # instead of f*R, or with the wrong power, breaks this band on top of
        # the exact comparison above.
        assert (win * freq * rate) % FS == 0, (freq, rate)
        gain = cic_gain(freq, rate, 2)
        assert 2 * amp * gain * cos(pi * freq * rate / FS) - 1e-9 <= tspan \
            <= 2 * amp * gain + 1e-9, (freq, rate, tspan, gain)
        checks += 1
        if rate == 8:
            droop.append((freq, span / (2 * amp)))
    # Droop is monotone in frequency at a fixed rate: 125 > 250 > 375 here, on
    # the measured spans and not just on the formula.
    assert [f for f, _ in droop] == [125, 250, 375], droop
    assert all(a > b for (_, a), (_, b) in zip(droop, droop[1:])), droop
    checks += 1
    # The textbook null at f = fs / R is exact, not approximate: there the
    # group-end second integrator runs as an arithmetic sequence, so its second
    # difference is zero in every bit before the shift.  Only the group that
    # straddles the restart keeps a transient, which is why the settled window
    # above is not group 0.
    for l2, rate, amp in ((3, 8, 64), (2, 4, 64)):
        state = 0
        outs = []
        for k in range(32 * rate):
            v = round(amp * sin(2 * pi * (FS // rate) * k / FS))
            r, x, f, state = step('cic_comp_s12', v & 0xfff, 0,
                                  l2 | ((1 << 31) if k == 0 else 0), state)
            assert f == 0, (rate, k, hex(x))
            if (x >> 5) & 1:
                outs.append(s12(r))
        assert all(v == 0 for v in outs[1:]), (rate, outs[:4])
        assert outs[0] != 0, (rate, outs[:2])       # the transient is real
        checks += 2

    # --- Goertzel: the accumulators ARE a DFT bin --------------------------------
    # For s(n) = x(n) + c1 s(n-1) - s(n-2) with c1 = 2 cos(w) and s(-1) = s(-2)
    # = 0, the standard closing identity is X(w) = s(N-1) - e^{-jw} s(N-2), hence
    #   |X(w)|^2 = s1^2 + s2^2 - c1 s1 s2
    # exactly, for any block length and any w.  The kernel keeps s1 and s2 in its
    # state in Q12 signal units, so the bin magnitude is recoverable and has to
    # match a direct sum of the very same integer samples against libm cos/sin.
    def gblock(bin_, samples):
        state = 0
        flags = 0
        peak = 0
        for n, v in enumerate(samples):
            r, _, f, state = step('goertzel_dtmf', v & 0xfff, 0,
                                  bin_ | ((1 << 31) if n == 0 else 0), state)
            flags |= f
            peak = max(peak, r)
        s1 = field(state, 0, 26) / 4096.0
        s2 = field(state, 1, 26) / 4096.0
        c1 = 2 * cos(2 * pi * GOERTZEL_F[bin_] / FS)
        return sqrt(max(s1 * s1 + s2 * s2 - c1 * s1 * s2, 0.0)), flags, peak, state

    def dft_mag(bin_, samples):
        w = 2 * pi * GOERTZEL_F[bin_] / FS
        re = sum(v * cos(w * n) for n, v in enumerate(samples))
        im = sum(v * sin(w * n) for n, v in enumerate(samples))
        return sqrt(re * re + im * im)

    # (1) one pure tone per bin, block of 32 at one sixteenth of full scale --
    # low enough that neither the 26-bit accumulator nor the 12-bit energy
    # proxy rails, so every magnitude below is earned rather than clamped.
    for i in range(8):
        tone = [round(64 * cos(2 * pi * GOERTZEL_F[i] * n / FS)) for n in range(32)]
        got, flags, _, _ = gblock(i, tone)
        want = dft_mag(i, tone)
        assert flags == 0 and abs(got - want) <= 1 + 0.002 * want, (i, got, want)
        checks += 1
    # (2) every bin of an off-grid tone still lands on its own DFT value, which
    # proves the recursion is the DTFT and not a matched-filter accident.
    odd = [round(64 * cos(2 * pi * 900 * n / FS)) for n in range(40)]
    for i in range(8):
        got, _, _, _ = gblock(i, odd)
        want = dft_mag(i, odd)
        assert abs(got - want) <= 1 + 0.002 * want, (i, got, want)
        checks += 1
    # (3) full dual-tone decode over the Q.23 plan: 64 samples per block, both
    # tones at 35 so that nothing rails, and the decision is the two bin
    # magnitudes above.  A wrong c1 list, a wrong shift list or an s2 that is
    # not the true s(n-2) all break the argmax pairing.
    rows = GOERTZEL_F[:4]
    cols = GOERTZEL_F[4:]
    plan = (('1', '2', '3', 'A'), ('4', '5', '6', 'B'),
            ('7', '8', '9', 'C'), ('*', '0', '#', 'D'))
    for a, low_f in enumerate(rows):
        for b, high_f in enumerate(cols):
            block = [round(35 * (cos(2 * pi * low_f * n / FS)
                                 + cos(2 * pi * high_f * n / FS)))
                     for n in range(64)]
            mags = [gblock(i, block) for i in range(8)]
            assert not any(m[1] for m in mags), plan[a][b]      # no rails
            mag = [m[0] for m in mags]
            for i in range(8):
                want = dft_mag(i, block)
                assert abs(mag[i] - want) <= 1 + 0.002 * want, (plan[a][b], i)
            li = max(range(4), key=lambda i: mag[i])
            hi = max(range(4, 8), key=lambda i: mag[i])
            assert (li, hi) == (a, 4 + b), (plan[a][b], li, hi)
            rival = max(max(mag[i] for i in range(4) if i != li),
                        max(mag[i] for i in range(4, 8) if i != hi))
            assert min(mag[li], mag[hi]) > 1.5 * rival, (plan[a][b], mag)
            checks += 3
    # (4) no tone and single tone are refused: silence gives exactly zero
    # magnitude in all eight bins, and one tone alone leaves the other group
    # more than 3 dB down, so a two-of-two decoder never fires on it.
    quiet = [gblock(i, [0] * 64) for i in range(8)]
    assert all(m[0] == 0 and m[2] == 0 and m[1] == 0 for m in quiet)
    checks += 1
    for a, only in enumerate(rows):
        block = [round(40 * cos(2 * pi * only * n / FS)) for n in range(64)]
        mag = [gblock(i, block)[0] for i in range(8)]
        assert max(mag[4:]) * 3 < max(mag[:4]), (only, mag)
        checks += 1
    for a, only in enumerate(cols):
        block = [round(40 * cos(2 * pi * only * n / FS)) for n in range(64)]
        mag = [gblock(i, block)[0] for i in range(8)]
        assert max(mag[:4]) * 3 < max(mag[4:]), (only, mag)
        checks += 1
    # (5) the reported proxy is exactly what the spec says, (|s(n)|+|s(n-1)|)
    # rounded to half-magnitude units and clamped, so an over-range block flags
    # instead of wrapping: three full-scale DC beats into bin 0 rail it.
    state = 0
    for k in range(3):
        r, x, f, state = step('goertzel_dtmf', 2047, 0,
                              (1 << 31) if k == 0 else 0, state)
    assert (f, r) == (1, 2047) and (x >> 16 & 0xfff) == 2047
    assert field(state, 0, 26) == (1 << 25) - 1, hex(state)   # clamped, not wrapped
    checks += 2

    # --- quadratic interpolation is exact on a parabola ------------------------
    # Three samples of x(n) = 16n^2 + 4n - 100 sit at n = -1, 0, 1.  The 3-point
    # Lagrange weights at mu are w0 = -mu(1-mu)/2, w1 = (1+mu)(1-mu),
    # w2 = mu(1+mu)/2, and at mu = 0, 1/4, 1/2, 3/4 the interpolant is
    # -100, -98, -94, -88: all integers, so an exact quadratic must hit them
    # with zero error, not approximately.
    y0, y1, y2 = -88, -100, -80
    word = (y0 & 0xff) | ((y1 & 0xff) << 8) | ((y2 & 0xff) << 16)
    exact = (-100, -98, -94, -88)
    for phase, mu in enumerate((Fr(0), Fr(1, 4), Fr(1, 2), Fr(3, 4))):
        w0, w1, w2 = (-mu * (1 - mu) / 2, (1 + mu) * (1 - mu), mu * (1 + mu) / 2)
        value = w0 * y0 + w1 * y1 + w2 * y2
        assert value == exact[phase], (phase, value)
        assert (w0 + w1 + w2) == 1                     # partition of unity
        r, x, f, _ = step('poly2_interp', word, word, phase | (phase << 2))
        assert (s_bits(r & 0xff, 8), s_bits(r >> 8, 8)) == (int(value),) * 2
        assert f == 0 and (x & 3) == 0                 # no lane clamped
        checks += 3
    # A straight line is a special case of the parabola, so the same weights on
    # (-60, -20, 20) have to reproduce -20 + 40*mu exactly.
    lin = (-60, -20, 20)
    lword = sum((v & 0xff) << 8 * k for k, v in enumerate(lin))
    for phase, mu in enumerate((Fr(0), Fr(1, 4), Fr(1, 2), Fr(3, 4))):
        r, _, f, _ = step('poly2_interp', lword, lword, phase | (phase << 2))
        want = -20 + 40 * mu
        assert f == 0 and want.denominator == 1
        assert s_bits(r & 0xff, 8) == int(want), (phase, r, float(want))
        checks += 2
    # ...and the documented half-sample weights really are (-1/8, 3/4, 3/8).
    assert (Fr(POLY2_Q14[2][0], 16384) == -Fr(1, 8)
            and Fr(POLY2_Q14[2][1], 16384) == Fr(3, 4)
            and Fr(POLY2_Q14[2][2], 16384) == Fr(3, 8))
    checks += 1

    # --- Karplus-Strong: loop gain, pitch and initialised taps ----------------
    # The documented loop is y(n) = (1 - 2^-E)(y(n-1) + y(n-M))/2 + x(n).  A
    # separate ring model built here from that sentence (and nothing else) has to
    # match the core beat for beat, which also proves the core never reads a tap
    # it has not written or zeroed, because every cell of the model starts at 0.
    def ks_run(sel, beats, excite):
        m = 4 * ((sel & 3) + 1)
        e = 4 if (sel >> 2) & 1 else 7
        line = [0] * m
        state = 0
        prev = 0
        pos = 0
        out = []
        wraps = []
        for n in range(beats):
            v = excite(n)
            r, x, f, state = step('karplus_strong', v & 0xfff, 0,
                                  sel | ((1 << 31) if n == 0 else 0), state)
            s = 0 if n == 0 else prev + line[pos]
            fb = ((s - (s >> e)) >> 1) + v
            want = clamp(fb, -2048, 2047)
            assert s12(r) == want and f == int(fb != want), (sel, n, s12(r), want)
            assert (x & 0xf) == (0 if pos + 1 >= m else pos + 1), (sel, n, hex(x))
            line[pos] = want
            if (x & 0xf) == 0 and n:
                wraps.append(n)
            pos = 0 if pos + 1 >= m else pos + 1
            prev = want
            out.append(want)
        return m, e, out, wraps

    for sel in range(8):
        m, e, out, wraps = ks_run(sel, 400, lambda n: 1800 if n == 0 else 0)
        assert set(b - a for a, b in zip(wraps, wraps[1:])) == {m}, (sel, m)
        peaks = [max(abs(v) for v in out[k:k + m]) for k in range(m, len(out), m)]
        assert all(a >= b for a, b in zip(peaks, peaks[1:])), (sel, peaks[:4])
        assert peaks[0] > peaks[-1] > 0, (sel, peaks[0], peaks[-1])
        checks += 3
    # Loop gain (1 - 2^-E) is strictly below unity, which is the only reason the
    # string decays at all: c[2] selects E = 4 (bright) or E = 7 (dark), so the
    # bright tap must die out measurably faster than the dark one at the same M,
    # and its per-period peak ratio has to sit inside (0, 1).
    for ln in range(4):
        m, eb, out, _ = ks_run(ln | 4, 400, lambda n: 1800 if n == 0 else 0)
        _, ed, dark, _ = ks_run(ln, 400, lambda n: 1800 if n == 0 else 0)
        assert eb == 4 and ed == 7 and abs(out[-1]) < abs(dark[-1]), (ln, out[-1], dark[-1])
        gp = [max(abs(v) for v in out[k:k + m]) for k in range(m, len(out), m)]
        ratio = max(gp[1:9]) / max(gp[:8])
        assert 0 < ratio < 1 - 2 ** -(eb + 1), (ln, eb, ratio)
        gd = [max(abs(v) for v in dark[k:k + m]) for k in range(m, len(dark), m)]
        assert max(gd[1:9]) / max(gd[:8]) > ratio, (ln, gd[8], gd[9])
        checks += 3
    # Pitch is fs/M: the four documented loop lengths are 4, 8, 12 and 16 cells
    # at fs = 8000, i.e. 2000, 1000, 666 and 500 Hz.  Integer check on the same
    # division the spec quotes.
    assert 8000 // 4 == 2000 and 8000 // 8 == 1000
    assert 8000 // 12 == 666 and 8000 // 16 == 500
    checks += 2

    # --- envelope: monotone peak follower with a geometric release ------------
    # Documented: attack is instant (the Q8 envelope jumps to |x|<<8 whenever
    # that is above the stored value) and release is e <- e - (e >> K), which is
    # a geometric series with the exact ratio (2^K - 1)/2^K per beat.  Recompute
    # it in rationals here and compare, sample after sample.
    for k_exp, kk in ((0, 1), (1, 2), (3, 4), (7, 8)):
        state = 0
        e = 0
        peak = 0
        trend = []
        v = [900, 700, 500, 300, 150, 80, 40, 20, 10, 5] * 3
        for n in range(30):
            x_in = v[n]
            r, x, f, state = step('envelope_ar', x_in, 0,
                                  k_exp | ((1 << 31) if n == 0 else 0), state)
            nxt = field(state, 0, 20)
            want = x_in << 8 if (x_in << 8) > e else e - (e >> kk)
            assert nxt == want and f == 0, (k_exp, n, nxt, want)
            peak = max(peak, x_in << 8)
            assert 0 <= nxt <= peak, (k_exp, n)            # never overshoots
            assert nxt >> 8 == s12(r), (k_exp, n, s12(r))  # reported level
            if (x_in << 8) <= e:
                trend.append(nxt)
                assert all(a >= b for a, b in zip(trend, trend[1:])), (k_exp, trend)
            else:
                trend = [nxt]                              # attack resets the trend
            e = nxt
            checks += 2
        # One release beat removes exactly 1/2^K of the stored envelope.
        assert (1 << 20) - ((1 << 20) >> kk) == ((2 ** kk - 1) * (1 << 20)) >> kk
        checks += 1
    # Release is a geometric series with ratio (2^K - 1)/2^K, bracketed here in
    # exact rationals rather than by re-running the recurrence: writing the
    # stored value as e = q*2^K + s (0 <= s < 2^K), the beat gives
    # e_next = e - q = r*e + s/2^K, so r*e <= e_next < r*e + 1 and by induction
    # 25600*r^n <= e_n < 25600*r^n + 2^K.  The lower half of that band fails if
    # the release subtracts too much, the upper half if it subtracts too little,
    # and the stall rule below is the documented one: e - (e >> K) can only hold
    # its value once e < 2^K, so a Q8 envelope never decays to zero.
    for k_exp, kk in ((0, 1), (1, 2), (3, 4), (6, 7), (7, 8)):
        st = 25600
        prev = 25600
        ratio = Fr(2 ** kk - 1, 2 ** kk)
        for n in range(1, 41):
            r, _, f, st = step('envelope_ar', 0, 0, k_exp, st)
            ideal = Fr(25600) * ratio ** n
            assert f == 0 and ideal <= st < ideal + 2 ** kk, (kk, n, st, float(ideal))
            assert (st == prev) == (prev < (1 << kk)), (kk, n, prev, st)
            prev = st
        checks += 2
    # Hold freezes the decay: with c[3] set the envelope is bit-identical over
    # silent beats, so a latched peak meter never drifts down while it is held.
    state = step('envelope_ar', 1500, 0, (1 << 31) | 8 | 2, 0)[3]
    held = field(state, 0, 20)
    for _ in range(6):
        state = step('envelope_ar', 0, 0, 8 | 2, state)[3]
    assert field(state, 0, 20) == held and held == 1500 << 8
    checks += 2
    # A step up attacks in a single beat (documented instant attack, not a ramp),
    # so the meter cannot lag the signal it is supposed to be showing.
    r, _, f, state = step('envelope_ar', 0, 0, 8 | 2, state)
    r, _, f, state = step('envelope_ar', 1800, 0, 8 | 2, state)
    assert s12(r) == 1800 and field(state, 0, 20) == 1800 << 8
    checks += 1

    # --- TDM8: slot placement, per-frame lock, misaligned and over-long frames -
    # The eight channels live in eight 16-bit fields of the state, so reading
    # field s back after a frame has to give exactly what slot s carried.
    frame = (-100, 200, -300, 400, -500, 600, -700, 800)
    state = 0
    for s, v in enumerate(frame):
        r, x, f, state = step('tdm8_demux', v, 0,
                               s | ((1 << 31) if s == 0 else 0), state)
        assert s_bits((state >> (16 * s)) & 0xffff, 16) == v, (s, v)
        assert (r & 0xffff) == (v & 0xffff) and f == 0, (s, r, f)
        assert ((x >> 16) & 0xff) == (1 << (s + 1)) - 1, (s, hex(x))
        assert ((x >> 29) & 1) == int(s == 7), (s, hex(x))
        checks += 2
    # Lock is per frame: a second clean frame re-locks only on its own slot 7,
    # so the flag cannot go stale after one good frame.
    for s, v in enumerate(frame):
        r, x, f, state = step('tdm8_demux', v + 1, 0,
                              s | ((1 << 31) if s == 0 else 0), state)
        assert ((x >> 29) & 1) == int(s == 7) and f == 0, (s, hex(x))
        checks += 1
    # A frame that repeats a slot index inside itself (over-length) or skips one
    # (misaligned) raises the sequence fault and cannot claim lock.
    state = 0
    for s, v in ((0, 10), (1, 20), (2, 30), (5, 40)):
        r, x, f, state = step('tdm8_demux', v, 0,
                               s | ((1 << 31) if s == 0 else 0), state)
    assert (f, (x >> 28) & 1, (x >> 29) & 1) == (1, 1, 0)
    checks += 1
    state = 0
    for s, v in ((0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7), (7, 8), (7, 9)):
        r, x, f, state = step('tdm8_demux', v, 0,
                              s | ((1 << 31) if s == 0 else 0), state)
    assert (f, (x >> 28) & 1) == (1, 1)                # a 9th slot is misaligned
    assert s_bits((state >> (16 * 7)) & 0xffff, 16) == 9
    checks += 2
    return checks


# --------------------------------------------------------------------------
# 2. biquad_df2_s12 -- Transposed Direct Form II, two hardwired Q14 sections.
# --------------------------------------------------------------------------
# State holds the two Q14 delay accumulators in 32-bit fields, so every internal
# node has headroom even when the s12 output is clamped at a rail:
#   P0 lowpass, exact DC gain 2
#        b = 0.15625, 0.3125, 0.15625   (Q14 2560, 5120, 2560; sum 10240 = 0.625)
#        -a1 = +1.0625 (2^14+2^10), -a2 = -0.375 (-(2^13)+2^11)
#     denominator 1-1.0625+0.375 = 0.3125, so DC gain = 0.625/0.3125 = 2 exactly.
#     Poles are the roots of z^2 - 1.0625z + 0.375, radius sqrt(0.375) = 0.612.
#     A DC input of 1000 therefore has the exact fixed point 2000, and 1500 wants
#     3000, which must clamp to the 2047 rail with the fault raised.
#   P1 DC blocker          b = 0.5, -0.5, 0   -a1 = +0.5   -a2 = 0
BIQUAD_DF2_BODY = '''
xin = $signed(a[11:0]);
s1 = c[31] ? 64'sd0 : $signed(state_r[31:0]);
s2 = c[31] ? 64'sd0 : $signed(state_r[63:32]);
if (c[0]) begin
    acc = (xin<<<13) + s1;
end else begin
    acc = (xin<<<11) + (xin<<<9) + s1;
end
acc = (acc + 64'sd8192) >>> 14;
cl = (acc > 64'sd2047) || (acc < -64'sd2048);
ys = acc > 64'sd2047 ? 12'h7ff : (acc < -64'sd2048 ? 12'h800 : acc[11:0]);
yv = acc > 64'sd2047 ? 64'sd2047 : (acc < -64'sd2048 ? -64'sd2048 : acc);
if (c[0]) begin
    n1 = -(xin<<<13) + (yv<<<13) + s2;
    n2 = 64'sd0;
end else begin
    n1 = (xin<<<12) + (xin<<<10) + (yv<<<14) + (yv<<<10) + s2;
    n2 = (xin<<<11) + (xin<<<9) - (yv<<<13) + (yv<<<11);
end
bad = (c[30:2] != 0) || (c[1:0] > 1);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    r = {{20{ys[11]}}, ys};
    x[15:0] = s1[15:0];
    x[31:16] = s2[15:0];
    f = cl;
    state_n = 0;
    state_n[31:0] = n1[31:0];
    state_n[63:32] = n2[31:0];
end'''

BIQUAD_DF2_DECL = ('reg signed [63:0] xin, s1, s2, acc, yv, n1, n2;\n'
                   'reg [11:0] ys;\nreg cl, bad;')

core('biquad_df2_s12',
     'Transposed Direct Form II biquad, one s12 sample per accepted beat. a[11:0] is '
     'the input; c[1:0] selects P0 lowpass with exact DC gain 2 or P1 DC blocker '
     '(values 2 and 3 are malformed); c[31] zeroes both Q14 delay registers before this beat; '
     'c[30:2] must be zero. result = sign-extended s12 clamp of '
     'round((d0*x + s1)/16384). aux[15:0] and aux[31:16] echo the low 16 bits of the '
     'incoming delay registers s1 and s2. fault = output clamp or malformed control.',
     BIQUAD_DF2_BODY,
     'The two Q14 state registers fold the whole IIR recursion into one beat: the '
     'new s1 needs the clamped output of the same beat, which a software loop pays '
     'for with a reload; here it is one combinational chain at II=1.',
     1, BIQUAD_DF2_DECL, stateful=True)
# --------------------------------------------------------------------------
# 3. biquad_cascade_step -- two sections in series inside one accepted beat.
# --------------------------------------------------------------------------
# Stage 1 is the exact-gain-2 lowpass used by biquad_df2_s12 (b = 2560,5120,2560;
# d1 = +1.0625; d2 = -0.375 in Q14), stage 2 is the 0.5/0.5 DC blocker.  c[0]
# bypasses stage 2.  The cascade DC gain is therefore 2 * 0 = 0: a settled DC
# input leaves stage 1 at exactly twice the input and drives the output to zero.
CASCADE_BODY = '''
xin = $signed(a[11:0]);
px1 = c[31] ? 64'sd0 : $signed(state_r[11:0]);
px2 = c[31] ? 64'sd0 : $signed(state_r[23:12]);
py1 = c[31] ? 64'sd0 : $signed(state_r[35:24]);
py2 = c[31] ? 64'sd0 : $signed(state_r[47:36]);
qx1 = c[31] ? 64'sd0 : $signed(state_r[59:48]);
qo1 = c[31] ? 64'sd0 : $signed(state_r[71:60]);
acc = (xin<<<11) + (xin<<<9) + (px1<<<12) + (px1<<<10) + (px2<<<11) + (px2<<<9)
      + (py1<<<14) + (py1<<<10) - (py2<<<13) + (py2<<<11);
acc = (acc + 64'sd8192) >>> 14;
c1 = (acc > 64'sd2047) || (acc < -64'sd2048);
ys = acc > 64'sd2047 ? 12'h7ff : (acc < -64'sd2048 ? 12'h800 : acc[11:0]);
yv = acc > 64'sd2047 ? 64'sd2047 : (acc < -64'sd2048 ? -64'sd2048 : acc);
acc2 = c[0] ? (yv<<<14) : ((yv<<<13) - (qx1<<<13) + (qo1<<<13));
acc2 = (acc2 + 64'sd8192) >>> 14;
c2 = (acc2 > 64'sd2047) || (acc2 < -64'sd2048);
zs = acc2 > 64'sd2047 ? 12'h7ff : (acc2 < -64'sd2048 ? 12'h800 : acc2[11:0]);
bad = (c[30:1] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    r = {{20{zs[11]}}, zs};
    x[11:0] = ys;
    x[12] = c1;
    x[13] = c2;
    x[14] = c[0];
    x[15] = c[31];
    f = c1 | c2;
    state_n = 0;
    state_n[11:0] = a[11:0];
    state_n[23:12] = state_r[11:0];
    state_n[35:24] = ys;
    state_n[47:36] = state_r[35:24];
    state_n[59:48] = ys;
    state_n[71:60] = zs;
end'''

CASCADE_DECL = ('reg signed [63:0] xin, px1, px2, py1, py2, qx1, qo1, acc, acc2, yv;\n'
                'reg [11:0] ys, zs;\nreg c1, c2, bad;')

core('biquad_cascade_step',
     'Two-section cascade stepped in one accepted beat. a[11:0] is the s12 input; '
     'section 1 is a Q14 lowpass with exact DC gain 2, section 2 is the 0.5/0.5 DC '
     'blocker and is bypassed when c[0]=1. c[31] zeroes all six 12-bit history fields '
     'before this beat; c[30:1] must be zero. result = sign-extended s12 clamp of '
     'section 2 (or of section 1 when bypassed). aux[11:0] = section-1 output, '
     'aux[12] = section-1 clamped, aux[13] = section-2 clamped, aux[14] = bypass, '
     'aux[15] = restart. fault = either section clamped, or malformed control.',
     CASCADE_BODY,
     'Two biquad sections in series normally cost two memory round-trips per sample; '
     'here section 2 consumes the clamped section-1 result in the same beat at II=1, '
     'and each section reports its own clamp bit.',
     1, CASCADE_DECL, stateful=True)
# --------------------------------------------------------------------------
# 4. poly2_interp -- two-lane second-order (3-tap) fractional interpolation.
# --------------------------------------------------------------------------
# Three s8 samples per lane are interpolated with the exact 3-point Lagrange
# weights at mu = 0, 1/4, 1/2, 3/4, in Q14:
#   mu=0    ( 0,      16384,  0     ) = (0, 1, 0)
#   mu=1/4  (-1536,   15360,  2560 ) = (-3/32, 15/16, 5/32)
#   mu=1/2  (-2048,   12288,  6144 ) = (-1/8,  3/4,   3/8)
#   mu=3/4  (-1536,   7168,   10752) = (-3/32, 7/16,  21/32)
# Every triple sums to 16384, so the interpolator has unity DC gain and a flat
# input reproduces itself exactly.  Each weight is emitted as signed powers of
# two, which is why no `*` appears in the kernel.
POLY2_Q14 = {0: (0, 16384, 0), 1: (-1536, 15360, 2560), 2: (-2048, 12288, 6144),
             3: (-1536, 7168, 10752)}
POLY2_TERMS = {0: ((1, 14, 1),),
               1: ((0, 10, -1), (0, 9, -1), (1, 14, 1), (1, 10, -1),
                   (2, 11, 1), (2, 9, 1)),
               2: ((0, 11, -1), (1, 13, 1), (1, 12, 1), (2, 13, 1), (2, 11, -1)),
               3: ((0, 10, -1), (0, 9, -1), (1, 13, 1), (1, 10, -1), (2, 13, 1),
                   (2, 11, 1), (2, 9, 1))}

POLY2_BODY = '''
bad = (c[31:4] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
end else begin
    for (lane = 0; lane < 2; lane = lane + 1) begin
        v = (lane == 0) ? a : b;
        pht = (lane == 0) ? c[1:0] : c[3:2];
        y0 = $signed(v[7:0]);
        y1 = $signed(v[15:8]);
        y2 = $signed(v[23:16]);
        case (pht)
            2'd0: acc = (y1<<<14);
            2'd1: acc = -(y0<<<10) - (y0<<<9) + (y1<<<14) - (y1<<<10)
                       + (y2<<<11) + (y2<<<9);
            2'd2: acc = -(y0<<<11) + (y1<<<13) + (y1<<<12)
                       + (y2<<<13) - (y2<<<11);
            2'd3: acc = -(y0<<<10) - (y0<<<9) + (y1<<<13) - (y1<<<10)
                       + (y2<<<13) + (y2<<<11) + (y2<<<9);
        endcase
        acc = (acc + 64'sd8192) >>> 14;
        cl = (acc > 64'sd127) || (acc < -64'sd128);
        cl8 = acc > 64'sd127 ? 8'h7f : (acc < -64'sd128 ? 8'h80 : acc[7:0]);
        r[(lane << 3) +: 8] = cl8;
        x[lane] = cl;
        x[(8 + (lane << 3)) +: 8] = acc[7:0];
        f = f | cl;
    end
end'''

POLY2_DECL = ('reg signed [63:0] y0, y1, y2, acc;\n'
              'reg [31:0] v;\nreg [1:0] pht;\nreg [7:0] cl8;\nreg cl, bad;')

core('poly2_interp',
     'Two independent 3-tap quadratic interpolators per accepted beat. Lane 0 reads '
     's8 samples from a[7:0], a[15:8], a[23:16] and uses phase c[1:0]; lane 1 reads '
     'b[7:0], b[15:8], b[23:16] and uses phase c[3:2]; the phase selects mu = 0, 1/4, '
     '1/2, 3/4 exact Lagrange weights in Q14. a[31:24] and b[31:24] are ignored and '
     'c[31:4] must be zero. result[7:0] and result[15:8] are the s8 clamped lane '
     'outputs, aux[1:0] = per-lane clamp flags, aux[15:8] and aux[23:16] = the '
     'pre-clamp rounded values. fault = any lane clamped or malformed control.',
     POLY2_BODY,
     'A fractional delay line wants one weighted 3-tap interpolation per output '
     'sample per channel: two lanes retire every enabled beat at II=1 with no '
     'multiplier and no coefficient load, where software needs a multiply per tap.',
     2, POLY2_DECL)
# --------------------------------------------------------------------------
# 5. cic_comp_s12 -- 2-stage CIC decimator with shift-only gain compression.
# --------------------------------------------------------------------------
# Pure accumulate/difference/filter: no coefficient multiply anywhere.  For a
# constant input v the second integrator is the partial sum v*(k+1)(k+2)/2 after
# beat k, so with R=8 the first group (beat 7) differs to 36v, the second group
# (beat 15) to 100v-36v = 64v = R^N * v exactly, and the >>6 compensation then
# reproduces v with no rounding error.  R=4 gives 10v then 16v and a >>4.
# The four 20-bit nodes saturate and raise their own overflow flag, because a
# DC run longer than the accumulator range must report overload, not wrap.
CIC_BODY = '''
xin = $signed(a[11:0]);
l2 = c[2:0];
msk = (3'd1 << l2) - 3'd1;
gsh = {l2, 1'b0};
oldph = c[31] ? 3'd0 : state_r[82:80];
i1 = c[31] ? 64'sd0 : $signed(state_r[19:0]);
i2 = c[31] ? 64'sd0 : $signed(state_r[39:20]);
d1 = c[31] ? 64'sd0 : $signed(state_r[59:40]);
d2 = c[31] ? 64'sd0 : $signed(state_r[79:60]);
w3 = 20'd0;
t3 = 64'sd0;
t4 = 64'sd0;
yv = 64'sd0;
ov = 5'd0;
fin = (oldph == msk);
phn = (oldph + 3'd1) & msk;
t1 = i1 + xin;
n1v = (t1 > 64'sd524287) ? 20'h7ffff : ((t1 < -64'sd524288) ? 20'h80000 : t1[19:0]);
t2 = i2 + $signed(n1v);
n2v = (t2 > 64'sd524287) ? 20'h7ffff : ((t2 < -64'sd524288) ? 20'h80000 : t2[19:0]);
ov[0] = (t1 > 64'sd524287) || (t1 < -64'sd524288);
ov[1] = (t2 > 64'sd524287) || (t2 < -64'sd524288);
if (fin) begin
    t3 = $signed(n2v) - d1;
    w3 = (t3 > 64'sd524287) ? 20'h7ffff : ((t3 < -64'sd524288) ? 20'h80000 : t3[19:0]);
    t4 = $signed(w3) - d2;
    yv = (t4 + (64'sd1 <<< (gsh - 4'd1))) >>> gsh;
    ov[2] = (t3 > 64'sd524287) || (t3 < -64'sd524288);
    ov[3] = (t4 > 64'sd524287) || (t4 < -64'sd524288);
    ov[4] = (yv > 64'sd2047) || (yv < -64'sd2048);
    h12 = (yv > 64'sd2047) ? 12'h7ff : ((yv < -64'sd2048) ? 12'h800 : yv[11:0]);
end else begin
    h12 = state_r[95:84];
end
bad = (c[30:3] != 0) || (l2 < 2) || (l2 > 3);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    r = {{20{h12[11]}}, h12};
    x[4:0] = ov;
    x[5] = fin;
    x[8:6] = phn;
    x[28:9] = n1v;
    f = (ov != 0);
    state_n = 0;
    state_n[19:0] = n1v;
    state_n[39:20] = n2v;
    state_n[59:40] = fin ? n2v : state_r[59:40];
    state_n[79:60] = fin ? w3 : state_r[79:60];
    state_n[82:80] = phn;
    state_n[95:84] = h12;
end'''

CIC_DECL = (
    'reg signed [63:0] xin, i1, i2, d1, d2, t1, t2, t3, t4, yv;\n'
    'reg [19:0] n1v, n2v, w3;\n'
    'reg [11:0] h12;\n'
    'reg [2:0] l2, msk, oldph, phn;\n'
    'reg [3:0] gsh;\n'
    'reg [4:0] ov;\n'
    'reg fin, bad;')

core('cic_comp_s12',
     'Two-stage cascaded integrator-comb decimator, one s12 sample per accepted beat. '
     'c[2:0] is log2(R) and must be 2 or 3 (R = 4 or 8); c[31] restarts the filter by '
     'zeroing both integrators, both comb delays and the phase counter before this '
     'beat; c[30:3] must be zero. result = sign-extended s12 clamp of the most recent '
     'completed group divided by R^2 using a shift. aux[4:0] = overflow flags for '
     'integrator 1, integrator 2, comb 1, comb 2 and the s12 output clamp, aux[5] = a '
     'group completed on this beat, aux[8:6] = next phase, aux[28:9] = the new first '
     'integrator. fault = any overflow flag or malformed control.',
     CIC_BODY,
     'A CIC decimator is pure add/difference/filter: this retires one input sample '
     'per enabled beat with no multiplier and no ROM, and the R^2 gain compensation '
     'is a single variable shift, which a software decimator cannot do per sample at '
     'II=1.', 1, CIC_DECL, stateful=True)
# --- core 6: goertzel_dtmf ------------------------------------------------ #
# Published anchor: the eight DTMF tones of ITU-T Q.23 at fs = 8000 Hz.
GOERTZEL_F = (697, 770, 852, 941, 1209, 1336, 1477, 1633)
# c1 = 2*cos(2*pi*f/fs) in Q14 (round-to-nearest), rebuilt and checked against
# math.cos inside selftest() so the pasted shift lists can never drift.
GOERTZEL_Q14 = (27980, 26956, 25701, 24219, 19073, 16325, 13085, 9315)
# Signed power-of-two (non-adjacent) expansion of each Q14 constant:
# (shift, sign) terms, sum( sign * 2**shift ) == GOERTZEL_Q14[i].
GOERTZEL_NAF = (
    ((2, -1), (4, 1), (6, 1), (8, 1), (10, -1), (12, -1), (15, 1)),
    ((2, -1), (4, 1), (6, 1), (8, 1), (11, 1), (13, -1), (15, 1)),
    ((0, 1), (2, 1), (5, -1), (7, 1), (10, 1), (13, -1), (15, 1)),
    ((0, -1), (2, -1), (5, 1), (7, 1), (9, -1), (13, -1), (15, 1)),
    ((0, 1), (7, 1), (9, 1), (11, 1), (14, 1)),
    ((0, 1), (2, 1), (6, -1), (14, 1)),
    ((0, 1), (2, -1), (5, 1), (8, -1), (10, 1), (12, -1), (14, 1)),
    ((0, -1), (2, 1), (5, -1), (7, 1), (10, 1), (13, 1)),
)

GOERTZEL_BODY = '''
bad = (c[30:3] != 0) || ((c[2:0] != state_r[54:52]) && (c[31] == 1'b0));
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    s1 = c[31] ? 64'sd0 : $signed(state_r[25:0]);
    s2 = c[31] ? 64'sd0 : $signed(state_r[51:26]);
    xin = $signed({{20{a[11]}}, a[11:0]});
    acc = (xin <<< 26);
    case (c[2:0])
        3'd0: acc = acc + (s1 <<< 15) - (s1 <<< 12) - (s1 <<< 10)
                    + (s1 <<< 8) + (s1 <<< 6) + (s1 <<< 4) - (s1 <<< 2);
        3'd1: acc = acc + (s1 <<< 15) - (s1 <<< 13) + (s1 <<< 11)
                    + (s1 <<< 8) + (s1 <<< 6) + (s1 <<< 4) - (s1 <<< 2);
        3'd2: acc = acc + (s1 <<< 15) - (s1 <<< 13) + (s1 <<< 10)
                    + (s1 <<< 7) - (s1 <<< 5) + (s1 <<< 2) + (s1 <<< 0);
        3'd3: acc = acc + (s1 <<< 15) - (s1 <<< 13) - (s1 <<< 9)
                    + (s1 <<< 7) + (s1 <<< 5) - (s1 <<< 2) - (s1 <<< 0);
        3'd4: acc = acc + (s1 <<< 14) + (s1 <<< 11) + (s1 <<< 9)
                    + (s1 <<< 7) + (s1 <<< 0);
        3'd5: acc = acc + (s1 <<< 14) - (s1 <<< 6) + (s1 <<< 2) + (s1 <<< 0);
        3'd6: acc = acc + (s1 <<< 14) - (s1 <<< 12) + (s1 <<< 10)
                    - (s1 <<< 8) + (s1 <<< 5) - (s1 <<< 2) + (s1 <<< 0);
        default: acc = acc + (s1 <<< 13) + (s1 <<< 10) + (s1 <<< 7)
                    - (s1 <<< 5) + (s1 <<< 2) - (s1 <<< 0);
    endcase
    acc = acc - (s2 <<< 14);
    sv = (acc + 64'sd8192) >>> 14;
    oaa = (sv > 64'sd33554431) || (sv < -64'sd33554431);
    sn1 = (sv > 64'sd33554431) ? 26'sd33554431 :
          (sv < -64'sd33554431) ? -26'sd33554431 : sv[25:0];
    sn2 = c[31] ? 26'd0 : state_r[25:0];
    e1 = sn1[25] ? ((~sn1) + 26'd1) : sn1;
    e2 = sn2[25] ? ((~sn2) + 26'd1) : sn2;
    hv = ((e1 + e2) + 32'd4096) >>> 13;
    oee = hv > 32'd2047;
    r = (oee ? 12'd2047 : hv[11:0]);
    x = {1'b0, c[2:0], e1[25:14], e2[25:14], oee, oaa, 1'b0, c[31]};
    f = oaa || oee;
    state_n = {1'b0, c[2:0], sn2, sn1};
end'''

GOERTZEL_DECL = (
    'reg signed [63:0] s1, s2, xin, acc, sv;\n'
    'reg [25:0] sn1, sn2, e1, e2;\n'
    'reg [31:0] hv;\n'
    'reg oaa, oee, bad;')

core('goertzel_dtmf',
     'Goertzel tone recursion s(n) = x(n) + c1*s(n-1) - s(n-2) with '
     'c1 = 2*cos(2*pi*f/fs) for the eight ITU-T Q.23 DTMF tones (697/770/852/'
     '941/1209/1336/1477/1633 Hz at fs = 8000), selected by c[2:0]. Each c1 is '
     'a Q14 constant expanded into signed power-of-two shifts, so the core has '
     'no multiplier. The accumulator is Q12 in a 26-bit clamping field '
     '(+/-8191.99 signal units). a is one s12 sample per accepted beat; c[31] '
     'zeroes both accumulators before the beat and must accompany any bin '
     'change, which is otherwise flagged malformed together with the reserved '
     'bits c[30:3]. result = (|s(n)|+|s(n-1)|) rounded, in units of two signal '
     'magnitudes, as the energy proxy for the decision stage; 12-bit unsigned '
     'clamped at 2047 '
     '(zero-extended, not sign-extended: it is a magnitude). aux[30:28] = bin, '
     'aux[27:16] = |s(n)|>>14, aux[15:4] = |s(n-1)|>>14 (quarter signal '
     'units), aux[3] = energy clamp, aux[2] = accumulator clamp, aux[0] = the '
     'restart bit. '
     'fault = accumulator clamp | energy clamp | malformed control.',
     GOERTZEL_BODY,
     'A dual-tone detector usually costs two multipliers per bin and a window '
     'RAM; here every c1 is a shift-add list and the whole state is 56 flip '
     'flops, so eight tone bins fit in the LUTs next to the sample path and '
     'flag themselves the moment their accumulator rails, with no DSP slice '
     'and no block RAM occupied.',
     1, GOERTZEL_DECL, stateful=True)

# --------------------------------------------------------------------------
# 7. karplus_strong -- plucked-string loop, 16 tap cells held in flip flops.
# --------------------------------------------------------------------------
# y(n) = (1 - 2^-E) * (y(n-1) + y(n-M)) / 2 + x(n), written exactly as the
# fabric needs it: one add for the two taps, one variable arithmetic shift for
# the 2^-E term, one shift by 1 for the average, one add for the excitation.
# The damping factor is the difference of a value and its own shifted copy, so
# there is no multiply anywhere -- and the tap address is a case map, so no
# address arithmetic becomes a multiplier either.
#   c[1:0] = loop length M: 4, 8, 12 or 16 cells (pitch fs/M at fs = 8000 Hz)
#   c[2]   = damping exponent E: 4 (bright, fast decay) or 7 (dark, slow decay)
#   c[30:3] reserved, any other combination is malformed
#   c[31]  = new pluck: clears the line, the pointer and the previous output
# State: cells [191:0] (12 bits per cell), previous output [203:192],
# pointer [207:204].
KS_READ = ''.join(f"        4'd{i}: dm = state_r[{12 * i + 11}:{12 * i}];\n"
                  for i in range(16))
KS_WRITE = ''.join(f"        4'd{i}: state_n[{12 * i + 11}:{12 * i}] = outv;\n"
                   for i in range(16))

KS_BODY = ('''
bad = (c[30:3] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    p = c[31] ? 4'd0 : state_r[207:204];
    case (c[1:0])
        2'd0: ll = 5'd4;
        2'd1: ll = 5'd8;
        2'd2: ll = 5'd12;
        default: ll = 5'd16;
    endcase
    ee = c[2] ? 5'd4 : 5'd7;
    nx = {1'b0, p} + 5'd1;
    pn = (nx >= ll) ? 4'd0 : nx[3:0];
    xv = $signed({{20{a[11]}}, a[11:0]});
    case (p)
''' + KS_READ + '''        default: dm = 12'd0;
    endcase
    d0v = $signed(state_r[203:192]);
    ssum = c[31] ? 64'sd0 : (d0v + $signed(dm));
    dsh = ssum >>> ee;
    fb = ((ssum - dsh) >>> 1) + xv;
    ovr = (fb > 64'sd2047) || (fb < -64'sd2048);
    outv = (fb > 64'sd2047) ? 12'h7ff :
           (fb < -64'sd2048) ? 12'h800 : fb[11:0];
    r = {{20{outv[11]}}, outv};
    x = {10'd0, fb[13:0], c[31], ovr, c[1:0], pn};
    f = ovr;
    state_n = c[31] ? 256'd0 : state_r;
    case (p)
''' + KS_WRITE + '''    endcase
    state_n[203:192] = outv;
    state_n[207:204] = pn;
end''')

KS_DECL = ('reg [11:0] dm, outv;\n'
           'reg [4:0] ll, ee, nx;\n'
           'reg [3:0] p, pn;\n'
           'reg signed [63:0] xv, d0v, ssum, dsh, fb;\n'
           'reg ovr, bad;')

core('karplus_strong',
     'Karplus-Strong plucked-string loop, one sample per accepted beat: '
     'y(n) = (1 - 2^-E) * (y(n-1) + y(n-M)) / 2 + x(n). a is the s12 excitation '
     'sample, c[1:0] selects the loop length M = 4/8/12/16 cells (pitch fs/M at '
     'fs = 8000 Hz), c[2] selects the damping exponent E = 4 or 7, c[31] starts '
     'a new pluck by clearing the 16-cell line, the pointer and the previous '
     'output (that beat rings from silence, its two-tap sum is forced to zero), '
     'and c[30:3] must be zero. result is the s12 clamped new cell '
     'value, sign extended. aux[3:0] = next pointer, aux[5:4] = M selector, '
     'aux[6] = output clamp, aux[7] = restart echo, aux[21:8] = the pre-clamp '
     'feedback value. fault = output clamped or malformed control.',
     KS_BODY,
     'A plucked-string voice normally wants a delay line in block RAM plus a '
     'multiply for the loop gain; here the 16x12 line is a case-mapped register '
     'file and the damping is a self-subtracted shifted copy, so a whole tone '
     'generator runs at II=1 with no BRAM, no DSP slice and no address '
     'multiply, leaving the memory blocks for everything else.',
     1, KS_DECL, stateful=True)
# --------------------------------------------------------------------------
# 8. dsm2_mod -- second-order 1-bit sigma-delta modulator (Class-D front end).
# --------------------------------------------------------------------------
# Canonical CIFB topology (Chao et al., IEEE TCAS 1990) with every coefficient
# equal to 1/2, i.e. exactly one arithmetic shift per term:
#     v(n)   = x2(n) + x1(n)/2                       comparator input
#     y(n)   = +2046 if v(n) >= 0 else -2046          1-bit DAC level
#     x1(n+1) = x1(n) + (x(n) - y(n))/2
#     x2(n+1) = x2(n) + x1(n)/2 - y(n)/2
# No multiplier appears anywhere: the loop coefficients are shifts, the DAC
# level is the constant 2046 (even, so y/2 = +/-1023 has no floor asymmetry)
# and the comparator is a sign test.  Both integrators are s12, i.e. exactly
# the +/-1.0 full-scale range a second-order CIFB needs to stay stable, so the
# clamp flag is the honest "the loop has left its stable range" warning.  A
# negative rail input does leave it (the floor shifts bias one LSB per step
# against the DAC), a half-scale input never does.
#   a     = s12 input sample (held for every oversampled sub-step of this beat)
#   c[1:0] = number of oversampled sub-steps per beat minus 1 (1..4)
#   c[30:2] reserved, any other combination is malformed
#   c[31]  = restart: both integrators are cleared before the beat
# State: x1 at [11:0], x2 at [23:12].
DSM_BODY = '''
bad = (c[30:2] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    ns = {2'd0, c[1:0]} + 3'd1;
    xin = $signed({{20{a[11]}}, a[11:0]});
    x1 = c[31] ? 64'sd0 : $signed(state_r[11:0]);
    x2 = c[31] ? 64'sd0 : $signed(state_r[23:12]);
    ov = 1'b0;
    cnt = 3'd0;
    pdm = 1'b0;
    for (i = 0; i < 4; i = i + 1) begin
        if (i < ns) begin
            v = x2 + (x1 >>> 1);
            pdm = (v >= 64'sd0);
            yd = pdm ? 64'sd2046 : -64'sd2046;
            cnt = cnt + {2'd0, pdm};
            t1 = x1 + ((xin - yd) >>> 1);
            t2 = x2 + (x1 >>> 1) - (yd >>> 1);
            x1n = (t1 > 64'sd2047) ? 12'h7ff :
                  ((t1 < -64'sd2048) ? 12'h800 : t1[11:0]);
            x2n = (t2 > 64'sd2047) ? 12'h7ff :
                  ((t2 < -64'sd2048) ? 12'h800 : t2[11:0]);
            ov = ov | (t1 > 64'sd2047) | (t1 < -64'sd2048)
                   | (t2 > 64'sd2047) | (t2 < -64'sd2048);
            x1 = $signed({{52{x1n[11]}}, x1n});
            x2 = $signed({{52{x2n[11]}}, x2n});
        end
    end
    r = pdm ? 32'sd2046 : -32'sd2046;
    x = {x2n, x1n, 2'b0, c[31], ov, cnt, pdm};
    f = ov;
    state_n[11:0] = x1n;
    state_n[23:12] = x2n;
end'''

DSM_DECL = ('reg signed [63:0] xin, x1, x2, v, yd, t1, t2;\n'
            'reg [11:0] x1n, x2n;\n'
            'reg [2:0] ns, cnt;\n'
            'reg pdm, ov, bad;')

core('dsm2_mod',
     'Second-order 1-bit sigma-delta modulator in the canonical CIFB topology '
     'with all loop coefficients equal to 1/2, so the whole noise-shaping loop '
     'is two shift-add integrators plus a sign test and no multiplier. a is the '
     's12 input; c[1:0] picks how many oversampled sub-steps (1..4) the beat '
     'retires with that same input, c[31] clears both integrators first, and '
     'c[30:2] must be zero. result is the 1-bit DAC level as +/-2046, sign '
     'extended. aux[0] = the last sub-step bit, aux[3:1] = how many of this '
     'beat\'s sub-steps went high, aux[4] = an integrator clamped (the loop '
     'left the s12 +/-1.0 full-scale stable range), aux[5] = restart echo, '
     'aux[19:8] and aux[31:20] = '
     'the new x1 and x2 integrator states in s12. fault = any '
     'integrator clamped or malformed control.',
     DSM_BODY,
     'One beat can retire up to four oversampled modulator steps through an '
     'unrolled shift-add loop, so a Class-D output bit stream at 1 MHz costs a '
     'quarter of the sample-rate budget in software; the loop needs no '
     'multiplier, no ROM and 32 bits of state, which is what makes 50 parallel '
     'modulators fit next to the rest of the audio path.',
     1, DSM_DECL, stateful=True)
# --------------------------------------------------------------------------
# 9. envelope_ar -- attack/release envelope follower with a meter range switch.
# --------------------------------------------------------------------------
# Hard attack, exponential release, peak-hold option, all in shift arithmetic:
#   mag = |x|                     (an absolute value, not x*x: a squaring
#                                  envelope would need a multiplier, and the
#                                  fabric $mul is off limits for this family)
#   e   = mag*256        if mag*256 > e      (instant attack, Q8 accumulator)
#         e - (e >> K)   otherwise           (release, K = c[2:0] + 1, 1..8)
#   e   = max(mag*256, e) when c[3] = 1      (peak hold, release disabled)
# The envelope is kept in Q8 (20 bits, up to 2^19 = 2048.0 signal units) so the
# release step keeps sub-LSB resolution; the reported level is e >> 8, scaled
# by the meter range c[5:4] as a shift (x1, x2, x4, x8) and clamped to s12.
# Two documented fixed-point truths the tests pin down: a magnitude can be one
# unit larger than the positive rail (|(-2048)| >> 0 = 2048 clamps), and the
# release stalls once e < 2^K because the floor shift then yields zero.
ENV_BODY = '''
bad = (c[30:6] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    xin = $signed({{20{a[11]}}, a[11:0]});
    mag = xin < 0 ? -xin : xin;
    gg = c[5:4];
    kk = {1'b0, c[2:0]} + 4'd1;
    eq8 = c[31] ? 20'd0 : state_r[19:0];
    tgt = mag <<< 8;
    at = (tgt > eq8);
    dec = eq8 >>> kk;
    enr = at ? tgt : (c[3] ? eq8 : (eq8 - dec));
    lvl = enr >> 8;
    gv = lvl << gg;
    ocl = gv > 16'd2047;
    rl = (~at) & (~c[3]);
    r = (ocl ? 12'd2047 : gv[11:0]);
    x = {2'b0, enr, c[3], c[2:0], c[5:4], ocl, at, rl, c[31]};
    f = ocl;
    state_n[19:0] = enr;
end'''

ENV_DECL = ('reg signed [63:0] xin, mag;\n'
            'reg [19:0] eq8, tgt, enr, dec;\n'
            'reg [15:0] gv;\n'
            'reg [12:0] lvl;\n'
            'reg [3:0] kk;\n'
            'reg [1:0] gg;\n'
            'reg at, rl, ocl, bad;')

core('envelope_ar',
     'Attack/release envelope follower for a level meter or a limiter side '
     'chain: instant attack, exponential release e = e - (e >> K) with '
     'K = c[2:0] + 1 (1..8), optional peak hold when c[3] = 1, and a meter '
     'range switch c[5:4] that shifts the reported level by 0/1/2/3 bits '
     '(x1, x2, x4, x8). a is the s12 sample, c[31] restarts with an empty '
     'envelope, c[30:6] must be zero. The envelope itself is a 20-bit Q8 '
     'accumulator so the release keeps sub-LSB resolution. result = (e >> 8) '
     'shifted by the range and clamped to 2047, 12-bit unsigned (zero '
     'extended, it is a magnitude). aux[0] = restart echo, aux[1] = release '
     'step taken, aux[2] = attack taken, aux[3] = output clamped, aux[5:4] = '
     'range, aux[8:6] = K-1, aux[9] = hold mode, aux[29:10] = the whole Q8 '
     'envelope. fault = output clamped or malformed control.',
     ENV_BODY,
     'An envelope follower in software pays a multiply and a float convert per '
     'sample; here the release is one floor shift off a Q8 accumulator and the '
     'range switch is a shifter, so a full attack/release/hold meter retires a '
     'sample per enabled beat with no DSP slice, and the 20-bit state leaves '
     '236 bits of the kernel word free for whatever the group needs next.',
     1, ENV_DECL, stateful=True)
# --------------------------------------------------------------------------
# 10. tdm8_demux -- 8-slot TDM receiver: route, integrity-check, fold down.
# --------------------------------------------------------------------------
# One 16-bit slot word per accepted beat, routed into the channel register the
# claimed slot index points at.  All the checks are bit tests and compares, so
# nothing in this core multiplies:
#   over-range  a valid audio slot is s12-in-s16, i.e. a[15:12] must equal the
#               sign extension {4{a[11]}} -- one XOR-style compare, no adder
#   sequence    the claimed slot must equal the expected counter, unless c[31]
#               re-synchronises the receiver to any slot
#   lock        an 8-bit "slot seen" bitmap, set from the slot index; full lock
#               is the bitmap reading 0xFF
#   fold-down   the sum of the eight channel registers, reported in aux so one
#               beat shows the whole bus (eight 16-bit signed adds, no multiply)
# State: ch0..ch7 at [127:0] (16 bits each), seen bitmap [135:128], expected
# slot counter [138:136].
TDM_BODY = '''
bad = (c[30:3] != 0);
orr = (a[15:12] != {4{a[11]}});
seq = (c[31] == 1'b0) && (c[2:0] != state_r[138:136]);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    bm = (c[31] ? 8'd0 : state_r[135:128]) | (8'd1 << c[2:0]);
    lk = (bm == 8'hff);
    case (c[2:0])
        3'd0: state_n[15:0] = a[15:0];
        3'd1: state_n[31:16] = a[15:0];
        3'd2: state_n[47:32] = a[15:0];
        3'd3: state_n[63:48] = a[15:0];
        3'd4: state_n[79:64] = a[15:0];
        3'd5: state_n[95:80] = a[15:0];
        3'd6: state_n[111:96] = a[15:0];
        default: state_n[127:112] = a[15:0];
    endcase
    state_n[135:128] = bm;
    state_n[138:136] = c[2:0] + 3'd1;
    mix = $signed(state_n[15:0]) + $signed(state_n[31:16])
        + $signed(state_n[47:32]) + $signed(state_n[63:48])
        + $signed(state_n[79:64]) + $signed(state_n[95:80])
        + $signed(state_n[111:96]) + $signed(state_n[127:112]);
    r = {{16{a[15]}}, a[15:0]};
    x = {1'b0, c[31], lk, seq, orr, c[2:0], bm, mix[15:0]};
    f = orr || seq;
end'''

TDM_DECL = ('reg [7:0] bm;\n'
            'reg signed [31:0] mix;\n'
            'reg lk, seq, orr, bad;')

core('tdm8_demux',
     'Eight-slot TDM receiver: every accepted beat carries one 16-bit slot word '
     'in a[15:0] with its claimed slot index in c[2:0], c[31] re-synchronises '
     'the receiver onto that slot instead of the expected one, and c[30:3] must '
     'be zero. The word is routed into that channel of eight 16-bit channel '
     'registers, and three integrity checks are made of bit tests and compares '
     'only: over-range (a valid audio slot is s12 inside s16, so a[15:12] must '
     'equal the sign bit replicated four times), sequence (the slot index has '
     'to match the running expected-slot counter) and lock (an eight-bit seen '
     'bitmap, full at 0xFF). result = the routed slot word, sign extended from '
     's16. aux[15:0] = the fold-down sum of all eight channel registers, '
     'aux[23:16] = the seen bitmap, aux[26:24] = this slot index, aux[27] = '
     'over-range, aux[28] = sequence error, aux[29] = frame lock, aux[30] = '
     'restart echo. fault = over-range or sequence error, or malformed control '
     '(which also drops lock).',
     TDM_BODY,
     'A TDM demultiplexer in software is a switch and a sign test per sample; '
     'here eight registered channels, the seen-bitmap lock tracker and the '
     'fold-down monitor all update in one enabled beat with no multiplier, no '
     'block RAM and 139 bits of state, so the receiver can watch every slot of '
     'the bus while the audio path keeps its DSP slices.',
     1, TDM_DECL, stateful=True)

@model('biquad_df2_s12')
def biquad_df2(a, b, c, state):
    if (c >> 2 & ((1 << 29) - 1)) or (c & 3) > 1:
        return 0, 0, 1, 0
    restart = bool(c >> 31)
    xin = s12(a)
    s1 = 0 if restart else field(state, 0, 32)
    s2 = 0 if restart else field(state, 1, 32)
    if c & 1:                                   # P1 DC blocker
        acc = (xin << 13) + s1
    else:                                       # P0 lowpass, DC gain exactly 2
        acc = (xin << 11) + (xin << 9) + s1
    acc = (acc + 8192) >> 14
    cl = acc > 2047 or acc < -2048
    yv = clamp(acc, -2048, 2047)
    if c & 1:
        n1, n2 = -(xin << 13) + (yv << 13) + s2, 0
    else:
        n1 = (xin << 12) + (xin << 10) + (yv << 14) + (yv << 10) + s2
        n2 = (xin << 11) + (xin << 9) - (yv << 13) + (yv << 11)
    x = (s1 & 0xffff) | ((s2 & 0xffff) << 16)
    return yv & MASK, x, int(cl), \
        (n1 & 0xffffffff) | ((n2 & 0xffffffff) << 32)


@gen('biquad_df2_s12')
def biquad_df2_rows(count):
    rows = []
    for preset in (0, 1):
        for i, value in enumerate(tri(30)):
            c = preset | (1 << 31) if i == 0 else preset
            rows.append((value & 0xfff, 0, c))
        rows.append((2047, 0, preset))                  # positive rail
        rows.append((-2048 & 0xfff, 0, preset))         # negative rail
        rows.append((0, 0, preset | (1 << 3)))          # reserved bit: fault
        rows.append((1000, 0, preset | 2))              # preset 2: malformed
    for i, value in enumerate(ramp(count - len(rows))):
        rows.append((value, 0, i & 1))                 # both sections, no repeats
    return rows


@model('biquad_cascade_step')
def cascade(a, b, c, state):
    if c >> 1 & ((1 << 30) - 1):
        return 0, 0, 1, 0
    restart = bool(c >> 31)

    def old(index):
        return 0 if restart else field(state, index, 12)

    xin = s12(a)
    px1, px2, py1, py2, qx1, qo1 = (old(0), old(1), old(2), old(3), old(4), old(5))
    acc = ((xin << 11) + (xin << 9) + (px1 << 12) + (px1 << 10) + (px2 << 11) +
           (px2 << 9) + (py1 << 14) + (py1 << 10) - (py2 << 13) + (py2 << 11))
    acc = (acc + 8192) >> 14
    c1 = int(acc > 2047 or acc < -2048)
    ys = clamp(acc, -2048, 2047)
    if c & 1:
        acc2 = ys << 14
    else:
        acc2 = (ys << 13) - (qx1 << 13) + (qo1 << 13)
    acc2 = (acc2 + 8192) >> 14
    c2 = int(acc2 > 2047 or acc2 < -2048)
    zs = clamp(acc2, -2048, 2047)
    x = ((ys & 0xfff) | (c1 << 12) | (c2 << 13) | ((c & 1) << 14) |
         (int(restart) << 15))
    new = ((a & 0xfff) | ((state & 0xfff) << 12) | ((ys & 0xfff) << 24) |
           ((state >> 24 & 0xfff) << 36) | ((ys & 0xfff) << 48) |
           ((zs & 0xfff) << 60))
    return zs & MASK, x, c1 | c2, new


@gen('biquad_cascade_step')
def cascade_rows(count):
    rows = []
    for mode in (0, 1):
        # Keep the sweeps inside the linear region of the gain-2 section (which
        # rails above |x| = 1024) so the board set shows real output values; the
        # two rail rows below still exercise both clamp flags.
        for i, value in enumerate(tri(48, 1000)):
            c = mode | (1 << 31) if i == 0 else mode
            rows.append((value & 0xfff, 0, c))
        rows.append((2047, 0, mode))                  # positive rail
        rows.append((-2048 & 0xfff, 0, mode))         # negative rail
        rows.append((0, 0, mode | (1 << 5)))          # reserved bit: fault
        for i, value in enumerate(tri(24, 1900)):
            rows.append((value & 0xfff, 0, mode))     # through both rails
    for i, value in enumerate(ramp(count - len(rows))):
        rows.append((value, 0, i & 1))                # both bypass settings
    return rows


@model('poly2_interp')
def poly2(a, b, c, state):
    if c >> 4:
        return 0, 0, 1, state
    r = x = f = 0
    for lane, source in enumerate((a, b)):
        samples = [s_bits((source >> 8*k) & 0xff, 8) for k in range(3)]
        acc = 0
        for tap, shift, sign in POLY2_TERMS[(c >> 2*lane) & 3]:
            term = samples[tap] << shift
            acc += -term if sign < 0 else term
        acc = (acc + 8192) >> 14
        cl = int(acc > 127 or acc < -128)
        r |= (clamp(acc, -128, 127) & 0xff) << 8*lane
        x |= cl << lane
        x |= (acc & 0xff) << (8 + 8*lane)
        f |= cl
    return r, x, f, state


@gen('poly2_interp')
def poly2_rows(count):
    rows = []
    # s8 rail corners on all three taps: this is where the clamp path lives.
    for phase in range(4):
        for combo in range(8):
            lo = sum((0x80 if combo >> k & 1 else 0x7f) << 8*k for k in range(3))
            hi = sum((0x7f if combo >> k & 1 else 0x80) << 8*k for k in range(3))
            rows.append((lo, hi, phase | (phase << 2)))
    # Malformed control, four independent reserved bits.
    rows.append((0x7f7f7f7f, 0x80808080, 1 | (1 << 4)))
    rows.append((0, 0, 1 << 31))
    rows.append((0x12345678, 0x9abcdef0, 3 | (1 << 12)))
    rows.append((0x55aa55aa, 0xaa55aa55, 2 | 8 | (1 << 30)))
    i = 0
    while len(rows) < count:
        a = (((i * 7) & 0xff) | (((i * 29) & 0xff) << 8) |
             (((i * 53) & 0xff) << 16) | (((i * 101) & 0xff) << 24))
        b = (((i * 13) & 0xff) | (((i * 37) & 0xff) << 8) |
             (((i * 61) & 0xff) << 16) | (((i * 107) & 0xff) << 24))
        rows.append((a, b, (i & 3) | (((i >> 2) & 3) << 2)))
        i += 1
    return rows


@model('cic_comp_s12')
def cic(a, b, c, state):
    l2 = c & 7
    if (c >> 3 & ((1 << 28) - 1)) or l2 < 2 or l2 > 3:
        return 0, 0, 1, 0
    hi, lo = (1 << 19) - 1, -(1 << 19)
    restart = bool(c >> 31)
    msk = (1 << l2) - 1
    gsh = 2 * l2
    oldph = 0 if restart else (state >> 80 & 7)
    i1 = 0 if restart else field(state, 0, 20)
    i2 = 0 if restart else field(state, 1, 20)
    d1 = 0 if restart else field(state, 2, 20)
    d2 = 0 if restart else field(state, 3, 20)
    xin = s12(a)
    fin = oldph == msk
    phn = (oldph + 1) & msk
    t1 = i1 + xin
    ov = [int(t1 > hi or t1 < lo), 0, 0, 0, 0]
    n1v = clamp(t1, lo, hi)
    t2 = i2 + n1v
    ov[1] = int(t2 > hi or t2 < lo)
    n2v = clamp(t2, lo, hi)
    if fin:
        t3 = n2v - d1
        ov[2] = int(t3 > hi or t3 < lo)
        w3 = clamp(t3, lo, hi)
        t4 = w3 - d2
        ov[3] = int(t4 > hi or t4 < lo)
        yv = (t4 + (1 << (gsh - 1))) >> gsh
        ov[4] = int(yv > 2047 or yv < -2048)
        h12 = clamp(yv, -2048, 2047)
    else:
        w3 = 0
        h12 = s_bits(state >> 84, 12)
    flags = (ov[0] | ov[1] << 1 | ov[2] << 2 | ov[3] << 3 | ov[4] << 4)
    x = flags | int(fin) << 5 | phn << 6 | ((n1v & 0xfffff) << 9)
    new = ((n1v & 0xfffff) | ((n2v & 0xfffff) << 20) |
           (((n2v if fin else s_bits(state >> 40, 20)) & 0xfffff) << 40) |
           (((w3 if fin else s_bits(state >> 60, 20)) & 0xfffff) << 60) |
           (phn << 80) | ((h12 & 0xfff) << 84))
    return h12 & MASK, x, int(flags != 0), new


@gen('cic_comp_s12')
def cic_rows(count):
    rows = []
    for l2 in (3, 2):
        unit = 64 if l2 == 3 else 16          # the group gain R^2 is exactly 2*gsh
        for i in range(40):                   # long enough for two full groups
            rows.append((unit, 0, l2 | (1 << 31) if i == 0 else l2))
        for i in range(40):                   # overload the 20-bit integrator chain
            rows.append((2047, 0, l2))
        rows.append((0, 0, l2 | (1 << 10)))   # reserved bit: fault
        rows.append((0, 0, 1))                # log2(R) = 1 is malformed: fault
    i = 0
    while len(rows) < count:
        rows.append(((i * 211) & 0xfff, 0, 2 + (i & 1)))
        i += 1
    return rows


@model('goertzel_dtmf')
def goertzel(a, b, c, state):
    restart = bool(c >> 31)
    if ((c >> 3) & ((1 << 28) - 1)) or (not restart
                                        and (c & 7) != ((state >> 52) & 7)):
        return 0, 0, 1, 0
    s1 = 0 if restart else field(state, 0, 26)
    s2 = 0 if restart else field(state, 1, 26)
    acc = (s12(a) << 26) - (s2 << 14)
    for k, d in GOERTZEL_NAF[c & 7]:
        acc += (s1 << k) if d > 0 else -(s1 << k)
    sv = (acc + 8192) >> 14
    lim = (1 << 25) - 1
    oaa = not -lim <= sv <= lim
    sn1 = clamp(sv, -lim, lim)
    sn2 = 0 if restart else field(state, 0, 26)
    e1, e2 = abs(sn1), abs(sn2)
    hv = (e1 + e2 + 4096) >> 13
    oee = hv > 2047
    r = 2047 if oee else hv
    x = (int(restart) | (int(oaa) << 2) | (int(oee) << 3)
         | ((e2 >> 14) << 4) | ((e1 >> 14) << 16) | ((c & 7) << 28))
    new = ((sn1 & ((1 << 26) - 1)) | ((sn2 & ((1 << 26) - 1)) << 26)
           | ((c & 7) << 52))
    return r & MASK, x & MASK, int(oaa or oee), new


@gen('goertzel_dtmf')
def goertzel_rows(count):
    rows = []
    for i in range(8):                       # one short block per tone bin
        peak = 200 if i < 4 else 400         # the low bins carry the bigger gain
        wave = tri(6, peak)
        for k in range(8):
            if k == 0:
                rows.append((0, 0, (1 << 31) | i))           # pre-charge
            elif k == 7:
                rows.append((0, 0, i | (1 << 20)))           # reserved bit: fault
            else:
                rows.append((wave[k - 1] & 0xfff, 0, i))
    rows.append((0, 0, (1 << 31) | 0))       # ring bin 0 up until it rails
    rows += [(2047, 0, 0)] * 11
    rows.append((0, 0, (1 << 31) | 4))       # bin 4 with a dithered near-rail
    rows += [((2040 - k * 29) & 0xfff, 0, 4) for k in range(11)]
    j = 0
    while len(rows) < count:                 # eight-row sweep of every bin
        bin_ = (j // 8) & 7
        k = j % 8
        rows.append(((200 - ((k + 1) * 173 + j * 7) % 400) & 0xfff, 0,
                     bin_ | ((1 << 31) if k == 0 else 0)))
        j += 1
    return rows


@model('karplus_strong')
def karplus(a, b, c, state):
    if (c >> 3) & ((1 << 28) - 1):
        return 0, 0, 1, 0
    restart = bool(c >> 31)
    ln = c & 3
    m = 4 * (ln + 1)                       # 4, 8, 12, 16 cells
    ee = 4 if (c >> 2) & 1 else 7
    p = 0 if restart else ((state >> 204) & 0xf)
    dm = s_bits(state >> (12 * p), 12)
    d0 = s_bits((state >> 192) & 0xfff, 12)
    ssum = 0 if restart else d0 + dm            # restart beat rings from silence
    fb = ((ssum - (ssum >> ee)) >> 1) + s12(a)
    ovr = not -2048 <= fb <= 2047
    out = clamp(fb, -2048, 2047)
    pn = 0 if p + 1 >= m else p + 1
    new = 0 if restart else state
    new = (new & ~(0xfff << (12 * p))) | ((out & 0xfff) << (12 * p))
    new = (new & ~(0xfff << 192)) | ((out & 0xfff) << 192)
    new = (new & ~(0xf << 204)) | (pn << 204)
    x = (((fb & 0x3fff) << 8) | (int(restart) << 7) | (int(ovr) << 6)
         | (ln << 4) | pn)
    return out & MASK, x & MASK, int(ovr), new


@gen('karplus_strong')
def karplus_rows(count):
    rows = []
    wave = tri(13, 1500)
    for ln in range(4):                    # every loop length and damping
        for eb in (0, 1):
            sel = ln | (eb << 2)
            rows.append((2047, 0, (1 << 31) | sel))       # full-scale pluck
            for k in range(13):
                rows.append((wave[k] & 0xfff, 0, sel))
            rows.append((0, 0, sel))                       # free decay
            rows.append((0, 0, sel | (1 << 12)))           # reserved bit: fault
    while len(rows) < count:
        ln = len(rows)
        rows.append(((((ln * 211) & 0x7ff) - 1024) & 0xfff, 0,
                     (ln & 3) | (((ln >> 2) & 1) << 2)
                     | ((1 << 31) if ln % 16 == 0 else 0)))
    return rows


@model('dsm2_mod')
def dsm2(a, b, c, state):
    if (c >> 2) & ((1 << 29) - 1):
        return 0, 0, 1, 0
    restart = bool(c >> 31)
    ns = (c & 3) + 1
    xin = s12(a)
    x1 = 0 if restart else s_bits(state, 12)
    x2 = 0 if restart else s_bits(state >> 12, 12)
    ov = 0
    cnt = 0
    pdm = 0
    n1 = n2 = 0
    for _ in range(ns):
        v = x2 + (x1 >> 1)
        pdm = 1 if v >= 0 else 0
        yd = 2046 if pdm else -2046
        cnt += pdm
        t1 = x1 + ((xin - yd) >> 1)
        t2 = x2 + (x1 >> 1) - (yd >> 1)
        n1 = clamp(t1, -2048, 2047)
        n2 = clamp(t2, -2048, 2047)
        ov |= int(t1 != n1 or t2 != n2)
        x1, x2 = n1, n2
    x = ((x2 & 0xfff) << 20) | ((x1 & 0xfff) << 8) | (int(restart) << 5)
    x |= (ov << 4) | (cnt << 1) | pdm
    new = ((x2 & 0xfff) << 12) | (x1 & 0xfff)
    return ((2046 if pdm else -2046) & MASK), x & MASK, ov, new


@gen('dsm2_mod')
def dsm2_rows(count):
    rows = []
    for ns in range(4):                          # 1..4 sub-steps per beat
        rows.append((0, 0, (1 << 31) | ns))      # silence, then a full sweep
        rows += [(v & 0xfff, 0, ns) for v in tri(24, 1200)]
        rows += [((2047 if k % 2 == 0 else -2048) & 0xfff, 0, ns)
                 for k in range(6)]
        rows.append((0, 0, ns | (1 << 12)))      # reserved bit: fault
    j = 0
    while len(rows) < count:
        k = j % 32
        rows.append(((tri(24, 1600)[k % 24] if k < 24 else 900) & 0xfff, 0,
                     ((j // 32) & 3) | ((1 << 31) if k == 0 else 0)))
        j += 1
    return rows


@model('envelope_ar')
def envelope(a, b, c, state):
    if (c >> 6) & ((1 << 25) - 1):
        return 0, 0, 1, 0
    restart = bool(c >> 31)
    xin = s12(a)
    mag = -xin if xin < 0 else xin
    gg = (c >> 4) & 3
    kk = (c & 7) + 1
    hold = (c >> 3) & 1
    eq8 = 0 if restart else (state & 0xfffff)
    tgt = mag << 8
    at = int(tgt > eq8)
    dec = eq8 >> kk
    enr = tgt if at else (eq8 if hold else eq8 - dec)
    lvl = enr >> 8
    gv = lvl << gg
    ocl = int(gv > 2047)
    rl = int(not at and not hold)
    x = ((enr << 10) | (hold << 9) | ((c & 7) << 6) | (gg << 4)
         | (ocl << 3) | (at << 2) | (rl << 1) | int(restart))
    return ((2047 if ocl else gv) & MASK), x & MASK, ocl, enr & 0xfffff


@gen('envelope_ar')
def envelope_rows(count):
    rows = []
    blk = 0
    while len(rows) < max(count, 128):
        k = blk & 7                            # release exponent K = k + 1
        hold = (blk >> 3) & 1                  # peak hold on the upper blocks
        for j in range(8):
            gg = (j >> 1) & 3                  # sweep the four meter ranges
            c = k | (hold << 3) | (gg << 4)
            if j == 0:
                rows.append((0, 0, (1 << 31) | c))          # empty envelope
            elif j == 7 and blk % 2 == 0:
                rows.append((0, 0, c | (1 << 20)))          # reserved: fault
            else:
                rows.append(((((blk * 977 + j * 313) % 3600) - 1800) & 0xfff,
                             0, c))
        blk += 1
    return rows


@model('tdm8_demux')
def tdm8(a, b, c, state):
    if (c >> 3) & ((1 << 28) - 1):
        return 0, 0, 1, 0
    restart = bool(c >> 31)
    slot = c & 7
    s16v = s16(a)
    orr = int(s16v != s12(a))               # not an s12 word inside s16
    seq = int(not restart and slot != ((state >> 136) & 7))
    bm = (0 if restart else ((state >> 128) & 0xff)) | (1 << slot)
    lk = int(bm == 0xff)
    chans = [s_bits(state >> (16 * i), 16) for i in range(8)]
    chans[slot] = s16v
    mix = sum(chans)
    new = state & ((1 << 256) - 1)
    new = (new & ~(0xffff << (16 * slot))) | ((s16v & 0xffff) << (16 * slot))
    new = (new & ~(0xff << 128)) | (bm << 128)
    new = (new & ~(7 << 136)) | (((slot + 1) & 7) << 136)
    x = ((int(restart) << 30) | (lk << 29) | (seq << 28) | (orr << 27)
         | (slot << 24) | (bm << 16) | (mix & 0xffff))
    return s16v & MASK, x & MASK, int(orr or seq), new


@gen('tdm8_demux')
def tdm8_rows(count):
    rows = []
    for fr in range(16):
        sig = tri(8, 300 + 110 * fr)        # a different frame every time
        for s in range(8):
            c = s | ((1 << 31) if s == 0 else 0)
            if fr in (3, 11) and s == 3:
                rows.append((sig[s] & 0xffff, 0, 5))      # slot jumped: seq err
            elif fr in (5, 13) and s == 6:
                rows.append(((2400 if fr == 5 else -2500) & 0xffff, 0, c))
            elif fr == 7 and s == 4:
                rows.append((0, 0, c | (1 << 10)))         # reserved bit: fault
            else:
                rows.append((sig[s] & 0xffff, 0, c))
    j = 0
    while len(rows) < count:
        s = j % 8
        rows.append(((((j * 997) % 3000) - 1500) & 0xffff, 0,
                     s | ((1 << 31) if s == 0 else 0)))
        j += 1
    return rows


# --- APPEND HERE ---
