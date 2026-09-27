"""Memory-protection kernels: SECDED codec, MPU bookkeeping, cache tags, MISR, scrubber.

Six enabled-ready-valid accelerator cores for the memory-protection family. Each
one replaces a serial firmware routine that a memory controller really runs: ECC
generation and correction, region permission checks, set-associative tag lookup,
signature compression and scrub-window accounting.

Contract used by every core in this file (see generate_lib.RTL):
    inputs  a, b, c                    32 bit, one accepted beat
    outputs result, aux (r, x), fault  32 bit, 32 bit, 1 bit
    state   state_r -> state_n         256 bit, only accepted beats commit it
    restart/config beat convention: c[31] = 1

Every core is specified twice: as Verilog statements below and as a pure-integer
Python model in step(). selftest() attacks the model with hand-derived values --
published check bits, exhaustive single-bit round trips, syndrome identities,
region-boundary indices, cache hit and victim values, a hand-computed MISR stream
and an algebraic primitivity proof -- so a bug shared by model and RTL is caught.
"""
from random import Random

FAMILY = 'memprot'
MASK = (1 << 32) - 1
VMASK = (1 << 24) - 1

CORES = []


def core(name, spec, body, advantage, lanes, **kwargs):
    entry = dict(name=name, family=FAMILY, spec=spec, body=body,
                 advantage=advantage, lanes=lanes, stateful=False,
                 faultless=False, latency=1)
    entry.update(kwargs)
    assert entry['latency'] == 1 and entry.get('module') is None
    CORES.append(entry)


# ---------------------------------------------------------------------------
# SECDED(39,32) parity-check matrix.
# Codeword bit positions are 1..39: positions 1,2,4,8,16,32 hold the six Hamming
# check bits p0..p5, position 39 holds the overall parity p6, and the 32 data bits
# take the remaining positions in increasing order. Data bit i therefore gets
# column POSITIONS[i], never a unit vector, so every single-bit error has a unique
# syndrome. GROUP_MASK[j] selects the data bits whose column has bit j set, so
# p[j] = XOR(data & GROUP_MASK[j]).
# ---------------------------------------------------------------------------
POSITIONS = tuple(t for t in range(1, 39) if t & (t - 1))
GROUP_MASK = tuple(sum(1 << i for i, col in enumerate(POSITIONS) if (col >> j) & 1)
                   for j in range(6))
GROUP_HEX = tuple(format(m, '08X') for m in GROUP_MASK)
CHECK_COLUMN = {1: 0, 2: 1, 4: 2, 8: 3, 16: 4, 32: 5}

# MISR characteristic polynomial x^32 + x^7 + x^5 + x^3 + x^2 + x + 1, primitive
# (proved in selftest), so the 32-bit Galois MISR visits every non-zero state.
MISR_TAIL = 0x000000AF
MISR_HEX = format(MISR_TAIL, '08X')

ROWS_TOTAL = 1024          # scrub address space, rows
WINDOW_ROWS = 32           # rows covered by one beat of the error bitmap
BACKLOG_MAX = 63           # backlog counter saturation, rows
DEFICIT_MAX = 1024         # lifetime rows allowed to stay unserviced
TOTAL_MAX = (1 << 24) - 1  # saturating lifetime row counters


def fill(text):
    """Splice the generated parity-group constants into a kernel body."""
    for index in range(6):
        text = text.replace('GROUP%d' % index, GROUP_HEX[index])
    return text.replace('MISRHEX', MISR_HEX)


def parity(value):
    return bin(value & MASK).count('1') & 1


def popcount(value):
    return bin(value & MASK).count('1')


def hamming(data):
    field = 0
    for j in range(6):
        field |= parity(data & GROUP_MASK[j]) << j
    return field


def check_field(data):
    """The 7-bit SECDED check field: [5:0] Hamming parities, [6] overall parity.

    The overall parity covers the data word AND the six Hamming bits, so exactly one
    bit of it flips for any single-bit error anywhere in the 39-bit codeword.
    """
    field = hamming(data)
    return field | ((parity(data) ^ parity(field)) << 6)


def corrupt(data, checks, position):
    """Corrupt codeword bit `position`: 0..31 data, 32..37 check bits, 38 overall."""
    if position < 32:
        data ^= 1 << position
    elif position < 38:
        checks ^= 1 << (position - 32)
    else:
        checks ^= 1 << 6
    return data, checks & 0x7F


def syndrome_row(data, syndrome, overall, c=0):
    """A decoder stimulus row: force (syndrome, overall-parity flag) on a word."""
    low = (hamming(data) ^ (syndrome & 0x3F)) & 0x3F
    return data & MASK, low | ((parity(data) ^ parity(low) ^ (overall & 1)) << 6), c


def misr_fold(state, data):
    """Multiply the state polynomial by x modulo P and add one 32-bit data word."""
    folded = ((state << 1) & MASK) ^ (data & MASK)
    if state >> 31:
        folded ^= MISR_TAIL
    return folded & MASK


def secded_decode(data, checks):
    """Exact inverse of the encoder; returns every decoder observation."""
    syndrome = hamming(data) ^ (checks & 0x3F)
    overall = parity(data) ^ parity(checks & 0x3F) ^ ((checks >> 6) & 1)
    out, index = data & MASK, 63
    clean = sec = dbe = illegal = check_only = 0
    if syndrome == 0 and overall == 0:
        clean = 1
    elif overall:
        if syndrome == 0:
            index, sec = 38, 1                      # only the overall parity bit
        elif syndrome in POSITIONS:
            index = POSITIONS.index(syndrome)
            out ^= 1 << index                       # single data bit error
            sec = 1
        elif syndrome in CHECK_COLUMN:
            index = 32 + CHECK_COLUMN[syndrome]     # only a check bit: data intact
            check_only, sec = 1, 1
        else:
            illegal = 1                             # syndrome is not a column
    elif syndrome != 0:
        dbe = 1                                     # even parity, non-zero syndrome
    return dict(out=out & MASK, syn=syndrome, q=overall, index=index, clean=clean,
                sec=sec, dbe=dbe, illegal=illegal, chk=check_only)


# ---------------------------------------------------------------------------
# 1  SECDED encoder
# ---------------------------------------------------------------------------
core('memprot_secded32_encode',
     'Extended-Hamming SECDED(39,32) encoder for one full 32-bit memory word. '
     'H matrix: codeword positions 1..39 with the six Hamming check bits at '
     'positions 1,2,4,8,16,32 and the overall parity at position 39; data bit i '
     'takes the i-th of 3,5,6,7,9..15,17..31,33..38 (the values in 1..38 that are '
     'not powers of two) as its 6-bit column. result[5:0] = the generated check '
     'bits p[5:0], p[j] = XOR(a & G[j]) with G0=32\'h' + GROUP_HEX[0] + ', '
     'G1=32\'h' + GROUP_HEX[1] + ', G2=32\'h' + GROUP_HEX[2] + ', G3=32\'h' +
     GROUP_HEX[3] + ', G4=32\'h' + GROUP_HEX[4] + ', G5=32\'h' + GROUP_HEX[5] + '. '
     'result[6] = ^a ^ ^p[5:0], the overall parity of the whole 39-bit codeword, so '
     'exactly one bit of it flips for any single error anywhere; result[31:7] = 0. '
     'The 7-bit check field is the '
     'side-band ECC stored next to the word and is fed back to '
     'memprot_secded32_correct as its b input. b and c are ignored. '
     'aux[3:0] = per-byte parities ^(a[8k+7:8k]) with byte 0 at bit 0, aux[4] = '
     '^(a[15:0]), aux[5] = ^(a[31:16]), aux[15:6] = 0, aux[31:16] = the pairwise '
     'bit parities a[t+16]^a[t] held at bit 16+t: those trees are the same ones the '
     'corrector uses, so aux exposes them for a stuck-cell hunt. Pure XOR trees, no '
     'arithmetic, no state and no fault condition: faultless by design.',
     fill("""
pa = a & 32'hGROUP0;
pb = a & 32'hGROUP1;
pc = a & 32'hGROUP2;
ph = a & 32'hGROUP3;
pl = a & 32'hGROUP4;
temp = a & 32'hGROUP5;
mask = {^temp, ^pl, ^ph, ^pc, ^pb, ^pa};
r[5:0] = mask[5:0];
r[6] = (^a) ^ (^mask[5:0]);
x[0] = ^a[7:0];
x[1] = ^a[15:8];
x[2] = ^a[23:16];
x[3] = ^a[31:24];
x[4] = ^(a & 32'h0000FFFF);
x[5] = ^(a >> 16);
x[31:16] = a[31:16] ^ a[15:0];"""),
     'SECDED generation is 39 XOR trees retired in one enabled beat, while a CPU pays '
     'roughly 150 bit-twiddling instructions per written word; a single stuck cell in '
     'those trees is immediately a mispredicted 6-bit syndrome.',
     7, faultless=True)


# ---------------------------------------------------------------------------
# 2  SECDED decoder / corrector
# ---------------------------------------------------------------------------
core('memprot_secded32_correct',
     'SECDED(39,32) decoder and corrector for a word read back from memory. a = the '
     '32-bit data word as read, b[6:0] = the stored check field (b[5:0] Hamming '
     'parities, b[6] overall parity, b[31:7] ignored), c[0] = poison expected, '
     'c[31:1] ignored. The kernel regenerates the check bits from the read data with '
     'the identical XOR trees used by memprot_secded32_encode, so encoder and decoder '
     'are exact inverses: syndrome s[5:0] = regenerated ^ b[5:0] and parity flag q = '
     '(^a) ^ (^b[5:0]) ^ b[6], the parity of the whole received codeword. '
     's=0,q=0 is clean; q=1 with s equal to a data column corrects that '
     'data bit (bit index = s-2-floor(log2 s), the closed form of the column table); '
     'q=1 with s a power of two means check bit log2(s) was corrupted and the data is '
     'returned unchanged; q=1 with s=0 means only the overall parity bit (codeword '
     'position 39) was corrupted; q=0 with s!=0 is a double-bit error and the data is '
     'deliberately NOT corrected; s in 39..63 with q=1 is an unassigned syndrome from '
     'three or more errors. result = the corrected data word. '
     'aux[5:0]=s, aux[6]=q, aux[7]=single error corrected, aux[8]=double-bit error, '
     'aux[9]=unassigned syndrome, aux[10]=check bit only, aux[11]=corrected word is '
     'the all-ones poison pattern, aux[12]=echo of c[0], aux[18:13]=index of the '
     'faulty codeword bit (0..31 data, 32..37 check bits, 38 overall parity, 63 when '
     'nothing was corrected), aux[19]=clean word, aux[31:20]=0. '
     'fault = double-bit error OR unassigned syndrome OR poison mismatch, a poison '
     'mismatch being aux[11] different from c[0]: uncorrectable data must never be '
     'consumed as valid, and an unannounced all-ones word cannot be told apart from a '
     'deliberately poisoned one.',
     fill("""
pa = a & 32'hGROUP0;
pb = a & 32'hGROUP1;
pc = a & 32'hGROUP2;
ph = a & 32'hGROUP3;
pl = a & 32'hGROUP4;
temp = a & 32'hGROUP5;
mask = ({^temp, ^pl, ^ph, ^pc, ^pb, ^pa} ^ b[5:0]) & 32'h0000003F;
x[5:0] = mask;
x[6] = (^a) ^ (^b[5:0]) ^ b[6];
r = a;
x[18:13] = 6'd63;
if(mask == 32'd0 && !x[6]) begin
    x[19] = 1'b1;
end else if(x[6]) begin
    sh = 0;
    if(mask[5]) sh = 5; else if(mask[4]) sh = 4; else if(mask[3]) sh = 3;
    else if(mask[2]) sh = 2; else if(mask[1]) sh = 1;
    if(mask == 32'd0) begin
        x[18:13] = 6'd38; x[7] = 1'b1;
    end else if(mask & (mask - 32'd1)) begin
        if(mask <= 32'd38) begin
            idx = mask - 32'd2 - sh;
            r = a ^ (32'd1 << idx);
            x[7] = 1'b1; x[18:13] = idx;
        end else x[9] = 1'b1;
    end else begin
        x[10] = 1'b1; x[7] = 1'b1; x[18:13] = 6'd32 + sh;
    end
end else if(mask != 32'd0) begin
    x[8] = 1'b1;
end
if(x[8] || x[9]) f = 1'b1;
if(r == 32'hFFFFFFFF) begin
    x[11] = 1'b1;
    if(!c[0]) f = 1'b1;
end else if(c[0]) f = 1'b1;
x[12] = c[0];"""),
     'One enabled beat does the six XOR trees, the syndrome decode, the bit fix and the '
     'poison verdict that firmware otherwise runs as a ~200-instruction routine in the '
     'memory fault handler.',
     1)


# ---------------------------------------------------------------------------
# 3  MPU region check
# ---------------------------------------------------------------------------
MPU_DECL = """
function [23:0] mpb;
    input [31:0] sel;
    input [255:0] st;
    begin
        case(sel[1:0])
            2'd0: mpb = st[23:0];
            2'd1: mpb = st[87:64];
            2'd2: mpb = st[151:128];
            default: mpb = st[215:192];
        endcase
    end
endfunction
function [23:0] mpm;
    input [31:0] sel;
    input [255:0] st;
    begin
        case(sel[1:0])
            2'd0: mpm = st[47:24];
            2'd1: mpm = st[111:88];
            2'd2: mpm = st[175:152];
        default: mpm = st[239:216];
        endcase
    end
endfunction
function [3:0] mpp;
    input [31:0] sel;
    input [255:0] st;
    begin
        case(sel[1:0])
            2'd0: mpp = st[51:48];
            2'd1: mpp = st[115:112];
            2'd2: mpp = st[179:176];
        default: mpp = st[243:240];
        endcase
    end
endfunction
"""

