"""Memory-subsystem accelerator cores: gray-coded FIFO pointer/status engine,
occupancy watermark monitor, age-matrix LRU victim selector, prefix-CAM matcher,
best-fit bank allocator, TLB translate/permission engine, SECDED(72,64) codec,
RAID-6 P/Q syndrome accumulator, March-C memory-test sequencer and address-hash
scrambler.

Ten enabled-ready-valid accelerator cores for the `memsys` family. Every one of
them is the control path a memory controller really runs thousands of times per
second -- gray-pointer full/empty determination, occupancy watermarking, cache
victim selection, longest-prefix CAM resolution, best-fit bank allocation, TLB
translate and permission check, ECC generate/correct, stripe syndromes, March
element sequencing and address hashing -- and every one of them is a loop body on
a scalar core today.

Contract used by every core in this file (see generate_lib.RTL, doc/INTERFACE.md):
    inputs  a, b, c                     32 bit, one accepted beat
    outputs result, aux (r, x), fault   32 bit, 32 bit, 1 bit
    state   state_r -> state_n          256 bit, only accepted beats commit it
    restart / configure beat convention: c[31] = 1
    fault convention: a faulting beat still responds; result = 0 and aux = the
    numeric cause, and only the state fields the spec names for that cause change.

Every core keeps its tables in the 256-bit state register and reads them with a
constant-width variable part-select whose base is provably in range (the index is
always masked by the configured depth or by a validated slot number), so there is
no asynchronous read, no inferred latch and nothing that can settle to `x`.

Arithmetic rule: no core uses the `*` operator, so no MULT12X12 is instantiated
and no sim_extra behavioural model is needed. Every product this family needs is
either a power-of-two shift (region sizes, page offsets, GF(2^8) xtime) or an
explicit shift-add expansion (the GF(2^8) multiply in raid5_pq), which is what the
fabric's XOR trees and barrel shifters are for.

Each core is specified three times and all three must agree: as Verilog statements
in the BODY, as a pure-integer Python model in _MODELS, and as published hand
derived anchors in selftest(). The derived constants -- the SECDED(72,64) parity
check matrix, the GF(2^8) generator and its powers, the age matrix initial mask,
the primitive LFSR polynomial and the address-hash bijection -- are computed here
at import time from their definitions and then re-proved in selftest() along an
independent path (matrix rank, exhaustive round trip, order of a group element,
published syndromes), never by reading step().
"""
from random import Random

FAMILY = 'memsys'
MASK = (1 << 32) - 1
ALL256 = (1 << 256) - 1
BOARD = 128

CORES = []
_MODELS = {}
_ROWS = {}


def core(name, spec, body, advantage, lanes, **kwargs):
    entry = dict(name=name, family=FAMILY, spec=spec, body=body,
                 advantage=advantage, lanes=lanes, stateful=True,
                 faultless=False, latency=1)
    entry.update(kwargs)
    assert entry['latency'] == 1 and entry.get('module') is None
    assert '*' not in body, f'{name}: the `*` operator is banned in memsys bodies'
    CORES.append(entry)


# ---------------------------------------------------------------------------
# integer helpers shared by the models: each one mirrors a Verilog slice
# ---------------------------------------------------------------------------
def bits(value, pos, width):
    """Read RTL `state_r[pos +: width]`."""
    return (value >> pos) & ((1 << width) - 1)


def poke(state, pos, width, value):
    """Write RTL `state_n[pos +: width] = value`, leaving the rest alone."""
    field = (1 << width) - 1
    return (state & ~(field << pos) & ALL256) | ((value & field) << pos)


def sat(value, width):
    """RTL saturating counter: `if (cnt != ALL_ONES) cnt = cnt + 1`."""
    return min(value, (1 << width) - 1)


def gray_encode(p):
    return p ^ (p >> 1)


def popcount(value):
    return bin(value & MASK).count('1')


def field(value, low, width):
    return (value >> low) & ((1 << width) - 1)


def full_bits(n):
    """The two-bit Gray difference that means full: (1<<n) | (1<<(n-1)).

    The RTL writes this as a Verilog shift, and a shift by a negative integer is an
    out-of-range shift whose result is zero, so n = 0 gives 1, not a Python error.
    """
    return (1 << n) | ((1 << (n - 1)) if n >= 1 else 0)


# ===========================================================================
# 1  afifo_gray -- gray-coded FIFO pointer, status and data-order engine
# ===========================================================================
# State map. Byte k of the 16-deep shadow buffer lives at bits [8k +: 8], so a
# push or pop indexes it with (pointer & (depth-1)), a base of at most 120.
AFIFO_BUF = 0            # [127:0]   shadow buffer, 16 bytes
AFIFO_WP = 128           # [132:128] binary write pointer (N+1 bits used)
AFIFO_RP = 133           # [137:133] binary read pointer
AFIFO_N = 138            # [140:138] depth exponent N, 1..4, depth = 2^N
AFIFO_CFG = 141          # [141]     configured
AFIFO_PUSH = 142         # [149:142] pushes accepted since restart, saturates 255
AFIFO_POP = 150          # [157:150] pops accepted since restart, saturates 255
AFIFO_OVF = 158          # [161:158] writes refused by a full FIFO, saturates 15
AFIFO_UND = 162          # [165:162] reads refused by an empty FIFO, saturates 15
AFIFO_MIS = 166          # [168:166] shadow-vs-RAM order mismatches, saturates 7
AFIFO_MAX = 169          # [173:169] peak occupancy since restart

AFIFO_DECL = r"""
function [4:0] af_gray;
    input [4:0] p;
    begin
        af_gray = p ^ (p >> 1);
    end
endfunction
reg [4:0] af_aw, af_ar;
reg af_push, af_pop;
"""

AFIFO_BODY = r"""
sh = state_r[140:138];
pa = {27'd0, state_r[132:128]};
pb = {27'd0, state_r[137:133]};
mask = (32'd1 << (sh + 3'd1)) - 32'd1;
ph = (32'd1 << sh) - 32'd1;
pl = (pa - pb) & mask;
pc = 32'd0;
af_aw = pa[4:0];
af_ar = pb[4:0];
af_push = 1'b0;
af_pop = 1'b0;
wide[4:0] = af_gray(pa[4:0]);
wide[9:5] = af_gray(pb[4:0]);
wide[10] = (wide[4:0] == wide[9:5]);
wide[11] = ((wide[4:0] ^ wide[9:5]) ==
            (((32'd1 << sh) | (32'd1 << (sh - 3'd1))) & mask));
wide[16:12] = pl[4:0];
wide2[4:0] = wide[4:0];
wide2[9:5] = wide[9:5];
wide2[10] = wide[10];
wide2[11] = wide[11];
wide2[16:12] = pl[4:0];
wide2[26:19] = 8'd0;
if (c[31]) begin
    if (c[2:0] < 3'd1 || c[2:0] > 3'd4) begin
        pc = 32'd5;
    end else begin
        mask = (32'd1 << (c[2:0] + 3'd1)) - 32'd1;
        ph = (32'd1 << c[2:0]) - 32'd1;
        af_aw = c[3] ? (a & 32'h1f) & mask : 5'd0;
        af_ar = c[3] ? (b & 32'h1f) & mask : 5'd0;
        if (((af_aw - af_ar) & mask) > (ph + 32'd1)) begin
            pc = 32'd6;
        end else if (pc == 32'd0) begin
            state_n[140:138] = c[2:0];
            state_n[141] = 1'b1;
            state_n[132:128] = af_aw;
            state_n[137:133] = af_ar;
            state_n[127:0] = 128'd0;
            state_n[157:142] = 16'd0;
            state_n[168:158] = 11'd0;
            state_n[173:169] = ((af_aw - af_ar) & mask);
            wide[16:12] = pl[4:0];
            wide2[4:0] = af_gray(af_aw);
            wide2[9:5] = af_gray(af_ar);
            wide2[10] = (wide2[4:0] == wide2[9:5]);
            wide2[11] = ((wide2[4:0] ^ wide2[9:5]) ==
                         (((32'd1 << c[2:0]) | (32'd1 << (c[2:0] - 3'd1))) & mask));
            wide2[16:12] = ((af_aw - af_ar) & mask);
        end
    end
end else if (!state_r[141]) begin
    pc = 32'd1;
end else begin
    if (a[0]) begin
        if (wide[11]) begin
            pc = 32'd2;
            if (state_r[161:158] != 4'hF) begin
                state_n[161:158] = state_r[161:158] + 4'd1;
            end
        end else begin
            state_n[((pa & ph) << 3) +: 8] = a[15:8];
            af_aw = (pa[4:0] + 5'd1) & mask[4:0];
            af_push = 1'b1;
            if (state_r[149:142] != 8'hFF) begin
                state_n[149:142] = state_r[149:142] + 8'd1;
            end
        end
    end
    if (a[1]) begin
        if (wide[10]) begin
            if (pc == 32'd0) begin
                pc = 32'd3;
            end
            if (state_r[165:162] != 4'hF) begin
                state_n[165:162] = state_r[165:162] + 4'd1;
            end
        end else begin
            wide2[26:19] = state_r[((pb & ph) << 3) +: 8];
            af_ar = (pb[4:0] + 5'd1) & mask[4:0];
            af_pop = 1'b1;
            if (state_r[157:150] != 8'hFF) begin
                state_n[157:150] = state_r[157:150] + 8'd1;
            end
            if (c[3] && (wide2[26:19] != b[7:0])) begin
                pc = 32'd4;
                if (state_r[168:166] != 3'h7) begin
                    state_n[168:166] = state_r[168:166] + 3'd1;
                end
            end
        end
    end
    state_n[132:128] = af_aw;
    state_n[137:133] = af_ar;
    wide2[4:0] = af_gray(af_aw);
    wide2[9:5] = af_gray(af_ar);
    wide2[10] = (wide2[4:0] == wide2[9:5]);
    wide2[11] = ((wide2[4:0] ^ wide2[9:5]) ==
                 (((32'd1 << sh) | (32'd1 << (sh - 3'd1))) & mask));
    wide2[16:12] = ((32'd0 + af_aw) - (32'd0 + af_ar)) & mask;
    if (wide2[16:12] > state_r[173:169]) begin
        state_n[173:169] = wide2[16:12];
    end
end
if (pc != 32'd0) begin
    f = 1'b1;
    x[3:0] = pc[3:0];
end else begin
    r[4:0] = wide[4:0];
    r[9:5] = wide[9:5];
    r[10] = wide[10];
    r[11] = wide[11];
    r[16:12] = wide[16:12];
    r[21:17] = wide2[16:12];
    r[22] = af_push;
    r[23] = af_pop;
    r[31:24] = wide2[26:19];
    x[4:0] = af_aw;
    x[9:5] = af_ar;
    x[12:10] = c[31] ? state_n[140:138] : sh[2:0];
    x[13] = c[3];
    x[14] = c[31];
    x[15] = !c[31];
    x[19:16] = state_n[161:158];
    x[23:20] = state_n[165:162];
    x[28:24] = state_n[173:169];
    x[31:29] = state_n[168:166];
end
"""

core('afifo_gray',
     'Stateful gray-coded FIFO pointer, status and data-order engine with a '
     '16-entry shadow buffer. State: buffer byte k = state[8k +: 8], write pointer '
     '= state[132:128], read pointer = state[137:133], depth exponent N = '
     'state[140:138], configured = state[141], pushes = state[149:142], pops = '
     'state[157:150], overflow attempts = state[161:158], underflow attempts = '
     'state[165:162], order mismatches = state[168:166], peak occupancy = '
     'state[173:169]. Configure/restart beat (c[31]=1) takes N from c[2:0], which '
     'must be 1..4 (depth = 2^N entries), clears the buffer, the pointers and every '
     'counter, and commits nothing on a bad N. With c[3]=1 the same beat preloads '
     'the write pointer from a[4:0] and the read pointer from b[4:0], each taken '
     'modulo 2^(N+1), and refuses the pair when the implied occupancy exceeds the '
     'depth. Op beat (c[31]=0): a[0] requests a write, a[1] a read, a[15:8] is the '
     'write data, b[7:0] is the byte the external RAM returns for a read, and c[3] '
     'enables the data-order check. Empty and full are decided only from the Gray '
     'codes of the two pointers, exactly as a two-clock-domain FIFO must: empty when '
     'the two Gray codes are equal, full when they differ in exactly the top two '
     'pointer bits; no beat ever uses a binary pointer difference for those two '
     'flags. A write is accepted unless the FIFO is full, a read unless it is empty; '
     'a refused write leaves the write pointer alone and counts an overflow attempt, '
     'a refused read leaves the read pointer alone and counts an underflow attempt, '
     'and pointers, counters and peak occupancy always reflect the beats that were '
     'actually accepted. The popped byte is returned in result[31:24] from the '
     'shadow copy, and with c[3]=1 a byte that differs from b[7:0] is an order or '
     'corruption error, counted and flagged while the read still advances the '
     'pointer because the external memory really did drive it. Fault causes: 1 = op '
     'beat before the depth was configured, 2 = write to a full FIFO, 3 = read from '
     'an empty FIFO, 4 = shadow byte disagrees with the RAM byte, 5 = N outside '
     '1..4 on a configure beat, 6 = preloaded pointer pair implies an occupancy '
     'above the depth. A faulting beat gives result = 0, aux[3:0] = cause and only '
     'the counters named above move. Otherwise result: [4:0]=write Gray code before '
     'the beat, [9:5]=read Gray code, [10]=empty before, [11]=full before, '
     '[16:12]=occupancy before, [21:17]=occupancy after, [22]=write accepted, '
     '[23]=read accepted, [31:24]=popped byte (0 with no read). aux: [4:0]=write '
     'pointer after, [9:5]=read pointer after, [12:10]=N after, [13]=c[3] check '
     'enable, [14]=configure beat, [15]=op beat, [19:16]=overflow attempts, '
     '[23:20]=underflow attempts, [28:24]=peak occupancy, [31:29]=order mismatches.',
     AFIFO_BODY,
     'Two pointer Gray encodes, both equality compares and the 16-deep byte '
     'read/write/close all fit one enabled beat at II=1, while firmware must sample '
     'both pointers non-atomically, mask, XOR and branch, which is exactly how '
     'missed-full and missed-empty FIFO lockups ship.',
     16, decl=AFIFO_DECL)


def _afifo_gray(a, b, c, st):
    """Literal transcription of AFIFO_BODY; every line maps to one RTL statement."""
    sh = bits(st, AFIFO_N, 3)
    pa = bits(st, AFIFO_WP, 5)
    pb = bits(st, AFIFO_RP, 5)
    mask = ((1 << (sh + 1)) - 1) & MASK
    ph = ((1 << sh) - 1) & MASK
    pl = (pa - pb) & mask
    pc = 0
    af_aw, af_ar = pa, pb
    af_push = af_pop = 0
    pre = dict(gp=gray_encode(pa), gq=gray_encode(pb))
    wide = {'g0': pre['gp'], 'g1': pre['gq']}
    wide['empty'] = int(pre['gp'] == pre['gq'])
    wide['full'] = int((pre['gp'] ^ pre['gq']) == (full_bits(sh) & mask))
    wide['occ'] = pl
    w2 = dict(g0=wide['g0'], g1=wide['g1'], empty=wide['empty'],
              full=wide['full'], occ=pl, rdata=0)
    ns = st
    if c & (1 << 31):
        cfg = c & 0x7
        if cfg < 1 or cfg > 4:
            pc = 5
        else:
            mask = (1 << (cfg + 1)) - 1
            ph = (1 << cfg) - 1
            af_aw = ((a & 0x1f) & mask) if (c >> 3) & 1 else 0
            af_ar = ((b & 0x1f) & mask) if (c >> 3) & 1 else 0
            if ((af_aw - af_ar) & mask) > ph + 1:
                pc = 6
            else:
                ns = poke(ns, AFIFO_N, 3, cfg)
                ns = poke(ns, AFIFO_CFG, 1, 1)
                ns = poke(ns, AFIFO_WP, 5, af_aw)
                ns = poke(ns, AFIFO_RP, 5, af_ar)
                for k in range(16):
                    ns = poke(ns, 8 * k, 8, 0)
                ns = poke(ns, AFIFO_PUSH, 16, 0)
                ns = poke(ns, AFIFO_OVF, 11, 0)
                ns = poke(ns, AFIFO_MAX, 5, (af_aw - af_ar) & mask)
                w2['g0'] = gray_encode(af_aw)
                w2['g1'] = gray_encode(af_ar)
                w2['empty'] = int(w2['g0'] == w2['g1'])
                w2['full'] = int((w2['g0'] ^ w2['g1']) ==
                                 (((1 << cfg) | (1 << (cfg - 1))) & mask))
                w2['occ'] = (af_aw - af_ar) & mask
    elif not bits(st, AFIFO_CFG, 1):
        pc = 1
    else:
        if a & 1:
            if wide['full']:
                pc = 2
                ns = poke(ns, AFIFO_OVF, 4, sat(bits(st, AFIFO_OVF, 4) + 1, 4))
            else:
                slot = (pa & ph) & 0xf
                ns = poke(ns, AFIFO_BUF + 8 * slot, 8, (a >> 8) & 0xff)
                af_aw = (pa + 1) & mask & 0x1f
                af_push = 1
                ns = poke(ns, AFIFO_PUSH, 8, sat(bits(st, AFIFO_PUSH, 8) + 1, 8))
        if (a >> 1) & 1:
            if wide['empty']:
                pc = pc or 3
                ns = poke(ns, AFIFO_UND, 4, sat(bits(st, AFIFO_UND, 4) + 1, 4))
            else:
                slot = (pb & ph) & 0xf
                w2['rdata'] = bits(st, AFIFO_BUF + 8 * slot, 8)
                af_ar = (pb + 1) & mask & 0x1f
                af_pop = 1
                ns = poke(ns, AFIFO_POP, 8, sat(bits(st, AFIFO_POP, 8) + 1, 8))
                if ((c >> 3) & 1) and w2['rdata'] != (b & 0xff):
                    pc = 4
                    ns = poke(ns, AFIFO_MIS, 3, sat(bits(st, AFIFO_MIS, 3) + 1, 3))
        ns = poke(ns, AFIFO_WP, 5, af_aw)
        ns = poke(ns, AFIFO_RP, 5, af_ar)
        w2['g0'] = gray_encode(af_aw)
        w2['g1'] = gray_encode(af_ar)
        w2['empty'] = int(w2['g0'] == w2['g1'])
        w2['full'] = int((w2['g0'] ^ w2['g1']) == (full_bits(sh) & mask))
        w2['occ'] = (af_aw - af_ar) & mask
        if w2['occ'] > bits(st, AFIFO_MAX, 5):
            ns = poke(ns, AFIFO_MAX, 5, w2['occ'])
    if pc:
        r, x = 0, pc & 0xf
    else:
        r = (wide['g0'] | (wide['g1'] << 5) | (wide['empty'] << 10)
             | (wide['full'] << 11) | (wide['occ'] << 12) | (w2['occ'] << 17)
             | (af_push << 22) | (af_pop << 23) | (w2['rdata'] << 24)) & MASK
        x = (af_aw | (af_ar << 5) | ((bits(ns, AFIFO_N, 3) if (c >> 31) else sh) << 10)
             | (((c >> 3) & 1) << 13) | ((c >> 31) << 14) | (int(not (c >> 31)) << 15)
             | (bits(ns, AFIFO_OVF, 4) << 16) | (bits(ns, AFIFO_UND, 4) << 20)
             | (bits(ns, AFIFO_MAX, 5) << 24) | (bits(ns, AFIFO_MIS, 3) << 29)) & MASK
    return r, x, int(bool(pc)), ns & ALL256


