"""Communication and link-layer arithmetic kernels: one beat per symbol group.

Six enabled-ready-valid accelerator cores for the communication family. Each one
replaces a serial loop that a link-layer controller really runs: a CRC-32 frame
checker, an NRZI/FM line-code transform with density and clock-lock watchdogs, a
bit-level sync-marker hunter with lock/loss accounting, a 16-bit polar (Arikan)
encoder with frozen-bit checking, a 16-QAM max-log soft demapper and a four-state
rate-1/2 Viterbi ACS step with puncturing support.

Every core is specified twice: as Verilog statements below and as a pure-integer
Python model in step(). The two specifications are deliberately *different*
algorithms for the same function -- the CRC model folds bit-serially while the RTL
runs a generated GF(2) matrix, the Viterbi model is an ACS recurrence that the
selftest checks against an exhaustive MLSE search -- so a shared bug surfaces as a
vector mismatch instead of passing silently. selftest() also pins published
constants: CRC-32 of "123456789" = 0xCBF43926 and the 0xDEBB20E3 frame residue,
the (7,5)-octal convolutional code and its MLSE distance, the polar kernel's
repetition and identity bit channels, and 16-QAM boundary geometry.

Contract used by every core in this file (see generate_lib.RTL):
    inputs  a, b, c                  32 bit, one accepted beat
    outputs result, aux (r, x), fault
    state   state_r -> state_n       256 bit, only accepted beats commit it
    restart/config beat convention:  c[31] = 1

Template body vocabulary, re-initialised on every evaluation:
    r x f temp mask pa pb pc ph pl ext wide wide2 swide swide2 sa sb sc data
    i j idx lane sh state_r state_n
Anything declared in `decl` lives at module scope and is NOT re-initialised. All
module-scope state here is `wire` continuous assignments (or functions), which
cannot hold a stale value; the few `reg` vectors are written on every evaluation
path that reads them.

All six cores are one combinational cone behind one register stage: latency 1
enabled edge, II 1. No core uses a hard multiplier, so none needs a sim_extra cell
model, and every product-free cone stays inside 4-input LUT arithmetic.
"""
import zlib
from itertools import product
from random import Random

FAMILY = 'comm'
MASK = (1 << 32) - 1

CORES = []


def core(name, spec, body, advantage, lanes, decl='', stateful=False,
         faultless=False):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body, decl=decl,
                      advantage=advantage, lanes=lanes, stateful=stateful,
                      faultless=faultless))


def hexs(value, digits=8):
    return format(value, f'0{digits}X')


# Shared module-scope helper functions used by several cores' bodies.
POPDECL = """
function [5:0] pc32;                       // popcount of a 32-bit word
    input [31:0] v;
    reg [31:0] t;
    begin
        t = v - ((v >> 1) & 32'h55555555);
        t = (t & 32'h33333333) + ((t >> 2) & 32'h33333333);
        t = (t + (t >> 4)) & 32'h0F0F0F0F;
        t = t + (t >> 8);
        t = t + (t >> 16);
        pc32 = t[5:0];
    end
endfunction

function [5:0] tz32;                       // zeros below the lowest set bit, 32 if empty
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        t = v; n = 6'd0;
        if((t & 32'h0000FFFF) == 32'd0) begin n = n + 6'd16; t = t >> 16; end
        if((t & 32'h000000FF) == 32'd0) begin n = n + 6'd8;  t = t >> 8;  end
        if((t & 32'h0000000F) == 32'd0) begin n = n + 6'd4;  t = t >> 4;  end
        if((t & 32'h00000003) == 32'd0) begin n = n + 6'd2;  t = t >> 2;  end
        if((t & 32'h00000001) == 32'd0) begin n = n + 6'd1;  t = t >> 1;  end
        tz32 = (v == 32'd0) ? 6'd32 : n;
    end
endfunction

function [5:0] lz32;                       // zeros above the highest set bit, 32 if empty
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        t = v; n = 6'd0;
        if((t & 32'hFFFF0000) == 32'd0) begin n = n + 6'd16; t = t << 16; end
        if((t & 32'hFF000000) == 32'd0) begin n = n + 6'd8;  t = t << 8;  end
        if((t & 32'hF0000000) == 32'd0) begin n = n + 6'd4;  t = t << 4;  end
        if((t & 32'hC0000000) == 32'd0) begin n = n + 6'd2;  t = t << 2;  end
        if((t & 32'h80000000) == 32'd0) begin n = n + 6'd1;  t = t << 1;  end
        lz32 = (v == 32'd0) ? 6'd32 : n;
    end
endfunction

function [31:0] px32;                      // bit k = XOR of v[k:0], five XOR levels
    input [31:0] v;
    reg [31:0] t;
    begin
        t = v;
        t = t ^ (t << 1);
        t = t ^ (t << 2);
        t = t ^ (t << 4);
        t = t ^ (t << 8);
        t = t ^ (t << 16);
        px32 = t;
    end
endfunction
"""


# ---------------------------------------------------------------------------
# 1  CRC-32/ISO-HDLC frame engine
# ---------------------------------------------------------------------------
# Published reflected CRC-32: polynomial written reversed (0xEDB88320), each
# payload byte XORed into the low byte of the running register, eight right
# shifts per byte, initial register 0xFFFFFFFF, complemented result. Byte 0 of a
# beat is a[7:0] and each byte enters LSB first, which is exactly the
# transmission order, so a frame folds beat by beat.
CRC32_POLY = 0xEDB88320
CRC32_INIT = 0xFFFFFFFF
# Folding a correct frame *including* its four appended checksum bytes leaves the
# raw register at 0xDEBB20E3 whatever the message length or the beat boundaries.
# Hardware checkers compare against that residue instead of complementing.
CRC32_RESIDUE = 0xDEBB20E3


def crc32_fold(reg, nbytes, word):
    """Bit-serial CRC-32 register update; independent of the generated matrix."""
    for _ in range(nbytes):
        reg ^= word & 0xFF
        for _ in range(8):
            reg = (reg >> 1) ^ (CRC32_POLY if reg & 1 else 0)
        word >>= 8
    return reg & MASK


def crc32_matrix(nbytes):
    """The 32 (state, data) XOR masks of one nbytes-wide CRC-32 step.

    The byte step is linear over GF(2), so its value on any (register, data) pair
    is the XOR of the columns selected by the set bits. Columns come from running
    the serial reference on unit vectors, never from a hand-written table.
    """
    cols_s = [crc32_fold(1 << j, nbytes, 0) for j in range(32)]
    cols_d = [crc32_fold(0, nbytes, 1 << k) for k in range(8 * nbytes)]
    return [(sum(1 << j for j in range(32) if (cols_s[j] >> i) & 1),
             sum(1 << k for k in range(8 * nbytes) if (cols_d[k] >> i) & 1))
            for i in range(32)]


def crc32_decl():
    lines = [
        '// Generated parallel CRC-32 fold: one XOR tree per output bit and per',
        '// byte length. The Python model uses the serial reference, so RTL and',
        '// model agreeing is the proof that the matrix is the right one.',
        "wire [2:0] nb = c[2:0];",
        "wire [31:0] cs = c[31] ? b[31:0] : state_r[31:0];"]
    for nbytes in (1, 2, 3, 4):
        lines.append(f'wire [31:0] cr{nbytes};')
        for index, (sm, dm) in enumerate(crc32_matrix(nbytes)):
            lines.append("assign cr%d[%d] = ^({cs & 32'h%s, a & 32'h%s});"
                         % (nbytes, index, hexs(sm), hexs(dm)))
    lines.append("wire [31:0] crx = (nb == 3'd4) ? cr4 : (nb == 3'd3) ? cr3"
                 " : (nb == 3'd2) ? cr2 : cr1;")
    return '\n'.join(lines) + '\n'


core('comm_crc32_frame',
     'Running CRC-32/ISO-HDLC frame checker over up to 32 new payload bits per '
     'accepted beat. Byte j of the beat is a[8j+7:8j], byte 0 folds first and '
     'every byte enters LSB first, so a beat is exactly transmission order. '
     'c[2:0] = payload bytes folded by this beat, 1..4. c[31]=1 loads the '
     'register from b[31:0] before folding, so the standard seed 0xFFFFFFFF turns '
     'the nine bytes "123456789" into result 0xCBF43926. c[30]=1 closes the frame '
     'and tests the published residue: fault=1 unless the raw register equals '
     '0xDEBB20E3, which is what a correct frame folded together with its own four '
     'checksum bytes must leave; a closing beat then reloads register 0xFFFFFFFF '
     'and byte count 0 so the next beat already belongs to a new frame. c[29:3] '
     'must be zero. result[31:0] = the finalized checksum (raw register '
     'complemented, the value a transmitter appends). aux[7:0] = payload bytes '
     'folded in this frame saturating at 255, aux[10:8] = bytes folded by this '
     'beat, aux[11] = seed applied, aux[12] = frame closed, aux[13] = the byte '
     'count was already saturated before this beat (a closing beat clears it), '
     'aux[31:14] = 0. State: raw register = state[31:0], byte count = state[39:32]. '
     'A malformed beat (byte count 0 or above 4, or a set reserved bit) returns '
     'result=aux=0, fault=1 and leaves state untouched.',
     "if(nb == 3'd0 || nb > 3'd4 || c[29:3] != 27'd0) f = 1'b1;\n"
     "else begin\n"
     "    pa = crx;\n"
     "    r = ~pa;\n"
     "    temp = {24'd0, state_r[39:32]} + {29'd0, nb};\n"
     "    x[7:0] = c[30] ? 8'd0 : (temp > 32'd255) ? 8'hFF : temp[7:0];\n"
     "    x[10:8] = nb;\n"
     "    x[11] = c[31];\n"
     "    x[12] = c[30];\n"
     "    x[13] = c[30] ? 1'b0 : (state_r[39:32] == 8'hFF);\n"
     "    x[31:14] = 18'd0;\n"
     "    if(c[30] && pa != 32'h" + hexs(CRC32_RESIDUE) + ") f = 1'b1;\n"
     "    state_n = c[30] ? {216'd0, 8'd0, 32'h" + hexs(CRC32_INIT) + "}\n"
     "                      : {216'd0, x[7:0], pa};\n"
     "end",
     'A 32-bit XOR tree folds four bytes every enabled cycle, so a 1500-byte '
     'frame is checked in 375 beats, while the bit-serial loop costs eight shifts, '
     'eight conditional polynomial XORs and a 4 KiB table lookup per byte.', 4,
     decl=crc32_decl(), stateful=True)


# ---------------------------------------------------------------------------
# 2  NRZI / FM line-code transform with density and lock watchdogs
# ---------------------------------------------------------------------------
NRZI_DECL = POPDECL + """
wire       nr_ref = c[31] ? 1'b0 : state_r[0];
wire [7:0] nr_run = c[31] ? 8'd0 : state_r[8:1];
wire [7:0] nr_tot = c[31] ? 8'd0 : state_r[31:24];
// Transition map: where the channel level changes, which is the data word.
wire [31:0] nr_map = c[30] ? a : (a ^ ((a << 1) | {31'd0, nr_ref}));
// Channel word: NRZI is the running XOR of the data, so encoding is a prefix XOR.
wire [31:0] nr_chan = c[30] ? (px32(a) ^ (nr_ref ? 32'hFFFFFFFF : 32'h00000000)) : a;
wire [31:0] nr_out  = c[30] ? nr_chan : nr_map;
wire        nr_lvl  = c[30] ? nr_chan[31] : a[31];
wire [5:0]  nr_dens = pc32(nr_map);
wire [8:0]  nr_raw_out = (nr_map == 32'd0)
    ? ({1'b0, nr_run} + 9'd32) : {3'd0, lz32(nr_map)};
wire [9:0]  nr_raw_span = {2'b0, nr_run} + {4'b0, tz32(nr_map)};
wire [7:0]  nr_run_out  = (nr_raw_out  > 10'd255) ? 8'hFF : nr_raw_out[7:0];
wire [7:0]  nr_run_span = (nr_raw_span > 10'd255) ? 8'hFF : nr_raw_span[7:0];
wire [9:0]  nr_tot_raw = {2'b0, nr_tot} + {4'b0, nr_dens};
wire [7:0]  nr_tot_out = (nr_tot_raw > 10'd255) ? 8'hFF : nr_tot_raw[7:0];
wire nr_alarm =
      ((b[5:0]  != 6'd0)  && ({1'b0, nr_dens} > {1'b0, b[5:0]}))
   || ((b[11:6] != 6'd0)  && ({1'b0, nr_dens} < {1'b0, b[11:6]}))
   || ((b[19:12] != 8'd0) && (nr_raw_out  > {1'b0, b[19:12]}))
   || ((b[19:12] != 8'd0) && (nr_raw_span > {2'b0, b[19:12]}));
"""

