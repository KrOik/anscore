"""Numeric-datapath accelerator cores: iterative arithmetic arrays.

Every core here is a bit-slice array whose per-beat work is what a CPU pays a
whole subroutine for: one CORDIC rotation, one Newton-Raphson correction, one
non-restoring division slice, one restoring square-root bit pair, one
fixed-to-floating normalisation network, one floating add, one bfloat16 pair
multiply, one canonical-signed-digit digit, one Montgomery reduction limb.

Template body vocabulary (declared by generate_lib.RTL, re-initialised on every
evaluation, all width-safe as written):
    r x f temp mask pa pb pc ph pl ext wide wide2 swide swide2 sa sb sc data
    i j idx lane sh state_r state_n
Module-scope text (localparam / reg / wire / function) comes from `decl`, which
is also where the shift-add multiplier functions of this file are declared.

Multiply policy, uniform across the family: no generated module contains a
Verilog `*`, because on GW5A the fabric `$mul` is unsigned and silently
corrupts any operand with bit 11 set, and hand-instantiating MULT12X12 is out
of scope here.  Every product in this family is formed by `shift_add_mul()`
below, an explicit partial-product recode: one conditional add of
`{pad,u}<<<k` per operand bit of the multiplier, accumulated in a register
exactly wide enough that no partial sum can overflow, so yosys lowers it to
LUT-class carry chains and the DSP count stays zero.  Which recode each
product-bearing core uses:
    nr_recip   sm12 (signed 12x12 -> 24) for D*Y = 3072*6144 + 6144*E
               + 3072*V + E*V, of which only E*V and V*tq are recoded here;
               the other three terms stay wired shifts and adds.
    bf16_mul   um8 (unsigned 8x8 -> 16) per lane, on mantissas in [128,255]
               for normals and [0,127] for subnormals, so both operands are
               non-negative and the unsigned recode is exact.
    mont_mul   um11 (unsigned 11x11 -> 22) three times per step, on limbs kept
               at 11 bits precisely so that an unsigned partial-product window
               never exceeds 2^22 and no sign trick is needed.
The remaining cores multiply nothing at all: they are shift/compare arrays
(cordic_atan, div_nonrestoring, isqrt, csd_recode) or exponent/mantissa
repacking networks (fix2float, float2fix_rne, fadd_s32).

Fault convention, uniform across the family: a faulted beat drives result=0,
aux=0 and leaves state untouched, so a fault is always a clean, repeated
zero response rather than a half-updated number.

All derived constants (CORDIC atan table, reciprocal seed ROM, Montgomery
moduli and their -N^-1 limbs) are computed by this file's own integer code at
import time -- see the derivation blocks below -- and are re-proved against
independent references in selftest().
"""
from fractions import Fraction
from math import atan, atan2, isqrt as misqrt
from random import Random
from struct import pack, unpack

FAMILY = 'arith'
MASK = (1 << 32) - 1

CORES = []


def core(name, spec, body_text, advantage, lanes, decl='', stateful=False,
         **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body_text,
                      decl=decl, advantage=advantage, lanes=lanes,
                      stateful=stateful, **kwargs))


def B(*lines):
    return '\n'.join(lines)


def shift_add_mul(name, bits, signed_in):
    """Explicit partial-product recode; the only product former in this family.

    `name` is a Verilog function of two `bits`-wide operands returning a
    2*bits-wide product.  signed_in uses the sign-magnitude form (negate the
    operands into unsigned patterns, accumulate, conditionally negate), which
    is exact for the two's-complement minimum because |x| <= 2^(bits-1) still
    fits the unsigned pattern.  Unsigned mode is for operands that are already
    non-negative by construction.  No `*` appears in the emitted text.
    """
    w = 2 * bits
    sig = 'signed ' if signed_in else ''
    lines = [f'function {sig}[{w - 1}:0] {name};',
             f'  input {sig}[{bits - 1}:0] u, v;',
             f'  integer k;']
    if signed_in:
        lines += [f'  reg su, sv; reg [{bits - 1}:0] au, av;',
                  f'  reg signed [{w - 1}:0] acc;',
                  'begin',
                  '  su=(u<0); sv=(v<0);',
                  f"  au=su ? ({bits}'d0-u) : u;",
                  f"  av=sv ? ({bits}'d0-v) : v;",
                  f"  acc={w}'sd0;",
                  f"  for(k=0;k<{bits};k=k+1) if(av[k]) acc=acc+({{{bits}'d0,au}}<<<k);",
                  f'  {name}=(su^sv) ? -acc : acc;',
                  'end', 'endfunction\n']
    else:
        lines += [f'  reg [{w - 1}:0] acc;',
                  'begin',
                  f"  acc={w}'d0;",
                  f"  for(k=0;k<{bits};k=k+1) if(v[k]) acc=acc+({{{bits}'d0,u}}<<<k);",
                  f'  {name}=acc;',
                  'end', 'endfunction\n']
    return '\n'.join(lines)


def fun_text(name, width, values, index_width, comment=''):
    """Constant case-function text over derived values (no synthesis loops)."""
    rows = [f'function [{width-1}:0] {name}; input [{index_width-1}:0] ix; '
            f'begin {name}={width}\'d0; case (ix)']
    for index, value in enumerate(values):
        note = comment.format(index=index, value=value) if comment else ''
        rows.append(f"{index_width}'d{index}: {name}={width}'d{value};{note}")
    rows.append('default: ; endcase end endfunction\n')
    return '\n'.join(rows)


# =============================================================== derived tables
# ----------------------------------------------------------------- CORDIC atan
# atan(2^-i) must not be copied from any published table: it is derived here from
# the Gregory series atan(1/q) = sum (-1)^k / ((2k+1) q^(2k+1)) in exact rational
# arithmetic, and pi/4 from Machin's identity pi/4 = 4*atan(1/5) - atan(1/239).
# selftest() re-proves the identity with the tangent addition formula over
# Fractions (tan(4*atan(1/5) - atan(1/239)) == 1 exactly) and compares every
# entry against the library atan() this table is meant to replace.
def _atan_inv(q, bits=95):
    total, k = Fraction(0), 0
    while True:
        term = Fraction(1, (2 * k + 1) * q ** (2 * k + 1))
        if term < Fraction(1, 2 ** bits):
            return total, k
        total += -term if k % 2 else term
        k += 1


_PI4 = 4 * _atan_inv(5)[0] - _atan_inv(239)[0]
CORDIC_Q = 20                       # angle accumulator: LSB = 2^-20 rad
CORDIC_ATAN = [round(float(_atan_inv(1 << i)[0] if i else _PI4) * (1 << CORDIC_Q))
               for i in range(16)]
CORDIC_PI = round(float(4 * _PI4) * (1 << CORDIC_Q))
CORDIC_ITERS = 16
CORDIC_GAIN_BITS = 23               # x/y state width after the normaliser


def atan_fun_text():
    rows = ['function signed [21:0] atan_at; input [3:0] ix; begin atan_at=0;'
            ' case (ix)']
    for index, value in enumerate(CORDIC_ATAN):
        exact = _atan_inv(1 << index)[0] if index else _PI4
        rows.append(f"4'd{index}: atan_at=22'sd{value};"
                    f"  // atan(2^-{index}) = {float(exact):.10f} rad")
    rows.append('default: ; endcase end endfunction\n')
    return '\n'.join(rows)


# ------------------------------------------------------- Newton-Raphson seed ROM
# The reciprocal core may not divide, so its 6-bit seed ROM is derived offline by
# exact integer rounding of 2^24/D at the centre of each 64-wide divisor bin.
# The measured consequence (a <= 2^-6 relative seed error) is asserted in
# selftest(); the hardware then only multiplies and shifts.
def _round_div(num, den):
    """Round-half-up of num/den for den > 0, integer only (no / operator)."""
    return (2 * num + den) // (2 * den)


NR_BINS = 64
NR_CENTER = 6144                    # r = 1.5 + V*2^-12, V is 12-bit signed
NR_E_CENTER = 3072                  # x = 0.75 + E*2^-12, E is 12-bit signed
NR_DMIN = 2049                      # x in (1/2, 1): D = x*2^12 in [2049, 4095]
NR_SEED = [0] * NR_BINS
for _j in range(32, NR_BINS):
    _mid = _j * 64 + 32
    _v = _round_div(1 << 24, _mid) - NR_CENTER
    NR_SEED[_j] = _v if -2048 <= _v <= 2047 else (2047 if _v > 2047 else -2048)
NR_SHIFT = (7, 3, 1)                # residual shift of correction beats 0..2
NR_KFIX = 3                         # beat index that runs the exact fix-up
NR_BEATS = 5                        # seed + 3 corrections + fix-up


def seed_fun_text():
    rows = ['function signed [11:0] seed_at; input [5:0] ix; begin seed_at=0;'
            ' case (ix)']
    for index, value in enumerate(NR_SEED):
        # A negative sized decimal literal (`12'sd-1536`) is a syntax error in
        # Verilog, so the sign is written as a unary minus in front.
        text = f"12'sd{abs(value)}" if value < 0 else f"12'sd{value}"
        rows.append(f"6'd{index}: seed_at={'-' if value < 0 else ''}{text};"
                    f"  // bin centre D={index * 64 + 32}")
    rows.append('default: ; endcase end endfunction\n')
    return '\n'.join(rows)


# --------------------------------------------------------------- Montgomery ROM
# Eight 22-bit odd moduli with N' = -N^-1 mod 2^11.  N' comes from the 2-adic
# Newton iteration x <- x*(2 - N*x), which doubles the number of correct bits per
# step and needs no division; selftest() re-derives it with Python's pow() and
# checks N*N' == -1 (mod 2^11).  Limbs are 11 bits precisely so that every
# partial-product window of the um11 shift-add recode stays inside 22 bits: the
# recode adds only non-negative operands, so no sign trick is needed anywhere.
MONT_LIMB = 11
MONT_BASE = 1 << MONT_LIMB
MONT_R = 1 << (2 * MONT_LIMB)       # radix R = 2^22, two limbs


def _mont_neg_inv(n, bits=MONT_LIMB):
    x = 1
    for _ in range(6):
        x = (x * (2 - n * x)) % (1 << bits)
    assert (n * x) % (1 << bits) == 1, n
    return (-x) % (1 << bits)


MONT_MODULI = (0x200001, 0x100001, 0x3FFFFF, 0x00B3FF, 0x155577, 0x0FFFFF,
               0x12345B, 0x2A5A53)
MONT_TABLE = [(n, _mont_neg_inv(n)) for n in MONT_MODULI]


# ============================================================ 1..5 core sources
# ------------------------------------------------------------------ cordic_atan
CORDIC_DECL = (atan_fun_text() +
               'localparam signed [23:0] PID20 = 24\'sd%d;\n' % CORDIC_PI +
               'reg signed [22:0] cx, cy, cxn, cyn, cmx, cmy, cmm, csv, csv2;\n'
               'reg signed [21:0] cz, czn, cai;\n'
               'reg signed [23:0] cang;\n'
               'reg [4:0] ccnt, ccntn;\n'
               'reg cfl, cfln, cfsg, cfsgn, chold, cdir;\n'
               'reg [5:0] cbl;\n'
               'reg [3:0] cix;\n')

core('cordic_atan',
    "CORDIC vectoring-mode atan2. Seed beat (c[31]=1) takes x=a[15:0] signed and "
    "y=a[31:16] signed, pre-rotates by 180 degrees when x<0 (recorded so the "
    "reported angle lands in (-pi,pi]), normalises max(|x|,|y|) with a "
    "leading-zero shifter into the window [2^19,2^20), then executes one "
    "rotation per accepted beat for 16 beats total (rotation 0 runs on the seed "
    "beat); a later beat with c[31]=0 once the counter is idle repeats the "
    "converged angle. x and y are signed 23-bit state fields (measured growth "
    "bound 2.42e6 < 2^22), the angle accumulator is signed Q20 (LSB 2^-20 rad), "
    "the pre-rotation sum needs 24 signed bits because pi*2^20 is added to it. "
    "result=the running angle estimate in signed Q16 radians, i.e. (Q20+8)>>4, "
    "so one LSB is 2^-16 rad and the verified bound against atan2 is |error| <= "
    "4 LSB (measured 2.55; the intrinsic 16-step resolution is "
    "atan(2^-15)=2.0002 LSB, so no Q16 16-step CORDIC can promise 1 LSB). "
    "aux[3:0]=rotation index executed this beat, aux[4]=1 when the 16th "
    "rotation just finished, aux[5]=quadrant pre-rotation applied, aux[6]=run "
    "1 = rotation towards -y, 0 = towards +y or idle, aux[7]=idle repeat, "
    "aux[23:8]=low 16 bits of the post-rotation y, aux[31:24]=0. fault=1 only on "
    "the degenerate seed x=y=0 (atan2 is undefined there).",
    B("cx=$signed(state_r[22:0]); cy=$signed(state_r[45:23]);",
      "cz=$signed(state_r[67:46]); ccnt=state_r[72:68];",
      "cfl=state_r[73]; cfsg=state_r[74];",
      "cxn=cx; cyn=cy; czn=cz; ccntn=ccnt; cfln=cfl; cfsgn=cfsg;",
      "chold=1'b0; cdir=1'b0; cix=4'd0; cai=22'sd0;",
      "if(c[31]) begin",
      "    if(a[15:0]==16'd0 && a[31:16]==16'd0) f=1'b1;",
      "    else begin",
      "        csv=$signed(a[15:0]); csv2=$signed(a[31:16]);",
      "        if(csv<0) begin cmx=-csv; cmy=-csv2; cfln=1'b1;",
      "            cfsgn=(csv2>=0); end",
      "        else begin cmx=csv; cmy=csv2; cfln=1'b0; cfsgn=1'b1; end",
      "        if(cmy<0) cmm=-cmy; else cmm=cmy;",
      "        if(cmx>cmm) cmm=cmx;",
      "        cbl=6'd0; for(i=0;i<23;i=i+1) if(cmm[i]) cbl=i+1;",
      "        sh=20-cbl;",
      "        cx=cmx<<<sh; cy=cmy<<<sh; cz=22'sd0; ccnt=5'd0; cix=4'd0;",
      "    end",
      "end else if(ccnt==5'd16) chold=1'b1;",
      "else cix=ccnt[3:0];",
      "if(!f) begin",
      "    if(!chold) begin",
      "        cai=atan_at(cix);",
      "        if(cy>=0) begin cxn=cx+(cy>>>cix); cyn=cy-(cx>>>cix);",
      "            czn=cz+cai; cdir=1'b1; end",
      "        else begin cxn=cx-(cy>>>cix); cyn=cy+(cx>>>cix);",
      "            czn=cz-cai; cdir=1'b0; end",
      "        ccntn=ccnt+5'd1;",
      "    end",
      "    cang=czn + (cfln ? (cfsgn ? PID20 : -PID20) : 24'sd0);",
      "    r=(cang+24'sd8)>>>4;",
      "    x[3:0]=cix; x[4]=(ccntn==5'd16); x[5]=cfln; x[6]=cdir;",
      "    x[7]=chold; x[23:8]=cyn[15:0]; x[31:24]=8'd0;",
      "    state_n={181'd0, cfsgn, cfln, ccntn, czn, cyn, cxn};",
      "end"),
    "One wired rotation per enabled beat: the shift-add pair, the sign decision "
    "and the accumulator update all settle in one cycle, so 16 vectors are in "
    "flight per 16 beats and the angle never leaves the fabric. A CPU running "
    "the same recurrence pays a loop, a branch on the y sign and a shift "
    "instruction per step, and libm atan2 adds polynomial evaluation on top of "
    "that.",
    1, CORDIC_DECL, stateful=True)

# --------------------------------------------------------------------- nr_recip
NR_DECL = (seed_fun_text() +
           shift_add_mul('sm12', 12, True) +
           'reg signed [26:0] ne, nv, nvn, na24, nt24, ntq, ng, nco, ntt, nd;\n'
           'reg signed [26:0] nlim;\n'
           'reg signed [23:0] np1, np2;\n'
           'reg signed [31:0] nres;\n'
           'reg [12:0] nY;\n'
           'reg [3:0] nph;\n'
           'reg [5:0] nbin;\n'
           'reg nsg, nwait;\n')