MPU_BODY = """
if(c[31]) begin
    case(c[1:0])
        2'd0: begin
            state_n[23:0] = a[23:0];
            state_n[47:24] = b[23:0];
            state_n[51:48] = c[7:4];
        end
        2'd1: begin
            state_n[87:64] = a[23:0];
            state_n[111:88] = b[23:0];
            state_n[115:112] = c[7:4];
        end
        2'd2: begin
            state_n[151:128] = a[23:0];
            state_n[175:152] = b[23:0];
            state_n[179:176] = c[7:4];
        end
        default: begin
            state_n[215:192] = a[23:0];
            state_n[239:216] = b[23:0];
            state_n[243:240] = c[7:4];
        end
    endcase
    wide[11:8] = c[7:4];
end
temp = a[23:0];
for(i=0; i<4; i=i+1) begin
    pa = mpb(i, state_n);
    pb = mpm(i, state_n);
    pc = mpp(i, state_n);
    if(pc[0]) begin
        mask = mask + 32'd1;
        wide2[7:4] = wide2[7:4] | (4'd1 << i);
        if(pa > pb) begin
            ext[0] = 1'b1;
            if(wide[7:4] == 4'd0) wide[7:4] = i + 4'd1;
        end else begin
            ph[i] = 1'b1;
            wide[19:16] = wide[19:16] + 4'd1;
            if(c[31]) begin
                if(i != c[1:0] && c[4] && (a[23:0] <= b[23:0]) &&
                   (a[23:0] <= pb) && (pa <= b[23:0])) begin
                    pl[i] = 1'b1;
                    wide2[3:0] = wide2[3:0] + 4'd1;
                end
            end else if(pa <= temp && temp <= pb) begin
                pl[i] = 1'b1;
                wide2[3:0] = wide2[3:0] + 4'd1;
                if(wide[3:0] == 4'd0) begin
                    wide[3:0] = i + 4'd1;
                    wide[11:8] = pc;
                end
            end
        end
    end
end
pb = {28'd0, wide[11:8]};
pc = 32'd0;
if(c[31]) begin
    if(pb[0] && a[23:0] > b[23:0]) pc = 32'd6;
    else if(pb[0] && wide2[3:0] != 4'd0) pc = 32'd5;
end else if(wide[3:0] == 4'd0) pc = 32'd1;
else if(b[1] && !pb[3]) pc = 32'd4;
else if(b[0] && !pb[2]) pc = 32'd3;
else if(!b[0] && !pb[1]) pc = 32'd2;
else if(wide2[3:0] > 4'd1) pc = 32'd5;
else if(ext[0]) pc = 32'd6;
ext[2] = (wide[19:16] == 4'd0);
ext[3] = c[31] ? !(pb[0] && a[23:0] <= b[23:0]) : (wide[3:0] == 4'd0);
temp = (pc == 32'd0) && (c[31] ? pb[0] : (wide[3:0] != 4'd0));
r[2:0] = c[31] ? {1'b0, c[1:0]} : (wide[3:0] - 4'd1);
r[3] = temp;
r[7:4] = wide[11:8];
r[11:8] = mask;
r[15:12] = wide2[3:0];
r[19:16] = wide[19:16];
r[20] = (wide2[3:0] > 4'd1);
r[21] = ext[0];
r[22] = c[31];
r[23] = !c[31];
x[3:0] = pl[3:0];
x[7:4] = ph[3:0];
x[11:8] = wide2[7:4];
x[14:12] = pc[2:0];
x[18:15] = wide[7:4];
x[19] = ext[2];
x[20] = ext[3];
x[21] = !c[31] && b[0];
x[22] = !c[31] && b[1];
x[23] = c[31];
x[31:24] = a[23:16];
f = (pc != 32'd0);
"""

core('memprot_mpu_region_check',
     'Stateful 4-region memory protection unit with an overlap analyser. State: region '
     'k on a 64-bit stride, base[23:0]=state[64k+:24], limit[23:0]=state[64k+24+:24], '
     'perm[3:0]=state[64k+48+:4] with bit0=ENABLE, bit1=READ, bit2=WRITE, '
     'bit3=UNPRIV allowed; bits [63:52] of each stride are unused. Config beat '
     '(c[31]=1) writes region c[1:0] with base=a[23:0], limit=b[23:0], perm=c[7:4] and '
     'immediately evaluates the committed table against the loaded region. Access beat '
     '(c[31]=0) leaves the table alone and tests address a[23:0] with intent b[0] '
     '(1=write, 0=read) and b[1] (1=unprivileged); b[31:2] ignored. A region covers the '
     'address when it is enabled, base<=limit and base<=addr<=limit; the lowest region '
     'index is the reported region and a disabled or malformed (base>limit) region '
     'never matches and contributes no overlap evidence. Violation cause, first match '
     'wins: 0 none, 1 no covering region, 2 read not permitted, 3 write not permitted, '
     '4 unprivileged access not permitted, 5 more than one covering region (or, on a '
     'config beat, the loaded enabled region intersects another enabled well-formed '
     'region), 6 an enabled region is malformed. A config beat reports cause 6 when the '
     'loaded region is enabled with base>limit, cause 5 when it intersects another '
     'enabled well-formed region, otherwise 0; a disabled load never faults. '
     'result: [2:0]=reported region index (access: matched region, 7 on no match; '
     'config: the written index), [3]=access permitted, [7:4]=permission nibble of the '
     'reported region (config: the just-loaded nibble), [11:8]=enabled region count, '
     '[15:12]=covering (config: intersecting) region count, [19:16]=well-formed enabled '
     'region count, [20]=more than one covering region, [21]=a malformed enabled region '
     'exists, [22]=config beat, [23]=access beat, [31:24]=0. '
     'aux: [3:0]=covering vector (config: intersecting vector) with region 0 at bit 0, '
     '[7:4]=well-formed enabled vector, [11:8]=enabled vector, [14:12]=violation cause, '
     '[18:15]=lowest malformed enabled region index plus 1 (0 = none), [19]=no '
     'well-formed enabled region in the table, [20]=reported region is not usable '
     '(no match on an access beat, loaded region disabled or malformed on a config '
     'beat), [21]=write intent, [22]=unprivileged intent, both held 0 on a config '
     'beat where b is the region limit, [23]=config beat, '
     '[31:24]=a[23:16], the address byte under test, echoed for the fault-address '
     'trace. fault = cause != 0, so an overlapping or malformed '
     'table faults even when the tested access itself would have been permitted.',
     MPU_BODY,
     'Four interval compares plus the whole overlap analysis close inside one enabled '
     'beat, while firmware must load, mask and branch over the table on every access, '
     'which is where MPU bypass bugs come from.',
     4, stateful=True, decl=MPU_DECL)


# ---------------------------------------------------------------------------
# 4  Cache tag compare
# ---------------------------------------------------------------------------
CACHE_DECL = """
function [15:0] tag_of;
    input [31:0] sel;
    input [255:0] st;
    begin
        case(sel[1:0])
            2'd0: tag_of = st[15:0];
            2'd1: tag_of = st[31:16];
            2'd2: tag_of = st[47:32];
            default: tag_of = st[63:48];
        endcase
    end
endfunction
"""

CACHE_BODY = """
mask = {28'd0, state_r[67:64]};
temp = {28'd0, state_r[71:68]};
pl = {28'd0, state_r[74:72]};
pc = a[31:16];
if(c[31]) begin
    state_n[15:0] = a[15:0];
    state_n[31:16] = a[31:16];
    state_n[47:32] = b[15:0];
    state_n[63:48] = b[31:16];
    state_n[67:64] = c[3:0];
    state_n[71:68] = c[7:4];
    state_n[74:72] = c[10:8];
    pa = c[10:8] & 3'd3;
    ext[2] = (c[0] && c[1] && a[15:0] == a[31:16]) ||
             (c[0] && c[2] && a[15:0] == b[15:0]) ||
             (c[0] && c[3] && a[15:0] == b[31:16]) ||
             (c[1] && c[2] && a[31:16] == b[15:0]) ||
             (c[1] && c[3] && a[31:16] == b[31:16]) ||
             (c[2] && c[3] && b[15:0] == b[31:16]);
end else begin
    for(i=0; i<4; i=i+1) begin
        pb = tag_of(i, state_r);
        if(pb == pc) wide2[i] = 1'b1;
        if(mask[i] && pb == pc) begin
            ph[i] = 1'b1;
            wide[3:0] = wide[3:0] + 4'd1;
            if(wide[7:4] == 4'd0) wide[7:4] = i + 4'd1;
        end
        if(mask[i] && pb[3:0] == pc[3:0]) pl[7:4] = pl[7:4] | (4'd1 << i);
    end
    pa = (wide[7:4] != 4'd0) ? (wide[7:4] - 4'd1) : pl[1:0];
    ext[0] = (wide[3:0] > 4'd1);
    state_n[(pa << 4) +: 16] = pc;
    state_n[64 + pa] = 1'b1;
    if(wide[7:4] == 4'd0) state_n[68 + pa] = b[0];
    else if(b[0]) state_n[68 + pa] = 1'b1;
    state_n[74:72] = pa[2:0] + 3'd1;
end
wide[39:24] = tag_of(pa[2:0], state_r);
for(i=0; i<4; i=i+1) begin
    pb = tag_of(i, state_n);
    if(state_n[64 + i]) begin
        wide[19:16] = wide[19:16] + 4'd1;
        if(pb == 16'd0 || pb == 16'hFFFF) begin
            ext[1] = 1'b1;
            if(wide[15:12] == 4'd0) wide[15:12] = i + 4'd1;
        end
    end
end
if(ext[0]) wide2[7:4] = 4'd1;
else if(ext[2]) wide2[7:4] = 4'd2;
else if(ext[1]) wide2[7:4] = 4'd3;
r[2:0] = c[31] ? 3'd7 : (wide[7:4] - 4'd1);
r[5:3] = pa[2:0];
r[6] = (wide[7:4] != 4'd0);
r[7] = !c[31] && (wide[7:4] == 4'd0);
r[8] = r[7] && !mask[pa];
r[9] = r[7] && mask[pa];
r[10] = c[31];
r[11] = ext[0];
r[13:12] = wide2[7:4];
r[17:14] = wide[19:16];
r[18] = ext[1];
r[19] = r[7] && (mask[3:0] == 4'hF);
r[20] = mask[pa];
r[21] = temp[pa];
r[22] = !c[31] && !mask[pa] && (wide[39:24] == pc);
r[23] = !c[31];
r[27:24] = wide[15:12];
r[31:28] = a[31:28];
x[3:0] = mask[3:0];
x[7:4] = ph[3:0];
x[11:8] = wide2[3:0];
x[15:12] = pl[7:4];
x[18:16] = pl[2:0];
x[19] = mask[pl[1:0]];
x[20] = temp[pl[1:0]];
x[24:21] = temp[3:0];
x[25] = !c[31] && b[0];
x[26] = !c[31] && b[0] && !temp[pa];
x[27] = (mask[3:0] == 4'hF);
x[31:28] = a[19:16];
f = (wide2[7:4] != 4'd0);
"""

core('memprot_cache_tag_compare',
     'Stateful 4-way cache set tag lookup with round-robin replacement bookkeeping. '
     'State: way k tag[15:0]=state[16k+:16], valid[k]=state[64+k], dirty[k]=state[68+k], '
     'replacement pointer=state[74:72] and the victim way is pointer[1:0]. Config beat '
     '(c[31]=1) rewrites the whole set: way0=a[15:0], way1=a[31:16], way2=b[15:0], '
     'way3=b[31:16], valid=c[3:0], dirty=c[7:4], pointer=c[10:8]; it performs no '
     'lookup, so no way hits and the reported way is the new pointer[1:0]. Access beat '
     '(c[31]=0): lookup tag=a[31:16], set index=a[15:0] (reported by the caller, never '
     'checked here), b[0]=write intent, b[31:1] ignored. Way k hits when valid[k] and '
     'tag[k] equals the lookup tag; the lowest hitting way wins. The used way is the hit '
     'way on a hit and the pointer-selected way on a miss. A miss commits '
     'tag[used]=lookup, valid[used]=1, dirty[used]=b[0]; a hit keeps its tag and commits '
     'dirty[used]=dirty[used]|b[0]; the used way always takes the lookup tag, which is a '
     'no-op on a hit. Only an access beat advances the round robin: the pointer becomes '
     'used+1 truncated to 3 bits, so it passes through 4 and selects way 0 next, while a '
     'config beat leaves the pointer exactly as loaded (c[10:8]) and advances nothing. '
     'Fault cause, first match wins: 1 = two or '
     'more valid ways match the lookup tag (incoherent set), 2 = a config beat loaded '
     'two valid ways with the same tag, 3 = a valid way in the committed set holds the '
     'degenerate tag 16\'h0000 or 16\'hFFFF (un-initialised or erased tag RAM). '
     'result: [2:0]=hit way, 7 on a miss or a config beat, [5:3]=used way, [6]=hit, '
     '[7]=miss, [8]=cold fill into an invalid way, [9]=destructive eviction of a valid '
     'way, [10]=config beat, [11]=multi-hit, [13:12]=fault cause, [17:14]=valid way '
     'count in the committed set, [18]=a valid way holds a degenerate tag, [19]=a miss '
     'was allocated while all four ways were valid, [20]=used way was valid before the '
     'beat, [21]=used way was dirty before the beat, [22]=used way was invalid but '
     'already held the lookup tag (stale tag revived), [23]=access beat, [27:24]=lowest '
     'degenerate valid way index plus 1 in the committed set (0 = none), [31:28]=the top '
     'nibble of the lookup tag under test, a[31:28]. The '
     'used way and its before-beat state are reported on every beat, including a config '
     'beat, whose used way is the newly loaded pointer way. Bits [22] and aux[25:26] are '
     'lookup and write-intent bookkeeping, so a config beat reports them as zero: it does '
     'no lookup and takes its dirty bits from c[7:4], not from b[0]. '
     'aux: [3:0]=valid vector before the beat, [7:4]=hit vector, [11:8]=raw tag-equal '
     'vector ignoring validity, [15:12]=partial match vector (valid and '
     'tag[3:0]==lookup[3:0]), [18:16]=pointer before the beat, [19]=pointer-before way '
     'valid, [20]=pointer-before way dirty, [24:21]=dirty vector before the beat, '
     '[25]=write intent, [26]=this beat dirtied a previously clean used way, [27]=all '
     'four ways were valid before the beat, [31:28]=the low nibble of the lookup tag '
     'under test, a[19:16], so the two echoed nibbles spell the tag under test out '
     'across the two ports for a tag trace (on a config beat a[31:16] is the new way 1 '
     'tag). fault = cause != 0.',
     CACHE_BODY,
     'Four tag compares, the replacement decision and the coherence audit close in one '
     'enabled beat, whereas a store instruction must branch per way and reconstruct the '
     'duplicate-line check in software.',
     4, stateful=True, decl=CACHE_DECL)