core('comm_nrzi_fmr32',
     'NRZI (FMR) line-code transform for a 32-bit slice of the serial stream with '
     'transition-density and clock-lock accounting. Bit 0 of every word is the '
     'earliest in time. c[30]=0 decodes: result=data with data[k]=chan[k]^chan[k-1] '
     'and chan[-1]=state[0]. c[30]=1 encodes: result=channel level with '
     'chan[k]=chan[k-1]^data[k] and the same reference, so in both directions the '
     'data-domain word is the transition map and the same watchdogs apply to a '
     'transmit stream. c[31]=1 restarts first: the reference level becomes 0 and '
     'the run and total counters clear, then this beat is processed. c[29:1] must '
     'be zero. Limits come from b: b[5:0]=maximum transitions per beat (0 '
     'disables), b[11:6]=minimum transitions per beat (0 disables; a minimum above '
     '32 can never be met so it always alarms), b[19:12]=maximum transition-free '
     'bits measured over beat boundaries (0 disables), b[31:20] must be zero. '
     'result[31:0]=the transformed word. aux[5:0]=transitions this beat, '
     'aux[13:6]=the transition-free run leaving this beat (saturating), '
     'aux[21:14]=the run that ends at this beat\'s first transition, i.e. the '
     'carried run plus this beat\'s leading data zeros (saturating), aux[22]=this '
     'beat had no transition, aux[23]=a limit was violated, aux[31:24]=transitions '
     'folded since the last restart (saturating). fault=1 on any violated limit '
     '(the response is still reported and state still advances) or on a malformed '
     'beat, which returns result=aux=0 and leaves state untouched. State: '
     'reference level = state[0], carried run = state[8:1], transitions total = '
     'state[31:24]. A run that starts and ends strictly inside one beat is only '
     'caught by the minimum-transition check.',
     "if(c[29:1] != 29'd0 || b[31:20] != 12'd0) f = 1'b1;\n"
     "else begin\n"
     "    r = nr_out;\n"
     "    x[5:0] = nr_dens;\n"
     "    x[13:6] = nr_run_out;\n"
     "    x[21:14] = nr_run_span;\n"
     "    x[22] = (nr_map == 32'd0);\n"
     "    x[23] = nr_alarm;\n"
     "    x[31:24] = nr_tot_out;\n"
     "    if(nr_alarm) f = 1'b1;\n"
     "    state_n = {224'd0, nr_tot_out, 15'd0, nr_run_out, nr_lvl};\n"
     "end",
     'A 32-bit prefix-XOR net and a 32-bit differential net replace the '
     'per-bit loop a soft core runs for the same slice, and the density, gap and '
     'lock alarms are produced in the same beat, so the line-code check costs no '
     'extra pass over the data.', 32, decl=NRZI_DECL, stateful=True)


# ---------------------------------------------------------------------------
# 3  Bit-level sync-marker hunter with lock and loss-of-frame accounting
# ---------------------------------------------------------------------------
PAT_DECL = POPDECL + """
wire       pl_load = c[31];
wire [31:0] pl_pat = pl_load ? b[31:0] : state_r[63:32];
wire [31:0] pl_old = pl_load ? 32'd0 : state_r[31:0];
wire [63:0] pl_win = {a, pl_old};
wire [32:0] pl_m;
genvar gp;
generate
    for(gp = 0; gp < 33; gp = gp + 1) begin : g_cmp
        assign pl_m[gp] = (pl_win[gp +: 32] == pl_pat);
    end
endgenerate
wire       pl_any = |pl_m;
// Position 32 is the newest of the 33 phases, so it wins over the bitmap.
wire [5:0] pl_newest = pl_m[32] ? 6'd32
                             : (pl_m[31:0] != 32'd0) ? (6'd31 - lz32(pl_m[31:0]))
                                                     : 6'd0;
wire [5:0] pl_cnt6 = pc32(pl_m[31:0]) + {5'd0, pl_m[32]};
wire [4:0] pl_cnt = (pl_cnt6 > 6'd31) ? 5'd31 : pl_cnt6[4:0];
// Distance to the marker for this beat's own word: a near miss says the phase
// hunt is within a few bit slips of lock, which is worth reporting although
// nothing matched, and it is what makes a non-matching beat observable.
wire [5:0] pl_dist = pc32(a ^ pl_pat);
wire       pl_near = (pl_dist != 6'd0) && (pl_dist <= {2'd0, c[11:8]}) && ~pl_any;
wire [3:0] pl_mc = state_r[67:64];
wire [3:0] pl_xc = state_r[71:68];
wire       pl_locked = state_r[72];
wire [7:0] pl_evt = state_r[80:73];
wire [3:0] pl_mc_n = pl_any ? ((pl_mc == 4'hF) ? 4'hF : pl_mc + 4'd1) : 4'd0;
wire [3:0] pl_xc_n = pl_any ? 4'd0 : ((pl_xc == 4'hF) ? 4'hF : pl_xc + 4'd1);
wire pl_lock_n = pl_any ? ((pl_mc_n >= c[3:0]) ? 1'b1 : pl_locked)
                        : ((pl_xc_n >= c[7:4]) ? 1'b0 : pl_locked);
wire pl_lock_evt = pl_lock_n & ~pl_locked;
wire pl_loss_evt = ~pl_lock_n & pl_locked;
wire [7:0] pl_evt_n = (pl_evt == 8'hFF) ? 8'hFF : (pl_evt + {7'd0, pl_lock_evt});
"""

core('comm_pattern_lock32',
     'Bit-level sync-marker hunter: every accepted beat appends 32 channel bits '
     '(bit 0 oldest, bit 31 newest) to the 32 bits kept in state, giving a 64-bit '
     'window, and all 33 positions p=0..32 are tested for a 32-bit equality '
     'against the stored pattern, so a marker such as the G.709 frame alignment '
     'signal 0xF6F6F6FA is found at any bit offset across a beat boundary. '
     'c[31]=1 is a load beat: the pattern becomes b[31:0], the window and both '
     'counters and the locked flag clear, and the beat is still correlated against '
     'the empty window. c[3:0]=beats-with-a-match needed to declare lock and '
     'c[7:4]=beats-without-a-match needed to declare loss, both 1..15; c[11:8]=near'
     '-miss tolerance in bits (0 disables the check); c[30:12] must be zero. '
     'result[31:0]=match bitmap, bit p = the pattern starts at window position p. '
     'aux[0]=match at position 32, aux[1]=any match, aux[2]=locked after this beat, '
     'aux[3]=lock acquired this beat, aux[4]=frame lost this beat, aux[5]=near miss: '
     'this beat matched nowhere and its own word differs from the marker in 1 to '
     'tolerance bits, aux[6]=load beat, aux[10:7]=matching-beat counter, '
     'aux[14:11]=non-matching-beat counter, aux[20:15]=newest match position (0 '
     'when there is no match), aux[25:21]=matching positions found this beat, '
     'saturating at 31, aux[31:26]=Hamming distance from this beat\'s word to the '
     'marker, 0..32, which is the bit-phase hunt telemetry on a beat that matched '
     'nothing. fault=1 on a loss-of-frame event or on a near miss (the full '
     'response is still reported) or on a malformed beat, which returns result='
     'aux=0 and leaves state untouched. State: window=state[31:0], pattern='
     'state[63:32], matching-beat counter=state[67:64], non-matching-beat '
     'counter=state[71:68], locked=state[72], lock events=state[80:73] saturating.',
     "if(c[30:12] != 19'd0 || c[3:0] == 4'd0 || c[7:4] == 4'd0) f = 1'b1;\n"
     "else begin\n"
     "    r = pl_m[31:0];\n"
     "    x[0] = pl_m[32];\n"
     "    x[1] = pl_any;\n"
     "    x[2] = pl_lock_n;\n"
     "    x[3] = pl_lock_evt;\n"
     "    x[4] = pl_loss_evt;\n"
     "    x[5] = pl_near;\n"
     "    x[6] = pl_load;\n"
     "    x[10:7] = pl_mc_n;\n"
     "    x[14:11] = pl_xc_n;\n"
     "    x[20:15] = pl_newest;\n"
     "    x[25:21] = pl_cnt;\n"
     "    x[31:26] = pl_dist;\n"
     "    if(pl_loss_evt || pl_near) f = 1'b1;\n"
     "    state_n = {175'd0, pl_evt_n, pl_lock_n, pl_xc_n, pl_mc_n, pl_pat, a};\n"
     "end",
     '33 full 32-bit comparisons retire in one enabled beat. A soft core hunting '
     'bit-phase must shift a 64-bit window and re-compare once per bit offset, '
     'roughly 330 operations per beat, and cannot hold a fixed hunt rate.', 33,
     decl=PAT_DECL, stateful=True)


# ---------------------------------------------------------------------------
# 4  16-bit polar (Arikan) encoder with frozen-bit checking
# ---------------------------------------------------------------------------
POLAR_MASKS = [sum(1 << j for j in range(16) if (i & j) == j) for i in range(16)]
POLAR_REV = [int(format(i, '04b')[::-1], 2) for i in range(16)]


def polar_decl():
    lines = [
        '// Polar kernel G_16 = F^x4 with F=[[1,0],[1,1]]: output bit i is the XOR',
        '// of the input bits j that are subsets of i. Input bit 0 therefore',
        '// repeats into all sixteen outputs and input bit 15 only reaches output',
        '// 15, which is the parity of the whole vector; output 0 is the identity.']
    for lane in (0, 1):
        lines += [
            "wire [15:0] pl_u%d = a[%d:%d];" % (lane, 16 * lane + 15, 16 * lane),
            "wire [15:0] pl_fz%d = b[%d:%d];" % (lane, 16 * lane + 15, 16 * lane),
            "wire [15:0] pl_g%d = pl_u%d & ~pl_fz%d;" % (lane, lane, lane),
            "wire pl_cf%d = |(pl_u%d & pl_fz%d);" % (lane, lane, lane)]
    for lane in (0, 1):
        # {v[15], v[14], ... v[0]} with v[k] = pl_g[rev4(k)]
        bits = ', '.join('pl_g%d[%d]' % (lane, POLAR_REV[k]) for k in range(15, -1, -1))
        lines.append("wire [15:0] pl_v%d = c[31] ? {%s} : pl_g%d;"
                     % (lane, bits, lane))
    for lane in (0, 1):
        lines.append(f'wire [15:0] pl_x{lane};')
        for i in range(16):
            lines.append("assign pl_x%d[%d] = ^(pl_v%d & 16'h%s);"
                         % (lane, i, lane, hexs(POLAR_MASKS[i], 4)))
    lines.append(POPDECL)
    # A 16-bit weight reaches 16, so the helper returns 5 bits.
    lines.append("""
function [4:0] w16;                          // weight of one 16-bit lane word
    input [15:0] v;
    reg [5:0] t;
    begin
        t = pc32({16'd0, v});
        w16 = t[4:0];
    end
endfunction
""")
    return '\n'.join(lines) + '\n'


core('comm_polar_enc16',
     'Two independent 16-bit polar (Arikan kernel) encodes per accepted beat. '
     'Lane 0 reads the input vector u=a[15:0] and the frozen-bit map '
     'f=b[15:0]; lane 1 reads a[31:16] and b[31:16]; bit j is input position j. A '
     'frozen position must carry 0, so u[j]=1 with f[j]=1 is a freeze conflict: '
     'that bit is forced to 0 for the encode, fault=1, and the conflict is '
     'reported. The codeword is x[i] = XOR of the surviving input bits j that are '
     'bitwise subsets of i (G_16 = F^x4, F=[[1,0],[1,1]]), so output 0 is the '
     'identity of input 0, output 15 is the parity of all sixteen inputs, input 0 '
     'repeats into every output and G_16 is its own inverse. c[31]=1 applies the '
     '4-bit index bit-reversal to each input vector before the transform, so '
     'either the natural or the bit-reversed '
     'channel ordering can be fed; the frozen map always refers to the pre-'
     'reversal positions. c[30:1] must be zero. result[15:0]=lane 0 codeword, '
     'result[31:16]=lane 1 codeword. aux[4:0]=weight of codeword 0, aux[9:5]='
     'weight of codeword 1, aux[14:10]=information positions used by lane 0 '
     '(16 minus the frozen count), aux[19:15]=same for lane 1, aux[20]=lane 0 '
     'freeze conflict, aux[21]=lane 1 freeze conflict, aux[22]=bit-reversal '
     'applied, aux[31:23]=0. A set reserved bit in c is a malformed beat: '
     'result=aux=0, fault=1, and nothing is retained because the core is '
     'combinational.',
     "if(c[30:1] != 30'd0) f = 1'b1;\n"
     "else begin\n"
     "    r = {pl_x1, pl_x0};\n"
     "    x[4:0] = w16(pl_x0);\n"
     "    x[9:5] = w16(pl_x1);\n"
     "    x[14:10] = 5'd16 - w16(pl_fz0);\n"
     "    x[19:15] = 5'd16 - w16(pl_fz1);\n"
     "    x[20] = pl_cf0;\n"
     "    x[21] = pl_cf1;\n"
     "    x[22] = c[31];\n"
     "    x[31:23] = 9'd0;\n"
     "    if(pl_cf0 || pl_cf1) f = 1'b1;\n"
     "end",
     'A 4-level XOR butterfly encodes two 16-bit polar blocks per enabled beat '
     'with the frozen-bit validity check in the same cone; the same kernel needs '
     'a 16-step Gray-code loop plus a mask test per block in software.', 2,
     decl=polar_decl())


# ---------------------------------------------------------------------------
# 5  16-QAM max-log soft demapper
# ---------------------------------------------------------------------------
# |x - y| of two signed 9-bit operands as an unsigned byte: the one arithmetic
# primitive both the demapper and the Viterbi section need.
ABSDIFF = """
function [7:0] qd;                         // |x-y| of two signed 9-bit operands
    input signed [8:0] x;
    input signed [8:0] y;
    begin
        qd = (x >= y) ? (x - y) : (y - x);
    end
endfunction
"""

QAM_FUNCS = ABSDIFF + """
function [7:0] qm8;                        // the smaller unsigned distance
    input [7:0] p;
    input [7:0] q;
    begin
        qm8 = (p <= q) ? p : q;
    end
endfunction

function [1:0] qarg;                       // argmin level, lowest index on a tie
    input [7:0] d0;
    input [7:0] d1;
    input [7:0] d2;
    input [7:0] d3;
    begin
        if(d0 <= d1 && d0 <= d2 && d0 <= d3) qarg = 2'd0;
        else if(d1 <= d2 && d1 <= d3)        qarg = 2'd1;
        else if(d2 <= d3)                    qarg = 2'd2;
        else                                 qarg = 2'd3;
    end
endfunction

function [8:0] qscale;                     // {saturated, value} of a scaled LLR
    input signed [9:0] v;
    input [2:0] s;
    reg signed [16:0] acc;
    begin
        acc = v;
        acc = acc <<< s;
        qscale = (acc > 17'sd127) ? 9'h17F
                 : (acc < -17'sd128) ? 9'h180 : {1'b0, acc[7:0]};
    end
endfunction
"""