core('nr_recip',
    "Newton-Raphson reciprocal of a normalised 12-bit mantissa. Seed beat "
    "(c[31]=1) takes D=a[11:0] with 2049<=D<=4095 (x=D*2^-12 in (1/2,1)), loads "
    "E=D-3072 (so x=0.75+E*2^-12) and the seed V from the derived 64-bin ROM "
    "addressed by D>>6, and a[12] selects a negated result. Beats 1..3 apply "
    "V <- V + round((6144*tq + V*tq)/2^(24-k)) with tq=T>>k, k=7,3,1 and "
    "T=2^24-D*Y the exact residual of Y=6144+V (each beat is the Newton step "
    "Y <- Y*(2-x*Y) written in fixed point, so the error squares every beat). "
    "Beat 4 is an exact fix-up that recomputes T and adds (2T>=D) ? 1 : "
    "(2T<=-D) ? -1 : 0, which is the correctly rounded result because |T|<D "
    "there. A later beat with c[31]=0 once the phase counter is idle repeats the "
    "converged answer. Every correction beat forms the two products E*V and "
    "V*tq with one explicit 12-bit signed shift-add recode (12 conditional "
    "partial-product adds, sign-magnitude, no Verilog `*` anywhere). result=signed "
    "round(2^12/x)=signed round(2^24/D) (LSB 2^-12, magnitude 4097..8188 over "
    "the in-range D, proved by the exhaustive selftest sweep), "
    "aux[2:0]=phase counter, aux[3]=converged, aux[4]=sign applied, aux[5]=idle "
    "repeat, aux[9:6]=0, aux[15:10]=seed ROM bin (nonzero only on a seeded "
    "beat), aux[31:16]=low 16 bits of the residual T of the beat just run (zero "
    "on a seed or idle beat). fault=1 on D<=2048 (1/x would be 2 and does not "
    "fit the format) or when a beat's residual leaves the 12-bit slice window "
    "|T| < 2048*2^k (proved unreachable for in-range D by the exhaustive "
    "selftest sweep, kept as a range guard).",
    B("ne=$signed(state_r[11:0]); nv=$signed(state_r[23:12]);",
      "nph=state_r[27:24]; nsg=state_r[28];",
      "nbin=6'd0; nvn=nv; nwait=1'b0; nt24=27'sd0; nvn=nv;",
      "if(c[31]) begin",
      "    if(a[11:0]<=12'd2048) f=1'b1;",
      "    else begin",
      "        ne=$signed({1'b0,a[11:0]})-27'sd3072;",
      "        nbin=a[11:6]; nv=seed_at(nbin); nvn=nv; nph=4'd0; nsg=a[12];",
      "    end",
      "end else if(nph==4'd4) nwait=1'b1;",
      "else begin",
      "    nd=27'sd3072+ne;",
      "    np1=sm12(ne,nv);",
      "    na24=27'sd18874368+(ne<<<12)+(ne<<<11)+(nv<<<11)+(nv<<<10)+np1;",
      "    nt24=27'sd16777216-na24;",
      "    if(nph==4'd3) begin",
      "        ntt=nt24<<<1;",
      "        if(ntt>=nd) nvn=nv+27'sd1;",
      "        else if(ntt<=-nd) nvn=nv-27'sd1;",
      "        else nvn=nv;",
      "        nph=4'd4;",
      "    end else begin",
      "        sh=(nph==4'd0) ? 7 : ((nph==4'd1) ? 3 : 1);",
      "        nlim=27'sd2048<<<sh;",
      "        if(nt24>=nlim || nt24<=-nlim) f=1'b1;",
      "        else begin",
      "            ntq=nt24>>>sh;",
      "            np2=sm12(nv,ntq);",
      "            ng=(ntq<<<12)+(ntq<<<11)+np2;",
      "            nco=(ng+(27'sd1<<<(23-sh)))>>>(24-sh);",
      "            nvn=nv+nco;",
      "            if(nvn<-(27'sd1<<<11) || nvn>(27'sd1<<<11)-27'sd1) f=1'b1;",
      "            else nph=nph+4'd1;",
      "        end",
      "    end",
      "end",
      "if(!f) begin",
      "    nY=13'd6144+nvn[12:0];",
      "    nres=nsg ? (32'sd0-$signed({19'd0,nY})) : $signed({19'd0,nY});",
      "    r=nres; x[2:0]=nph; x[3]=(nph==4'd4); x[4]=nsg; x[5]=nwait;",
      "    x[9:6]=4'd0; x[15:10]=nbin; x[31:16]=nt24[15:0];",
      "    state_n={227'd0, nsg, nph, nvn[11:0], ne[11:0]};",
      "end"),
    "Two shift-add recodes retire one quadratic-convergence correction per "
    "enabled beat: the residual 2^24-D*Y is exact in 25 bits so the loop needs no "
    "division, no compare-retry and no restoring branch, and the whole rounded "
    "reciprocal costs 5 beats. A soft core either calls a library divide or "
    "emulates the same iteration with several multiply-high instructions and a "
    "branch per correction.",
    1, NR_DECL, stateful=True)
# --------------------------------------------------------------- div_nonrestoring
DIV_DECL = ('reg signed [34:0] dr, dmb, dm, dn, drn, dds2;\n'
            'reg [34:0] dmbits;\n'
            'reg [33:0] dds;\n'
            'reg [31:0] ddn, dq, dqn;\n'
            'reg [5:0] dcnt, dcntn;\n'
            'reg dsgn, dsgnn, drst, drstn, dhold, dbit, dbig;\n')

core('div_nonrestoring',
    "Non-restoring signed 32/32 integer divide, one bit-slice per accepted "
    "beat. Seed beat (c[31]=1) takes n=a signed and d=b signed, stores |d| (34 "
    "bits), |n| (32 bits), the sign XOR, a cleared 35-bit signed partial "
    "remainder and a cleared 32-bit magnitude quotient, and reports a zero-count "
    "state; beats 1..32 shift in one dividend bit (MSB first) and apply "
    "R <- 2R+bit-|d| when R was non-negative or R <- 2R+bit+|d| when it was "
    "negative, appending q=1 exactly when the new R is non-negative (that sign "
    "test is the quotient bit, so there is no restore pass inside the loop); "
    "beat 33 conditionally restores R <- R+|d| only when R is negative, leaving "
    "the quotient correct as it stands. Later beats with c[31]=0 once the "
    "counter has reached 33 repeat the converged answer. result=the truncated "
    "signed quotient (magnitude built from |n| and |d|, sign = sign XOR, so "
    "-7/2=-3 and -7%-2 is the C-truncated quotient, not floored); during the "
    "loop the same field carries the running quotient. aux[5:0]=slices done "
    "(33 means the restore beat has run), aux[6]=converged, aux[7]=sign applied "
    "to the quotient, aux[8]=restore taken, aux[9]=divisor magnitude is 2^31 "
    "(d=-2^31), aux[10]=dividend bit shifted in this beat, aux[31:11]=low 21 "
    "bits of the current partial remainder. fault=1 on d=0 (divide by zero) or "
    "on the single overflowing pair n=-2^31, d=-1.",
    B("dr=$signed(state_r[34:0]); dq=state_r[66:35];",
      "dds=state_r[100:67]; ddn=state_r[132:101]; dcnt=state_r[138:133];",
      "dsgn=state_r[139]; drst=state_r[140];",
      "drn=dr; dqn=dq; dcntn=dcnt; dsgnn=dsgn; drstn=drst; dds2=4'd0;",
      "dhold=1'b0; dbit=1'b0; dbig=1'b0; dm=dr; dn=dr;",
      "if(c[31]) begin",
      "    if(b==32'd0 || (a==32'h80000000 && b==32'hffffffff)) f=1'b1;",
      "    else begin",
      "        dds=b[31] ? (({2'b0,~b})+34'd1) : {2'b0,b};",
      "        ddn=a[31] ? ((~a)+32'd1) : a;",
      "        dsgnn=a[31]^b[31]; drn=35'sd0; dqn=32'd0; dcntn=6'd0;",
      "        drstn=1'b0;",
      "    end",
      "end else if(dcnt==6'd33) dhold=1'b1;",
      "else begin",
      "    dds2={1'b0,dds};",
      "    if(dcnt==6'd32) begin",
      "        if(dr<0) begin drn=dr+dds2; drstn=1'b1; end",
      "        dcntn=6'd33; dqn=dq;",
      "      end else begin",
      "        sh=31-dcnt;",
      "        dbit=ddn[sh];",
      "        dmbits=(dr<<<1)|{34'd0,dbit};",
      "        dm=$signed(dmbits);",
      "        dn=(dm>=0) ? (dm-dds2) : (dm+dds2);",
      "        drn=dn; dqn={dq[30:0], (dn>=0)}; dcntn=dcnt+6'd1;",
      "    end",
      "end",
      "if(!f) begin",
      "    r=dsgnn ? (~dqn+32'd1) : dqn;",
      "    x[5:0]=dcntn; x[6]=(dcntn==6'd33); x[7]=dsgnn; x[8]=drstn;",
      "    x[9]=(dds>34'd2147483647); x[10]=dbit;",
      "    x[31:11]=drn[20:0];",
      "    state_n={115'd0, drstn, dsgnn, dcntn, ddn, dds, dqn, drn};",
      "end"),
    "One division bit per enabled beat in a 35-bit signed slice: the quotient "
    "bit is the sign of the new remainder, so there is no restore branch and no "
    "multiply-estimate retry, and the width grows by widening the counter, not "
    "by rewriting the algorithm. A soft processor's 32-bit divide is either a "
    "fixed-cost multi-cycle unit or several hundred instructions of shift-subtract.",
    1, DIV_DECL, stateful=True)

# ------------------------------------------------------------------------ isqrt
SQRT_DECL = ('reg [32:0] sqm, sqn, sqadd, sqbit, sqsh;\n'
             'reg [15:0] sqr, sqrn;\n'
             'reg [4:0] sqi, sqin;\n'
             'reg sqhold, sqdon, sqdonn;\n')

core('isqrt',
    "Restoring integer square root of the 32-bit unsigned operand a, one bit "
    "pair per accepted beat. Seed beat (c[31]=1) loads rem=a (33 bits), root=0, "
    "bit index 15 and reports that seed; later beats test bits 14..0. A test "
    "forms add=(root<<(i+1))|(1<<(2i)) - the exact increase of root^2 when bit i "
    "is set - and keeps the bit only when rem>=add, so the state invariant "
    "rem = a-root^2 holds every beat and the running root is floor(sqrt of the "
    "high bits seen so far). After bit 0 the done flag is set and a beat with "
    "c[31]=0 repeats the converged answer. result=root=floor(sqrt(a)) (16 bits, "
    "result[31:16]=0), aux[4:0]=next bit index tested, aux[5]=converged, "
    "aux[6]=idle repeat, aux[31:7]=low 25 bits of the remainder a-root^2. No "
    "input is invalid, so this core is declared faultless.",
    B("sqm=state_r[32:0]; sqr=state_r[48:33]; sqi=state_r[53:49];",
      "sqdon=state_r[54];",
      "sqn=sqm; sqrn=sqr; sqin=sqi; sqdonn=sqdon; sqhold=1'b0; sqadd=33'd0;",
      "if(c[31]) begin",
      "    sqm={1'b0,a}; sqr=16'd0; sqi=5'd15; sqdon=1'b0;",
      "    sqn=sqm; sqrn=sqr; sqin=sqi; sqdonn=sqdon;",
      "end else if(sqdon) begin",
      "    sqhold=1'b1;",
      "end else begin",
      "    sh=sqi+5'd1;",
      "    sqsh={17'd0,sqr}<<<sh;",
      "    sh=sqi+sqi;",
      "    sqbit=33'd1<<<sh;",
      "    sqadd=sqsh|sqbit;",
      "    if(sqm>=sqadd) begin sqn=sqm-sqadd; sqin=sqi;",
      "        sh=sqi; sqrn=sqr|(16'd1<<<sh); end",
      "    else begin sqn=sqm; sqrn=sqr; end",
      "    sqin = (sqi==5'd0) ? 5'd0 : sqi-5'd1;",
      "    sqdonn = (sqi==5'd0);",
      "end",
      "r={16'd0,sqrn};",
      "x[4:0]=sqin; x[5]=sqdonn; x[6]=sqhold; x[31:7]=sqn[24:0];",
      "state_n={201'd0, sqdonn, sqin, sqrn, sqn};"),
    "The 33-bit addend (root<<(i+1))|(1<<(2i)) is a wired shift, not a "
    "multiplier, so a 32-bit root costs 17 enabled beats and zero slices while "
    "the remainder invariant stays visible on aux every beat. A CPU has no "
    "integer-square-root instruction at this width and pays a compare, a "
    "subtract and a shift per bit pair in software.",
    1, SQRT_DECL, stateful=True, faultless=True)

# --------------------------------------------------------------------- fix2float
F2L_DECL = ('reg [31:0] fxmag, fxn;\n'
            'reg [63:0] fxmask, fxr, fxhalf;\n'
            'reg signed [10:0] fxe, fxf, fxdrop;\n'
            'reg [5:0] fxlz;\n'
            'reg [24:0] fxk;\n'
            'reg [7:0] fxr8;\n'
            'reg fxinc, fxsticky, fxunder, fxover;\n'
            'reg fxsign;\n')

core('fix2float',
    "Fixed Q31 -> IEEE-754 binary32 in one beat (latency 1, not stateful). The "
    "signed value is a*2^(e-31) with e=$signed(c[7:0]) a runtime binary-point "
    "offset and c[31:8] required zero. The network priority-encodes the "
    "magnitude (leading-zero count l, 32 for a zero input), normalises "
    "n=|a|<<l so bit 31 is the implicit one, forms the biased exponent field "
    "F=e-l+127, then rounds the 23-bit fraction round-to-nearest-even from the "
    "8 discarded bits with the tie broken by the kept LSB, propagates a fraction "
    "carry into the exponent, and takes the subnormal path (right shift 9-F, "
    "RNE, sticky, 9<=9-F<=32 handled by 64-bit guard masks, larger shifts "
    "collapse to zero-with-sticky) when F<=0. Overflow to infinity needs the "
    "rounding carry because c[7:0] caps F at 254, and it is reported as a "
    "correctly signed infinity with a flag rather than a fault. result=the "
    "32-bit binary32 pattern with round-to-nearest-even, signed zero preserved "
    "and signed underflow to subnormal or signed zero. aux[7:0]=c[7:0] echoed, "
    "aux[8]=rounding incremented, aux[9]=sticky (information discarded), "
    "aux[10]=subnormal/underflow path taken, aux[11]=overflowed to infinity, "
    "aux[12]=exact (nothing discarded), aux[13]=zero input, aux[14]=sign, "
    "aux[19:15]=0, aux[25:20]=leading-zero count, aux[31:26]=0. fault=1 only on "
    "a nonzero c[31:8] (malformed binary-point selector).",
    B("if(c[31:8]!=24'd0) f=1'b1;",
      "else begin",
      "    fxsign=a[31]; fxe=$signed(c[7:0]);",
      "    fxmag=a[31] ? ((~a)+32'd1) : a;",
      "    pl=32'd0; for(i=0;i<32;i=i+1) if(fxmag[i]) pl=i+1;",
      "    fxlz=6'd32-pl[5:0];",
      "    fxn=fxmag<<<fxlz;",
      "    fxf=fxe-{{5{1'b0}},fxlz}+11'sd127;",
      "    x[7:0]=c[7:0]; x[14]=fxsign; x[25:20]=fxlz; x[19:15]=5'd0;",
      "    x[31:26]=6'd0; x[10]=1'b0; x[11]=1'b0; x[13]=1'b0;",
      "    if(fxmag==32'd0) begin",
      "        r={fxsign,31'd0}; x[12]=1'b1; x[13]=1'b1;",
      "    end else if(fxf>=11'sd1) begin",
      "        fxk={1'd0,fxn[31:8]}; fxr8=fxn[7:0];",
      "        fxsticky=(fxr8!=8'd0);",
      "        fxinc=(fxr8>8'h80) || (fxr8==8'h80 && fxk[0]);",
      "        if(fxinc) fxk=fxk+25'd1;",
      "        if(fxk[24]) begin fxk=fxk>>1; fxf=fxf+11'sd1; end",
      "        if(fxf>=11'sd255) begin",
      "            r={fxsign,8'hff,23'd0}; x[11]=1'b1; x[8]=1'b0;",
      "            x[9]=fxsticky; x[12]=1'b0;",
      "        end else begin",
      "            r={fxsign,fxf[7:0],fxk[22:0]};",
      "            x[8]=fxinc; x[9]=fxsticky; x[12]=!fxsticky;",
      "        end",
      "    end else begin",
      "        fxdrop=11'sd9-fxf;",
      "        if(fxdrop>=11'sd33) begin",
      "            fxk=25'd0; fxsticky=1'b1; fxinc=1'b0;",
      "        end else begin",
      "            sh=fxdrop;",
      "            fxk={1'b0,fxn>>sh};",
      "            fxmask=(64'd1<<<sh)-64'd1;",
      "            fxr={32'd0,fxn}&fxmask;",
      "            fxhalf=64'd1<<<(sh-1);",
      "            fxsticky=(fxr!=64'd0);",
      "            fxinc=(fxr>fxhalf) || (fxr==fxhalf && fxk[0]);",
      "            if(fxinc) fxk=fxk+25'd1;",
      "        end",
      "        x[10]=1'b1; x[8]=fxinc; x[9]=fxsticky; x[12]=!fxsticky;",
      "        r=fxk[23] ? {fxsign,8'd1,23'd0} : {fxsign,8'd0,fxk[22:0]};",
      "    end",
      "end"),
    "A 32-bit priority encoder, a barrel normaliser and a round-to-nearest-even "
    "fix-up settle in one enabled beat: the leading-one position is a wired "
    "OR-reduction, so the cost is independent of the magnitude. A CPU needs a "
    "clz instruction plus a shift, a mask and a conditional exponent increment "
    "per sample, and has no notion of a runtime binary point at all.",
    1, F2L_DECL)