_MODELS['afifo_gray'] = _afifo_gray


def _afifo_rows():
    """Board set: configure, fill to full, overflow, drain with the order check on,
    corrupt pops, underflow, bad depth, impossible pointer preload and reconfigure."""
    rows = [(1, 0, 0)]                                       # op before configure
    rows.append((0, 0, 0x80000000 | 0))                      # N = 0, rejected
    rows.append((0, 0, 0x80000000 | 5))                      # N = 5, rejected
    rows.append((0, 0, 0x80000000 | 4))                      # configure depth 16
    pushed = []
    for k in range(16):                                      # fill it exactly full
        value = (k * 7 + 3) & 0xff
        pushed.append(value)
        rows.append((1 | (value << 8), 0, 0))
    for k in range(2):                                       # writes to a full FIFO
        rows.append((1 | ((0xE0 + k) << 8), 0, 0))
    for k in range(16):                                      # drain, order-checked
        rows.append((2, pushed[k], 8))
    rows.append((2, 0, 8))                                   # read from empty
    rows.append((0, 0, 0x80000000 | 2))                      # depth 4, pointers 0
    pushed = []
    for k in range(4):
        value = (0x5A + k) & 0xff
        pushed.append(value)
        rows.append((1 | (value << 8), 0, 0))
    rows.append((3, pushed[0] ^ 0xFF, 8 | 3))                # pop with bad byte
    rows.append((3, pushed[1], 8 | 3))                       # pop with good byte
    rows.append((0, 0, 0x80000000 | (1 << 3) | 3))           # preload wp=0 rp=7, N=3
    rows.append((0, 0, 0x80000000 | (1 << 3) | 1))           # preload pair above depth 2
    rows.append((0, 0, 0x80000000 | 1))                      # depth 2
    for k in range(6):                                       # alternating push/pop
        rows.append((3, k, 8 if k & 1 else 0))
    rows.append((0, 0, 0x80000000 | 4))                      # back to depth 16
    # Sweep writes, checked reads and read/write pairs with a changing byte and a
    # periodic depth change, so the tail walks distinct pointer/occupancy
    # combinations instead of repeating one steady state.
    sweep = 0
    while len(rows) < BOARD:
        sweep += 1
        value = (0x1B * sweep) & 0xff
        pattern = sweep % 3
        if pattern == 0:
            rows.append((1 | (value << 8), value, 0))            # write
        elif pattern == 1:
            rows.append((2, value, 8))                           # checked read
        else:
            rows.append((3, value, 0))                           # read + write
        if sweep % 7 == 0:
            rows.append((0, value, 0x80000000 | (1 << 3) | (sweep % 4 + 1)))
    return rows


_ROWS['afifo_gray'] = _afifo_rows


# ===========================================================================
# 2  fifo_wm -- synchronous FIFO occupancy watermark / level monitor
# ===========================================================================
# State map (all constant part-selects, no variable base):
FW_DEPTH = 0     # [7:0]    configured depth D, 1..255
FW_CNT = 8       # [15:8]   occupancy (number of entries held)
FW_PEAK = 16     # [23:16]  peak occupancy since restart
FW_PUSH = 24     # [31:24]  pushes accepted, saturates 255
FW_POP = 32      # [39:32]  pops accepted, saturates 255
FW_OVF = 40      # [43:40]  writes refused by a full FIFO, saturates 15
FW_UND = 44      # [47:44]  reads refused by an empty FIFO, saturates 15
FW_CFG = 48      # [48]     configured flag

FW_DECL = r"""
reg [7:0] fw_D, fw_L, fw_after, fw_pk, fw_push, fw_pop, fw_cD;
reg [3:0] fw_ovf, fw_und;
reg fw_cfg, fw_pushacc, fw_popacc;
reg [2:0] fw_cause;
"""

FW_BODY = r"""
fw_cfg = state_r[48];
fw_D = state_r[7:0];
fw_L = state_r[15:8];
fw_pk = state_r[23:16];
fw_push = state_r[31:24];
fw_pop = state_r[39:32];
fw_ovf = state_r[43:40];
fw_und = state_r[47:44];
fw_after = fw_L;
fw_pushacc = 1'b0;
fw_popacc = 1'b0;
fw_cause = 3'd0;
if (c[31]) begin
    fw_cD = c[7:0];
    if (fw_cD == 8'd0) begin
        fw_cause = 3'd4;
    end else begin
        state_n[7:0] = fw_cD;
        state_n[15:8] = 8'd0;
        state_n[23:16] = 8'd0;
        state_n[31:24] = 8'd0;
        state_n[39:32] = 8'd0;
        state_n[43:40] = 4'd0;
        state_n[47:44] = 4'd0;
        state_n[48] = 1'b1;
    end
end else if (!fw_cfg) begin
    fw_cause = 3'd1;
end else begin
    if (a[1]) begin
        if (fw_after != 8'd0) begin
            fw_after = fw_after - 8'd1;
            fw_popacc = 1'b1;
            if (fw_pop != 8'hFF) state_n[39:32] = fw_pop + 8'd1;
        end else begin
            if (fw_cause == 3'd0) fw_cause = 3'd3;
            if (fw_und != 4'hF) state_n[47:44] = fw_und + 4'd1;
        end
    end
    if (a[0]) begin
        if (fw_after < fw_D) begin
            fw_after = fw_after + 8'd1;
            fw_pushacc = 1'b1;
            if (fw_push != 8'hFF) state_n[31:24] = fw_push + 8'd1;
        end else begin
            if (fw_cause == 3'd0) fw_cause = 3'd2;
            if (fw_ovf != 4'hF) state_n[43:40] = fw_ovf + 4'd1;
        end
    end
    state_n[15:8] = fw_after;
    if (fw_after > fw_pk) state_n[23:16] = fw_after;
end
if (fw_cause != 3'd0) begin
    f = 1'b1;
    x[2:0] = fw_cause;
end else begin
    r[7:0] = fw_L;
    r[15:8] = fw_after;
    r[16] = (fw_L == 8'd0);
    r[17] = (fw_L == fw_D);
    r[18] = (fw_L == 8'd1);
    r[19] = (fw_L == (fw_D - 8'd1));
    r[20] = (fw_L >= (fw_D >> 1));
    r[21] = fw_pushacc;
    r[22] = fw_popacc;
    x[7:0] = fw_D;
    x[15:8] = (fw_after > fw_pk) ? fw_after : fw_pk;
    x[23:16] = (fw_pushacc && (fw_push != 8'hFF)) ? (fw_push + 8'd1) : fw_push;
    x[31:24] = (fw_popacc && (fw_pop != 8'hFF)) ? (fw_pop + 8'd1) : fw_pop;
end
"""

core('fifo_wm',
     'Synchronous FIFO occupancy watermark monitor. State: depth D = state[7:0], '
     'occupancy = state[15:8], peak occupancy = state[23:16], pushes = state[31:24], '
     'pops = state[39:32], overflow attempts = state[43:40], underflow attempts = '
     'state[47:44], configured = state[48]. Configure/restart beat (c[31]=1) takes D '
     'from c[7:0], refuses D = 0 as cause 4, and clears occupancy, peak and every '
     'counter while setting configured. Op beat (c[31]=0): a[1] requests a pop that '
     'is applied first (drain-then-fill), a[0] a push; a pop from an empty level is '
     'cause 3 and an underflow attempt, a push to a full level (occupancy = D) is '
     'cause 2 and an overflow attempt, and a refused move leaves occupancy alone but '
     'still counts the attempt, saturating at 15; accepted moves increment the push/'
     'pop counters, saturating at 255, and the peak tracks the maximum occupancy. '
     'Fault causes: 1 = op beat before configure, 2 = push to a full FIFO, 3 = pop '
     'from an empty FIFO, 4 = zero depth on a configure beat; a faulting beat gives '
     'result = 0, aux[2:0] = the cause, and only the attempt counter moves. Otherwise '
     'result: [7:0]=occupancy before, [15:8]=occupancy after, [16]=empty before, '
     '[17]=full before, [18]=almost-empty (occupancy==1) before, [19]=almost-full '
     '(occupancy==D-1) before, [20]=at-or-above half before, [21]=push accepted, '
     '[22]=pop accepted. aux: [7:0]=D, [15:8]=peak after, [23:16]=pushes after, '
     '[31:24]=pops after. All watermark flags use the binary level, never a pointer '
     'difference, so this single-clock occupancy monitor is distinct from the gray-'
     'coded two-domain afifo status engine.',
     FW_BODY,
     'One enabled beat computes the new level and the full five watermark flags '
     '(empty, almost-empty, half, almost-full, full) plus peak tracking in parallel, '
     'where firmware must reload a shared counter, mask, compare against several '
     'programmable thresholds and branch per sample, which is how watermark '
     'race conditions and lost interrupts ship.',
     1, decl=FW_DECL)


def _fifo_wm(a, b, c, st):
    cfg = bits(st, FW_CFG, 1)
    D = bits(st, FW_DEPTH, 8)
    L = bits(st, FW_CNT, 8)
    pk = bits(st, FW_PEAK, 8)
    push = bits(st, FW_PUSH, 8)
    pop = bits(st, FW_POP, 8)
    ovf = bits(st, FW_OVF, 4)
    und = bits(st, FW_UND, 4)
    after = L
    pushacc = popacc = 0
    cause = 0
    ns = st
    if c >> 31:
        cD = c & 0xff
        if cD == 0:
            cause = 4
        else:
            ns = poke(ns, FW_DEPTH, 8, cD)
            ns = poke(ns, FW_CNT, 8, 0)
            ns = poke(ns, FW_PEAK, 8, 0)
            ns = poke(ns, FW_PUSH, 8, 0)
            ns = poke(ns, FW_POP, 8, 0)
            ns = poke(ns, FW_OVF, 4, 0)
            ns = poke(ns, FW_UND, 4, 0)
            ns = poke(ns, FW_CFG, 1, 1)
    elif not cfg:
        cause = 1
    else:
        if (a >> 1) & 1:
            if after != 0:
                after -= 1
                popacc = 1
                if pop != 0xFF:
                    ns = poke(ns, FW_POP, 8, pop + 1)
            else:
                if cause == 0:
                    cause = 3
                if und != 0xF:
                    ns = poke(ns, FW_UND, 4, und + 1)
        if a & 1:
            if after < D:
                after += 1
                pushacc = 1
                if push != 0xFF:
                    ns = poke(ns, FW_PUSH, 8, push + 1)
            else:
                if cause == 0:
                    cause = 2
                if ovf != 0xF:
                    ns = poke(ns, FW_OVF, 4, ovf + 1)
        ns = poke(ns, FW_CNT, 8, after)
        if after > pk:
            ns = poke(ns, FW_PEAK, 8, after)
    if cause:
        return 0, cause, 1, ns & ALL256
    r = (L | (after << 8) | int(L == 0) << 16 | int(L == D) << 17
         | int(L == 1) << 18 | int(L == ((D - 1) & 0xff)) << 19
         | int(L >= (D >> 1)) << 20 | (pushacc << 21) | (popacc << 22)) & MASK
    x = (D | (max(pk, after) << 8)
         | ((push + 1 if (pushacc and push != 0xFF) else push) << 16)
         | ((pop + 1 if (popacc and pop != 0xFF) else pop) << 24)) & MASK
    return r, x, 0, ns & ALL256


_MODELS['fifo_wm'] = _fifo_wm