def qam_decl():
    lines = [
        '// Gray-labelled 16-QAM: one axis holds the four levels -3S, -S, +S, +3S',
        '// numbered 0..3 and labelled gray(k) = k ^ (k >> 1), so bit 1 selects the',
        '// half of the axis and bit 0 selects inner against outer. A rectangular',
        '// constellation separates per axis under max-log MAP, so eight absolute',
        '// differences and six minima give both LLRs of both axes: no 2-D search',
        '// over 16 points and no multiplier anywhere.',
        "wire signed [8:0] qs = {6'd0, b[2:0]};",
        "wire signed [8:0] qns = -qs;",
        "wire [5:0] q3v = {3'd0, b[2:0]} + {2'd0, b[2:0], 1'b0};",
        "wire signed [8:0] q3s = {3'd0, q3v};",
        "wire signed [8:0] qn3s = -q3s;",
        "wire [7:0] q7v = {2'd0, b[2:0], 3'd0} - {5'd0, b[2:0]};"]
    for tag, field, sign in (('i', 'a[7:0]', 'a[7]'), ('q', 'a[15:8]', 'a[15]')):
        lines += [
            "wire signed [8:0] qv%s = {{1{%s}}, %s};" % (tag, sign, field),
            "wire [7:0] qd%s0 = qd(qv%s, qn3s);" % (tag, tag),
            "wire [7:0] qd%s1 = qd(qv%s, qns);" % (tag, tag),
            "wire [7:0] qd%s2 = qd(qv%s, qs);" % (tag, tag),
            "wire [7:0] qd%s3 = qd(qv%s, q3s);" % (tag, tag),
            # qa = nearest level with bit 0 (outer pair), qb = with bit 1 (inner)
            "wire [7:0] qa%s = qm8(qd%s0, qd%s3);" % (tag, tag, tag),
            "wire [7:0] qb%s = qm8(qd%s1, qd%s2);" % (tag, tag, tag),
            # qc = nearest level with bit 1 = 0 (low half), qg = with bit 1 = 1
            "wire [7:0] qc%s = qm8(qd%s0, qd%s1);" % (tag, tag, tag),
            "wire [7:0] qg%s = qm8(qd%s2, qd%s3);" % (tag, tag, tag),
            "wire signed [9:0] ql%s0 = $signed({2'b0, qb%s})"
            " - $signed({2'b0, qa%s});" % (tag, tag, tag),
            "wire signed [9:0] ql%s1 = $signed({2'b0, qg%s})"
            " - $signed({2'b0, qc%s});" % (tag, tag, tag),
            "wire [1:0] qk%s = qarg(qd%s0, qd%s1, qd%s2, qd%s3);"
            % (tag, tag, tag, tag, tag),
            "wire [7:0] qz%s = qd(qv%s, 9'sd0);" % (tag, tag),
            "wire [7:0] qm%s = qm8(qm8(qm8(qd%s0, qd%s1), qd%s2), qd%s3);"
            % (tag, tag, tag, tag, tag)]
    lines += [
        "wire [8:0] qmd = {1'b0, qmi} + {1'b0, qmq};",
        "wire qor = (qzi > q7v) || (qzq > q7v);"]
    return QAM_FUNCS + '\n'.join(lines) + '\n'


core('comm_qam16_llr',
     'Max-log soft demapper for one Gray-labelled 16-QAM symbol per accepted '
     'beat. The in-phase coordinate is the signed byte a[7:0] and the quadrature '
     'coordinate is the signed byte a[15:8]; a[31:16] must be zero. Each axis '
     'carries the four levels -3S, -S, +S, +3S in that order, numbered k=0..3, '
     'with the symbol spacing S=b[2:0] in 1..7 and b[31:3] zero; level k emits '
     'the two Gray bits k^(k>>1), so bit 1 says which half of the axis and bit 0 '
     'says inner or outer. A rectangular constellation separates per axis under '
     'max-log MAP, so LLR(bit) = (smallest axis distance |coordinate-level| over '
     'the levels with bit=1) - (smallest over bit=0): positive means bit 0 is '
     'nearer. Both raw LLRs are multiples of S at most, so each is scaled by the '
     'receiver LLR gain 2^c[2:0] (0..7) and saturated to a signed byte; c[31:3] '
     'must be zero. result[7:0]=LLR of I bit 0, result[15:8]=LLR of I '
     'bit 1, result[23:16]=LLR of Q bit 0, result[31:24]=LLR of Q bit 1, all '
     'signed. aux[3:0]=hard decisions in the same order (1 when the raw, '
     'unscaled LLR is negative, a tie decides 0), aux[5:4]=index of the nearest '
     'level on I with the lowest index on a tie, aux[7:6]=same on Q, aux[10:8]='
     'the gain exponent, aux[11+k]=LLR k saturated the signed byte, aux[15]='
     'over-range alarm: |I| or |Q| exceeds 7S, aux[24:16]=Manhattan distance to '
     'the nearest constellation point (both axis contributions added), '
     'aux[27:25]=S, aux[31:28]=0. fault=1 when any LLR saturated or the '
     'over-range alarm fired (the full response is still reported) or on a '
     'malformed beat, which returns result=aux=0.',
     "if(a[31:16] != 16'd0 || b[31:3] != 29'd0 || b[2:0] == 3'd0"
     " || c[31:3] != 29'd0) f = 1'b1;\n"
     "else begin\n"
     "    pa = qscale(qli0, c[2:0]);\n"
     "    r[7:0] = pa[7:0];\n"
     "    x[11] = pa[8];\n"
     "    pa = qscale(qli1, c[2:0]);\n"
     "    r[15:8] = pa[7:0];\n"
     "    x[12] = pa[8];\n"
     "    pa = qscale(qlq0, c[2:0]);\n"
     "    r[23:16] = pa[7:0];\n"
     "    x[13] = pa[8];\n"
     "    pa = qscale(qlq1, c[2:0]);\n"
     "    r[31:24] = pa[7:0];\n"
     "    x[14] = pa[8];\n"
     "    x[0] = qli0[9];\n"
     "    x[1] = qli1[9];\n"
     "    x[2] = qlq0[9];\n"
     "    x[3] = qlq1[9];\n"
     "    x[5:4] = qki;\n"
     "    x[7:6] = qkq;\n"
     "    x[10:8] = c[2:0];\n"
     "    x[15] = qor;\n"
     "    x[24:16] = qmd;\n"
     "    x[27:25] = b[2:0];\n"
     "    x[31:28] = 4'd0;\n"
     "    if(x[15] || x[14] || x[13] || x[12] || x[11]) f = 1'b1;\n"
     "end",
     'Eight absolute differences and six 8-bit minima retire a full 4-bit soft '
     'symbol in one enabled beat. The exact max-log MAP form needs 16 squared '
     'Euclidean distances and 16 min updates, so a soft core looping over a '
     'constellation cannot hold a symbol rate at all.', 4, decl=qam_decl())


# ---------------------------------------------------------------------------
# 6  Four-state rate-1/2 Viterbi add-compare-select step
# ---------------------------------------------------------------------------
VIT_CEIL = 1023          # unreachable-and-saturating path metric
VIT_SENT = 2047          # "no candidate" marker for the minima trees


def vbi_decl():
    lines = [
        '// One trellis section of the (7,5) octal rate-1/2 K=3 code. With input u',
        '// and register bits u1, u2 the channel bits are c0 = u^u1^u2 and',
        '// c1 = u^u2, the state is s = u1*2+u2 and the next state is u*2+u1, so',
        '// for a given next state u and the predecessor high bit are fixed and',
        '// every branch distance below is static wiring rather than a mux tree:',
        '// four add-compare-select units plus two minima trees in one cone.']
    for c0 in (0, 1):
        for c1 in (0, 1):
            e0 = 'vp' if c0 == 0 else 'vm'
            e1 = 'vp' if c1 == 0 else 'vm'
            m0 = 'vh0' if c0 == 0 else '~vh0'
            m1 = 'vh1' if c1 == 0 else '~vh1'
            lines += [
                "wire [7:0] vsd%d%d = qd(vy0, %s) + qd(vy1, %s);" % (c0, c1, e0, e1),
                "wire [2:0] vhd%d%d = {2'd0, %s} + {2'd0, %s};" % (c0, c1, m0, m1),
                "wire [7:0] vbd%d%d = c[30] ? {5'd0, vhd%d%d} : vsd%d%d;"
                % (c0, c1, c0, c1, c0, c1)]
    for ns in range(4):
        u = (ns >> 1) & 1
        s1 = ns & 1
        for p in (0, 1):
            s = 2 * s1 + p
            lines += [
                "wire [10:0] vsum%d%d = {1'b0, vpm%d} + {3'b0, vbd%d%d};"
                % (ns, p, s, u ^ s1 ^ p, u ^ p),
                "wire [10:0] vcd%d%d = vrc%d ? ((vsum%d%d > 11'd%d) ? 11'd%d"
                " : vsum%d%d) : 11'd%d;" % (ns, p, s, ns, p, VIT_CEIL, VIT_CEIL,
                                            ns, p, VIT_CEIL),
                "wire vsat%d%d = vrc%d && (vsum%d%d > 11'd%d);"
                % (ns, p, s, ns, p, VIT_CEIL)]
        lines += [
            "wire vdec%d = (vcd%d1 < vcd%d0);" % (ns, ns, ns),
            "wire [10:0] vch%d = vdec%d ? vcd%d1 : vcd%d0;" % (ns, ns, ns, ns),
            "wire vrn%d = vrc%d | vrc%d;" % (ns, 2 * s1, 2 * s1 + 1),
            "wire vtie%d = vrn%d && (vcd%d0 == vcd%d1);" % (ns, ns, ns, ns),
            "wire [10:0] vmn%d = vrn%d ? vch%d : 11'd%d;" % (ns, ns, ns, VIT_SENT)]
    lines += [
        "wire [10:0] vmn = vmin(vmin(vmn0, vmn1), vmin(vmn2, vmn3));",
        "wire vtie = vtie0 | vtie1 | vtie2 | vtie3;",
        "wire vsat = vsat00 | vsat01 | vsat10 | vsat11 | vsat20 | vsat21"
        " | vsat30 | vsat31;",
        "wire vbest0 = vrn0 && (vch0 == vmn);",
        "wire vbest1 = vrn1 && (vch1 == vmn);",
        "wire vbest2 = vrn2 && (vch2 == vmn);",
        "wire [1:0] vbst = vbest0 ? 2'd0 : vbest1 ? 2'd1 : vbest2 ? 2'd2 : 2'd3;",
        "wire [2:0] vcnt = {2'd0, vrn0} + {2'd0, vrn1} + {2'd0, vrn2} + {2'd0, vrn3};"]
    for ns in range(4):
        lines += [
            "wire [10:0] vsub%d = vch%d - vmn;" % (ns, ns),
            "wire [9:0] vpn%d = vrn%d ? vsub%d[9:0] : 10'd%d;"
            % (ns, ns, ns, VIT_CEIL),
            "wire [10:0] vsec%d = (vrn%d && vbst != 2'd%d) ? vch%d : 11'd%d;"
            % (ns, ns, ns, ns, VIT_SENT)]
    lines += [
        "wire [10:0] vsec = vmin(vmin(vsec0, vsec1), vmin(vsec2, vsec3));",
        "wire [10:0] vmarw = vsec - vmn;",
        "wire [4:0] vmarg = (vmarw > 11'd31) ? 5'd31 : vmarw[4:0];",
        "wire [12:0] voffw = {1'b0, voff} + {2'b0, vmn};",
        "wire voffo = voffw > 13'd4095;",
        "wire [11:0] voffn = voffo ? 12'hFFF : voffw[11:0];"]
    decl = '\n'.join(lines) + '\n'
    header = """
function [10:0] vmin;                      // smaller of two candidate metrics
    input [10:0] p;
    input [10:0] q;
    begin
        vmin = (p <= q) ? p : q;
    end
endfunction

function [7:0] vsat8;                      // unsigned metric view, clipped
    input [9:0] v;
    begin
        vsat8 = (v > 10'd255) ? 8'hFF : v[7:0];
    end
endfunction
"""
    state = """
wire signed [8:0] vy0 = {{3{a[5]}}, a[5:0]};
wire signed [8:0] vy1 = {{3{a[11]}}, a[11:6]};
wire signed [8:0] vp = {6'd0, b[2:0]};
wire signed [8:0] vm = -vp;
wire vh0 = a[5];
wire vh1 = a[11];
"""
    slices = ["wire [9:0] vpm%d = c[31] ? 10'd%d : state_r[%d:%d];"
              % (k, 0 if k == 0 else VIT_CEIL, 10 * k + 9, 10 * k) for k in range(4)]
    slices += ['wire vrc%d = c[31] ? 1\'b%d : state_r[%d];'
               % (k, 1 if k == 0 else 0, 40 + k) for k in range(4)]
    slices.append("wire [11:0] voff = c[31] ? 12'd0 : state_r[55:44];")
    return ABSDIFF + header + state + \
        '\n'.join(slices) + '\n' + decl