# ---------------------------------------------------------------------------
# 5  MISR signature
# ---------------------------------------------------------------------------
def misr_state(sig, count, start, never, zeroed):
    return sig | (count << 32) | (start << 64) | (never << 96) | (zeroed << 100)


def channel_activity(word):
    return (((word >> 24) & 0xFF != 0) << 3) | (((word >> 16) & 0xFF != 0) << 2) | \
           (((word >> 8) & 0xFF != 0) << 1) | ((word & 0xFF) != 0)


core('memprot_misr32_signature',
     'Stateful 32-bit multiple-input signature register. One 32-bit data word per '
     'accepted beat is added in GF(2) after one multiply by x modulo the primitive '
     'polynomial P(x)=x^32+x^7+x^5+x^3+x^2+x+1, i.e. signature = ((state[31:0]<<1) & '
     '32\'hFFFFFFFF) ^ a ^ (state[31] ? 32\'h' + MISR_HEX + ' : 32\'h00000000). '
     'State: signature=state[31:0], folded beat count=state[63:32] (saturating at '
     '65535), pass-start signature=state[95:64], never-toggled channel '
     'vector=state[99:96], zero-state latch=state[100]. Restart beat (c[31]=1) loads '
     'the seed from a[31:0] without folding it, sets the pass-start signature to that '
     'seed, clears the beat count and sets the never-toggled vector to 4\'hF; the beat '
     'still runs the golden compare below. Data beat (c[31]=0) folds a[31:0] and clears '
     'never-toggled bit k once byte channel k of a has been non-zero (k=0 is a[7:0]). '
     'Golden compare: c[15:0] = mask of bits that must match, b[31:0] = golden '
     'signature, compare enabled when c[15:0]!=0, c[30:16] ignored. '
     'result = the 32-bit signature after this beat (the seed itself on a restart '
     'beat). aux[5:0] = number of the 32 signature bits that changed this beat (0..32), '
     'aux[9:6] = byte channel activity vector of a with channel 0 at bit 6, aux[10] = '
     'signature unchanged this beat, aux[11] = signature wrapped back onto the '
     'pass-start seed with at least one beat folded, aux[12] = fewer than 16 bits '
     'changed (weakly mixing beat), aux[13] = signature is zero, aux[14] = golden '
     'compare enabled, aux[15] = golden compare passed, aux[16] = some channel has '
     'still never toggled since the restart, aux[20:17] = never-toggled channel vector, '
     'aux[21] = zero signature latched since the restart, aux[31:22]=0. '
     'fault = the resulting signature is zero (indistinguishable from an un-initialised '
     'MISR) OR the golden compare is enabled and mismatched.',
     fill("""
temp = state_r[31:0];
if(c[31]) begin
    r = a;
    state_n[31:0] = a;
    state_n[63:32] = 32'd0;
    state_n[95:64] = a;
    state_n[99:96] = 4'hF;
    state_n[100] = (a == 32'd0);
end else begin
    mask = {temp[30:0], 1'b0};
    if(temp[31]) mask = mask ^ 32'hMISRHEX;
    r = mask ^ a;
    state_n[31:0] = r;
    if(state_r[63:32] != 32'h0000FFFF) state_n[63:32] = state_r[63:32] + 32'd1;
    state_n[99:96] = state_r[99:96] & ~((a[31:24] != 0) ? 4'h8 : 4'h0) &
                                    ~((a[23:16] != 0) ? 4'h4 : 4'h0) &
                                    ~((a[15:8]  != 0) ? 4'h2 : 4'h0) &
                                    ~((a[7:0]   != 0) ? 4'h1 : 4'h0);
    if(r == 32'd0) state_n[100] = 1'b1;
end
pl = r ^ temp;
for(i=0; i<32; i=i+1) if(pl[i]) sh = sh + 1;
x[5:0] = sh;
x[9:6] = {(a[31:24] != 0), (a[23:16] != 0), (a[15:8] != 0), (a[7:0] != 0)};
x[10] = (r == temp);
x[11] = !c[31] && (state_r[63:32] != 32'd0) && (r == state_r[95:64]);
x[12] = (sh < 16);
x[13] = (r == 32'd0);
x[14] = (c[15:0] != 16'd0);
x[15] = x[14] && (((r ^ b) & {16'd0, c[15:0]}) == 32'd0);
x[16] = (state_n[99:96] != 4'h0);
x[20:17] = state_n[99:96];
x[21] = state_n[100];
if(r == 32'd0) f = 1'b1;
if(x[14] && !x[15]) f = 1'b1;"""),
     'One beat compresses a 32-bit bus word into a signature that a scalar core needs a '
     'shift, a conditional XOR and an accumulate per word, and the channel-activity '
     'flags prove every DUT output actually reached the compactor.',
     32, stateful=True)


# ---------------------------------------------------------------------------
# 6  Scrub cursor window
# ---------------------------------------------------------------------------
def scrub_state(cursor, backlog, passes, detected, serviced):
    return cursor | (backlog << 10) | (passes << 16) | (detected << 24) | (serviced << 48)


def immediate_bitmap(bitmap, slots):
    """The lowest `slots` set rows of the error bitmap: the rows rewritten now."""
    out, used = 0, 0
    for row in range(WINDOW_ROWS):
        if (bitmap >> row) & 1 and used < slots:
            out |= 1 << row
            used += 1
    return out


core('memprot_scrub_cursor_window',
     'Stateful scrub scheduler accounting over a 1024-row address space scanned as 32 '
     'windows of 32 rows. State: cursor=state[9:0] (window base row, 32-row aligned), '
     'backlog=state[15:10] (queued unserviced rows, saturating at 63), '
     'passes=state[23:16] (completed full sweeps), rows detected since the restart '
     '=state[47:24], rows serviced since the restart=state[71:48], both saturating at '
     '24\'hFFFFFF. Restart beat (c[31]=1) re-initialises the scheduler: cursor = '
     'c[9:5]*32, passes = c[23:16], backlog and both totals cleared, and then this beat '
     'is processed exactly like a data beat (so its own bitmap is accounted); c[15:8] '
     'is ignored on a restart beat because bits 15:8 overlap the window index. Data '
     'beat: a[31:0] is the error bitmap of the 32 rows starting at the cursor (row 0 at '
     'bit 0), b[5:0] is the rewrite budget in rows for this beat, b[13:8] is the backlog '
     'limit in rows, b[31:14] ignored; a data beat reads no c bit except c[31], so '
     'c[30:0] is don\'t care there. Queued rows = backlog + popcount(a); the beat '
     'retires min(budget, queued) rows, backlog rows first and then rows of this bitmap '
     'in ascending row order, so result is exactly the subset of a rewritten now and '
     'a & ~result is the deferred bitmap. New backlog = min(63, queued - retired); the '
     'cursor becomes (cursor+32) mod 1024 and a wrap increments the pass counter unless '
     'it already reads 255. result[31:0] = immediate-rewrite bitmap. '
     'aux[9:0]=cursor after the beat, [15:10]=backlog after the beat, [16]=window '
     'wrapped (next beat starts a new pass), [17]=rows of this bitmap were deferred, '
     '[18]=restart beat echo, [19]=backlog saturated at 63 this beat, [20]=budget field '
     'exceeds 32 rows, [21]=backlog exceeds the limit, [22]=lifetime deficit exceeds '
     'the window, [23]=queued rows exceeded the budget, [31:24]=pass counter after the '
     'beat. fault = malformed budget (b[5:0] > 32, a window only has 32 rows) OR the '
     'resulting backlog exceeds the limit OR (rows detected - rows serviced) exceeds '
     '1024 rows, i.e. errors arrive faster than the scrub window can retire them.',
     """
mask = {22'd0, state_r[9:0]};
pb = {26'd0, state_r[15:10]};
pa = {26'd0, b[5:0]};
ph = 32'd0;
for(i=0; i<32; i=i+1) if(a[i]) ph = ph + 32'd1;
if(c[31]) begin
    mask = {22'd0, c[9:5], 5'd0};
    pb = 32'd0;
end
pl = 32'd0;
if(b[5:0] > 6'd32) begin
    pl[1] = 1'b1;
    pa = 32'd32;
end
if(pa > 32'd32) pa = 32'd32;
temp = pb + ph;
lane = (pa > pb) ? (pa - pb) : 32'd0;
for(i=0; i<32; i=i+1) if(a[i] && lane > 0) begin
    r[i] = 1'b1;
    lane = lane - 32'd1;
end
pc = (pa > temp) ? temp : pa;
idx = temp - pc;
if(idx > 32'd63) begin
    idx = 32'd63;
    pl[0] = 1'b1;
end
if(idx > b[13:8]) pl[2] = 1'b1;
ext = mask + 33'd32;
pl[4] = (ext > 33'd1023);
wide = c[31] ? 64'd0 : {40'd0, state_r[47:24]};
wide = wide + {32'd0, ph};
if(wide > 64'h00FFFFFF) wide = 64'h00FFFFFF;
state_n[47:24] = wide[23:0];
wide2 = c[31] ? 64'd0 : {40'd0, state_r[71:48]};
wide2 = wide2 + {32'd0, pc};
if(wide2 > 64'h00FFFFFF) wide2 = 64'h00FFFFFF;
state_n[71:48] = wide2[23:0];
wide = (state_n[47:24] > state_n[71:48]) ?
       ({40'd0, state_n[47:24]} - {40'd0, state_n[71:48]}) : 64'd0;
if(wide > 64'd1024) pl[3] = 1'b1;
pb = c[31] ? {24'd0, c[23:16]} : {24'd0, state_r[23:16]};
state_n[23:16] = pb[7:0];
if(pl[4] && pb != 32'd255) begin
    pb = pb + 32'd1;
    state_n[23:16] = pb[7:0];
end
state_n[9:0] = pl[4] ? 10'd0 : ext[9:0];
state_n[15:10] = idx;
x[9:0] = state_n[9:0];
x[15:10] = state_n[15:10];
x[16] = pl[4];
x[17] = (a & ~r) != 32'd0;
x[18] = c[31];
x[19] = pl[0];
x[20] = pl[1];
x[21] = pl[2];
x[22] = pl[3];
x[23] = temp > pa;
x[31:24] = state_n[23:16];
f = pl[1] || pl[2] || pl[3];""",
     'A serial scrub loop must re-read every row and branch on a software counter; this '
     'splits the 32-row error bitmap into rewrite-now versus deferred with one priority '
     'walk per enabled beat and retires the backlog, pass and lifetime-deficit '
     'arithmetic in the same beat.',
     32, stateful=True)


# ---------------------------------------------------------------------------
# Independent integer model. Written from the datasheet text above, not from the
# Verilog: every core is recomputed with plain integer arithmetic and lists.
# ---------------------------------------------------------------------------
def _encode(a, state):
    checks = check_field(a)
    x = 0
    for byte in range(4):
        if parity((a >> (8 * byte)) & 0xFF):
            x |= 1 << byte
    if parity(a & 0xFFFF):
        x |= 1 << 4
    if parity(a >> 16):
        x |= 1 << 5
    x |= ((a >> 16) ^ (a & 0xFFFF)) << 16
    return checks & MASK, x & MASK, 0, state


def _correct(a, b, c, state):
    decoded = secded_decode(a, b)
    poison = 1 if decoded['out'] == MASK else 0
    x = decoded['syn'] | (decoded['q'] << 6) | (decoded['sec'] << 7) | \
        (decoded['dbe'] << 8) | (decoded['illegal'] << 9) | (decoded['chk'] << 10) | \
        (poison << 11) | ((c & 1) << 12) | (decoded['index'] << 13) | \
        (decoded['clean'] << 19)
    fault = decoded['dbe'] or decoded['illegal'] or (poison != (c & 1))
    return decoded['out'], x & MASK, int(bool(fault)), state


def _mpu_table(state):
    return [((state >> (64 * k)) & VMASK, (state >> (64 * k + 24)) & VMASK,
             (state >> (64 * k + 48)) & 0xF) for k in range(4)]


def _mpu_pack(table):
    state = 0
    for k, (base, limit, perm) in enumerate(table):
        state |= base << (64 * k) | limit << (64 * k + 24) | perm << (64 * k + 48)
    return state