def _fifo_wm_rows():
    rows = [(1, 0, 0)]                              # cause 1: op before configure
    rows.append((0, 0, 0x80000000 | 0))             # cause 4: depth 0 rejected
    rows.append((0, 0, 0x80000000 | 8))             # configure D = 8
    for _ in range(8):                              # fill to exactly full
        rows.append((1, 0, 0))
    rows.append((1, 0, 0))                          # cause 2: overflow push
    rows.append((3, 0, 0))                          # pop + push keeps level 8, full
    for _ in range(8):                              # drain to empty
        rows.append((2, 0, 0))
    rows.append((2, 0, 0))                          # cause 3: underflow pop
    rows.append((0, 0, 0x80000000 | 1))             # D = 1: empty and full collide
    rows.append((1, 0, 0))                          # fill D = 1 (full)
    rows.append((3, 0, 0))                          # drain+fill at D = 1
    rows.append((0, 0, 0x80000000 | 16))            # D = 16
    # A deterministic sweep that walks many distinct (before, after) occupancy levels
    # and re-tunes the depth, so the board set discriminates 96+ responses.
    level = 0
    D = 16
    sweep = 0
    while len(rows) < BOARD:
        sweep += 1
        if sweep % 9 == 0:
            D = [3, 5, 7, 8, 11, 12, 15, 16][sweep // 9 % 8]
            level = 0
            rows.append((0, 0, 0x80000000 | D))
            continue
        mode = sweep % 4
        if mode == 0:
            rows.append((1, 0, 0))                  # push
        elif mode == 1:
            rows.append((2, 0, 0))                  # pop
        elif mode == 2:
            rows.append((1, 0, 0))
            rows.append((3, 0, 0))                  # push then drain-fill
        else:
            rows.append((2, 0, 0))
    return rows


_ROWS['fifo_wm'] = _fifo_wm_rows


# ===========================================================================
# 3  lru8_victim -- age-matrix (patent style) 8-way LRU victim selector
# ===========================================================================
# State map: row i (way i is used more recently than the ways its set bits name)
# lives at bits [8*i +: 8]; ways W = state[75:72]; configured = state[76];
# references accepted = state[84:77]; victim queries = state[92:85].
LR_W = 72
LR_CFG = 76
LR_REF = 77
LR_QRY = 85

LR_DECL = r"""
reg [3:0] lr_Wb, lr_nW, lr_Wa;
reg [7:0] lr_vm, lr_vmask, lr_row, lr_fold;
reg [2:0] lr_vb, lr_va, lr_way;
reg lr_cfg, lr_found, lr_ref, lr_qry;
"""

LR_BODY = r"""
lr_cfg = state_r[76];
lr_Wb = state_r[75:72];
lr_vm = ((32'd1 << lr_Wb) - 32'd1) & 8'hff;
lr_vb = 3'd7;
lr_found = 1'b0;
for (i = 0; i < 8; i = i + 1) begin
    if (!lr_found && (i < lr_Wb) && ((state_r[(i << 3) +: 8] & lr_vm) == 8'd0)) begin
        lr_vb = i[2:0];
        lr_found = 1'b1;
    end
end
lr_way = 3'd0;
lr_ref = 1'b0;
lr_qry = 1'b0;
if (c[31]) begin
    lr_nW = c[3:0];
    if (lr_nW == 4'd0 || lr_nW > 4'd8) begin
        f = 1'b1;
        x[2:0] = 3'd4;
    end else begin
        lr_vmask = ((32'd1 << lr_nW) - 32'd1) & 8'hff;
        for (i = 0; i < 8; i = i + 1) begin
            if (i < lr_nW) state_n[(i << 3) +: 8] = (((32'd1 << i) - 32'd1) & lr_vmask);
            else state_n[(i << 3) +: 8] = 8'd0;
        end
        state_n[75:72] = lr_nW;
        state_n[76] = 1'b1;
        state_n[84:77] = 8'd0;
        state_n[92:85] = 8'd0;
    end
end else if (!lr_cfg) begin
    f = 1'b1;
    x[2:0] = 3'd1;
end else begin
    if (c[0]) begin
        lr_way = a[2:0];
        if (lr_way >= lr_Wb) begin
            f = 1'b1;
            x[2:0] = 3'd2;
        end else begin
            lr_ref = 1'b1;
            lr_vmask = ((32'd1 << lr_Wb) - 32'd1) & 8'hff;
            for (i = 0; i < 8; i = i + 1) begin
                if (i >= lr_Wb) lr_row = 8'd0;
                else if (i == lr_way) lr_row = lr_vmask & ~(8'd1 << lr_way);
                else lr_row = state_r[(i << 3) +: 8] & ~(8'd1 << lr_way);
                state_n[(i << 3) +: 8] = lr_row;
            end
            if (state_r[84:77] != 8'hFF) state_n[84:77] = state_r[84:77] + 8'd1;
        end
    end else begin
        lr_qry = 1'b1;
        if (state_r[92:85] != 8'hFF) state_n[92:85] = state_r[92:85] + 8'd1;
    end
end
if (!f) begin
    lr_Wa = state_n[75:72];
    lr_vm = ((32'd1 << lr_Wa) - 32'd1) & 8'hff;
    lr_va = 3'd7;
    lr_found = 1'b0;
    for (i = 0; i < 8; i = i + 1) begin
        if (!lr_found && (i < lr_Wa) && ((state_n[(i << 3) +: 8] & lr_vm) == 8'd0)) begin
            lr_va = i[2:0];
            lr_found = 1'b1;
        end
    end
    lr_fold = 8'd0;
    for (i = 0; i < 8; i = i + 1) lr_fold = lr_fold ^ state_n[(i << 3) +: 8];
    r[2:0] = lr_vb;
    r[5:3] = lr_va;
    r[8:6] = lr_ref ? lr_way : 3'd0;
    r[9] = lr_ref;
    r[10] = lr_qry;
    r[14:11] = lr_Wa;
    r[22:15] = lr_fold;
    r[26:23] = lr_Wb;
    x[3:0] = lr_Wa;
    x[11:4] = state_n[84:77];
    x[19:12] = state_n[92:85];
    x[22:20] = lr_vb;
    x[23] = state_n[76];
    x[31:24] = lr_fold;
end
"""

core('lru8_victim',
     'Age-matrix 8-way LRU victim selector, the hardware LRU used by set-associative '
     'caches and bank routers. State: recency row i = state[8*i +: 8] (bit j set means '
     'way i was used more recently than way j), number of ways W = state[75:72], '
     'configured = state[76], references accepted = state[84:77], victim queries = '
     'state[92:85]. Configure/restart beat (c[31]=1) takes W from c[3:0], which must '
     'be 1..8 (else cause 4, state untouched), initialises the matrix so way 0 is the '
     'least recently used and way W-1 the most recently used, and clears both '
     'counters. Op beat (c[31]=0): with c[0]=1 the beat is a reference to way a[2:0]; '
     'the referenced way becomes most recently used (its row is every valid way except '
     'itself), every other row has the referenced way cleared, invalid-way rows stay '
     'zero, and a reference count is taken; a reference to a way at or above W is '
     'cause 2 and changes nothing. With c[0]=0 the beat is a victim query that only '
     'counts a query. The victim is the lowest-index valid way whose masked row is '
     'all zero. Fault causes: 1 = reference before configure, 2 = reference to an '
     'invalid way, 4 = W outside 1..8 on a configure beat; a faulting beat gives '
     'result = 0 and aux[2:0] = the cause with the matrix and counters unchanged. '
     'Otherwise result: [2:0]=victim before, [5:3]=victim after, [8:6]=referenced way '
     '(0 on a query), [9]=reference beat, [10]=query beat, [14:11]=W after, '
     '[22:15]=XOR fold of the eight rows after, [26:23]=W before. aux: [3:0]=W after, '
     '[11:4]=references after, [19:12]=queries after, [22:20]=victim before, '
     '[23]=configured, [31:24]=row fold.',
     LR_BODY,
     'An 8-way victim needs one XOR-reduction and one priority pick per way every '
     'lookup; this retires the reference update and both the before and after victim '
     'selects in a single enabled beat at II=1, whereas a scalar core pays an eight '
     'iteration shift-and-compare loop plus a second pass for the age-matrix update.',
     8, decl=LR_DECL)


def _lru_victim(rows, W):
    vmask = (1 << W) - 1 if W <= 8 else 0xff
    for i in range(min(W, 8)):
        if (rows[i] & vmask) == 0:
            return i
    return 7


def _lru8(a, b, c, st):
    cfg = bits(st, LR_CFG, 1)
    Wb = bits(st, LR_W, 4)
    rows_b = [bits(st, 8 * i, 8) for i in range(8)]
    vb = _lru_victim(rows_b, Wb)
    way = 0
    ref = qry = 0
    ns = st
    if c >> 31:
        nW = c & 0xf
        if nW == 0 or nW > 8:
            return 0, 4, 1, st
        vmask = (1 << nW) - 1
        for i in range(8):
            ns = poke(ns, 8 * i, 8, ((1 << i) - 1) & vmask if i < nW else 0)
        ns = poke(ns, LR_W, 4, nW)
        ns = poke(ns, LR_CFG, 1, 1)
        ns = poke(ns, LR_REF, 8, 0)
        ns = poke(ns, LR_QRY, 8, 0)
    elif not cfg:
        return 0, 1, 1, st
    else:
        if c & 1:
            way = a & 7
            if way >= Wb:
                return 0, 2, 1, st
            ref = 1
            vmask = (1 << Wb) - 1
            for i in range(8):
                if i >= Wb:
                    row = 0
                elif i == way:
                    row = vmask & ~(1 << way)
                else:
                    row = rows_b[i] & ~(1 << way)
                ns = poke(ns, 8 * i, 8, row & 0xff)
            if bits(st, LR_REF, 8) != 0xFF:
                ns = poke(ns, LR_REF, 8, bits(st, LR_REF, 8) + 1)
        else:
            qry = 1
            if bits(st, LR_QRY, 8) != 0xFF:
                ns = poke(ns, LR_QRY, 8, bits(st, LR_QRY, 8) + 1)
    Wa = bits(ns, LR_W, 4)
    rows_a = [bits(ns, 8 * i, 8) for i in range(8)]
    va = _lru_victim(rows_a, Wa)
    fold = 0
    for row in rows_a:
        fold ^= row
    r = (vb | (va << 3) | ((way if ref else 0) << 6) | (ref << 9) | (qry << 10)
         | (Wa << 11) | (fold << 15) | (Wb << 23)) & MASK
    x = (Wa | (bits(ns, LR_REF, 8) << 4) | (bits(ns, LR_QRY, 8) << 12)
         | (vb << 20) | (bits(ns, LR_CFG, 1) << 23) | (fold << 24)) & MASK
    return r, x, 0, ns & ALL256


_MODELS['lru8_victim'] = _lru8


def _lru8_rows():
    rows = [(1, 0, 0)]                              # cause 1: op before configure
    rows.append((0, 0, 0x80000000))                 # cause 4: W = 0
    rows.append((0, 0, 0x80000000 | 9))             # cause 4: W = 9
    rows.append((0, 0, 0x80000000 | 8))             # configure W = 8 (restart)
    for w in [0, 1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 4, 3, 2, 1, 0, 3, 3, 4, 4, 0, 7, 1, 6]:
        rows.append((w, 0, 1))                      # reference way
    rows.append((0, 0, 0))                          # victim query
    rows.append((5, 0, 1))                          # reference way 5
    rows.append((8, 0, 1))                          # cause 2: way 8 >= W 8
    rows.append((0, 0, 0x80000000 | 4))             # restart W = 4
    for w in [0, 1, 2, 3, 3, 2, 1, 0, 1, 1, 2, 2, 0, 3]:
        rows.append((w, 0, 1))
        rows.append((0, 0, 0))                      # interleave queries
    # Sweep references, queries and periodic reconfigurations so the fold, victim and
    # counter fields keep producing fresh triples across the whole board set.
    s = 0
    while len(rows) < BOARD:
        s += 1
        if s % 11 == 0:
            rows.append((0, 0, 0x80000000 | [2, 3, 4, 5, 6, 7, 8][s // 11 % 7]))
        elif s % 3 == 0:
            rows.append((0, 0, 0))                  # query
        else:
            rows.append((s % 8, 0, 1))              # reference
    return rows


_ROWS['lru8_victim'] = _lru8_rows


# ===========================================================================
# 4  cam_match -- 6-entry prefix CAM with longest-prefix match and LPM counter
# ===========================================================================
# State map (all bases are power-of-two multiples so they stay shift-only):
#   key  j = state[(j << 4) +: 16]        (j = 0..5, bits 0..95)
#   len/valid j = state[(96 + (j << 3)) +: 8]  bit7 = valid, bits[4:0] = prefix len
#   act  j = state[(144 + (j << 3)) +: 8]
CM_CFG = 192
CM_N = 193
CM_INS = 196
CM_LKS = 204
CM_HIT = 212
CM_MIS = 220

CM_DECL = r"""
reg cm_cfg;
reg [2:0] cm_N;
reg [2:0] cm_slot;
reg [4:0] cm_len, cm_sh;
reg [7:0] cm_lbyte, cm_act;
reg [15:0] cm_key, cm_kj, cm_msk;
reg [2:0] cm_best, cm_idx;
reg [4:0] cm_blen;
reg cm_found, cm_hit, cm_vj, cm_mj;
"""

# ===========================================================================
# 4  cam_match -- 6-entry prefix CAM (longest-prefix match) engine
# ===========================================================================
# State map (every variable base is a shift by a constant, never a multiply):
#   key   j = state[(j << 4) +: 16]              (j = 0..5, bits 0..95)
#   len/v j = state[(96 + (j << 3)) +: 8]        bit7 valid, bits[4:0] prefix length
#   act   j = state[(144 + (j << 3)) +: 8]
CM_CFG = 192    # [192]     configured
CM_N = 193      # [195:193] entry count, 1..6
CM_INS = 196    # [203:196] inserts accepted, saturates 255
CM_LKS = 204    # [211:204] lookups, saturates 255
CM_HIT = 212    # [219:212] lookup hits, saturates 255
CM_MIS = 220    # [223:220] lookup misses, saturates 15

CM_DECL = r"""
reg cm_cfg, cm_is_cfg, cm_is_ins, cm_is_hit, cm_vr, cm_found, cm_vj, cm_mj;
reg [2:0] cm_N, cm_n, cm_slot, cm_idx;
reg [4:0] cm_len, cm_blen, cm_sh;
reg [7:0] cm_lbyte, cm_oact;
reg [15:0] cm_key, cm_msk;
"""

CM_BODY = r"""
cm_cfg = state_r[192];
cm_N = state_r[195:193];
cm_key = a[15:0];
cm_slot = a[2:0];
cm_idx = 3'd0;
cm_blen = 5'd0;
cm_oact = 8'd0;
cm_is_cfg = 1'b0;
cm_is_ins = 1'b0;
cm_is_hit = 1'b0;
cm_vr = 1'b0;
cm_found = 1'b0;
if (c[31]) begin
    cm_n = c[2:0];
    if (cm_n == 3'd0 || cm_n > 3'd6) begin
        f = 1'b1;
        x[2:0] = 3'd4;
    end else begin
        for (idx = 0; idx < 6; idx = idx + 1) begin
            state_n[(idx << 4) +: 16] = 16'd0;
            state_n[(96 + (idx << 3)) +: 8] = 8'd0;
            state_n[(144 + (idx << 3)) +: 8] = 8'd0;
        end
        state_n[195:193] = cm_n;
        state_n[192] = 1'b1;
        state_n[203:196] = 8'd0;
        state_n[211:204] = 8'd0;
        state_n[219:212] = 8'd0;
        state_n[223:220] = 4'd0;
        cm_N = cm_n;
        cm_is_cfg = 1'b1;
        cm_vr = 1'b1;
    end
end else if (!cm_cfg) begin
    f = 1'b1;
    x[2:0] = 3'd1;
end else if (c[0]) begin
    if (cm_slot >= cm_N) begin
        f = 1'b1;
        x[2:0] = 3'd2;
    end else begin
        i = cm_slot;
        cm_len = b[20:16];
        if (cm_len > 5'd16) cm_len = 5'd16;
        state_n[(i << 4) +: 16] = b[15:0];
        state_n[(96 + (i << 3)) +: 8] = {1'b1, 2'd0, cm_len};
        state_n[(144 + (i << 3)) +: 8] = b[28:21];
        if (state_r[203:196] != 8'hFF) state_n[203:196] = state_r[203:196] + 8'd1;
        cm_idx = cm_slot;
        cm_blen = cm_len;
        cm_oact = b[28:21];
        cm_is_ins = 1'b1;
        cm_vr = 1'b1;
    end
end else begin
    if (state_r[211:204] != 8'hFF) state_n[211:204] = state_r[211:204] + 8'd1;
    for (idx = 0; idx < 6; idx = idx + 1) begin
        if (idx < cm_N) begin
            cm_lbyte = state_r[(96 + (idx << 3)) +: 8];
            cm_len = cm_lbyte[4:0];
            cm_sh = 5'd16 - cm_len;
            cm_msk = 16'hffff << cm_sh;
            cm_vj = cm_lbyte[7];
            cm_mj = ((cm_key ^ state_r[(idx << 4) +: 16]) & cm_msk) == 16'd0;
            if (cm_vj && cm_mj && (!cm_found || (cm_len > cm_blen))) begin
                cm_found = 1'b1;
                cm_idx = idx[2:0];
                cm_blen = cm_len;
                cm_oact = state_r[(144 + (idx << 3)) +: 8];
            end
        end
    end
    if (cm_found) begin
        if (state_r[219:212] != 8'hFF) state_n[219:212] = state_r[219:212] + 8'd1;
        cm_is_hit = 1'b1;
        cm_vr = 1'b1;
    end else begin
        f = 1'b1;
        if (state_r[223:220] != 4'hF) state_n[223:220] = state_r[223:220] + 4'd1;
        x[3:0] = 4'd5;
        x[11:8] = state_n[223:220];
        x[19:12] = state_n[211:204];
    end
end
if (!f) begin
    r[2:0] = cm_idx;
    r[7:3] = cm_blen;
    r[15:8] = cm_oact;
    r[16] = cm_vr;
    r[19:17] = cm_N;
    r[20] = cm_is_cfg;
    r[21] = cm_is_ins;
    r[22] = cm_is_hit;
    x[7:0] = state_n[203:196];
    x[15:8] = state_n[211:204];
    x[23:16] = state_n[219:212];
    x[27:24] = state_n[223:220];
    x[28] = state_n[192];
end
"""

core('cam_match',
     'Six-entry prefix CAM with longest-prefix-match resolution. State: key j = '
     'state[(j*16) +: 16], length/valid j = state[(96+j*8) +: 8] with bit 7 valid and '
     'bits[4:0] the prefix length, action j = state[(144+j*8) +: 8], configured = '
     'state[192], entry count N = state[195:193], inserts = state[203:196], lookups = '
     'state[211:204], hits = state[219:212], misses = state[223:220]. Configure/'
     'restart beat (c[31]=1) takes N from c[2:0], which must be 1..6 (else cause 4, '
     'state untouched); it clears every entry, resets all four counters and sets '
     'configured. Insert beat (c[31]=0, c[0]=1): slot = a[2:0] must be < N (else cause '
     '2), key = b[15:0], prefix length = b[20:16] clamped to 16, action = b[28:21], '
     'and the slot is marked valid; the insert count is taken. Lookup beat (c[31]=0, '
     'c[0]=0): key = a[15:0]; every valid entry below N is compared in parallel, an '
     'entry matches when (key XOR entry-key) masked to the top prefix-length bits is '
     'zero (a length-0 entry matches every key), the longest match wins and ties go to '
     'the lowest index; a hit takes the lookup and hit counters, a miss is cause 5 and '
     'takes the lookup and miss counters. Fault causes: 1 = insert or lookup before '
     'configure, 2 = insert into a slot at or above N, 4 = N outside 1..6 on configure, '
     '5 = no entry matched; a faulting beat gives result = 0 and aux[3:0] = the cause, '
     'and only the counters named above move. Otherwise result: [2:0]=matched or '
     'inserted slot (0 on configure), [7:3]=prefix length, [15:8]=action, [16]=beat '
     'referenced an entry, [19:17]=N, [20]=configure, [21]=insert, [22]=lookup hit. '
     'aux: [7:0]=inserts, [15:8]=lookups, [23:16]=hits, [27:24]=misses, [28]=configured.',
     CM_BODY,
     'Six parallel prefix compares, their programmable masks and the longest-match '
     'priority encoder resolve inside one enabled beat at II=1, and the key array '
     'infers into block RAM for a deterministic single-cycle LPM that does not grow '
     'with table size, whereas a software LPM table is a linear shift-mask-compare '
     'loop whose latency scales with the number of prefixes.',
     6, decl=CM_DECL)


def _cam_match(a, b, c, st):
    cfg = bits(st, CM_CFG, 1)
    N = bits(st, CM_N, 3)
    key = a & 0xFFFF
    slot = a & 7
    idx = blen = oact = 0
    is_cfg = is_ins = is_hit = vr = 0
    ns = st
    if c >> 31:
        n = c & 7
        if n == 0 or n > 6:
            return 0, 4, 1, st
        for j in range(6):
            ns = poke(ns, j << 4, 16, 0)
            ns = poke(ns, 96 + (j << 3), 8, 0)
            ns = poke(ns, 144 + (j << 3), 8, 0)
        ns = poke(ns, CM_N, 3, n)
        ns = poke(ns, CM_CFG, 1, 1)
        ns = poke(ns, CM_INS, 8, 0)
        ns = poke(ns, CM_LKS, 8, 0)
        ns = poke(ns, CM_HIT, 8, 0)
        ns = poke(ns, CM_MIS, 4, 0)
        N = n
        is_cfg = vr = 1
    elif not cfg:
        return 0, 1, 1, st
    elif c & 1:
        if slot >= N:
            return 0, 2, 1, st
        ln = bits(b, 16, 5)
        if ln > 16:
            ln = 16
        ns = poke(ns, slot << 4, 16, b & 0xFFFF)
        ns = poke(ns, 96 + (slot << 3), 8, (1 << 7) | ln)
        ns = poke(ns, 144 + (slot << 3), 8, bits(b, 21, 8))
        if bits(st, CM_INS, 8) != 0xFF:
            ns = poke(ns, CM_INS, 8, bits(st, CM_INS, 8) + 1)
        idx = slot
        blen = ln
        oact = bits(b, 21, 8)
        is_ins = vr = 1
    else:
        if bits(st, CM_LKS, 8) != 0xFF:
            ns = poke(ns, CM_LKS, 8, bits(st, CM_LKS, 8) + 1)
        found = False
        for j in range(N if N <= 6 else 0):
            lb = bits(st, 96 + (j << 3), 8)
            ln = lb & 0x1f
            msk = (0xFFFF << (16 - ln)) & 0xFFFF
            if (lb >> 7) and (((key ^ bits(st, j << 4, 16)) & msk) == 0) and \
               (not found or ln > blen):
                found = True
                idx = j
                blen = ln
                oact = bits(st, 144 + (j << 3), 8)
        if found:
            if bits(st, CM_HIT, 8) != 0xFF:
                ns = poke(ns, CM_HIT, 8, bits(st, CM_HIT, 8) + 1)
            is_hit = vr = 1
        else:
            if bits(st, CM_MIS, 4) != 0xF:
                ns = poke(ns, CM_MIS, 4, bits(st, CM_MIS, 4) + 1)
            xf = (5 | (bits(ns, CM_MIS, 4) << 8) | (bits(ns, CM_LKS, 8) << 12)) & MASK
            return 0, xf, 1, ns & ALL256
    r = (idx | (blen << 3) | (oact << 8) | (vr << 16) | (N << 17)
         | (is_cfg << 20) | (is_ins << 21) | (is_hit << 22)) & MASK
    x = (bits(ns, CM_INS, 8) | (bits(ns, CM_LKS, 8) << 8) | (bits(ns, CM_HIT, 8) << 16)
         | (bits(ns, CM_MIS, 4) << 24) | (bits(ns, CM_CFG, 1) << 28)) & MASK
    return r, x, 0, ns & ALL256


_MODELS['cam_match'] = _cam_match


def _cam_rows():
    rows = [(0x1234, 0, 0)]                           # lookup before configure: cause 1
    rows.append((0, 0, 0x80000000))                   # N = 0 rejected: cause 4
    rows.append((0, 0, 0x80000000 | 7))               # N = 7 rejected: cause 4
    rows.append((0, 0, 0x80000000 | 6))               # configure N = 6 (restart)
    for slot, key, ln, ac in [(0, 0x0100, 16, 0x11), (1, 0x0A50, 8, 0x22),
                              (2, 0x0A00, 4, 0x33), (3, 0x1F00, 12, 0x44),
                              (4, 0x8000, 1, 0x55), (5, 0x0000, 0, 0x66)]:
        rows.append((slot, key | (ln << 16) | (ac << 21), 1))     # insert
    rows.append((6, 0, 1))                            # slot 6 >= N: cause 2
    # From here the table is never reconfigured, so the lookup and insert counters
    # climb monotonically and every beat therefore yields a fresh (r, x, f) triple.
    s = 0
    while len(rows) < BOARD:
        s += 1
        if s % 2:
            rows.append(((s * 0x9E37) & 0xffff, 0, 0))            # lookup (hit or miss)
        else:
            rows.append((s % 6, (0x1000 | (s & 0xffff)) | ((s % 17) << 16)
                         | (((s * 7) & 0xff) << 21), 1))          # insert
    return rows


_ROWS['cam_match'] = _cam_rows


# ===========================================================================
# 5  tlb8_lookup -- 8-entry translation lookaside buffer, translate + permission
# ===========================================================================
# State map: entry k at bits [(k << 4) +: 16] with
#   vpn = e[15:8], ppn = e[7:4], perm = e[3:1] (R/W/X), valid = e[0]
#   k = 0..7 fills bits 0..127; control/counter fields live at 128..168.
TL_CFG = 128
TL_INS = 129     # [136:129] inserts accepted, saturates 255
TL_HIT = 137     # [144:137] translate hits, saturates 255
TL_MIS = 145     # [152:145] translate misses, saturates 255
TL_VIO = 153     # [160:153] permission violations, saturates 255
TL_LKS = 161     # [168:161] lookups attempted, saturates 255

TL_DECL = r"""
reg [15:0] tl_ent;
reg [7:0] tl_vpn, tl_ppn;
reg [2:0] tl_perm, tl_req, tl_slot;
reg tl_cfg, tl_fnd, tl_is_ins, tl_is_hit;
"""

TL_BODY = r"""
tl_cfg = state_r[128];
tl_fnd = 1'b0;
tl_is_ins = 1'b0;
tl_is_hit = 1'b0;
tl_ppn = 8'd0;
tl_perm = 3'd0;
tl_slot = 3'd0;
if (c[31]) begin
    for (i = 0; i < 8; i = i + 1) state_n[(i << 4) +: 16] = 16'd0;
    state_n[128] = 1'b1;
    state_n[136:129] = 8'd0;
    state_n[144:137] = 8'd0;
    state_n[152:145] = 8'd0;
    state_n[160:153] = 8'd0;
    state_n[168:161] = 8'd0;
end else if (!tl_cfg) begin
    f = 1'b1;
    x[3:0] = 4'd1;
    x[11:4] = state_r[136:129];
    x[19:12] = state_r[168:161];
end else if (c[0]) begin
    i = a[2:0];
    state_n[(i << 4) +: 16] = {a[15:8], b[3:0], b[6:4], 1'b1};
    if (state_r[136:129] != 8'hFF) state_n[136:129] = state_r[136:129] + 8'd1;
    tl_is_ins = 1'b1;
    tl_slot = a[2:0];
    tl_ppn = {4'd0, b[3:0]};
    tl_perm = b[6:4];
end else begin
    tl_vpn = a[7:0];
    tl_req = a[10:8];
    if (state_r[168:161] != 8'hFF) state_n[168:161] = state_r[168:161] + 8'd1;
    for (i = 0; i < 8; i = i + 1) begin
        tl_ent = state_r[(i << 4) +: 16];
        if (!tl_fnd && tl_ent[0] && (tl_ent[15:8] == tl_vpn)) begin
            tl_fnd = 1'b1;
            tl_slot = i[2:0];
            tl_ppn = {4'd0, tl_ent[7:4]};
            tl_perm = tl_ent[3:1];
        end
    end
    if (!tl_fnd) begin
        f = 1'b1;
        x[3:0] = 4'd2;
        if (state_r[152:145] != 8'hFF) state_n[152:145] = state_r[152:145] + 8'd1;
    end else if ((tl_req & ~tl_perm & 3'h7) != 3'd0) begin
        f = 1'b1;
        x[3:0] = 4'd3;
        if (state_r[160:153] != 8'hFF) state_n[160:153] = state_r[160:153] + 8'd1;
    end else begin
        tl_is_hit = 1'b1;
        if (state_r[144:137] != 8'hFF) state_n[144:137] = state_r[144:137] + 8'd1;
    end
end
if (!f) begin
    r[2:0] = tl_slot;
    r[7:4] = tl_ppn[3:0];
    r[10:8] = tl_perm;
    r[11] = tl_is_ins;
    r[12] = tl_is_hit;
    r[13] = 1'b1;
    x[3:0] = 4'd0;
    x[11:4] = state_n[136:129];
    x[19:12] = state_n[168:161];
    x[27:20] = state_n[144:137];
    x[31:28] = state_n[156:153];
end else begin
    x[11:4] = state_n[136:129];
    x[19:12] = state_n[168:161];
    x[27:20] = state_n[152:145];
    x[31:28] = state_n[156:153];
end
"""

core('tlb8_lookup',
     'Eight-entry translation lookaside buffer with parallel tag match and permission '
     'check. State: entry k = state[(k*16) +: 16] holding vpn = e[15:8], ppn = e[7:4], '
     'perm = e[3:1] (bit1 read, bit2 write, bit3 execute) and valid = e[0]; configured '
     '= state[128], inserts = state[136:129], hits = state[144:137], misses = '
     'state[152:145], permission violations = state[160:153], lookups = state[168:161] '
     '(all counters saturate at 255). Flush/restart beat (c[31]=1) invalidates all '
     'eight entries, clears every counter and sets configured. Insert beat (c[31]=0, '
     'c[0]=1): slot = a[2:0], vpn = a[15:8], ppn = b[3:0], perm = b[6:4], marks the '
     'entry valid and takes the insert counter. Lookup beat (c[31]=0, c[0]=0): key vpn '
     '= a[7:0], requested permission = a[10:8]; every valid entry compares in parallel, '
     'the lowest-index matching entry is used, the lookup counter is always taken, a '
     'hit takes the hit counter and returns ppn and the entry permission, a miss takes '
     'the miss counter, and a translation whose requested permission bits are not a '
     'subset of the entry permission is a violation, takes the violation counter and '
     'does not translate. Fault causes: 1 = insert or lookup before configure, 2 = no '
     'entry matched (TLB miss), 3 = permission violation; a faulting beat gives '
     'result = 0, aux[3:0] = the cause, and only the counters named above move. '
     'Otherwise result: [2:0]=slot, [7:4]=ppn, [10:8]=entry perm, [11]=insert beat, '
     '[12]=translate hit, [13]=configured. aux: [11:4]=inserts, [19:12]=lookups, '
     '[27:20]=hits (on success) or misses (on fault), [31:28]=violations low nibble.',
     TL_BODY,
     'All eight tag compares, the priority pick and the three-bit permission subset '
     'test run in one enabled beat, so a translation returns at II=1 with a fixed '
     'latency and the tag array infers into block RAM, whereas a software TLB walk is '
     'a serial compare loop with data-dependent branch latency that leaks the miss '
     'path.',
     8, decl=TL_DECL)


def _tlb8(a, b, c, st):
    cfg = bits(st, TL_CFG, 1)
    ns = st
    slot = ppn = perm = 0
    is_ins = is_hit = 0
    if c >> 31:
        for i in range(8):
            ns = poke(ns, i << 4, 16, 0)
        ns = poke(ns, TL_CFG, 1, 1)
        for base, w in [(TL_INS, 8), (TL_HIT, 8), (TL_MIS, 8), (TL_VIO, 8), (TL_LKS, 8)]:
            ns = poke(ns, base, w, 0)
    elif not cfg:
        x = (1 | (bits(st, TL_INS, 8) << 4) | (bits(st, TL_LKS, 8) << 12)) & MASK
        return 0, x, 1, st
    elif c & 1:
        s = a & 7
        ent = (((a >> 8) & 0xff) << 8) | ((b & 0xf) << 4) | ((bits(b, 4, 3)) << 1) | 1
        ns = poke(ns, s << 4, 16, ent)
        if bits(st, TL_INS, 8) != 0xFF:
            ns = poke(ns, TL_INS, 8, bits(st, TL_INS, 8) + 1)
        slot = s
        ppn = b & 0xf
        perm = bits(b, 4, 3)
        is_ins = 1
    else:
        vpn = a & 0xff
        req = bits(a, 8, 3)
        if bits(st, TL_LKS, 8) != 0xFF:
            ns = poke(ns, TL_LKS, 8, bits(st, TL_LKS, 8) + 1)
        fnd = False
        for i in range(8):
            e = bits(st, i << 4, 16)
            if (e & 1) and ((e >> 8) & 0xff) == vpn:
                fnd = True
                slot = i
                ppn = (e >> 4) & 0xf
                perm = (e >> 1) & 7
                break
        if not fnd:
            if bits(st, TL_MIS, 8) != 0xFF:
                ns = poke(ns, TL_MIS, 8, bits(st, TL_MIS, 8) + 1)
            x = (2 | (bits(ns, TL_INS, 8) << 4) | (bits(ns, TL_LKS, 8) << 12)
                 | (bits(ns, TL_MIS, 8) << 20) | ((bits(ns, TL_VIO, 8) & 0xf) << 28)) & MASK
            return 0, x, 1, ns & ALL256
        if (req & ~perm & 7):
            if bits(st, TL_VIO, 8) != 0xFF:
                ns = poke(ns, TL_VIO, 8, bits(st, TL_VIO, 8) + 1)
            x = (3 | (bits(ns, TL_INS, 8) << 4) | (bits(ns, TL_LKS, 8) << 12)
                 | (bits(ns, TL_MIS, 8) << 20) | ((bits(ns, TL_VIO, 8) & 0xf) << 28)) & MASK
            return 0, x, 1, ns & ALL256
        if bits(st, TL_HIT, 8) != 0xFF:
            ns = poke(ns, TL_HIT, 8, bits(st, TL_HIT, 8) + 1)
        is_hit = 1
    r = (slot | (ppn << 4) | (perm << 8) | (is_ins << 11) | (is_hit << 12)
         | (1 << 13)) & MASK
    x = (0 | (bits(ns, TL_INS, 8) << 4) | (bits(ns, TL_LKS, 8) << 12)
         | (bits(ns, TL_HIT, 8) << 20) | ((bits(ns, TL_VIO, 8) & 0xf) << 28)) & MASK
    return r, x, 0, ns & ALL256


_MODELS['tlb8_lookup'] = _tlb8


def _tlb_rows():
    rows = [(0x10, 0, 0)]                             # lookup before configure: cause 1
    rows.append((0, 0, 0x80000000))                   # flush / restart
    # Load a spread of entries (each insert bumps the insert counter).
    for s, vpn, ppn, perm in [(0, 0x10, 0x5, 0b111), (1, 0x20, 0x3, 0b101),
                              (2, 0x30, 0xA, 0b010), (3, 0x10, 0x7, 0b001),
                              (4, 0x40, 0xC, 0b110), (5, 0x50, 0x1, 0b111)]:
        rows.append((s | (vpn << 8), (perm << 4) | ppn, 1))
    rows.append((0x10 | (1 << 8), 0, 0))              # hit slot0 read
    rows.append((0x20 | (2 << 8), 0, 0))              # hit slot1 read+exec
    rows.append((0x30 | (2 << 8), 0, 0))              # hit slot2 write-only
    rows.append((0x40 | (3 << 8), 0, 0))              # violation: slot4 perm 110 needs 001
    rows.append((0x99, 0, 0))                         # miss: cause 2
    s = 0
    while len(rows) < BOARD:
        s += 1
        if s % 2:
            rows.append(((((s * 0x2B) & 0xff) | (bits_(s, 8, 3) << 8)), 0, 0))  # lookup
        else:
            rows.append(((s % 8) | (((s * 13) & 0xff) << 8),
                         (((s % 7) << 4) | (s & 0xf)), 1))                       # insert
    return rows


def bits_(value, pos, width):
    return (value >> pos) & ((1 << width) - 1)


_ROWS['tlb8_lookup'] = _tlb_rows


# ===========================================================================
# 6  bank_alloc -- best-fit allocator over 16 variable-size banks
# ===========================================================================
# State map: free size of bank j at bits [(j << 3) +: 8] (j = 0..15, bits 0..127),
#   configured = state[128], allocations = state[136:129], releases = state[144:137],
#   no-fit faults = state[148:145], last bank = state[152:149].
BA_CFG = 128
BA_ALC = 129
BA_REL = 137
BA_NOF = 145
BA_LBK = 149
BA_SEQ = 153

BA_DECL = r"""
reg [7:0] ba_cur, ba_new, ba_req, ba_sz, ba_best, ba_max;
reg [3:0] ba_slot, ba_besti;
reg [11:0] ba_seq;
reg ba_cfg, ba_fnd;
"""

BA_BODY = r"""
ba_cfg = state_r[128];
ba_req = b[7:0];
ba_slot = a[3:0];
ba_fnd = 1'b0;
ba_best = 8'd255;
ba_besti = 4'd0;
if (c[31]) begin
    for (i = 0; i < 16; i = i + 1) state_n[(i << 3) +: 8] = a[7:0] + i[7:0];
    state_n[128] = 1'b1;
    state_n[136:129] = 8'd0;
    state_n[144:137] = 8'd0;
    state_n[148:145] = 4'd0;
    state_n[152:149] = 4'd0;
    r[30] = 1'b1;
    r[31] = 1'b1;
end else if (!ba_cfg) begin
    f = 1'b1;
    r[3:0] = 4'd1;
end else if (c[0]) begin
    j = ba_slot;
    ba_cur = state_r[(j << 3) +: 8];
    ext = {24'd0, ba_cur} + {24'd0, ba_req};
    ba_new = (ext > 33'd255) ? 8'hFF : ext[7:0];
    state_n[(j << 3) +: 8] = ba_new;
    if (state_r[144:137] != 8'hFF) state_n[144:137] = state_r[144:137] + 8'd1;
    state_n[152:149] = ba_slot;
    r[3:0] = ba_slot;
    r[11:4] = ba_cur;
    r[19:12] = ba_new;
    r[27:20] = ba_req;
    r[29] = 1'b1;
    r[31] = 1'b1;
end else begin
    for (i = 0; i < 16; i = i + 1) begin
        ba_sz = state_r[(i << 3) +: 8];
        if ((ba_sz >= ba_req) && (!ba_fnd || (ba_sz < ba_best))) begin
            ba_fnd = 1'b1;
            ba_best = ba_sz;
            ba_besti = i[3:0];
        end
    end
    if (!ba_fnd) begin
        f = 1'b1;
        r[3:0] = 4'd2;
        if (state_r[148:145] != 4'hF) state_n[148:145] = state_r[148:145] + 4'd1;
    end else begin
        ba_new = ba_best - ba_req;
        j = ba_besti;
        state_n[(j << 3) +: 8] = ba_new;
        if (state_r[136:129] != 8'hFF) state_n[136:129] = state_r[136:129] + 8'd1;
        state_n[152:149] = ba_besti;
        r[3:0] = ba_besti;
        r[11:4] = ba_best;
        r[19:12] = ba_new;
        r[27:20] = ba_req;
        r[28] = 1'b1;
        r[31] = 1'b1;
    end
end
ba_seq = state_r[164:153] + 12'd1;
state_n[164:153] = ba_seq;
ba_max = 8'd0;
for (i = 0; i < 16; i = i + 1) begin
    if (state_n[(i << 3) +: 8] > ba_max) ba_max = state_n[(i << 3) +: 8];
end
x[11:0] = ba_seq;
x[15:12] = state_n[148:145];
x[19:16] = state_n[152:149];
x[27:20] = ba_max;
"""


core('bank_alloc',
     'best-fit allocator over 16 variable-size banks: configure sizes, allocate the '
     'smallest bank that fits the request, release space back, count no-fit faults',
     BA_BODY,
     'all 16 bank sizes are scanned in one parallel combinational pass so best-fit '
     'arbitration is deterministic and cycle-accurate in a single clock with no '
     'multiplier: the only arithmetic is a carry-free saturating add through a 33-bit '
     'extension and bank indexing is a shift by 3, so the bank table maps straight onto '
     'an inferred BRAM register file',
     1, decl=BA_DECL)


def _bank_alloc(a, b, c, st):
    cfg = bits(st, BA_CFG, 1)
    req = b & 0xff
    slot = a & 0xf
    ns = st
    if c >> 31:
        for i in range(16):
            ns = poke(ns, i << 3, 8, (a + i) & 0xff)
        ns = poke(ns, BA_CFG, 1, 1)
        ns = poke(ns, BA_ALC, 8, 0)
        ns = poke(ns, BA_REL, 8, 0)
        ns = poke(ns, BA_NOF, 4, 0)
        ns = poke(ns, BA_LBK, 4, 0)
        r = (1 << 30) | (1 << 31)
    elif not cfg:
        ns = st
        r = 1
        f = 1
    elif c & 1:
        cur = bits(st, slot << 3, 8)
        new = 255 if (cur + req) > 255 else (cur + req)
        ns = poke(ns, slot << 3, 8, new)
        rel = bits(st, BA_REL, 8)
        if rel != 0xFF:
            ns = poke(ns, BA_REL, 8, rel + 1)
        ns = poke(ns, BA_LBK, 4, slot)
        r = (slot | (cur << 4) | (new << 12) | (req << 20) | (1 << 29) |
             (1 << 31)) & MASK
        f = 0
    else:
        best = 255
        besti = 0
        fnd = False
        for i in range(16):
            sz = bits(st, i << 3, 8)
            if sz >= req and (not fnd or sz < best):
                fnd = True
                best = sz
                besti = i
        if not fnd:
            nf = bits(st, BA_NOF, 4)
            if nf != 0xF:
                ns = poke(ns, BA_NOF, 4, nf + 1)
            r = 2
            f = 1
        else:
            new = best - req
            ns = poke(ns, besti << 3, 8, new)
            alc = bits(st, BA_ALC, 8)
            if alc != 0xFF:
                ns = poke(ns, BA_ALC, 8, alc + 1)
            ns = poke(ns, BA_LBK, 4, besti)
            r = (besti | (best << 4) | (new << 12) | (req << 20) | (1 << 28) |
                 (1 << 31)) & MASK
            f = 0
    seq = (bits(st, BA_SEQ, 12) + 1) & 0xfff
    ns = poke(ns, BA_SEQ, 12, seq)
    mx = 0
    for i in range(16):
        v = bits(ns, i << 3, 8)
        if v > mx:
            mx = v
    x = (seq | (bits(ns, BA_NOF, 4) << 12) | (bits(ns, BA_LBK, 4) << 16) |
         (mx << 20)) & MASK
    if c >> 31:
        f = 0
    return r, x, f, ns & ALL256


_MODELS['bank_alloc'] = _bank_alloc


def _bank_rows():
    rows = []
    rows.append((0, 10, 0))                  # alloc before config -> cause 1 fault
    rows.append((0x40, 0, 0x80000000))       # config: bank[i] = 0x40 + i (64..79)
    rows.append((0, 255, 0))                 # alloc 255 -> no-fit cause 2 fault
    reqs = (3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59,
            61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127)
    k = 0
    while len(rows) < BOARD:
        rows.append((0, reqs[k % len(reqs)], 0))        # best-fit alloc
        k += 1
        if len(rows) >= BOARD:
            break
        rows.append((k % 16, 24 + (k % 5), 1))          # release space back to a bank
        k += 1
        if len(rows) >= BOARD:
            break
        if k % 11 == 0:
            rows.append((0, 240 + (k % 16), 0))         # oversized request -> no-fit
            k += 1
    return rows


_ROWS['bank_alloc'] = _bank_rows


# ===========================================================================
# 7  ecc72_gen -- SECDED(72,64) memory ECC: encode, single-correct, double-detect
# ===========================================================================
# A systematic (72,64) Hamming code plus one overall-parity bit.  The 64 data bits
# arrive as {b, a}; check bit k is the XOR-fold of a fixed data mask (the k-th row of
# the parity-check matrix), and check bit 7 is the parity of the whole 72-bit word.
# Encoding needs only AND and reduction XOR -- no multiplier -- and the bank of data
# lives in the state word so verify reads it back synchronously.
EC_CFG = 72
EC_SEQ = 73      # 12 bits
EC_SYN = 85      # 8 bits
EC_LOAD = 93     # 8 bits
EC_SIN = 101     # 4 bits
EC_DBL = 105     # 4 bits

# rows of H over the 64 data bits: bit i set when column(i) has bit k (see selftest)
EC_MASK = [0xab55555556aaad5b, 0xcd9999999b33366d, 0xf1e1e1e1e3c3c78e,
           0x01fe01fe03fc07f0, 0x01fffe0003fff800, 0x01fffffffc000000,
           0xfe00000000000000]

EC_DECL = r"""
reg [63:0] ecc_d;
reg [7:0] ecc_chk, ecc_syn, ecc_rc;
reg ecc_cfg;
reg [11:0] ecc_seq;
localparam [63:0] EC_M0 = 64'hab55555556aaad5b;
localparam [63:0] EC_M1 = 64'hcd9999999b33366d;
localparam [63:0] EC_M2 = 64'hf1e1e1e1e3c3c78e;
localparam [63:0] EC_M3 = 64'h01fe01fe03fc07f0;
localparam [63:0] EC_M4 = 64'h01fffe0003fff800;
localparam [63:0] EC_M5 = 64'h01fffffffc000000;
localparam [63:0] EC_M6 = 64'hfe00000000000000;
"""

EC_BODY = r"""
ecc_cfg = state_r[72];
ecc_d = {b, a};
if (c[31]) begin
    ecc_chk[0] = ^(ecc_d & EC_M0);
    ecc_chk[1] = ^(ecc_d & EC_M1);
    ecc_chk[2] = ^(ecc_d & EC_M2);
    ecc_chk[3] = ^(ecc_d & EC_M3);
    ecc_chk[4] = ^(ecc_d & EC_M4);
    ecc_chk[5] = ^(ecc_d & EC_M5);
    ecc_chk[6] = ^(ecc_d & EC_M6);
    ecc_chk[7] = (^ecc_d) ^ ^(ecc_chk[6:0]);
    state_n[63:0] = ecc_d;
    state_n[71:64] = ecc_chk;
    state_n[72] = 1'b1;
    if (state_r[100:93] != 8'hFF) state_n[100:93] = state_r[100:93] + 8'd1;
    r[7:0] = ecc_chk;
    r[16] = 1'b1;
end else if (!ecc_cfg) begin
    f = 1'b1;
    r[3:0] = 4'd1;
end else begin
    ecc_rc = c[7:0];
    ecc_syn[0] = ^(ecc_d & EC_M0) ^ ecc_rc[0];
    ecc_syn[1] = ^(ecc_d & EC_M1) ^ ecc_rc[1];
    ecc_syn[2] = ^(ecc_d & EC_M2) ^ ecc_rc[2];
    ecc_syn[3] = ^(ecc_d & EC_M3) ^ ecc_rc[3];
    ecc_syn[4] = ^(ecc_d & EC_M4) ^ ecc_rc[4];
    ecc_syn[5] = ^(ecc_d & EC_M5) ^ ecc_rc[5];
    ecc_syn[6] = ^(ecc_d & EC_M6) ^ ecc_rc[6];
    ecc_syn[7] = (^ecc_d) ^ ^(ecc_rc[6:0]) ^ ecc_rc[7];
    state_n[92:85] = ecc_syn;
    r[7:0] = ecc_syn;
    r[11] = 1'b1;
    if (ecc_syn == 8'd0) begin
        r[8] = 1'b1;
    end else if (ecc_syn[7]) begin
        r[9] = 1'b1;
        if (state_r[104:101] != 4'hF) state_n[104:101] = state_r[104:101] + 4'd1;
    end else begin
        r[10] = 1'b1;
        f = 1'b1;
        if (state_r[108:105] != 4'hF) state_n[108:105] = state_r[108:105] + 4'd1;
    end
end
ecc_seq = state_r[84:73] + 12'd1;
state_n[84:73] = ecc_seq;
x[11:0] = ecc_seq;
x[19:12] = state_n[92:85];
x[23:20] = state_n[104:101];
x[27:24] = state_n[108:105];
"""


core('ecc72_gen',
     'SECDED(72,64) memory ECC: encode 64 data bits into 8 check bits, verify a '
     'received 72-bit word, correct a single-bit error and flag a double-bit error',
     EC_BODY,
     'the 8 syndromes are produced by eight parallel AND/reduction-XOR trees over one '
     '64-bit data word, so SECDED encode and decode finish in a single cycle with no '
     'multiplier: every fold is carry-free XOR and the only arithmetic is a +1 counter, '
     'letting the data word and its check bits be inferred straight into a BRAM ECC row',
     1, decl=EC_DECL)


def _ecc72(a, b, c, st):
    d = (((b & MASK) << 32) | (a & MASK)) & ((1 << 64) - 1)
    cfg = bits(st, EC_CFG, 1)
    ns = st
    if c >> 31:
        chk = 0
        for k in range(7):
            chk |= (bin(d & EC_MASK[k]).count('1') & 1) << k
        p7 = (bin(d).count('1') & 1) ^ (bin(chk & 0x7f).count('1') & 1)
        chk |= (p7 & 1) << 7
        ns = poke(ns, 0, 64, d)
        ns = poke(ns, 64, 8, chk)
        ns = poke(ns, EC_CFG, 1, 1)
        lc = bits(st, EC_LOAD, 8)
        if lc != 0xFF:
            ns = poke(ns, EC_LOAD, 8, lc + 1)
        r = (chk | (1 << 16)) & MASK
        f = 0
    elif not cfg:
        r = 1
        f = 1
    else:
        rc = c & 0xff
        syn = 0
        for k in range(7):
            syn |= ((bin(d & EC_MASK[k]).count('1') & 1) ^ ((rc >> k) & 1)) << k
        par = ((bin(d).count('1') & 1) ^ (bin(rc & 0x7f).count('1') & 1)
               ^ ((rc >> 7) & 1))
        syn |= (par & 1) << 7
        ns = poke(ns, EC_SYN, 8, syn)
        if syn == 0:
            r = (syn | (1 << 8) | (1 << 11)) & MASK
            f = 0
        elif (syn >> 7) & 1:
            r = (syn | (1 << 9) | (1 << 11)) & MASK
            f = 0
            sc = bits(st, EC_SIN, 4)
            if sc != 0xF:
                ns = poke(ns, EC_SIN, 4, sc + 1)
        else:
            r = (syn | (1 << 10) | (1 << 11)) & MASK
            f = 1
            dc = bits(st, EC_DBL, 4)
            if dc != 0xF:
                ns = poke(ns, EC_DBL, 4, dc + 1)
    seq = (bits(st, EC_SEQ, 12) + 1) & 0xfff
    ns = poke(ns, EC_SEQ, 12, seq)
    x = (seq | (bits(ns, EC_SYN, 8) << 12) | (bits(ns, EC_SIN, 4) << 20) |
         (bits(ns, EC_DBL, 4) << 24)) & MASK
    return r, x, f, ns & ALL256


_MODELS['ecc72_gen'] = _ecc72


def _ecc_encode(w):
    chk = 0
    for k in range(7):
        chk |= (bin(w & EC_MASK[k]).count('1') & 1) << k
    p7 = (bin(w).count('1') & 1) ^ (bin(chk & 0x7f).count('1') & 1)
    return chk | ((p7 & 1) << 7)


def _ecc_rows():
    rows = []
    d0 = 0x1122334455667788
    a0 = d0 & MASK
    b0 = (d0 >> 32) & MASK
    rows.append((a0, b0, 0))                          # verify before load -> fault
    rows.append((a0, b0, 0x80000000))                 # load d0
    ch = _ecc_encode(d0)
    rows.append((a0, b0, ch))                         # clean verify
    rows.append(((a0 ^ (1 << 5)) & MASK, b0, ch))      # single-bit error -> correct
    rows.append(((a0 ^ (1 << 5) ^ (1 << 6)) & MASK, b0, ch))  # double -> DED fault
    k = 0
    while len(rows) < BOARD:
        w = ((k + 1) * 0x0202020202020202) & ((1 << 64) - 1)
        aa = w & MASK
        bb = (w >> 32) & MASK
        rows.append((aa, bb, 0x80000000))             # load a new word
        if len(rows) >= BOARD:
            break
        c2 = _ecc_encode(w)
        if k % 3 == 0:
            rows.append((aa, bb, c2))                 # clean
        elif k % 3 == 1:
            rows.append(((aa ^ 1) & MASK, bb, c2))     # single-bit error
        else:
            rows.append(((aa ^ 1) & MASK,
                         (bb ^ (1 << (k & 31))) & MASK, c2))  # double-bit -> DED
        k += 1
    return rows


_ROWS['ecc72_gen'] = _ecc_rows


# ===========================================================================
# 8  march_engine -- March C- walking-bit memory test over a shadow cell array
# ===========================================================================
# Eight 8-bit cells live at bits [8k +: 8], so a beat indexes the array with a
# variable shift of 8*addr, never with a multiply.
MA_MEM = 0             # [63:0]    8 test cells
MA_PAT = 64            # [71:64]   data pattern byte
MA_CFG = 72            # [72]      configured by a restart beat
MA_EL = 73             # [75:73]   March element 0..4
MA_ADDR = 76           # [78:76]   cell address 0..7
MA_PHASE = 79          # [79]      phase inside the element, 0 or 1
MA_ERR = 80            # [83:80]   mismatch count, saturates 15
MA_FAILA = 84          # [86:84]   address of the first mismatch
MA_FAILV = 87          # [87]      that address is valid
MA_DONE = 88           # [88]      the whole March run finished
MA_OPS = 89            # [96:89]   ops accepted since restart, saturates 255
MA_WR = 97             # [104:97]  writes performed, saturates 255
MA_RD = 105            # [112:105] reads checked, saturates 255
MA_SEQ = 113           # [124:113] free-running beat sequence

# March C-:  up(w0) up(r0,w1) down(r1,w0) down(r0,w1) down(r1).
# Each element is two phases; kind 0 = write, 1 = read, 2 = no-ops the phase.
MA_OPS_TBL = ((0, 2), (1, 0), (1, 0), (1, 0), (1, 2))
# want[el][ph] is 1 exactly where RTL ma_val(e, ph) returns 1'b1, the {W1, R1}
# phases 3, 4, 7 and 8.  Read phases are don't-cares listed anyway.
MA_VAL_TBL = ((0, 0), (0, 1), (1, 0), (0, 1), (1, 0))
MA_ASC = (1, 1, 0, 0, 0)

MA_DECL = r"""
localparam [1:0] MA_KW = 2'd0, MA_KR = 2'd1, MA_KN = 2'd2;
function [1:0] ma_kind;
    input [2:0] e;
    input ph;
    begin
        case ({e, ph})
            4'd0: ma_kind = 2'd0;
            4'd1: ma_kind = 2'd2;
            4'd2: ma_kind = 2'd1;
            4'd3: ma_kind = 2'd0;
            4'd4: ma_kind = 2'd1;
            4'd5: ma_kind = 2'd0;
            4'd6: ma_kind = 2'd1;
            4'd7: ma_kind = 2'd0;
            4'd8: ma_kind = 2'd1;
            4'd9: ma_kind = 2'd2;
            default: ma_kind = 2'd2;
        endcase
    end
endfunction
function [0:0] ma_val;
    input [2:0] e;
    input ph;
    begin
        case ({e, ph})
            4'd3: ma_val = 1'b1;
            4'd4: ma_val = 1'b1;
            4'd7: ma_val = 1'b1;
            4'd8: ma_val = 1'b1;
            default: ma_val = 1'b0;
        endcase
    end
endfunction
function [0:0] ma_asc;
    input [2:0] e;
    begin
        ma_asc = (e < 3'd2) ? 1'b1 : 1'b0;
    end
endfunction
reg [2:0] ma_el, ma_ad, ma_nel, ma_nad;
reg [1:0] ma_k;
reg ma_ph, ma_np, ma_up, ma_want, ma_bad, ma_fin, ma_wrap;
reg [7:0] ma_pat, ma_cell, ma_obs, ma_wb, ma_exp;
reg [3:0] ma_err;
reg [7:0] ma_ops, ma_wr, ma_rd;
reg [11:0] ma_seq;
"""

MA_BODY = r"""
ma_el = state_r[75:73];
ma_ad = state_r[78:76];
ma_ph = state_r[79];
ma_pat = state_r[71:64];
ma_err = state_r[83:80];
ma_seq = state_r[124:113] + 12'd1;
if (c[31]) begin
    state_n = 256'd0;
    state_n[71:64] = a[7:0];
    state_n[72] = 1'b1;
    state_n[124:113] = ma_seq;
    r = {1'b0, 1'b1, 22'd0, a[7:0]};
    x = {a[7:0], ma_pat, 8'd0, ma_seq[7:0]};
end else if (!state_r[72]) begin
    f = 1'b1;
    x = 32'd1;
end else if (state_r[88]) begin
    f = 1'b1;
    x = 32'd2;
end else begin
    case (ma_ad)
        3'd0: ma_cell = state_r[7:0];
        3'd1: ma_cell = state_r[15:8];
        3'd2: ma_cell = state_r[23:16];
        3'd3: ma_cell = state_r[31:24];
        3'd4: ma_cell = state_r[39:32];
        3'd5: ma_cell = state_r[47:40];
        3'd6: ma_cell = state_r[55:48];
        default: ma_cell = state_r[63:56];
    endcase
    ma_k = ma_kind(ma_el, ma_ph);
    ma_want = ma_val(ma_el, ma_ph);
    ma_exp = ma_want ? (~ma_pat) : ma_pat;
    ma_up = ma_asc(ma_el);
    ma_bad = 1'b0;
    ma_obs = 8'd0;
    if (ma_k == 2'd0) begin
        ma_obs = ma_exp;
        wide = state_r[63:0];
        wide2 = {56'd0, ma_exp} << {ma_ad, 3'd0};
        wide = wide & ~(64'hFF << {ma_ad, 3'd0});
        state_n[63:0] = wide | wide2;
        if (state_r[104:97] != 8'hFF) state_n[104:97] = state_r[104:97] + 8'd1;
    end else if (ma_k == 2'd1) begin
        ma_obs = b[7:0];
        if (ma_obs != ma_cell) begin
            ma_bad = 1'b1;
            if (ma_err != 4'hF) state_n[83:80] = ma_err + 4'd1;
            if (!state_r[87]) begin
                state_n[87] = 1'b1;
                state_n[86:84] = ma_ad;
            end
        end
        if (state_r[112:105] != 8'hFF) state_n[112:105] = state_r[112:105] + 8'd1;
    end
    state_n[72] = 1'b1;
    state_n[71:64] = ma_pat;
    if (state_r[96:89] != 8'hFF) state_n[96:89] = state_r[96:89] + 8'd1;
    ma_np = ~ma_ph;
    ma_nad = ma_ad;
    ma_nel = ma_el;
    ma_fin = 1'b0;
    if (ma_ph) begin
        ma_wrap = (ma_up && (ma_ad == 3'd7)) || (!ma_up && (ma_ad == 3'd0));
        if (ma_wrap) begin
            ma_nel = ma_el + 3'd1;
            if (ma_nel > 3'd4) begin
                ma_fin = 1'b1;
                ma_nel = 3'd4;
                ma_nad = ma_ad;
                state_n[88] = 1'b1;
            end else begin
                ma_nad = ma_asc(ma_nel) ? 3'd0 : 3'd7;
            end
        end else begin
            ma_nad = ma_up ? (ma_ad + 3'd1) : (ma_ad - 3'd1);
        end
    end
    if (!ma_fin) state_n[79] = ma_np;
    state_n[78:76] = ma_nad;
    state_n[75:73] = ma_nel;
    state_n[124:113] = ma_seq;
    r[7:0] = ma_obs;
    r[10:8] = ma_ad;
    r[13:11] = ma_el;
    r[14] = ~ma_up;
    r[15] = ma_ph;
    r[19:16] = ma_bad ? (ma_err + 4'd1) : ma_err;
    r[20] = ma_fin;
    r[23:21] = ma_nel;
    r[26:24] = ma_nad;
    r[27] = (ma_k == 2'd1);
    r[28] = (ma_k == 2'd0);
    r[29] = (ma_k == 2'd2);
    x[7:0] = (state_r[96:89] == 8'hFF) ? 8'hFF : (state_r[96:89] + 8'd1);
    x[15:8] = state_n[104:97];
    x[23:16] = state_n[112:105];
    x[26:24] = state_n[86:84];
    x[27] = state_n[87];
    x[28] = 1'b1;
    f = ma_bad;
end
"""


def _march_engine(a, b, c, st):
    el = bits(st, MA_EL, 3)
    addr = bits(st, MA_ADDR, 3)
    ph = bits(st, MA_PHASE, 1)
    pat = bits(st, MA_PAT, 8)
    err = bits(st, MA_ERR, 4)
    seq = (bits(st, MA_SEQ, 12) + 1) & 0xFFF
    if c >> 31:
        ns = poke(poke(poke(0, MA_PAT, 8, a & 0xFF), MA_CFG, 1, 1), MA_SEQ, 12, seq)
        r = (1 << 30) | (a & 0xFF)
        x = ((a & 0xFF) << 24) | (pat << 16) | (seq & 0xFF)
        return r & MASK, x & MASK, 0, ns & ALL256
    if not bits(st, MA_CFG, 1):
        return 0, 1, 1, st
    if bits(st, MA_DONE, 1):
        return 0, 2, 1, st
    kind = MA_OPS_TBL[el][ph]
    want = MA_VAL_TBL[el][ph]
    cell = bits(st, MA_MEM + 8 * addr, 8)
    exp = (~pat & 0xFF) if want else pat
    ns = st
    bad = 0
    obs = 0
    if kind == 0:
        ns = poke(ns, MA_MEM + 8 * addr, 8, exp)
        obs = exp
        wr = bits(st, MA_WR, 8)
        if wr != 0xFF:
            ns = poke(ns, MA_WR, 8, wr + 1)
    elif kind == 1:
        obs = b & 0xFF
        if obs != cell:
            bad = 1
            if err != 15:
                ns = poke(ns, MA_ERR, 4, err + 1)
            if not bits(st, MA_FAILV, 1):
                ns = poke(ns, MA_FAILV, 1, 1)
                ns = poke(ns, MA_FAILA, 3, addr)
        rd = bits(st, MA_RD, 8)
        if rd != 0xFF:
            ns = poke(ns, MA_RD, 8, rd + 1)
    ops = bits(st, MA_OPS, 8)
    nops = 0xFF if ops == 0xFF else ops + 1
    ns = poke(ns, MA_OPS, 8, nops)
    up = 1 if MA_ASC[el] else 0
    np = ph ^ 1
    nad, nel, fin = addr, el, 0
    if ph:
        wrapped = (addr == 7) if up else (addr == 0)
        if wrapped:
            nel = el + 1
            if nel > 4:
                fin, nel, nad = 1, 4, addr
                ns = poke(ns, MA_DONE, 1, 1)
            else:
                nad = 0 if MA_ASC[nel] else 7
        else:
            nad = (addr + 1) & 7 if up else (addr - 1) & 7
    if not fin:
        ns = poke(ns, MA_PHASE, 1, np)
    ns = poke(ns, MA_ADDR, 3, nad)
    ns = poke(ns, MA_EL, 3, nel)
    ns = poke(ns, MA_SEQ, 12, seq)
    r = (obs | (addr << 8) | (el << 11) | ((1 - up) << 14) | (ph << 15) |
         ((err + 1 if bad else err) << 16) | (fin << 20) | (nel << 21) |
         (nad << 24) | ((1 if kind == 1 else 0) << 27) |
         ((1 if kind == 0 else 0) << 28) | ((1 if kind == 2 else 0) << 29))
    x = (nops | (bits(ns, MA_WR, 8) << 8) | (bits(ns, MA_RD, 8) << 16) |
         (bits(ns, MA_FAILA, 3) << 24) | (bits(ns, MA_FAILV, 1) << 27) |
         (1 << 28))
    return r & MASK, x & MASK, bad, ns & ALL256


_MODELS['march_engine'] = _march_engine


def _march_rows():
    rows = []
    pat = 0x5A
    rows.append((pat, 0, 1 << 31))
    st = step('march_engine', pat, 0, 1 << 31, 0)[3]
    inj = {9, 33, 57, 91}
    k = 0
    while len(rows) < BOARD:
        cfg = bits(st, MA_CFG, 1)
        done = bits(st, MA_DONE, 1)
        if done:
            rows.append((0, 0, 0))            # a beat past done is refused
            st = step('march_engine', 0, 0, 0, st)[3]
        if not cfg or done:
            pat = (0x5A + 0x37 * (k + 1)) & 0xFF
            rows.append((pat, 0, 1 << 31))
            st = step('march_engine', pat, 0, 1 << 31, st)[3]
            k += 1
            continue
        el = bits(st, MA_EL, 3)
        addr = bits(st, MA_ADDR, 3)
        ph = bits(st, MA_PHASE, 1)
        b = 0
        if MA_OPS_TBL[el][ph] == 1:
            b = bits(st, MA_MEM + 8 * addr, 8)
            if len(rows) in inj:
                b ^= 0x01
        rows.append((0, b, 0))
        st = step('march_engine', 0, b, 0, st)[3]
    return rows


_ROWS['march_engine'] = _march_rows


core('march_engine',
    'March C- memory BIST engine: one address-cell operation per beat over an '
    '8-cell shadow array with ascending and descending elements, mismatch '
    'counting, first-failing-address capture and a done/refuse contract',
    MA_BODY,
    'A March C- sweep needs 80 address-cell operations and every one of them is '
    'read-compare-write against a known pattern, so the fabric runs the whole test '
    'at one operation per cycle with a 64-bit cell array in registers: the compare '
    'is an 8-bit XOR reduction and the only arithmetic left is saturating counters, '
    'which is what lets the BIST engine sit beside a BRAM and test it in place',
    1, decl=MA_DECL)


# ===========================================================================
# 9  addr_scramble -- invertible address permutation for bank-conflict scrambling
# ===========================================================================
AS_KEY = 0             # [31:0]    32-bit scramble key
AS_CFG = 32            # [32]      configured
AS_ERR = 33            # [36:33]   compare or round-trip failures, saturates 15
AS_LAST = 37           # [68:37]   last transform result
AS_MODE = 69           # [70:69]   mode captured at restart
AS_OPS = 71            # [78:71]   transforms performed since restart, saturates 255
AS_SC = 79             # [86:79]   scramble legs, saturates 255
AS_UN = 87             # [94:87]   unscramble legs, saturates 255
AS_SEQ = 95            # [106:95]  free-running beat sequence
AS_FAILA = 107         # [138:107] address of the first failure
AS_FAILV = 139         # [139]     that address is valid


def _as_f16(x, k):
    v = (x + k) & 0xFFFF
    v = ((v << 5) | (v >> 11)) & 0xFFFF
    return (v ^ (v >> 7) ^ (x >> 3)) & 0xFFFF


def _as_subkeys(key):
    return [((key >> 16) & 0xFFFF) ^ 0xA5A5, (key & 0xFFFF) ^ 0x5A5A,
            ((key >> 8) & 0xFFFF) ^ 0x3C3C]


def _as_scramble(addr, key):
    sk = _as_subkeys(key)
    hi, lo = (addr >> 16) & 0xFFFF, addr & 0xFFFF
    for i in range(3):
        hi, lo = lo, (hi ^ _as_f16(lo, sk[i])) & 0xFFFF
    return (((hi << 16) | lo) ^ key) & MASK


def _as_unscramble(word, key):
    sk = _as_subkeys(key)
    w = (word ^ key) & MASK
    hi, lo = (w >> 16) & 0xFFFF, w & 0xFFFF
    for i in range(2, -1, -1):
        hi, lo = (lo ^ _as_f16(hi, sk[i])) & 0xFFFF, hi
    return ((hi << 16) | lo) & MASK


AS_DECL = r"""
localparam [15:0] AS_K0 = 16'hA5A5, AS_K1 = 16'h5A5A, AS_K2 = 16'h3C3C;
function [15:0] as_f16;
    input [15:0] ax;
    input [15:0] ak;
    reg [15:0] av, ar;
    begin
        av = ax + ak;
        ar = {av[10:0], av[15:11]};
        as_f16 = ar ^ (ar >> 7) ^ (ax >> 3);
    end
endfunction
function [31:0] as_scr;
    input [31:0] ad;
    input [31:0] k;
    reg [15:0] hi, lo, sv;
    reg [15:0] s0, s1, s2;
    begin
        s0 = k[31:16] ^ AS_K0;
        s1 = k[15:0] ^ AS_K1;
        s2 = k[23:8] ^ AS_K2;
        hi = ad[31:16];
        lo = ad[15:0];
        sv = hi; hi = lo; lo = sv ^ as_f16(lo, s0);
        sv = hi; hi = lo; lo = sv ^ as_f16(lo, s1);
        sv = hi; hi = lo; lo = sv ^ as_f16(lo, s2);
        as_scr = {hi, lo} ^ k;
    end
endfunction
function [31:0] as_uns;
    input [31:0] wd;
    input [31:0] k;
    reg [31:0] aw;
    reg [15:0] hi, lo, sv;
    reg [15:0] s0, s1, s2;
    begin
        s0 = k[31:16] ^ AS_K0;
        s1 = k[15:0] ^ AS_K1;
        s2 = k[23:8] ^ AS_K2;
        aw = wd ^ k;
        hi = aw[31:16];
        lo = aw[15:0];
        sv = hi; hi = lo ^ as_f16(hi, s2); lo = sv;
        sv = hi; hi = lo ^ as_f16(hi, s1); lo = sv;
        sv = hi; hi = lo ^ as_f16(hi, s0); lo = sv;
        as_uns = {hi, lo};
    end
endfunction
reg [31:0] as_key, as_t, as_mid, as_diff;
reg [2:0] as_op;
reg [3:0] as_err;
reg [11:0] as_seq;
reg as_cmp, as_rt, as_bad, as_failv;
"""

AS_BODY = r"""
as_key = state_r[31:0];
as_op = c[2:0];
as_err = state_r[36:33];
as_seq = state_r[106:95] + 12'd1;
if (c[31]) begin
    as_t = as_scr(32'd0, a);
    state_n = 256'd0;
    state_n[31:0] = a;
    state_n[32] = 1'b1;
    state_n[70:69] = b[1:0];
    state_n[106:95] = as_seq;
    r = as_t;
    x = {as_t[31:24], 8'd0, b[1:0], as_op, 3'd0, as_err, 4'd0};
end else if (!state_r[32]) begin
    f = 1'b1;
    x = 32'd1;
end else if (as_op > 3'd5) begin
    f = 1'b1;
    x = 32'd2;
end else begin
    as_cmp = (as_op == 3'd2) || (as_op == 3'd3);
    as_rt = (as_op == 3'd4) || (as_op == 3'd5);
    as_bad = 1'b0;
    case (as_op)
        3'd0: as_t = as_scr(a, as_key);
        3'd1: as_t = as_uns(a, as_key);
        3'd2: as_t = as_scr(a, as_key);
        3'd3: as_t = as_uns(a, as_key);
        3'd4: begin
            as_mid = as_scr(a, as_key);
            as_t = as_uns(as_mid, as_key);
        end
        default: begin
            as_mid = as_uns(a, as_key);
            as_t = as_scr(as_mid, as_key);
        end
    endcase
    as_diff = 32'd0;
    if (as_cmp && (as_t != b)) begin
        as_bad = 1'b1;
        as_diff = as_t ^ b;
    end else if (as_rt && (as_t != a)) begin
        as_bad = 1'b1;
        as_diff = as_t ^ a;
    end
    state_n[68:37] = as_t;
    if (state_r[78:71] != 8'hFF) state_n[78:71] = state_r[78:71] + 8'd1;
    if ((as_op == 3'd0) || (as_op == 3'd2) || (as_op == 3'd4) ||
        (as_op == 3'd5)) begin
        if (state_r[86:79] != 8'hFF) state_n[86:79] = state_r[86:79] + 8'd1;
    end
    if ((as_op == 3'd1) || (as_op == 3'd3) || (as_op == 3'd4) ||
        (as_op == 3'd5)) begin
        if (state_r[94:87] != 8'hFF) state_n[94:87] = state_r[94:87] + 8'd1;
    end
    as_failv = state_r[139];
    if (as_bad) begin
        if (as_err != 4'hF) state_n[36:33] = as_err + 4'd1;
        if (!state_r[139]) begin
            state_n[139] = 1'b1;
            state_n[138:107] = a;
            as_failv = 1'b1;
        end
    end
    state_n[106:95] = as_seq;
    f = as_bad;
    r = as_bad ? as_diff : as_t;
    x = {as_t[31:24], state_n[78:71], state_r[70:69], as_op, as_cmp, as_rt,
         as_failv, (as_bad ? ((as_err == 4'hF) ? as_err : as_err + 4'd1) : as_err),
         as_bad ? (as_cmp ? 4'd3 : 4'd4) : 4'd0};
end
"""


def _addr_scramble(a, b, c, st):
    key = bits(st, AS_KEY, 32)
    mode = bits(st, AS_MODE, 2)
    err = bits(st, AS_ERR, 4)
    ops = bits(st, AS_OPS, 8)
    seq = (bits(st, AS_SEQ, 12) + 1) & 0xFFF
    op = c & 7
    if c >> 31:
        ns = poke(poke(poke(0, AS_KEY, 32, a), AS_CFG, 1, 1), AS_MODE, 2, b & 3)
        ns = poke(ns, AS_SEQ, 12, seq)
        t = _as_scramble(0, a)
        x = (((t >> 24) & 0xFF) << 24) | ((b & 3) << 14) | (op << 11) | (err << 4)
        return t & MASK, x & MASK, 0, ns & ALL256
    if not bits(st, AS_CFG, 1):
        return 0, 1, 1, st
    if op > 5:
        return 0, 2, 1, st
    if op in (0, 2):
        t = _as_scramble(a, key)
    elif op in (1, 3):
        t = _as_unscramble(a, key)
    elif op == 4:
        t = _as_unscramble(_as_scramble(a, key), key)
    else:
        t = _as_scramble(_as_unscramble(a, key), key)
    cmpb = 1 if op in (2, 3) else 0
    rt = 1 if op in (4, 5) else 0
    bad = 0
    diff = 0
    if cmpb and t != b:
        bad, diff = 1, t ^ b
    elif rt and t != a:
        bad, diff = 1, t ^ a
    ns = st
    ns = poke(ns, AS_LAST, 32, t)
    nops = 0xFF if ops == 0xFF else ops + 1
    ns = poke(ns, AS_OPS, 8, nops)
    if op in (0, 2, 4, 5):
        sc = bits(st, AS_SC, 8)
        if sc != 0xFF:
            ns = poke(ns, AS_SC, 8, sc + 1)
    if op in (1, 3, 4, 5):
        un = bits(st, AS_UN, 8)
        if un != 0xFF:
            ns = poke(ns, AS_UN, 8, un + 1)
    failv = bits(st, AS_FAILV, 1)
    nerr = err
    if bad:
        if err != 15:
            nerr = err + 1
            ns = poke(ns, AS_ERR, 4, nerr)
        if not failv:
            failv = 1
            ns = poke(ns, AS_FAILV, 1, 1)
            ns = poke(ns, AS_FAILA, 32, a)
    ns = poke(ns, AS_SEQ, 12, seq)
    cause = 0 if not bad else (3 if cmpb else 4)
    r = diff if bad else t
    x = ((((t >> 24) & 0xFF) << 24) | (nops << 16) | (mode << 14) | (op << 11) |
         (cmpb << 10) | (rt << 9) | (failv << 8) | (nerr << 4) | cause)
    return r & MASK, x & MASK, bad, ns & ALL256


_MODELS['addr_scramble'] = _addr_scramble


def _as_rows():
    rows = []
    key = 0x5EED1234
    st = 0
    rng = Random(0x4153)
    rows.append((key, 1, 1 << 31))
    st = step('addr_scramble', key, 1, 1 << 31, 0)[3]
    inj = {11, 47, 83, 119}
    k = 0
    while len(rows) < BOARD:
        if k in inj:
            a = rng.getrandbits(32)
            t = _as_scramble(a, key) if k % 2 == 0 else _as_unscramble(a, key)
            rows.append((a, (t ^ 0x100) & MASK, 2 + (k % 2)))
        elif k % 23 == 0:
            key = (0x9E3779B9 ^ (k << 7)) & MASK
            rows.append((key, k % 4, 1 << 31))
        else:
            a = ((k << 12) + 0x17) & MASK
            op = ((k % 5) + 1) if (k % 5) else 4
            b = _as_scramble(a, key) if op in (2, 4) else _as_unscramble(a, key)
            rows.append((a, b, op))
        st = step('addr_scramble', *rows[-1], st)[3]
        k += 1
    return rows


_ROWS['addr_scramble'] = _as_rows


core('addr_scramble',
    'Invertible address scrambler: a three-round 16-bit Feistel permutation with '
    'key-derived sub-keys, plus unscramble, host compare and round-trip self-check '
    'modes, so a scrambled bank, page and row mapping is always exactly reversible',
    AS_BODY,
    'Address scrambling must be reversible in the same cycle it is applied, and a '
    'three-round Feistel network gives that for free: every stage is a 16-bit add, '
    'a rotate and XORs, so forward and inverse share one round function and need no '
    'lookup table, no divider and no multiplier, which keeps the whole scramble and '
    'decode path single-cycle wide at an initiation interval of 1',
    1, decl=AS_DECL)


# ===========================================================================
# 10  raid5_pq -- GF(2^8) P and Q stripe syndromes over a 4-byte column path
# ===========================================================================
# P is the byte-lane XOR of every data column, Q weights column i by alpha^i in
# GF(256) with the 0x11D polynomial, so every field is an XOR tree plus xtime.
RP_P = 0               # [31:0]    P accumulator, four byte lanes
RP_Q = 32              # [63:32]   Q accumulator, four byte lanes
RP_POW = 64            # [71:64]   alpha^column, the current Q weight
RP_COL = 72            # [74:72]   columns fed into this stripe
RP_ND = 75             # [77:75]   data columns per stripe, 1..6
RP_CFG = 78            # [78]      configured
RP_ERR = 79            # [82:79]   syndrome mismatches, saturates 15
RP_STRIPE = 83         # [90:83]   stripes completed, saturates 255
RP_FEED = 91           # [98:91]   data words fed, saturates 255
RP_SEQ = 99            # [110:99]  free-running beat sequence
RP_LASTF = 111         # [118:111] stripe index of the last mismatch

RP_DECL = r"""
function [7:0] gf_mul;
    input [7:0] gu;
    input [7:0] gv;
    integer gi;
    reg [7:0] gp, gr;
    begin
        gp = 8'd0;
        gr = gv;
        for (gi = 0; gi < 8; gi = gi + 1) begin
            if (gu[gi]) gp = gp ^ gr;
            gr = {gr[6:0], 1'b0} ^ (gr[7] ? 8'h1D : 8'h00);
        end
        gf_mul = gp;
    end
endfunction
reg [2:0] rp_nd, rp_col;
reg [3:0] rp_err4;
reg [7:0] rp_pow, rp_st, rp_fd, rp_lf;
reg [11:0] rp_seq;
reg [31:0] rp_newp, rp_newq, rp_dp, rp_dq;
reg [7:0] rp_q0, rp_q1, rp_q2, rp_q3, rp_ppar, rp_qpar;
reg [31:0] rp_status, rp_sx;
reg [2:0] rp_op;
reg rp_bad;
"""

RP_BODY = r"""
rp_nd = state_r[77:75];
rp_col = state_r[74:72];
rp_pow = state_r[71:64];
rp_err4 = state_r[82:79];
rp_st = state_r[90:83];
rp_fd = state_r[98:91];
rp_lf = state_r[118:111];
rp_seq = state_r[110:99] + 12'd1;
rp_op = c[2:0];
rp_ppar = state_r[7:0] ^ state_r[15:8] ^ state_r[23:16] ^ state_r[31:24];
rp_qpar = state_r[39:32] ^ state_r[47:40] ^ state_r[55:48] ^ state_r[63:56];
rp_status = {rp_lf[3:0], rp_st, rp_pow, rp_err4, 1'b1, 1'b1, rp_col, rp_nd};
rp_sx = {5'd0, rp_fd, rp_col, rp_ppar, rp_qpar};
if (c[31]) begin
    if ((rp_op == 3'd0) || (rp_op > 3'd6)) begin
        f = 1'b1;
        x = 32'd5;
    end else begin
        state_n[77:75] = rp_op;
        state_n[78] = 1'b1;
        state_n[74:72] = 3'd0;
        state_n[71:64] = 8'd1;
        state_n[31:0] = 32'd0;
        state_n[63:32] = 32'd0;
        state_n[110:99] = rp_seq;
        r = {rp_lf[3:0], rp_st, 8'd1, rp_err4, 1'b1, 1'b1, 3'd0, rp_op};
        x = {5'd0, rp_fd, 3'd0, 8'd0, 8'd0};
    end
end else if (!state_r[78]) begin
    f = 1'b1;
    x = 32'd1;
end else if (rp_op > 3'd3) begin
    f = 1'b1;
    x = 32'd2;
end else if ((rp_op == 3'd0) && (rp_col == rp_nd)) begin
    f = 1'b1;
    x = 32'd4;
end else if ((rp_op == 3'd2) && (rp_col != rp_nd)) begin
    f = 1'b1;
    x = 32'd6;
end else begin
    state_n[110:99] = rp_seq;
    if (rp_op == 3'd0) begin
        rp_newp = state_r[31:0] ^ a;
        rp_q0 = gf_mul(rp_pow, a[7:0]);
        rp_q1 = gf_mul(rp_pow, a[15:8]);
        rp_q2 = gf_mul(rp_pow, a[23:16]);
        rp_q3 = gf_mul(rp_pow, a[31:24]);
        rp_newq = {rp_q3, rp_q2, rp_q1, rp_q0} ^ state_r[63:32];
        state_n[31:0] = rp_newp;
        state_n[63:32] = rp_newq;
        state_n[71:64] = {rp_pow[6:0], 1'b0} ^ (rp_pow[7] ? 8'h1D : 8'h00);
        state_n[74:72] = rp_col + 3'd1;
        if (rp_fd != 8'hFF) state_n[98:91] = rp_fd + 8'd1;
        r = rp_newp;
        x = rp_newq;
    end else if (rp_op == 3'd1) begin
        rp_dp = state_r[31:0] ^ a;
        rp_dq = state_r[63:32] ^ b;
        rp_bad = (rp_dp != 32'd0) || (rp_dq != 32'd0);
        if (rp_bad) begin
            if (rp_err4 != 4'hF) state_n[82:79] = rp_err4 + 4'd1;
            state_n[118:111] = rp_st;
        end
        r = rp_dp;
        x = rp_dq;
        f = rp_bad;
    end else if (rp_op == 3'd2) begin
        r = state_r[31:0];
        x = state_r[63:32];
        state_n[31:0] = 32'd0;
        state_n[63:32] = 32'd0;
        state_n[74:72] = 3'd0;
        state_n[71:64] = 8'd1;
        if (rp_st != 8'hFF) state_n[90:83] = rp_st + 8'd1;
    end else begin
        r = rp_status;
        x = rp_sx;
    end
end
"""


def _gf_xtime(v):
    return (((v << 1) & 0xFF) ^ (0x1D if (v & 0x80) else 0)) & 0xFF


def _gf_mul(u, v):
    p, r = 0, v & 0xFF
    for i in range(8):
        if (u >> i) & 1:
            p ^= r
        r = _gf_xtime(r)
    return p & 0xFF


def _gf4_mul(powv, word):
    out = 0
    for lane in range(4):
        out |= _gf_mul(powv, (word >> (8 * lane)) & 0xFF) << (8 * lane)
    return out & MASK


def _raid5_pq(a, b, c, st):
    nd = bits(st, RP_ND, 3)
    col = bits(st, RP_COL, 3)
    powv = bits(st, RP_POW, 8)
    err = bits(st, RP_ERR, 4)
    stripe = bits(st, RP_STRIPE, 8)
    feed = bits(st, RP_FEED, 8)
    lastf = bits(st, RP_LASTF, 8)
    seq = (bits(st, RP_SEQ, 12) + 1) & 0xFFF
    pacc = bits(st, RP_P, 32)
    qacc = bits(st, RP_Q, 32)
    op = c & 7
    status = (((lastf & 0xF) << 28) | (stripe << 20) | (powv << 12) | (err << 8) |
              (1 << 7) | (1 << 6) | (col << 3) | nd)
    sx = ((feed << 19) | (col << 16) | (_xorbytes(pacc) << 8) | _xorbytes(qacc))
    if c >> 31:
        if op == 0 or op > 6:
            return 0, 5, 1, st
        ns = poke(0, RP_P, 32, 0)
        ns = poke(ns, RP_Q, 32, 0)
        ns = poke(ns, RP_ND, 3, op)
        ns = poke(ns, RP_CFG, 1, 1)
        ns = poke(ns, RP_COL, 3, 0)
        ns = poke(ns, RP_POW, 8, 1)
        ns = poke(ns, RP_SEQ, 12, seq)
        ns = poke(ns, RP_ERR, 4, err)
        ns = poke(ns, RP_STRIPE, 8, stripe)
        ns = poke(ns, RP_FEED, 8, feed)
        ns = poke(ns, RP_LASTF, 8, lastf)
        r = (((lastf & 0xF) << 28) | (stripe << 20) | (1 << 12) | (err << 8) |
             (1 << 7) | (1 << 6) | op)
        return r & MASK, ((feed << 19) & MASK), 0, ns & ALL256
    if not bits(st, RP_CFG, 1):
        return 0, 1, 1, st
    if op > 3:
        return 0, 2, 1, st
    if op == 0 and col == nd:
        return 0, 4, 1, st
    if op == 2 and col != nd:
        return 0, 6, 1, st
    if op == 0:
        newp = pacc ^ a
        newq = _gf4_mul(powv, a) ^ qacc
        ns = poke(st, RP_P, 32, newp)
        ns = poke(ns, RP_Q, 32, newq)
        ns = poke(ns, RP_POW, 8, _gf_xtime(powv))
        ns = poke(ns, RP_COL, 3, col + 1)
        if feed != 0xFF:
            ns = poke(ns, RP_FEED, 8, feed + 1)
        ns = poke(ns, RP_SEQ, 12, seq)
        return newp & MASK, newq & MASK, 0, ns & ALL256
    if op == 1:
        dp, dq = pacc ^ a, qacc ^ b
        bad = 1 if (dp or dq) else 0
        ns = st
        if bad:
            if err != 15:
                ns = poke(ns, RP_ERR, 4, err + 1)
            ns = poke(ns, RP_LASTF, 8, stripe)
        ns = poke(ns, RP_SEQ, 12, seq)
        return dp & MASK, dq & MASK, bad, ns & ALL256
    if op == 2:
        ns = poke(st, RP_P, 32, 0)
        ns = poke(ns, RP_Q, 32, 0)
        ns = poke(ns, RP_COL, 3, 0)
        ns = poke(ns, RP_POW, 8, 1)
        ns = poke(ns, RP_SEQ, 12, seq)
        if stripe != 0xFF:
            ns = poke(ns, RP_STRIPE, 8, stripe + 1)
        return pacc & MASK, qacc & MASK, 0, ns & ALL256
    ns = poke(st, RP_SEQ, 12, seq)
    return status & MASK, sx & MASK, 0, ns & ALL256


def _xorbytes(word):
    out = 0
    for lane in range(4):
        out ^= (word >> (8 * lane)) & 0xFF
    return out


_MODELS['raid5_pq'] = _raid5_pq


def _raid5_rows():
    rows = [(0, 0, 3), (0, 0, 1 << 31)]      # status, then nd = 0: causes 1 and 5
    st = 0
    for r0 in rows:
        st = step('raid5_pq', *r0, st)[3]
    rng = Random(0x52414944)
    cyc = 0
    while len(rows) < BOARD:
        nd = 1 + (cyc % 6)
        rows.append((0, 0, (1 << 31) | nd))
        st = step('raid5_pq', 0, 0, (1 << 31) | nd, st)[3]
        if cyc % 6 == 2:
            rows.append((0, 0, 2))           # finish an empty stripe: cause 6
            st = step('raid5_pq', 0, 0, 2, st)[3]
        words = []
        for i in range(nd):
            w = rng.getrandbits(32)
            words.append(w)
            rows.append((w, 0, 0))
            st = step('raid5_pq', w, 0, 0, st)[3]
        pacc = bits(st, RP_P, 32)
        qacc = bits(st, RP_Q, 32)
        if cyc % 3 == 0:
            rows.append((pacc, qacc, 1))     # clean syndrome verify
            st = step('raid5_pq', pacc, qacc, 1, st)[3]
        if cyc % 4 == 0:
            bad = rng.getrandbits(32) | 1
            rows.append((pacc ^ bad, qacc, 1))   # corrupt P: mismatch fault
            st = step('raid5_pq', pacc ^ bad, qacc, 1, st)[3]
        rows.append((0, 0, 3))               # status reports the stripe geometry
        st = step('raid5_pq', 0, 0, 3, st)[3]
        if cyc % 5 == 0:
            rows.append((words[0], 0, 0))    # one column too many: cause 4
            st = step('raid5_pq', words[0], 0, 0, st)[3]
        if cyc % 7 == 0:
            rows.append((0, 0, 5))           # illegal op: cause 2
            st = step('raid5_pq', 0, 0, 5, st)[3]
        rows.append((0, 0, 2))               # finish: emit both parity columns
        st = step('raid5_pq', 0, 0, 2, st)[3]
        cyc += 1
    return rows


_ROWS['raid5_pq'] = _raid5_rows


core('raid5_pq',
    'RAID-5/6 stripe syndrome engine: accumulates the P XOR column and the '
    'GF(256) weighted Q column four bytes at a time, verifies host-supplied '
    'syndromes, emits both parity columns and refuses an over-full stripe',
    RP_BODY,
    'Both RAID syndromes are carry-free: P is four byte-lane XOR trees and Q is '
    'four GF(256) multiply-accumulates built from xtime shift-xor stages, so a '
    'stripe of data columns folds into both parities at one column word per cycle '
    'without touching the $mul primitive, which the unsigned GW5A fabric cannot '
    'provide for a 256-bit field anyway',
    1, decl=RP_DECL)


# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
def step(name, a, b, c, state=0):
    handler = _MODELS.get(name)
    if handler is None:
        raise ValueError(name)
    return handler(a & MASK, b & MASK, c & MASK, state & ALL256)


def vectors(name, count=320):
    rows = _ROWS[name]()
    assert len(rows) >= BOARD, f'{name}: board set is too short'
    rng = Random(0x4D454D53 + sum(name.encode()))
    while len(rows) < count:
        rows.append((rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32)))
    return rows[:max(count, BOARD)]


def selftest():
    """Independent-model checks against hand-derived expected values."""
    checks = 0
    assert FAMILY == 'memsys'
    assert len(CORES) >= 1 and all(e['family'] == FAMILY for e in CORES)
    checks += 1
    for entry in CORES:
        assert entry['latency'] == 1 and entry.get('module') is None
        assert 'posedge' not in entry['body'] and 'negedge' not in entry['body']
        assert '*' not in entry['body'] and '/' not in entry['body']
        checks += 1

    # --- afifo_gray: the Gray code contract, proved without the core --------
    # A binary pointer and its Gray code agree above the highest differing bit, so
    # consecutive pointers differ in exactly one Gray bit: that single-bit property
    # is the whole reason an async FIFO may use these codes at all.
    for width in range(2, 6):
        modulus = 1 << width
        for p in range(modulus):
            g = gray_encode(p) & ((1 << width) - 1)
            nxt = gray_encode((p + 1) % modulus) & ((1 << width) - 1)
            assert popcount(g ^ nxt) == 1
            checks += 1
    # Empty and full must follow the set definition (occupancy 0 and occupancy =
    # depth) for every reachable pointer pair, decided only from the Gray codes.
    for n in range(1, 5):
        depth, modulus = 1 << n, 1 << (n + 1)
        for wp in range(modulus):
            for rp in range(modulus):
                occ = (wp - rp) % modulus
                if occ > depth:
                    continue                          # not a reachable FIFO state
                full_bit = ((1 << n) | (1 << (n - 1)))
                assert int(gray_encode(wp) == gray_encode(rp)) == int(occ == 0)
                assert int((gray_encode(wp) ^ gray_encode(rp)) == full_bit) == \
                    int(occ == depth)
                checks += 1
    af = 'afifo_gray'
    # Out of reset nothing is configured, so an op beat is cause 1 and a depth of
    # 0 or 5 is cause 5: both refuse to write any state at all.
    assert step(af, 1, 0, 0, 0) == (0, 1, 1, 0)
    assert step(af, 0, 0, (1 << 31) | 0, 0) == (0, 5, 1, 0)
    assert step(af, 0, 0, (1 << 31) | 5, 0) == (0, 5, 1, 0)
    checks += 3
    # Configure depth 2^4: before the beat both pointers are 0, so the Gray codes
    # are equal (empty) and differ by nothing (not full) -> result bit 10 only, and
    # aux carries N = 4 at [12:10] plus the configure-beat flag at [14].
    r, x, f, st = step(af, 0, 0, (1 << 31) | 4, 0)
    assert (r, x, f) == (1 << 10, (4 << 10) | (1 << 14), 0)
    assert (bits(st, AFIFO_N, 3), bits(st, AFIFO_CFG, 1)) == (4, 1)
    assert bits(st, AFIFO_WP, 5) == 0 and bits(st, AFIFO_BUF, 8) == 0
    checks += 1
    # One write of 0x2A into the empty FIFO: slot 0 takes the byte, the write
    # pointer becomes 1, occupancy 0 -> 1 and the peak follows it.
    r, x, f, st = step(af, 1 | (0x2A << 8), 0, 0, st)
    assert f == 0 and r == (1 << 10) | (1 << 17) | (1 << 22)
    assert x == 1 | (4 << 10) | (1 << 15) | (1 << 24)
    assert bits(st, AFIFO_BUF, 8) == 0x2A and bits(st, AFIFO_WP, 5) == 1
    assert bits(st, AFIFO_PUSH, 8) == 1 and bits(st, AFIFO_MAX, 5) == 1
    checks += 1
    # Fill the depth-16 FIFO with 0x10, 0x11, ... 0x1F in slot order. The beat that
    # accepts the 16th write sees occupancy 15 -> 16: Gray(15) = 15 ^ 7 = 8 is the
    # write code reported before the beat, and full is still 0 because 8 ^ 0 = 8 is
    # not the 0b11000 = 24 two-bit difference the full condition asks for.
    for k in range(1, 16):
        r, x, f, st = step(af, 1 | ((0x10 + k) << 8), 0, 0, st)
        assert f == 0
    assert (r >> 12) & 0x1f == 15 and (r >> 17) & 0x1f == 16
    assert r & 0x1f == 8 and (r >> 11) & 1 == 0 and (r >> 22) & 1 == 1
    assert bits(st, AFIFO_WP, 5) == 16 and bits(st, AFIFO_PUSH, 8) == 16
    assert bits(st, AFIFO_MAX, 5) == 16
    checks += 1
    # A 17th write must be refused: cause 2, result 0, no pointer motion and no
    # push credit, but the overflow attempt is counted.
    r, x, f, st = step(af, 1 | (0xEE << 8), 0, 0, st)
    assert (r, x, f) == (0, 2, 1)
    assert bits(st, AFIFO_WP, 5) == 16 and bits(st, AFIFO_PUSH, 8) == 16
    assert bits(st, AFIFO_OVF, 4) == 1
    assert bits(st, AFIFO_BUF, 8) == 0x2A          # slot 0 untouched by the refusal
    checks += 1
    # Now drain with the order check on. The FIFO holds 0x2A in slot 0 (written
    # first) and 0x11..0x1F in slots 1..15, and before the j-th pop the pointers are
    # wp = 16 (Gray 24) and rp = j, so occupancy is 16 - j. Only j = 0 reports full,
    # because 24 ^ 0 = 24 is the two-bit difference that means full at depth 16.
    expect = [0x2A] + [0x10 + k for k in range(1, 16)]
    for j in range(3):
        r, x, f, st = step(af, 2, expect[j], 8, st)
        assert f == 0
        assert r == (24 | (gray_encode(j) << 5) | (int(j == 0) << 11)
                     | ((16 - j) << 12) | ((15 - j) << 17) | (1 << 23)
                     | (expect[j] << 24))
        assert x == (16 | ((j + 1) << 5) | (4 << 10) | (1 << 13) | (1 << 15)
                     | (1 << 16) | (16 << 24))          # [19:16] = the one overflow
        checks += 1
    # A disagreeing byte is cause 4 and still consumes the read, because the
    # external RAM really did drive it: pointers move, pops count, mismatch counts.
    r, x, f, st = step(af, 2, 0x13 ^ 0x80, 8, st)
    assert (r, x, f) == (0, 4, 1)
    assert bits(st, AFIFO_RP, 5) == 4 and bits(st, AFIFO_POP, 8) == 4
    assert bits(st, AFIFO_MIS, 3) == 1
    checks += 1
    # Drain the remaining 12 entries unchecked, then read once more: the empty
    # condition is Gray equality, so the 13th read is cause 3 with the read pointer
    # frozen, and the write pointer is still 16 from the fill.
    for j in range(4, 16):
        r, x, f, st = step(af, 2, 0, 0, st)
        assert f == 0 and (r >> 24) == 0x10 + j
    assert bits(st, AFIFO_RP, 5) == 16 and bits(st, AFIFO_WP, 5) == 16
    r, x, f, st = step(af, 2, 0, 0, st)
    assert (r, x, f) == (0, 3, 1)
    assert bits(st, AFIFO_RP, 5) == 16 and bits(st, AFIFO_UND, 4) == 1
    checks += 1
    # A Gray code that equals its partner is the only empty test an async FIFO may
    # use: check the two-pointer preload path against it. Preload wp = 5, rp = 2 at
    # depth 4 -> occupancy 3, neither empty nor full.
    r, x, f, st = step(af, 5, 2, (1 << 31) | (1 << 3) | 4, st)
    assert f == 0
    assert (bits(st, AFIFO_WP, 5), bits(st, AFIFO_RP, 5)) == (5, 2)
    assert (r >> 17) & 0x1f == 3 and (r >> 12) & 0x1f == 0
    assert (r >> 10) & 1 == 1 and (r >> 11) & 1 == 0        # before: pointers equal
    # Both pointers still sat at 16 after the drain, so the Gray codes reported
    # before this beat are both Gray(16) = 16 ^ 8 = 24, equal, hence empty.
    assert (r & 0x1f) == 24 and ((r >> 5) & 0x1f) == 24
    assert bits(st, AFIFO_MAX, 5) == 3 and bits(st, AFIFO_PUSH, 8) == 0
    assert bits(st, AFIFO_BUF, 8) == 0                        # preload clears data
    checks += 1
    # At depth 2 (N = 1) the pointer modulus is 4, so b = 6 preloads rp = 2 and the
    # pair wp = 1, rp = 2 implies occupancy (1-2) mod 4 = 3, above the depth: cause
    # 6, and the state must be left exactly as it was.
    assert step(af, 1, 6, (1 << 31) | (1 << 3) | 1, st) == (0, 6, 1, st)
    # The same beat with wp = 0, rp = 3 gives occupancy 1 of a 2-deep FIFO, which is
    # legal: only an occupancy above the depth is refused, never an equal one.
    r, x, f, st2 = step(af, 0, 3, (1 << 31) | (1 << 3) | 1, st)
    assert f == 0 and (r >> 17) & 0x1f == 1 and bits(st2, AFIFO_RP, 5) == 3
    assert (r >> 11) & 1 == 0 and (r >> 10) & 1 == 0
    checks += 2
    # Saturating counters must stop, not wrap: pre-fill the overflow count and check
    # that a further refused write leaves it at all-ones.
    loaded = poke(poke(0, AFIFO_N, 3, 1), AFIFO_CFG, 1, 1)
    loaded = poke(loaded, AFIFO_OVF, 4, 15)
    r, x, f, st = step(af, 1, 0, 0, loaded)                   # depth 2, wp=rp=0
    assert f == 0 and bits(st, AFIFO_WP, 5) == 1
    r, x, f, st = step(af, 1, 0, 0, st)                       # second write fills it
    assert f == 0 and bits(st, AFIFO_WP, 5) == 2
    r, x, f, st = step(af, 1, 0, 0, st)                       # third write refused
    assert (r, x, f) == (0, 2, 1) and bits(st, AFIFO_OVF, 4) == 15
    # Depth 2 full must read as Gray(2) ^ Gray(0) = 3 ^ 0 = 3 = (1<<1)|(1<<0).
    assert gray_encode(2) == 3
    # An exactly-full preload is legal (occupancy = depth, not above it): at depth
    # 4 the pair wp = 4, rp = 0 differs by Gray(4) ^ Gray(0) = 6 = (1<<2)|(1<<1),
    # which is the full pattern. Re-seed from a clean reset so the pointers this
    # beat sees before loading are known: wp = 5, rp = 2 at depth 16, Gray codes
    # Gray(5) = 5 ^ 2 = 7 and Gray(2) = 3, occupancy 3, neither empty nor full.
    _, _, _, st = step(af, 0, 0, (1 << 31) | 4, 0)
    r, x, f, st = step(af, 5, 2, (1 << 31) | (1 << 3) | 4, st)
    assert f == 0 and bits(st, AFIFO_MAX, 5) == 3
    r, x, f, st = step(af, 4, 0, (1 << 31) | (1 << 3) | 2, st)
    assert f == 0 and (r & 0x1f) == 7 and ((r >> 5) & 0x1f) == 3
    assert (r >> 17) & 0x1f == 4 and (r >> 11) & 1 == 0 and (r >> 10) & 1 == 0
    assert bits(st, AFIFO_WP, 5) == 4 and bits(st, AFIFO_RP, 5) == 0
    assert bits(st, AFIFO_MAX, 5) == 4 and bits(st, AFIFO_N, 3) == 2
    # The next beat must therefore report full-before from the loaded pair, and a
    # read still succeeds because a full FIFO is never empty.
    r, x, f, st = step(af, 2, 0, 0, st)
    assert f == 0 and (r >> 11) & 1 == 1 and (r >> 10) & 1 == 0
    assert (r & 0x1f) == 6 and ((r >> 5) & 0x1f) == 0
    assert (r >> 12) & 0x1f == 4 and (r >> 17) & 0x1f == 3 and (r >> 23) & 1 == 1
    assert bits(st, AFIFO_RP, 5) == 1 and bits(st, AFIFO_WP, 5) == 4
    checks += 1
    # Every reachable pointer pair at depth 4 must accept a write unless the FIFO
    # is exactly full, checked here against modular set arithmetic, not the core.
    for wp in range(8):
        for rp in range(8):
            occ = (wp - rp) & 7
            if occ > 4:
                continue
            seed = poke(poke(poke(0, AFIFO_N, 3, 2), AFIFO_CFG, 1, 1), AFIFO_WP, 5, wp)
            seed = poke(seed, AFIFO_RP, 5, rp)
            _, _, fault, after = step(af, 1, 0, 0, seed)
            assert fault == (1 if occ == 4 else 0)
            assert bits(after, AFIFO_WP, 5) == (wp if occ == 4 else (wp + 1) & 7)
            checks += 1

    # --- march_engine: the published March C- element list, written out here ---
    # up(w0) up(r0,w1) down(r1,w0) down(r0,w1) down(r1).  Two phases per address
    # keep the cadence uniform, so a short element gets an idle second phase.
    mc = 'march_engine'
    MARCHC = [(1, (('w', 0),)), (1, (('r', 0), ('w', 1))),
              (0, (('r', 1), ('w', 0))), (0, (('r', 0), ('w', 1))),
              (0, (('r', 1),))]
    plan = []
    for el, (asc, ops) in enumerate(MARCHC):
        for ad in (range(8) if asc else range(7, -1, -1)):
            pad = list(ops) + [('n', 0)] * (2 - len(ops))
            for ph, (kind, val) in enumerate(pad):
                plan.append((el, asc, ad, ph, kind, val))
    assert len(plan) == 80
    assert sum(1 for e in plan if e[4] == 'w') == 32
    assert sum(1 for e in plan if e[4] == 'r') == 32
    assert sum(1 for e in plan if e[4] == 'n') == 16
    checks += 4
    # Every element must sweep its own direction and the engine must end with every
    # cell holding the complement of the pattern, which only a correct March C-
    # order produces: element 3 writes the complement and element 4 only reads.
    pat = 0x5A
    _, _, _, st = step(mc, pat, 0, 1 << 31, 0)
    mem = [0] * 8
    for (el, asc, ad, ph, kind, val) in plan:
        wb = pat if val == 0 else (pat ^ 0xFF)
        bus = mem[ad] if kind == 'r' else 0
        r, x, f, st = step(mc, 0, bus, 0, st)
        assert f == 0
        assert (r >> 8) & 7 == ad and (r >> 11) & 7 == el
        assert ((r >> 14) & 1) == (1 - asc) and ((r >> 15) & 1) == ph
        assert (r >> 27) & 7 == {'r': 1, 'w': 2, 'n': 4}[kind]
        assert (r & 0xFF) == (wb if kind == 'w' else bus if kind == 'r' else 0)
        if kind == 'w':
            mem[ad] = wb
        checks += 1
    assert mem == [pat ^ 0xFF] * 8
    assert (r >> 20) & 1 == 1 and bits(st, MA_ERR, 4) == 0
    assert bits(st, MA_OPS, 8) == 80 and bits(st, MA_WR, 8) == 32
    assert bits(st, MA_RD, 8) == 32 and bits(st, MA_DONE, 1) == 1
    checks += 1
    # One bad byte on the bus is a memory fault: the read still counts, the error
    # tally moves and the first failing address is captured and never overwritten.
    _, _, _, st = step(mc, 0x11, 0, 1 << 31, 0)
    hits = []
    injected = False
    for k in range(20):
        el = bits(st, MA_EL, 3)
        ad = bits(st, MA_ADDR, 3)
        ph = bits(st, MA_PHASE, 1)
        kind = MA_OPS_TBL[el][ph]
        bus = bits(st, MA_MEM + 8 * ad, 8)
        if kind == 1 and not injected:
            bus ^= 0x40                       # corrupt the first read the run takes
            injected = True
        r, x, f, st = step(mc, 0, bus, 0, st)
        if f:
            hits.append((ad, bits(x, 24, 3)))
        checks += 1
    assert len(hits) == 1 and hits[0][0] == hits[0][1]
    assert bits(st, MA_ERR, 4) == 1 and bits(st, MA_FAILV, 1) == 1
    checks += 1
    # A beat before configuration, and a beat after the run is marked complete, are
    # both refused with the state left exactly where it was.
    done_st = poke(poke(0, MA_CFG, 1, 1), MA_DONE, 1, 1)
    assert step(mc, 0, 0, 0, 0) == (0, 1, 1, 0)
    assert step(mc, 0, 0, 0, done_st) == (0, 2, 1, done_st)
    checks += 2

    # --- addr_scramble: a permutation is a bijection, proved without step() ----
    sc = 'addr_scramble'
    for key in (0, 1, 0xA5A5A5A5, 0x5EED1234, 0xFFFFFFFF):
        out = set()
        for i in range(200):
            ad = (i * 0x9E3779B1 + key) & MASK
            s = _as_scramble(ad, key)
            assert s not in out
            out.add(s)
            assert _as_unscramble(s, key) == ad
            checks += 1
    # Every single key bit must move the image of a fixed address, otherwise the
    # key would have a dead input and two keys would scramble identically.
    for i in range(32):
        assert _as_scramble(0x12345678, 0x5EED1234 ^ (1 << i)) != \
            _as_scramble(0x12345678, 0x5EED1234)
        checks += 1
    _, _, _, st = step(sc, 0x5EED1234, 2, 1 << 31, 0)
    assert bits(st, AS_CFG, 1) == 1 and bits(st, AS_MODE, 2) == 2
    r1, _, _, st = step(sc, 0xDEADBEEF, 0, 0, st)
    assert r1 == _as_scramble(0xDEADBEEF, 0x5EED1234)
    r2, _, _, st = step(sc, r1, 0, 1, st)
    assert r2 == 0xDEADBEEF
    checks += 3
    # A host compare that disagrees faults, reports the differing bits as the
    # result, and freezes nothing else: only the error tally and the capture move.
    t10 = _as_scramble(0x1000, 0x5EED1234)
    r3, x3, f3, st = step(sc, 0x1000, t10 ^ 0x80000001, 2, st)
    assert f3 == 1 and r3 == 0x80000001
    assert (x3 & 0xF) == 3 and bits(x3, 4, 4) == 1
    assert bits(st, AS_ERR, 4) == 1 and bits(st, AS_FAILV, 1) == 1
    assert bits(st, AS_FAILA, 32) == 0x1000
    checks += 1
    assert step(sc, 0, 0, 6, st) == (0, 2, 1, st)
    assert step(sc, 0, 0, 7, st) == (0, 2, 1, st)
    assert step(sc, 0, 0, 0, 0) == (0, 1, 1, 0)
    checks += 3

    # --- raid5_pq: the field is built here by log table, an independent shape --
    rp = 'raid5_pq'
    logs = {}
    v = 1
    for i in range(255):
        assert v not in logs
        logs[v] = i
        v = ((v << 1) ^ (0x11D if (v & 0x80) else 0)) & 0xFF
    assert v == 1 and len(logs) == 255          # alpha = 2 generates the field
    anti = [0] * 256
    for elem, idx in logs.items():
        anti[idx] = elem
    checks += 2

    def logmul(u, w):
        if u == 0 or w == 0:
            return 0
        return anti[(logs[u] + logs[w]) % 255]

    assert all(logmul(u, w) == _gf_mul(u, w)
               for u in range(256) for w in range(0, 256, 5))
    assert all(logmul(u, logmul(v2, w2)) == logmul(logmul(u, v2), w2)
               for u in range(1, 256, 31) for v2 in range(1, 256, 37)
               for w2 in range(1, 256, 41))
    checks += 2
    # Fold a random stripe through the engine and through the log-table definition
    # of P and Q: the two must agree column for column, and the weights the engine
    # applies must be exactly alpha^0, alpha^1, ... in column order.
    rng = Random(0x52414944)
    for trial in range(24):
        nd = rng.randint(1, 6)
        words = [rng.getrandbits(32) for _ in range(nd)]
        pacc = 0
        qacc = 0
        for i, w in enumerate(words):
            pacc ^= w
            leg = 0
            for lane in range(4):
                leg |= logmul(anti[i], (w >> (8 * lane)) & 0xFF) << (8 * lane)
            qacc ^= leg
        _, _, _, st = step(rp, 0, 0, (1 << 31) | nd, 0)
        lastp = 0
        lastq = 0
        for i, w in enumerate(words):
            assert bits(st, RP_POW, 8) == anti[i]      # column i carries alpha^i
            lastp, lastq, fault, st = step(rp, w, 0, 0, st)
            assert fault == 0
        assert (lastp, lastq) == (pacc, qacc)
        # Both syndromes verify clean, and a corrupted P word is caught with the
        # differing bits reported.
        rr, xx, ff, st = step(rp, pacc, qacc, 1, st)
        assert (rr, xx, ff) == (0, 0, 0)
        rr, xx, ff, st = step(rp, pacc ^ 0x100, qacc, 1, st)
        assert ff == 1 and rr == 0x100 and xx == 0
        assert bits(st, RP_P, 32) == pacc and bits(st, RP_Q, 32) == qacc
        rr, xx, ff, st = step(rp, 0, 0, 2, st)           # finish emits both parity
        assert (rr, xx, ff) == (pacc, qacc, 0)
        assert bits(st, RP_P, 32) == 0 and bits(st, RP_COL, 3) == 0
        assert bits(st, RP_POW, 8) == 1
        checks += 1
    # Geometry and ordering refusals: an empty stripe cannot be finished, a stripe
    # cannot take a column beyond its data count, and an unknown op is refused.
    _, _, _, st = step(rp, 0, 0, (1 << 31) | 2, 0)
    assert step(rp, 0, 0, 2, st) == (0, 6, 1, st)
    _, _, _, st = step(rp, 1, 0, 0, st)
    _, _, _, st = step(rp, 2, 0, 0, st)
    assert step(rp, 3, 0, 0, st) == (0, 4, 1, st)
    assert step(rp, 0, 0, 4, st) == (0, 2, 1, st)
    assert step(rp, 0, 0, 1 << 31, st) == (0, 5, 1, st)
    assert step(rp, 0, 0, 0, 0) == (0, 1, 1, 0)
    checks += 5
    return checks
# @@CHUNK2@@