# ----------------------------------------------------------------- float2fix_rne
F2F_DECL = ('function [31:0] f2f_lane;\n'
            '  input [31:0] u;\n'
            '  input signed [7:0] nn;\n'
            '  reg [7:0] fe;\n'
            '  reg [23:0] fm;\n'
            '  reg signed [11:0] ft;\n'
            '  reg [63:0] fc, frr, fhh, fmk;\n'
            '  integer fk;\n'
            '  reg finex, fsat, fbad, fneg, finc;\n'
            '  reg [63:0] fout;\n'
            '  reg [15:0] fof;\n'
            'begin\n'
            "  fe=u[30:23]; fm=u[22:0]; fneg=u[31];\n"
            "  fbad=1'b0; fsat=1'b0; finex=1'b0; finc=1'b0; fout=64'd0;\n"
            "  fof=16'd0; ft=12'sd0;\n"
            "  if(fe==8'hff) fbad=1'b1;\n"
            "  else begin\n"
            "    ft=$signed({3'd0,fe})+nn-12'sd150;\n"
            "    if(fe!=8'd0) fm=fm|24'h800000;\n"
            "    else ft=12'sd1+nn-12'sd150;\n"
            + '''
    if(fm==24'd0) fout=64'd0;
    else if(ft>=12'sd16) fout=64'h100000000;
    else if(ft>=12'sd0) begin
      fk=ft; fout={40'd0,fm}<<<fk;
    end else if((0-ft)>=12'sd25) begin fout=64'd0; finex=1'b1; end
    else begin
      fk=0-ft;
      fmk=(64'd1<<<fk)-64'd1;
      frr={40'd0,fm}&fmk;
      fhh=64'd1<<<(fk-1);
      fout={40'd0,fm}>>>fk;
      finc=(frr>fhh) || (frr==fhh && fout[0]);
      finex=(frr!=64'd0);
      if(finc) fout=fout+64'd1;
    end
    if(fneg) begin
      if(fout>64'd32768) begin fsat=1'b1; fof=16'h8000; end
      else fof=16'd0-fout[15:0];
    end else begin
      if(fout>64'd32767) begin fsat=1'b1; fof=16'h7fff; end
      else fof=fout[15:0];
    end
  end
  f2f_lane={fbad,fsat,finex,finc,12'd0,fof};
end
endfunction
reg signed [7:0] nsc;
reg [31:0] p0, p1;
''')

core('float2fix_rne',
    "binary32 -> Q(n) signed fixed, two lanes per accepted beat (latency 1, not "
    "stateful): lane0 converts a, lane1 converts b, both to the scale 2^n with "
    "n=$signed(c[7:0]) and c[31:8] required zero. Each lane decodes "
    "v=mant*2^(Eff-150) with Eff=max(E,1) and mant=E?M|2^23:M, so subnormal "
    "inputs need no separate path, then forms out=round_to_nearest_even(v*2^n) "
    "with a single rounding step: the exact left shift when the binary point "
    "lands at or below the mantissa LSB (t=n+Eff-150 in [0,15]), "
    "guard/round/sticky right shift with a 64-bit half mask when t is in "
    "[-24,-1], and zero-with-sticky when t<=-25. The magnitude then saturates "
    "into [-32768,32767] with the negative rail allowed to be hit exactly. "
    "result[15:0]=lane0 int16 two's complement, result[31:16]=lane1. "
    "aux[0]=lane0 saturated, aux[1]=lane0 inexact, aux[2]=lane0 rounding "
    "incremented, aux[3]=0, aux[4]=lane1 saturated, aux[5]=lane1 inexact, "
    "aux[6]=lane1 incremented, aux[7]=0, "
    "aux[15:8]=c[7:0] echoed, aux[31:16]=0. fault=1 on a NaN or infinite input "
    "(the fixed target cannot carry those classes) or a nonzero c[31:8]; a "
    "faulted lane pair reports result=aux=0.",
    B("if(c[31:8]!=24'd0) f=1'b1;",
      "else begin",
      "    nsc=$signed(c[7:0]);",
      "    p0=f2f_lane(a,nsc); p1=f2f_lane(b,nsc);",
      "    if(p0[31] || p1[31]) f=1'b1;",
      "    else begin",
      "        r={p1[15:0],p0[15:0]};",
      "        x[0]=p0[30]; x[1]=p0[29]; x[2]=p0[28]; x[3]=1'b0;",
      "        x[4]=p1[30]; x[5]=p1[29]; x[6]=p1[28]; x[7]=1'b0;",
      "        x[15:8]=c[7:0]; x[31:16]=16'd0;",
      "    end",
      "end"),
    "Two independent 32-to-16 conversions share one enable beat: the decode, the "
    "alignment shift and the round-to-nearest-even fix-up are pure combinational "
    "fan-in, so a stereo sample pair costs one cycle instead of two soft-float "
    "conversion calls, and the binary point is a runtime operand rather than a "
    "recompiled constant.",
    2, F2F_DECL)

# --------------------------------------------------------------------- fadd_s32
# `sa`/`sb` are NOT declared here on purpose: the template already declares them
# as 32-bit signed regs.  This core re-uses them as its operand sign bits (only
# bit 0 is ever read, and the concatenations that place them at result[31] take
# exactly that bit), so re-declaring them would be a duplicate declaration.
FADD_DECL = ('reg sgneg, sub, fswap, tmpc;\n'
             'reg [31:0] tmp;\n'
             'reg [7:0] ea, eb;\n'
             'reg [8:0] eA, eB, bef, dd;\n'
             'reg [23:0] mA, mB;\n'
             'reg nanA, nanB, infA, infB;\n'
             'reg [63:0] wv, wq, wr, whalf, wmask, wms, wtmp;\n'
             'reg [6:0] bln;\n'
             'reg signed [8:0] kk;\n'
             'reg signed [12:0] ef;\n'
             'reg [24:0] om;\n'
             'reg pinc, pstk, pinex, zres, ovf;\n')

core('fadd_s32',
    "Minimal IEEE-754 binary32 add/subtract, one operation per accepted beat "
    "(latency 1, not stateful): result=a+b when c[0]=0 and a-b when c[0]=1, with "
    "c[31:1] required zero. The datapath is the classic three-stage unit: "
    "exponent compare (both operands are decoded to the unified form "
    "v=mant*2^(Eff-150) with Eff=max(E,1) and mant=(E==0)?M:(M|2^23), so "
    "subnormal inputs enter the same magnitude comparator as normals and the "
    "larger operand is always routed to the A side), a 26-position alignment "
    "shifter that then adds or subtracts the 24-bit mantissas, and a "
    "normalise-and-round stage that takes exactly one round-to-nearest-even "
    "decision at the final leading-one position (the round position is chosen "
    "from the sum's bit length BEFORE any shift, so there is no double "
    "rounding) plus a sticky bit. An operand more than 25 positions down the "
    "shifter contributes only a sticky bit, which is exact for round-to-nearest: "
    "a representable tie needs the distance to be exactly 24, so it is always "
    "inside the shifter. result=the binary32 pattern under "
    "round-to-nearest-even, with signed zero, exact subnormal output written as "
    "a code, and overflow to a correctly signed infinity. aux[0]=sticky, "
    "aux[1]=inexact, aux[2]=rounding incremented, aux[3]=infinity from "
    "overflow, aux[4]=zero result, aux[5]=subnormal result, aux[6]=operands "
    "swapped by the comparator, aux[7]=effective subtraction (operand sign flips "
    "included), aux[8]=0, aux[9]=infinity operand handled, aux[15:10]=0, "
    "aux[23:16]=alignment distance, aux[31:24]=0. fault=1 on a NaN input, on "
    "infinity-of-opposite-sign subtraction, or a nonzero c[31:1]. Documented "
    "deviation: no NaN payload is propagated (the class is reported as a fault "
    "instead), so this core is a finite-arithmetic adder, not a full IEEE "
    "quieting engine.",
    B("sub=c[0];",
      "if(c[31:1]!=31'd0) f=1'b1;",
      "else begin",
      "    sa=a[31]; ea=a[30:23]; mA={1'b0,a[22:0]};",
      "    sb=b[31]; eb=b[30:23]; mB={1'b0,b[22:0]};",
      "    if(sub) sb=sb^32'd1;",
      "    sgneg=sa^sb; fswap=1'b0;",
      "    nanA=(ea==8'hff && mA[22:0]!=23'd0);",
      "    nanB=(eb==8'hff && mB[22:0]!=23'd0);",
      "    infA=(ea==8'hff && mA[22:0]==23'd0);",
      "    infB=(eb==8'hff && mB[22:0]==23'd0);",
      "    if(nanA || nanB || (infA && infB && sa!=sb)) f=1'b1;",
      "    else if(infA || infB) begin",
      "        r={(infA ? sa : sb),8'hff,23'd0}; x[9]=1'b1; x[7]=sgneg;",
      "        x[6]=1'b0; x[23:16]=8'd0;",
      "    end else begin",
      "        eA=(ea==8'd0) ? 9'd1 : {1'b0,ea};",
      "        eB=(eb==8'd0) ? 9'd1 : {1'b0,eb};",
      "        if(ea!=8'd0) mA[23]=1'b1;",
      "        if(eb!=8'd0) mB[23]=1'b1;",
      "        if(eA<eB || (eA==eB && mA<mB)) begin",
      "            fswap=1'b1; tmp={7'd0,eA}; eA=eB; eB=tmp[8:0];",
      "            tmp={8'd0,mA}; mA=mB; mB=tmp[23:0];",
      "            tmpc=sa; sa=sb; sb=tmpc;",
      "        end",
      "        dd=eA-eB; pstk=1'b0; zres=1'b0; ovf=1'b0; pinc=1'b0;",
      "        pinex=1'b0; kk=9'sd0; ef=13'sd0; om=25'd0; wv=64'd0;",
      "        x[6]=fswap; x[7]=sgneg; x[23:16]=dd[7:0];",
      "        if(mA==24'd0) begin",
      "            r=sgneg ? 32'd0 : {sa,31'd0}; x[4]=1'b1;",
      "        end else begin",
      "            if(dd<=9'd25) begin",
      "                wtmp={40'd0,mA}<<<dd;",
      "                wv=sgneg ? (wtmp-{40'd0,mB}) : (wtmp+{40'd0,mB});",
      "                bef=eB;",
      "            end else begin",
      "                wv={40'd0,mA}; bef=eA; pstk=(mB!=24'd0);",
      "            end",
      "            if(wv==64'd0) begin r=32'd0; x[4]=1'b1; end",
      "            else begin",
      "                bln=7'd0; for(i=0;i<50;i=i+1) if(wv[i]) bln=i+1;",
      "                kk=$signed({2'd0,bln})-9'sd24;",
      "                ef=$signed({4'd0,bef})+{{6'd0,bln}}-13'sd24;",
      "                if(kk>9'sd0) begin",
      "                    sh=kk;",
      "                    wmask=(64'd1<<<sh)-64'd1;",
      "                    wq=wv>>>sh; wr=wv&wmask;",
      "                    whalf=64'd1<<<(sh-1);",
      "                    pinc=(wr>whalf) || (wr==whalf && wq[0]);",
      "                    om=wq+(pinc ? 25'd1 : 25'd0);",
      "                    pinex=(wr!=64'd0) || pstk;",
      "                end else begin",
      "                    om=wv[24:0]; pinex=pstk;",
      "                end",
      "                if(ef>=13'sd1) begin",
      "                    if(kk<=9'sd0) begin sh=24-bln; om=wv<<<sh; end",
      "                    if(om[24]) begin om=om>>1;",
      "                        ef=ef+13'sd1; end",
      "                    if(ef>=13'sd255) begin",
      "                        r={sa,8'hff,23'd0}; ovf=1'b1; x[3]=1'b1;",
      "                    end else r={sa,ef[7:0],om[22:0]};",
      "                end else begin",
      "                    sh=bef-9'd1; wms=wv<<<sh;",
      "                    r={sa,8'd0,wms[22:0]}; x[5]=1'b1;",
      "                end",
      "                x[0]=pstk; x[1]=pinex; x[2]=pinc;",
      "                x[4]=(r[30:0]==31'd0);",
      "            end",
      "        end",
      "    end",
      "end"),
    "A full alignment/normalise/round adder settles inside one enabled beat: the "
    "26-position shifter, the leading-one encoder and the tie-breaking round "
    "network are wired fan-in, so consecutive beats stream at interval 1 and the "
    "inexact and sticky flags come out beside the value. A soft core calls a "
    "library routine that unpacks both operands, branches on the exponent "
    "difference and runs a separate normalise loop, costing tens of instructions "
    "per sum.",
    1, FADD_DECL)

# --------------------------------------------------------------------- bf16_mul
BFM_DECL = ('function [23:0] bf_num;\n'
            '  input [7:0] ax; input [7:0] ay; input [7:0] ex; input [7:0] ey;\n'
            '  input sgn; input [15:0] pp;\n'
            '  reg [5:0] bl; reg signed [11:0] eo, drop; reg [31:0] q, rr, hh;\n'
            '  reg [31:0] msk; reg inc, inex, subn; integer k;\n'
            'begin\n'
            '  bl=6\'d0; for(k=0;k<16;k=k+1) if(pp[k]) bl=k+1;\n'
            '  eo=$signed({4\'d0,ex})+$signed({4\'d0,ey})+$signed({6\'d0,bl})-12\'sd142;\n'
            '  subn=(eo<=12\'sd0);\n'
            '  if(!subn) drop=$signed({6\'d0,bl})-12\'sd8;\n'
            '  else drop=12\'sd135-$signed({4\'d0,ex})-$signed({4\'d0,ey});\n'
            '  msk=32\'d0; rr=32\'d0; hh=32\'d0; q=32\'d0; k=0;\n'
            '  if(drop>=12\'sd1) begin\n'
            "      if(drop>=12'sd17) begin q=32'd0; inc=1'b0; inex=1'b1; end\n"
            '      else begin\n'
            '          k=drop; msk=(32\'d1<<<k)-32\'d1;\n'
            '          rr={16\'d0,pp}&msk; hh=32\'d1<<<(k-1);\n'
            '          q={16\'d0,pp}>>>k;\n'
            '          inc=(rr>hh) || (rr==hh && q[0]); inex=(rr!=32\'d0);\n'
            '          if(inc) q=q+32\'d1;\n'
            '      end\n'
            '  end else begin\n'
            '      k=0-drop; q={16\'d0,pp}<<<k; inc=1\'b0; inex=1\'b0;\n'
            '  end\n'
            '  if(subn) begin\n'
            '      if(q>=32\'d128) bf_num={1\'b0,inex,inc,1\'b1,1\'b0,\n'
            '                              3\'d0,{sgn,8\'d1,7\'d0}};\n'
            '      else bf_num={1\'b0,inex,inc,1\'b1,(q==32\'d0),\n'
            '                    3\'d0,{sgn,8\'d0,q[6:0]}};\n'
            '  end else begin\n'
            '      if(q>32\'d255) begin q=q>>1; eo=eo+12\'sd1; end\n'
            '      if(eo>=12\'sd255) bf_num={1\'b1,1\'b1,inc,1\'b0,1\'b0,\n'
            '                                3\'d0,{sgn,8\'hff,7\'d0}};\n'
            '      else bf_num={1\'b0,inex,inc,1\'b0,1\'b0,\n'
            '                    3\'d0,{sgn,eo[7:0],q[6:0]}};\n'
            '  end\n'
            'end\n'
            'endfunction\n'
            'reg [7:0] bax0, bay0, bex0, bey0, bax1, bay1, bex1, bey1;\n'
            'reg bs0, bs1, bzero0, bzero1, binf0, binf1, bbad0, bbad1;\n'
            'reg [15:0] bbx0, bby0, bbx1, bby1;\n'
            'reg [23:0] bp0, bp1;\n'
            'reg [15:0] bpr0, bpr1;\n'
            + shift_add_mul('um8', 8, False))