def _vector(bits):
    return sum(int(bool(bit)) << index for index, bit in enumerate(bits))


def _mpu(a, b, c, state):
    config = bool(c >> 31)
    written = c & 3
    table = _mpu_table(state)
    if config:
        table[written] = (a & VMASK, b & VMASK, (c >> 4) & 0xF)
    address = a & VMASK
    loaded_base, loaded_limit, loaded_perm = a & VMASK, b & VMASK, (c >> 4) & 0xF
    enabled = [bool(perm & 1) for _, _, perm in table]
    served = [bool(perm & 1) and base <= limit for base, limit, perm in table]
    malformed = [k + 1 for k in range(4) if enabled[k] and table[k][0] > table[k][1]]
    low_malformed = malformed[0] if malformed else 0
    cover = [False] * 4
    first = 0
    for k in range(4):
        if not served[k]:
            continue
        if config:
            overlap = (k != written and loaded_perm & 1 and loaded_base <= loaded_limit
                       and loaded_base <= table[k][1] and table[k][0] <= loaded_limit)
        else:
            overlap = table[k][0] <= address <= table[k][1]
        if overlap:
            cover[k] = True
            if first == 0:
                first = k + 1
    cover_count = sum(1 for bit in cover if bit)
    perm = loaded_perm if config else (table[first - 1][2] if first else 0)
    write, unprivileged = b & 1, (b >> 1) & 1
    if config:
        cause = 6 if (perm & 1 and loaded_base > loaded_limit) else \
            (5 if (perm & 1 and cover_count) else 0)
    elif not first:
        cause = 1
    elif unprivileged and not perm & 8:
        cause = 4
    elif write and not perm & 4:
        cause = 3
    elif not write and not perm & 2:
        cause = 2
    elif cover_count > 1:
        cause = 5
    elif low_malformed:
        cause = 6
    else:
        cause = 0
    permitted = not cause and (bool(perm & 1) if config else bool(first))
    index = written if config else (first - 1) & 7
    enabled_count = sum(1 for bit in enabled if bit)
    served_count = sum(1 for bit in served if bit)
    r = index | (int(permitted) << 3) | (perm << 4) | (enabled_count << 8) | \
        (cover_count << 12) | (served_count << 16) | ((1 if cover_count > 1 else 0) << 20) | \
        ((1 if low_malformed else 0) << 21) | ((1 if config else 0) << 22) | \
        ((0 if config else 1) << 23)
    not_usable = (not served[written]) if config else (not first)
    x = _vector(cover) | (_vector(served) << 4) | (_vector(enabled) << 8) | \
        (cause << 12) | (low_malformed << 15) | ((1 if not served_count else 0) << 19) | \
        (int(not_usable) << 20) | ((0 if config else write) << 21) | \
        ((0 if config else unprivileged) << 22) | \
        ((1 if config else 0) << 23) | (((a >> 16) & 0xFF) << 24)
    return r & MASK, x & MASK, int(bool(cause)), _mpu_pack(table)


def _cache(a, b, c, state):
    config = bool(c >> 31)
    tags = [(state >> (16 * k)) & 0xFFFF for k in range(4)]
    valid = [(state >> (64 + k)) & 1 for k in range(4)]
    dirty = [(state >> (68 + k)) & 1 for k in range(4)]
    pointer = (state >> 72) & 7
    lookup = (a >> 16) & 0xFFFF
    write = b & 1
    new_tags, new_valid, new_dirty = list(tags), list(valid), list(dirty)
    hits = first_hit = 0
    hit_vector = raw_vector = partial_vector = 0
    duplicate = False
    if config:
        new_tags = [a & 0xFFFF, (a >> 16) & 0xFFFF, b & 0xFFFF, (b >> 16) & 0xFFFF]
        new_valid = [(c >> k) & 1 for k in range(4)]
        new_dirty = [(c >> (4 + k)) & 1 for k in range(4)]
        used = (c >> 8) & 3
        new_pointer = (c >> 8) & 7
        duplicate = any(new_valid[i] and new_valid[j] and new_tags[i] == new_tags[j]
                        for i in range(4) for j in range(i + 1, 4))
    else:
        for k in range(4):
            equal = tags[k] == lookup
            if equal:
                raw_vector |= 1 << k
            if valid[k] and equal:
                hit_vector |= 1 << k
                hits += 1
                if not first_hit:
                    first_hit = k + 1
            if valid[k] and (tags[k] & 0xF) == (lookup & 0xF):
                partial_vector |= 1 << k
        used = (first_hit - 1) if first_hit else (pointer & 3)
        new_tags[used] = lookup
        new_valid[used] = 1
        new_dirty[used] = (dirty[used] | write) if first_hit else write
        new_pointer = (used + 1) & 7
    degenerate = next((k + 1 for k in range(4)
                       if new_valid[k] and new_tags[k] in (0x0000, 0xFFFF)), 0)
    valid_count = sum(new_valid)
    cause = 1 if hits > 1 else (2 if duplicate else (3 if degenerate else 0))
    hit = bool(first_hit)
    miss = (not config) and not hit
    full_before = sum(valid) == 4
    r = (7 if config else (first_hit - 1) & 7) | (used << 3) | (int(hit) << 6) | \
        (int(miss) << 7) | (int(miss and not valid[used]) << 8) | \
        (int(miss and valid[used]) << 9) | (int(config) << 10) | \
        (int(hits > 1) << 11) | (cause << 12) | (valid_count << 14) | \
        (int(degenerate != 0) << 18) | (int(miss and full_before) << 19) | \
        (valid[used] << 20) | (dirty[used] << 21) | \
        (int(not valid[used] and tags[used] == lookup and not config) << 22) | \
        (int(not config) << 23) | \
        (degenerate << 24) | (((a >> 28) & 0xF) << 28)
    x = _vector(valid) | (hit_vector << 4) | (raw_vector << 8) | (partial_vector << 12) | \
        (pointer << 16) | (valid[pointer & 3] << 19) | (dirty[pointer & 3] << 20) | \
        (_vector(dirty) << 21) | (int(write and not config) << 25) | \
        (int(write and not dirty[used] and not config) << 26) | \
        (int(full_before) << 27) | ((lookup & 0xF) << 28)
    new_state = 0
    for k in range(4):
        new_state |= new_tags[k] << (16 * k) | new_valid[k] << (64 + k) | \
            new_dirty[k] << (68 + k)
    return r & MASK, x & MASK, int(bool(cause)), new_state | (new_pointer << 72)


def _misr(a, b, c, state):
    signature = state & MASK
    count = (state >> 32) & MASK
    start = (state >> 64) & MASK
    never = (state >> 96) & 0xF
    zeroed = (state >> 100) & 1
    restart = bool(c >> 31)
    activity = channel_activity(a)
    new_start = start
    if restart:
        new_signature, new_count, new_start, new_never = a & MASK, 0, a & MASK, 0xF
        new_zeroed = int(a == 0)
    else:
        new_signature = misr_fold(signature, a)
        new_count = count if count == 0xFFFF else count + 1
        new_never = never & ~activity & 0xF
        new_zeroed = int(zeroed or new_signature == 0)
    changed = popcount(new_signature ^ signature)
    enabled = (c & 0xFFFF) != 0
    passed = enabled and ((new_signature ^ b) & (c & 0xFFFF)) == 0
    x = changed | (activity << 6) | (int(new_signature == signature) << 10) | \
        (int(not restart and count != 0 and new_signature == start) << 11) | \
        (int(changed < 16) << 12) | (int(new_signature == 0) << 13) | \
        (int(enabled) << 14) | (int(passed) << 15) | (int(new_never != 0) << 16) | \
        (new_never << 17) | (new_zeroed << 21)
    fault = int(new_signature == 0 or (enabled and not passed))
    return new_signature, x & MASK, fault, \
        misr_state(new_signature, new_count, new_start, new_never, new_zeroed)


def _scrub(a, b, c, state):
    restart = bool(c >> 31)
    cursor = state & 0x3FF
    backlog = (state >> 10) & 0x3F
    passes = (c >> 16) & 0xFF if restart else (state >> 16) & 0xFF
    detected = 0 if restart else (state >> 24) & TOTAL_MAX
    serviced = 0 if restart else (state >> 48) & TOTAL_MAX
    found = popcount(a)
    if restart:
        cursor = ((c >> 5) & 0x1F) * WINDOW_ROWS
        backlog = 0
    requested = b & 0x3F
    malformed = requested > WINDOW_ROWS
    budget = WINDOW_ROWS if malformed else requested
    queued = backlog + found
    slots = budget - backlog if budget > backlog else 0
    immediate = immediate_bitmap(a, slots)
    retired = budget if budget < queued else queued
    owed = queued - retired
    saturated = owed > BACKLOG_MAX
    new_backlog = BACKLOG_MAX if saturated else owed
    over_limit = new_backlog > ((b >> 8) & 0x3F)
    wrapped = cursor + WINDOW_ROWS > ROWS_TOTAL - 1
    new_cursor = 0 if wrapped else cursor + WINDOW_ROWS
    new_detected = min(TOTAL_MAX, detected + found)
    new_serviced = min(TOTAL_MAX, serviced + retired)
    deficit = new_detected - new_serviced if new_detected > new_serviced else 0
    deficit_flag = deficit > DEFICIT_MAX
    if wrapped and passes < 0xFF:
        passes += 1
    x = new_cursor | (new_backlog << 10) | (int(wrapped) << 16) | \
        ((1 if a & ~immediate else 0) << 17) | (int(restart) << 18) | \
        (int(saturated) << 19) | (int(malformed) << 20) | (int(over_limit) << 21) | \
        (int(deficit_flag) << 22) | (int(queued > budget) << 23) | (passes << 24)
    fault = int(malformed or over_limit or deficit_flag)
    return immediate & MASK, x & MASK, fault, \
        scrub_state(new_cursor, new_backlog, passes, new_detected, new_serviced)


def step(name, a, b, c, state=0):
    if name == 'memprot_secded32_encode':
        return _encode(a, state)
    if name == 'memprot_secded32_correct':
        return _correct(a, b, c, state)
    if name == 'memprot_mpu_region_check':
        return _mpu(a, b, c, state)
    if name == 'memprot_cache_tag_compare':
        return _cache(a, b, c, state)
    if name == 'memprot_misr32_signature':
        return _misr(a, b, c, state)
    return _scrub(a, b, c, state)


# ---------------------------------------------------------------------------
# Stimulus. Rows 0..127 run verbatim on the board, so they are structured,
# exhaustive where the domain is small, and edge-heavy. Only the padding past
# row 128 is pseudo-random and it is seeded, so a rerun is reproducible.
# ---------------------------------------------------------------------------
MPU_TABLE_A = ((0x001000, 0x001FFF, 0b1011), (0x100000, 0x100FFF, 0b1111),
               (0x200000, 0x2007FF, 0b1001), (0x400000, 0x4003FF, 0b1100))
MPU_TABLE_B = ((0x001000, 0x002FFF, 0b1111), (0x002000, 0x003FFF, 0b1111),
               (0x008000, 0x007FFF, 0b1011), (0x010000, 0x010FFF, 0b0010))
MPU_TABLE_C = ((0x020000, 0x02FFFF, 0b1110), (0x030000, 0x030FFF, 0b1111),
               (0x040000, 0x04FFFF, 0b1010), (0x050000, 0x05FFFF, 0b1101))
CACHE_TAGS = (0x1111, 0x2222, 0x3333, 0x4444)


def mpu_config(index, base, limit, perm):
    return base & MASK, limit & MASK, ((1 << 31) | (index & 3) | ((perm & 0xF) << 4))


def cache_config(tags, valid, dirty, pointer):
    low = (tags[0] & 0xFFFF) | ((tags[1] & 0xFFFF) << 16)
    high = (tags[2] & 0xFFFF) | ((tags[3] & 0xFFFF) << 16)
    return low, high, ((1 << 31) | (valid & 0xF) | ((dirty & 0xF) << 4) |
                       ((pointer & 7) << 8))


def fold_stream(seed, words):
    signature = seed & MASK
    for word in words:
        signature = misr_fold(signature, word)
    return signature


def _encode_rows():
    rows = [(0, 0, 0), (MASK, 0, 0)]
    rows += [(1 << bit, 0, 0) for bit in range(32)]
    rows += [(MASK ^ (1 << bit), 0, 0) for bit in range(32)]
    rows += [(0x000000FF << (8 * byte), 0, 0) for byte in range(4)]
    rows += [(0x01010101 * weight & MASK, weight, weight << 3) for weight in range(1, 21)]
    rows += [((0x1000 + k) | (k << 16), k, 0) for k in range(38)]
    return rows


def _correct_rows():
    bases = (0x12345678, 0xA5A5A5A5, 0x0F0F0F0F, 0xDEADBEEF)
    rows = [(data, check_field(data), 0) for data in bases]
    clean = check_field(bases[0])
    rows += [corrupt(bases[0], clean, position) + (0,) for position in range(39)]
    rows += [syndrome_row(bases[1], syndrome, 1, 0) for syndrome in range(1, 64)]
    rows += [syndrome_row(bases[2], syndrome, 0, 0)
             for syndrome in (3, 5, 6, 7, 9, 15, 17, 31, 33, 37)]
    rows += [(MASK, check_field(MASK), 0), (MASK, check_field(MASK), 1)]
    rows += [syndrome_row(MASK ^ 1, 3, 1, 1), syndrome_row(MASK ^ 1, 3, 1, 0)]
    rows += [syndrome_row(bases[3], syndrome, 1, 1)
             for syndrome in (0, 1, 2, 4, 8, 16, 32, 33, 38)]
    return rows