core('comm_viterbi_acs4',
     'One trellis section of the (7,5) octal rate-1/2 K=3 convolutional code: a '
     'four-state add-compare-select step with runtime metric normalisation, per '
     'beat. With input u and register bits u1, u2 the two channel bits are '
     'c0=u^u1^u2 and c1=u^u2, the state is s=u1*2+u2 and the next state is '
     'u*2+u1, so a section ending at next state ns carried input u=ns[1] and came '
     'from one of the two predecessors 2*ns[0] and 2*ns[0]+1. The received pair '
     'is the signed 6-bit symbol set y0=a[5:0], y1=a[11:6] with a[31:12] zero, '
     'and channel bit b maps to the expected level +A for b=0 and -A for b=1 with '
     'A=b[2:0] and b[31:3] zero. c[30]=1 switches to hard-decision metrics, the '
     'number of the two channel bits that disagree with the sign of the matching '
     'symbol, and then A is irrelevant. c[29:1] must be zero. c[31]=1 restarts '
     'the trellis first - state 0 becomes the only reachable state with metric 0 '
     'and the offset clears - and this beat is then decoded normally. Each '
     'candidate is a predecessor metric plus its branch distance; a candidate '
     'from an unreachable predecessor is the ceiling 1023 and cannot win, a '
     'reachable sum above 1023 saturates to 1023 and raises fault, and ties keep '
     'predecessor 2*ns[0], so the kept predecessor index is the decision bit. '
     'The four kept metrics are normalised by subtracting the smallest reachable '
     'one and that amount is accumulated into a 12-bit offset which saturates at '
     '4095 and raises fault, so the maximum-likelihood path distance is offset '
     'plus the smallest metric. result[8k+7:8k]=state k metric after '
     'normalisation, clipped to 8 bits. aux[3:0]=decision bits, aux[5:4]=lowest '
     'index of the best reachable states, aux[8:6]=reachable state count, '
     'aux[13:9]=best-to-second-best margin clipped to 31 (31 with fewer than two '
     'reachable states), aux[14]=an ACS pair tied, aux[15]=a metric saturated, '
     'aux[16]=the offset saturated, aux[17]=restart applied, aux[29:18]=offset, '
     'aux[31:30]=0. State: metrics state[9:0], state[19:10], state[29:20], '
     'state[39:30]; reachable mask state[43:40]; offset state[55:44]. A malformed '
     'beat returns result=aux=0 and leaves state untouched.',
     "if(a[31:12] != 20'd0 || b[31:3] != 29'd0 || c[29:1] != 29'd0) f = 1'b1;\n"
     "else begin\n"
     "    r[7:0] = vsat8(vpn0);\n"
     "    r[15:8] = vsat8(vpn1);\n"
     "    r[23:16] = vsat8(vpn2);\n"
     "    r[31:24] = vsat8(vpn3);\n"
     "    x[3:0] = {vdec3, vdec2, vdec1, vdec0};\n"
     "    x[5:4] = vbst;\n"
     "    x[8:6] = vcnt;\n"
     "    x[13:9] = vmarg;\n"
     "    x[14] = vtie;\n"
     "    x[15] = vsat;\n"
     "    x[16] = voffo;\n"
     "    x[17] = c[31];\n"
     "    x[29:18] = voffn;\n"
     "    x[31:30] = 2'd0;\n"
     "    state_n = {200'd0, voffn, vrn3, vrn2, vrn1, vrn0,"
     " vpn3, vpn2, vpn1, vpn0};\n"
     "    if(vsat || voffo) f = 1'b1;\n"
     "end",
     'Four ACS units, the reachability gating, the saturation clamps and the '
     'metric normalisation all close in one enabled beat, which is the II=1 a '
     'soft processor cannot hold: the same section costs eight adds, four '
     'compares and a traceback store per symbol time.', 4,
     decl=vbi_decl(), stateful=True)


# --------------------------------------------------------------------- models
def s_bits(value, width):
    value &= (1 << width) - 1
    return value - (1 << width) if value >> (width - 1) else value


def px32(value, start=0):
    """Serial NRZI reference: level k = running XOR of the data bits up to k."""
    level = start
    word = 0
    for k in range(32):
        level ^= (value >> k) & 1
        word |= level << k
    return word


def nrzi_decode(channel, reference):
    """Serial differential decode: data k = channel k ^ channel k-1."""
    word = 0
    previous = reference
    for k in range(32):
        current = (channel >> k) & 1
        word ^= (current ^ previous) << k
        previous = current
    return word


def tz(value):
    """Zeros below the lowest set bit, 32 when the word is empty."""
    return 32 if value == 0 else ((value & -value) - 1).bit_length()


def lz(value):
    """Zeros above the highest set bit, 32 when the word is empty."""
    return 32 - value.bit_length()


def polar_zeta(vector):
    """x[i] = XOR of vector[j] for every j that is a subset of i.

    Written as the sum-over-subsets dynamic program, one XOR per lattice bit per
    stage, so it shares no code with the generated per-output XOR trees.
    """
    cell = [(vector >> i) & 1 for i in range(16)]
    for bit in range(4):
        for i in range(16):
            if (i >> bit) & 1:
                cell[i] ^= cell[i ^ (1 << bit)]
    return sum(cell[i] << i for i in range(16))


def qam_llr(raw, gain):
    """The receiver's LLR scaling: multiply by 2^gain, then saturate to a byte."""
    value = raw << gain
    clamped = max(-128, min(127, value))
    return clamped, int(clamped != value)


def viterbi_section(pm, reach, dist, offset):
    """The four ACS units, normalisation and telemetry of one trellis section."""
    chosen = []
    decision = []
    new_reach = []
    saturated = 0
    tied = 0
    for ns in range(4):
        u = (ns >> 1) & 1
        high = ns & 1
        cand = []
        for p in (0, 1):
            s = 2 * high + p
            if not reach[s]:
                cand.append(VIT_CEIL)
                continue
            total = pm[s] + dist[(u ^ high ^ p, u ^ p)]
            if total > VIT_CEIL:
                saturated = 1
                total = VIT_CEIL
            cand.append(total)
        decision.append(int(cand[1] < cand[0]))
        chosen.append(cand[1] if cand[1] < cand[0] else cand[0])
        new_reach.append(reach[2 * high] | reach[2 * high + 1])
        tied |= int(new_reach[-1] and cand[0] == cand[1])
    floor = min(chosen[ns] for ns in range(4) if new_reach[ns])
    normalised = [((chosen[ns] - floor) if new_reach[ns] else VIT_CEIL)
                  for ns in range(4)]
    best = next(ns for ns in range(4) if new_reach[ns] and chosen[ns] == floor)
    others = [chosen[ns] for ns in range(4) if new_reach[ns] and ns != best]
    margin = min(31, (min(others) if others else VIT_SENT) - floor)
    grown = offset + floor
    overflow = int(grown > 4095)
    return dict(pm=normalised, reach=new_reach, decision=decision, best=best,
                count=sum(new_reach), margin=margin, tie=tied, sat=saturated,
                offset=min(4095, grown), overflow=overflow, floor=floor)


def step(name, a, b, c, state=0):
    if name == 'comm_crc32_frame':
        nb = c & 7
        if nb == 0 or nb > 4 or (c >> 3) & 0x7FFFFFF:
            return 0, 0, 1, state
        register = state & MASK
        count = (state >> 32) & 0xFF
        seed = (c >> 31) & 1
        close = (c >> 30) & 1
        folded = crc32_fold(b if seed else register, nb, a)
        total = min(count + nb, 255)
        x = (nb << 8) | (seed << 11) | (close << 12)
        if not close:
            x |= total | (int(count == 255) << 13)
        fault = int(bool(close) and folded != CRC32_RESIDUE)
        return folded ^ MASK, x, fault, (CRC32_INIT if close
                                        else (total << 32) | folded)
    if name == 'comm_nrzi_fmr32':
        if (c >> 1) & 0x1FFFFFFF or b >> 20:
            return 0, 0, 1, state
        restart = (c >> 31) & 1
        encode = (c >> 30) & 1
        reference = 0 if restart else state & 1
        run = 0 if restart else (state >> 1) & 0xFF
        total = 0 if restart else (state >> 24) & 0xFF
        if encode:
            data = a & MASK
            channel = px32(data, reference)
        else:
            channel = a & MASK
            data = nrzi_decode(channel, reference)
        density = bin(data).count('1')
        raw_run = run + 32 if data == 0 else lz(data)
        raw_span = run + tz(data)
        gap = (b >> 12) & 0xFF
        max_bits = b & 0x3F
        min_bits = (b >> 6) & 0x3F
        alarm = bool((max_bits and density > max_bits)
                     or (min_bits and density < min_bits)
                     or (gap and (raw_run > gap or raw_span > gap)))
        run_out = min(raw_run, 255)
        kept = min(total + density, 255)
        x = (density | (run_out << 6) | (min(raw_span, 255) << 14)
             | (int(data == 0) << 22) | (alarm << 23) | (kept << 24))
        return channel if encode else data, x, int(alarm), \
            (kept << 24) | (run_out << 1) | ((channel >> 31) & 1)
    if name == 'comm_pattern_lock32':
        if (c >> 12) & 0x7FFFF or (c & 15) == 0 or ((c >> 4) & 15) == 0:
            return 0, 0, 1, state
        load = (c >> 31) & 1
        pattern = (b if load else (state >> 32) & MASK) & MASK
        window = ((a & MASK) << 32) | (0 if load else state & MASK)
        hit = [(((window >> p) & MASK) == pattern) for p in range(33)]
        any_hit = any(hit)
        matched = min(sum(hit), 31)
        distance = bin((a ^ pattern) & MASK).count('1')
        tolerance = (c >> 8) & 15
        near = int(distance != 0 and distance <= tolerance and not any_hit)
        counters = (min(((state >> 64) & 15) + 1, 15) if any_hit else 0,
                    0 if any_hit else min(((state >> 68) & 15) + 1, 15))
        matched_count, missed_count = counters
        locked = (state >> 72) & 1
        if any_hit:
            lock = 1 if matched_count >= (c & 15) else locked
        else:
            lock = 0 if missed_count >= ((c >> 4) & 15) else locked
        acquired = int(lock and not locked)
        lost = int(not lock and locked)
        positions = [p for p in range(33) if hit[p]]
        x = (int(hit[32]) | (int(any_hit) << 1) | (lock << 2) | (acquired << 3)
             | (lost << 4) | (near << 5) | (load << 6)
             | (matched_count << 7) | (missed_count << 11)
             | ((positions[-1] if positions else 0) << 15) | (matched << 21)
             | (distance << 26))
        events = min(((state >> 73) & 0xFF) + acquired, 255)
        result = sum(1 << p for p in range(32) if hit[p])
        return result, x, lost | near, ((events << 73) | (lock << 72)
                                        | (missed_count << 68)
                                        | (matched_count << 64)
                                        | (pattern << 32) | (a & MASK))
    if name == 'comm_polar_enc16':
        if (c >> 1) & 0x3FFFFFFF:
            return 0, 0, 1, state
        reverse = (c >> 31) & 1
        result = aux = fault = 0
        for lane in (0, 1):
            vector = (a >> 16 * lane) & 0xFFFF
            frozen = (b >> 16 * lane) & 0xFFFF
            kept = vector & (frozen ^ 0xFFFF)
            ordered = (sum(((kept >> POLAR_REV[k]) & 1) << k for k in range(16))
                       if reverse else kept)
            word = polar_zeta(ordered)
            conflict = int(vector & frozen != 0)
            result |= word << 16 * lane
            aux |= bin(word).count('1') << 5 * lane
            aux |= (16 - bin(frozen).count('1')) << (10 + 5 * lane)
            aux |= conflict << (20 + lane)
            fault |= conflict
        return result, aux | (reverse << 22), fault, state
    if name == 'comm_qam16_llr':
        if a >> 16 or b >> 3 or (b & 7) == 0 or c >> 3:
            return 0, 0, 1, state
        amp = b & 7
        gain = c & 7
        levels = (-3 * amp, -amp, amp, 3 * amp)
        result = aux = fault = 0
        closest = []
        for lane, value in enumerate((s_bits(a, 8), s_bits(a >> 8, 8))):
            distance = [abs(value - level) for level in levels]
            closest.append(min(distance))
            pairs = ((min(distance[0], distance[3]), min(distance[1], distance[2])),
                     (min(distance[0], distance[1]), min(distance[2], distance[3])))
            for bit, (zero_set, one_set) in enumerate(pairs):
                raw = one_set - zero_set
                scaled, saturated = qam_llr(raw, gain)
                index = 2 * lane + bit
                result |= (scaled & 0xFF) << 8 * index
                aux |= int(raw < 0) << index
                aux |= saturated << (11 + index)
                fault |= saturated
            aux |= min(range(4), key=lambda k: (distance[k], k)) << (4 + 2 * lane)
        over = int(abs(s_bits(a, 8)) > 7 * amp or abs(s_bits(a >> 8, 8)) > 7 * amp)
        aux |= gain << 8 | over << 15 | ((closest[0] + closest[1]) << 16) \
            | (amp << 25)
        return result, aux, fault | over, state
    if name == 'comm_viterbi_acs4':
        if a >> 12 or b >> 3 or (c >> 1) & 0x1FFFFFFF:
            return 0, 0, 1, state
        hard = (c >> 30) & 1
        y0, y1 = s_bits(a, 6), s_bits(a >> 6, 6)
        amp = b & 7
        if hard:
            dist = {(c0, c1): int((y0 < 0) != c0) + int((y1 < 0) != c1)
                    for c0 in (0, 1) for c1 in (0, 1)}
        else:
            level = {0: amp, 1: -amp}
            dist = {(c0, c1): abs(y0 - level[c0]) + abs(y1 - level[c1])
                    for c0 in (0, 1) for c1 in (0, 1)}
        if (c >> 31) & 1:
            pm, reach, offset = [0, VIT_CEIL, VIT_CEIL, VIT_CEIL], \
                [1, 0, 0, 0], 0
        else:
            pm = [(state >> 10 * k) & 0x3FF for k in range(4)]
            reach = [(state >> (40 + k)) & 1 for k in range(4)]
            offset = (state >> 44) & 0xFFF
        out = viterbi_section(pm, reach, dist, offset)
        aux = (sum(out['decision'][k] << k for k in range(4)) | (out['best'] << 4)
               | (out['count'] << 6) | (out['margin'] << 9) | (out['tie'] << 14)
               | (out['sat'] << 15) | (out['overflow'] << 16) | ((c >> 31) & 1) << 17
               | (out['offset'] << 18))
        result = sum(min(out['pm'][k], 255) << 8 * k for k in range(4))
        new_state = (out['offset'] << 44) | sum(out['reach'][k] << (40 + k)
                                                for k in range(4)) \
            | sum(out['pm'][k] << 10 * k for k in range(4))
        return result, aux, out['sat'] | out['overflow'], new_state
    raise ValueError(name)