core('bf16_mul',
    "bfloat16 pair multiply, two lanes per accepted beat (latency 1, not "
    "stateful): lane0 is a[15:0]*b[15:0] and lane1 is a[31:16]*b[31:16], each "
    "bf16 being {sign, 8-bit exponent (bias 127), 7-bit fraction}. Both lanes "
    "decode to the unified form v=mant*2^(Eff-134) with Eff=max(E,1), so "
    "subnormal inputs (mant=M, Eff=1) share the normal path, and each lane "
    "forms its 8x8 mantissa product with the um8 shift-add recode (eight "
    "conditional partial-product adds; operands never exceed 255, so the 16-bit "
    "accumulator is exact and no Verilog `*` is emitted). The exponent fields are added "
    "and the product's leading-one position picks a single round-to-nearest-"
    "even step: result exponent field = Ex+Ey+p-141 with the mantissa shifted "
    "right p-7, and when that field would be <= 0 the lane instead takes the "
    "subnormal grid shift 135-Ex-Ey with the same RNE step, so a rounded-up "
    "code of 2^7 correctly becomes the smallest normal. A fraction carry beyond "
    "bit 7 increments the field, and a field of 255 becomes a correctly signed "
    "infinity. Infinity times a zero (or a NaN) is refused rather than "
    "silently turned into a quiet NaN, and any other infinity operand produces "
    "the sign-XOR infinity. result[15:0]=lane0 bf16 pattern, "
    "result[31:16]=lane1. aux[0]=lane0 infinity, aux[1]=lane0 zero result, "
    "aux[2]=lane0 inexact, aux[3]=lane0 rounding incremented, aux[4]=lane0 "
    "subnormal-grid path, aux[5..9]=the same five flags for lane1, aux[15:10]=0, "
    "aux[31:16]=lane0's 16-bit mantissa product. fault=1 when either lane sees "
    "a NaN operand or a 0*infinity pair (result=aux=0).",
    B("bbx0=a[15:0]; bby0=b[15:0]; bbx1=a[31:16]; bby1=b[31:16];",
      "bex0=bbx0[14:7]; bey0=bby0[14:7]; bex1=bbx1[14:7]; bey1=bby1[14:7];",
      "bax0=(bex0==8'd0) ? {1'b0,bbx0[6:0]} : {1'b1,bbx0[6:0]};",
      "bay0=(bey0==8'd0) ? {1'b0,bby0[6:0]} : {1'b1,bby0[6:0]};",
      "bax1=(bex1==8'd0) ? {1'b0,bbx1[6:0]} : {1'b1,bbx1[6:0]};",
      "bay1=(bey1==8'd0) ? {1'b0,bby1[6:0]} : {1'b1,bby1[6:0]};",
      "bs0=bbx0[15]^bby0[15]; bs1=bbx1[15]^bby1[15];",
      "bzero0=1'b0; bzero1=1'b0; binf0=1'b0; binf1=1'b0;",
      "bbad0=1'b0; bbad1=1'b0; bp0=24'd0; bp1=24'd0;",
      "bpr0=um8(bax0,bay0); bpr1=um8(bax1,bay1);",
      "if((bex0==8'hff && bbx0[6:0]!=7'd0) || (bey0==8'hff && bby0[6:0]!=7'd0))",
      "    bbad0=1'b1;",
      "if((bex1==8'hff && bbx1[6:0]!=7'd0) || (bey1==8'hff && bby1[6:0]!=7'd0))",
      "    bbad1=1'b1;",
      "if((bex0==8'hff && bay0==8'd0) || (bey0==8'hff && bax0==8'd0))",
      "    bbad0=1'b1;",
      "if(!bbad0) begin",
      "    if((bex0==8'hff) || (bey0==8'hff)) begin",
      "        binf0=1'b1; bp0={1'b1,1'b0,1'b0,1'b0,1'b0,3'd0,",
      "                          {bs0,8'hff,7'd0}};",
      "    end else if(bax0==8'd0 || bay0==8'd0) begin",
      "        bzero0=1'b1; bp0={1'b0,1'b0,1'b0,1'b0,1'b1,3'd0,",
      "                          {bs0,8'd0,7'd0}};",
      "    end else bp0=bf_num(bax0,bay0,(bex0==8'd0)?8'd1:bex0,",
      "                         (bey0==8'd0)?8'd1:bey0,bs0,bpr0[15:0]);",
      "end",
      "if((bex1==8'hff && bay1==8'd0) || (bey1==8'hff && bax1==8'd0))",
      "    bbad1=1'b1;",
      "if(!bbad1) begin",
      "    if((bex1==8'hff) || (bey1==8'hff)) begin",
      "        binf1=1'b1; bp1={1'b1,1'b0,1'b0,1'b0,1'b0,3'd0,",
      "                          {bs1,8'hff,7'd0}};",
      "    end else if(bax1==8'd0 || bay1==8'd0) begin",
      "        bzero1=1'b1; bp1={1'b0,1'b0,1'b0,1'b0,1'b1,3'd0,",
      "                          {bs1,8'd0,7'd0}};",
      "    end else bp1=bf_num(bax1,bay1,(bex1==8'd0)?8'd1:bex1,",
      "                         (bey1==8'd0)?8'd1:bey1,bs1,bpr1[15:0]);",
      "end",
      "if(bbad0 || bbad1) f=1'b1;",
      "else begin",
      "    r={bp1[15:0],bp0[15:0]};",
      "    x[0]=bp0[23]; x[1]=bp0[19]; x[2]=bp0[22]; x[3]=bp0[21];",
      "    x[4]=bp0[20]; x[5]=bp1[23]; x[6]=bp1[19]; x[7]=bp1[22];",
      "    x[8]=bp1[21]; x[9]=bp1[20]; x[15:10]=6'd0; x[31:16]=bpr0[15:0];",
      "end"),
    "Two independent bf16 products retire per enabled beat on two wired shift-add "
    "arrays: each lane is one 8x8 recode plus a wired exponent add and one "
    "round-to-nearest-even step, so a pair of ML activations costs one beat, "
    "while the same pair through a soft path needs two unpack-multiply-repack "
    "subroutines with a normalise branch each.",
    2, BFM_DECL)
# ------------------------------------------------------------------- csd_recode
CSD_DECL = ('reg [16:0] cv, cvn;\n'
            'reg [31:0] cacc, caccn;\n'
            'reg [4:0] cnt, cntn, cnz, cnzn;\n'
            'reg cdone, cdonen, chold, csig, cmgneg, csinn, cnzsig;\n'
            'reg [1:0] ccode;\n')

core('csd_recode',
    "Canonical signed digit (non-adjacent form) recoder for a signed 16-bit "
    "constant, one digit per accepted beat. Seed beat (c[31]=1) takes "
    "v=a[15:0] signed, latches its sign and its magnitude in 17 bits (so "
    "-2^15 keeps 2^15 exactly) and emits digit 0; each later beat takes the "
    "current odd value's residue modulo 4 - digit +1 when v mod 4 is 1, digit -1 "
    "when it is 3, digit 0 when v is even - and shifts v down by one position, "
    "so the weight-never-increases property holds and 16 digits always finish "
    "any 16-bit input. result=the add/subtract op list packed two bits per "
    "digit with digit i in result[2i+1:2i] as a 2-bit two's-complement signed "
    "operation code (00 add zero, 01 add, 11 subtract), i.e. exactly the control "
    "word a shift-add constant multiplier consumes; it is built up as the digits "
    "arrive, so a partially converged result is the low part of the list. "
    "aux[4:0]=digits emitted (0..16), aux[5]=converged, aux[6]=idle repeat, "
    "aux[7]=this beat's digit is nonzero, aux[8]=this beat's digit is a subtract "
    "(after the input sign is folded in), aux[13:9]=nonzero digit count so far, "
    "aux[14]=input sign, aux[15]=0, aux[31:16]=low 16 bits of the value still to "
    "recode. Later beats with c[31]=0 once done repeat the converged list. No "
    "input pattern is invalid, so this core is declared faultless.",
    B("cv=state_r[16:0]; cacc=state_r[48:17]; cnt=state_r[53:49];",
      "cnz=state_r[58:54]; cdone=state_r[59]; csinn=state_r[60];",
      "cvn=cv; caccn=cacc; cntn=cnt; cnzn=cnz; cdonen=cdone;",
      "chold=1'b0; ccode=2'b00; cnzsig=1'b0; csig=1'b0;",
      "if(c[31]) begin",
      "    csinn=a[15];",
      "    cv=a[15] ? ({1'b0,~a[15:0]}+17'd1) : {1'b0,a[15:0]};",
      "    cacc=32'd0; cnt=5'd0; cnz=5'd0; cdone=1'b0;",
      "    cvn=cv; caccn=cacc; cntn=cnt; cnzn=cnz; cdonen=cdone;",
      "end else if(cdone) begin",
      "    chold=1'b1;",
      "end",
      "if(!chold) begin",
      "    if(cv[0]) begin",
      "        csig=csinn ? !cv[1] : cv[1];",
      "        ccode=csig ? 2'b11 : 2'b01;",
      "        cvn=(csig^csinn) ? ((cv+17'd1)>>1) : ((cv-17'd1)>>1);",
      "        cnzsig=1'b1;",
      "      end else begin",
      "        ccode=2'b00; cvn=cv>>1;",
      "    end",
      "    sh=cnt+cnt;",
      "    caccn=cacc|({30'd0,ccode}<<<sh);",
      "    cntn=cnt+5'd1;",
      "    cnzn=cnz+(cnzsig ? 5'd1 : 5'd0);",
      "    cdonen=(cntn==5'd16);",
      "end",
      "r=caccn;",
      "x[4:0]=cntn; x[5]=cdonen; x[6]=chold; x[7]=cnzsig; x[8]=csig;",
      "x[13:9]=cnzn; x[14]=csinn; x[15]=1'b0; x[31:16]=cvn[15:0];",
      "state_n={195'd0, csinn, cdonen, cnzn, cntn, caccn, cvn};"),
    "A constant recode that would be a modulo-4 table plus a branch in software "
    "is here one residue test, one add or subtract by one and one shift per "
    "enabled beat, and the op list is assembled in the output register as it "
    "goes, so a downstream shift-add multiplier starts consuming digits before "
    "the recode finishes. Halving the operand digit count for constant "
    "multiplication is a structural win no instruction sequence changes.",
    1, CSD_DECL, stateful=True, faultless=True)

# --------------------------------------------------------------------- mont_mul
MONT_DECL = (fun_text('n_at', 22, [n for n, _ in MONT_TABLE], 3) +
             fun_text('np_at', 11, [p for _, p in MONT_TABLE], 3,
                      comment='  // -N^-1 mod 2^11 of N={value}') +
             shift_add_mul('um11', 11, False) +
             'reg [44:0] mc, mcn, madd;\n'
             'reg [21:0] mn, mnl, mnh;\n'
             'reg [21:0] mprod, pnlo, pnnh;\n'
             'reg [10:0] mnp, mm, mslo;\n'
             'reg [1:0] mlimb, mlimbn;\n'
             'reg [2:0] mk;\n'
             'reg mdone, mhold, msub, msubn;\n')

core('mont_mul',
    "Montgomery reduction (REDC) engine for the 22-bit modular multiply, one "
    "reduction limb per accepted beat. Three products per limb (m=lo*N', "
    "m*N_lo and m*N_hi) are formed by the um11 shift-add recode, 11 conditional "
    "partial-product adds each, so no Verilog `*` and no hardware multiplier "
    "cell appears in this core. "
    "The caller supplies the 44-bit product word T=a*b as a[21:0] in the "
    "high half and b[21:0] in the low half, and c[2:0] picks one of eight odd "
    "moduli whose N'=-N^-1 mod 2^11 is derived in this file by 2-adic Newton "
    "iteration. Seed beat (c[31]=1) latches C=T, N, N' and clears the limb "
    "counter, and it faults when T>=N*R (R=2^22) because REDC's single "
    "conditional subtraction only proves a result below N in the complementary "
    "range; for a real product T=a*b with a,b<N that test always passes since "
    "N<R. Beats 1 and 2 run one word-based reduction step each: "
    "m=(C mod 2^11)*N' mod 2^11, then C <- (C + m*N)/2^11, which is exact "
    "because m is chosen to cancel the low limb; beat 3 applies the conditional "
    "subtraction C <- C-N when C>=N and sets the converged flag; later beats with "
    "c[31]=0 repeat the residue. result=the low 32 bits of the running "
    "reduction window, so on the seed beat it is T[31:0] and once converged it "
    "is a*b*R^-1 mod N (below N, hence result[31:22]=0). aux[2:0]=modulus index, "
    "aux[4:3]=beats of work done (0..3), aux[5]=converged, aux[6]=idle repeat, "
    "aux[7]=final conditional subtraction applied, aux[18:8]=the Montgomery "
    "multiplier m used by the step just run (zero on a seed or idle beat), "
    "aux[31:19]=low 13 bits of the current window. fault=1 on T>=N*R or on a "
    "nonzero c[30:3] (malformed modulus selector; c[31] is the seed bit).",
    B("mc=state_r[44:0]; mn=state_r[66:45]; mnp=state_r[77:67];",
      "mlimb=state_r[79:78]; mk=state_r[82:80]; mm=state_r[93:83];",
      "mdone=state_r[94]; msub=state_r[95];",
      "mcn=mc; mlimbn=mlimb; msubn=msub; mhold=1'b0;",
      "madd=45'd0; mslo=11'd0; mprod=22'd0; pnlo=22'd0; pnnh=22'd0;",
      "mnl=22'd0; mnh=22'd0;",
      "if(c[31]) begin",
      "    if(c[30:3]!=28'd0) f=1'b1;",
      "    else begin",
      "        mk=c[2:0]; mn=n_at(mk); mnp=np_at(mk);",
      "        mc={1'b0,a[21:0],b[21:0]};",
      "        if(mc[43:22]>=mn) f=1'b1;",
      "        else begin",
      "            mcn=mc; mlimbn=2'd0; mm=11'd0; mdone=1'b0; msubn=1'b0;",
      "        end",
      "    end",
      "end else if(mlimb==2'd3) begin",
      "    mhold=1'b1; mcn=mc; mm=11'd0;",
      "end else begin",
      "    mnl=mn[10:0]; mnh=mn[21:11];",
      "    if(mlimb==2'd0 || mlimb==2'd1) begin",
      "        mslo=mc[10:0];",
      "        mprod=um11(mslo,mnp);",
      "        mm=mprod[10:0];",
      "        pnlo=um11(mm,mnl);",
      "        pnnh=um11(mm,mnh);",
      "        madd={22'd0,pnlo}+({22'd0,pnnh}<<<11);",
      "        mcn=(mc+madd)>>11;",
      "        mlimbn=mlimb+2'd1;",
      "      end else begin",
      "        if(mc>=mn) begin mcn=mc-{23'd0,mn}; msubn=1'b1; end",
      "        else mcn=mc;",
      "        mlimbn=2'd3; mdone=1'b1; mm=11'd0;",
      "    end",
      "end",
      "if(!f) begin",
      "    r=mcn[31:0];",
      "    x[2:0]=mk; x[4:3]=mlimbn; x[5]=mdone; x[6]=mhold;",
      "    x[7]=msubn; x[18:8]=mm; x[31:19]=mcn[12:0];",
      "    state_n={160'd0, msubn, mdone, mm, mk, mlimbn, mnp, mn, mcn};",
      "end"),
    "A Montgomery step is one 11x11 product to pick the multiplier and two more "
    "to fold it into the accumulator; wiring all three shift-add recodes per beat "
    "means the "
    "modular reduction of a 44-bit product costs 4 enabled beats with no "
    "division, no comparison-retry loop and no variable-latency branch, which is "
    "the shape a CPU cannot match: its modulo needs a divide (or a reciprocal "
    "table plus fix-ups) per reduction and pays it again for every limb.",
    1, MONT_DECL, stateful=True)