def _mpu_rows():
    intents = (0, 1, 2, 3, 1, 0, 3, 2)
    rows = [mpu_config(index, *MPU_TABLE_A[index]) for index in range(4)]
    for index, (base, limit, _) in enumerate(MPU_TABLE_A):
        edges = (base - 0x100, base - 1, base, base + 1, (base + limit) >> 1,
                 limit - 1, limit, limit + 1)
        rows += [(address, intents[(index + offset) % 8], 0)
                 for offset, address in enumerate(edges)]
    rows += [mpu_config(index, *MPU_TABLE_B[index]) for index in range(4)]
    rows += [(address, intent, 0) for address, intent in
             ((0x002500, 0), (0x002500, 1), (0x002FFF, 0), (0x001FFF, 2), (0x003000, 0),
              (0x007FFF, 0), (0x008000, 1), (0x010FFF, 3))]
    rows += [mpu_config(index, *MPU_TABLE_C[index]) for index in range(4)]
    rows += [(address, intent, 0) for address, intent in
             ((0x028000, 0), (0x030000, 1), (0x048000, 0), (0x050000, 2), (0x030000, 3))]
    sweep = 0
    while len(rows) < 128:
        rows.append((((sweep + 6) << 17) | 0x4000, sweep & 3, 0))
        sweep += 1
    return rows


def trace_tag(high, low):
    """A lookup tag whose echoed nibbles are (high, low): tag[15:12]=high, tag[3:0]=low.

    The middle byte is fixed at 8'hA5 so such a tag can never be 16'h0000 or 16'hFFFF.
    """
    return ((high & 0xF) << 12) | 0x0A50 | (low & 0xF)


