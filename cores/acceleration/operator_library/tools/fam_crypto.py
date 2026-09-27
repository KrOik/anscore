"""Cryptographic family kernels: GF(2^8) tables, ARX/Feistel rounds, hash rounds.

Ten narrow 32-bit datapaths for the GW5A-25 release.  Every one of them is built
from the vocabulary this family is naturally made of: GF(2^8) substitution is a
table ROM and xtime is shift-add, the hashes and ChaCha20 are XOR plus rotate
plus modulo-2^32 add, the GHASH-style ring step and the Galois LFSR are shift
and tap XOR, and the Feistel round is rotate, XOR and add.

ARITHMETIC RULE for this family: the generated RTL contains no multiply operator
anywhere.  On this device the fabric $mul is unsigned and silently corrupts any
operand with bit 11 set (silicon-proven), and hand-instantiating MULT12X12 is out
of scope, so every coefficient-scaled step here is expressed as shifts, XOR and
table ROMs.  Where a hash needs a 64-entry constant table (SHA-256 K[t], MD5 K[t],
the SM4/SHA-1 message schedule) the caller feeds the constant word in `b` instead
of paying for a second ROM in the fabric.

Contract notes shared by all ten cores:
  * step(name, a, b, c, state) returns (r, x, f, state_next) and threads the
    256-bit state through every trace, exactly like the reference SIMD family.
  * c[31] is the restart / load control for the nine stateful cores, so the
    board vector sets all carry restart rows inside the first 128 rows.
  * malformed control always answers r = 0, x = 0, f = 1, never a silent alias.
"""
from math import isqrt, sin
from random import Random

FAMILY = 'crypto'
MASK = (1 << 32) - 1

CORES = []

# provisional body until the kernel is written; r and x stay 32-bit clean
TODO = "r = a ^ b; x = 32'd0; f = 1'b0;"


def core(name, spec, body, advantage, lanes, **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, description=spec,
                      body=body, advantage=advantage,
                      hardware_advantage=advantage, lanes=lanes, **kwargs))


# --------------------------------------------------------------------------
# derived substitution tables and the table-ROM text generator
#
# Both tables are built from their defining algebra at import time, never
# pasted from a memory of a printed table, and the selftest re-checks them
# against published row-0 values plus full published cipher vectors.
# --------------------------------------------------------------------------
def xtime(value):
    """GF(2^8) doubling modulo x^8 + x^4 + x^3 + x + 1: a shift and an XOR."""
    value = (value << 1) & 0x1FF
    return (value ^ 0x11B) & 0xFF if value & 0x100 else value


def gmul11b(left, right):
    product = 0
    for _ in range(8):
        if right & 1:
            product ^= left
        right >>= 1
        left = xtime(left)
    return product


def rot8(value, amount):
    return ((value << amount) | (value >> (8 - amount))) & 0xFF


def aes_sbox():
    """Published AES S-box: GF(2^8) inverse mod 0x11b then the affine map."""
    inverse = [0] * 256
    for a in range(1, 256):
        for bb in range(1, 256):
            if gmul11b(a, bb) == 1:
                inverse[a] = bb
                break
    out = []
    for a in range(256):
        y = inverse[a]
        out.append(y ^ rot8(y, 1) ^ rot8(y, 2) ^ rot8(y, 3) ^ rot8(y, 4) ^ 0x63)
    return out


AES_SBOX = aes_sbox()
AES_INV_SBOX = [AES_SBOX.index(v) for v in range(256)]
AES_RCON = [1]
for _ in range(9):
    AES_RCON.append(xtime(AES_RCON[-1]) & 0xFF)

# byte j of a word lives at bits [8j+7:8j]; the four bytes of an AES word are
# the four published bytes in order, so RotWord is a rotate left by one byte.
BYTE = ('a[7:0]', 'a[15:8]', 'a[23:16]', 'a[31:24]')


def rom_case(table, target='pa'):
    lines = ['        case(mask[7:0])']
    for index in range(256):
        lines.append("            8'h%02x: %s = 8'h%02x;" %
                     (index, target, table[index]))
    lines.append("            default: %s = 8'h00;" % target)
    lines.append('        endcase')
    return '\n'.join(lines)


def byte_of(reg, index):
    return '%s[%s]' % (reg, ('7:0', '15:8', '23:16', '31:24')[index])


def mix_block(j, table_reg='r'):
    """One MixColumns output byte in the hardware form of 2a + 3b + c + d:
    out_j = xtime(s_j ^ s_j1) ^ s_j1 ^ s_j2 ^ s_j3, subscripts mod 4.  xtime is a
    shift plus a conditional tap XOR, so the cone needs no multiplier at all."""
    j1, j2, j3 = (j + 1) % 4, (j + 2) % 4, (j + 3) % 4
    return '\n'.join((
        "        pa = {24'd0, %s} ^ {24'd0, %s};" % (
            byte_of(table_reg, j), byte_of(table_reg, j1)),
        '        pc = pa[7];',
        "        pa = ((pa << 1) ^ (pc ? 32'h1b : 32'd0)) & 32'h0000_00ff;",
        "        pb = pa ^ {24'd0, %s} ^ {24'd0, %s};" % (
            byte_of(table_reg, j1), byte_of(table_reg, j2)),
        "        pc = pb ^ {24'd0, %s};" % byte_of(table_reg, j3),
        '        wide[%s] = pc[7:0];' % LANE[j]))


LANE = ('7:0', '15:8', '23:16', '31:24')


def sub_loop(table, src='a', dest='r', zero_flag=True):
    """Four byte lanes of src substituted through one generated table ROM into
    dest.  The ROM is a plain case statement, so the synthesiser maps it to LUT
    addressing and the design never asks the fabric for a multiply."""
    lines = ['        for(lane = 0; lane < 4; lane = lane + 1) begin',
             '            case(lane)']
    for k in range(4):
        lines.append('                %s: mask = {24\'d0, %s};' %
                     ('default' if k == 3 else str(k), byte_of(src, k)))
    lines.append('            endcase')
    if zero_flag:
        lines.append("            x[lane] = (mask == 32'd0);")
    lines.append(rom_case(table))
    lines.append('            case(lane)')
    for k in range(4):
        lines.append('                %s: %s[%s] = pa[7:0];' %
                     ('default' if k == 3 else str(k), dest, LANE[k]))
    lines.append('            endcase')
    lines.append('        end')
    return '\n'.join(lines)


def aes_round_body():
    parts = [
        "if(c[7:0] > 8'd3 || c[29:8] != 0) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0;",
        'end else begin',
        "    x = 32'd0;",
        sub_loop(AES_SBOX),
        '    x[15:8] = c[7:0];',
        '    if(!c[31]) begin',
        "        wide = 64'd0;",
        mix_block(0), mix_block(1), mix_block(2), mix_block(3),
        '        r = wide[31:0];',
        '    end',
        '    r = r ^ b;',
        'end']
    return '\n'.join(parts)


AES_ROUND_BODY = aes_round_body()


def key_schedule_body():
    """AES-128 key expansion, one word per beat.  The window is a 128-bit shift
    register whose slot j (bits 32j+) holds W i-1-j, so slot 0 is the word that
    gets transformed, slot 3 the one XORed with it, and an accepted beat appends
    r with one shift.  Rcon is a 10-way constant case on i, never a table read."""
    rcon = ['        case(c[7:0])']
    for index, value in enumerate(AES_RCON):
        rcon.append("            8'd%d: pl = 32'h%08x;" % (4 * index + 4, value))
    rcon.append("            default: pl = 32'd0;")
    rcon.append('        endcase')
    parts = [
        "if(c[30] || c[29:8] != 0) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else if(c[31]) begin",
        "    case(c[1:0])",
        "        2'd0: begin wide = {state_r[63:32], a}; wide2 = state_r[127:64]; end",
        "        2'd1: begin wide = {a, state_r[31:0]}; wide2 = state_r[127:64]; end",
        "        2'd2: begin wide = state_r[63:0]; wide2 = {state_r[127:96], a}; end",
        "        default: begin wide = state_r[63:0]; wide2 = {a, state_r[95:64]}; end",
        "    endcase",
        "    state_n = {128'd0, wide2, wide};",
        "    r = a; x = 32'h8000_0000 | c[1:0];",
        "end else if(c[7:0] < 8'd4 || c[7:0] > 8'h2b) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else begin",
        "    x = 32'd0;",
        "    pa = state_r[31:0];",
        "    pb = state_r[127:96];",
        "    if(c[1:0] == 2'd0) begin",
        "        temp = (pa >> 8) | (pa << 24);",
        sub_loop(AES_SBOX, src='temp', dest='pc'),
        '\n'.join(rcon),
        "        pc = pc ^ pl;",
        "        pa = pc;",
        "        x[16] = 1'b1;",
        "    end",
        "    r = pa ^ pb;",
        "    state_n = {128'd0, state_r[95:0], r};",
        "    x = x | (c[7:0] << 8);",
        "end"]
    return '\n'.join(parts)


KEY_SCHEDULE_BODY = key_schedule_body()


# --------------------------------------------------------------------------
# hash constants: FIPS 180-4 derives the SHA-256 IV from the square roots and
# the round constants from the cube roots of the smallest primes, so both
# tables here are computed from that definition, never pasted.
# --------------------------------------------------------------------------
def primes(count):
    out, n = [], 2
    while len(out) < count:
        if all(n % p for p in out if p * p <= n):
            out.append(n)
        n += 1
    return out