# ============================================================ integer models
# Each m_* below is a statement-for-statement transcription of that core's kernel
# body: the same register widths, the same truncations, the same order of
# evaluation and the same aux field placement.  That is what makes the generated
# testbench a cross-check of the RTL instead of a tautology -- the RTL is built
# from `body`, the vectors from `m_*`, and they only agree if both implement the
# same arithmetic.  U() truncates like a Verilog assignment, S() re-reads the
# truncated pattern as two's complement, `>>` is the arithmetic shift Verilog's
# `>>>` performs on a signed reg, and field() is a Verilog bit slice.
def U(value, width):
    return value & ((1 << width) - 1)


def S(value, width):
    value &= (1 << width) - 1
    return value - (1 << width) if value >> (width - 1) else value


def field(value, low, high):
    return (value >> low) & ((1 << (high - low + 1)) - 1)


PID20 = S(CORDIC_PI, 24)                 # the 24-bit signed localparam


def m_cordic(a, b, c, state):
    cx = S(field(state, 0, 22), 23)
    cy = S(field(state, 23, 45), 23)
    cz = S(field(state, 46, 67), 22)
    ccnt = field(state, 68, 72)
    cfl = field(state, 73, 73)
    cxn, cyn, czn, ccntn, cfln = cx, cy, cz, ccnt, cfl
    cfsgn = field(state, 74, 74)
    chold = cdir = cix = 0
    f = 0
    if c >> 31:
        if field(a, 0, 15) == 0 and field(a, 16, 31) == 0:
            f = 1
        else:
            csv = S(field(a, 0, 15), 16)
            csv2 = S(field(a, 16, 31), 16)
            if csv < 0:
                cmx, cmy, cfln = -csv, -csv2, 1
                cfsgn = 1 if csv2 >= 0 else 0
            else:
                cmx, cmy, cfln, cfsgn = csv, csv2, 0, 1
            cmm = -cmy if cmy < 0 else cmy
            if cmx > cmm:
                cmm = cmx
            sh = 20 - cmm.bit_length()
            cx, cy, cz, ccnt, cix = S(cmx << sh, 23), S(cmy << sh, 23), 0, 0, 0
    elif ccnt == 16:
        chold = 1
    else:
        cix = ccnt & 15
    r = x = 0
    if not f:
        if not chold:
            cai = CORDIC_ATAN[cix] if cix < len(CORDIC_ATAN) else 0
            if cy >= 0:
                cxn = S(cx + (cy >> cix), 23)
                cyn = S(cy - (cx >> cix), 23)
                czn = S(cz + cai, 22)
                cdir = 1
            else:
                cxn = S(cx - (cy >> cix), 23)
                cyn = S(cy + (cx >> cix), 23)
                czn = S(cz - cai, 22)
                cdir = 0
            ccntn = (ccnt + 1) & 31
        pre = 0 if not cfln else (PID20 if cfsgn else -PID20)
        cang = S(S(czn, 24) + S(pre, 24), 24)
        r = S(S(cang + 8, 24) >> 4, 32)
        x = (cix & 15) | ((1 if ccntn == 16 else 0) << 4) | (cfln << 5) | \
            (cdir << 6) | (chold << 7) | (U(cyn, 16) << 8)
        state = (cfsgn << 74) | (cfln << 73) | (ccntn << 68) | \
            (U(czn, 22) << 46) | (U(cyn, 23) << 23) | U(cxn, 23)
    return U(r, 32), U(x, 32), f, state


def m_isqrt(a, b, c, state):
    sqm = field(state, 0, 32)
    sqr = field(state, 33, 48)
    sqi = field(state, 49, 53)
    sqdon = field(state, 54, 54)
    sqn, sqrn, sqin = sqm, sqr, sqi
    sqdonn, sqhold, sqadd = sqdon, 0, 0
    if c >> 31:
        sqm = U(a, 32)
        sqr, sqi, sqdon = 0, 15, 0
        sqn, sqrn, sqin, sqdonn = sqm, sqr, sqi, sqdon
    elif sqdon:
        sqhold = 1
    else:
        sh = sqi + 1
        sqsh = U(sqr << sh, 33)
        sh = sqi + sqi
        sqadd = U(sqsh | U(1 << sh, 33), 33)
        if sqm >= sqadd:
            sqn = U(sqm - sqadd, 33)
            sqin = sqi
            sqrn = U(sqr | U(1 << sqi, 16), 16)
        else:
            sqn, sqrn = sqm, sqr
        sqin = 0 if sqi == 0 else U(sqi - 1, 5)
        sqdonn = 1 if sqi == 0 else 0
    r = U(sqrn, 16)
    x = U(sqin, 5) | (sqdonn << 5) | (sqhold << 6) | (U(sqn, 25) << 7)
    state = (sqdonn << 54) | (sqin << 49) | (sqrn << 33) | sqn
    return r, x, 0, state


def m_csd(a, b, c, state):
    cv = field(state, 0, 16)
    cacc = field(state, 17, 48)
    cnt = field(state, 49, 53)
    cnz = field(state, 54, 58)
    cdone = field(state, 59, 59)
    csinn = field(state, 60, 60)
    cvn, caccn, cntn, cnzn, cdonen = cv, cacc, cnt, cnz, cdone
    chold = ccode = cnzsig = csig = 0
    if c >> 31:
        csinn = (a >> 15) & 1
        a16 = U(a, 16)
        cv = U((a16 ^ 0xFFFF) + 1, 17) if csinn else a16
        cacc = cnt = cnz = cdone = 0
        cvn, caccn, cntn, cnzn, cdonen = cv, cacc, cnt, cnz, cdone
    elif cdone:
        chold = 1
    if not chold:
        if cv & 1:
            csig = (1 - ((cv >> 1) & 1)) if csinn else ((cv >> 1) & 1)
            ccode = 3 if csig else 1
            cvn = U((cv + 1) >> 1, 17) if (csig ^ csinn) else U((cv - 1) >> 1, 17)
            cnzsig = 1
        else:
            ccode = 0
            cvn = U(cv >> 1, 17)
        caccn = U(cacc | (U(ccode, 2) << (cnt + cnt)), 32)
        cntn = U(cnt + 1, 5)
        cnzn = U(cnz + cnzsig, 5)
        cdonen = 1 if cntn == 16 else 0
    r = U(caccn, 32)
    x = U(cntn, 5) | (cdonen << 5) | (chold << 6) | (cnzsig << 7) | (csig << 8) | \
        (U(cnzn, 5) << 9) | (csinn << 14) | (U(cvn, 16) << 16)
    state = (csinn << 60) | (cdonen << 59) | (U(cnzn, 5) << 54) | (cntn << 49) | \
        (U(caccn, 32) << 17) | U(cvn, 17)
    return r, x, 0, state


def m_div(a, b, c, state):
    dr = S(field(state, 0, 34), 35)
    dq = field(state, 35, 66)
    dds = field(state, 67, 100)
    ddn = field(state, 101, 132)
    dcnt = field(state, 133, 138)
    dsgn = field(state, 139, 139)
    drst = field(state, 140, 140)
    drn, dqn, dcntn, dsgnn, drstn = dr, dq, dcnt, dsgn, drst
    dhold = dbit = 0
    f = 0
    av, bv = U(a, 32), U(b, 32)
    if c >> 31:
        if bv == 0 or (av == 0x80000000 and bv == 0xFFFFFFFF):
            f = 1
        else:
            dds = U((bv ^ 0xFFFFFFFF) + 1, 34) if (bv >> 31) else U(bv, 34)
            ddn = U((av ^ 0xFFFFFFFF) + 1, 32) if (av >> 31) else av
            dsgnn = (av >> 31) ^ (bv >> 31)
            drn, dqn, dcntn, drstn = 0, 0, 0, 0
    elif dcnt == 33:
        dhold = 1
    else:
        dds2 = U(dds, 35)
        if dcnt == 32:
            if dr < 0:
                drn = S(dr + dds2, 35)
                drstn = 1
            dcntn, dqn = 33, dq
        else:
            sh = 31 - dcnt
            dbit = (ddn >> sh) & 1
            dm = S(U(dr << 1, 35) | dbit, 35)
            dn = S(dm - dds2, 35) if dm >= 0 else S(dm + dds2, 35)
            drn = dn
            dqn = U(((dq & 0x7FFFFFFF) << 1) | (1 if dn >= 0 else 0), 32)
            dcntn = U(dcnt + 1, 6)
    r = x = 0
    if not f:
        r = U(-dqn if dsgnn else dqn, 32)
        x = U(dcntn, 6) | ((1 if dcntn == 33 else 0) << 6) | (dsgnn << 7) | \
            (drstn << 8) | ((1 if dds > 0x7FFFFFFF else 0) << 9) | (dbit << 10) | \
            (U(drn, 21) << 11)
        state = (drstn << 140) | (dsgnn << 139) | (dcntn << 133) | (ddn << 101) | \
            (dds << 67) | (dqn << 35) | U(drn, 35)
    return r, x, f, state


def umul(u, v, bits):
    """Exactly what the generated shift_add_mul function computes: one
    conditional partial-product add per bit of v, accumulated in 2*bits."""
    u, v = U(u, bits), U(v, bits)
    acc = 0
    for k in range(bits):
        if (v >> k) & 1:
            acc = U(acc + (u << k), 2 * bits)
    return acc


def smul(u, v, bits):
    """The signed form: sign-magnitude, unsigned umul, conditional negate."""
    su, sv = S(U(u, bits), bits) < 0, S(U(v, bits), bits) < 0
    au = U(-S(U(u, bits), bits), bits) if su else U(u, bits)
    av = U(-S(U(v, bits), bits), bits) if sv else U(v, bits)
    acc = umul(au, av, bits)
    return S(-acc if (su ^ sv) else acc, 2 * bits)


def m_nr(a, b, c, state):
    ne = S(field(state, 0, 11), 12)
    nv = S(field(state, 12, 23), 12)
    nph = field(state, 24, 27)
    nsg = field(state, 28, 28)
    nbin, nwait, nt24, f = 0, 0, 0, 0
    nvn = nv
    if c >> 31:
        d12 = U(a, 12)
        if d12 <= 2048:
            f = 1
        else:
            ne = S(d12 - 3072, 27)
            nbin = (a >> 6) & 0x3F
            nv = S(NR_SEED[nbin], 12)
            nvn = nv
            nph = 0
            nsg = (a >> 12) & 1
    elif nph == 4:
        nwait = 1
    else:
        nd = S(3072 + ne, 27)
        na24 = S(18874368 + S(ne << 12, 27) + S(ne << 11, 27) + S(nv << 11, 27) +
                 S(nv << 10, 27) + smul(ne, nv, 12), 27)
        nt24 = S(16777216 - na24, 27)
        if nph == 3:
            ntt = S(nt24 << 1, 27)
            if ntt >= nd:
                nvn = S(nv + 1, 27)
            elif ntt <= -nd:
                nvn = S(nv - 1, 27)
            nph = 4
        else:
            sh = (7, 3, 1)[nph]
            nlim = S(2048 << sh, 27)
            if nt24 >= nlim or nt24 <= -nlim:
                f = 1
            else:
                ntq = S(nt24 >> sh, 27)
                ng = S(S(ntq << 12, 27) + S(ntq << 11, 27) + smul(nv, ntq, 12), 27)
                nco = S((ng + (1 << (23 - sh))) >> (24 - sh), 27)
                nvn = S(nv + nco, 27)
                if nvn < -2048 or nvn > 2047:
                    f = 1
                else:
                    nph = U(nph + 1, 4)
    r = x = 0
    if not f:
        nY = U(6144 + U(nvn, 13), 13)
        nres = -nY if nsg else nY
        r = U(nres, 32)
        x = U(nph, 3) | ((1 if nph == 4 else 0) << 3) | (nsg << 4) | (nwait << 5) | \
            (U(nbin, 6) << 10) | (U(nt24, 16) << 16)
        state = (nsg << 28) | (U(nph, 4) << 24) | (U(nvn, 12) << 12) | U(ne, 12)
    return r, x, f, state


def m_fix2float(a, b, c, state):
    if U(c, 32) >> 8:
        return 0, 0, 1, state
    fxsign = (a >> 31) & 1
    fxe = S(U(c, 8), 8)
    fxmag = U((U(a, 32) ^ 0xFFFFFFFF) + 1, 32) if fxsign else U(a, 32)
    fxlz = U(32 - U(fxmag.bit_length(), 6), 6)
    fxn = U(fxmag << fxlz, 32)
    fxf = S(fxe - fxlz + 127, 11)
    base = U(c, 8) | (fxsign << 14) | (U(fxlz, 6) << 20)
    if fxmag == 0:
        return U(fxsign << 31, 32), base | (1 << 12) | (1 << 13), 0, state
    if fxf >= 1:
        fxk = fxn >> 8
        fxr8 = U(fxn, 8)
        fxsticky = 1 if fxr8 else 0
        fxinc = 1 if (fxr8 > 0x80 or (fxr8 == 0x80 and (fxk & 1))) else 0
        fxk = U(fxk + fxinc, 25)
        if fxk >> 24:
            fxk = U(fxk >> 1, 25)
            fxf = S(fxf + 1, 11)
        if fxf >= 255:
            return U((fxsign << 31) | (0xFF << 23), 32), \
                base | (1 << 11) | (fxsticky << 9), 0, state
        return U((fxsign << 31) | (U(fxf, 8) << 23) | U(fxk, 23), 32), \
            base | (fxinc << 8) | (fxsticky << 9) | ((0 if fxsticky else 1) << 12), \
            0, state
    fxdrop = S(9 - fxf, 11)
    if fxdrop >= 33:
        fxk, fxsticky, fxinc = 0, 1, 0
    else:
        fxk = fxn >> fxdrop
        fxr = fxn & ((1 << fxdrop) - 1)
        fxhalf = 1 << (fxdrop - 1)
        fxsticky = 1 if fxr else 0
        fxinc = 1 if (fxr > fxhalf or (fxr == fxhalf and (fxk & 1))) else 0
        fxk = U(fxk + fxinc, 25)
    pattern = (1 << 23) if (fxk >> 23) else U(fxk, 23)
    return U((fxsign << 31) | pattern, 32), \
        base | (1 << 10) | (fxinc << 8) | (fxsticky << 9) | \
        ((0 if fxsticky else 1) << 12), 0, state


def _f2f_lane(u, nn):
    """One lane of the generated f2f_lane function, statement for statement."""
    fe = (u >> 23) & 0xFF
    fm = U(u, 23)
    fneg = (u >> 31) & 1
    fbad = fsat = finex = finc = 0
    fout = 0
    fof = 0
    if fe == 0xFF:
        fbad = 1
    else:
        ft = S(U(fe, 12) + nn - 150, 12)
        if fe != 0:
            fm = U(fm | (1 << 23), 24)
        else:
            ft = S(1 + nn - 150, 12)
        if fm == 0:
            fout = 0
        elif ft >= 16:
            fout = 0x100000000
        elif ft >= 0:
            fout = U(fm << ft, 64)
        elif (0 - ft) >= 25:
            fout = 0
            finex = 1
        else:
            fk = 0 - ft
            frr = fm & ((1 << fk) - 1)
            fhh = 1 << (fk - 1)
            fout = fm >> fk
            finc = 1 if (frr > fhh or (frr == fhh and (fout & 1))) else 0
            finex = 1 if frr else 0
            fout = U(fout + finc, 64)
        if fneg:
            if fout > 32768:
                fsat, fof = 1, 0x8000
            else:
                fof = U(-U(fout, 16), 16)
        else:
            if fout > 32767:
                fsat, fof = 1, 0x7FFF
            else:
                fof = U(fout, 16)
    return U((fbad << 31) | (fsat << 30) | (finex << 29) | (finc << 28) | fof, 32)