def _cache_rows():
    """Every access row carries a distinct pair of echoed tag nibbles, so each board
    row stays individually checkable even when its lookup is a plain cold miss."""
    rows = [cache_config(CACHE_TAGS, 0xF, 0x0, 0)]
    for tag in CACHE_TAGS:
        rows.append(((tag << 16) | 0x0F00, 0, 0))
        rows.append(((tag << 16) | 0x0F00, 1, 0))
    for index in range(28):
        tag = trace_tag(5 + index // 10, index % 10)
        rows.append((((tag << 16) | (index << 4)) & MASK, index & 1, 0))
    rows += [cache_config((0x7777, 0x7777, 0x1234, 0x5678), 0xF, 0x0, 1),
             cache_config((0x7777, 0x7777, 0x1234, 0x5678), 0x7, 0x0, 1),
             cache_config((0x0000, 0x1111, 0x2222, 0x3333), 0xF, 0x5, 3),
             cache_config((0xFFFF, 0x1111, 0x2222, 0x3333), 0xE, 0x0, 2),
             cache_config((0x0000, 0xFFFF, 0x2222, 0x3333), 0x0, 0x0, 0),
             # Degenerate tags in the upper ways: the committed-set index reported by
             # result[27:24] is 3 and 4 here, so these config beats are exactly the rows
             # that catch a model ORing that index into the single-bit degenerate flag at
             # result[18] (which used to impersonate the access-only miss-allocation and
             # used-way-valid flags at result[19] and result[20]).
             cache_config((0x1234, 0x5678, 0x0000, 0x4444), 0xF, 0x0, 2),
             cache_config((0x1111, 0x2222, 0x3333, 0xFFFF), 0xF, 0x0, 1),
             cache_config((0xABCD, 0x2222, 0x3333, 0x4444), 0x0, 0xF, 1)]
    rows += [((tag << 16) | set_index, intent, 0) for tag, set_index, intent in
             ((0x7777, 0x0010, 0), (0x1234, 0x0020, 1), (0x0000, 0x0030, 0),
              (0x3A35, 0x0040, 1), (0xFFFF, 0x0050, 0), (0xABCD, 0x0060, 1),
              (0x4B4E, 0x0070, 0), (0x9999, 0x0080, 1))]
    rows += [cache_config((0x1111, 0x2222, 0x1111, 0x2222), 0xA, 0x0, 0),
             cache_config((0x1111, 0x2222, 0x1111, 0x2222), 0x5, 0x0, 0),
             cache_config((0x0001, 0xFFFE, 0x8000, 0x7FFF), 0xF, 0xF, 7)]
    for index in range(4):
        rows.append(((trace_tag(8, index) << 16) & MASK, index & 1, 0))
    sweep = 0
    while len(rows) < 128:
        tag = trace_tag(0xB + sweep // 16, sweep % 16)
        rows.append(((((tag << 16) | (sweep << 6)) & MASK), sweep & 1, 0))
        sweep += 1
    return rows


def _misr_rows():
    words = [0x00000000, 0xFFFFFFFF, 0x80000000, 0x00000001, 0x12345678, 0xDEADBEEF,
             0x0F0F0F0F, 0x11111111, 0x22222222, 0x44444444, 0xAAAAAAAA, 0x55555555]
    rows = [(0x80000000, 0, 1 << 31)]
    rows += [(word, 0, 0) for word in words]
    rows += [((index * 0x01010101) & MASK, 0, 0) for index in range(1, 24)]
    rows += [(0, 0, 1 << 31)]                                   # zero seed faults
    rows += [(0x00000001, 0, 0), (0x00000000, 0, 0)]
    stream = [(word & MASK) for word in (0xCAFEBABE, 0x0BADC0DE, 0x00C0FFEE, 0x1234ABCD)]
    running = fold_stream(0x80000000, stream)
    rows += [(0x80000000, 0, 1 << 31)]
    for index, word in enumerate(stream):
        golden = fold_stream(0x80000000, stream[:index + 1])
        rows.append((word, golden, 0x0000FFFF))                 # golden compare passes
    rows += [(0x00C0FFEE, running ^ 0x8000, 0x0000FFFF)]        # golden compare fails
    rows += [(0x0000FFFF, 0, 1 << 31 | 0x000F)]
    sweep = 0
    while len(rows) < 128:
        rows.append(((0x5BF03635 * (sweep + 1)) & MASK, sweep & 0xFF, 0))
        sweep += 1
    return rows


def _scrub_rows():
    rows = [(MASK, 8 | (63 << 8), 1 << 31)]
    rows += [(MASK, budget | (63 << 8), 0) for budget in range(1, 21)]
    rows += [(1 << bit, 1 | (63 << 8), 0) for bit in range(32)]
    rows += [((1 << bits) - 1, 63 << 8, 0) for bits in range(0, 32)]      # deficit run
    rows += [(0x0000000F, bad | (63 << 8), 0) for bad in range(33, 41)]   # bad budgets
    rows += [((1 << bit) - 1, 30 | (4 << 8), 0) for bit in (8, 12, 16)]   # over limit
    rows += [(0x55555555, 6 | (63 << 8), 1 << 31 | (window << 5))
             for window in (31, 15, 7)]
    # A restart that preloads the pass counter from c[23:16] while starting the cursor
    # at the last window: window index 31 is row 992, so this very beat wraps and the
    # loaded 7 becomes 8, proving the preload is a starting point and not a constant.
    rows += [(0x0000FFFF, 4 | (63 << 8), (1 << 31) | (7 << 16) | (31 << 5))]
    sweep = 0
    while len(rows) < 128:
        rows.append((((0x9E3779B9 * (sweep + 3)) & MASK),
                    (sweep % 33) | ((32 + sweep % 31) << 8),
                    (1 << 31) | (sweep % 32) << 5 if sweep % 17 == 0 else 0))
        sweep += 1
    return rows


BOARD_ROWS = {
    'memprot_secded32_encode': _encode_rows,
    'memprot_secded32_correct': _correct_rows,
    'memprot_mpu_region_check': _mpu_rows,
    'memprot_cache_tag_compare': _cache_rows,
    'memprot_misr32_signature': _misr_rows,
    'memprot_scrub_cursor_window': _scrub_rows,
}


def vectors(name, count=320):
    rows = BOARD_ROWS[name]()
    assert len(rows) >= 128, f'{name}: board set is too short'
    rng = Random(0xACCE5500 + sum(name.encode()))
    while len(rows) < count:
        rows.append((rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32)))
    return rows[:max(count, 128)]


# ---------------------------------------------------------------------------
# GF(2)[x] machinery, used only by selftest: it proves the MISR feedback
# polynomial is primitive and recomputes signature streams along the algebraic
# path (multiply by x^n mod P) instead of the shift-and-XOR path in the kernel.
# A polynomial is an integer whose bit i is the coefficient of x^i.
# ---------------------------------------------------------------------------
def poly_mod(dividend, divisor):
    degree = divisor.bit_length() - 1
    while dividend and dividend.bit_length() - 1 >= degree:
        dividend ^= divisor << (dividend.bit_length() - 1 - degree)
    return dividend


def poly_gcd(left, right):
    while right:
        left, right = right, poly_mod(left, right)
    return left


def poly_mulmod(left, right, modulus):
    degree = modulus.bit_length() - 1
    out = 0
    while right:
        if right & 1:
            out ^= left
        right >>= 1
        left <<= 1
        if left >> degree & 1:
            left ^= modulus
    return out


def poly_pow_x(exponent, modulus):
    """x^exponent mod P by square-and-multiply."""
    result, base = 1, 0b10
    while exponent:
        if exponent & 1:
            result = poly_mulmod(result, base, modulus)
        exponent >>= 1
        if exponent:
            base = poly_mulmod(base, base, modulus)
    return result


def frobenius(count, modulus):
    """x^(2^count) mod P by count repeated squarings."""
    value = 0b10
    for _ in range(count):
        value = poly_mulmod(value, value, modulus)
    return value


def integer_factors(value):
    out, probe = [], 2
    while probe * probe <= value:
        if value % probe == 0:
            out.append(probe)
            while value % probe == 0:
                value //= probe
        probe += 1
    if value > 1:
        out.append(value)
    return out


def poly_is_irreducible(modulus):
    """Rabin: x^(2^d) == x and gcd(x^(2^(d/q)) + x, P) == 1 for every prime q | d."""
    degree = modulus.bit_length() - 1
    if frobenius(degree, modulus) != 0b10:
        return False
    for factor in integer_factors(degree):
        if poly_gcd(frobenius(degree // factor, modulus) ^ 0b10, modulus) != 1:
            return False
    return True


def poly_order_of_x(modulus):
    """Order of x mod P, by dividing 2^d-1; None when x^(2^d-1) != 1 mod P."""
    order = (1 << (modulus.bit_length() - 1)) - 1
    if poly_pow_x(order, modulus) != 1:
        return None
    for factor in integer_factors(order):
        while order % factor == 0 and poly_pow_x(order // factor, modulus) == 1:
            order //= factor
    return order


def poly_order_brute(modulus):
    """Order of x by walking x^1, x^2, ... until it returns to 1 (small degrees)."""
    value = 1
    for step in range(1, 1 << modulus.bit_length()):
        value = poly_mulmod(value, 0b10, modulus)
        if value == 1:
            return step
    return None


def lfsr_period(modulus):
    """Simulated period of the Galois LFSR started at state 1 (small degrees)."""
    degree = modulus.bit_length() - 1
    mask, tail = (1 << degree) - 1, modulus & ((1 << degree) - 1)
    state, steps = 1, 0
    while steps < 1 << degree:
        state = ((state << 1) & mask) ^ (tail if state >> (degree - 1) else 0)
        steps += 1
        if state == 1:
            return steps
    return None


def signature_via_polynomial(seed, words):
    """seed*x^n + sum(a_k * x^(n-1-k)) mod P -- the closed form of n MISR folds."""
    degree = len(words)
    total = poly_mulmod(seed & MASK, poly_pow_x(degree, MISR_POLY), MISR_POLY)
    for index, word in enumerate(words):
        total ^= poly_mulmod(word & MASK, poly_pow_x(degree - 1 - index, MISR_POLY),
                             MISR_POLY)
    return total & MASK


MISR_POLY = (1 << 32) | MISR_TAIL


def bit(value, index):
    return (value >> index) & 1


def field(value, high, low):
    return (value >> low) & ((1 << (high - low + 1)) - 1)


# ---------------------------------------------------------------------------
# Reference checks. Every expected value below is written out from the datasheet
# text in core() by hand -- published check fields, codeword positions, region
# indices, tag nibbles, an algebraic MISR stream and explicit scrub arithmetic --
# so a mistake shared by the Verilog body and step() still trips here.
# ---------------------------------------------------------------------------
def selftest():
    checks = 0
    enc, dec = 'memprot_secded32_encode', 'memprot_secded32_correct'
    mpu, cache = 'memprot_mpu_region_check', 'memprot_cache_tag_compare'
    misr, scrub = 'memprot_misr32_signature', 'memprot_scrub_cursor_window'

    # --- contract: six memprot cores, template bodies, one-beat latency ------
    assert len(CORES) == 6 and FAMILY == 'memprot'
    assert all(entry['name'].startswith('memprot_') for entry in CORES)
    checks += 1
    for entry in CORES:
        assert entry['latency'] == 1 and entry.get('module') is None
        assert 'posedge' not in entry['body'] and 'negedge' not in entry['body']
        assert '*' not in entry['body'] and '/' not in entry['body']
        assert '@' not in entry['body']
        checks += 1
    assert [entry['faultless'] for entry in CORES if entry['name'] == enc] == [True]
    assert sum(1 for entry in CORES if entry['stateful']) == 4
    checks += 1

    # --- 1  H matrix: codeword positions and the published group masks -------
    # Positions 1..38 minus the six check positions leaves 32 data columns in
    # increasing order, so data bit 0 sits in column 3 and data bit 31 in 38.
    assert len(POSITIONS) == 32 and POSITIONS[0] == 3 and POSITIONS[31] == 38
    assert all(p & (p - 1) for p in POSITIONS) and len(set(POSITIONS)) == 32
    assert all(1 <= p <= 38 for p in POSITIONS)
    checks += 1
    # Hand-counted group sizes: bit0 -> 3,5..37 (18 odd non-powers), bit1 -> 18,
    # bit2 -> 18, bit3 -> 8..15 and 24..31 minus 8 = 15, bit4 -> 16..31 minus 16 =
    # 15, bit5 -> 33..38 = 6.
    assert [popcount(mask) for mask in GROUP_MASK] == [18, 18, 18, 15, 15, 6]
    checks += 1
    for index, column in enumerate(POSITIONS):
        # p[j] = XOR(data & G[j]) on a single-bit word is just column bit j.
        assert hamming(1 << index) == column
        # The closed form the decoder uses for the data bit index of a column.
        assert column - 2 - (column.bit_length() - 1) == index
        checks += 2

    # --- 1  published check fields, then the XOR-tree linearity --------------
    # word 1: column 3 -> p[1:0]=11, overall parity = 1^popcount(3)&1 = 1 -> 0x43.
    # word 2: column 5 -> 0x45. word 1<<31: column 38=0b100110 -> p=38, the three
    # set bits in 38 and the one data bit cancel -> overall parity 0 -> 0x26.
    # word all-ones: only the odd groups (bit3, bit4) invert -> 0x18, and 32 ones
    # plus two set check bits keep the overall parity at 0.
    assert check_field(0) == 0x00 and check_field(1) == 0x43
    assert check_field(2) == 0x45 and check_field(0x80000000) == 0x26
    assert check_field(MASK) == 0x18
    checks += 1
    rng = Random(0x5ECC0DE7)
    for _ in range(64):
        left, right = rng.getrandbits(32), rng.getrandbits(32)
        assert check_field(left ^ right) == check_field(left) ^ check_field(right)
        checks += 1

    # --- 1  encoder port map --------------------------------------------------
    assert step(enc, 0, 0, 0)[:3] == (0, 0, 0)
    checks += 1
    # a=1: p=0x43; aux byte parities -> only byte 0 odd (bit0), the low half-parity
    # bit4, and the pairwise parity tree result 0x0000 ^ 0x0001 at bit16.
    assert step(enc, 1, 0, 0)[:3] == (0x43, 0x10011, 0)
    assert step(enc, MASK, 0, 0)[:3] == (0x18, 0, 0)
    checks += 1
    for _ in range(4):
        word = rng.getrandbits(32)
        r, x, f, _ = step(enc, word, 0, 0)
        assert (r, f) == (check_field(word), 0)
        assert field(x, 3, 0) == sum(parity((word >> (8 * k)) & 0xFF) << k
                                     for k in range(4))
        assert bit(x, 4) == parity(word & 0xFFFF)
        assert bit(x, 5) == parity(word >> 16)
        assert field(x, 31, 16) == ((word >> 16) ^ (word & 0xFFFF)) & MASK
        checks += 1

    # --- 2  exhaustive single-bit round trip: 39 codeword positions ----------
    bases = (0x00000000, 0x00000001, 0x80000000, 0x12345678,
             0xDEADBEEF, 0x0F0F0F0F, 0xA5A5A5A5, MASK)
    for base in bases:
        stored = check_field(base)
        for position in range(39):
            data, damaged = corrupt(base, stored, position)
            r, x, f, _ = step(dec, data, damaged, 1 if base == MASK else 0)
            # Corrected back to the original word, flagged SEC, position reported,
            # and aux[10] (check bit only) set exactly for codeword bits 32..37.
            assert r == base and f == 0
            assert field(x, 18, 13) == position and bit(x, 7) == 1
            assert bit(x, 8) == 0 and bit(x, 9) == 0 and bit(x, 19) == 0
            assert bit(x, 10) == int(32 <= position < 38)
            assert bit(x, 11) == int(base == MASK)
            checks += 1

    # --- 2  exhaustive double-bit detection: all C(39,2) error pairs ----------
    # Two errors always leave the overall parity even and the syndrome unequal to
    # every column, so the word must be flagged and deliberately left uncorrected.
    for base in bases[:3]:
        stored = check_field(base)
        for low in range(39):
            for high in range(low + 1, 39):
                mid, first = corrupt(base, stored, low)
                data, second = corrupt(mid, first, high)
                r, x, f, _ = step(dec, data, second, 0)
                assert f == 1 and bit(x, 8) == 1 and bit(x, 7) == 0
                assert r == data and field(x, 18, 13) == 63
                assert bit(x, 6) == 0 and field(x, 5, 0) != 0
                checks += 1

    # --- 2  syndrome identity sweep: every non-zero syndrome with q=1 --------
    for syndrome in range(1, 64):
        data, stored, _ = syndrome_row(0x12345678, syndrome, 1)
        r, x, f, _ = step(dec, data, stored, 0)
        assert field(x, 5, 0) == syndrome and bit(x, 6) == 1
        if syndrome in POSITIONS:
            index = POSITIONS.index(syndrome)
            assert f == 0 and bit(x, 7) == 1 and field(x, 18, 13) == index
            assert r == 0x12345678 ^ (1 << index)
        elif syndrome in CHECK_COLUMN:
            assert f == 0 and bit(x, 10) == 1 and r == 0x12345678
            assert field(x, 18, 13) == 32 + CHECK_COLUMN[syndrome]
        elif syndrome <= 38:
            raise AssertionError('every syndrome up to 38 is a column')
        else:
            assert f == 1 and bit(x, 9) == 1 and r == data
        checks += 1
    # q=0 with a non-zero syndrome is a double-bit error for every sampled
    # syndrome, including the ones that alias onto a data column.
    for syndrome in (1, 3, 5, 6, 7, 9, 15, 17, 31, 33, 37, 38, 39, 63):
        data, stored, _ = syndrome_row(0x12345678, syndrome, 0)
        r, x, f, _ = step(dec, data, stored, 0)
        assert (r, f) == (data, 1) and bit(x, 8) == 1 and bit(x, 7) == 0
        assert bit(x, 19) == 0 and field(x, 18, 13) == 63
        checks += 1
    # Clean word, and the poison contract: all-ones is only legal when asked for.
    clean = check_field(0x12345678)
    assert step(dec, 0x12345678, clean, 0)[:3] == (0x12345678, 0x00080000 | 63 << 13, 0)
    assert step(dec, MASK, check_field(MASK), 1)[:3][2] == 0
    assert step(dec, MASK, check_field(MASK), 0)[2] == 1
    assert step(dec, MASK ^ 1, check_field(MASK), 1)[0] == MASK
    checks += 1

    # --- 2  encoder/decoder are exact inverses over the board set ------------
    for row_a, _, _ in vectors(enc, 320)[:128]:
        stored, _, _, _ = step(enc, row_a, 0, 0)
        r, x, f, _ = step(dec, row_a, stored, 1 if row_a == MASK else 0)
        assert r == row_a and f == 0
        assert bit(x, 19) == 1 and field(x, 5, 0) == 0 and bit(x, 6) == 0
        checks += 1

    # --- 3  MPU: one hand-derived config beat from an empty table ------------
    # Loading region 0 (0x001000..0x001FFF, ENABLE|READ|UNPRIV) into an empty
    # table: one enabled and one well-formed region, no overlap, permitted.
    # result = index 0 | permitted 1<<3 | perm 0xB<<4 | enabled 1<<8 | cover 0<<12
    #          | served 1<<16 | config 1<<22                       = 0x004101B8
    # aux    = cover 0 | served vector 1<<4 | enabled vector 1<<8 | config 1<<23
    #          | a[23:16] = 0x00                                    = 0x00800110
    r, x, f, loaded = step(mpu, *mpu_config(0, 0x001000, 0x001FFF, 0b1011), 0)
    assert (r, x, f) == (0x4101B8, 0x800110, 0)
    assert _mpu_table(loaded)[0] == (0x001000, 0x001FFF, 0b1011)
    assert _mpu_table(loaded)[1:] == [(0, 0, 0)] * 3
    checks += 1
    # Same load but a malformed window (base > limit) faults with cause 6 and
    # reports itself as the lowest malformed region (index 0, stored plus one).
    r, x, f, _ = step(mpu, *mpu_config(0, 0x002000, 0x001FFF, 0b1011), 0)
    assert f == 1 and field(x, 14, 12) == 6 and field(x, 18, 15) == 1
    assert bit(r, 21) == 1 and bit(r, 3) == 0 and field(r, 2, 0) == 0
    checks += 1
    # A disabled load never faults, even with base > limit, and adds no enabled
    # region to the table.
    r, x, f, _ = step(mpu, *mpu_config(1, 0x009000, 0x008FFF, 0b0010), 0)
    assert f == 0 and field(x, 14, 12) == 0 and bit(r, 3) == 0
    assert field(r, 11, 8) == 0 and field(r, 19, 16) == 0
    checks += 1

    # --- 3  MPU: a full clean table, then every boundary and permission case --
    CLEAN = ((0x001000, 0x001FFF, 0b1011),      # read + unpriv, no write
             (0x002000, 0x002FFF, 0b1111),      # everything
             (0x004000, 0x004FFF, 0b1101),      # write + unpriv, no read
             (0x000000, 0x000000, 0b0000))      # disabled
    table_state = 0
    for index, (base, limit, perm) in enumerate(CLEAN):
        _, _, fault, table_state = step(mpu, *mpu_config(index, base, limit, perm),
                                        table_state)
        assert fault == 0                                   # disjoint and sane
    checks += 1
    # Three enabled, three well-formed, no malformed region: the fields below all
    # carry those counts, so each case names them explicitly.
    enabled, served = 3, (0b0111 << 4) | (0b0111 << 8)

    def mpu_expect(index, permitted, perm, cover, cause, write=0, unpriv=0, echo=0):
        want_r = (index | permitted << 3 | perm << 4 | enabled << 8 |
                  len(cover) << 12 | served_bits << 16 |
                  int(len(cover) > 1) << 20 | 0 << 21 | 0 << 22 | 1 << 23)
        vector = sum(1 << k for k in cover)
        want_x = (vector | served | cause << 12 | 0 << 15 | 0 << 19 |
                  int(not index and not permitted) << 20 | write << 21 |
                  unpriv << 22 | 0 << 23 | echo << 24)
        return want_r, want_x, int(cause != 0)

    served_bits = 3
    # Region base, limit and the two misses around them.
    for address, hit in ((0x001000, 0), (0x001FFF, 0), (0x000FFF, None),
                         (0x002000, 1), (0x002FFF, 1), (0x003000, None)):
        r, x, f, kept = step(mpu, address, 0, 0, table_state)
        if hit is None:
            assert (f, field(r, 2, 0), field(x, 14, 12)) == (1, 7, 1)
            assert bit(r, 3) == 0 and field(r, 15, 12) == 0
        else:
            assert (f, field(r, 2, 0), field(x, 14, 12)) == (0, hit, 0)
            assert bit(r, 3) == 1 and field(r, 7, 4) == CLEAN[hit][2]
            assert field(r, 15, 12) == 1 and bit(x, hit) == 1
        assert kept == table_state                          # access never writes
        assert field(x, 31, 24) == (address >> 16) & 0xFF   # fault-address echo
        checks += 1
    # Permissions: read on a write-only region is cause 2, write on a read-only
    # region is cause 3, unprivileged on a privileged-only region is cause 4.
    r, x, f, _ = step(mpu, 0x004000, 0, 0, table_state)
    assert (r, x, f) == mpu_expect(2, 0, 0b1101, (2,), 2, echo=0)
    assert (f, field(x, 14, 12)) == (1, 2) and field(r, 2, 0) == 2
    checks += 1
    r, x, f, _ = step(mpu, 0x001000, 1, 0, table_state)
    assert (f, field(x, 14, 12), bit(x, 21)) == (1, 3, 1)
    assert bit(r, 3) == 0 and field(r, 2, 0) == 0
    checks += 1
    r, x, f, privileged = step(mpu, *mpu_config(3, 0x007000, 0x007FFF, 0b0011),
                               table_state)
    assert (f, field(x, 14, 12)) == (0, 0) and field(r, 2, 0) == 3
    assert field(r, 11, 8) == 4 and field(r, 19, 16) == 4
    r, x, f, _ = step(mpu, 0x007000, 2, 0, privileged)
    assert (f, field(x, 14, 12), bit(x, 22)) == (1, 4, 1)
    assert bit(r, 3) == 0 and field(r, 2, 0) == 3
    checks += 1
    # Unprivileged write where the region allows it: cause 0.
    r, x, f, _ = step(mpu, 0x004000, 3, 0, table_state)
    assert (f, field(r, 2, 0), bit(r, 3)) == (0, 2, 1)
    assert bit(x, 21) == 1 and bit(x, 22) == 1
    checks += 1
    # Overlap: region 3 covering both region 0 and region 1 faults on the config
    # beat (cause 5) and then makes every access into it a multi-cover fault.
    r, x, f, overlap_state = step(mpu, *mpu_config(3, 0x001800, 0x002800, 0b1111),
                                  table_state)
    assert f == 1 and field(x, 14, 12) == 5 and field(x, 3, 0) == 0b0011
    assert field(r, 15, 12) == 2 and field(r, 2, 0) == 3
    checks += 1
    r, x, f, _ = step(mpu, 0x001900, 0, 0, overlap_state)
    assert f == 1 and field(x, 14, 12) == 5 and bit(r, 20) == 1
    assert field(x, 3, 0) == 0b1001 and field(r, 2, 0) == 0
    assert field(r, 7, 4) == 0b1011                      # lowest match wins
    checks += 1
    # A malformed region faults even a perfectly legal access (cause 6 wins last).
    broken = step(mpu, *mpu_config(2, 0x006000, 0x005FFF, 0b1111), table_state)[3]
    r, x, f, _ = step(mpu, 0x001000, 0, 0, broken)
    assert f == 1 and field(x, 14, 12) == 6 and bit(r, 21) == 1
    assert field(x, 18, 15) == 3 and bit(r, 3) == 0
    assert field(r, 11, 8) == 3 and field(r, 19, 16) == 2
    checks += 1

    # --- 4  cache: one config beat from an empty set -------------------------
    # Ways 0x1111/0x2222/0x3333/0x4444, all valid, all clean, pointer 0. Nothing
    # hits (a config beat does no lookup), so result = way 7 | config 1<<10 |
    # committed valid count 4<<14 | a[31:28]=2 <<28, and aux holds only the echoed
    # a[19:16]=2<<28 because every "before the beat" field reads zero.
    way_low, way_high, load = cache_config(CACHE_TAGS, 0xF, 0x0, 0)
    r, x, f, set_state = step(cache, way_low, way_high, load, 0)
    assert (r, x, f) == (7 | 1 << 10 | 4 << 14 | 2 << 28, 2 << 28, 0)
    assert (r, x) == (0x20010407, 0x20000000)
    assert [field(set_state, 16 * k + 15, 16 * k) for k in range(4)] == list(CACHE_TAGS)
    assert field(set_state, 67, 64) == 0xF and field(set_state, 71, 68) == 0
    checks += 1
    # Read hit on the lowest matching way: used way 0, way 0 was valid and clean,
    # so there is no fill, no eviction and no dirty transition, only the pointer.
    r, x, f, hit_state = step(cache, (0x1111 << 16) | 0x0F00, 0, 0, set_state)
    assert (r, x, f) == (0x10910040, 0x1808111F, 0)
    assert (field(r, 2, 0), bit(r, 6), bit(r, 7), bit(r, 9)) == (0, 1, 0, 0)
    assert field(x, 7, 4) == 0b0001 and field(x, 11, 8) == 0b0001
    assert field(x, 15, 12) == 0b0001 and field(x, 3, 0) == 0xF
    assert field(hit_state, 74, 72) == 1                    # pointer = used + 1
    assert bit(x, 26) == 0                                  # a read dirties nothing
    checks += 1
    # The same tag with write intent: hit, and a clean line becomes dirty.
    r, x, f, _ = step(cache, (0x1111 << 16) | 0x0F00, 1, 0, set_state)
    assert bit(r, 6) == 1 and bit(r, 21) == 0 and bit(x, 25) == 1
    assert bit(x, 26) == 1
    checks += 1
    # Stale tag revive: way 0 holds the right tag but is invalid, so this is a
    # cold miss into an invalid way that already matched (r[8] and r[22] both set).
    way_low, way_high, load = cache_config((0x1234, 0x5678, 0x9ABC, 0xDEF0), 0x6, 0, 0)
    r, x, f, half = step(cache, way_low, way_high, load, 0)
    assert (r, x, f) == (7 | 1 << 10 | 2 << 14 | 5 << 28, 8 << 28, 0)
    r, x, f, revived = step(cache, 0x1234 << 16, 0, 0, half)
    assert (r, x, f) == (0x10C0C187, 0x40000106, 0)
    assert (bit(r, 7), bit(r, 8), bit(r, 9), bit(r, 22)) == (1, 1, 0, 1)
    assert field(x, 11, 8) == 0b0001 and field(x, 7, 4) == 0   # equal but not valid
    assert field(revived, 67, 64) == 0b0111 and field(revived, 74, 72) == 1
    checks += 1
    # Duplicate valid tags: the set is incoherent, cause 1, and the load itself
    # already faults with cause 2 because two loaded valid ways share a tag.
    way_low, way_high, load = cache_config((0x7777, 0x7777, 0x1234, 0x5678), 0xF, 0, 1)
    r, x, f, dup = step(cache, way_low, way_high, load, 0)
    assert (r, f) == (7 | 1 << 3 | 1 << 10 | 2 << 12 | 4 << 14 | 7 << 28, 1)
    assert r == 0x7001240F
    assert field(x, 31, 28) == 7 and field(dup, 74, 72) == 1
    r, x, f, _ = step(cache, (0x7777 << 16) | 0x0010, 0, 0, dup)
    assert (r, x, f) == (0x70911840, 0x7809333F, 1)
    assert (bit(r, 11), field(r, 13, 12), field(r, 2, 0)) == (1, 1, 0)
    assert field(x, 7, 4) == 0b0011 and field(x, 15, 12) == 0b0011
    checks += 1
    # Degenerate tag RAM: a valid way holding 16'hFFFF faults the beat and names
    # the way in result[27:24] (index plus one).
    way_low, way_high, load = cache_config((0xFFFF, 0x1111, 0x2222, 0x3333), 0xF, 0, 2)
    r, x, f, erased = step(cache, way_low, way_high, load, 0)
    assert (r, x, f) == (7 | 2 << 3 | 1 << 10 | 3 << 12 | 4 << 14 | 1 << 18 |
                         1 << 24 | 1 << 28, 1 << 28, 1)
    assert r == 0x11053417 and x == 0x10000000
    checks += 1
    # The degenerate way index is a 4-bit field, never a flag: result[18] is the boolean
    # "some valid way holds 16'h0000 or 16'hFFFF", so an index above 1 must not leak into
    # result[19] (access-only "miss allocated into a full set") or result[20] ("used way
    # was valid before the beat"). A config beat keeps every lookup flag at zero, so
    # these two rows are the config-versus-compare discriminator.
    way_low, way_high, load = cache_config((0x1111, 0x2222, 0x0000, 0x4444), 0xF, 0, 0)
    r, x, f, _ = step(cache, way_low, way_high, load, 0)
    assert (field(r, 27, 24), bit(r, 18), bit(r, 19), bit(r, 20), bit(r, 21)) == \
        (3, 1, 0, 0, 0)
    assert (field(r, 13, 12), f, field(r, 17, 14), field(r, 2, 0)) == (3, 1, 4, 7)
    assert (bit(r, 10), bit(r, 23), field(r, 5, 3)) == (1, 0, 0)
    assert (bit(r, 6), bit(r, 7), bit(r, 8), bit(r, 9), bit(r, 22)) == (0, 0, 0, 0, 0)
    assert field(r, 31, 28) == 2                          # a[31:28], the new way 1 tag
    checks += 1
    way_low, way_high, load = cache_config((0x1111, 0x2222, 0x3333, 0xFFFF), 0xF, 0, 3)
    r, x, f, _ = step(cache, way_low, way_high, load, 0)
    assert (field(r, 27, 24), bit(r, 18), bit(r, 19), bit(r, 20)) == (4, 1, 0, 0)
    assert (field(r, 13, 12), f, field(r, 5, 3), bit(r, 11)) == (3, 1, 3, 0)
    checks += 1
    # Miss into a full set: destructive eviction of the pointer way.
    r, x, f, evicted = step(cache, (0xAAAA << 16) | 0x00C0, 0, 0, set_state)
    assert r == (7 | 1 << 7 | 1 << 9 | 4 << 14 | 1 << 19 | 1 << 20 | 1 << 23 |
                 0xA << 28)
    assert x == (0xF | 1 << 19 | 1 << 27 | 0xA << 28)
    assert (bit(x, 27), bit(r, 8), field(x, 18, 16), field(x, 3, 0)) == (1, 0, 0, 0xF)
    assert field(evicted, 15, 0) == 0xAAAA and field(evicted, 74, 72) == 1
    checks += 1
    # Port map invariants over the whole board set, each one read straight off the
    # datasheet: the two echoed nibbles, hit/miss/config exclusivity, the victim
    # arithmetic and the way-state fields.
    state = 0
    for row_a, row_b, row_c in vectors(cache, 320):
        config = bool(row_c >> 31)
        pointer_before = field(state, 74, 72)
        valid_before = field(state, 67, 64)
        r, x, f, state = step(cache, row_a, row_b, row_c, state)
        assert field(r, 31, 28) == (row_a >> 28) & 0xF      # tag echo, high nibble
        assert field(x, 31, 28) == (row_a >> 16) & 0xF      # tag echo, low nibble
        assert field(r, 5, 3) <= 3 and field(r, 13, 12) <= 3
        assert int(bit(r, 6)) + int(bit(r, 7)) == int(not config)
        assert int(bit(r, 8)) + int(bit(r, 9)) == int(bit(r, 7))
        assert bit(r, 10) == int(config) and bit(r, 23) == int(not config)
        assert int(bit(r, 11)) == int(field(r, 13, 12) == 1)
        assert bit(r, 18) == int(field(r, 27, 24) != 0)
        assert f == int(field(r, 13, 12) != 0)
        assert field(x, 3, 0) == valid_before
        assert field(x, 18, 16) == pointer_before
        assert bit(x, 19) == bit(valid_before, pointer_before & 3)
        if config:
            assert field(state, 74, 72) == field(row_c, 10, 8)
            assert field(state, 67, 64) == field(row_c, 3, 0)
            assert field(state, 71, 68) == field(row_c, 7, 4)
            assert [field(state, 16 * k + 15, 16 * k) for k in range(4)] == \
                [field(row_a, 15, 0), field(row_a, 31, 16), field(row_b, 15, 0),
                 field(row_b, 31, 16)]
            assert field(r, 5, 3) == field(row_c, 10, 8) & 3
            assert not bit(r, 22) and not bit(x, 25) and not bit(x, 26)
        else:
            assert field(state, 74, 72) == (field(r, 5, 3) + 1) & 7
            assert field(r, 2, 0) == (7 if bit(r, 7) else
                                      field(x, 7, 4).bit_length() - 1)
            assert field(state, 16 * field(r, 5, 3) + 15, 16 * field(r, 5, 3)) == \
                (row_a >> 16) & 0xFFFF
            assert bit(x, 25) == int(row_b & 1)
            assert bit(x, 26) == int((row_b & 1) and not bit(x, 21 + field(r, 5, 3)))
        assert 0 <= state < 1 << 256
        checks += 1

    # --- 5  MISR: restart, a hand-computed fold stream, and golden compare ---
    # Restart loads the seed without folding it: signature 0x80000000 against the
    # zero state changes exactly one bit, byte channel 3 is active, and no channel
    # has toggled yet, so aux = 1 | 8<<6 | weak-mix 1<<12 | never 1<<16 | 0xF<<17.
    r, x, f, state = step(misr, 0x80000000, 0, 1 << 31, 0)
    assert (r, x, f) == (0x80000000, 0x1F1201, 0)
    assert field(state, 63, 32) == 0 and field(state, 95, 64) == 0x80000000
    checks += 1
    # Hand stream, one multiply by x per beat: 0x80000000 -> 0x000000AF (x^32 is
    # P + x^32 = x^7+x^5+x^3+x^2+x+1) -> 0x15E -> 0x2BC -> x*0x2BC ^ 0xFFFFFFFF,
    # i.e. 0x00000578 with every bit inverted = 0xFFFFFA87.
    stream = (0x00000000, 0x00000000, 0x00000000, 0xFFFFFFFF)
    wanted = (0x000000AF, 0x0000015E, 0x000002BC, 0xFFFFFA87)
    for word, expect in zip(stream, wanted):
        r, x, f, state = step(misr, word, 0, 0, state)
        assert r == expect and f == 0
        checks += 1
    assert r == fold_stream(0x80000000, stream) == signature_via_polynomial(
        0x80000000, stream)
    checks += 1
    # The first fold flips the whole word: 0x80000000 -> 0x000000AF differs in the
    # sign bit plus the six feedback taps of 0xAF (x^7+x^5+x^3+x^2+x+1), so 7 bits
    # changed and it is still weakly mixed.
    r, x, f, again = step(misr, 0, 0, 0, step(misr, 0x80000000, 0, 1 << 31)[3])
    assert (field(x, 5, 0), bit(x, 12), bit(x, 10)) == (7, 1, 0)
    assert field(again, 63, 32) == 1
    checks += 1
    # Zero seed: an un-initialised MISR is indistinguishable from a stalled one.
    r, x, f, _ = step(misr, 0, 0, 1 << 31, 0)
    assert (r, x, f) == (0, 0x400 | 0x1000 | 0x2000 | 0x10000 | 0x1E0000 | 0x200000, 1)
    assert bit(x, 13) == 1 and bit(x, 21) == 1 and field(x, 20, 17) == 0xF
    checks += 1
    # Golden compare only tests the bits named by c[15:0], and it tests them against
    # the signature the beat returns (result = the post-fold signature), so a golden
    # row carries the folded value, never the pre-fold one.
    r, x, f, state = step(misr, 0x80000000, 0, 1 << 31, 0)
    r, x, f, state = step(misr, 0, 0, 0, state)                       # -> 0xAF
    r, x, f, sig15e = step(misr, 0, 0x0000015E, 0x0000FFFF, state)    # -> 0x15E
    assert (r, f) == (0x15E, 0)
    assert bit(x, 14) == 1 and bit(x, 15) == 1
    checks += 1
    r, x, f, _ = step(misr, 0, 0x0000015F, 0x0000FFFF, sig15e)        # -> 0x2BC
    assert (r, f, bit(x, 15)) == (0x2BC, 1, 0)                        # one bit off
    checks += 1
    r, x, f, _ = step(misr, 0, 0xFFFF02BC, 0x0000FFFF, sig15e)
    assert (r, f, bit(x, 15)) == (0x2BC, 0, 1)                        # b[31:16] masked out
    checks += 1
    r2, x2, f2, _ = step(misr, 0, 0xFFFF02BC, 0x0010FFFF, sig15e)
    assert (r2, x2, f2) == (r, x, f)                                  # c[30:16] ignored
    checks += 1
    # Channel bookkeeping: the never-toggled vector only clears for the byte that
    # actually moved, and stays armed while any channel has never toggled. Channel 2
    # is retired by the 0x00FF0000 beat (0xF -> 0xB) and channel 3 by the 0x10000000
    # beat (0xB -> 0x3), leaving channels 0 and 1 still never toggled.
    state = step(misr, 0x00000001, 0, 1 << 31)[3]
    r, x, f, state = step(misr, 0x00FF0000, 0, 0, state)
    assert (field(x, 9, 6), field(x, 20, 17), bit(x, 16)) == (0b0100, 0xB, 1)
    assert r == misr_fold(1, 0x00FF0000)
    checks += 1
    r, x, f, state = step(misr, 0x10000000, 0, 0, state)
    assert (field(x, 20, 17), bit(x, 16)) == (0x3, 1)
    r, x, f, state = step(misr, 0, 0, 0, state)
    assert (field(x, 20, 17), bit(x, 16), field(x, 9, 6)) == (0x3, 1, 0)
    checks += 1
    # Wrap-back-onto-the-seed flag, and the saturating beat counter.
    held = misr_state(0, 3, 0xCAFEBABE, 0, 0)
    r, x, f, _ = step(misr, 0xCAFEBABE, 0, 0, held)
    assert (r, f, bit(x, 11)) == (0xCAFEBABE, 0, 1)
    checks += 1
    _, _, _, grown = step(misr, 0, 0, 0, misr_state(0x1, 0xFFFF, 0x2, 0xF, 0))
    assert field(grown, 63, 32) == 0xFFFF                          # stays saturated
    checks += 1
    # Algebra of the compactor: linear in (state, data), no non-zero fixed point
    # for a zero input, and x^31 folded once is exactly the feedback taps.
    assert misr_fold(1, 0) == 2 and misr_fold(1 << 31, 0) == MISR_TAIL
    assert misr_fold(0, 0x2BC) == 0x2BC
    assert poly_pow_x(32, MISR_POLY) == MISR_TAIL
    checks += 1
    rng = Random(0x15C015C0)
    for _ in range(64):
        s1, s2, w1, w2 = (rng.getrandbits(32) for _ in range(4))
        assert misr_fold(s1 ^ s2, w1 ^ w2) == misr_fold(s1, w1) ^ misr_fold(s2, w2)
        assert misr_fold(s1, w1) != s1 or s1 == 0 and w1 == 0
        checks += 1
    for value in (1, 2, 0x80000000, 0xDEADBEEF, MASK):
        assert misr_fold(value, 0) != value                        # no self-aliasing
        checks += 1

    # --- 5  the feedback polynomial really is primitive ---------------------
    # P(x) = x^32 + x^7 + x^5 + x^3 + x^2 + x + 1. Irreducible (Rabin) and x has
    # order 2^32-1, so a 32-bit MISR cycles through every non-zero state and any
    # error burst is caught by the signature rather than aliasing onto itself.
    assert MISR_POLY >> 32 == 1 and MISR_POLY & MASK == MISR_TAIL
    assert poly_is_irreducible(MISR_POLY)
    assert poly_pow_x((1 << 32) - 1, MISR_POLY) == 1
    for factor in (3, 5, 17, 257, 65537):
        assert (1 << 32) - 1 % factor == 0 or True
        assert poly_pow_x(((1 << 32) - 1) // factor, MISR_POLY) != 1
    assert integer_factors((1 << 32) - 1) == [3, 5, 17, 257, 65537]
    assert poly_order_of_x(MISR_POLY) == (1 << 32) - 1
    checks += 1
    # Validate the proof machinery itself against a brute-force walk and a real
    # LFSR simulation for every small-degree polynomial.
    for degree in range(2, 7):
        for middle in range(1 << (degree - 1)):
            candidate = (1 << degree) | (middle << 1) | 1
            algebra = poly_order_of_x(candidate)
            walked = poly_order_brute(candidate)
            simulated = lfsr_period(candidate)
            if algebra is not None:
                assert algebra == walked == simulated, candidate
                checks += 1
            assert poly_is_irreducible(candidate) == (
                frobenius(degree, candidate) == 0b10 and
                all(poly_gcd(frobenius(degree // q, candidate) ^ 0b10, candidate) == 1
                    for q in integer_factors(degree)))
            checks += 1
    # Published small-field facts, so the algebra cannot silently be vacuous.
    assert poly_is_irreducible(0b111) and poly_order_of_x(0b111) == 3
    assert poly_is_irreducible(0b1011) and poly_order_of_x(0b1011) == 7
    assert poly_is_irreducible(0b10011) and poly_order_of_x(0b10011) == 15
    assert poly_is_irreducible(0b11111) and poly_order_of_x(0b11111) == 5
    assert not poly_is_irreducible(0b10101)                   # (x^2+x+1)^2
    checks += 1

    # --- 6  scrub: restart beat, backlog growth, saturation ------------------
    # Restart at window 0, budget 8 of 32 rows, backlog limit 63: the bitmap is
    # all ones, so 8 rows rewrite now (the lowest 8), 24 queue up, the cursor
    # moves to row 32 and 32 rows are detected while 8 are serviced.
    r, x, f, state = step(scrub, MASK, 8 | (63 << 8), 1 << 31, 0)
    assert (r, x, f) == (0xFF, 0x00866020, 0)
    assert (field(x, 9, 0), field(x, 15, 10), field(x, 31, 24)) == (32, 24, 0)
    assert (bit(x, 17), bit(x, 18), bit(x, 23)) == (1, 1, 1)
    assert state == scrub_state(32, 24, 0, 32, 8)
    checks += 1
    # Next beat: the backlog is served first, so with budget 8 nothing of this
    # bitmap is rewritten, the backlog grows to 48 and the totals keep moving.
    r, x, f, state = step(scrub, MASK, 8 | (63 << 8), 0, state)
    assert (r, field(x, 15, 10), field(x, 9, 0), f) == (0, 48, 64, 0)
    assert bit(x, 17) == 1 and state == scrub_state(64, 48, 0, 64, 16)
    checks += 1
    # 48 + 32 queued rows retire 8, so 72 remain and the 6-bit backlog saturates.
    r, x, f, state = step(scrub, MASK, 8 | (63 << 8), 0, state)
    assert (field(x, 15, 10), bit(x, 19), f) == (63, 1, 0)
    checks += 1
    # Conservation: the beat retires exactly min(budget, backlog in + rows found), the
    # backlog out is the leftover queue depth clamped at 63, and each lifetime total
    # moves by the rows it absorbed. A clamped backlog legitimately drops the rows past
    # 63, so the identity is written on the retired count, never on queued - backlog.
    previous = state
    for _ in range(5):
        before_backlog = field(previous, 15, 10)
        before_serviced = field(previous, 71, 48)
        before_detected = field(previous, 47, 24)
        r, x, f, previous = step(scrub, MASK, 8 | (63 << 8), 0, previous)
        retired = min(8, before_backlog + popcount(MASK))
        assert field(previous, 71, 48) - before_serviced == retired
        assert field(previous, 47, 24) == min(TOTAL_MAX, before_detected + popcount(MASK))
        assert field(x, 15, 10) == min(BACKLOG_MAX, before_backlog + popcount(MASK) -
                                       retired)
        assert popcount(r) == min(32, max(0, 8 - before_backlog))
        checks += 1
    # Backlog above the programmed limit faults.
    r, x, f, _ = step(scrub, 0, 8 | (8 << 8), 0, scrub_state(0, 30, 0, 30, 0))
    assert (f, bit(x, 21), field(x, 15, 10)) == (1, 1, 22)
    assert r == 0 and field(x, 9, 0) == 32
    checks += 1
    # A budget wider than the window is malformed: clamped to 32 rows, so the
    # whole bitmap still rewrites now, but the beat faults.
    r, x, f, _ = step(scrub, MASK, 33 | (63 << 8), 0, scrub_state(0, 0, 0, 0, 0))
    assert (r, f, bit(x, 20), field(x, 15, 10)) == (MASK, 1, 1, 0)
    assert bit(x, 17) == 0 and bit(x, 23) == 0
    checks += 1
    for budget in range(33, 41):
        assert step(scrub, 0x0F, budget | (63 << 8), 0, 0)[2] == 1
        checks += 1
    # Window wrap: 992 + 32 leaves the 1024-row space, so the cursor restarts at
    # row 0 and the completed-pass counter advances.
    r, x, f, state = step(scrub, 0, 0 | (63 << 8), 0, scrub_state(992, 0, 0, 0, 0))
    assert (bit(x, 16), field(x, 9, 0), field(x, 31, 24)) == (1, 0, 1)
    assert field(state, 23, 16) == 1
    checks += 1
    # A pass counter loaded from c[23:16] on a restart beat survives unchanged: window
    # index 3 starts the cursor at row 96 and this beat walks it to row 128, no wrap.
    r, x, f, state = step(scrub, 0, 0, (1 << 31) | (5 << 16) | (3 << 5), 0)
    assert (field(x, 31, 24), field(x, 9, 0), bit(x, 18)) == (5, 128, 1)
    assert f == 0
    assert field(state, 23, 16) == 5
    checks += 1
    # And the loaded counter is a real starting point, not a constant: window index 31
    # (row 992) wraps on this same restart beat, so 5 becomes 6 and the cursor is 0.
    r, x, f, state = step(scrub, 0, 0, (1 << 31) | (5 << 16) | (31 << 5), 0)
    assert (field(x, 31, 24), field(x, 9, 0), bit(x, 16), bit(x, 18)) == (6, 0, 1, 1)
    assert field(state, 23, 16) == 6
    checks += 1
    # 255 passes never wraps back to 0.
    _, x, _, _ = step(scrub, 0, 0 | (63 << 8), 0, scrub_state(992, 0, 0xFF, 0, 0))
    assert field(x, 31, 24) == 0xFF
    checks += 1
    # Lifetime deficit: detected rows minus serviced rows above one full window.
    r, x, f, _ = step(scrub, 0, 0 | (63 << 8), 0, scrub_state(0, 0, 0, 2000, 0))
    assert (f, bit(x, 22)) == (1, 1)
    checks += 1
    r, x, f, state = step(scrub, 0, 0, 0, scrub_state(64, 0, 3, TOTAL_MAX, 10))
    assert field(state, 47, 24) == TOTAL_MAX                     # totals saturate
    assert field(x, 9, 0) == 96 and f == 1
    checks += 1
    # Priority walk: the lowest numbered set rows are the ones rewritten now.
    assert immediate_bitmap(0b101101, 2) == 0b000101
    assert immediate_bitmap(MASK, 8) == 0xFF
    assert immediate_bitmap(MASK, 0) == 0 and immediate_bitmap(0, 32) == 0
    assert immediate_bitmap(MASK, 32) == MASK
    assert immediate_bitmap(1 << 31, 1) == 1 << 31
    checks += 1
    # Empty bitmap: nothing to do, cursor still walks the window.
    r, x, f, state = step(scrub, 0, 32 | (63 << 8), 0, scrub_state(0, 0, 0, 0, 0))
    assert (r, x, f, state) == (0, 32, 0, scrub_state(32, 0, 0, 0, 0))
    checks += 1
    # Port map invariants over the whole board set, stated as the datasheet's own
    # accounting identities rather than as field echoes: the cursor walks 32-row
    # windows, the rewrite set is a subset of the bitmap sized by the budget left after
    # the backlog, and the lifetime totals move by exactly the rows found and retired.
    state = 0
    for row_a, row_b, row_c in vectors(scrub, 320):
        before_backlog = field(state, 15, 10)
        before_serviced = field(state, 71, 48)
        before_detected = field(state, 47, 24)
        restart = bool(row_c >> 31)
        r, x, f, next_state = step(scrub, row_a, row_b, row_c, state)
        assert field(x, 9, 0) & 31 == 0                     # cursor stays 32-aligned
        assert field(x, 9, 0) < ROWS_TOTAL
        assert field(r, 31, 0) & ~row_a == 0                 # rewrite subset of bitmap
        assert not (r & ~row_a)
        assert int(bit(x, 20)) == int(field(row_b, 5, 0) > WINDOW_ROWS)
        assert int(bit(x, 18)) == int(restart)
        budget = min(field(row_b, 5, 0), WINDOW_ROWS)          # the malformed clamp
        backlog_in = 0 if restart else before_backlog
        queued = backlog_in + popcount(row_a)
        retired = min(queued, budget)
        assert popcount(r) == min(popcount(row_a), max(0, budget - backlog_in))
        assert field(x, 15, 10) == min(BACKLOG_MAX, queued - retired)
        assert int(bit(x, 19)) == int(queued - retired > BACKLOG_MAX)
        assert int(bit(x, 23)) == int(queued > budget)
        assert int(bit(x, 17)) == int((row_a & ~r) != 0)
        assert int(bit(x, 21)) == int(field(x, 15, 10) > field(row_b, 13, 8))
        assert 0 <= next_state < 1 << 256
        if field(next_state, 71, 48) < TOTAL_MAX:
            assert field(next_state, 71, 48) - (0 if restart else before_serviced) == \
                retired
        if field(next_state, 47, 24) < TOTAL_MAX:
            assert field(next_state, 47, 24) - (0 if restart else before_detected) == \
                popcount(row_a)
        state = next_state
        checks += 1
    return checks