# ------------------------------------------------------------------- vectors
def word(data):
    """Up to four frame bytes as a beat word: byte j becomes a[8j+7:8j]."""
    return int.from_bytes(data[:4], 'little'), len(data[:4])


def pack6(y0, y1):
    return (y0 & 0x3F) | ((y1 & 0x3F) << 6)


def encode(bits):
    """(7,5) octal encoder: the channel-bit pair transmitted at each symbol time.

    With input u and register bits u1, u2 the two channel bits are c0=u^u1^u2 and
    c1=u^u2, and the register shifts to u,u1, which is the trellis next state
    ns=u*2+u1 used by the accelerator.
    """
    out = []
    reg = 0
    for u in bits:
        u1, u2 = (reg >> 1) & 1, reg & 1
        out.append((u ^ u1 ^ u2, u ^ u2))
        reg = ((u << 1) | u1) & 3
    return out


def trellis(bits, amp=4, flips=()):
    """Received beat words for one (7,5) codeword; flips inverts those levels."""
    out = []
    for index, (c0, c1) in enumerate(encode(bits)):
        y0, y1 = -amp if c0 else amp, -amp if c1 else amp
        if (index, 0) in flips:
            y0 = -y0
        if (index, 1) in flips:
            y1 = -y1
        out.append(pack6(y0, y1))
    return out


def path_distance(guess, pairs, amp, flips=()):
    """Soft distance of one candidate input sequence, summed beat by beat.

    pairs[i][k] is the received polarity of channel bit k at beat i (flipped for
    the beats named in flips) and the candidate's own level is +A for a 0 and -A
    for a 1, so the total is the metric a maximum-likelihood decoder must minimise.
    """
    total = 0
    for index, (c0, c1) in enumerate(encode(guess)):
        y0 = -amp if pairs[index][0] else amp
        y1 = -amp if pairs[index][1] else amp
        if (index, 0) in flips:
            y0 = -y0
        if (index, 1) in flips:
            y1 = -y1
        total += abs(y0 - (amp if c0 == 0 else -amp)) \
            + abs(y1 - (amp if c1 == 0 else -amp))
    return total


def mlse(pairs, amp, flips=()):
    """Exhaustive maximum-likelihood sequence estimate over all input paths.

    Written as a brute-force enumeration of every 2**n input sequence with the
    section distances summed directly, so it shares no recurrence with the ACS
    model and no wiring with the RTL.
    """
    return min((path_distance(guess, pairs, amp, flips), guess)
               for guess in product((0, 1), repeat=len(pairs)))


def crc_is_malformed(c):
    return bool((c >> 3) & 0x7FFFFFF) or (c & 7) == 0 or (c & 7) > 4


def vectors(name, count=320):
    """Board set first: rows 0..127 are the hardware set and are built on purpose.

    Each sweep is a corner or published-value walk, then in-range random padding
    carries the variety. Random words outside the declared field widths would be
    almost all malformed beats, which collapse onto one response and stop
    discriminating, so pad() only ever emits control words the core accepts.
    """
    rows = []
    if name == 'comm_crc32_frame':
        rng = Random(0xCBC0CAB0)
        register = CRC32_INIT

        def emit(a, b, c):
            nonlocal register
            rows.append((a, b, c))
            if crc_is_malformed(c):
                return
            register = crc32_fold(b if (c >> 31) & 1 else register, c & 7, a)
            if (c >> 30) & 1:
                register = CRC32_INIT

        # The published check value, folded 4 + 4 + 1 bytes, then closed with its
        # own appended checksum: the residue test passes with fault=0.
        emit(0x34333231, CRC32_INIT, (1 << 31) | 4)
        emit(0x38373635, 0, 4)
        emit(0x39, 0, 1)
        assert register ^ MASK == 0xCBF43926
        emit(register ^ MASK, 0, (1 << 30) | 4)
        # A frame closed without its checksum violates the residue: fault=1.
        emit(0x39, CRC32_INIT, (1 << 31) | 1)
        emit(0, 0, (1 << 30) | 1)
        # Seed reload corners and the four byte counts.
        for seed in (0, 1, 2, 0x80000000, 0xFFFFFFFF, 0x0F0F0F0F, 0xA5A5A5A5,
                     0x00FF00FF):
            for size in (1, 2, 3, 4):
                emit(0x41424344, seed, (1 << 31) | size)
        # Malformed control words: byte count 0, above 4 and reserved bits set.
        rows += [(0, 0, 0), (0, 0, 5), (0, 0, 7), (0, 0, 1 << 29),
                 (1, 2, (1 << 31) | 4 | (1 << 3)), (1, 2, 4 | (1 << 20))]
        # Byte count ladder: 4 bytes a beat until aux[7:0] saturates at 255 and
        # aux[13] starts reporting the previous saturation.
        for _ in range(66):
            emit(rng.getrandbits(32), 0, 4)
        # Six well-formed frames, each closed on the residue.
        for _ in range(6):
            for _ in range(2):
                emit(rng.getrandbits(32), 0, 4)
            emit(register ^ MASK, 0, (1 << 30) | 4)
        while len(rows) < 128:
            emit(rng.getrandbits(32), 0, 1 + rng.randrange(4))
    elif name == 'comm_nrzi_fmr32':
        rng = Random(0xCE5E5E00)
        # Hand-derived corners: an all-ones channel decodes to a single data bit,
        # an alternating channel decodes to all ones, and the encoders mirror them.
        for source in (0x00000000, 0xFFFFFFFF, 0x55555555, 0xAAAAAAAA,
                       0x00000001, 0x80000000, 0x0F0F0F0F, 0xF0F0F0F0):
            rows.append((source, 0, (1 << 31)))
            rows.append((source, 0, (1 << 31) | (1 << 30)))
        # 24 exact encode/decode round trips, each pinned to a cleared reference.
        for _ in range(24):
            data = rng.getrandbits(32)
            rows.append((data, 0, (1 << 31) | (1 << 30)))
            rows.append((px32(data), 0, 1 << 31))
        # A transition-free stream: the carried run grows until it saturates.
        for _ in range(12):
            rows.append((0, 0, 1 << 31 if len(rows) % 12 == 0 else 0))
        # Density, minimum-density and transition-gap alarms.
        for density, limit in ((32, 31), (32, 16), (1, 2), (0, 1)):
            value = (1 << density) - 1 if density < 32 else MASK
            rows.append((value, limit | (0 << 6), 1 << 31))
            rows.append((value, (0 if density > 2 else limit << 6), 1 << 31))
        for gap in (1, 4, 17, 64, 200):
            rows.append((1 << (gap % 31), gap << 12, (1 << 31) | (1 << 30)))
            rows.append((0, gap << 12, 0))
            rows.append((0, gap << 12, 0))
        # Streaming beats with a carried reference and a live density meter.
        for _ in range(30):
            rows.append((rng.getrandbits(32), rng.randrange(1 << 20),
                         rng.randrange(2) << 30))
        # Malformed control words: reserved c bits and reserved b bits.
        rows += [(1, 0, 2), (1, 0, 1 << 29), (1, 1 << 20, 0), (1, 0, (1 << 31) | 2)]
        # The transitions-since-restart counter saturating at 255.
        for _ in range(14):
            rows.append((MASK, 0, 1 << 31 if len(rows) % 14 == 0 else 0))
    elif name == 'comm_pattern_lock32':
        rng = Random(0xA11CE000)
        fas = 0xF6F6F6FA
        thr = 2 | (2 << 4)
        # A load beat installs the pattern and empties the window, so the marker
        # can only be found in this beat's own half: this one misses, and the
        # distance field still reports how far the loaded pattern is from it.
        rows.append((fas >> 1, fas, (1 << 31) | thr))
        # Every one of the 32 byte-boundary offsets: prime the window, then place
        # the marker so it straddles the beat boundary at exactly that phase.
        for offset in range(1, 32):
            rows.append(((fas << offset) & MASK, 0, thr))
            rows.append((fas >> (32 - offset), 0, thr))
        # Position 32 (whole marker inside this beat) and position 0 (inside the
        # carried window) come from two consecutive marker beats.
        rows.append((fas, 0, thr))
        rows.append((fas, 0, thr))
        # Marker distance ladder at tolerance 15: the near-miss flag walks across
        # its on/off boundary and aux[31:26] counts the differing bits exactly.
        rows.append((fas, fas, (1 << 31) | thr | (15 << 8)))
        for weight in range(1, 33):
            rows.append((fas ^ ((1 << weight) - 1), 0, thr | (15 << 8)))
        # The same ladder with the check disabled: distance still reported, but
        # never a fault, so the two tolerances must not be confused.
        rows.append((fas, fas, (1 << 31) | thr))
        for weight in range(1, 17):
            rows.append((fas ^ ((1 << weight) - 1), 0, thr))
        # Matching-beat ladder: the counter runs to its 4-bit saturation.
        for _ in range(15):
            rows.append((fas, 0, thr))
        # Non-matching ladder until frame is lost, then to counter saturation.
        for _ in range(17):
            rows.append((rng.getrandbits(32), 0, thr))
        # A self-synchronising pattern gives a run of positions in one beat: the
        # 8-periodic marker matches at 0, 8, 16, 24 and 32 together.
        rows.append((0, 0, (1 << 31) | thr))
        rows.append((0xF6F6F6F6, 0xF6F6F6F6, (1 << 31) | thr))
        rows.append((0xF6F6F6F6, 0, thr))
        # All-ones pattern: contiguous run of matching positions, so a sliding
        # edge shows up as a growing bitmap rather than a single bit.
        for high, low in ((32, 32), (24, 16), (16, 24), (28, 28), (8, 12),
                          (31, 31), (12, 20), (20, 12), (16, 16), (2, 6)):
            rows.append((0, 0xFFFFFFFF, (1 << 31) | thr))
            rows.append(((MASK << (32 - high)) & MASK, 0, thr))
            rows.append(((1 << low) - 1, 0, thr))
        # Slow lock and slow loss thresholds stretch the FSM over more beats.
        for thresholds in ((3, 2), (5, 3), (7, 5), (9, 7), (12, 8), (15, 15)):
            c = thresholds[0] | (thresholds[1] << 4)
            rows.append((fas, fas, (1 << 31) | c))
            for _ in range(thresholds[0] + 1):
                rows.append((fas, 0, c))
            for _ in range(thresholds[1] + 1):
                rows.append((rng.getrandbits(32), 0, c))
        # Malformed control words: a zero lock threshold, a zero loss threshold,
        # both zero and three reserved-bit settings.
        rows += [(fas, fas, 0), (fas, fas, 1 << 4), (fas, fas, 2),
                 (fas, fas, 1 << 12), (fas, fas, 1 << 30),
                 (fas, fas, (1 << 31) | (1 << 19))]
        while len(rows) < 128:
            offset = rng.randrange(1, 32)
            rows.append(((fas << offset) & MASK, 0, thr))
            rows.append((fas >> (32 - offset), 0, thr))
    elif name == 'comm_polar_enc16':
        rng = Random(0xC0FFEE00)
        # One input bit set per lane: the codeword is exactly that channel column,
        # so input 0 repeats into all sixteen outputs and input 15 is the identity.
        for index in range(16):
            rows.append((1 << index, 0, 0))
            rows.append((1 << (16 + index), 0, 0))
            rows.append((1 << index, 0, 1 << 31))
        # Freeze maps: one frozen position per beat against an all-ones vector, so
        # the conflict flag and the information-position count both walk.
        for index in range(16):
            rows.append((MASK, 1 << index, 0))
            rows.append((0, (1 << index) | (1 << (16 + index)), 0))
        # Two-bit inputs exercise the subset structure across the kernel.
        for low, high in ((0, 1), (0, 15), (3, 12), (5, 10), (7, 8), (1, 2),
                          (4, 6), (9, 14), (11, 13), (2, 3)):
            rows.append(((1 << low) | (1 << high), 0, 0))
            rows.append(((1 << low) | (1 << high), 0, 1 << 31))
            rows.append((MASK, (1 << low) | (1 << high), 0))
        # Lane 1 alone and both lanes with mismatched freeze maps.
        for _ in range(20):
            rows.append((rng.getrandbits(32), rng.getrandbits(32), 0))
        for value in (0, 1, 0x5555, 0xAAAA, 0xFFFF):
            rows.append((value, value, 0))
            rows.append((value << 16, value << 16, 1 << 31))
        # Malformed control words: only bit 0 and bit 31 are legal.
        rows += [(0, 0, 2), (0, 0, 1 << 20), (1, 1, 1 << 30), (1, 1, (1 << 31) | 2)]
        while len(rows) < 128:
            rows.append((rng.getrandbits(32), rng.getrandbits(32),
                         (1 << 31) if rng.randrange(3) == 0 else 0))
    elif name == 'comm_qam16_llr':
        rng = Random(0x9ABE5000)
        corners = (-128, -127, -65, -64, -8, -7, -6, -1, 0, 1, 6, 7, 8, 21, 20,
                   63, 64, 127)
        # Exact constellation points and exact midpoints for every spacing: the
        # LLR pair is then (+-2S, 0) or (0, +-2S), and the hard bits must match.
        for amp in (1, 2, 4, 7):
            for level in (-3 * amp, -amp, amp, 3 * amp):
                rows.append((pack6(level, level), amp, 0))
                rows.append((pack6(level, 0), amp, 1))
                rows.append((pack6(0, level), amp, 2))
                rows.append((pack6(level * 2 + 1, 0), amp, 7))
            for half in (-2 * amp, 0, 2 * amp):
                rows.append((pack6(half, half), amp, 3))
                rows.append((pack6(half, -half), amp, 4))
        # Axis sweeps at six gains, including the two hardest corners.
        for value in corners:
            for amp, gain in ((1, 0), (4, 0), (7, 0), (4, 3), (7, 7), (2, 5)):
                rows.append((pack6(value, -value), amp, gain))
                rows.append((pack6(value, value), amp, gain))
        # Over-range alarm: |coordinate| above 7S with S at both extremes.
        for amp in (1, 3, 7):
            for value in (-128, -7 * amp - 1, 7 * amp, 7 * amp + 1, 127):
                rows.append((pack6(value, 0), amp, 0))
        # Saturated LLRs: a large gain with the widest axis separation, so the
        # signed byte cannot hold 2S * 2^gain.
        for value in (-128, -96, -32, 32, 96, 127):
            rows.append((pack6(value, -value), 7, 5))
            rows.append((pack6(value, value), 7, 7))
        # Malformed control words: reserved a, b and c bits, and S = 0.
        rows += [(1 << 16, 1, 0), (0, 1 << 3, 0), (0, 0, 0), (0, 8, 0),
                 (0, 1, 1 << 3), (0, 1, 1 << 31), (1 << 31, 1, 0)]
        while len(rows) < 128:
            rows.append((pack6(rng.randrange(-128, 128), rng.randrange(-128, 128)),
                         rng.randrange(1, 8), rng.randrange(8)))
    elif name == 'comm_viterbi_acs4':
        rng = Random(0x1E5E1000)
        # Malformed beats: reserved a, b and c bits, and a reserved c bit set
        # together with a restart. Each returns result=aux=0 and leaves the
        # trellis exactly as it was, so the walk below starts from the reset state.
        rows += [(1 << 12, 1, 0), (0, 1 << 3, 0), (0, 1, 2), (0, 1, 1 << 29),
                 (1, 1, (1 << 31) | (1 << 30) | 4)]
        # Offset overflow walk: restart, then the worst-case symbol pair at A=1.
        # The section floor is 61 every beat, so the accumulated 12-bit offset
        # passes 4095 after 67 beats, and aux[16] and fault stay raised from there.
        rows.append((pack6(-32, 31), 1, 1 << 31))
        for _ in range(34):
            rows.append((pack6(-32, 31), 1, 0))
            rows.append((pack6(31, -32), 1, 0))
        # AGC trellis run: one (7,5) codeword received with the amplitude cycling
        # 1..7, three levels inverted, a hard-decision beat every seventh (metrics
        # become disagreement counts, A is irrelevant and ACS pairs tie) and a
        # trellis restart every ninth, so the metrics, decisions, margins and the
        # reachable-state count all walk over the same 56 beats.
        bits = [rng.randrange(2) for _ in range(56)]
        pairs = encode(bits)
        flips = {(3, 0), (17, 1), (29, 0)}
        for index in range(56):
            amp = 1 + index % 7
            y0, y1 = pairs[index]
            y0, y1 = (-amp if y0 else amp), (-amp if y1 else amp)
            if (index, 0) in flips:
                y0 = -y0
            if (index, 1) in flips:
                y1 = -y1
            rows.append((pack6(y0, y1), amp,
                         (1 << 31) if index % 9 == 0
                         else (1 << 30) if index % 7 == 3 else 0))
        # Random symbols with each amplitude, exercising the soft metric range.
        for amp in range(8):
            for _ in range(6):
                rows.append((pack6(rng.randrange(-32, 32), rng.randrange(-32, 32)),
                             amp, (1 << 31) if amp == 0 else 0))
        # Degenerate amplitudes: A=0 makes every branch the same distance.
        rows += [(pack6(-32, 31), 0, 1 << 31), (pack6(31, -32), 0, 0),
                 (pack6(0, 0), 7, 1 << 31), (pack6(0, 0), 7, 0)]
        while len(rows) < 128:
            rows.append((pack6(rng.randrange(-32, 32), rng.randrange(-32, 32)),
                         rng.randrange(1, 8),
                         rng.randrange(4) << 30 if rng.randrange(8) else 1 << 31))
    else:
        raise ValueError(name)
    rng = Random(0xC041C0DE + sum(name.encode()))
    while len(rows) < count:
        rows.append(pad(name, rng))
    return rows[:count]