def m_f2f(a, b, c, state):
    if U(c, 32) >> 8:
        return 0, 0, 1, state
    nsc = S(U(c, 8), 8)
    p0, p1 = _f2f_lane(U(a, 32), nsc), _f2f_lane(U(b, 32), nsc)
    if (p0 >> 31) & 1 or (p1 >> 31) & 1:
        return 0, 0, 1, state
    r = U((U(p1, 16) << 16) | U(p0, 16), 32)
    x = ((p0 >> 30) & 1) | (((p0 >> 29) & 1) << 1) | (((p0 >> 28) & 1) << 2) | \
        (((p1 >> 30) & 1) << 4) | (((p1 >> 29) & 1) << 5) | (((p1 >> 28) & 1) << 6) | \
        (U(c, 8) << 8)
    return r, U(x, 32), 0, state


def m_fadd(a, b, c, state):
    sub = c & 1
    if U(c, 32) >> 1:
        return 0, 0, 1, state
    sa, ea, mA = (a >> 31) & 1, (a >> 23) & 0xFF, U(a, 23)
    sb, eb, mB = (b >> 31) & 1, (b >> 23) & 0xFF, U(b, 23)
    if sub:
        sb ^= 1
    sgneg = sa ^ sb
    fswap = 0
    nanA, nanB = ea == 0xFF and mA != 0, eb == 0xFF and mB != 0
    infA, infB = ea == 0xFF and mA == 0, eb == 0xFF and mB == 0
    if nanA or nanB or (infA and infB and sa != sb):
        return 0, 0, 1, state
    if infA or infB:
        sign = sa if infA else sb
        return U((sign << 31) | (0xFF << 23), 32), (1 << 9) | (sgneg << 7), 0, state
    eA, eB = 1 if ea == 0 else ea, 1 if eb == 0 else eb
    if ea != 0:
        mA = U(mA | (1 << 23), 24)
    if eb != 0:
        mB = U(mB | (1 << 23), 24)
    if eA < eB or (eA == eB and mA < mB):
        fswap, eA, eB, mA, mB, sa, sb = 1, eB, eA, mB, mA, sb, sa
    dd = U(eA - eB, 9)
    pstk = pinc = pinex = 0
    kk, ef, om, wv, bef = 0, 0, 0, 0, 0
    x = (fswap << 6) | (sgneg << 7) | (U(dd, 8) << 16)
    if mA == 0:
        return (0 if sgneg else U(sa << 31, 32)), x | (1 << 4), 0, state
    if dd <= 25:
        wtmp = U(mA << dd, 64)
        wv = U(wtmp - mB, 64) if sgneg else U(wtmp + mB, 64)
        bef = eB
    else:
        wv, bef, pstk = U(mA, 64), eA, 1 if mB else 0
    r = 0
    if wv == 0:
        x |= 1 << 4
    else:
        bln = wv.bit_length()
        kk, ef = S(bln - 24, 9), S(bef + bln - 24, 13)
        if kk > 0:
            wq = wv >> kk
            wr = wv & ((1 << kk) - 1)
            whalf = 1 << (kk - 1)
            pinc = 1 if (wr > whalf or (wr == whalf and (wq & 1))) else 0
            om = U(wq + pinc, 25)
            pinex = 1 if (wr or pstk) else 0
        else:
            om, pinex = U(wv, 25), pstk
        if ef >= 1:
            if kk <= 0:
                om = U(wv << (24 - bln), 25)
            if (om >> 24) & 1:
                om = U(om >> 1, 25)
                ef = S(ef + 1, 13)
            if ef >= 255:
                r, x = U((sa << 31) | (0xFF << 23), 32), x | (1 << 3)
            else:
                r = U((sa << 31) | (U(ef, 8) << 23) | U(om, 23), 32)
        else:
            wms = U(wv << (bef - 1), 64)
            r, x = U((sa << 31) | U(wms, 23), 32), x | (1 << 5)
        x |= pstk | (pinex << 1) | (pinc << 2) | ((1 if U(r, 31) == 0 else 0) << 4)
    return r, x, 0, state


def _bf_num(pp, ex, ey, sgn):
    """bf_num(bax,bay,ex,ey,sgn,pp): 24-bit {inf,inex,inc,sgrid,zero,3'd0,pattern}."""
    pp = U(pp, 16)
    bl = 0
    for k in range(16):
        if (pp >> k) & 1:
            bl = k + 1
    eo = S(ex + ey + bl - 142, 12)
    subn = 1 if eo <= 0 else 0
    drop = S(bl - 8, 12) if not subn else S(135 - ex - ey, 12)
    rr = hh = q = inc = inex = 0
    if drop >= 1:
        if drop >= 17:
            q, inc, inex = 0, 0, 1
        else:
            msk = (1 << drop) - 1
            rr = pp & msk
            hh = 1 << (drop - 1)
            q = pp >> drop
            inc = 1 if (rr > hh or (rr == hh and (q & 1))) else 0
            inex = 1 if rr else 0
            q = U(q + inc, 32)
    else:
        q = U(pp << (0 - drop), 32)
        inc = inex = 0
    if subn:
        if q >= 128:
            patt = (sgn << 15) | (1 << 7)
            return (0 << 23) | (inex << 22) | (inc << 21) | (1 << 20) | \
                (0 << 19) | U(patt, 16)
        patt = (sgn << 15) | U(q, 7)
        return (0 << 23) | (inex << 22) | (inc << 21) | (1 << 20) | \
            ((1 if q == 0 else 0) << 19) | U(patt, 16)
    if q > 255:
        q = q >> 1
        eo = S(eo + 1, 12)
    if eo >= 255:
        patt = (sgn << 15) | (0xFF << 7)
        return (1 << 23) | (inex << 22) | (inc << 21) | U(patt, 16)
    patt = (sgn << 15) | ((eo & 0xFF) << 7) | U(q, 7)
    return (0 << 23) | (inex << 22) | (inc << 21) | U(patt, 16)


def _bf_lane(x16, y16):
    """One bf16 lane: returns (bad, 24-bit pattern word)."""
    ex, ey = (x16 >> 7) & 0xFF, (y16 >> 7) & 0xFF
    ax = U(x16, 7) if ex == 0 else U(0x80 | U(x16, 7), 8)
    ay = U(y16, 7) if ey == 0 else U(0x80 | U(y16, 7), 8)
    sgn = ((x16 >> 15) ^ (y16 >> 15)) & 1
    bad = ((ex == 0xFF and U(x16, 7) != 0) or (ey == 0xFF and U(y16, 7) != 0) or
           (ex == 0xFF and ay == 0) or (ey == 0xFF and ax == 0))
    if bad:
        return 1, 0
    if ex == 0xFF or ey == 0xFF:
        return 0, (1 << 23) | ((sgn << 15) | (0xFF << 7))
    if ax == 0 or ay == 0:
        return 0, (1 << 19) | ((sgn << 15))
    return 0, _bf_num(umul(ax, ay, 8), 1 if ex == 0 else ex, 1 if ey == 0 else ey,
                      sgn)


def m_bf16(a, b, c, state):
    a, b = U(a, 32), U(b, 32)
    bad0, p0 = _bf_lane(U(a, 16), U(b, 16))
    bad1, p1 = _bf_lane(a >> 16, b >> 16)
    if bad0 or bad1:
        return 0, 0, 1, state
    pr0 = umul((U(a, 7) if ((a >> 7) & 0xFF) == 0 else 0x80 | U(a, 7)),
               (U(b, 7) if ((b >> 7) & 0xFF) == 0 else 0x80 | U(b, 7)), 8)
    x = ((p0 >> 23) & 1) | (((p0 >> 19) & 1) << 1) | (((p0 >> 22) & 1) << 2) | \
        (((p0 >> 21) & 1) << 3) | (((p0 >> 20) & 1) << 4) | \
        (((p1 >> 23) & 1) << 5) | (((p1 >> 19) & 1) << 6) | (((p1 >> 22) & 1) << 7) | \
        (((p1 >> 21) & 1) << 8) | (((p1 >> 20) & 1) << 9) | (U(pr0, 16) << 16)
    r = U((U(p1, 16) << 16) | U(p0, 16), 32)
    return r, U(x, 32), 0, state


def m_mont(a, b, c, state):
    mc = field(state, 0, 44)
    mn = field(state, 45, 66)
    mnp = field(state, 67, 77)
    mlimb = field(state, 78, 79)
    mk = field(state, 80, 82)
    mm = field(state, 83, 93)
    mdone = field(state, 94, 94)
    msub = field(state, 95, 95)
    c = U(c, 32)
    mcn, mlimbn, msubn, mhold = mc, mlimb, msub, 0
    if c >> 31:
        if (c >> 3) & 0x0FFFFFFF:
            return 0, 0, 1, state
        mk = c & 7
        mn, mnp = MONT_TABLE[mk]
        mc = (U(a, 22) << 22) | U(b, 22)
        if (mc >> 22) >= mn:
            return 0, 0, 1, state
        mcn, mlimbn, mm, mdone, msubn = mc, 0, 0, 0, 0
    elif mlimb == 3:
        mhold, mcn, mm = 1, mc, 0
    else:
        mnl, mnh = mn & 0x7FF, (mn >> 11) & 0x7FF
        if mlimb in (0, 1):
            mm = umul(mc & 0x7FF, mnp, 11) & 0x7FF
            pnlo = umul(mm, mnl, 11)
            pnnh = umul(mm, mnh, 11)
            madd = U(pnlo + (pnnh << 11), 45)
            mcn = U((mc + madd) >> 11, 45)
            mlimbn = U(mlimb + 1, 2)
        else:
            if mc >= mn:
                mcn, msubn = U(mc - mn, 45), 1
            else:
                mcn = mc
            mlimbn, mdone, mm = 3, 1, 0
    x = mk | (mlimbn << 3) | (mdone << 5) | (mhold << 6) | (msubn << 7) | \
        (mm << 8) | ((mcn & 0x1FFF) << 19)
    r = U(mcn, 32)
    new = (msubn << 95) | (mdone << 94) | (U(mm, 11) << 83) | (U(mk, 3) << 80) | \
        (U(mlimbn, 2) << 78) | (U(mnp, 11) << 67) | (U(mn, 22) << 45) | U(mcn, 45)
    return r, U(x, 32), 0, new


# ================================================================ public dispatch
_MODELS = {
    'cordic_atan': m_cordic, 'nr_recip': m_nr, 'div_nonrestoring': m_div,
    'isqrt': m_isqrt, 'fix2float': m_fix2float, 'float2fix_rne': m_f2f,
    'fadd_s32': m_fadd, 'bf16_mul': m_bf16, 'csd_recode': m_csd,
    'mont_mul': m_mont,
}
assert sorted(_MODELS) == sorted(c['name'] for c in CORES), 'model/core mismatch'


def step(name, a, b, c, state):
    """One enabled beat of `name`; returns (result, aux, fault, next_state)."""
    return _MODELS[name](a & MASK, b & MASK, c & MASK, state)


# ================================================================= board vectors
# Beats each stateful operation occupies on the wire: one seed beat plus its
# work beats, then one idle-repeat beat that proves the converged register is
# still readable with c[31]=0.
_BEATS = {'cordic_atan': 17, 'nr_recip': 5, 'div_nonrestoring': 34,
          'isqrt': 17, 'csd_recode': 17, 'mont_mul': 4}

SEED = 1 << 31


def _stream(name, mk, count):
    """One case per operation: seed beat, work beats, idle-repeat beat."""
    k, rows, i = _BEATS[name], [], 0
    while len(rows) < count:
        a, b, c, fault = mk(i)
        i += 1
        rows.append((a, b, c))
        if fault:
            continue
        for _ in range(k):
            rows.append((a, b, 0))
    return rows[:count]


def _f32(rng, emin=110, emax=145):
    """Random finite binary32 pattern with an exponent field in the window."""
    return (rng.randrange(2) << 31) | (rng.randrange(emin, emax + 1) << 23) | \
        rng.randrange(1 << 23)


def _bf(rng, emin=118, emax=138):
    """Random finite bfloat16 pattern (8-bit exponent field, 7-bit fraction)."""
    return (rng.randrange(2) << 15) | (rng.randrange(emin, emax + 1) << 7) | \
        rng.randrange(1 << 7)


def _v_cordic(count):
    rng = Random(0x2C09D1)

    def mk(i):
        if i % 2 == 1:                                  # x=y=0: atan2 undefined
            return 0, 0, SEED, True
        x = rng.randrange(-(1 << 15), 1 << 15)
        y = rng.randrange(-(1 << 15), 1 << 15)
        if not (x or y):
            x = 1
        return U(x, 16) | (U(y, 16) << 16), 0, SEED, False

    return _stream('cordic_atan', mk, count)


def _v_nr(count):
    rng = Random(0x4E2117)

    def mk(i):
        if i % 5 == 4:                                  # D <= 2048: 1/x needs 2^13
            return rng.randrange(0, 2049), 0, SEED, True
        return rng.randrange(2049, 4096) | (rng.randrange(2) << 12), 0, SEED, False

    return _stream('nr_recip', mk, count)


def _v_div(count):
    rng = Random(0x0D129)

    def mk(i):
        if i % 3 == 1:                                  # d = 0
            return rng.randrange(1 << 32), 0, SEED, True
        if i % 11 == 5:                                 # -2^31 / -1 overflows
            return 0x80000000, 0xFFFFFFFF, SEED, True
        n = rng.randrange(-(1 << 31), 1 << 31)
        d = rng.randrange(-(1 << 31), 1 << 31)
        if d == 0 or (n == -(1 << 31) and d == -1):
            d = 3
        return U(n, 32), U(d, 32), SEED, False

    return _stream('div_nonrestoring', mk, count)


def _v_isqrt(count):
    rng = Random(0x15130A)
    base = [0, 1, 2, 3, 4, 8, 15, 16, 2 ** 32 - 1, 2 ** 32 - 2, 2 ** 31, 2 ** 30,
            2 ** 16, 2 ** 16 + 1, 0x0FFFFFFF, 0x10000000, 0x55555555, 0x2AAAAAAA]
    roots = [4, 5, 255, 256, 257, 1023, 1024, 4095, 4096, 36274, 65534, 65535]
    vals = base + [r * r for r in roots] + [r * r + 2 * r for r in roots] + \
        [rng.randrange(1 << 32) for _ in range(48)]
    vals = list(dict.fromkeys(vals))                     # no repeated operation

    def mk(i):
        return vals[i % len(vals)], 0, SEED, False

    return _stream('isqrt', mk, count)


def _v_csd(count):
    rng = Random(0x5C5D00)
    consts = [0, 1, -1, 3, -3, 5, 7, -7, 15, -15, 31, 63, -63, 127, 255, -255,
              1023, -1023, 32767, -32768, 21845, -21845, 43691, -43691] + \
        [rng.randrange(-32768, 32768) for _ in range(40)]

    def mk(i):
        return U(consts[i % len(consts)], 16), 0, SEED, False

    return _stream('csd_recode', mk, count)


def _v_mont(count):
    rng = Random(0x40171C)

    def mk(i):
        if i % 6 == 2:                                  # malformed selector c[30:3]
            return rng.randrange(1 << 22), rng.randrange(1 << 22), \
                SEED | 8 | (i & 7), True
        k = i & 7
        n = MONT_TABLE[k][0]
        t = rng.randrange(n) * rng.randrange(n)
        return t >> 22, t & ((1 << 22) - 1), SEED | k, False

    return _stream('mont_mul', mk, count)


def _v_fix2float(count):
    rng = Random(0x1F10A7)
    mags = [0, 1, 2, 3, 0x7FFFFFFF, 0x80000000, 0x40000000, 0x00800000,
            0x00000100, 0x0000FFFF, 0x00010000, 0x00FFFFFF] + \
        [rng.randrange(1 << 32) for _ in range(20)]

    rows = []
    for i in range(count):
        v = U(mags[i % len(mags)], 32)
        if i % 29 == 7:                         # malformed binary-point selector
            rows.append((v, 0, 0x0100 | (i & 0xFF)))
            continue
        rows.append((v, rng.randrange(1 << 16), ((i * 7) % 61) - 30 & 0xFF))
    return rows


def _v_float2fix(count):
    rng = Random(0x0F2F1C)

    def mk(i):
        if i % 23 == 5:                                 # NaN or infinity operand
            return 0x7FC00000 | rng.randrange(1 << 23), _f32(rng), i & 0xFF, 0
        if i % 31 == 9:                                 # malformed scale selector
            return _f32(rng), _f32(rng), 0x00FF00, 0
        return _f32(rng), _f32(rng), (i * 5 % 41) - 20 & 0xFF, 0

    return [row[:3] for row in (mk(i) for i in range(count))]