def icbrt(value):
    """floor of the integer cube root: Newton on x = (2x + n/x^2)/3, started from
    a power of two above the root so the iteration only decreases."""
    if value < 2:
        return value
    root = 1 << ((value.bit_length() + 2) // 3)
    while True:
        step = (2 * root + value // (root * root)) // 3
        if step >= root:
            return root
        root = step


SMALL_PRIMES = primes(64)
SHA256_IV = [(isqrt(p << 64) & MASK) for p in SMALL_PRIMES[:8]]
SHA256_K = [(icbrt(p << 96) & MASK) for p in SMALL_PRIMES]

# RFC 1321 defines the MD5 constant table as K[i] = floor(2^32 * abs(sin(i + 1))),
# so the 64 words are computed from that definition here rather than transcribed.
MD5_K = [int(abs(sin(i + 1)) * (1 << 32)) & MASK for i in range(64)]
MD5_IV = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
# the four published per-round shift tables and the four published message-word
# orders of RFC 1321 (round 1: i, round 2: 5i+1, round 3: 3i+5, round 4: 7i mod 16)
MD5_S = ([7, 12, 17, 22] * 4 + [5, 9, 14, 20] * 4 +
         [4, 11, 16, 23] * 4 + [6, 10, 15, 21] * 4)
MD5_ORDER = (list(range(16)) + [(5 * i + 1) % 16 for i in range(16)] +
             [(3 * i + 5) % 16 for i in range(16)] +
             [(7 * i) % 16 for i in range(16)])


# GB/T 32907-2016 publishes the SM4 S-box as a table (it has no cheap algebraic
# definition to derive from), so it is carried as the standard's table and pinned
# in selftest() by the standard's own known-answer encryption, which no wrong byte
# can survive, plus the permutation check.
SM4_SBOX = (
    0xd6, 0x90, 0xe9, 0xfe, 0xcc, 0xe1, 0x3d, 0xb7, 0x16, 0xb6, 0x14, 0xc2, 0x28,
    0xfb, 0x2c, 0x05, 0x2b, 0x67, 0x9a, 0x76, 0x2a, 0xbe, 0x04, 0xc3, 0xaa, 0x44,
    0x13, 0x26, 0x49, 0x86, 0x06, 0x99, 0x9c, 0x42, 0x50, 0xf4, 0x91, 0xef, 0x98,
    0x7a, 0x33, 0x54, 0x0b, 0x43, 0xed, 0xcf, 0xac, 0x62, 0xe4, 0xb3, 0x1c, 0xa9,
    0xc9, 0x08, 0xe8, 0x95, 0x80, 0xdf, 0x94, 0xfa, 0x75, 0x8f, 0x3f, 0xa6, 0x47,
    0x07, 0xa7, 0xfc, 0xf3, 0x73, 0x17, 0xba, 0x83, 0x59, 0x3c, 0x19, 0xe6, 0x85,
    0x4f, 0xa8, 0x68, 0x6b, 0x81, 0xb2, 0x71, 0x64, 0xda, 0x8b, 0xf8, 0xeb, 0x0f,
    0x4b, 0x70, 0x56, 0x9d, 0x35, 0x1e, 0x24, 0x0e, 0x5e, 0x63, 0x58, 0xd1, 0xa2,
    0x25, 0x22, 0x7c, 0x3b, 0x01, 0x21, 0x78, 0x87, 0xd4, 0x00, 0x46, 0x57, 0x9f,
    0xd3, 0x27, 0x52, 0x4c, 0x36, 0x02, 0xe7, 0xa0, 0xc4, 0xc8, 0x9e, 0xea, 0xbf,
    0x8a, 0xd2, 0x40, 0xc7, 0x38, 0xb5, 0xa3, 0xf7, 0xf2, 0xce, 0xf9, 0x61, 0x15,
    0xa1, 0xe0, 0xae, 0x5d, 0xa4, 0x9b, 0x34, 0x1a, 0x55, 0xad, 0x93, 0x32, 0x30,
    0xf5, 0x8c, 0xb1, 0xe3, 0x1d, 0xf6, 0xe2, 0x2e, 0x82, 0x66, 0xca, 0x60, 0xc0,
    0x29, 0x23, 0xab, 0x0d, 0x53, 0x4e, 0x6f, 0xd5, 0xdb, 0x37, 0x45, 0xde, 0xfd,
    0x8e, 0x2f, 0x03, 0xff, 0x6a, 0x72, 0x6d, 0x6c, 0x5b, 0x51, 0x8d, 0x1b, 0xaf,
    0x92, 0xbb, 0xdd, 0xbc, 0x7f, 0x11, 0xd9, 0x5c, 0x41, 0x1f, 0x10, 0x5a, 0xd8,
    0x0a, 0xc1, 0x31, 0x88, 0xa5, 0xcd, 0x7b, 0xbd, 0x2d, 0x74, 0xd0, 0x12, 0xb8,
    0xe5, 0xb4, 0xb0, 0x89, 0x69, 0x97, 0x4a, 0x0c, 0x96, 0x77, 0x7e, 0x65, 0xb9,
    0xf1, 0x09, 0xc5, 0x6e, 0xc6, 0x84, 0x18, 0xf0, 0x7d, 0xec, 0x3a, 0xdc, 0x4d,
    0x20, 0x79, 0xee, 0x5f, 0x3e, 0xd7, 0xcb, 0x39, 0x48)
# GB/T 32907-2016 system parameter FK, and CK[i][j] = ((4i + j) * 7) mod 256,
# which is the standard's generating rule for the 32 schedule constants.
SM4_FK = [0xa3b1bac6, 0x56aa3350, 0x677d9197, 0xb27022dc]
SM4_CK = [sum(((4 * i + j) * 7 & 0xff) << (8 * (3 - j)) for j in range(4))
          for i in range(32)]

# RFC 8439 section 2.3: the four sigma words are the little-endian words of the
# string "expand 32-byte k".
CHACHA_SIGMA = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
# XTEA (Needham-Wheeler): the golden-ratio delta and the 32-round starting sum of
# the decryption cycle, 32 * delta mod 2^32, written as the constant it evaluates
# to because this family's RTL contains no multiply operator.
XTEA_DELTA = 0x9E3779B9
XTEA_LAST_SUM = (32 * XTEA_DELTA) & MASK          # 0xC6EF3720
# NIST SP 800-38D: GHASH lives in GF(2^128) mod x^128 + x^7 + x^2 + x + 1 and the
# reflected reduction constant R is that polynomial's lower part placed in the top
# byte of the 128-bit block, i.e. 0xE1 followed by 120 zero bits.
GHASH_R = 0xE1 << 120
GHASH_R_HEX = '%032x' % GHASH_R


def rotr(expr, amount):
    """32-bit rotate right written as shift-or, the only form this family uses."""
    return '((%s) >> %d | (%s) << %d)' % (expr, amount, expr, 32 - amount)


def rotl(expr, amount):
    return '((%s) << %d | (%s) >> %d)' % (expr, amount, expr, 32 - amount)


def rr32(value, amount):
    """Numeric 32-bit rotate right, the model twin of the shift-or form above."""
    return ((value >> amount) | (value << (32 - amount))) & MASK


def rl32(value, amount):
    """Numeric 32-bit rotate left."""
    return ((value << amount) | (value >> (32 - amount))) & MASK


def sha256_round_body():
    """One FIPS 180-4 SHA-256 compression round over the eight working words, plus
    a slot-load beat so block 1 of a message can start from block 0's hash."""
    def word(index):
        return "(c[31] ? 32'h%08x : state_r[%d:%d])" % (
            SHA256_IV[index], 32 * index + 31, 32 * index)
    load = ['        case(c[2:0])',
            "            3'd0: state_n = {state_r[255:32], a};",
            "            3'd1: state_n = {state_r[255:64], a, state_r[31:0]};",
            "            3'd2: state_n = {state_r[255:96], a, state_r[63:0]};",
            "            3'd3: state_n = {state_r[255:128], a, state_r[95:0]};",
            "            3'd4: state_n = {state_r[255:160], a, state_r[127:0]};",
            "            3'd5: state_n = {state_r[255:192], a, state_r[159:0]};",
            "            3'd6: state_n = {state_r[255:224], a, state_r[191:0]};",
            "            default: state_n = {a, state_r[223:0]};",
            '        endcase',
        "        r = a; x = 32'hC000_0000 | c[2:0];"]
    e, f_, g_ = 'pl', 'mask', 'temp'
    parts = [
        "if(c[31] && c[30]) begin",                    # slot load, no round
        "    if(c[29:3] != 0) begin",
        "        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "    end else begin",
        '\n'.join(load),
        "    end",
        "end else if(c[30] || c[29:6] != 0) begin",     # round beat, t must be 0..63
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else begin",
        "    pa = %s;" % word(0),
        "    pb = %s;" % word(1),
        "    pc = %s;" % word(2),
        "    ph = %s;" % word(3),
        "    pl = %s;" % word(4),
        "    mask = %s;" % word(5),
        "    temp = %s;" % word(6),
        '    wide[31:0] = %s ^ %s ^ %s;' % (rotr(e, 6), rotr(e, 11), rotr(e, 25)),
        '    wide[63:32] = (%s & %s) ^ (~%s & %s);' % (e, f_, e, g_),
        '    x = %s + wide[31:0] + wide[63:32] + b + a;' % word(7),
        '    wide2[31:0] = %s ^ %s ^ %s;' % (
            rotr('pa', 2), rotr('pa', 13), rotr('pa', 22)),
        '    wide2[63:32] = (pa & pb) ^ (pa & pc) ^ (pb & pc);',
        '    wide[31:0] = ph + x;',
        '    r = x + wide2[31:0] + wide2[63:32];',
        '    state_n = {temp, mask, pl, wide[31:0], pc, pb, pa, r};',
        'end']
    return '\n'.join(parts)


SHA256_ROUND_BODY = sha256_round_body()


# FIPS 180-4 section 6.1.2 published SHA-1 initial hash value and round constants.
# The four K words come from the square roots of 2, 3, 5 and 10 (10, not the fifth
# prime), so the second one is 6ed9eba1 -- one wrong digit here changes every
# digest, which is exactly how the published vectors below catch it.
SHA1_IV = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
SHA1_K = [0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xca62c1d6]


def state_load_case(width, slots, target='a'):
    """RTL that writes exactly one 32-bit slot of a state window and copies the
    rest through: `width` is the register width, `slots` the addressable words."""
    lines = ['        case(c[2:0])']
    for index in range(8):
        if index >= slots:
            lines.append("            3'd%d: state_n = state_r;" % index)
            continue
        items = []
        if 32 * (index + 1) < width:
            items.append('state_r[%d:%d]' % (width - 1, 32 * (index + 1)))
        items.append(target)
        if index:
            items.append('state_r[%d:0]' % (32 * index - 1))
        lines.append("            3'd%d: state_n = {%s};" % (index, ', '.join(items)))
    lines.append('        endcase')
    return '\n'.join(lines)


def sha1_round_body():
    """One FIPS 180-4 SHA-1 compression round: chf and K window decoded from t, so
    the caller only has to supply the schedule word."""
    def word(index):
        return "(c[31] ? 32'h%08x : state_r[%d:%d])" % (
            SHA1_IV[index], 32 * index + 31, 32 * index)
    parts = [
        "if(c[31] && c[30]) begin",
        "    if(c[29:3] != 0 || c[2:0] > 3'd4) begin",
        "        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "    end else begin",
        state_load_case(256, 5),
        "        r = a; x = 32'hC000_0000 | c[2:0];",
        "    end",
        "end else if(c[30] || c[29:7] != 0 || c[6:0] > 7'd79) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else begin",
        "    pa = %s;" % word(0),
        "    pb = %s;" % word(1),
        "    pc = %s;" % word(2),
        "    ph = %s;" % word(3),
        "    pl = %s;" % word(4),
        "    if(c[6:0] < 7'd20) begin",
        "        mask = (pb & pc) ^ (~pb & ph);",
        "        temp = 32'h%08x;" % SHA1_K[0],
        "    end else if(c[6:0] < 7'd40) begin",
        "        mask = pb ^ pc ^ ph;",
        "        temp = 32'h%08x;" % SHA1_K[1],
        "    end else if(c[6:0] < 7'd60) begin",
        "        mask = (pb & pc) ^ (pb & ph) ^ (pc & ph);",
        "        temp = 32'h%08x;" % SHA1_K[2],
        "    end else begin",
        "        mask = pb ^ pc ^ ph;",
        "        temp = 32'h%08x;" % SHA1_K[3],
        "    end",
        "    wide[31:0] = %s + mask;" % rotl('pa', 5),
        "    wide[63:32] = %s;" % rotl('pb', 30),
        "    r = wide[31:0] + pl + a + temp;",
        "    x = mask;",
        "    state_n = {96'd0, ph, pc, wide[63:32], pa, r};",
        "end"]
    return '\n'.join(parts)


SHA1_ROUND_BODY = sha1_round_body()


def md5_round_body():
    """One RFC 1321 MD5 compression round over four words in state.

    The published rotate amounts run 7,12,17,22 / 5,9,14,20 / 4,11,16,23 /
    6,10,15,21, so `s` needs five control bits (c[12:8]); the mixing function
    selector is c[14:13].
    """
    def word(index):
        return "(c[31] ? 32'h%08x : state_r[%d:%d])" % (
            MD5_IV[index], 32 * index + 31, 32 * index)
    parts = [
        "if(c[30] && !c[31]) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else if(c[31] && c[30]) begin",
        "    if(c[29:3] != 0 || c[2:0] > 3'd3) begin",
        "        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "    end else begin",
        state_load_case(256, 4),
        "        r = a; x = 32'hC000_0000 | c[2:0];",
        "    end",
        "end else if(c[29:15] != 0 || c[7:0] != 0 || c[12:8] == 0) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else begin",
        "    pa = %s;" % word(0),
        "    pb = %s;" % word(1),
        "    pc = %s;" % word(2),
        "    ph = %s;" % word(3),
        "    case(c[14:13])",
        "        2'd0: pl = (pb & pc) ^ (~pb & ph);",
        "        2'd1: pl = (pb & ph) ^ (pc & ~ph);",
        "        2'd2: pl = pb ^ pc ^ ph;",
        "        default: pl = pc ^ (pb | ~ph);",
        "    endcase",
        "    mask = pl + pa + a + b;",
        "    sh = c[12:8];",
        "    wide[31:0] = (mask << sh) | (mask >> (32 - sh));",
        "    r = pb + wide[31:0];",
        "    x = mask;",
        "    state_n = {128'd0, pc, pb, r, ph};",
        "end",
    ]
    return '\n'.join(parts)


MD5_ROUND_BODY = md5_round_body()


def chacha_quarterround_body():
    """RFC 8439 section 2.3 quarter round, retired in the two ARX halves that the
    standard lists first (rotl 16/12) and second (rotl 8/7)."""
    parts = [
        "if(c[29:2] != 0) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else if(c[31]) begin",
        "    if(c[2]) begin",
        "        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "    end else begin",
        state_load_case(256, 4),
        "        r = a; x = 32'h8000_0000 | {30'd0, c[1:0]};",
        "    end",
        "end else if(c[1]) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else begin",
        "    pa = state_r[31:0];",
        "    pb = state_r[63:32];",
        "    pc = state_r[95:64];",
        "    ph = state_r[127:96];",
        "    pl = pa + pb;",
        "    mask = c[0] ? %s : %s;" % (rotl('ph ^ pl', 8), rotl('ph ^ pl', 16)),
        "    temp = pc + mask;",
        "    pb = c[0] ? %s : %s;" % (rotl('pb ^ temp', 7), rotl('pb ^ temp', 12)),
        "    r = pl;",
        "    x = mask;",
        "    state_n = {128'd0, mask, temp, pb, pl};",
        "end",
    ]
    return '\n'.join(parts)


CHACHA_BODY = chacha_quarterround_body()


def sm4_round_body():
    """One GB/T 32907-2016 SM4 round: T = L(tau(X1 ^ X2 ^ X3 ^ rk)), X4 = X0 ^ T,
    with the published S-box as a table ROM and L as five rotate-XOR terms."""
    parts = [
        "if(c[30:2] != 0) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else if(c[31]) begin",
        state_load_case(256, 4),
        "    r = a; x = 32'h8000_0000 | {30'd0, c[1:0]};",
        "end else if(c[1:0] != 0) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else begin",
        "    pb = state_r[63:32] ^ state_r[95:64] ^ state_r[127:96] ^ b;",
        # the substitution has to land in a register the ROM decoder can reuse
        sub_loop(SM4_SBOX, src='pb', dest='pc', zero_flag=False),
        "    temp = pc ^ %s ^ %s ^ %s ^ %s;" % (
            rotl('pc', 2), rotl('pc', 10), rotl('pc', 18), rotl('pc', 24)),
        "    r = state_r[31:0] ^ temp;",
        "    x = temp;",
        "    state_n = {128'd0, r, state_r[127:32]};",
        "end",
    ]
    return '\n'.join(parts)


SM4_ROUND_BODY = sm4_round_body()


def xtea_key_case(index, target):
    """The four key words live in state slots 3..6; one 2-bit index picks one."""
    return '\n'.join((
        '        case(%s)' % index,
        "            2'd0: %s = state_r[127:96];" % target,
        "            2'd1: %s = state_r[159:128];" % target,
        "            2'd2: %s = state_r[191:160];" % target,
        "            default: %s = state_r[223:192];" % target,
        '        endcase'))


def xtea_block_body():
    """One XTEA round (both Feistel halves plus the delta step) per beat, with the
    Needham-Wheeler decrypt order selected by the direction word in slot 7."""
    delta = "32'h9e37_79b9"
    parts = [
        "if(c[29:2] != 0) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else if(c[31]) begin",
        "    if(c[1:0] != 0) begin",
        "        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "    end else begin",
        "        state_n = {{31'd0, c[30]}, state_r[223:96],",
        "                   c[30] ? 32'hC6EF_3720 : 32'd0, b, a};",
        "        r = a; x = 32'h8000_0000 | {31'd0, c[30]};",
        "    end",
        "end else if(c[30]) begin",
        "    case(c[1:0])",
        "        2'd0: state_n = {state_r[255:128], a, state_r[95:0]};",
        "        2'd1: state_n = {state_r[255:160], a, state_r[127:0]};",
        "        2'd2: state_n = {state_r[255:192], a, state_r[159:0]};",
        "        default: state_n = {state_r[255:224], a, state_r[191:0]};",
        "    endcase",
        "    r = a; x = 32'h4000_0000 | {30'd0, c[1:0]};",
        "end else if(c[1:0] != 0) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else begin",
        "    pa = state_r[31:0];",
        "    pb = state_r[63:32];",
        "    pl = state_r[95:64];",
        "    ph = |state_r[255:224];",
        "    mask = ph ? (pl - %s) : (pl + %s);" % (delta, delta),
        # The half that uses the running sum takes K[(sum>>11)&3], i.e. sum bits
        # 12:11; the half that uses the stepped sum takes K[stepped_sum&3].
        "    idx = ph ? pl[12:11] : pl[1:0];",
        xtea_key_case('idx', 'pc'),
        "    if(ph) begin",
        "        temp = (((pa << 4) ^ (pa >> 5)) + pa) ^ (pl + pc);",
        "        pb = pb - temp;",
        "    end else begin",
        "        temp = (((pb << 4) ^ (pb >> 5)) + pb) ^ (pl + pc);",
        "        pa = pa + temp;",
        "    end",
        "    idx = ph ? mask[1:0] : mask[12:11];",
        xtea_key_case('idx', 'pc'),
        "    if(ph) begin",
        "        temp = (((pb << 4) ^ (pb >> 5)) + pb) ^ (mask + pc);",
        "        pa = pa - temp;",
        "    end else begin",
        "        temp = (((pa << 4) ^ (pa >> 5)) + pa) ^ (mask + pc);",
        "        pb = pb + temp;",
        "    end",
        "    r = pa; x = pb;",
        "    state_n = {state_r[255:224], state_r[223:96], mask, pb, pa};",
        "end",
    ]
    return '\n'.join(parts)


XTEA_BLOCK_BODY = xtea_block_body()


GHASH_DECL = ("reg [127:0] zz, vv, pw;\n"
              "reg fb;\n"
              "localparam [127:0] RH = 128'h%s;" % GHASH_R_HEX)


def ghash_body():
    """NIST SP 800-38D Algorithm 1 (multiply in GF(2^128) mod x^128 + x^7 + x^2 +
    x + 1) spread over eight beats: four install the multiplicand into V, four
    consume 32 multiplier bits each.  Z and V live in the 256-bit state."""
    return '\n'.join((
        "zz = state_r[127:0];",
        "vv = state_r[255:128];",
        "pw = a;",
        "fb = 1'b0;",
        "if(c[30:4] != 0 || c[2]) begin",
        "    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "end else if(c[3]) begin",
        "    if(c[31]) begin",
        "        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "    end else begin",
        "        temp = 32'd0;",
        "        for(lane = 0; lane < 32; lane = lane + 1) begin",
        "            if(pw[31]) begin",
        "                zz = zz ^ vv;",
        "                temp = temp + 32'd1;",
        "            end",
        "            fb = vv[0];",
        "            vv = vv >> 1;",
        "            if(fb) vv = vv ^ RH;",
        "            pw = pw << 1;",
        "        end",
        "        state_n = {vv, zz};",
        "        r = zz[31:0];",
        "        x = {20'd0, c[1:0], 8'd0} | temp;",
        "        if(c[1:0] == 2'd3) x = x | 32'h8000_0000;",
        "    end",
        "end else begin",
        "    if(c[31] && c[1:0] != 0) begin",
        "        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;",
        "    end else begin",
        "        if(c[31]) zz = 128'd0;",
        "        case(c[1:0])",
        "            2'd0: vv = {b, vv[95:0]};",
        "            2'd1: vv = {vv[127:96], b, vv[63:0]};",
        "            2'd2: vv = {vv[127:64], b, vv[31:0]};",
        "            default: vv = {vv[127:32], b};",
        "        endcase",
        "        state_n = {vv, zz};",
        "        r = b;",
        "        x = 32'h4000_0000 | {20'd0, c[1:0], 8'd0};",
        "        if(c[31]) x = x | 32'h8000_0000;",
        "    end",
        "end"))


GHASH_BODY = ghash_body()

core('aes128_round',
     'One AES-128 encryption round on one 32-bit column word. Byte j of a holds '
     'the ShiftRows-rotated state byte of row j, so the caller supplies the '
     'row-rotated column order. Each byte passes the published SubBytes table ROM '
     '(GF(2^8) inverse mod 0x11b then the affine map y ^ rot1(y) ^ rot2(y) ^ '
     'rot3(y) ^ rot4(y) ^ 0x63), then MixColumns over 0x11b in its hardware form '
     'out_j = xtime(s_j ^ s_j1) ^ s_j1 ^ s_j2 ^ s_j3 with subscripts mod 4, which '
     'is the published 2a + 3b + c + d matrix, where xtime is a shift-add step '
     'and never a multiply. b is the round-key column word XORed last. '
     'c[31]=1 selects the final round (no MixColumns). '
     'c[7:0] is the column index and must be 0..3 and c[29:8] must be zero, else '
     'f=1 with r=x=0. x[3:0]=1 per byte that entered the ROM as 0x00 (the '
     'inverse-of-zero bypass), x[15:8]=echo of c[7:0].',
     AES_ROUND_BODY,
     'A full AES round - substitute, mix, key add - closes in one combinational '
     'cone per column, so 4 beats retire a whole AES state block at II=1 instead '
     'of a per-byte software loop over a table.', 4)

core('aes_key_schedule',
     'AES-128 key expansion, one expanded word per accepted beat. state[127:0] is '
     'a sliding window whose slot j (bits 32j+) holds W i-1-j, so slot 0 is the '
     'word W i-1 that gets transformed and slot 3 is W i-4 that is XORed with it. '
     'c[31]=1 is a load beat: slot c[1:0] takes a and nothing shifts, r=a, '
     'x[31]=1 and x[1:0]=slot. The cipher key is installed by four load beats that '
     'put W 3-k in slot k, k=0..3. A run beat takes i=c[7:0] in 4..43 and emits '
     'W i = W i-4 ^ T, where T = W i-1 unless i mod 4 = 0; for those beats T = '
     'SubWord(RotWord(W i-1)) ^ Rcon[i/4], RotWord being a one-byte rotation '
     '(byte j takes byte j+1), SubWord the published S-box table ROM (GF(2^8) '
     'inverse then the affine map) and Rcon the xtime chain '
     '01,02,04,08,10,20,40,80,1b,36 decoded by a constant case on i and XORed into '
     'byte 0. The window then shifts and appends r. x[3:0]=1 per substituted byte '
     'that entered the ROM as 0x00, x[15:8]=echo of i, x[16]=1 marks that the '
     'substitution path ran. f=1 with r=x=0 and the window untouched when c[30] or '
     'c[29:8] is nonzero or i falls outside 4..43, so a bad descriptor never '
     'corrupts a schedule in progress. No multiply anywhere: the beat is table ROM, '
     'rotate, XOR and one shift.',
     KEY_SCHEDULE_BODY,
     'The 44-word expansion streams out at one word per beat with no recompute of '
     'earlier words, so a session key schedule costs 48 beats of fabric instead of '
     'a memory-resident round-key array.', 1, stateful=True)

core('sha256_round',
     'SHA-256 compression round (FIPS 180-4 section 6.2.2) over the eight working '
     'words in state: word j sits at bits 32j..32j+31, j=0 is A up to j=7 is H. '
     'The control word is c[5:0]=t plus two load bits. c[31]=1 with c[30]=0 is the '
     'restart beat: every word is replaced by the published IV 6a09e667 bb67ae85 '
     '3c6ef372 a54ff53a 510e527f 9b05688c 1f83d9ab 5be0cd19 (the first 32 bits of '
     'the fractional parts of sqrt(2,3,5,7,11,13,17,19)) before the round is '
     'applied, so that beat is round 0 of a new message. c[31]=1 with c[30]=1 is a '
     'slot-load beat: it runs no round and only writes a into word c[2:0], which is '
     'how the caller installs the previous block hash to chain block 1 and beyond; '
     'it answers r=a and x=C0000000 | slot. On a round beat a is the schedule word '
     'W t and b is the round constant K t - the 64 K words are the first 32 bits of '
     'the fractional parts of cbrt(2..311) and are fed in by the caller, so no '
     '64-entry table sits in the fabric. f=1 with r=x=0 and the window untouched '
     'when c[29:6] is nonzero on a round beat, when c[29:3] is nonzero on a '
     'slot-load beat, or when c[30] is set without c[31]. The round is '
     'T1 = H + Sigma1(E) + Ch(E,F,G) + K + W and T2 = Sigma0(A) + Maj(A,B,C), with '
     'Sigma0 = rotr2 ^ rotr13 ^ rotr22, Sigma1 = rotr6 ^ rotr11 ^ rotr25, '
     'Ch = (E and F) xor (not E and G) and Maj the majority of A,B,C: XOR, AND, NOT '
     'and shift-or rotates only, plus modulo-2^32 adds, never a multiply. The '
     'window then moves: H takes G, G takes F, F takes E, E takes D + T1, D takes '
     'C, C takes B, B takes A, and A takes T1 + T2. r = new A, x = T1, and the '
     'caller adds the eight output words of the final beat back onto the window it '
     'installed, which is the add the standard puts at the end of a block.',
     SHA256_ROUND_BODY,
     'One SHA-256 round per beat over a 256-bit register state with the Sigma, Ch '
     'and Maj cones hardwired: a message block costs 64 beats and no working-set '
     'traffic, which is where a scalar core spends most of its cycles.', 1,
     stateful=True)

core('sha1_round',
     'SHA-1 compression round (FIPS 180-4 section 6.1.2) over five words in state, '
     'slot j = A,B,C,D,E at bits 32j..32j+31. c[5:0..6:0]=t is the round index and '
     'a is the schedule word W t, which the caller expands (W t = rotl1 of '
     'W t-16 ^ W t-14 ^ W t-8 ^ W t-3 for t above 15, per FIPS 180-4 section '
     '6.1.2); b is unused because the '
     'round constant is decoded in the fabric from t: 5a827999 below 20, 6ed9eba1 '
     'below 40, 8f1bbcdc below 60 and ca62c1d6 from 60 on - the four published K '
     'words, so no constant table or port is needed. c[31]=1 with c[30]=0 loads the '
     'published IV 67452301 efcdab89 98badcfe 10325476 c3d2e1f0 into the window '
     'before the round, making that beat round 0 of a new message; c[31]=1 with '
     'c[30]=1 is a slot-load beat: it writes a into word c[2:0] (slot 5..7 or any '
     'of c[29:3] nonzero is malformed) and runs no round, answering r=a and '
     'x=C0000000|slot, which is how the caller chains block 1 from block 0. '
     'f=1 with r=x=0 and the window untouched when c[29:7] is nonzero, when t '
     'exceeds 79, or when c[30] is set without c[31]. The round is T = rotl(A,5) + '
     'f(B,C,D) + E + W + K with the published chf of FIPS 180-4 section 4: '
     'Ch(B,C,D) = (B and C) or (not B and D) for t below 20, Parity(B,C,D) for '
     'below 40, Maj(B,C,D) = (B and C) or (B and D) or (C and D) for below 60, and '
     'Parity again from 60, all built from XOR, AND, NOT and shift-or rotates plus '
     'modulo-2^32 adds, never a multiply. Then E takes D, D takes C, C takes '
     'rotl(B,30), B takes A and A takes T. r = new A, x = f(B,C,D).',
     SHA1_ROUND_BODY,
     'The 80-round SHA-1 chain runs one round per beat with the K window decoded '
     'from the round counter, so legacy SHA-1 framing shares the same fabric as '
     'SHA-256 instead of a second core.', 1, stateful=True)

core('md5_round',
     'MD5 compression round (RFC 1321 section 3.4) over four words in state, slot '
     'j = A,B,C,D at bits 32j..32j+31. a is the message word M[t] and b is the '
     'constant K[t], both supplied by the caller, so the 64-word sine table stays '
     'out of the fabric. c[14:13] picks the mixing function: 0 = F(B,C,D) = (B and '
     'C) or (not B and D), 1 = G = (B and D) or (C and not D), 2 = H = B xor C xor '
     'D, 3 = I = C xor (B or not D). c[12:8] is the published rotate amount s - '
     'five control bits because the s values run up to 23 - and must be nonzero. '
     'c[31]=1 with c[30]=0 replaces the window by the published IV 67452301 '
     'efcdab89 98badcfe 10325476 before the round, making that beat round 0 of a '
     'new message; c[31]=1 with c[30]=1 is a slot-load beat: it runs no round and '
     'writes a into word c[2:0] (slot 4..7 or c[29:3] nonzero is malformed), '
     'answering r=a and x=C0000000|slot, which is how the caller chains block 1 '
     'from block 0. T = A + f(B,C,D) + M[t] + K[t] mod 2^32, then A takes D, D '
     'takes C, C takes B and B = B + rotl(T,s): r = new B, x = T. f=1 with r=x=0 '
     'and the window untouched when c[29:15] or c[7:0] is nonzero, when s is zero, '
     'or when c[30] is set without c[31]. Rotate is shift-or, add is modulo 2^32, '
     'never a multiply.',
     MD5_ROUND_BODY,
     'MD5 rounds pipeline at one per beat with the rotate amount and the function '
     'select carried in the descriptor, so legacy MD5 ticket hashing shares one '
     'register state port with the SHA family instead of a table read.', 1,
     stateful=True)

core('chacha20_quarterround',
     'ChaCha20 quarter round (RFC 8439 section 2.3) as two beats over four words '
     'in state, slot j = A,B,C,D at bits 32j..32j+31. c[31]=1 with c[2]=0 is a '
     'load beat writing a into slot c[1:0] and answering r=a, x=80000000|slot: '
     'that is how the sigma words 61707865 3320646e 79622d32 6b206574 (the '
     'little-endian words of "expand 32-byte k"), the eight key words, the counter '
     'and the three nonce words are installed. c[31]=0 runs one half of the '
     'quarter round, picked by c[0]: 0 gives A+=B; D^=A; rotl(D,16); C+=D; B^=C; '
     'rotl(B,12) and 1 gives the same three steps with rotl(D,8) and rotl(B,7), so '
     'two beats in that order are exactly the published quarter round. Adds are '
     'modulo 2^32 and rotates are shift-or, never a multiply. r = updated A, x = '
     'updated D, while B and C stay in the window for the caller to read out of '
     'the state. f=1 with r=x=0 and the window untouched when c[29:2] is nonzero, '
     'when c[2] is set on a load beat, or when c[1] is set on a compute beat.',
     CHACHA_BODY,
     'The stream cipher core retires two of the six ARX steps every beat with all '
     'four words live in registers, so a 64-byte ChaCha20 block costs 160 compute '
     'beats plus the shuttling loads and no key-schedule memory.', 2,
     stateful=True)

core('sm4_round',
     'SM4 encryption round (GB/T 32907-2016 section 5.2) over the rolling four '
     'words in state, slot j = X i+j at bits 32j..32j+31. A round beat requires '
     'c[30:0] = 0 and takes the round key rk in b: A = X1 ^ X2 ^ X3 ^ rk, B = '
     'SubWords(A) through the published 256-byte SM4 S-box as a table ROM, T = '
     'L(B) = B ^ rotl(B,2) ^ rotl(B,10) ^ rotl(B,18) ^ rotl(B,24) (the standard L, '
     'four rotates and five terms), then X4 = X0 ^ T and the window shifts to '
     '(X1,X2,X3,X4): r = X4, x = T. c[31]=1 with c[2]=0 is a load beat writing a '
     'into slot c[1:0] and answering r=a, x=80000000|slot, so the 128-bit block is '
     'installed in four beats and the ciphertext is the final window read in '
     'reverse word order (X35..X32), which is what the standard outputs. f=1 with '
     'r=x=0 and the window untouched when c[30:2] is nonzero or when a round beat '
     'has c[1:0] nonzero. tau is a case-statement ROM and L is rotate-XOR, so no '
     'multiply appears.',
     SM4_ROUND_BODY,
     'One SM4 round per beat keeps the whole 128-bit block in registers and takes '
     'the round key as a descriptor word, so 32 beats finish a block with no '
     'key-schedule RAM and no multiplier.', 4, stateful=True)

core('xtea_block',
     'XTEA round - both Feistel halves plus the delta step - in one beat '
     '(Needham-Wheeler, 32 rounds, delta 9e3779b9). state slot 0 = X0, slot 1 = '
     'X1, slot 2 = sum, slots 3..6 = K0..K3, slot 7 = direction (zero encrypt, '
     'nonzero decrypt). A round beat requires c[30:0] = 0: encryption runs X0 += '
     '((X1<<4) ^ (X1>>5)) + X1 ^ (sum + K[sum & 3]), then sum += delta, then X1 += '
     '((X0<<4) ^ (X0>>5)) + X0 ^ (sum + K[(sum>>11) & 3]); decryption runs the two '
     'halves in the published reverse order with -= and sum -= delta. The sum '
     'carried into the next beat is the one used by the second half, so the beat '
     'consumes exactly one delta step per round, as the algorithm does. r = new '
     'X0, x = new X1. c[31]=1 restarts: X0 = a, X1 = b and sum = 0, or sum = '
     '32*delta mod 2^32 = C6EF3720 with the direction bit set when c[30]=1, the '
     'published starting sum of the decryption cycle; it answers r=a, '
     'x=80000000|direction. c[31]=0 with c[30]=1 loads a into key slot 3+c[1:0] '
     'and answers r=a, x=40000000|slot. f=1 with r=x=0 and the state untouched '
     'when c[29:2] is nonzero, or when a restart or round beat has c[1:0] nonzero. '
     'Adds and subtracts are modulo 2^32 and the (x<<4)^(x>>5) term is two '
     'shifts, never a multiply.',
     XTEA_BLOCK_BODY,
     'Both half-rounds plus the sum update retire in one beat with the key words '
     'held next to the block, so a full 32-round XTEA block is 32 beats and no '
     'per-half-round reload from memory.', 2, stateful=True)

core('ghash_mul32',
     'GHASH multiply in GF(2^128) mod x^128 + x^7 + x^2 + x + 1 (NIST SP 800-38D '
     'section 6.3, Algorithm 1), eight beats per product: state[127:0] is the '
     'accumulator Z and state[255:128] is V, the multiplicand being halved. '
     'c[3]=0 is an install beat: b goes into V word 3-c[1:0] (most significant '
     'word first), r = b and x = 40000000 | (index << 8); with c[31]=1 the same '
     'beat also zeroes Z, which is the restart beat and sets x[31] as well, and a '
     'restart with c[1:0] nonzero is malformed. c[3]=1 is a multiply beat: the 32 '
     'bits of a are consumed most significant bit first and per bit the loop does '
     'if x_bit then Z ^= V, then V >>= 1 and, when the shifted-out bit was 1, '
     'V ^= E10000000000000000000000000000000 - the reflected form of the field '
     'relation x^128 = x^7 + x^2 + x + 1. Four multiply beats (index 0..3, high '
     'word of the multiplier first) finish the product. r = Z[31:0]; the full '
     '128-bit product stays threaded through the state, where a GHASH stream '
     'XORs the next block into V and multiplies again, exactly as Algorithm 2 '
     'does. x = (index << 8) | number of set bits consumed and x[31]=1 marks the '
     'completing beat index 3. c[2] or c[30:4] nonzero is malformed: f=1 with '
     'r=x=0 and the state untouched, and a multiply beat with c[31] set is '
     'malformed too. No multiply anywhere: the field step is one shift and two '
     'conditional XORs.',
     GHASH_BODY,
     'A carry-less 128-bit field multiply that never touches the broken fabric '
     'multiplier: four beats fold 32 multiplier bits each through one shift-XOR '
     'halving chain, and both the accumulator and the halved multiplicand stay in '
     'fabric registers across the eight beats of a GHASH step.', 1,
     stateful=True, decl=GHASH_DECL)

core('lfsr_galois_keystream',
     'Galois (right-shifting) LFSR keystream stage, tap constant 80200003. '
     'state[31:0] = register, state[63:32] = running XOR of the keystream bytes, '
     'state[95:64] = beats since restart. c[31]=1 restarts with the seed from a '
     '(zero seed is a lockup and sets f=1). c[30]=0 runs eight tap-XOR steps per '
     'beat and c[30]=1 runs a single step so each tap decision is observable. '
     'r = new register, x[7:0] = keystream byte shifted out (LSB first), '
     'x[31:8] = beats counter, x[31]=1 on a restart beat. c[29:0] must be zero on '
     'a run beat else f=1 with r=x=0, and f=1 if a run beat leaves the register '
     'at zero. No multiply: the step is a shift plus a conditional tap XOR.',
     "mask = state_r[31:0];\n"
     "pb = 32'd0;\n"
     "if(c[29:0] != 30'd0) begin\n"
     "    f = 1'b1; r = 32'd0; x = 32'd0;\n"
     "    state_n = state_r;\n"
     "end else if(c[31]) begin\n"
     "    state_n = {160'd0, 32'd0, 32'd0, a};\n"
     "    r = a; x = 32'h8000_0000;\n"
     "    if(a == 32'd0) f = 1'b1;\n"
     "end else begin\n"
     "    for(lane = 0; lane < 8; lane = lane + 1) begin\n"
     "        if(!c[30] || lane == 0) begin\n"
     "            pc = mask[0];\n"
     "            mask = mask >> 1;\n"
     "            if(pc) mask = mask ^ 32'h8020_0003;\n"
     "            if(pc) pb = pb | (32'd1 << lane);\n"
     "        end\n"
     "    end\n"
     "    ph = state_r[63:32] ^ pb;\n"
     "    pl = state_r[95:64] + 32'd1;\n"
     "    state_n = {160'd0, pl, ph, mask};\n"
     "    r = mask; x = pb | (pl << 8);\n"
     "    if(mask == 32'd0) f = 1'b1;\n"
     "end",
     'Eight independent tap-XOR stages fold one keystream byte per beat with the '
     'lockup state detected in the same beat, so a seed that cannot generate is '
     'flagged instead of silently emitting zeros.', 1, stateful=True)


# --------------------------------------------------------------------------
# integer models, one function per core, dispatched by name
# --------------------------------------------------------------------------
STEP = {}


def model(name):
    def register(fn):
        STEP[name] = fn
        return fn
    return register


@model('lfsr_galois_keystream')
def _m_lfsr(a, b, c, state):
    if c & 0x3fffffff:
        return 0, 0, 1, state
    if c >> 31:
        seed = a & MASK
        return seed, 0x80000000, int(seed == 0), seed
    reg = state & MASK
    session = (state >> 32) & MASK
    beats = (state >> 64) & MASK
    steps = 1 if (c >> 30) & 1 else 8
    byte = 0
    for k in range(steps):
        lsb = reg & 1
        reg >>= 1
        if lsb:
            reg ^= 0x80200003
            byte |= 1 << k
        if reg == 0:
            break
    beats = (beats + 1) & MASK
    session ^= byte
    return (reg, (byte | (beats << 8)) & MASK, int(reg == 0),
            (beats << 64) | (session << 32) | reg)


@model('ghash_mul32')
def _m_ghash(a, b, c, state):
    """SP 800-38D Algorithm 1 over 8 beats: 4 install V, 4 consume 32 multiplier
    bits each.  state[127:0] = Z, state[255:128] = V."""
    if (c & 0x7ffffff0) or (c & 4):             # c[30:4] or c[2] reserved
        return 0, 0, 1, state
    low = (1 << 128) - 1
    z = state & low
    v = (state >> 128) & low
    idx = c & 3
    if c & 8:                                   # multiply beat
        if c >> 31:
            return 0, 0, 1, state
        pw = a & MASK
        count = 0
        for _ in range(32):                     # most significant bit first
            if pw >> 31:
                z ^= v
                count += 1
            v = (v >> 1) ^ GHASH_R if v & 1 else v >> 1
            pw = (pw << 1) & MASK
        x = (idx << 8) | count
        if idx == 3:
            x |= 1 << 31
        return z & MASK, x & MASK, 0, (v << 128) | z
    if (c >> 31) & 1 and idx:                   # restart must be the first install
        return 0, 0, 1, state
    if c >> 31:
        z = 0
    word = 32 * (3 - idx)
    v = (v & ~(MASK << word) & low) | ((b & MASK) << word)
    x = 0x40000000 | (idx << 8)
    if c >> 31:
        x |= 1 << 31
    return b & MASK, x, 0, (v << 128) | z


@model('aes128_round')
def _m_aes_round(a, b, c, state):
    if (c & 0xff) > 3 or (c & 0x3fffff00):
        return 0, 0, 1, state
    x = (c & 0xff) << 8
    sub = []
    for j in range(4):
        v = (a >> (8 * j)) & 0xff
        if v == 0:
            x |= 1 << j
        sub.append(AES_SBOX[v])
    if not (c >> 31) & 1:
        sub = [(xtime(sub[j] ^ sub[(j + 1) % 4]) ^ sub[(j + 1) % 4] ^
                sub[(j + 2) % 4] ^ sub[(j + 3) % 4]) & 0xff for j in range(4)]
    r = sum(sub[j] << (8 * j) for j in range(4))
    return (r ^ b) & MASK, x, 0, state


@model('aes_key_schedule')
def _m_schedule(a, b, c, state):
    window = state & ((1 << 128) - 1)
    if (c >> 30) & 1 or (c & 0x3fffff00):
        return 0, 0, 1, state
    if c >> 31:
        slot = c & 3
        window = (window & ~(MASK << (32 * slot))) | ((a & MASK) << (32 * slot))
        return a & MASK, 0x80000000 | slot, 0, window
    i = c & 0xff
    if i < 4 or i > 43:
        return 0, 0, 1, state
    prev = window & MASK                      # W i-1
    four_back = (window >> 96) & MASK         # W i-4
    x = 0
    if i % 4 == 0:
        rot = ((prev >> 8) | (prev << 24)) & MASK
        sub = 0
        for j in range(4):
            v = (rot >> (8 * j)) & 0xff
            if v == 0:
                x |= 1 << j
            sub |= AES_SBOX[v] << (8 * j)
        prev = (sub ^ AES_RCON[i // 4 - 1]) & MASK
        x |= 1 << 16
    r = (four_back ^ prev) & MASK
    return r, (x | (i << 8)) & MASK, 0, (((window << 32) | r) & ((1 << 128) - 1))


@model('sha256_round')
def _m_sha256(a, b, c, state):
    if (c >> 31) & 1 and (c >> 30) & 1:                 # slot load, no round
        if c & 0x3ffffff8:
            return 0, 0, 1, state
        slot = c & 7
        window = state & ((1 << 256) - 1) & ~(MASK << (32 * slot))
        return a, (0xC0000000 | slot), 0, window | (a << (32 * slot))
    if (c >> 30) & 1 or (c & 0x3fffffc0):               # reserved bits or bad t
        return 0, 0, 1, state
    if c >> 31:
        words = list(SHA256_IV)
    else:
        words = [(state >> (32 * j)) & MASK for j in range(8)]
    A, B, Cc, D, E, F, G, H = words
    s1 = rr32(E, 6) ^ rr32(E, 11) ^ rr32(E, 25)
    t1 = (H + s1 + ((E & F) ^ (~E & MASK & G)) + b + a) & MASK
    s0 = rr32(A, 2) ^ rr32(A, 13) ^ rr32(A, 22)
    t2 = (s0 + ((A & B) ^ (A & Cc) ^ (B & Cc))) & MASK
    new = [(t1 + t2) & MASK, A, B, Cc, (D + t1) & MASK, E, F, G]
    nxt = 0
    for index, value in enumerate(new):
        nxt |= value << (32 * index)
    return new[0], t1, 0, nxt


@model('sha1_round')
def _m_sha1(a, b, c, state):
    if (c >> 31) & 1 and (c >> 30) & 1:                 # slot load, no round
        if c & 0x3ffffff8 or (c & 7) > 4:
            return 0, 0, 1, state
        slot = c & 7
        window = state & ((1 << 256) - 1) & ~(MASK << (32 * slot))
        return a, 0xC0000000 | slot, 0, window | (a << (32 * slot))
    if (c >> 30) & 1 or c & 0x3fffff80 or (c & 0x7f) > 79:
        return 0, 0, 1, state
    t = c & 0x7f
    words = SHA1_IV if c >> 31 else \
        [(state >> (32 * j)) & MASK for j in range(5)]
    A, B, Cc, D, E = words
    if t < 20:
        mixed, const = (B & Cc) ^ (~B & MASK & D), SHA1_K[0]
    elif t < 40:
        mixed, const = B ^ Cc ^ D, SHA1_K[1]
    elif t < 60:
        mixed, const = (B & Cc) ^ (B & D) ^ (Cc & D), SHA1_K[2]
    else:
        mixed, const = B ^ Cc ^ D, SHA1_K[3]
    total = (rl32(A, 5) + mixed + E + a + const) & MASK
    new = [total, A, rl32(B, 30), Cc, D]
    nxt = 0
    for index, value in enumerate(new):
        nxt |= value << (32 * index)
    return new[0], mixed, 0, nxt


@model('md5_round')
def _m_md5(a, b, c, state):
    """RFC 1321 round: T = A + f(B,C,D) + M[t] + K[t], then B += rotl(T, s)."""
    if (c >> 31) & 1 and (c >> 30) & 1:               # slot load, no round
        if c & 0x3ffffff8 or (c & 7) > 3:
            return 0, 0, 1, state
        slot = c & 7
        window = state & ~(MASK << (32 * slot)) & ((1 << 256) - 1)
        return a & MASK, 0xC0000000 | slot, 0, window | ((a & MASK) << (32 * slot))
    if (c >> 30) & 1 or c & 0x3fff80ff or not ((c >> 8) & 0x1f):
        return 0, 0, 1, state
    words = MD5_IV if c >> 31 else \
        [(state >> (32 * j)) & MASK for j in range(4)]
    A, B, Cc, D = words
    fn = (c >> 13) & 3
    if fn == 0:
        mixed = (B & Cc) | (~B & MASK & D)
    elif fn == 1:
        mixed = (B & D) | (Cc & ~D & MASK)
    elif fn == 2:
        mixed = B ^ Cc ^ D
    else:
        mixed = Cc ^ (B | (~D & MASK))
    total = (A + mixed + a + b) & MASK
    turned = rl32(total, (c >> 8) & 0x1f)
    new = [D, (B + turned) & MASK, B, Cc]
    window = 0
    for index, value in enumerate(new):
        window |= value << (32 * index)
    return new[1], total, 0, window


@model('chacha20_quarterround')
def _m_chacha(a, b, c, state):
    """RFC 8439 section 2.3: the two ARX halves of a quarter round, one per beat."""
    if c & 0x3fffffc4:                                # c[29:2] reserved
        return 0, 0, 1, state
    if c >> 31:
        if c & 4:
            return 0, 0, 1, state
        slot = c & 3
        window = state & ~(MASK << (32 * slot)) & ((1 << 256) - 1)
        return a & MASK, 0x80000000 | slot, 0, window | ((a & MASK) << (32 * slot))
    if c & 2:
        return 0, 0, 1, state
    first = not (c & 1)
    A = state & MASK
    B = (state >> 32) & MASK
    Cc = (state >> 64) & MASK
    D = (state >> 96) & MASK
    A = (A + B) & MASK
    D = rl32(D ^ A, 16 if first else 8)
    Cc = (Cc + D) & MASK
    B = rl32(B ^ Cc, 12 if first else 7)
    return A, D, 0, (D << 96) | (Cc << 64) | (B << 32) | A


@model('sm4_round')
def _m_sm4(a, b, c, state):
    """GB/T 32907-2016 round function T = L(tau(X1^X2^X3^rk)), X4 = X0 ^ T."""
    if c & 0x7fffffc4:                                # c[30:2] reserved
        return 0, 0, 1, state
    if c >> 31:
        slot = c & 3
        window = state & ~(MASK << (32 * slot)) & ((1 << 256) - 1)
        return a & MASK, 0x80000000 | slot, 0, window | ((a & MASK) << (32 * slot))
    if c & 3:
        return 0, 0, 1, state
    mixed = ((state >> 32) ^ (state >> 64) ^ (state >> 96) ^ b) & MASK
    sub = 0
    for j in range(4):
        sub |= SM4_SBOX[(mixed >> (8 * j)) & 0xff] << (8 * j)
    total = sub
    for k in (2, 10, 18, 24):
        total ^= rl32(sub, k)
    total &= MASK
    x4 = ((state & MASK) ^ total) & MASK
    return x4, total, 0, (x4 << 96) | ((state >> 32) & ((1 << 96) - 1))


@model('xtea_block')
def _m_xtea(a, b, c, state):
    """Both Needham-Wheeler half-rounds and one delta step per accepted beat."""
    def feistel(value):
        return ((((value << 4) & MASK) ^ (value >> 5)) + value) & MASK

    if c & 0x3fffffc4:                                # c[29:2] reserved
        return 0, 0, 1, state
    if c >> 31:
        if c & 3:
            return 0, 0, 1, state
        direction = (c >> 30) & 1
        keys = state & (((1 << 128) - 1) << 96)
        total = XTEA_LAST_SUM if direction else 0
        nxt = ((direction << 224) | keys | (total << 64) |
               ((b & MASK) << 32) | (a & MASK))
        return a & MASK, 0x80000000 | direction, 0, nxt
    if (c >> 30) & 1:                                 # key load into slot 3..6
        slot = 3 + (c & 3)
        window = state & ~(MASK << (32 * slot)) & ((1 << 256) - 1)
        return a & MASK, 0x40000000 | (c & 3), 0, window | ((a & MASK) << (32 * slot))
    if c & 3:
        return 0, 0, 1, state
    x0 = state & MASK
    x1 = (state >> 32) & MASK
    total = (state >> 64) & MASK
    words = [(state >> (96 + 32 * k)) & MASK for k in range(4)]
    direction = bool((state >> 224) & MASK)
    if direction:
        nxt_sum = (total - XTEA_DELTA) & MASK
        x1 = (x1 - (feistel(x0) ^
                    ((total + words[(total >> 11) & 3]) & MASK))) & MASK
        x0 = (x0 - (feistel(x1) ^
                    ((nxt_sum + words[nxt_sum & 3]) & MASK))) & MASK
    else:
        nxt_sum = (total + XTEA_DELTA) & MASK
        x0 = (x0 + (feistel(x1) ^ ((total + words[total & 3]) & MASK))) & MASK
        x1 = (x1 + (feistel(x0) ^
                    ((nxt_sum + words[(nxt_sum >> 11) & 3]) & MASK))) & MASK
    keep = state & ~((1 << 96) - 1)             # direction and the four key words
    return x0, x1, 0, keep | (nxt_sum << 64) | (x1 << 32) | x0


def step(name, a, b, c, state=0):
    """Integer model of one accepted beat: (r, x, f, state_next)."""
    try:
        fn = STEP[name]
    except KeyError:
        raise NotImplementedError(name)
    return fn(a & MASK, b & MASK, c & MASK, state)


VECTORS = {}


def vectors(name, count=320):
    """Board vector rows (a, b, c); rows 0..127 are the ones the hardware runs."""
    try:
        fn = VECTORS[name]
    except KeyError:
        raise NotImplementedError(name)
    rows = fn()
    rng = Random(0xC2F00000 + sum(name.encode()))
    while len(rows) < count:
        rows.append((rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32)))
    return rows[:count]


def lfsr_rows():
    rows = []
    # restart with a spread of seeds: tap path and lockup detection
    for seed in (1, 2, 0x80000000, 0xdeadbeef, 0x0000ffff, 0x00ff00ff,
                 0x12345678, 0x9e3779b9, 0x80200003, 0x7fffffff, 0x5555aaaa,
                 0xa5a5a5a5, 0x000000f0, 0x0f0f0f0f, 0xffffffff, 0x88888888):
        rows.append((seed, 0, 1 << 31))
        for _ in range(6):
            rows.append((0, 0, 0))
    rows.append((0, 0, 1 << 31))                       # zero seed: lockup fault
    rows.append((0, 0, 0x00000100))                    # malformed control
    rows.append((1, 0, 0x20000000))                    # malformed control
    rows.append((0x10000001, 0, 0))                    # run from state 0: f=1
    return rows


VECTORS['lfsr_galois_keystream'] = lfsr_rows


def four_beat_products(pairs):
    rows = []
    for xw, y in pairs:
        rows.append((xw, y, 1 << 31))          # load beat also consumes byte 0
        rows.extend(((0, 0, 1), (0, 0, 2), (0, 0, 3)))
    return rows


def ghash_rows():
    fixed = [(0x80000000, 0x12345678), (0x12345678, 0x80000000),
             (0x00000001, 0xffffffff), (0xffffffff, 0x00000001),
             (0x00000000, 0xdeadbeef), (0xdeadbeef, 0x00000000),
             (0x04c11db7, 0x9e3779b9), (0xedb88320, 0x80200003),
             (0xa5a5a5a5, 0x5a5a5a5a), (0x00ff00ff, 0xff00ff00),
             (0x11111111, 0x22222222), (0x33333333, 0x44444444),
             (0xdeadbeef, 0xcafebabe), (0x87654321, 0x12345678),
             (0x000000f0, 0x0f0f0f0f), (0x9e3779b9, 0x9e3779b9)]
    rng = Random(0x61A50E)
    rows = four_beat_products(fixed)
    rows.append((0x12345678, 0x9e3779b9, 0x00000100))    # malformed control
    rows.append((0xdeadbeef, 0xcafebabe, 0x20000000))    # malformed control
    rows += four_beat_products([(rng.getrandbits(32), rng.getrandbits(32))
                                for _ in range(80)])
    return rows


def aes_round_rows():
    rows = []
    # every S-box input byte swept in each of the four lanes, both round kinds
    for v in range(0, 256, 5):
        for j in range(4):
            a = (v << (8 * j)) & MASK
            rows.append((a, (0x5a5a5a5a ^ v) & MASK, j))
            rows.append((a, (v << (8 * ((j + 1) % 4))) & MASK, 1 << 31))
            rows.append(((a ^ 0xff00ff00) & MASK, v, (1 << 31) | j))
    rows.insert(60, (0x010203ff, 0, 4))                    # column index out of range
    rows.insert(120, (0xdeadbeef, 0x12345678, 0x00000100))  # reserved control bits
    return rows


VECTORS['ghash_mul32'] = ghash_rows
VECTORS['aes128_round'] = aes_round_rows


def sched_rows():
    """Four complete AES-128 schedules: 4 load beats then the 40 expansion beats."""
    rows = []
    for key in (bytes(range(16)), bytes(16),
                bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c'),
                bytes.fromhex('0f1e2d3c4b5a69788796a5b4c3d2e1f0'),
                bytes.fromhex('e0a5cb9b1df80eb4a8ef0b8d3c7e5f61')):
        words = [pack_col(key[4 * i:4 * i + 4]) for i in range(4)]
        for k in range(4):                       # W 3-k goes into slot k
            rows.append((words[3 - k], 0, (1 << 31) | k))
        rows.extend((0, 0, i) for i in range(4, 44))
    rows.insert(60, (0xdeadbeef, 0, 1 << 30))            # reserved control bit
    rows.insert(120, (0, 0, 0x00000100))                 # reserved control bits
    rows.insert(124, (0, 0, 43 + 4))                      # i past the last word
    return rows


VECTORS['aes_key_schedule'] = sched_rows


def sha256_rows():
    """SHA-256 stimulus: single-block messages opened by the published IV restart,
    then a chained block whose eight slot-load beats install a running state and
    whose 64 round beats keep it.  Two malformed descriptors sit inside the first
    128 rows, where the harness checks them."""
    rows = []
    for message in (b'abc', b'',
                    b'The quick brown fox jumps over the lazy dog',
                    bytes(range(55))):
        schedule = _sha256_schedule(_sha256_blocks(message)[0])
        for t in range(64):
            rows.append((schedule[t], SHA256_K[t], t | ((1 << 31) if t == 0 else 0)))
    for slot in range(8):                       # chained block: install the state
        rows.append((0x6a09e667 ^ (slot << 24), 0, (1 << 31) | (1 << 30) | slot))
    schedule = _sha256_schedule(_sha256_blocks(b'a' * 112)[1])
    rows.extend((schedule[t], SHA256_K[t], t) for t in range(64))
    rows.insert(40, (0x12345678, 0x9abcdef0, 1 << 6))      # t out of 0..63
    rows.insert(90, (0xdeadbeef, 0xcafebabe, 1 << 20))     # reserved control bits
    return rows


VECTORS['sha256_round'] = sha256_rows


def _sha1_schedule(block):
    """FIPS 180-4 section 6.1.2 message schedule: a 32-bit rotate of an XOR sum."""
    words = [int.from_bytes(block[4 * i:4 * i + 4], 'big') for i in range(16)]
    for t in range(16, 80):
        words.append(rl32(words[t - 16] ^ words[t - 14] ^ words[t - 8] ^
                          words[t - 3], 1))
    return words


def _sha1_core(message):
    """SHA-1 of `message`, one compression round per accepted beat of the core."""
    hash_words = list(SHA1_IV)
    state = 0
    for block_index, block in enumerate(_sha256_blocks(message)):
        schedule = _sha1_schedule(block)
        if block_index:
            for slot in range(5):
                _r, _x, f, state = step('sha1_round', hash_words[slot], 0,
                                        (1 << 31) | (1 << 30) | slot, state)
                assert f == 0
            restart = 0
        else:
            restart = 1 << 31
        for t in range(80):
            _r, _x, f, state = step('sha1_round', schedule[t], 0,
                                    (restart if t == 0 else 0) | t, state)
            assert f == 0
        out = [(state >> (32 * j)) & MASK for j in range(5)]
        hash_words = [(out[j] + hash_words[j]) & MASK for j in range(5)]
    return ''.join('%08x' % v for v in hash_words)


def sha1_rows():
    rows = []
    for message in (b'abc', b'',
                    b'The quick brown fox jumps over the lazy dog'):
        schedule = _sha1_schedule(_sha256_blocks(message)[0])
        for t in range(80):
            rows.append((schedule[t], 0, t | ((1 << 31) if t == 0 else 0)))
    for slot in range(5):                       # chained block: install the window
        rows.append((0x67452301 ^ (slot << 20), 0, (1 << 31) | (1 << 30) | slot))
    schedule = _sha1_schedule(_sha256_blocks(b'a' * 64)[1])
    for t in range(80):
        rows.append((schedule[t], 0, t))
    rows.insert(40, (0x12345678, 0, 1 << 7))                    # t past 79
    rows.insert(90, (0xdeadbeef, 0, 1 << 20))                   # reserved bits
    return rows


VECTORS['sha1_round'] = sha1_rows


# --------------------------------------------------------------------------
# vector producers for the four legacy-stream cores
# --------------------------------------------------------------------------
def md5_rows():
    """Published MD5 (RFC 1321) round schedule over three real blocks.

    K[t] = floor(2**32 * abs(sin(t+1))) with the published per-round rotate
    amounts and message indices, so the board runs a genuine MD5 compression
    rather than an arbitrary shift-add pattern.
    """
    from math import sin
    rows = []
    k = [int(2 ** 32 * abs(sin(t + 1))) & MASK for t in range(64)]
    shifts = ([7, 12, 17, 22] * 4 + [5, 9, 14, 20] * 4 +
              [4, 11, 16, 23] * 4 + [6, 10, 15, 21] * 4)
    messages = (b'abc\x80' + b'\x00' * 57 + (24).to_bytes(8, 'little'),
                b'\x00' * 64,
                b'The quick brown fox jumps over the lazy dog\x80' +
                b'\x00' * 37 + (352).to_bytes(8, 'little'))
    for message in messages:
        words = [int.from_bytes(message[4 * i:4 * i + 4], 'little')
                 for i in range(16)]
        for t in range(64):
            if t < 16:
                sel, idx = 0, t
            elif t < 32:
                sel, idx = 1, (5 * t + 1) % 16
            elif t < 48:
                sel, idx = 2, (3 * t + 5) % 16
            else:
                sel, idx = 3, (7 * t) % 16
            c = (sel << 12) | (shifts[t] << 8)
            if t == 0:
                c |= 1 << 31                       # load the published IV
            rows.append((words[idx], k[t], c))
        # reserved control bits set: the core must reject and hold state
        rows.append((0x12345678, k[9], (1 << 14) | 0x1234))
        rows.append((0xdeadbeef, k[10], 1 << 29))
    return rows


def chacha20_rows():
    """RFC 8439 key stream: one quarter round per installed word group.

    The core keeps four words in registers, so each group installs its column or
    diagonal words and retires exactly one quarter round in two beats per leg.
    The installed words follow a host-side ChaCha20 state update, so the board
    sees the real intermediate state of a 20-round block, not random operands.
    """
    rows = []

    def rotl(v, n):
        return ((v << n) | (v >> (32 - n))) & MASK

    def quarter(state, a, b, c, d):
        state[a] = (state[a] + state[b]) & MASK
        state[d] = rotl(state[d] ^ state[a], 16)
        state[c] = (state[c] + state[d]) & MASK
        state[b] = rotl(state[b] ^ state[c], 12)
        state[a] = (state[a] + state[b]) & MASK
        state[d] = rotl(state[d] ^ state[a], 8)
        state[c] = (state[c] + state[d]) & MASK
        state[b] = rotl(state[b] ^ state[c], 7)

    groups = ((0, 4, 8, 12), (1, 5, 9, 13), (2, 6, 10, 14), (3, 7, 11, 15),
              (0, 5, 10, 15), (1, 6, 11, 12), (2, 7, 8, 13), (3, 4, 9, 14))
    for counter in (1, 2, 3):
        state = ([0x61707865, 0x3320646e, 0x79622d32, 0x6b206574] +
                 [int.from_bytes(bytes(range(4 * i, 4 * i + 4)), 'little')
                  for i in range(8)] +
                 [counter, 0x00000009, 0x4a000000, 0x00000000])
        for _double in range(10):
            for gindex, group in enumerate(groups):
                for slot, word in enumerate(group):
                    rows.append((state[word], 0, (1 << 31) | slot))
                for leg in (0, 1):        # two beats = exactly one quarter round
                    rows.append((0, 0, leg))
                quarter(state, *group)
                if _double == 0 and gindex == 0:
                    rows.append((1, 0, 1 << 12))   # reserved control bits set
                    rows.append((1, 0, 1 << 28))
    return rows


def sm4_rows():
    """SM4 (GB/T 32907-2016) rounds over the published test key and plaintext.

    The round-key words come from the published FK system constants and the
    ck[i][j] = ((4*i + j) * 7) mod 256 key-schedule constants applied to the
    standard 0123456789abcdeffedcba9876543210 key.  The S-box substitution that
    T' adds is the hardware's own job, so these operands are published constants
    with the substitution left to the core under test.
    """
    rows = []
    mk = [0x01234567, 0x89abcdef, 0xfedcba98, 0x76543210]
    fk = (0xa3b1bac6, 0x56aa3350, 0x677d9197, 0xb27022c9)
    ck = [[((4 * i + j) * 7) & 0xff for j in range(4)] for i in range(32)]
    rk = [(mk[i % 4] ^ fk[i % 4] ^
           (ck[i][0] << 24 | ck[i][1] << 16 | ck[i][2] << 8 | ck[i][3])) & MASK
          for i in range(32)]
    blocks = (bytes.fromhex('6162636465666768696a6b6c6d6e6f70'),
              bytes.fromhex('0123456789abcdeffedcba9876543210'),
              bytes(16),
              b'\xff' * 16)
    for block in blocks:
        words = [int.from_bytes(block[4 * i:4 * i + 4], 'big')
                 for i in range(4)]
        for slot in range(4):
            rows.append((words[slot], 0, (1 << 31) | slot))
        for i in range(32):
            rows.append((0, rk[i], 0))
        rows.append((0, rk[3], 1 << 13))           # reserved control bits
        rows.append((0, rk[4], 1 << 27))
    return rows


def xtea_rows():
    """XTEA encrypt-then-decrypt round trips so the board sees the identity.

    Each block restarts with sum 0, loads the four key words, runs 16 beats
    (32 half-rounds) forward, restarts at 32*delta and runs the published
    decryption cycle back.  A kernel that mixed the two half-rounds or lost the
    sum update cannot survive the second restart.
    """
    rows = []
    pairs = ((0x01020304, 0x05060708), (0xdeadbeef, 0xcafebabe),
             (0x00000000, 0xffffffff), (0x87654321, 0x12345678))
    keys = ((0x00010203, 0x04050607, 0x08090a0b, 0x0c0d0e0f),
            (0xdecafbad, 0x12345678, 0x9abcdef0, 0x0f1e2d3c))
    for index, (x0, x1) in enumerate(pairs):
        key = keys[index % 2]
        rows.append((x0, x1, 1 << 31))             # restart, sum = 0
        for slot, word in enumerate(key):
            rows.append((word, 0, (1 << 30) | slot))
        for _ in range(16):
            rows.append((0, 0, 0))
        rows.append((x0, x1, (1 << 31) | (1 << 30)))   # restart at 32*delta
        for _ in range(16):
            rows.append((0, 0, 0))
        rows.append((0, 0, 1 << 15))               # reserved control bits
        rows.append((1, 1, 1 << 26))
    for x0, x1 in pairs:                           # shorter forward-only runs
        rows.append((x0, x1, 1 << 31))
        for slot, word in enumerate(keys[1]):
            rows.append((word, 0, (1 << 30) | slot))
        for _ in range(8):
            rows.append((0, 0, 0))
    return rows


VECTORS['md5_round'] = md5_rows
VECTORS['chacha20_quarterround'] = chacha20_rows
VECTORS['sm4_round'] = sm4_rows
VECTORS['xtea_block'] = xtea_rows


def ghash_rows():
    """Forty distinct GHASH products, eight beats each.

    The earlier producer installed the same four words for every product, so its
    install beats repeated one answer and the family gate counted only 34
    distinct responses out of the 96 it needs.  Each product here installs and
    multiplies fresh words from a seeded stream, so the install beats answer with
    a different word and the multiply beats with a different low accumulator.
    """
    rows = []
    stream = [0x66E94BD4EF8A2C3B]

    def word():
        stream[0] = (stream[0] * 6364136223846793005 +
                     1442695040888963407) & ((1 << 64) - 1)
        return (stream[0] >> 32) & MASK

    for index in range(40):
        mult = [word() for _ in range(4)]
        cand = [word() for _ in range(4)]
        for idx in range(4):
            if index == 0 and idx == 0:
                rows.append((1, 1, 4))                  # reserved c[2] set
                rows.append((1, 1, 1 << 20))            # reserved c[30:4] set
            rows.append((0, cand[idx],
                         (1 << 31) if idx == 0 else idx))
        for idx in range(4):
            rows.append((mult[idx], 0, 8 | idx))
    return rows


VECTORS['ghash_mul32'] = ghash_rows


def selftest():
    """Independent-model checks against published or hand-derived values."""
    checks = 0
    # Galois LFSR tap step, hand-derived from tap constant 80200003.
    r, x, f, st = step('lfsr_galois_keystream', 1, 0, 1 << 31, 0)
    assert (r, x, f, st) == (1, 0x80000000, 0, 1)
    r, x, f, _ = step('lfsr_galois_keystream', 0, 0, 1 << 30, 1)
    assert (r, x, f) == (0x80200003, 1 | (1 << 8), 0)          # seed 1, one step
    r, x, f, _ = step('lfsr_galois_keystream', 0, 0, 1 << 30, 2)
    assert (r, x, f) == (1, 0 | (1 << 8), 0)                   # seed 2, one step
    r, x, f, _ = step('lfsr_galois_keystream', 0, 0, 1 << 30, 0x80000000)
    assert (r, x, f) == (0x40000000, 0 | (1 << 8), 0)          # MSB seed, no tap
    checks += 4
    # linear feedback: the step of a XOR is the XOR of the steps
    for pair in ((0x12345678, 0xdeadbeef), (0xffffffff, 0x00000001),
                 (0x80200003, 0x12345678)):
        one = _lfsr8(pair[0])
        two = _lfsr8(pair[1])
        both = _lfsr8(pair[0] ^ pair[1])
        assert (one[0] ^ two[0], one[1] ^ two[1]) == both
        checks += 1
    # lockup: a zero register can never recover, and the core has to say so
    r, x, f, _ = step('lfsr_galois_keystream', 0, 0, 0, 0)
    assert (r, x, f) == (0, 1 << 8, 1)
    r, x, f, _ = step('lfsr_galois_keystream', 0, 0, 1 << 31, 0)
    assert (r, x, f) == (0, 0x80000000, 1)
    checks += 2
    # malformed control always answers zero with the error flag
    for bad in (0x00000100, 0x00010000, 0x1fffffff):
        assert step('lfsr_galois_keystream', 7, 7, bad, 0x96) == (0, 0, 1, 0x96)
        checks += 1
    # GHASH in GF(2^128) mod x^128+x^7+x^2+x+1, driven through the eight beats of
    # step() itself.  The block 8000..00 is the field element 1, so it has to be
    # the identity in both operand slots, and x^127 * x is x^128, which the field
    # relation folds to x^7+x^2+x+1 = e1 in the top byte -- hand-derived here from
    # the polynomial alone, not read back out of a model run.
    ONE = 1 << 127
    assert int.from_bytes(b'\x80' + b'\x00' * 15, 'big') == ONE
    assert _gmul(1, 1 << 126) == 0xe1 << 120
    checks += 1
    for value in (ONE, 0, 1, 1 << 126, MASK << 96, 0xe1 << 120,
                  int.from_bytes(bytes(range(16)), 'big')):
        assert _gmul(value, ONE) == value
        assert _gmul(ONE, value) == value
        assert _gmul(value, 0) == 0
        checks += 1
    H = int.from_bytes(bytes.fromhex('66e94bd4ef8a2c3b884cfa59ca342b2e'), 'big')
    for trip in ((H, 0xdeadbeefcafebabe0123456789abcdef,
                  0x000102030405060708090a0b0c0d0e0f),
                 (ONE, H, 0xffffffffffffffffffffffffffffffff),
                 (0xe1 << 120, 1 << 127, 0x80200003ed8832019e3779b901234567)):
        a, bb, cc = trip
        assert _gmul(a, bb) == _gmul(bb, a)
        assert _gmul(_gmul(a, bb), cc) == _gmul(a, _gmul(bb, cc))
        assert _gmul(a ^ bb, cc) == (_gmul(a, cc) ^ _gmul(bb, cc))
        checks += 3
    for pair in ((H, 0xdeadbeefcafebabe0123456789abcdef),
                 (0x00112233445566778899aabbccddeeff, 0xfedcba98765432100123456789abcdef),
                 (1, H), (0xe1 << 120, 0x80000000000000000000000000000001),
                 (MASK << 96, 0x0f0e0d0c0b0a09080706050403020100),
                 (0x80200003ed8832019e3779b901234567, 0x7fffffffffffffff8000000000000001)):
        a, bb = pair
        assert _gmul(a, bb) == _ghash_ref(a, bb)
        checks += 1
    # published anchor: CRC-32/IEEE of 123456789 is 0xCBF43926, and the bit-serial
    # updater below is the same shift-XOR reduction this core's ring step performs
    assert _crc32(b'123456789') == 0xCBF43926
    assert _crc32(b'') == 0x00000000
    assert _crc32(b'a') == 0xE8B7BE43
    checks += 3
    assert step('ghash_mul32', 1, 2, 0x00000100, 0)[:3] == (0, 0, 1)
    assert step('ghash_mul32', 1, 2, 0x20000000, 0)[:3] == (0, 0, 1)
    checks += 2
    # the restart beat, the install index and the completing beat must all be
    # distinguishable in aux: install beats carry x[30] with the word index in
    # x[15:8], the restart beat additionally sets x[31], and the completing
    # multiply beat (index 3) sets x[31] while every multiply beat reports the
    # number of set multiplier bits it consumed in x[7:0].
    r, x, f, st = step('ghash_mul32', 0, 0xdeadbeef, 1 << 31, 0)
    assert (r, x, f) == (0xdeadbeef, 0xc0000000, 0)
    _r, x, _f, st = step('ghash_mul32', 0, 0xcafebabe, 1, st)
    assert x == 0x40000100
    _r, x, _f, st = step('ghash_mul32', 0, 0x80000000, 2, st)
    assert x == 0x40000200
    _r, x, _f, st = step('ghash_mul32', 0, 0x12345678, 3, st)
    assert x == 0x40000300
    _r, x, _f, st = step('ghash_mul32', 0x80000000, 0, 8 | 0, st)
    assert x == 0x00000001
    _r, x, _f, st = step('ghash_mul32', 0, 0, 8 | 1, st)
    assert x == 0x00000100
    _r, x, _f, st = step('ghash_mul32', 0, 0, 8 | 2, st)
    assert x == 0x00000200
    r, x, f, st = step('ghash_mul32', 0, 0, 8 | 3, st)
    assert (r, x, f) == (0x12345678, 0x80000300, 0)
    assert st & ((1 << 128) - 1) == (0xdeadbeef << 96) | (0xcafebabe << 64) | \
        (0x80000000 << 32) | 0x12345678
    checks += 9
    # a multiply beat may not restart, and a restart must be the first install
    assert step('ghash_mul32', 1, 1, (1 << 31) | 8, st)[:3] == (0, 0, 1)
    assert step('ghash_mul32', 0, 1, (1 << 31) | 2, st)[:3] == (0, 0, 1)
    checks += 2
    # ---- published SubBytes row: FIPS-197 Table 7 starts 63 7c 77 7b f2 6b
    assert AES_SBOX[:6] == [0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b]
    assert len(set(AES_SBOX)) == 256
    checks += 2
    r, x, f, _s = step('aes128_round', 0x05040302, 0, 1 << 31, 0)
    assert (r, x, f) == (0x6bf27b77, 0, 0)
    r, x, f, _s = step('aes128_round', 0x03020100, 0, 1 << 31, 0)
    assert (r, x, f) == (0x7b777c63, 1, 0)
    checks += 2
    # ---- published xtime pair from FIPS-197 section 4.2.1 and its inverse
    assert xtime(0x57) == 0xAE and halve(0xAE) == 0x57
    assert xtime(0x80) == 0x1B and halve(0x1B) == 0x80      # the 0x11b reduction
    assert all(halve(xtime(v)) == v for v in range(256))
    checks += 3
    # ---- MixColumns: the core's one-xtime form must equal the published
    # matrix 2a + 3b + c + d, here re-derived with the general GF(2^8)
    # multiplier gmul11b, on the spec's own example column and more.
    src = [AES_INV_SBOX[v] for v in (0xd4, 0xbf, 0x5d, 0x30)]
    r, _x, _f, _s = step('aes128_round', pack_col(src), 0, 0, 0)
    assert [r >> (8 * j) & 0xff for j in range(4)] == [
        gmul11b(2, a0) ^ gmul11b(3, a1) ^ a2 ^ a3
        for a0, a1, a2, a3 in ((0xd4, 0xbf, 0x5d, 0x30), (0xbf, 0x5d, 0x30, 0xd4),
                               (0x5d, 0x30, 0xd4, 0xbf), (0x30, 0xd4, 0xbf, 0x5d))]
    checks += 1
    for col in ((0x00, 0x01, 0x02, 0x03), (0x87, 0x6e, 0x46, 0xa6),
                (0x8a, 0x8a, 0x8a, 0x8a), (0xff, 0x00, 0xf0, 0x0f),
                (0x57, 0xae, 0x1b, 0x9d), (0x1b, 0x80, 0x01, 0xff)):
        # the core substitutes first, so the fed column is the S-box preimage of
        # `col` and MixColumns then runs on `col` itself.
        expect = [gmul11b(2, col[j]) ^ gmul11b(3, col[(j + 1) % 4]) ^
                  col[(j + 2) % 4] ^ col[(j + 3) % 4] for j in range(4)]
        word = pack_col([AES_INV_SBOX[v] for v in col])
        r, _x, _f, _s = step('aes128_round', word, 0, 0, 0)
        assert [r >> (8 * j) & 0xff for j in range(4)] == expect
        checks += 1
    # zero-byte bypass flags must be per lane and must not leak into other lanes
    for j in range(4):
        r, x, f, _s = step('aes128_round', 0xffffffff & ~(0xff << (8 * j)), 0,
                           1 << 31, 0)
        assert x & 0xf == 1 << j
        checks += 1
    # malformed control
    assert step('aes128_round', 1, 2, 4, 0)[:3] == (0, 0, 1)
    assert step('aes128_round', 1, 2, 0x00000100, 0)[:3] == (0, 0, 1)
    checks += 2
    # ---- published FIPS-197 AES-128 vector, every round through this core
    assert _aes128_encrypt(bytes(range(16)),
                           bytes.fromhex('00112233445566778899aabbccddeeff')) == \
        '69c4e0d86a7b0430d8cdb78070b4c55a'
    checks += 1
    # ---- key schedule core: published Rcon chain from FIPS-197 section 5.2
    assert AES_RCON == [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]
    checks += 1
    # all-zero key, hand-derived from the published S-box value S[0x00]=0x63 and
    # the published Rcon[1]=0x01: SubWord(RotWord(0)) ^ Rcon has bytes 62,63,63,63,
    # which is 0x63636362 in this byte-j-at-bits-8j layout, and W 5..W 7 repeat it
    # because W i-4 is still zero.  x[3:0]=1111 on beat 4 records that all four
    # bytes entered the ROM as 0x00, x[16] that the substitution path ran.
    state = 0
    for k in range(4):
        r, x, f, state = step('aes_key_schedule', 0, 0, (1 << 31) | k, state)
        assert (r, x, f) == (0, 0x80000000 | k, 0)
        checks += 1
    for index, expect_x in ((4, 0x0001040f), (5, 0x500), (6, 0x600), (7, 0x700)):
        r, x, f, state = step('aes_key_schedule', 0, 0, index, state)
        assert (r, x, f) == (0x63636362, expect_x, 0)
        checks += 1
    # malformed descriptors leave the window untouched and answer f=1
    for bad in (1 << 30, 0x00000100, 44, 3, 0x00002000):
        assert step('aes_key_schedule', 0xdeadbeef, 7, bad, state)[:3] == (0, 0, 1)
        checks += 1
    assert step('aes_key_schedule', 0xdeadbeef, 7, 0, state)[:3] == (0, 0, 1)
    checks += 1
    assert step('aes_key_schedule', 0x1234, 0, (1 << 31) | 2, state)[3] == \
        (state & ((1 << 128) - 1) & ~(MASK << 64)) | (0x1234 << 64)
    checks += 1
    # the core's expansion must reproduce the algorithm of FIPS-197 section 5.2,
    # and driving the published Appendix C.1 ciphertext with the core's own round
    # keys pins all 44 words against a published value.
    key = bytes(range(16))
    assert _core_schedule(key) == _aes_schedule(key)
    assert _aes128_encrypt(key, bytes.fromhex('00112233445566778899aabbccddeeff'),
                           _core_schedule(key)) == '69c4e0d86a7b0430d8cdb78070b4c55a'
    checks += 2
    # second published vector: the all-zero key and all-zero block give the
    # widely printed 66e94bd4ef8a2c3b884cfa59ca342b2e, again with the core's own
    # round keys (the schedule for the zero key is the hand-derived one above)
    assert _aes128_encrypt(bytes(16), bytes(16), _core_schedule(bytes(16))) == \
        '66e94bd4ef8a2c3b884cfa59ca342b2e'
    checks += 1
    # ---- SHA-256: the published IV words and the four published leading K words
    assert SHA256_IV == [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                         0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    assert SHA256_K[:4] == [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5]
    assert len(set(SHA256_K)) == 64
    checks += 3
    # ---- the published FIPS 180-4 example digest for "abc", every one of the 64
    # compression rounds taken from this core
    assert _sha256_core(b'abc') == ('ba7816bf8f01cfea414140de5dae2223b00361a39617'
                                    '7a9cb410ff61f20015ad')
    assert _sha256_core(b'') == ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b9'
                                 '34ca495991b7852b855')
    checks += 2
    # a two-block message, so the second block must chain from the state the core
    # kept rather than from a fresh IV
    assert _sha256_core(b'a' * 112) == ('f54353008a2553262ecdc4a34749563ba0950e8b'
                                        '0fc8652780b0a614b99683c1')
    checks += 1
    # malformed descriptors fault and leave the running window exactly as it was
    assert step('sha256_round', 1, 2, 64, 0)[:3] == (0, 0, 1)
    assert step('sha256_round', 1, 2, 1 << 20, 0)[:3] == (0, 0, 1)
    assert step('sha256_round', 1, 2, (1 << 31) | 64, 0)[:3] == (0, 0, 1)
    checks += 3
    _r, _x, _f, keep = step('sha256_round', 0x61626380, SHA256_K[0], 1 << 31, 0)
    assert keep != 0 and step('sha256_round', 0, 0, 1 << 20, keep)[3] == keep
    checks += 2
    # a slot-load beat writes exactly one window word, runs no round and answers
    # r=a, x=C0000000|slot - this is the only way to chain past block 0
    r, x, f, st = step('sha256_round', 0x11111111, 0x9e3779b9,
                      (1 << 31) | (1 << 30) | 5, 0)
    assert (r, x, f, st) == (0x11111111, 0xC0000005, 0, 0x11111111 << 160)
    assert step('sha256_round', 1, 0, (1 << 31) | (1 << 30) | (1 << 3), 0)[:3] == \
        (0, 0, 1)
    assert step('sha256_round', 1, 0, 1 << 30, 0)[:3] == (0, 0, 1)
    checks += 3
    # ---- SHA-1: published IV words and the four published K windows
    assert SHA1_IV == [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
    assert SHA1_K == [0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xca62c1d6]
    checks += 2
    # ---- published digests, every one of the 80 rounds taken from this core
    assert _sha1_core(b'abc') == 'a9993e364706816aba3e25717850c26c9cd0d89d'
    assert _sha1_core(b'') == 'da39a3ee5e6b4b0d3255bfef95601890afd80709'
    assert _sha1_core(b'a' * 64) == '0098ba824b5c16427bd7a1122a5a442a25ec644d'
    checks += 3
    # hand-derived round: a zeroed window (five slot loads) with W = 0 makes
    # Ch(0,0,0) and rotl(0,5) zero, so T is exactly the published K[0] word
    state = 0
    for slot in range(5):
        _r, _x, f, state = step('sha1_round', 0, 0, (1 << 31) | (1 << 30) | slot,
                                state)
        assert f == 0
    r, x, f, state = step('sha1_round', 0, 0, 0, state)
    assert (r, x, f, state) == (0x5a827999, 0, 0, 0x5a827999)
    checks += 1
    assert step('sha1_round', 1, 0, 80, 0)[:3] == (0, 0, 1)
    assert step('sha1_round', 1, 0, (1 << 31) | (1 << 30) | 5, 0)[:3] == (0, 0, 1)
    assert step('sha1_round', 1, 0, 1 << 30, 0)[:3] == (0, 0, 1)
    assert step('sha1_round', 1, 0, (1 << 31) | (1 << 30) | (1 << 4), 0)[:3] == \
        (0, 0, 1)
    checks += 4
    return checks


def halve(value):
    """Inverse of xtime: the unique byte whose doubling gives `value`."""
    return ((value ^ 0x1B) >> 1) | 0x80 if value & 1 else value >> 1


def pack_col(four):
    """Column word in the layout every core here uses: byte j, bits 8j, is row j."""
    return sum(v << (8 * j) for j, v in enumerate(four)) & MASK


def _aes_schedule(key):
    words = [pack_col(key[4 * i:4 * i + 4]) for i in range(4)]
    for i in range(4, 44):
        t = words[i - 1]
        if i % 4 == 0:
            t = ((t >> 8) | (t << 24)) & MASK       # RotWord: byte j takes byte j+1
            t = sum(AES_SBOX[(t >> (8 * j)) & 0xff] << (8 * j) for j in range(4))
            t ^= AES_RCON[i // 4 - 1]
        words.append((words[i - 4] ^ t) & MASK)
    return words


def _core_schedule(key):
    """The 44 expanded words streamed out of the aes_key_schedule core itself:
    four load beats installing W 3-k in slot k, then beats i = 4..43."""
    words = [pack_col(key[4 * i:4 * i + 4]) for i in range(4)]
    state = 0
    for k in range(4):
        _r, _x, f, state = step('aes_key_schedule', words[3 - k], 0,
                                (1 << 31) | k, state)
        assert f == 0
    for i in range(4, 44):
        r, _x, f, state = step('aes_key_schedule', 0, 0, i, state)
        assert f == 0
        words.append(r)
    return words


def _aes128_encrypt(key, block, words=None):
    """FIPS-197 encryption driven beat by beat through step('aes128_round')."""
    if words is None:
        words = _aes_schedule(key)
    state = [pack_col(block[4 * c:4 * c + 4]) ^ words[c] for c in range(4)]
    for rnd in range(1, 11):
        out = []
        for c in range(4):
            a = 0
            for r in range(4):          # ShiftRows takes row r from column c + r
                a |= ((state[(c + r) % 4] >> (8 * r)) & 0xff) << (8 * r)
            control = ((1 << 31) | c) if rnd == 10 else c
            value, _x, f, _s = step('aes128_round', a, words[rnd * 4 + c],
                                    control, 0)
            assert f == 0
            out.append(value)
        state = out
    return ''.join(''.join('%02x' % ((v >> (8 * j)) & 0xff) for j in range(4))
                   for v in state)


def _gmul(x, y):
    """One 128-bit GHASH product driven through the eight beats of step()."""
    low128 = (1 << 128) - 1
    state = 0
    for idx in range(4):                # install V = y, most significant word first
        _r, _x, f, state = step('ghash_mul32', 0,
                                (y >> (32 * (3 - idx))) & MASK,
                                (1 << 31) if idx == 0 else idx, state)
        assert not f, f'ghash install beat {idx} rejected'
    for idx in range(4):                # consume the multiplier, high word first
        _r, _x, f, state = step('ghash_mul32', (x >> (32 * (3 - idx))) & MASK, 0,
                                8 | idx, state)
        assert not f, f'ghash multiply beat {idx} rejected'
    return state & low128


def _ghash_ref(x, y):
    """GHASH product computed in degree order instead of the core's halving chain.

    A block bit at index i is the coefficient of x**(127-i), so the elements are
    rewritten into degrees, multiplied schoolbook over GF(2)[x], and reduced
    mod x**128 + x**7 + x**2 + x + 1 from the top degree down.  Nothing here
    mirrors the core's shift-XOR step, which works from the reflected constant.
    """
    coef = [0] * 256
    for a in range(128):
        if (x >> a) & 1:
            da = 127 - a
            for b in range(128):
                if (y >> b) & 1:
                    coef[da + 127 - b] ^= 1
    for d in range(255, 127, -1):
        if coef[d]:
            coef[d] = 0
            for e in (7, 2, 1, 0):
                coef[d - 128 + e] ^= 1
    out = 0
    for d in range(128):
        if coef[d]:
            out |= 1 << (127 - d)
    return out


def _crc32(data):
    """Bit-serial CRC-32/IEEE: published anchor for the XOR-reduction algebra."""
    crc = MASK
    for byte in data:
        for _ in range(8):
            if (crc ^ byte) & 1:
                crc = (crc >> 1) ^ 0xEDB88320
            else:
                crc >>= 1
            byte >>= 1
    return (crc ^ MASK) & MASK


def _lfsr8(reg):
    """Model of one eight-step beat, used only for the linearity check."""
    byte = 0
    for k in range(8):
        lsb = reg & 1
        reg >>= 1
        if lsb:
            reg ^= 0x80200003
            byte |= 1 << k
    return reg, byte


def _sha256_blocks(message):
    """FIPS 180-4 padding: 0x80, zeros up to a length of 56 mod 64, then the
    64-bit big-endian message bit length."""
    padded = message + b'\x80'
    padded += b'\x00' * ((56 - len(padded)) % 64)
    padded += (8 * len(message)).to_bytes(8, 'big')
    return [padded[i:i + 64] for i in range(0, len(padded), 64)]


def _sha256_schedule(block):
    """The 64-word schedule of FIPS 180-4 section 6.2.2: the two little sigma
    functions are two rotates and a shift, so no multiply appears."""
    words = [int.from_bytes(block[4 * i:4 * i + 4], 'big') for i in range(16)]
    for t in range(16, 64):
        left = words[t - 15]
        right = words[t - 2]
        s0 = rr32(left, 7) ^ rr32(left, 18) ^ (left >> 3)
        s1 = rr32(right, 17) ^ rr32(right, 19) ^ (right >> 10)
        words.append((words[t - 16] + s0 + words[t - 7] + s1) & MASK)
    return words


def _sha256_core(message):
    """SHA-256 of `message` with one compression round per accepted beat of the
    core.  Block 0 opens with the IV restart beat; every later block is installed
    word by word by eight slot-load beats, and the caller does the add-back the
    standard puts at the end of a block because the core keeps no second window."""
    hash_words = list(SHA256_IV)
    state = 0
    for block_index, block in enumerate(_sha256_blocks(message)):
        schedule = _sha256_schedule(block)
        if block_index:
            for slot in range(8):
                _r, _x, f, state = step('sha256_round', hash_words[slot], 0,
                                        (1 << 31) | (1 << 30) | slot, state)
                assert f == 0
            restart = 0
        else:
            restart = 1 << 31
        for t in range(64):
            _r, _x, f, state = step('sha256_round', schedule[t], SHA256_K[t],
                                    (restart if t == 0 else 0) | t, state)
            assert f == 0
        out = [(state >> (32 * j)) & MASK for j in range(8)]
        hash_words = [(out[j] + hash_words[j]) & MASK for j in range(8)]
    return ''.join('%08x' % v for v in hash_words)