def pad(name, rng):
    """One in-range random beat, so padding keeps discriminating."""
    if name == 'comm_crc32_frame':
        mode = rng.randrange(8)
        c = rng.randrange(1, 5)
        if mode == 0:
            c |= 1 << 31
        elif mode == 1:
            c |= 1 << 30
        return (rng.getrandbits(32),
                CRC32_INIT if mode == 0 else rng.getrandbits(32) if mode < 3 else 0,
                c)
    if name == 'comm_nrzi_fmr32':
        c = (rng.randrange(2) << 30) | ((1 << 31) if rng.randrange(6) == 0 else 0)
        b = 0
        if rng.randrange(3) == 0:
            b = rng.randrange(64) | (rng.randrange(64) << 6) | (rng.randrange(256) << 12)
        return rng.getrandbits(32), b, c
    if name == 'comm_pattern_lock32':
        c = (rng.randrange(1, 16) | (rng.randrange(1, 16) << 4)
             | (rng.randrange(16) << 8))
        pattern = rng.getrandbits(32)
        if rng.randrange(5) == 0:
            c |= 1 << 31
            slip = rng.getrandbits(32) & ((1 << rng.randrange(6)) - 1)
            return pattern ^ slip, pattern, c
        return rng.getrandbits(32), pattern, c
    if name == 'comm_polar_enc16':
        return (rng.getrandbits(32), rng.getrandbits(32),
                (1 << 31) if rng.randrange(4) == 0 else 0)
    if name == 'comm_qam16_llr':
        return (pack6(rng.randrange(-128, 128), rng.randrange(-128, 128)),
                rng.randrange(1, 8), rng.randrange(8))
    if name == 'comm_viterbi_acs4':
        c = ((1 << 30) if rng.randrange(3) == 0 else 0) \
            | ((1 << 31) if rng.randrange(12) == 0 else 0)
        return (pack6(rng.randrange(-32, 32), rng.randrange(-32, 32)),
                rng.randrange(1, 8), c)
    raise ValueError(name)