def _v_fadd(count):
    rng = Random(0x6ADD17)

    def mk(i):
        if i % 17 == 4:                                 # NaN operand
            return 0xFF800000, _f32(rng), i & 1, 0
        if i % 25 == 12:                                # (+inf) + (-inf)
            return 0x7F800000, 0xFF800000, 1, 0
        if i % 41 == 20:                                # malformed control word
            return _f32(rng), _f32(rng), 0x100, 0
        return _f32(rng), _f32(rng), i & 1, 0

    return [row[:3] for row in (mk(i) for i in range(count))]


def _v_bf16(count):
    rng = Random(0x8F16BF)

    def mk(i):
        if i % 19 == 6:                                 # NaN operand in lane0
            return 0xFF80 | (rng.randrange(2) << 15), _bf(rng) | (_bf(rng) << 16), 0, 0
        if i % 27 == 13:                                # 0 * infinity in lane1
            return (_bf(rng) & 0x7FFF) | ((rng.randrange(2)) << 15), \
                0x7F80 << 16, 0, 0
        x0, y0, x1, y1 = _bf(rng), _bf(rng), _bf(rng), _bf(rng)
        return x0 | (x1 << 16), y0 | (y1 << 16), 0, 0

    return [row[:3] for row in (mk(i) for i in range(count))]


_VECTOR_BUILDERS = {
    'cordic_atan': _v_cordic, 'nr_recip': _v_nr, 'div_nonrestoring': _v_div,
    'isqrt': _v_isqrt, 'csd_recode': _v_csd, 'mont_mul': _v_mont,
    'fix2float': _v_fix2float, 'float2fix_rne': _v_float2fix,
    'fadd_s32': _v_fadd, 'bf16_mul': _v_bf16,
}


def vectors(name, count=320):
    """Board stimulus: one operation per case for the pipelined cores."""
    return _VECTOR_BUILDERS[name](count)


# ==================================================================== selftest
def _rne(num, den):
    """Round-to-nearest, ties-to-even integer quotient of num/den (den > 0).

    Written here with divmod only, so no core's own guard/sticky rounding
    network can be accused of being the reference.
    """
    return _rne3(num, den)[0]


def _rne3(num, den):
    """(_rne(num, den), inexact, incremented) -- integer only, no float math."""
    q, r = divmod(num, den)
    twice = 2 * r
    up = twice > den or (twice == den and (q & 1))
    return q + (1 if up else 0), bool(r), bool(up)


def _scale(mag, q, grid_q):
    """Round mag*2**q onto the grid 2**grid_q: (M, inexact, incremented)."""
    sh = q - grid_q
    if sh >= 0:
        return mag << sh, False, False
    return _rne3(mag, 1 << -sh)


def _grid(mag, q, sig_bits, bias, min_exp, sub_grid):
    """Exact non-negative value mag*2**q -> (E, F, inexact, incremented,
    subnormal, overflow) for a binary float format with a `sig_bits`-bit
    significand, `bias`, smallest normal binade exponent `min_exp` and subnormal
    grid `sub_grid`.  Shares no code with any kernel here: bit_length + _scale
    only, and it rounds exactly once (no double rounding)."""
    if mag == 0:
        return 0, 0, False, False, False, False
    frac_bits = sig_bits - 1
    k = q + mag.bit_length() - 1                   # floor(log2(value))
    if k >= min_exp:
        m, inx, inc = _scale(mag, q, k - frac_bits)
        if m == 1 << sig_bits:                     # rounding carried up a binade
            m >>= 1
            k += 1
        exp = k + bias
        if exp >= 255:
            return 255, 0, inx, inc, False, True
        return exp, m - (1 << frac_bits), inx, inc, False, False
    m, inx, inc = _scale(mag, q, sub_grid)
    if m == 1 << frac_bits:                        # rounded up onto the normal rail
        return 1, 0, inx, inc, True, False
    return 0, m, inx, inc, True, False


def _dec32(u):
    """binary32 pattern -> (sign, significand, q) with value = mant*2**q and a
    24-bit significand; subnormals fall out of the same formula."""
    e = (u >> 23) & 0xFF
    m = U(u, 23)
    return (u >> 31) & 1, (m if e == 0 else m | (1 << 23)), (e if e else 1) - 150


def _dec_bf(u):
    """bfloat16 pattern -> (sign, 8-bit significand, q), value = mant*2**q."""
    e = (u >> 7) & 0xFF
    m = U(u, 7)
    return (u >> 15) & 1, (m if e == 0 else m | 0x80), (e if e else 1) - 134


def _run(name, a, b, c, beats):
    """Seed beat plus `beats` follow-up beats; returns (final r, final x, f,
    per-beat (r, x, f) list, final state)."""
    r = x = f = 0
    state = 0
    seen = []
    for i in range(beats + 1):
        r, x, f, state = _MODELS[name](a, b, c if i == 0 else 0, state)
        seen.append((r, x, f))
        if f:
            break
    return r, x, f, seen, state


def _csd_digits(word):
    """Signed-digit list out of a packed two-bits-per-digit op list."""
    return [S(field(word, 2 * i, 2 * i + 1), 2) for i in range(16)]


def _csd_min_weight(value):
    """Minimum nonzero-digit count for a 16-bit value, by a carry DP over the
    bit positions that shares no code with the recoder's modulo-4 rule."""
    x, cur = abs(value), {0: 0}
    for i in range(16):
        bit = (x >> i) & 1
        nxt = {}
        for carry, cost in cur.items():
            for dig in (0, 1, -1):
                rest = bit + carry - dig
                if rest & 1 or rest > 2:
                    continue
                key = rest >> 1
                if key not in nxt or cost + bool(dig) < nxt[key]:
                    nxt[key] = cost + bool(dig)
        cur = nxt
    return cur.get(0)