# --------------------------------------------------------------------- selftest
def selftest():
    """Reference checks pinned to published constants and hand-run traces.

    Every expected value below is written on purpose -- the published CRC-32 check
    value and residue, the (7,5) octal code and its free distance, the polar
    kernel's repetition and parity channels, 16-QAM Gray boundary geometry -- and
    each core is additionally held against a second algorithm that shares no code
    with step(): zlib's CRC-32, a serial differential loop, a submask enumeration,
    an exhaustive 16-point min-sum and an exhaustive MLSE search.
    """
    checks = 0

    def check(ok, what):
        nonlocal checks
        assert ok, 'selftest failed: ' + what
        checks += 1

    def u8(value, bit):
        return (value >> bit) & 1

    def field(value, start, width):
        return (value >> start) & ((1 << width) - 1)

    def weight(value):
        return bin(value).count('1')

    def gray(index):
        return index ^ (index >> 1)

    # ---------------------------------------------------------------- contract
    check(FAMILY == 'comm' and len(CORES) == 6, 'family comm has exactly six cores')
    check(len({entry['name'] for entry in CORES}) == 6
          and all(entry['name'].startswith('comm_')
                  and entry['family'] == FAMILY for entry in CORES),
          'every core is a uniquely named comm_* member of this family')
    for entry in CORES:
        check(entry.get('latency', 1) == 1 and 'module=' not in entry['body']
              and 'posedge' not in entry['body'] and '@' not in entry['body'],
              '%s answers in one enabled edge with II 1' % entry['name'])
        code = '\n'.join(line.split('//', 1)[0]
                         for line in (entry['body'] + entry['decl']).splitlines())
        check(not any(op in code for op in ('*', '/')),
              '%s needs no multiplier and no divider' % entry['name'])
        check(entry['lanes'] >= 2, '%s retires several lanes per accepted beat'
              % entry['name'])
    checks += 1
    check(sorted(entry['name'] for entry in CORES if entry['stateful']) ==
          ['comm_crc32_frame', 'comm_nrzi_fmr32', 'comm_pattern_lock32',
           'comm_viterbi_acs4'], 'exactly four comm cores keep state')
    check(not any(entry['faultless'] for entry in CORES),
          'every comm core can report a fault')

    # ------------------------------------------------------- 1  crc32 frame
    name = 'comm_crc32_frame'
    check(CRC32_POLY == 0xEDB88320 and CRC32_INIT == 0xFFFFFFFF
          and CRC32_RESIDUE == 0xDEBB20E3,
          'the published CRC-32/ISO-HDLC reflected polynomial, seed and residue')
    r, x, f, state = step(name, 0x34333231, CRC32_INIT, (1 << 31) | 4)
    check((r, f, state & MASK) == (0x9BE3E0A3, 0, 0x641C1F5C),
          'CRC-32 of "1234" from the 0xFFFFFFFF seed is zlib 0x9BE3E0A3')
    r, x, f, state = step(name, 0x38373635, 0, 4, state)
    check((r, f, state & MASK) == (0x9AE0DAAF, 0, 0x651F2550),
          'the frame continued with "5678" gives zlib 0x9AE0DAAF')
    r, x, f, state = step(name, 0x39, 0, 1, state)
    check((r, f) == (0xCBF43926, 0),
          'CRC-32/ISO-HDLC check value of "123456789" is 0xCBF43926')
    check(state >> 32 == 9 and field(x, 8, 3) == 1 and field(x, 0, 8) == 9,
          'nine payload bytes are counted and this beat folded one')
    checks += 1
    # Closing on the residue: all four appended checksum bytes are part of the
    # frame, so the closing beat has to carry the whole checksum, not one byte.
    r, x, f, state = step(name, r, 0, (1 << 30) | 4, state)
    check((r, f, state) == (CRC32_RESIDUE ^ MASK, 0, CRC32_INIT) and x & 0xFF == 0
          and field(x, 8, 3) == 4 and u8(x, 12) == 1,
          'a frame closed with its own checksum leaves the 0xDEBB20E3 residue '
          'and reloads the seed')
    checks += 1
    for tail in (1, 2, 3, 4):
        _, _, _, state = step(name, 0x34333231, CRC32_INIT, (1 << 31) | 4)
        _, _, _, state = step(name, 0x38373635, 0, 4, state)
        _, _, _, state = step(name, 0x39, 0, 1, state)
        for index in range(4 - tail):
            _, _, _, state = step(name, (0xCBF43926 >> (8 * index)) & 0xFF, 0, 1,
                                  state)
        beat = sum(((0xCBF43926 >> (8 * (4 - tail + k))) & 0xFF) << (8 * k)
                   for k in range(tail))
        r, x, f, state = step(name, beat, 0, (1 << 30) | tail, state)
        check((r, f, state) == (CRC32_RESIDUE ^ MASK, 0, CRC32_INIT),
              'the residue test is independent of the checksum beat split')
    checks += 1
    # A frame closed without carrying its checksum cannot leave the residue.
    _, _, _, state = step(name, 0x34333231, CRC32_INIT, (1 << 31) | 4)
    _, _, _, state = step(name, 0x38373635, 0, 4, state)
    _, _, _, state = step(name, 0x39, 0, 1, state)
    r, x, f, state = step(name, 0, 0, (1 << 30) | 1, state)
    check((r, f, u8(x, 12)) == (zlib.crc32(b'123456789\x00'), 1, 1),
          'closing a frame on a padding byte instead of its checksum faults it')
    check(state == CRC32_INIT, 'a closing beat reloads the seed even when it fails')
    checks += 1
    # Two more published one-shot values.
    r, x, f, state = step(name, 0, CRC32_INIT, (1 << 31) | 1)
    check((r, f) == (0xD202EF8D, 0), 'CRC-32 of one 0x00 byte is 0xD202EF8D')
    fox = b'The quick brown fox jumps over the lazy dog'
    r, x, f, state = step(name, int.from_bytes(fox[:4], 'little'), CRC32_INIT,
                          (1 << 31) | 4)
    for index in range(4, len(fox), 4):
        chunk = fox[index:index + 4]
        r, x, f, state = step(name, int.from_bytes(chunk, 'little'), 0, len(chunk),
                              state)
    check((r, f, x & 0xFF) == (0x414FA339, 0, 43),
          'CRC-32 of the 43-byte fox string is 0x414FA339')
    checks += 1
    # Length and split independence, then a beat-by-beat cross-check against zlib.
    frame = int.from_bytes(b'123456789', 'little')
    for sizes in ((4, 4, 1), (1, 1, 1, 1, 4, 1), (2, 2, 2, 2, 1), (3, 2, 4)):
        register = CRC32_INIT
        offset = 0
        for k in sizes:
            register = crc32_fold(register, k, frame >> (8 * offset))
            offset += k
        check(offset == 9 and register ^ MASK == 0xCBF43926,
              'the check value is independent of how the frame is split')
    checks += 1
    stream = bytes(range(0x30, 0x40))
    stream += (zlib.crc32(stream) & MASK).to_bytes(4, 'little')
    rng = Random(0x5EED5EED)
    left, sizes = len(stream), []
    while left:
        k = min(left, rng.choice((1, 2, 3, 4)))
        sizes.append(k)
        left -= k
    state = 0
    offset = 0
    for index, k in enumerate(sizes):
        closing = index + 1 == len(sizes)
        c = ((1 << 31) if index == 0 else 0) | ((1 << 30) if closing else 0) | k
        r, x, f, state = step(name, int.from_bytes(stream[offset:offset + k],
                                                   'little'),
                              CRC32_INIT if index == 0 else 0, c, state)
        offset += k
        check(r == zlib.crc32(stream[:offset], 0) and f == 0,
              'CRC beat %d of a %s-byte split matches zlib exactly' % (index, sizes))
        if not closing:
            check(x & 0xFF == offset and state >> 32 == offset,
                  'the byte counter tracks the frame length through zlib beats')
    check(r == CRC32_RESIDUE ^ MASK and x & 0xFF == 0 and state == CRC32_INIT,
          'the zlib-checked stream closes on the residue and reloads the seed')
    checks += 1
    # The payload counter saturates at 255 and then reports the prior saturation.
    state = 0
    for _ in range(255):
        r, x, f, state = step(name, 0, 0, 1, state)
    check(x & 0xFF == 255 and u8(x, 13) == 0 and f == 0,
          'the payload byte counter saturates at 255')
    r, x, f, state = step(name, 0, 0, 1, state)
    check(x & 0xFF == 255 and u8(x, 13) == 1,
          'a saturated counter keeps saturating and flags the previous beat')
    checks += 1
    _, _, _, state = step(name, 0x31, CRC32_INIT, (1 << 31) | 3)
    held = state
    for bad in (0, 5, 7, 1 << 29, (1 << 31) | 8, (1 << 20) | 4):
        r, x, f, state = step(name, 0x1234, 0x99, bad, held)
        check((r, x, f, state) == (0, 0, 1, held),
              'a malformed CRC beat returns nothing and leaves the register held')
    checks += 1

    # ---------------------------------------------------- 2  nrzi / fm line code
    name = 'comm_nrzi_fmr32'
    corners = ((0xAAAAAAAA, 0xFFFFFFFE, 0x1F00401F, 0x1F000001),
               (0x55555555, 0xFFFFFFFF, 0x20000020, 0x20000000),
               (0xFFFFFFFF, 0x00000001, 0x010007C1, 0x0100003F),
               (0x00000001, 0x00000003, 0x02000782, 0x0200003C),
               (0x80000000, 0x80000000, 0x0107C001, 0x01000001),
               (0x00000000, 0x00000000, 0x00480800, 0x00000040))
    for channel, data, aux, state_want in corners:
        r, x, f, state = step(name, channel, 0, 1 << 31)
        check((r, x, f) == (data, aux, 0),
              'NRZI decode of channel %s is data %s with run telemetry %s'
              % (hexs(channel), hexs(data), hexs(aux)))
        check(state == (state_want & 0xFF000000)
              | (field(aux, 6, 8) << 1) | ((channel >> 31) & 1),
              'the reference level, carried run and transition total pack into state')
    checks += 1
    check(u8(0x00480800, 22) == 1 and u8(0x1F00401F, 22) == 0,
          'only a transition-free beat sets the no-transition flag')
    # Encoding is the inverse of decoding, with and without a carried reference.
    rng = Random(0x49E5ED00)
    for _ in range(8):
        data = rng.getrandbits(32)
        r, x, f, state = step(name, data, 0, (1 << 31) | (1 << 30))
        check(r == px32(data) and x & 0x3F == weight(data) and f == 0,
              'NRZI encode of %s is its prefix XOR' % hexs(data))
        back, _, _, state = step(name, r, 0, 1 << 31)
        check(back == data, 'decoding the encoded word returns the data')
    checks += 1
    for _ in range(8):
        channel = rng.getrandbits(32)
        data, _, _, state = step(name, channel, 0, 1 << 31)
        back, x, _, _ = step(name, data, 0, (1 << 30) | (1 << 31))
        check(back == channel and x & 0x3F == weight(data),
              're-encoding the recovered data rebuilds the channel word')
    checks += 1
    # The carried level is the whole difference at bit 0.
    _, _, _, state = step(name, 0, 0, 1 << 31)
    r, x, f, _ = step(name, MASK, 0, 0)
    check((r, x & 0x3F) == (0x00000001, 1),
          'an all-ones channel decoded from a low carried level is one transition')
    _, _, _, state = step(name, 1, 0, (1 << 31) | (1 << 30))
    r, x, f, state = step(name, MASK, 0, 0, state)
    check((r, x & 0x3F, state & 1) == (0, 0, 1),
          'the same channel from a high carried level is transition-free')
    checks += 1
    # Run ladder: one idle beat grows the transition-free run by 32, saturating.
    state = 0
    ladder = []
    for _ in range(9):
        r, x, f, state = step(name, 0, 0, 0, state)
        ladder.append((field(x, 6, 8), field(x, 14, 8), f))
    check(ladder[0] == (32, 32, 0) and ladder[2] == (96, 96, 0)
          and ladder[6] == (224, 224, 0) and ladder[7] == (255, 255, 0)
          and ladder[8] == (255, 255, 0) and not any(row[2] for row in ladder),
          'the transition-free run grows by 32 per beat and saturates at 255')
    checks += 1
    r, x, f, state = step(name, 1 << 20, 5 << 12, 0, state)
    check(f == 1 and u8(x, 23) == 1 and r == 0x00300000
          and field(x, 14, 8) == 255 and field(x, 6, 8) == 10,
          'a 255-bit carried run ending inside this beat alarms a 5-bit gap limit')
    r, x, f, _ = step(name, 1 << 8, 31 << 12, 1 << 31)
    check(f == 0 and field(x, 14, 8) == 8 and field(x, 6, 8) == 22,
          'after a restart the run that ends at the first transition is the leading '
          'zero count, not the trailing one')
    checks += 1
    # A data-free beat keeps whatever level the last beat left behind.
    _, _, _, state = step(name, 0, 0, 1 << 31)
    r, x, f, state = step(name, 0, 0, 1 << 30, state)
    check((r, f) == (0, 0), 'no transition after a level of 0 holds the line low')
    r, _, _, state = step(name, 1, 0, (1 << 31) | (1 << 30))
    check(r == MASK, 'a single data bit drives the level to one')
    r, x, f, _ = step(name, 0, 0, 1 << 30, state)
    check(r == MASK and x & 0x3F == 0,
          'the same data-free beat holds a carried level of one instead')
    checks += 1
    # Density alarms and the disabled checks.
    r, x, f, _ = step(name, MASK, 31, (1 << 31) | (1 << 30))
    check((f, u8(x, 23), x & 0x3F) == (1, 1, 32),
          'thirty-two transitions over a 31-transition density limit alarms')
    r, x, f, _ = step(name, MASK, 1 | (40 << 6), 1 << 31)
    check(f == 1, 'a minimum density above 32 can never be met and always alarms')
    r, x, f, _ = step(name, 0, 3 << 12, 1 << 31)
    check((f, u8(x, 23), x & 0x3F) == (1, 1, 0),
          'an idle beat alarms against a 3-bit transition gap')
    r, x, f, _ = step(name, 0, 0, 1 << 31)
    check(f == 0, 'a limit of zero disables the check it belongs to')
    # The transitions-since-restart counter saturates at 255. An encode beat of
    # 0x55555555 contributes 16 transitions, so 17 beats would count 272.
    state = 0
    for index in range(17):
        r, x, f, state = step(name, 0x55555555, 0,
                              (1 << 30) | (1 << 31 if index == 0 else 0), state)
    check(x >> 24 == 255 and x & 0x3F == 16 and f == 0,
          'the transition total since restart saturates at 255')
    checks += 1
    held = state
    for bad in (2, 1 << 29, 1 << 20, (1 << 31) | 2):
        r, x, f, state = step(name, 1, 1 << 20 if bad == 1 << 20 else 0, bad, held)
        check((r, x, f, state) == (0, 0, 1, held),
              'a malformed line-code beat leaves the watchdog state untouched')
    checks += 1

    # ------------------------------------------------------ 3  bit sync hunter
    name = 'comm_pattern_lock32'
    fas = 0xF6F6F6FA                 # G.709 frame alignment signal
    thr = 2 | (2 << 4)               # beats with a match to lock, without to lose

    def phases(window, marker):
        """Plain bit loop: every phase of the 64-bit window that holds the marker."""
        bits = [(window >> k) & 1 for k in range(64)]
        want = [(marker >> k) & 1 for k in range(32)]
        return [p for p in range(33) if bits[p:p + 32] == want]

    def shown(window, marker):
        """One window's report: bitmap, aux[0], aux[1], count, newest phase."""
        hits = phases(window, marker)
        return (sum(1 << p for p in hits if p < 32), 1 if 32 in hits else 0,
                1 if hits else 0, min(len(hits), 31), max(hits) if hits else 0)
    result, aux, fault, loaded = step(name, 0, fas, (1 << 31) | thr)
    check(u8(aux, 6) == 1 and result == 0 and fault == 0 and u8(aux, 1) == 0
          and field(aux, 26, 6) == weight(fas),
          'a load beat installs the marker, empties the window, still correlates')
    for phase in range(1, 32):
        head, tail = (fas << phase) & MASK, fas >> (32 - phase)
        _, _, _, primed = step(name, head, 0, thr, loaded)
        result, aux, fault, _ = step(name, tail, 0, thr, primed)
        want = shown((tail << 32) | head, fas)
        check(result == want[0] and u8(result, phase) == 1 and want[2] == 1
              and (u8(aux, 0), u8(aux, 1), field(aux, 21, 5), field(aux, 15, 6))
              == want[1:5] and fault == 0,
              'marker split across the beat boundary sits at window phase %d' % phase)
    checks += 1
    result, aux, fault, primed = step(name, fas, 0, thr, loaded)
    check((result, u8(aux, 0), u8(aux, 1), field(aux, 21, 5), field(aux, 15, 6))
          == shown(fas << 32, fas) == (0, 1, 1, 1, 32),
          'a marker wholly inside one beat is phase 32, absent from the bitmap')
    result, aux, fault, locked = step(name, fas, 0, thr, primed)
    check(result == 1 and (u8(aux, 0), field(aux, 15, 6), field(aux, 21, 5))
          == (1, 32, 2)
          and (u8(aux, 1), u8(aux, 2), u8(aux, 3), fault) == (1, 1, 1, 0),
          'two marker beats hold the marker at both window ends and declare lock')
    state = locked               # the hunter's own counters, read back from state
    matched = field(state, 64, 4)
    missed = field(state, 68, 4)
    held = field(state, 72, 1)
    for index in range(6):
        beat = fas if index < 2 else 0
        window = (beat << 32) | (state & MASK)
        hit = bool(phases(window, fas))
        result, aux, fault, state = step(name, beat, 0, thr, state)
        matched, missed = (min(matched + 1, 15), 0) if hit \
            else (0, min(missed + 1, 15))
        was, held = held, 1 if hit and matched >= (thr & 15) else \
            (0 if not hit and missed >= ((thr >> 4) & 15) else held)
        check(result == shown(window, fas)[0] and field(aux, 7, 4) == matched
              and field(aux, 11, 4) == missed and u8(aux, 2) == held
              and u8(aux, 3) == int(held and not was)
              and u8(aux, 4) == fault == int(was and not held),
              'hunter beat %d: %d matched beats, %d non-matched, lock %d'
              % (index, matched, missed, held))
    checks += 1
    for tolerance in (15, 0):
        control = thr | (tolerance << 8)
        for distance in range(1, 33):
            _, _, _, primed = step(name, 0, fas, (1 << 31) | control)
            word = fas ^ ((1 << distance) - 1)
            result, aux, fault, _ = step(name, word, 0, control, primed)
            check(field(aux, 26, 6) == distance and result == 0 and u8(aux, 1) == 0
                  and u8(aux, 5) == int(distance <= tolerance)
                  and fault == u8(aux, 5),
                  'a %d-bit slip off the marker is a near miss only within %d'
                  % (distance, tolerance))
    checks += 1
    _, _, _, ones = step(name, 0, MASK, (1 << 31) | thr)
    for low in (0, 1, 29, 30, 31):
        _, _, _, primed = step(name, MASK, 0, thr, ones)
        result, aux, fault, _ = step(name, (1 << low) - 1, 0, thr, primed)
        window = (((1 << low) - 1) << 32) | MASK
        check(phases(window, MASK) == list(range(low + 1))
              and result == shown(window, MASK)[0] == (1 << (low + 1)) - 1
              and field(aux, 21, 5) == min(low + 1, 31)
              and (field(aux, 15, 6), u8(aux, 0), u8(aux, 1)) == (low, 0, 1),
              'an all-ones marker matches %d phases, capped at 31' % (low + 1))
    checks += 1
    _, _, _, held = step(name, fas, 0, thr, loaded)
    for bad in (0, 1 << 4, 1 << 12, 1 << 30, (1 << 31) | (1 << 19)):
        result, aux, fault, state = step(name, fas, fas, bad, held)
        check((result, aux, fault, state) == (0, 0, 1, held),
              'a malformed hunter beat reports nothing and holds the window')
    checks += 1

    # --------------------------------------------------------- 4  polar encoder
    name = 'comm_polar_enc16'

    def polar16(vector):
        """G16 = F^x4 as the spec states it: x[i] XORs every surviving u[j] whose
        set bits are a subset of i, enumerated per output rather than per stage."""
        return sum((sum((vector >> j) & 1 for j in range(16)
                        if (j & ~i) == 0) & 1) << i for i in range(16))

    def rev4(vector):
        """Index bit reversal over the four kernel stages."""
        return sum(((vector >> int(format(k, '04b')[::-1], 2)) & 1) << k
                   for k in range(16))
    walk = Random(0x5EEDF00D)
    check(polar16(1) == 0xFFFF and polar16(1 << 15) == 1 << 15 and polar16(0) == 0
          and all(polar16(polar16(v)) == v for v in range(256)),
          'G16 column 0 is the repetition channel, row 15 the parity, row 0 the '
          'identity and the kernel is its own inverse')
    for lane in (0, 1):
        result, aux, fault, state = step(name, 1 << (16 * lane), 0, 0)
        check((result, fault, state) == (0xFFFF << 16 * lane, 0, 0)
              and field(aux, 5 * lane, 5) == 16,
              'input 0 of lane %d repeats into every one of the sixteen outputs'
              % lane)
        result, _, _, _ = step(name, 1 << (15 + 16 * lane), 0, 0)
        check(field(result, 16 * lane, 16) == 1 << 15,
              'input 15 of lane %d is the identity channel' % lane)
    checks += 1
    for _ in range(12):
        vector, frozen = walk.getrandbits(32), walk.getrandbits(32)
        reverse = walk.randrange(2)
        result, aux, fault, state = step(name, vector, frozen, reverse << 31)
        for lane in (0, 1):
            source = (vector >> 16 * lane) & 0xFFFF
            map_bits = (frozen >> 16 * lane) & 0xFFFF
            kept = source & (map_bits ^ 0xFFFF)
            word = polar16(rev4(kept)) if reverse else polar16(kept)
            check(field(result, 16 * lane, 16) == word
                  and (word >> 15) & 1 == weight(kept) & 1
                  and word & 1 == kept & 1
                  and field(aux, 5 * lane, 5) == weight(word)
                  and field(aux, 10 + 5 * lane, 5) == 16 - weight(map_bits)
                  and u8(aux, 20 + lane) == int(bool(source & map_bits))
                  and fault == int(bool(vector & frozen)) and u8(aux, 22) == reverse
                  and field(aux, 23, 9) == 0 and state == 0,
                  'polar lane %d encodes %s under freeze map %s'
                  % (lane, hexs(source, 4), hexs(map_bits, 4)))
    checks += 1
    for index in range(16):
        result, aux, fault, state = step(name, 1 << index, 1 << index, 0)
        lane = index >> 4
        check(result == 0 and fault == 1 and state == 0
              and u8(aux, 20 + lane) == 1 and field(aux, 5 * lane, 5) == 0
              and field(aux, 10 + 5 * lane, 5) == 15,
              'a frozen position carrying 1 is forced to 0 and counted out')
    checks += 1
    plain, turned = (step(name, 1 << 1, 1 << 8, bit << 31) for bit in (0, 1))
    check(plain[0] == polar16(1 << 1) and turned[0] == polar16(rev4(1 << 1))
          and plain[2] == turned[2] == plain[3] == turned[3] == 0
          and u8(turned[1], 22) == 1,
          'c[31] reverses the input index while the freeze map stays pre-reversal')
    checks += 1
    for _ in range(8):
        vector = walk.getrandbits(16)
        result, _, _, _ = step(name, vector, 0, 0)
        back, _, _, state = step(name, result & 0xFFFF, 0, 0)
        check(back == vector and state == 0,
              'two beats of the kernel undo each other, so G16 is its own inverse')
    checks += 1
    for index in range(1, 31):
        result, aux, fault, state = step(name, 0xFFFF, 0xFFFF, 1 << index)
        check((result, aux, fault, state) == (0, 0, 1, 0),
              'reserved control bit %d makes the polar beat malformed' % index)
    checks += 1

    # ---------------------------------------------------- 5  16-QAM soft demap
    name = 'comm_qam16_llr'

    def demap(in_phase, quad_phase, spacing, gain):
        """Brute force over all 16 Gray points: per bit the smallest axis distance
        among the points carrying it, then the gain and signed-byte clamp, and the
        Manhattan distance as a genuine two-dimensional minimum."""
        levels = (-3 * spacing, -spacing, spacing, 3 * spacing)
        raw, near = [], []
        for value in (in_phase, quad_phase):
            axis = [abs(value - level) for level in levels]
            for bit in (0, 1):
                one = min(axis[k] for k in range(4) if (gray(k) >> bit) & 1)
                zero = min(axis[k] for k in range(4) if not (gray(k) >> bit) & 1)
                raw.append(one - zero)
            near.append(min(range(4), key=lambda k: (axis[k], k)))
        scaled = [value << gain for value in raw]
        clamped = [max(-128, min(127, value)) for value in scaled]
        manhattan = min(abs(in_phase - low) + abs(quad_phase - high)
                        for low in levels for high in levels)
        return clamped, [int(value < 0) for value in raw], \
            [int(kept != exact) for kept, exact in zip(clamped, scaled)], near, \
            manhattan, int(max(abs(in_phase), abs(quad_phase)) > 7 * spacing)
    cases = [(level, other, spacing) for spacing in (1, 2, 4, 7)
             for level in (-3 * spacing, -spacing, spacing, 3 * spacing)
             for other in (level, 0)]
    cases += [(2 * level + 1, 0, spacing) for spacing in (1, 4, 7)
              for level in (-3 * spacing, -spacing, spacing, 3 * spacing)]
    cases += [(0, 0, spacing) for spacing in (1, 4, 7)]
    cases += [(-2 * 7, 2 * 7, 7), (-128, 127, 1), (127, -128, 7), (-125, 0, 7),
              (0, -125, 4), (49, 7, 7), (-49, -7, 1), (-128, -128, 7)]
    walk = Random(0x9ABE7000)
    cases += [(walk.randrange(-128, 128), walk.randrange(-128, 128),
               walk.randrange(1, 8)) for _ in range(12)]
    for in_phase, quad_phase, spacing in cases:
        for gain in (0, 3, 7):
            llr, hard, sat, near, manhattan, over = \
                demap(in_phase, quad_phase, spacing, gain)
            result, aux, fault, state = step(
                name, (in_phase & 0xFF) | ((quad_phase & 0xFF) << 8), spacing, gain)
            check(all(field(result, 8 * index, 8) == (llr[index] & 0xFF)
                      for index in range(4))
                  and field(aux, 0, 4) == sum(hard[index] << index
                                              for index in range(4))
                  and (field(aux, 4, 2), field(aux, 6, 2)) == (near[0], near[1])
                  and (field(aux, 8, 3), field(aux, 25, 3)) == (gain, spacing)
                  and field(aux, 16, 9) == manhattan and u8(aux, 15) == over
                  and all(u8(aux, 11 + index) == sat[index] for index in range(4))
                  and fault == int(over or any(sat)) and state == 0,
                  'symbol (%d,%d) at S=%d gain=%d demaps to %s'
                  % (in_phase, quad_phase, spacing, gain, llr))
    checks += 1
    # -S/+S midpoint and the -3S/-S midpoint both tie, so the lower level index
    # and a hard bit of 0 are the published Gray-boundary answers.
    for in_phase, want in ((4, 2), (0, 1), (-8, 0)):
        result, aux, fault, state = step(name, in_phase & 0xFF, 4, 0)
        llr, hard, sat, near, manhattan, over = demap(in_phase, 0, 4, 0)
        check(field(aux, 4, 2) == want == near[0] and fault == 0 and state == 0
              and not any(sat)
              and all(field(result, 8 * index, 8) == (llr[index] & 0xFF)
                      for index in range(4))
              and field(aux, 16, 9) == manhattan
              and field(aux, 0, 2) == sum(hard[index] << index for index in (0, 1)),
              'exact level, axis midpoint and outer midpoint demap with ties low')
    checks += 1
    for bad in ((1 << 16, 1, 0), (0xFFFF0000, 1, 0), (0, 1 << 3, 0), (0, 1 << 31, 0),
                (0, 0, 0), (0, 8, 0), (0, 1, 1 << 3), (0, 1, 1 << 31)):
        result, aux, fault, state = step(name, bad[0], bad[1], bad[2])
        check((result, aux, fault, state) == (0, 0, 1, 0),
              'reserved I/Q, spacing and gain bits and S=0 are malformed beats')
    checks += 1

    # ------------------------------------------------------ 6  viterbi acs step
    name = 'comm_viterbi_acs4'

    def branch(y0, y1, spacing, c0, c1):
        """(7,5) branch metric: |y - level| over both channels, +A for a channel
        bit of 0 and -A for a 1."""
        return (abs(y0 - (spacing if c0 == 0 else -spacing))
                + abs(y1 - (spacing if c1 == 0 else -spacing)))

    def hard_distance(guess, beats):
        """Spec hard metric: how many of the two channel bits disagree with the
        sign of the matching symbol."""
        return sum(int((s_bits(beat, 6) < 0) != c0)
                   + int((s_bits(beat >> 6, 6) < 0) != c1)
                   for (c0, c1), beat in zip(encode(guess), beats))

    def feed(beats, spacing, control):
        """Replay a beat sequence threading state as the board harness does."""
        state, decisions, bests, rows = 0, [], [], []
        for index, beat in enumerate(beats):
            result, aux, fault, state = step(name, beat, spacing, control(index),
                                             state)
            decisions.append(field(aux, 0, 4))
            bests.append(field(aux, 4, 2))
            rows.append((result, aux, fault, state))
        return rows, decisions, bests

    def traceback(decisions, bests):
        """Walk back from the best state: state k is reached from predecessor
        2*k[0] plus the decision bit and carried input k[1]."""
        state, path = bests[-1], []
        for index in range(len(bests) - 1, -1, -1):
            path.append((state >> 1) & 1)
            state = 2 * (state & 1) + ((decisions[index] >> state) & 1)
        return path[::-1], state
    walk = Random(0xAC50AC50)
    bits = [walk.randrange(2) for _ in range(10)]
    codeword = encode(bits)
    restart = lambda index: 1 << 31 if index == 0 else 0
    hard_restart = lambda index: (1 << 31) | (1 << 30) if index == 0 else 1 << 30
    for flips in ((), ((3, 0),), ((0, 1),), ((6, 0),), ((3, 0), (7, 1))):
        for spacing in (1, 4, 7):
            rows, decisions, bests = feed(trellis(bits, spacing, flips), spacing,
                                          restart)
            result, aux, fault, state = rows[-1]
            want, winner = mlse(codeword, spacing, flips)
            path, origin = traceback(decisions, bests)
            check(fault == 0 and origin == 0 and want == 2 * spacing * len(flips)
                  and field(aux, 18, 12) + min(field(result, 8 * k, 8)
                                               for k in range(4)) == want
                  and path == list(winner) == bits,
                  '%d-beat (7,5) walk, flips %s, A=%d: MLSE distance %d and sequence'
                  % (len(rows), flips, spacing, want))
    checks += 1
    beats = trellis(bits, 4, ())
    rows, decisions, bests = feed(beats, 4, restart)
    result, aux, fault, state = rows[0]
    y0, y1 = s_bits(beats[0], 6), s_bits(beats[0] >> 6, 6)
    check(u8(aux, 17) == 1 and field(aux, 6, 3) == 2
          and field(state, 40, 4) == 0b0101 and field(state, 0, 10) == 0
          and field(aux, 18, 12) == min(branch(y0, y1, 4, 0, 0),
                                        branch(y0, y1, 4, 1, 1))
          and u8(rows[1][1], 17) == 0,
          'a restart seeds only state 0, so just its two successors survive')
    checks += 1
    columns = []
    for spacing in (1, 4, 7):
        beats = trellis(bits, spacing, ((3, 0), (7, 1)))
        rows, decisions, bests = feed(beats, spacing, hard_restart)
        columns.append([tuple(row) for row in rows])
        result, aux, fault, state = rows[-1]
        want, winner = min((hard_distance(guess, beats), guess)
                           for guess in product((0, 1), repeat=len(beats)))
        path, origin = traceback(decisions, bests)
        check(field(aux, 18, 12) + min(field(result, 8 * k, 8) for k in range(4))
              == want == hard_distance(bits, beats) == len(((3, 0), (7, 1)))
              and path == list(winner) == bits and origin == 0,
              'hard decisions count %d disagreeing bits at A=%d, independent of A'
              % (want, spacing))
    check(columns[0] == columns[2],
          'in hard-decision mode A changes nothing, as the spec states')
    checks += 1
    state, floors, reach = 0, 0, [1, 0, 0, 0]
    for index, beat in enumerate((pack6(-32, 31), pack6(31, -32), pack6(0, 0))):
        y0, y1 = s_bits(beat, 6), s_bits(beat >> 6, 6)
        result, aux, fault, state = step(name, beat, 0, restart(index), state)
        floors += branch(y0, y1, 0, 0, 0)
        reach = [reach[2 * (ns & 1)] or reach[2 * (ns & 1) + 1] for ns in range(4)]
        check(field(aux, 18, 12) == floors and field(aux, 6, 3) == sum(reach)
              and field(state, 40, 4) == sum(reach[k] << k for k in range(4))
              and all(field(result, 8 * k, 8) == (0 if reach[k] else 255)
                      for k in range(4))
              and u8(aux, 14) == int(index == 2) and field(aux, 0, 4) == 0
              and field(aux, 9, 5) == 0 and fault == 0,
              'A=0 makes every branch equally far, so reachable states tie at the '
              'floor and ACS keeps predecessor 2*ns[0]')
    checks += 1
    for metric, limit in ((940, 0), (960, 0), (960, None), (960, 4090), (1000, 4090)):
        beat = pack6(31, 31)
        y0, y1 = s_bits(beat, 6), s_bits(beat >> 6, 6)
        sums = [metric + branch(y0, y1, 7, c0, c1) for c0, c1 in ((0, 0), (1, 1))]
        kept = [min(total, 1023) for total in sums]
        floor = min(kept)
        held = 4095 - floor if limit is None else limit
        result, aux, fault, state = step(name, beat, 7, 0,
                                         (held << 44) | (1 << 40) | metric)
        check(field(result, 0, 8) == kept[0] - floor
              and field(result, 16, 8) == kept[1] - floor
              and min(field(result, 8 * k, 8) for k in range(4)) == 0
              and u8(aux, 15) == int(max(sums) > 1023) and field(aux, 6, 3) == 2
              and field(aux, 4, 2) == (0 if kept[0] <= kept[1] else 2)
              and field(aux, 9, 5) == min(31, abs(kept[0] - kept[1]))
              and u8(aux, 14) == int(1023 in kept) and field(aux, 0, 4) == 0
              and field(aux, 18, 12) == min(4095, held + floor)
              and u8(aux, 16) == int(held + floor > 4095)
              and fault == u8(aux, 15) | u8(aux, 16),
              'sum %d clamps at 1023 and offset %d+%d clamps at 4095'
              % (max(sums), held, floor))
    checks += 1
    held = (123 << 44) | (1 << 40) | 5
    for bad in ((1 << 12, 1, 0), (0, 1 << 3, 0), (0, 1, 2), (0, 1, 1 << 29),
                (1, 1, (1 << 31) | (1 << 30) | 4), (1 << 30, 1, 0)):
        result, aux, fault, state = step(name, bad[0], bad[1], bad[2], held)
        check((result, aux, fault, state) == (0, 0, 1, held),
              'a malformed acs beat leaves metrics, reach and offset untouched')
    checks += 1
    return checks