def selftest():
    """Independent attacks on every arithmetic kernel: exact integer/rational
    references, brute force, second algorithms and algebraic invariants.

    Nothing below is a replay of an `m_*` model: expected values come from
    Python integer arithmetic, `math`, `struct`, divmod-based round-to-nearest
    grids written here, and from published constants.
    """
    checks = 0

    # ---- family contract ---------------------------------------------------
    assert FAMILY == 'arith' and len(CORES) == 10
    names = sorted(c['name'] for c in CORES)
    assert names == sorted(_MODELS) == sorted(_VECTOR_BUILDERS)
    checks += 1

    # The fabric rule: no generated Verilog text of this family may contain a
    # `*`, because $mul on GW5A is unsigned and corrupts bit-11 operands.
    for entry in CORES:
        for key in ('body', 'decl'):
            assert '*' not in entry[key], (entry['name'], key)
    # ... and the same fabric has no divider either, so no code line may carry a
    # `/`: every reciprocal in this family is a shift-add seed plus corrections.
    # Only `//` comment text is allowed to mention a slash (the derived tables
    # label their bin centres in comments), so the operator scan is done on the
    # comment-stripped code of every kernel and every module-scope declaration.
    for entry in CORES:
        for key in ('body', 'decl'):
            code = '\n'.join(line.split('//')[0] for line in entry[key].split('\n'))
            assert '/' not in code, (entry['name'], key, [
                line for line in code.split('\n') if '/' in line][:1])
            assert '*' not in code.replace('@*', ''), (entry['name'], key)
    checks += 1

    # Every one-beat core must be stateless-safe: the documented pattern comes
    # out the same on a fresh and on a dirtied state register, and that register
    # is left exactly as it was found.  The expectations below are hand-written
    # from the core specs and re-derived with `struct` IEEE-754 binary32 packing
    # and integer arithmetic, so no line of this block is a model-against-model
    # replay:
    #   fix2float     : a=0x40000000 read as Q31 is 2^30*2^-31 = 0.5, whose
    #                   binary32 code is 0x3F000000; aux[25:20]=leading-zero
    #                   count 1 (0x40000000 has 31 significant bits) and
    #                   aux[12]=1 because the conversion discards nothing.
    #   float2fix_rne : n=0, so lane0=round(4.0)=4 and lane1=round(1.0)=1,
    #                   exact on both lanes -> result=(1<<16)|4, aux=0.
    #   fadd_s32      : 1.0+2.0=3.0 -> 0x40400000; aux[6]=1 because the
    #                   comparator routes the larger operand (2.0) to the A
    #                   side and aux[23:16]=1 is the alignment distance.
    #   bf16_mul      : both lanes are bf16 1.0*1.0 and 1.0 is the code
    #                   (127<<7), so result=(0x3F80<<16)|0x3F80 with
    #                   aux[31:16]=0x80*0x80=0x4000, the hand-formed mantissa
    #                   product, and every lane flag clear.
    def _f32bits(value):
        return unpack('>I', pack('>f', value))[0]

    _ONE = 127 << 7                                   # bfloat16 code of 1.0
    for name, a, b, c, want, want_aux in (
            ('fix2float', 0x40000000, 0, 0, _f32bits(0.5), (1 << 20) | (1 << 12)),
            ('float2fix_rne', 0x40800000, 0x3F800000, 0, (1 << 16) | 4, 0),
            ('fadd_s32', 0x3F800000, 0x40000000, 0, _f32bits(1.0 + 2.0),
             (1 << 16) | (1 << 6)),
            ('bf16_mul', 0x3F803F80, 0x3F803F80, 0, (_ONE << 16) | _ONE,
             0x4000 << 16)):
        for dirty in (0, MASK, 0x5A5A5A5A5A5A5A5A, (1 << 256) - 1):
            r, x, f, nxt = step(name, a, b, c, dirty)
            assert f == 0, (name, hex(dirty))
            assert U(r, 32) == want, (name, hex(r), hex(want))
            assert U(x, 32) == want_aux, (name, hex(x), hex(want_aux))
            assert nxt == dirty, (name, hex(dirty))   # one beat, state untouched
    checks += 1

    # ---- isqrt: exact small domain, hand-derived ---------------------------
    # 46340 = floor(sqrt(2^31-1)) and 65535 = floor(sqrt(2^32-1)) are the two
    # rails of the declared 32-bit domain; 2^28-1 sits one below 16384^2.
    for n, want in ((0, 0), (1, 1), (2, 1), (3, 1), (4, 2), (15, 3), (16, 4),
                    (2 ** 31 - 1, 46340), (2 ** 32 - 1, 65535),
                    (2 ** 30, 32768), (0x0FFFFFFF, 16383), (0x10000000, 16384)):
        r, x, f, seen, st = _run('isqrt', n, 0, SEED, 17)
        assert (r, f) == (want, 0) and r < (1 << 16), (n, r, want)
        assert n - r * r == field(x, 7, 31), (n, r, x)
    checks += 1

    # Exhaustive over the low 13-bit domain against the library isqrt, with the
    # remainder invariant rem = a - root^2 read back off aux every time.
    for n in range(1 << 13):
        r, x, f, seen, st = _run('isqrt', n, 0, SEED, 17)
        assert f == 0 and r == misqrt(n) and r < (1 << 16), (n, r)
        assert n - r * r == field(x, 7, 31), n
    checks += 1

    rng = Random(0x15ABE3)
    # k^2 and the last n below (k+1)^2 across the whole 16-bit root space:
    # these are the exact perfect-square and off-by-one boundaries.
    for k in range(0, 1 << 16, 8):
        for n in (k * k, k * k + 2 * k):
            if n > MASK:
                continue
            r, x, f, seen, st = _run('isqrt', n, 0, SEED, 17)
            assert f == 0 and r * r <= n < (r + 1) * (r + 1), (n, r)
            assert r == misqrt(n), (n, r)
    checks += 1
    for k in list(range(0, 260)) + [1023, 1024, 4095, 4096, 36274, 65534, 65535]:
        for delta in (-1, 0, 1):
            n = k * k + delta
            if not 0 <= n <= MASK:
                continue
            r, x, f, seen, st = _run('isqrt', n, 0, SEED, 17)
            assert f == 0 and r == misqrt(n), (n, r, misqrt(n))
    checks += 1
    for _ in range(4000):                            # dense random over 32 bits
        n = rng.randrange(1 << 32)
        r, x, f, seen, st = _run('isqrt', n, 0, SEED, 17)
        assert f == 0 and r == misqrt(n), (n, r)
        assert n - r * r == field(x, 7, 31), n
    checks += 1

    # State threading is load-bearing: a half run reports the partial root of
    # the bit pairs already tested, which must differ from the converged one,
    # and a c[31] restart must wipe it (first beat of a new op is the seed 0).
    n = 0x3B9ACA00
    _, _, _, half, _ = _run('isqrt', n, 0, SEED, 7)
    r, x, f, full, _ = _run('isqrt', n, 0, SEED, 17)
    assert f == 0 and r == misqrt(n)
    assert 0 < half[3][0] < half[-1][0] < r, (half[3][0], half[-1][0], r)
    assert half[-1][0] == r & ~0x1FF, (half[-1][0], r)   # low 9 bits not yet tested
    r2, x2, f2, seen2, _ = _run('isqrt', 9, 0, SEED, 17)
    assert (r2, f2, seen2[0][0]) == (3, 0, 0)
    checks += 1

    # ---- csd_recode: sum back, minimal weight, NAF adjacency --------------
    # The result is a shift-add multiplier op list, so it must re-sum to the
    # signed input for every pattern, its nonzero count must equal an
    # independent carry-DP minimum, and no two digits may be adjacent.
    for u in [0, 1, -1 & MASK, 3, -3 & MASK, 5, 7, -7 & MASK, 15, -15 & MASK,
              31, 63, -63 & MASK, 127, 255, -255 & MASK, 1023, -1023 & MASK,
              32767, -32768 & MASK, 21845, -21845 & MASK, 43691, -43691 & MASK] \
            + list(range(0, 1 << 16, 7)) + [rng.randrange(1 << 16)
                                            for _ in range(1500)]:
        v = S(U(u, 16), 16)
        r, x, f, seen, st = _run('csd_recode', u, 0, SEED, 17)
        assert f == 0                                          # declared faultless
        dig = _csd_digits(r)
        assert sum(dig[i] * 2 ** i for i in range(16)) == v, (v, hex(r))
        nz = sum(1 for d in dig if d)
        assert nz == _csd_min_weight(v) == field(x, 9, 13), (v, nz, _csd_min_weight(v))
        assert not any(dig[i] and dig[i + 1] for i in range(15)), v
        assert field(x, 0, 4) == 16 and (x >> 5) & 1 == 1, (v, hex(x))
        # digits 0..8 are already final after nine work beats
        assert _csd_digits(seen[8][0])[:9] == dig[:9], v
        assert field(seen[8][1], 9, 13) == sum(1 for d in dig[:9] if d), v
        assert seen[-1][0] == seen[-2][0] == r and (x >> 6) & 1 == 1   # idle repeat
    checks += 1

    # ---- div_nonrestoring --------------------------------------------------
    # Documented rounding is C truncation toward zero, so the quotient comes
    # from |n|//|d| with the sign XOR and the remainder keeps the dividend sign.
    def trunc_div(n, d):
        n, d = S(U(n, 32), 32), S(U(d, 32), 32)      # the operands as decoded
        qm = abs(n) // abs(d)
        return (qm if (n < 0) == (d < 0) else -qm), abs(n) - abs(d) * qm

    for n in range(-40, 41):
        for d in range(-40, 41):
            if d == 0:
                continue
            q, rm = trunc_div(n, d)
            r, x, f, seen, st = _run('div_nonrestoring', U(n, 32), U(d, 32),
                                     SEED, _BEATS['div_nonrestoring'])
            assert f == 0 and S(r, 32) == q, (n, d, r, q)
            assert rm == abs(n) - abs(d) * abs(q) and abs(rm) < abs(d)
            assert (n == d * q + (rm if n >= 0 else -rm))           # truncation law
            assert field(x, 11, 31) == U(rm, 21), (n, d, rm, hex(x))
            assert field(x, 0, 5) == 33 and (x >> 6) & 1 == 1, hex(x)
            assert (x >> 7) & 1 == ((n < 0) ^ (d < 0)), (n, d)
            assert (x >> 9) & 1 == (abs(d) == 1 << 31), (n, d)
            pre = S(field(seen[32][1], 11, 31), 21)          # before the restore
            assert (x >> 8) & 1 == (1 if pre < 0 else 0), (n, d, pre)
            assert rm == pre + (abs(d) if pre < 0 else 0), (n, d, pre, rm)
            assert seen[-1] == seen[-2], (n, d)              # idle repeat beat
    checks += 1

    # zero divisor and the single overflowing pair must flag, never wrap
    nz = 0
    for n, d in [(0, 0), (1, 0), (-1, 0), (-(1 << 31), 0), (2 ** 32 - 1, 0),
                 (-(1 << 31), -1), (0x7FFFFFFF, 0), (-5, 0)]:
        r, x, f, seen, st = _run('div_nonrestoring', U(n, 32), U(d, 32), SEED,
                                 _BEATS['div_nonrestoring'])
        assert f == 1 and (seen[0][0], seen[0][1]) == (0, 0), (n, d)
        assert st == 0                                       # fault leaves state be
        nz += 1
    assert nz == 8
    checks += 1

    # rails and a dense 32-bit random sweep
    for n, d in (-(1 << 31), 1), (-(1 << 31), 2), (1, -(1 << 31)), \
            (-(1 << 31), -(1 << 31)), (-(1 << 31), 1 << 31), (0x7FFFFFFF, -1), \
            (0, -(1 << 31)), (-(1 << 31), 3), (7, -(1 << 31)):
        want, wrm = trunc_div(n, d)
        r, x, f, seen, st = _run('div_nonrestoring', U(n, 32), U(d, 32), SEED,
                                 _BEATS['div_nonrestoring'])
        assert f == 0 and S(r, 32) == want, (n, d, hex(r), want)
        assert field(x, 11, 31) == U(wrm, 21), (n, d, wrm)
    for _ in range(2500):
        n = rng.randrange(-(1 << 31), 1 << 31)
        d = rng.randrange(-(1 << 31), 1 << 31)
        if d == 0 or (n == -(1 << 31) and d == -1):
            d = 3
        q, rm = trunc_div(n, d)
        r, x, f, seen, st = _run('div_nonrestoring', U(n, 32), U(d, 32), SEED,
                                 _BEATS['div_nonrestoring'])
        assert f == 0 and S(r, 32) == q and abs(rm) < abs(d), (n, d, hex(r), q)
        if rm < (1 << 20):
            assert field(x, 11, 31) == U(rm, 21), (n, d, rm)
    # a restart mid-loop must abandon the in-flight quotient
    _, _, _, part, st = _run('div_nonrestoring', U(12345, 32), U(7, 32), SEED, 10)
    assert part[-1][0] != U(12345 // 7, 32)
    r, x, f, st = _MODELS['div_nonrestoring'](U(-99, 32), U(8, 32), SEED, st)
    for _ in range(_BEATS['div_nonrestoring']):
        r, x, f, st = _MODELS['div_nonrestoring'](U(-99, 32), U(8, 32), 0, st)
    assert (S(r, 32), f) == (-12, 0), (r, f)
    checks += 1

    # ---- nr_recip ----------------------------------------------------------
    # Exhaustive over the declared D window: beat 4 is an exact fix-up, so the
    # converged result must be the correctly rounded 2^24/D, not merely close.
    for D in range(2049, 4096):
        for sgn in (0, 1):
            r, x, f, seen, st = _run('nr_recip', D | (sgn << 12), 0, SEED,
                                     _BEATS['nr_recip'])
            want = _rne(1 << 24, D)
            assert f == 0 and S(r, 32) == (-want if sgn else want), (D, sgn, r, want)
            assert 4097 <= want <= 8188, (D, want)                 # declared range
            # The budget is on the magnitude of the reciprocal: the documented
            # result is signed round(2^24/D), so with a[12]=1 the raw product
            # S(r,32)*D is negative and `negative - 1` is about -2 for every D
            # in the window.  Comparing that to 1/8192 would demand 2^24/D ~ 0,
            # which no correct result can satisfy, so the bound is taken on
            # |result| * D, the quantity that must sit next to 2^24.
            rel = abs(Fraction(abs(S(r, 32)) * D, 1 << 24) - 1)
            assert rel <= Fraction(1, 8192), (D, sgn, rel)          # half-ULP budget
            assert field(x, 0, 2) == 4 and (x >> 3) & 1 == 1, (D, hex(x))
            assert (x >> 4) & 1 == sgn and (x >> 5) & 1 == 1, (D, hex(x))
            # aux[15:10] is the seed ROM bin and the documented layout says it is
            # "nonzero only on a seeded beat": nbin is a function of the seed
            # beat's a[11:6] alone and is not carried in state, so the field must
            # read the closed-form bin on beat 0 and must read zero on every
            # later beat of the same operation, including the converged one.
            binx = (D >> 6) & 0x3F
            assert field(seen[0][1], 10, 15) == binx, (D, sgn, hex(seen[0][1]))
            assert field(x, 10, 15) == 0, (D, hex(x))
            # and the seed beat must report the seed of exactly that bin
            seed_y = NR_CENTER + S(NR_SEED[binx], 12)
            assert S(seen[0][0], 32) == (-seed_y if sgn else seed_y), (D, sgn, binx)
        _, _, _, seen, _ = _run('nr_recip', D, 0, SEED, 0)
        seed_rel = abs(Fraction(seen[0][0] * D, 1 << 24) - 1)
        assert seed_rel <= Fraction(1, 64), (D, seed_rel)     # documented seed bound
    checks += 1
    for D in (0, 1, 2, 2047, 2048, 4096, 6144):               # D = 0 and non-normal
        r, x, f, seen, st = _run('nr_recip', D, 0, SEED, _BEATS['nr_recip'])
        assert f == 1 and (seen[0][0], seen[0][1]) == (0, 0) and st == 0, D
    # The seed ROM is re-derived from exact rational arithmetic: no division and
    # no published table, just round(2^24 / bin centre) clamped into the slice.
    for j in range(NR_BINS):
        centre = j * 64 + 32
        want = _rne(1 << 24, centre) - NR_CENTER if j >= 32 else 0
        want = max(-2048, min(2047, want))
        assert NR_SEED[j] == want, (j, NR_SEED[j], want)
    assert all(-2048 <= v <= 2047 for v in NR_SEED)
    checks += 1

    # ---- CORDIC atan table and the pi/4 constant ----------------------------
    # The docstring promises this table is not copied: it is the Gregory series
    # for atan(1/q) summed in exact rationals, with pi/4 from Machin's identity.
    # Two independent sources attack it here -- the identity itself, proved in
    # `Fraction` arithmetic, and the library `atan()` of the CPython `math`
    # module, which the Q20 grid must reproduce entry by entry.
    def _tan_double(t):
        return 2 * t / (1 - t * t)

    _t4 = _tan_double(_tan_double(Fraction(1, 5)))          # tan(4*atan(1/5))
    _machin = (_t4 - Fraction(1, 239)) / (1 + _t4 * Fraction(1, 239))
    assert _machin == 1, _machin                    # tan(pi/4) == 1, exactly
    # Each truncated series leaves an alternating tail bounded by its first
    # omitted term; that bound must sit far under one Q20 step (2^-20 rad).
    for _q, (_sum, _k) in ((5, _atan_inv(5)), (239, _atan_inv(239))):
        _tail = Fraction(1, (2 * _k + 1) * _q ** (2 * _k + 1))
        assert _tail < Fraction(1, 1 << 90), (_q, _k, _tail)
    checks += 1
    for _i, _entry in enumerate(CORDIC_ATAN):
        _lib = atan(1.0) if not _i else atan(2.0 ** -_i)
        assert abs(round(_lib * (1 << CORDIC_Q)) - _entry) <= 1, (_i, _entry, _lib)
        assert abs(float(_PI4 if not _i else _atan_inv(1 << _i)[0]) - _lib) < 2 ** -50
    # pi/4 from the identity, and the 24-bit pi localparam the core adds on the
    # pre-rotated half-plane, both re-rounded from the library's own pi/4.
    assert abs(CORDIC_PI - round(4 * atan(1.0) * (1 << CORDIC_Q))) <= 1, CORDIC_PI
    assert abs(float(4 * _PI4) - 4 * atan(1.0)) < 2 ** -48   # 4*_PI4 is pi
    assert 0 < CORDIC_PI < (1 << 23), CORDIC_PI          # fits signed 24 bits
    checks += 1

    # ---- Montgomery moduli and their multipliers ---------------------------
    # N' = -N^-1 mod 2^11 is built here by 2-adic Newton iteration.  The
    # independent references are Python's own `pow(N, -1, 2**11)` and the
    # defining congruence N*N' == -1 (mod 2^11), which can only hold for odd N.
    assert len(MONT_TABLE) == 8 and len(MONT_MODULI) == 8
    for _i, (_n, _np) in enumerate(MONT_TABLE):
        assert _n & 1, (_i, _n)                                    # odd modulus
        assert (_n * _np) % MONT_BASE == MONT_BASE - 1, (_i, _n, _np)
        assert _np == (-pow(_n, -1, MONT_BASE)) % MONT_BASE, (_i, _n, _np)
        assert 0 <= _np < MONT_BASE and 0 < _n < MONT_R, (_i, _n, _np)
    checks += 1

    # ---- mont_mul: REDC against the definition, not against the core -------
    # The converged window must be T*R^-1 mod N with T = {a[21:0], b[21:0]} and
    # R = 2^22, so multiplying the answer back by R recovers T mod N.  Every
    # reduction step's multiplier m = (C mod 2^11)*N' mod 2^11 is recomputed from
    # the seed word by hand, and the window it produced must satisfy the exact
    # limb-cancellation identity (C1 << 11) == T + m*N.
    # A fresh generator for this block, so the shared `rng` carried by the
    # sweeps above keeps its own stream.
    mrng = Random(0x11047)
    for _ in range(1200):
        _i = mrng.randrange(8)
        _n, _np = MONT_TABLE[_i]
        _a = mrng.randrange(_n) if mrng.randrange(4) else mrng.randrange(1 << 22)
        _b = mrng.randrange(_n) if mrng.randrange(4) else mrng.randrange(1 << 22)
        _t = (U(_a, 22) << 22) | U(_b, 22)
        if _a >= _n:                       # the documented T >= N*R guard bites
            r, x, f, seen, st = _run('mont_mul', _a, _b, SEED | _i,
                                     _BEATS['mont_mul'])
            assert f == 1 and (seen[0][0], seen[0][1]) == (0, 0) and st == 0, _i
            continue
        r, x, f, seen, st = _run('mont_mul', _a, _b, SEED | _i,
                                 _BEATS['mont_mul'])
        want = _t * pow(MONT_R % _n, -1, _n) % _n
        assert f == 0 and r == want and want < _n, (_i, _a, _b, r, want)
        assert (want * MONT_R) % _n == _t % _n               # REDC definition
        assert field(x, 0, 2) == _i and field(x, 3, 4) == 3, (_i, hex(x))
        assert (x >> 5) & 1 == 1 and (x >> 6) & 1 == 1, (_i, hex(x))
        assert field(x, 8, 18) == 0, (_i, _t, hex(x))         # idle: no m reported
        assert field(x, 19, 31) == want & 0x1FFF, (_i, _t, hex(x))
        assert seen[0][0] == (_t & MASK) and field(seen[0][1], 0, 2) == _i
        # beat 1: m from the low limb of T, and the window it produced.  m is
        # chosen to cancel that limb, so T + m*N is exactly divisible by 2^11 and
        # the quotient is the next window -- full 45-bit quotient here, while
        # result carries its low 32 bits and aux[31:19] its low 13 (documented).
        _m = (_t & 0x7FF) * _np & 0x7FF
        assert field(seen[1][1], 8, 18) == _m, (_i, _t, hex(seen[1][1]))
        _c1 = (_t + _m * _n) >> 11
        assert (_c1 << 11) == _t + _m * _n, (_i, _t, _m)      # low limb cancelled
        assert seen[1][0] == _c1 & MASK, (_i, _t, _c1, seen[1][0])
        assert field(seen[1][1], 19, 31) == _c1 & 0x1FFF, (_i, _t, hex(seen[1][1]))
        assert seen[-1][0] == seen[-2][0] == r, (_i, _t, r)  # idle repeat
    checks += 1
    # rails: T = 0 reduces to 0, T = 1 gives R^-1 mod N, and a high half of
    # exactly N faults as T >= N*R; a malformed modulus selector faults too.
    for _i, (_n, _np) in enumerate(MONT_TABLE):
        for _t, _want in ((0, 0), (1, pow(MONT_R % _n, -1, _n)),
                          (MONT_R - 1, (MONT_R - 1) * pow(MONT_R % _n, -1, _n) % _n)):
            r, x, f, seen, st = _run('mont_mul', _t >> 22, _t & 0x3FFFFF,
                                     SEED | _i, _BEATS['mont_mul'])
            assert f == 0 and r == _want, (_i, _t, r, _want)
        r, x, f, seen, st = _run('mont_mul', _n, _n - 1, SEED | _i,
                                 _BEATS['mont_mul'])
        assert f == 1 and (seen[0][0], seen[0][1]) == (0, 0), (_i, 'T>=N*R')
        for _bad in (1 << 3, 1 << 30, 0xF0000000):
            r, x, f, seen, st = _run('mont_mul', 1, 1, SEED | _i | _bad,
                                     _BEATS['mont_mul'])
            assert f == 1 and st == 0 and seen[0][:2] == (0, 0), (_i, hex(_bad))
    checks += 1

    # ---- cordic_atan: the angle against the library atan2 ------------------
    # Independent reference is CPython's `math.atan2` on the same 16-bit signed
    # pair, quantised onto the documented Q16 result grid (LSB 2^-16 rad).  The
    # declared accuracy contract is |error| <= 4 LSB, which is what is asserted;
    # the 16-step CORDIC resolution alone is 2.0002 LSB, so a tighter promise
    # here would be false advertising rather than a stronger test.
    crng = Random(0x5EEDC0)                        # own stream, as above
    worst = 0
    for _ in range(1200):
        _x = crng.randrange(-(1 << 15), 1 << 15)
        _y = crng.randrange(-(1 << 15), 1 << 15)
        if not (_x or _y):
            continue
        r, x, f, seen, st = _run('cordic_atan',
                                 U(_x, 16) | (U(_y, 16) << 16), 0, SEED,
                                 _BEATS['cordic_atan'])
        assert f == 0, (_x, _y)
        want = round(atan2(_y, _x) * (1 << 16))
        err = abs(S(r, 32) - want)
        worst = max(worst, err)
        assert err <= 4, (_x, _y, S(r, 32), want, err)
        assert field(x, 24, 31) == 0, (_x, _y, hex(x))       # declared zero slice
        assert (x >> 4) & 1 == 1 and (x >> 7) & 1 == 1, (_x, _y, hex(x))
        assert (x >> 5) & 1 == (1 if _x < 0 else 0), (_x, _y, hex(x))
    checks += 1
    # the four axes and the degenerate seed, where atan2 is undefined
    for _x, _y, _want in ((1, 0, 0), (0, 1, round(atan2(1, 0) * (1 << 16))),
                          (-1, 0, round(atan2(0, -1) * (1 << 16))),
                          (0, -1, round(atan2(-1, 0) * (1 << 16)))):
        r, x, f, seen, st = _run('cordic_atan',
                                 U(_x, 16) | (U(_y, 16) << 16), 0, SEED,
                                 _BEATS['cordic_atan'])
        assert f == 0 and abs(S(r, 32) - _want) <= 4, (_x, _y, r, _want)
    # atan2(0, 0) is undefined, so the degenerate seed must fault cleanly: a zero
    # response on every beat and a state register left where it was found.
    r, x, f, seen, st = _run('cordic_atan', 0, 0, SEED, _BEATS['cordic_atan'])
    assert f == 1 and (seen[0][0], seen[0][1]) == (0, 0) and st == 0
    # a restart mid-iteration must abandon the in-flight angle: eight of sixteen
    # rotations cannot already report the converged estimate, because the twelve
    # omitted |atan(2^-i)| steps sum to well over one Q16 LSB.
    _a = U(10293, 16) | (U(-24567, 16) << 16)
    _, _, _, part, _ = _run('cordic_atan', _a, 0, SEED, 8)
    r, x, f, seen, st = _run('cordic_atan', _a, 0, SEED, _BEATS['cordic_atan'])
    assert f == 0 and part[-1][0] != r, (hex(part[-1][0]), hex(r))
    assert worst <= 4, worst                       # declared bound, measured
    checks += 1
    return checks

