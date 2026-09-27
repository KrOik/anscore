"""FEC decoder datapaths: the parallel reduction a serial core cannot pipeline.
Ten enabled-ready-valid accelerator cores for forward-error-correction engines.
Every one of them is a *decoder building block* whose FPGA value is the width of
the reduction it closes in a single enabled beat: eight check-node messages
min-reduced with a sign tree, sixteen Viterbi add-compare-select units plus a
16-wide normalisation tree, four log-MAP branch updates, a 20-row GF(2) parity
XOR tree with a 31-way single-error locator compare, a 32-chip puncturing
crossbar, four SECDED(8,4) lanes, a Reed-Solomon syndrome fold and a convex
interleave address network.

Two specifications per core, deliberately written as different algorithms:
    * `step()` -- exact Python integer semantics, and
    * `body`   -- the Verilog combinational kernel emitted by generate_lib.
The generated testbench compares the hardware against vectors that only the
Python model produced, and selftest() attacks the model from a third direction:
exhaustive brute force over small codes (all 2048 BCH(31,11) codewords, all 256
single-byte GF(256) products, all 8 Hamming(7,4) corrections and all 28
double-error patterns, every (state, input) trellis edge), published code
properties (zero syndrome of a clean codeword, uniqueness of single-error
syndromes, distance 3/4/7 coverage, the max-log versus linear-domain identity)
and independent reference decoders (exhaustive MLSE over all input sequences of
a short trellis, a plain recursive depuncturer, a linear-domain BCJR sum).

Field arithmetic rules used throughout:
    GF(2^8) is built on the published primitive polynomial x^8+x^4+x^3+x^2+1 =
    0x11D, so alpha = 2 is a field element whose doubling is xtime(v) =
    (v<<1) ^ (v[7] ? 0x1D : 0). GF(2^5) is built on x^5+x^2+1 = 0x25. Both are
    *derived* below and their properties (element order, table bijectivity) are
    asserted in selftest(), never assumed from a comment.

No core contains a `*` or a `/`: GF products are xtime shift-xor walks or
generated log/antilog ROM images, and every rank, popcount, min or max is an
unrolled fabric tree. Every core is one combinational cone behind one register
stage: latency 1 enabled edge, II 1, 256-bit state, restart convention c[31]=1.

Template body vocabulary (re-initialised on every evaluation):
    r x f temp mask pa pb pc ph pl ext wide wide2 swide swide2 sa sb sc data
    i j idx lane sh state_r state_n
Anything in `decl` is module scope and is NOT re-initialised, so every module-scope
reg declared here is assigned at the top of its own kernel body on every path.
"""
from random import Random

FAMILY = 'fec'
MASK = (1 << 32) - 1
BOARD_ROWS = 128

CORES = []


def core(name, spec, body, advantage, lanes, decl='', stateful=False,
         faultless=False, rom=None):
    entry = dict(name=name, family=FAMILY, spec=spec, body=body, decl=decl,
                 advantage=advantage, lanes=lanes, stateful=stateful,
                 faultless=faultless)
    if rom is not None:
        entry['rom'] = rom
    CORES.append(entry)


def hexs(value, digits):
    return format(value, '0%dX' % digits)


# ---------------------------------------------------------------------------
# GF(2^8) on 0x11D and GF(2^5) on 0x25, both derived, never tabulated by hand.
# ---------------------------------------------------------------------------
POLY8 = 0x11D              # x^8 + x^4 + x^3 + x^2 + 1 (published RS/Flashcom field)
RED8 = POLY8 & 0xFF        # 0x1D, the byte XORed in when bit 7 carries out
POLY5 = 0x25               # x^5 + x^2 + 1 (published primitive polynomial for GF(32))


def xtime(value):
    """Multiply a GF(2^8) element by alpha = x, modulo 0x11D."""
    value <<= 1
    if value & 0x100:
        value ^= POLY8
    return value & 0xFF


def gf8_mul(left, right):
    """shift-xor product modulo 0x11D: the brute-force definition of the field."""
    product = 0
    for bit in range(8):
        if (right >> bit) & 1:
            product ^= left << bit
    for bit in range(15, 7, -1):
        if (product >> bit) & 1:
            product ^= POLY8 << (bit - 8)
    return product & 0xFF


def gf8_tables():
    """(log, antilog) for generator alpha = x of GF(2^8)/0x11D.

    antilog[i] = alpha^i for i = 0..254 and antilog[255] = antilog[0], log[x] is
    the discrete logarithm base alpha with log[0] undefined (reads 0).
    """
    antilog, value = [], 1
    for _ in range(255):
        antilog.append(value)
        value = xtime(value)
    antilog.append(antilog[0])
    log = [0] * 256
    for index in range(255):
        log[antilog[index]] = index
    return log, antilog


def gf8_pow(power):
    """alpha^k with any integer k folded into 0..254 (alpha has order 255)."""
    return gf8_tables()[1][power % 255]


def gf5_mul(left, right, poly=POLY5):
    product = 0
    for bit in range(5):
        if (right >> bit) & 1:
            product ^= left << bit
    for bit in range(8, 4, -1):
        if (product >> bit) & 1:
            product ^= poly << (bit - 5)
    return product & 0x1F


def gf5_beta_powers(poly=POLY5):
    """beta^0..beta^30 for beta = x in GF(32)/poly, verified to close at 31."""
    powers, value = [], 1
    for _ in range(31):
        powers.append(value)
        value = gf5_mul(value, 2, poly)
    return powers


# ---------------------------------------------------------------------------
# BCH(31,11,t=3) check space, derived from GF(32) conjugacy classes.
# ---------------------------------------------------------------------------
BCH_CLASSES = (1, 3, 5, 7)          # designed distance 8 -> roots beta^1..beta^7
BCH_N, BCH_K, BCH_PARITY = 31, 11, 20


def _bch_rows(powers):
    """The 20 x 31 binary parity-check matrix as row masks.

    Row (class index e, bit b) has coefficient bit b of beta^(class[e]*j) at
    codeword position j, so the b-th bit of the e-th GF(32) syndrome component is
    the GF(2) parity of the received word AND that mask.
    """
    rows = []
    for cls in BCH_CLASSES:
        for bit in range(5):
            mask = 0
            for j in range(BCH_N):
                if (powers[(cls * j) % 31] >> bit) & 1:
                    mask |= 1 << j
            rows.append(mask)
    return rows


def _bch_columns(powers):
    """The 31 single-error syndromes: column j of H expanded into 20 bits."""
    columns = []
    for j in range(BCH_N):
        value = 0
        for index, cls in enumerate(BCH_CLASSES):
            value |= powers[(cls * j) % 31] << (5 * index)
        columns.append(value)
    return columns


# ---------------------------------------------------------------------------
def bch_network_decl():
    """Module wires for the (31,11) check network, derived from GF(32)/x^5+x^2+1.

    The 20 check rows and the 31 single-error syndromes are packed into wide
    constant vectors with a 32-bit stride so the kernel can index them with a
    shift (no multiplier, no memory) and reduce each row with one XOR tree.
    """
    powers = gf5_beta_powers()
    rows = _bch_rows(powers)
    columns = _bch_columns(powers)
    rowall = ', '.join("32'h%08X" % mask for mask in reversed(rows))
    colall = ', '.join("32'h%08X" % value for value in reversed(columns))
    return """
reg [19:0] bch_syn;
reg [5:0] bch_pop, bch_wgt;
reg [4:0] bch_pos;
reg bch_any, bch_changed, bch_same;
reg [31:0] bch_cnt;
wire [30:0] bch_word = a[30:0];
wire bch_bad = (a[31] != 1'b0) || (c[29:0] != 29'd0);
wire [255:0] bch_base = c[31] ? 256'd0 : state_r;
wire [19:0] bch_acc = bch_base[19:0];
wire [30:0] bch_prevword = bch_base[62:32];
wire [31:0] bch_prevcnt = bch_base[95:64];
// 20 check rows of GF(32)/x^5+x^2+1, one 31-bit mask per syndrome bit, at a
// 32-bit stride; row index i = 5*(conjugacy class) + bit, matching the
// single-error column packing below.
wire [639:0] bch_rowall = {%s};
// the 20-bit syndrome of a single error at codeword position j, 31 of them,
// also at a 32-bit stride: the locator is 31 parallel comparators.
wire [991:0] bch_colall = {%s};
""" % (rowall, colall)


core('bch31_syndrome',
   'BCH(31,11) syndrome network (designed distance 8 from the roots beta^1..beta^7, '
   'exhaustive minimum weight 11, so t = 3 by the design bound): the whole 31-bit '
   'received block arrives in '
   'a[30:0] in one accepted beat (a[31] must be zero) and 20 independent GF(2) '
   'parity trees fire in parallel -- check row i is the AND of the block with a '
   'constant 31-bit mask reduced by one XOR tree -- giving the 20-bit syndrome '
   '(S_1,S_3,S_5,S_7) of GF(32)/x^5+x^2+1 = 0x25, derived from the conjugacy '
   'classes 1,3,5,7 and never tabulated by hand. The same construction yields '
   'the 31 single-error syndromes, compared against the computed syndrome by 31 '
   'parallel 20-bit comparators feeding one lowest-index priority pick, so the '
   'locator position is fabric rather than a loop. c[31]=1 restarts (the stored '
   'syndrome and the counters are cleared before this beat), c[30]=1 selects '
   'accumulate mode (this beat XORs into the stored syndrome, for stacked '
   'blocks) and c[29:0] must be zero. There is no multiply anywhere: 20 XOR '
   'trees over 31 inputs, 31 equality comparators and two popcount trees. '
   'result[19:0] = syndrome, result[20] = clean (syndrome zero), result[21] = '
   'the syndrome matches a single-error column (correctable), result[22] = '
   'nonzero syndrome matching no column (two or three errors, detected, not '
   'corrected here), result[23] = accumulate mode applied, result[31:24] = 0. '
   'aux[4:0] = located error position (0..30, 31 = none), aux[5] = a column '
   'matched, aux[6] = syndrome zero, aux[7] = detected but not located, aux[8] = '
   'accumulate applied, aux[9] = restart applied, aux[15:10] = syndrome popcount '
   '(0..20), aux[21:16] = popcount of the 31 received bits (0..31), aux[22] = '
   'the syndrome changed versus the stored one, aux[23] = this block equals the '
   'previous visit block (a stall watchdog), aux[31:24] = 0. '
   'State: state[19:0] = accumulated syndrome, state[31:20] = 0, state[63:32] = '
   'the received word of this visit (bit 63 always 0), state[95:64] = block '
   'counter (wrapping 32-bit), state[111:96] = 0, state[143:112] = the syndrome '
   'stored before this beat, state[255:144] = 0. A malformed beat returns '
   'result=aux=0, fault=1 and keeps state. Fault = malformed input, or a nonzero '
   'syndrome that no single-error column explains (an uncorrectable pattern).',
   """bch_syn=20'd0; bch_pop=6'd0; bch_wgt=6'd0; bch_pos=5'd31; bch_any=1'b0;
       bch_changed=1'b0; bch_same=1'b0; bch_cnt=32'd0;
       if(bch_bad) f = 1'b1;
       else begin
           for(i=0; i<20; i=i+1)
               bch_syn[i] = ^(bch_word & bch_rowall[(i << 5) +: 31]);
           if(c[30]) bch_syn = bch_syn ^ bch_acc;
           for(i=0; i<20; i=i+1) if(bch_syn[i]) bch_pop = bch_pop + 6'd1;
           for(i=0; i<31; i=i+1) if(bch_word[i]) bch_wgt = bch_wgt + 6'd1;
           for(i=0; i<31; i=i+1) begin
               if(!bch_any && (bch_syn == bch_colall[(i << 5) +: 20])) begin
                   bch_any = 1'b1;
                   bch_pos = i;
               end
           end
           bch_changed = (bch_syn != bch_acc);
           bch_same = (bch_word == bch_prevword);
           bch_cnt = bch_prevcnt + 32'd1;
           r = {8'd0, c[30], (bch_syn != 20'd0) && !bch_any, bch_any,
                (bch_syn == 20'd0), bch_syn};
           x = {8'd0, bch_same, bch_changed, bch_wgt, bch_pop, c[31], c[30],
                ((bch_syn != 20'd0) && !bch_any), (bch_syn == 20'd0), bch_any,
                bch_pos};
           state_n = {112'd0, {12'd0, bch_acc}, 16'd0, bch_cnt,
                      {1'b0, bch_word}, {12'd0, bch_syn}};
           f = ((bch_syn != 20'd0) && !bch_any);
       end""",
   'A software BCH decoder computes each of the 20 checks as a serial bit loop '
   'or a table walk over 31 positions; here all 20 XOR trees and all 31 locator '
   'comparators settle inside one enabled beat, so syndrome, correction position '
   'and the correctable/uncorrectable verdict arrive together at fixed latency.',
   20, decl=bch_network_decl(), stateful=True)

def poly_eval_image():
    """256 words, word i = (log[i] << 8) | antilog[i] for GF(2^8)/0x11D."""
    log, antilog = gf8_tables()
    return [(log[value] << 8) | antilog[value] for value in range(256)]


def puncture_image():
    """Four period-32 keep masks, word s = the chips surviving in stream s.

    The rules are the periodic ones the model states and the selftest re-derives:
      s=0 systematic : every chip except positions 7,15,23,31   (28 kept)
      s=1 parity 1   : chips with (j mod 4) != 3                (24 kept)
      s=2 parity 2   : chips with (j mod 8) < 4                 (16 kept)
      s=3            : deliberately empty, an illegal pattern that must fault.
    """
    words = []
    base = [(1 << 32) - 1]
    words.append(base[0] & ~(0x80 | 0x8000 | 0x800000 | 0x80000000))
    mask4 = 0
    for j in range(32):
        if j % 4 != 3:
            mask4 |= 1 << j
    words.append(mask4)
    mask8 = 0
    for j in range(32):
        if j % 8 < 4:
            mask8 |= 1 << j
    words.append(mask8)
    words.append(0)
    return words


_IMAGES = {}


def tables(name):
    if name not in _IMAGES:
        if name == 'gf256_poly_eval':
            _IMAGES[name] = {'pm16': poly_eval_image()}
        elif name == 'puncture_map_r13':
            _IMAGES[name] = {'pat': puncture_image()}
        else:
            _IMAGES[name] = {}
    return _IMAGES[name]


# ---------------------------------------------------------------------------
# 1  ldpc_cn_minsum : one 8-edge LDPC check node, min-sum
# ---------------------------------------------------------------------------
CN_DECL = """
reg [7:0] cn_mag1, cn_mag2;
reg [2:0] cn_arg;
reg [3:0] cn_tie, cn_zero;
reg [1:0] cn_dir;
reg [15:0] cn_cnt;
reg cn_par, cn_sat, cn_hist;
wire [3:0] cn_beta = c[3:0];
wire cn_bad = (c[30:4] != 27'd0);
wire [255:0] cn_base = c[31] ? 256'd0 : state_r;
wire cn_hist0 = cn_base[192];
wire [7:0] cn_prevmin = cn_base[135:128];
wire [15:0] cn_prevcnt = cn_base[175:160];
"""

core('ldpc_cn_minsum',
   'One degree-8 LDPC check node, min-sum, in one accepted beat: the eight '
   'signed 8-bit LLR messages arrive as m0=a[7:0], m1=a[15:8], m2=a[23:16], '
   'm3=a[31:24], m4=b[7:0] ... m7=b[31:24]. c[3:0] is the min-sum offset beta '
   '(0..15) subtracted from every magnitude and floored at zero, c[31] is the '
   'restart (the state is cleared before this beat), and c[30:4] must be zero. '
   'Per message: sign s_k = m_k[7], magnitude g_k = |m_k| with the int8 floor '
   '-128 saturating to 127 and raising fault, then g_k = max(g_k - beta, 0). '
   'mag1/mag2 are the two smallest g_k (mag2 counted with multiplicity, so a tie '
   'gives mag1 == mag2), argmin is the lowest index achieving mag1, tiecnt counts '
   'how many do, zerocnt counts g_k == 0, parity is the XOR of the eight signs. '
   'The exclude-min message magnitude for edge k is mag2 when k == argmin and '
   'mag1 otherwise, and its sign is parity ^ s_k, so result+aux carry the whole '
   '8-message outgoing vector without a single multiply. '
   'result[7:0]=mag1, result[15:8]=mag2, result[23:16]=input sign mask, '
   'result[24]=parity, result[25]=magnitude saturation applied, result[31:26]=0. '
   'aux[7:0]=min2 select mask (1<<argmin), aux[15:8]=output sign mask, aux[16]='
   'parity, aux[19:17]=argmin, aux[23:20]=tie count (1..8), aux[24]=this was the '
   'first visit of the node, aux[26:25]=mag1 trend versus the previous visit '
   '(00 equal, 01 decreased, 10 increased, 11 no history), aux[27]=history valid '
   'before this beat, aux[31:28]=zero-magnitude count (0..8). '
   'State (only accepted beats): w0=previous a, w1=previous b, w2:w3=the eight '
   'signed outgoing messages of the previous visit (byte k = edge k), w4=previous '
   'visit summary (mag1, mag2, sign mask, parity, sat), w5=visit counter '
   '(saturating at 65535, which raises fault), w6=history valid, w7=0. A '
   'malformed beat (c[30:4] != 0) returns result=aux=0, fault=1 and keeps state.',
   """cn_mag1=255; cn_mag2=255; cn_arg=3'd0; cn_tie=4'd0; cn_zero=4'd0;
       cn_dir=2'b00; cn_cnt=16'd0; cn_par=1'b0; cn_sat=1'b0; cn_hist=1'b0;
       wide=0; wide2=0; pa=0; ph=0;
       if(cn_bad) f = 1'b1;
       else begin
           for(i=0; i<8; i=i+1) begin
               idx = (i < 4) ? (i + 8) : i;
               temp = data[(idx << 3) +: 8];
               if(temp[7]) pa = pa | (32'h1 << i);
               pl = temp[7] ? (32'h100 - temp) : temp;
               if(pl == 128) cn_sat = 1'b1;
               if(pl > 127) pl = 127;
               if(pl > cn_beta) pl = pl - cn_beta;
               else pl = 32'd0;
               wide[(i << 3) +: 8] = pl[7:0];
           end
           for(i=0; i<8; i=i+1) begin
               pc = wide[(i << 3) +: 8];
               if(pc < {24'd0, cn_mag1}) begin
                   cn_mag2 = cn_mag1;
                   cn_mag1 = pc[7:0];
                   cn_arg = i[2:0];
               end
               else if(pc < {24'd0, cn_mag2}) cn_mag2 = pc[7:0];
           end
           for(i=0; i<8; i=i+1) begin
               pc = wide[(i << 3) +: 8];
               if(pc == {24'd0, cn_mag1}) cn_tie = cn_tie + 4'd1;
               if(pc == 32'd0) cn_zero = cn_zero + 4'd1;
           end
           cn_par = ^pa;
           cn_hist = cn_hist0;
           if(!cn_hist0) cn_dir = 2'b11;
           else if(cn_mag1 == cn_prevmin) cn_dir = 2'b00;
           else if(cn_mag1 < cn_prevmin) cn_dir = 2'b01;
           else cn_dir = 2'b10;
           for(i=0; i<8; i=i+1) begin
               pc = (i == cn_arg) ? cn_mag2 : cn_mag1;
               pl = (((pa >> i) & 32'h1) ^ cn_par) & 32'h1;
               if(pl) begin
                   ph = ph | (32'h1 << i);
                   mask = (32'h100 - pc) & 32'hff;
               end
               else mask = pc;
               wide2[(i << 3) +: 8] = mask[7:0];
           end
           cn_cnt = (cn_prevcnt == 16'hffff) ? 16'hffff : (cn_prevcnt + 16'd1);
           r = {6'd0, cn_sat, cn_par, pa[7:0], cn_mag2, cn_mag1};
           x = {cn_zero, cn_hist, cn_dir, (!cn_hist0), cn_tie, cn_arg, cn_par,
                ph[7:0], ((8'h1 << cn_arg) & 8'hff)};
           state_n = {32'd0, 32'h1, {16'd0, cn_cnt}, r, wide2, b, a};
           f = cn_sat || (cn_prevcnt == 16'hffff);
       end""",
   'A min-sum check node is eight dependent sign tests, a two-minimum selection '
   'and eight exclude-min writes per edge; in LUTs the whole node is one 8-lane '
   'magnitude tree that closes in a single enabled beat and republishes the '
   'complete outgoing vector on result+aux, so one node per clock is reachable.',
   8, decl=CN_DECL, stateful=True)


# ---------------------------------------------------------------------------
# 2  ldpc_vn_update : four variable nodes, saturating posterior accumulation
# ---------------------------------------------------------------------------
VN_DECL = """
reg signed [31:0] vn_old, vn_msg, vn_sum;
reg [7:0] vn_byte;
reg [3:0] vn_clamp, vn_satm, vn_zero, vn_dec;
reg [3:0] vn_hard;
reg [15:0] vn_cnt;
reg vn_cntsat;
wire vn_bad = (c[30:0] != 30'd0);
wire [255:0] vn_base = c[31] ? 256'd0 : state_r;
wire [15:0] vn_prevcnt = vn_base[79:64];
wire vn_seeded = vn_base[81];
"""

core('ldpc_vn_update',
   'Variable-node update for four independent variable nodes per accepted beat. '
   'Lane k receives one signed 8-bit check-to-variable message m_k = a[8k+7:8k]; '
   'the 16-bit signed posterior P_k held in state[16k+15:16k] is replaced by '
   'sat16(P_k + m_k), where sat16 clamps to [-32768,32767] and any clamp that '
   'bites raises fault. c[31]=1 is the seed/restart beat: the whole state is '
   'cleared first and each lane starts from the channel LLR L_k = b[8k+7:8k] '
   'instead of the stored posterior, so the posterior after a seed beat is '
   'sat16(L_k + m_k) and after d further beats it is the channel LLR plus the d '
   'incoming messages (the degree-(d+1) closed form). c[30:0] must be zero. '
   'result[8k+7:8k] = P_k clamped to the symmetric signed range [-127,127] '
   '(0x7F / 0x81), which is the LLR re-published to the check network; the '
   'unclamped value stays in state. '
   'aux[3:0]=8-bit clamp applied per lane, aux[7:4]=16-bit saturation applied per '
   'lane, aux[11:8]=posterior exactly zero per lane (an erasure the decoder must '
   'not decide), aux[15:12]=|P_k| got smaller than it was for that lane, '
   'aux[19:16]=hard decision per lane (1 when P_k > 0), aux[23:20]=posterior '
   'nonzero per lane, aux[24]=this beat was a seed beat, aux[25]=no seed beat '
   'has ever been applied before this beat (the prior is the uninformative '
   'zero), aux[26]=the message counter has saturated, aux[27]=all four '
   'posteriors are positive, aux[31:28]=messages accumulated since the last '
   'seed (low nibble). '
   'State: state[63:0] = the four signed 16-bit posteriors (lane k at 16k), '
   'state[79:64] = messages accumulated (saturating at 65535, which raises '
   'fault), state[80] = count-saturation latch, state[81] = seeded latch, '
   'state[95:82] = 0, state[127:96] = the previous beat a, state[159:128] = the '
   'previous result, state[255:160] = 0. A malformed beat returns '
   'result=aux=0, fault=1 and leaves state untouched.',
   """vn_old=32'sd0; vn_msg=32'sd0; vn_sum=32'sd0; vn_byte=8'd0;
       vn_clamp=4'd0; vn_satm=4'd0; vn_zero=4'd0; vn_dec=4'd0; vn_hard=4'd0;
       vn_cnt=16'd0; vn_cntsat=1'b0;
       if(vn_bad) f = 1'b1;
       else begin
           state_n = vn_base;
           for(lane=0; lane<4; lane=lane+1) begin
               sh = lane << 3;
               vn_byte = a[sh +: 8];
               vn_msg = $signed({{24{vn_byte[7]}}, vn_byte});
               if(c[31]) begin
                   vn_byte = b[sh +: 8];
                   vn_old = $signed({{24{vn_byte[7]}}, vn_byte});
               end
               else vn_old = $signed({{16{vn_base[(lane << 4) + 15]}},
                                      vn_base[(lane << 4) +: 16]});
               vn_sum = vn_old + vn_msg;
               if(vn_sum > 32'sd32767) begin
                   vn_sum = 32'sd32767;
                   vn_satm = vn_satm | (4'b1 << lane);
               end
               else if(vn_sum < -32'sd32768) begin
                   vn_sum = -32'sd32768;
                   vn_satm = vn_satm | (4'b1 << lane);
               end
               if(vn_sum > 0) vn_hard = vn_hard | (4'b1 << lane);
               if(vn_sum == 0) vn_zero = vn_zero | (4'b1 << lane);
               pl = vn_sum[31] ? ($unsigned(32'd0) - $unsigned(vn_sum))
                               : $unsigned(vn_sum);
               pc = vn_old[31] ? ($unsigned(32'd0) - $unsigned(vn_old))
                               : $unsigned(vn_old);
               if(pl < pc) vn_dec = vn_dec | (4'b1 << lane);
               vn_byte = 8'h7f;
               if(vn_sum > 32'sd127) begin
                   vn_byte = 8'h7f;
                   vn_clamp = vn_clamp | (4'b1 << lane);
               end
               else if(vn_sum < -32'sd127) begin
                   vn_byte = 8'h81;
                   vn_clamp = vn_clamp | (4'b1 << lane);
               end
               else vn_byte = vn_sum[7:0];
               r = r | ({24'd0, vn_byte} << sh);
               state_n[(lane << 4) +: 16] = vn_sum[15:0];
           end
           vn_cnt = (vn_prevcnt == 16'hffff) ? 16'hffff
                                             : (vn_prevcnt + 16'd4);
           vn_cntsat = vn_base[80] || (vn_prevcnt == 16'hffff);
           x = {vn_cnt[3:0], (vn_hard == 4'b1111), vn_cntsat,
                (!vn_seeded && !c[31]), c[31], (~vn_zero), vn_hard, vn_dec,
                vn_zero, vn_satm, vn_clamp};
           state_n[95:64] = {14'd0, (vn_seeded || c[31]), vn_cntsat, vn_cnt};
           state_n[127:96] = a;
           state_n[159:128] = r;
           f = (|vn_satm) || (vn_prevcnt == 16'hffff);
       end""",
   'Four posteriors, their saturating adds, the 8-bit output clamp, the zero-'
   'erasure test and the magnitude-trend watchdog all resolve in one enabled '
   'beat; a serial decoder pays a load, an add, two compares and a store per '
   'variable node, so it cannot keep a wide LDPC row of nodes at II=1.',
   4, decl=VN_DECL, stateful=True)


# ---------------------------------------------------------------------------
# 3  rs255_syndrome_acc : Reed-Solomon GF(256) syndrome fold, 4 symbols a beat
# ---------------------------------------------------------------------------
RS_DECL = """
reg [31:0] rs_sy, rs_prevblk;
reg [3:0] rs_nz, rs_mask;
reg [15:0] rs_cnt;
reg rs_sticky, rs_partial, rs_clean;
wire [2:0] rs_count = b[2:0];
wire rs_bad = (b[31:3] != 29'd0) || (rs_count > 3'd4) || (c[30:0] != 30'd0);
wire [255:0] rs_base = c[31] ? 256'd0 : state_r;
wire [31:0] rs_old = rs_base[31:0];
wire [15:0] rs_prevcnt = rs_base[47:32];
wire rs_sticky0 = rs_base[48];
wire [31:0] rs_lastblk = c[31] ? state_r[31:0] : rs_base[127:96];
"""


def rs_decl():
    """xtime is the only field arithmetic the kernel needs: no product, no ROM."""
    return ("""
function [7:0] rs_xt;                    // multiply by alpha = x, mod 0x11D
    input [7:0] v;
    begin
        rs_xt = {v[6:0], 1'b0} ^ (v[7] ? 8'h1D : 8'h00);
    end
endfunction
""" + RS_DECL)


core('rs255_syndrome_acc',
   'Reed-Solomon syndrome accumulator over GF(256) with the published primitive '
   'polynomial x^8+x^4+x^3+x^2+1 = 0x11D and alpha = x. Four symbols per '
   'accepted beat, in stream order sym0=a[7:0] ... sym3=a[31:24], and b[2:0] '
   'says how many of them are live (0..4, for shortened blocks and tail '
   'chunks); b[31:3] must be zero. For each live symbol and each syndrome '
   'register i = 0..3 the fold is S_i <- mul(S_i, alpha^i) ^ sym, so after N '
   'symbols S_i = sum_k sym_k * alpha^(i*(N-1-k)), i.e. the received polynomial '
   'evaluated at alpha^i with the first-fed symbol as the highest power. Every '
   'field multiply is an unrolled xtime walk (0, 1, 2 and 3 doublings for '
   'i = 0,1,2,3), so the core contains no product and no ROM. c[31]=1 clears all '
   'four syndrome registers and the counters before folding this beat, and the '
   'block syndromes it replaces are kept for block-to-block comparison; c[30:0] '
   'must be zero. t=2: four syndromes correct two symbol errors and detect '
   'three, and S_0 is the whole-block XOR. '
   'result[8i+7:8i] = S_i. aux[3:0] = per-syndrome nonzero flags, aux[6:4] = '
   'count of nonzero syndromes (0..4), aux[7] = all syndromes zero (clean so '
   'far), aux[8] = a nonzero syndrome has ever appeared in this block (sticky), '
   'aux[9] = restart applied, aux[10] = the syndromes saved at the last restart boundary were all zero, aux[11] = '
   'this beat was partial (fewer than four symbols), aux[12] = the symbol count '
   'saturated, aux[15:13] = 0, aux[31:16] = symbols folded since the last '
   'restart (saturating at 65535, which raises fault). '
   'State: state[31:0] = the four syndrome bytes, state[47:32] = symbol count, '
   'state[48] = sticky-error latch, state[63:49] = 0, state[95:64] = the four '
   'symbols of this beat, state[127:96] = the syndrome bytes at the last '
   'restart boundary, state[255:128] = 0. A malformed beat returns '
   'result=aux=0, fault=1 and leaves state untouched.',
   """rs_sy=32'd0; rs_prevblk=32'd0; rs_nz=4'd0; rs_mask=4'd0; rs_cnt=16'd0;
       rs_sticky=1'b0; rs_partial=1'b0; rs_clean=1'b0;
       if(rs_bad) f = 1'b1;
       else begin
           rs_sy = rs_old;
           for(j=0; j<4; j=j+1) begin
               if(j < rs_count) begin
                   idx = (j + 8) << 3;
                   temp = data[idx +: 8];
                   for(i=0; i<4; i=i+1) begin
                       ph = rs_sy[(i << 3) +: 8];
                       for(lane=0; lane<i; lane=lane+1) ph = rs_xt(ph);
                       rs_sy[(i << 3) +: 8] = ph ^ temp;
                   end
               end
           end
           for(i=0; i<4; i=i+1) begin
               mask = rs_sy[(i << 3) +: 8];
               if(mask != 32'd0) begin
                   rs_mask = rs_mask | (4'b1 << i);
                   rs_nz = rs_nz + 4'd1;
               end
           end
           rs_cnt = (rs_prevcnt == 16'hffff) ? 16'hffff
                    : (rs_prevcnt + {13'd0, rs_count});
           rs_sticky = rs_sticky0 || (rs_mask != 4'd0);
           rs_clean = (rs_sy == 32'd0);
           r = rs_sy;
           x = 32'd0;
           x[3:0] = rs_mask;
           x[6:4] = rs_nz;
           x[7] = rs_clean;
           x[8] = rs_sticky;
           x[9] = c[31];
           x[10] = (rs_lastblk == 32'd0);
           x[11] = (rs_count < 3'd4);
           x[12] = (rs_prevcnt == 16'hffff);
           x[15:13] = 3'd0;
           x[31:16] = rs_cnt;
           state_n = {128'd0, rs_lastblk, a,
                      {15'd0, rs_sticky, rs_cnt}, rs_sy};
           f = (rs_prevcnt == 16'hffff);
       end""",
   'Four syndrome registers fold four symbols per enabled beat: 24 xtime '
   'doublings, 16 XORs and the whole Horner step retire in one LUT cone, which '
   'is the symbol rate a storage controller or DVB receiver needs and far more '
   'than a bit-serial software fold that costs a loop per symbol per syndrome.',
   4, decl=rs_decl(), stateful=True)


# ---------------------------------------------------------------------------
# 4  gf256_poly_eval : Horner over GF(256) from a generated log/antilog ROM
# ---------------------------------------------------------------------------
PE_DECL = """
reg [7:0] pe_pv, pe_prod, pe_la;
reg [8:0] pe_sm;
reg [31:0] pe_stg;
reg [23:0] pe_cnt;
reg pe_zeroed, pe_sticky;
wire [7:0] pe_k = c[7:0];
wire pe_bad = (pe_k == 8'd255) || (c[30:8] != 23'd0);
wire [255:0] pe_base = c[31] ? 256'd0 : state_r;
wire [23:0] pe_prevcnt = pe_base[31:8];
wire [31:0] pe_prevpv = pe_base[127:96];
"""

core('gf256_poly_eval',
   'Horner evaluation of a polynomial over GF(256) (x^8+x^4+x^3+x^2+1 = 0x11D, '
   'generator alpha = x) at the point x = alpha^k, four 8-bit coefficients per '
   'accepted beat. c[7:0] = k, the discrete logarithm of the evaluation point, '
   'and k = 255 is out of range; c[31]=1 restarts the evaluation (accumulator '
   'and coefficient count cleared before this beat); c[30:8] must be zero. The '
   'coefficients are consumed in Horner order, highest degree next: '
   'c0=a[7:0], c1=a[15:8], c2=a[23:16], c3=a[31:24], and each step is '
   'p <- mul(p, alpha^k) ^ c_j, with mul taken from one generated 256-word ROM '
   'image (word i = (log[i] << 8) | antilog[i], file line 0 = index 0) so a '
   'product is log read + one conditional subtract of 255 + antilog read, and a '
   'zero accumulator short-circuits to zero because log[0] is undefined. Four '
   'steps retire per beat. '
   'result[7:0] = p after all four steps, result[15:8] = after three, '
   'result[23:16] = after two, result[31:24] = after one (the whole unrolled '
   'Horner chain is observable). aux[7:0] = the accumulator as it entered this '
   'beat, aux[15:8] = k echoed, aux[16] = restart applied, aux[17] = at least '
   'one step multiplied a zero accumulator, aux[18] = a coefficient was folded '
   'into the same value the previous beat produced, aux[19] = coefficient count '
   'saturated, aux[31:20] = coefficients consumed since the restart (saturating '
   'at 2^24-1, which raises fault). '
   'State: state[7:0] = running value p, state[31:8] = coefficient count, '
   'state[63:32] = the four coefficients of this beat, state[95:64] = the four '
   'coefficients of the previous beat, state[127:96] = the accumulator as it '
   'entered this beat, state[128] = started latch, state[129] = '
   'count-saturation latch, '
   'state[255:130] = 0. A malformed beat returns result=aux=0, fault=1 and keeps '
   'state.',
   """pe_pv=8'd0; pe_prod=8'd0; pe_la=8'd0; pe_sm=9'd0; pe_stg=32'd0;
       pe_cnt=24'd0; pe_zeroed=1'b0; pe_sticky=1'b0;
       if(pe_bad) f = 1'b1;
       else begin
           pe_pv = pe_base[7:0];
           for(j=0; j<4; j=j+1) begin
               if(pe_pv == 8'd0) begin
                   pe_prod = 8'd0;
                   pe_zeroed = 1'b1;
               end
               else begin
                   pe_la = pemap[pe_pv & 8'hff] >> 8;
                   pe_sm = pe_la + pe_k;
                   if(pe_sm >= 255) pe_sm = pe_sm - 255;
                   pe_prod = pemap[pe_sm[7:0]] & 8'hff;
               end
               idx = (j + 8) << 3;
               pe_pv = pe_prod ^ data[idx +: 8];
               pe_stg[((3 - j) << 3) +: 8] = pe_pv;
           end
           pe_cnt = (pe_prevcnt == 24'hffffff) ? 24'hffffff
                    : (pe_prevcnt + 24'd4);
           r = pe_stg;
           x = {pe_cnt[11:0], (pe_prevcnt == 24'hffffff),
                (pe_prevpv == pe_stg[31:24]), pe_zeroed, c[31], pe_k,
                pe_base[7:0]};
           state_n = {126'd0, (pe_base[129] || (pe_prevcnt == 24'hffffff)),
                      1'b1, {24'd0, pe_base[7:0]}, pe_base[63:32], a,
                      pe_cnt, pe_stg[7:0]};
           f = (pe_prevcnt == 24'hffffff);
       end""",
   'A GF(256) Horner step in software is a log lookup, a modular add and an '
   'antilog lookup per coefficient with a branch on the zero case; here four '
   'steps unroll into eight ROM reads off one fabric-LUT image plus two '
   'conditional subtracts and retire a whole quartet of coefficients every '
   'enabled beat.',
   4, decl=PE_DECL, stateful=True,
   rom={'name': 'pemap', 'suffix': 'pm16', 'width': 16})


# ---------------------------------------------------------------------------
# 6  convk7_acs16 : sixteen Viterbi add-compare-select units + norm tree
# ---------------------------------------------------------------------------
ACS_DECL = """
// The kernel sign-extends a branch-metric byte held in the 32-bit template
// temporaries temp/mask. Those registers keep the zero-extended byte, so the
// sign fill must cover only the byte itself ({{24{temp[7]}}, temp[7:0]} = 32
// bits); filling over the whole register makes a 56-bit vector and turns every
// negative delta into about -2^32, which saturates every candidate to zero.
reg [7:0] acs_m0, acs_m1, acs_c0, acs_c1, acs_best, acs_min, acs_max, acs_tmp;
reg [15:0] acs_surv, acs_cnt;
reg [3:0] acs_minlanes;
reg [7:0] acs_inc;
reg acs_tie, acs_clamp;
reg [127:0] acs_ns;
wire acs_bad = (c[29:0] != 30'd0);
wire [255:0] acs_base = c[31] ? 256'd0 : state_r;
wire [127:0] acs_metrics = acs_base[127:0];
wire [15:0] acs_prevcnt = acs_base[159:144];
wire acs_hist0 = acs_base[192];
"""

core('convk7_acs16',
   'Sixteen Viterbi add-compare-select units for the K=7 (rate 1/2) constraint '
   'length, one whole survivor update per accepted beat. The 64-state trellis is '
   'walked as four consecutive visits to this 16-wide stage, which is why the '
   'survivor metrics live in state and nothing is reinitialised between visits. '
   'Unit j (j = 0..15) combines predecessor metrics m[j>>1] and m[(j>>1)+8] with '
   'one branch metric each: the metric bank for the input-bit-0 edges is '
   'A0=a[7:0] A1=a[15:8] A2=a[23:16] A3=a[31:24] and for input-bit-1 edges '
   'B0..B3 from b, both as signed 8-bit log-likelihood deltas, selected by '
   'j&3. Candidates are sat_u8(metric + delta) clamped to [0,255]; the larger '
   'candidate wins (ties go to the lower predecessor and raise the tie flag), '
   'and the 16 winners are then normalised in parallel by subtracting their '
   'minimum, so the best survivor is always 0 and no metric can drift out of '
   'range. c[31]=1 restarts the trellis (all metrics and counters cleared before '
   'this beat), c[30]=1 bypasses the normalisation tree (metrics then drift and '
   'the saturating adders start biting), and c[29:0] must be zero. No multiply: '
   '32 saturating adders, 16 comparators, one 16-wide min tree and 16 subtractors. '
   'result[7:0] = the winner minimum before normalisation, result[15:8] = the '
   'winner maximum, result[23:16] = spread (max - min), result[24] = normalise '
   'mode applied (c[30] low), result[25] = at least one candidate saturated, '
   'result[26] = at least one unit tied, result[31:27] = 0. '
   'aux[7:0] = survivor bits for units 0..7 (1 = the +8 predecessor won), '
   'aux[15:8] = survivor bits for units 8..15, aux[16] = restart applied, '
   'aux[17] = this was the first visit since the restart, aux[18] = spread '
   'exceeds 127 (range pressure on the 8-bit metric), aux[19] = the visit '
   'counter has saturated, aux[23:20] = number of units achieving the minimum '
   '(saturating at 15), aux[31:24] = number of survivors that increased versus '
   'the previous visit (0..16). '
   'State: state[127:0] = the 16 normalised survivor metrics, state[143:128] = '
   'the survivor selection bits, state[159:144] = visit counter since the last '
   'restart (saturating at 65535, which raises fault), state[191:160] = the '
   'previous result, state[192] = started latch, state[255:193] = 0. A malformed '
   'beat returns result=aux=0, fault=1 and keeps state. Fault = malformed '
   'control, a saturating candidate, or a saturated visit counter.',
   """acs_m0=8'd0; acs_m1=8'd0; acs_c0=8'd0; acs_c1=8'd0; acs_best=8'd0;
       acs_min=8'd255; acs_max=8'd0; acs_tmp=8'd0; acs_surv=16'd0; acs_cnt=16'd0;
       acs_minlanes=4'd0; acs_inc=8'd0; acs_tie=1'b0; acs_clamp=1'b0;
       acs_ns=128'd0; wide=0; wide2=0;
       if(acs_bad) f = 1'b1;
       else begin
           for(j=0; j<16; j=j+1) begin
               idx = (j >> 1) << 3;
               acs_m0 = acs_metrics[idx +: 8];
               idx = ((j >> 1) + 8) << 3;
               acs_m1 = acs_metrics[idx +: 8];
               sh = (j & 3) << 3;
               temp = a[sh +: 8];
               mask = b[sh +: 8];
               swide = $signed({{24{temp[7]}}, temp[7:0]}) + $signed({24'd0, acs_m0});
               if(swide < 64'sd0) begin acs_c0 = 8'd0; acs_clamp = 1'b1; end
               else if(swide > 64'sd255) begin acs_c0 = 8'd255; acs_clamp = 1'b1; end
               else acs_c0 = swide[7:0];
               swide2 = $signed({{24{mask[7]}}, mask[7:0]}) + $signed({24'd0, acs_m1});
               if(swide2 < 64'sd0) begin acs_c1 = 8'd0; acs_clamp = 1'b1; end
               else if(swide2 > 64'sd255) begin acs_c1 = 8'd255; acs_clamp = 1'b1; end
               else acs_c1 = swide2[7:0];
               if(acs_c1 > acs_c0) begin
                   acs_best = acs_c1;
                   acs_surv[j] = 1'b1;
               end
               else begin
                   acs_best = acs_c0;
                   if(acs_c0 == acs_c1) acs_tie = 1'b1;
               end
               if(j < 8) wide[(j << 3) +: 8] = acs_best;
               else wide2[((j - 8) << 3) +: 8] = acs_best;
               if(acs_best < acs_min) acs_min = acs_best;
               if(acs_best > acs_max) acs_max = acs_best;
           end
           for(j=0; j<16; j=j+1) begin
               if(j < 8) acs_best = wide[(j << 3) +: 8];
               else acs_best = wide2[((j - 8) << 3) +: 8];
               if(acs_best == acs_min && acs_minlanes != 4'd15)
                   acs_minlanes = acs_minlanes + 4'd1;
               if(c[30]) acs_tmp = acs_best;
               else acs_tmp = acs_best - acs_min;
               acs_ns[(j << 3) +: 8] = acs_tmp;
               if(acs_tmp > acs_metrics[(j << 3) +: 8] && acs_inc != 8'd16)
                   acs_inc = acs_inc + 8'd1;
           end
           acs_cnt = (acs_prevcnt == 16'hffff) ? 16'hffff
                                               : (acs_prevcnt + 16'd1);
           r = {5'd0, acs_tie, acs_clamp, (!c[30]), (acs_max - acs_min),
                acs_max, acs_min};
           x = {acs_inc, acs_minlanes, (acs_prevcnt == 16'hffff),
                ((acs_max - acs_min) > 8'd127), (!acs_hist0), c[31],
                acs_surv[15:8], acs_surv[7:0]};
           state_n = {63'd0, 1'b1, r, acs_cnt, acs_surv, acs_ns};
           f = acs_clamp || (acs_prevcnt == 16'hffff);
       end""",
   'A software ACS costs two loads, two adds, a compare, a store and a traceback '
   'write per state, and the normalisation pass is a second loop over all 16 '
   'survivors; here 32 saturating adders, 16 comparators and the 16-wide min '
   'tree close in one enabled beat, which is exactly the trellis step rate a '
   'Viterbi decoder needs to stay ahead of the symbol stream.',
   16, decl=ACS_DECL, stateful=True)


# ---------------------------------------------------------------------------
# 7  puncture_map_r13 : 32-chip puncturing / depuncturing crossbar
# ---------------------------------------------------------------------------
PU_DECL = """
reg [31:0] pu_out, pu_mask, pu_total, pu_beats, pu_emit;
reg pu_illegal, pu_first, pu_same;
reg [3:0] pu_skip;
wire [1:0] pu_sel = c[1:0];
wire pu_bad = (c[30:4] != 27'd0);
wire [255:0] pu_base = c[31] ? 256'd0 : state_r;
wire [31:0] pu_prevout = pu_base[31:0];
wire [31:0] pu_prevmask = pu_base[63:32];
wire [15:0] pu_prevbeats = pu_base[79:64];
wire [15:0] pu_prevtotal = pu_base[95:80];
"""

core('puncture_map_r13',
   '32-chip puncturing crossbar for the period-31 rate-1/3 convolutional '
   'matching pattern, in one accepted beat: the 32 chips of one codeword stream '
   'arrive as a[31:0] (chip j = a[j]) and the keep mask is one of four '
   'period-32 patterns read from a generated ROM image whose cells are computed '
   'from the published puncturing rules (stream 0 keeps every chip except '
   'positions 7, 15, 23 and 31; stream 1 keeps chips with j mod 4 != 3; stream 2 '
   'keeps chips with j mod 8 < 4; stream 3 is deliberately empty and illegal). '
   'c[1:0] selects the pattern, c[3]=1 selects depuncture (expansion: the '
   'compressed input is written back into the kept positions in order and every '
   'punctured position is filled with a zero chip = erasure), c[3]=0 selects '
   'puncture (compression: the kept chips are packed down in rank order), and '
   'c[30:4] must be zero. c[31]=1 restarts the running totals before this beat. '
   'The crossbar is one 32-deep rank-count chain feeding 32 variable shifts: '
   '32 rank increments, 32 conditional bit writes and no multiply and no memory '
   'beyond the 4-word pattern image. '
   'result[31:0] = the 32-chip output word (packed low in compression mode, '
   'position-aligned in expansion mode). '
   'aux[5:0] = chips emitted this beat (the kept count, 0..32), aux[6] = '
   'expansion (depuncture) mode applied, aux[7] = an empty (illegal) pattern was '
   'selected, aux[8] = restart applied, aux[9] = the first beat since the '
   'restart, aux[10] = this output word equals the previous beat output, aux[11] '
   '= this mask equals the previous beat mask, aux[15:12] = kept positions whose '
   'input chip is zero (erasures in expansion mode, saturating at 15), '
   'aux[23:16] = kept-chip total since restart (low byte of a saturating 16-bit '
   'sum), aux[31:24] = beats since restart (low byte). '
   'State: state[31:0] = previous output word, state[63:32] = previous keep mask, '
   'state[79:64] = beats since the last restart (saturating at 65535, which '
   'raises fault), state[95:80] = chips emitted since the last restart '
   '(saturating), state[127:96] = the previous beat input word, state[255:128] = '
   '0. A malformed beat returns result=aux=0, fault=1 and keeps state. Fault = '
   'malformed control, an empty pattern, or a saturated beat counter.',
   """pu_out=32'd0; pu_mask=32'd0; pu_total=32'd0; pu_beats=32'd0; pu_emit=32'd0;
       pu_illegal=1'b0; pu_first=1'b0; pu_same=1'b0; pu_skip=4'd0;
       if(pu_bad) f = 1'b1;
       else begin
           pu_mask = pat[pu_sel];
           pu_illegal = (pu_mask == 32'd0);
           sh = 0;
           for(i=0; i<32; i=i+1) begin
               if(pu_mask[i]) begin
                   if(!a[i] && pu_skip != 4'd15) pu_skip = pu_skip + 4'd1;
                   if(!c[3]) begin
                       if(a[i]) pu_out = pu_out | (32'h1 << sh);
                   end
                   else if(a[sh]) pu_out = pu_out | (32'h1 << i);
                   sh = sh + 1;
               end
           end
           pu_total = {27'd0, sh};
           if(pu_prevbeats == 16'hffff) pu_beats = 32'hffff;
           else pu_beats = pu_prevbeats + 32'd1;
           if(pu_prevtotal > 32'hffff - pu_total) pu_emit = 32'hffff;
           else pu_emit = pu_prevtotal + pu_total;
           pu_first = (pu_prevbeats == 16'd0);
           pu_same = (pu_out == pu_prevout);
           r = pu_out;
           x = {pu_beats[7:0], pu_emit[7:0], pu_skip, (pu_prevmask == pu_mask),
                pu_same, pu_first, c[31], pu_illegal, c[3], pu_total[5:0]};
           state_n = {128'd0, a, pu_emit[15:0], pu_beats[15:0], pu_mask, pu_out};
           f = pu_illegal || (pu_prevbeats == 16'hffff);
       end""",
   'A depuncturer in software is a nested loop with a running rank and a branch '
   'per chip; here all 32 rank tests, the rank-count chain and the 32 '
   'conditional bit writes settle in one enabled beat, so the crossbar runs at '
   'the chip rate with a fixed two-cycle-group latency that a turbo decoder can '
   'hide behind its interleaver.',
   32, decl=PU_DECL, stateful=True,
   rom={'name': 'pat', 'suffix': 'pat', 'width': 32})


# ---------------------------------------------------------------------------
# 8  turbo_alpha_step : four log-MAP forward state updates with a window tree
# ---------------------------------------------------------------------------
TA_DECL = """
reg signed [31:0] ta_sa, ta_sb, ta_cand, ta_other, ta_cur, ta_mx, ta_mn, ta_win;
reg [3:0] ta_sbit, ta_wbit, ta_tie, ta_clampc;
reg [15:0] ta_cnt;
reg ta_first;
wire ta_bad = (c[29:0] != 30'd0);
wire [255:0] ta_base = c[31] ? 256'd0 : state_r;
wire [3:0] ta_aprev = ta_base[35:32];
wire [3:0] ta_bprev = ta_base[39:36];
wire [15:0] ta_prevcnt = ta_base[111:96];
wire [31:0] ta_alpha = ta_base[31:0];
wire [31:0] ta_prevalpha = ta_base[87:56];
"""

core('turbo_alpha_step',
   'Four log-MAP forward state updates for a radix-2 turbo trellis, one whole '
   'trellis section per accepted beat. The four survivor metrics are signed '
   '8-bit values at state[31:0] (byte i = the log-likelihood of state i at the '
   'previous section); branch metrics for input bit 0 are A0..A3 = a[7:0] '
   'a[15:8] a[23:16] a[31:24] and for input bit 1 B0..B3 from b, all signed '
   '8-bit. State i has predecessors p0 = i>>1 (bit 0) and p1 = (i>>1)+2 (bit 1), '
   'and the update is the max-log operation '
   'cand = alpha[p] + branch_metric, taking the larger of the two candidates and '
   'recording which predecessor won. The four results are then window '
   'normalised by one parallel tree: if max-min > 64 the whole vector is shifted '
   'down by (max-min) - 64, else if max-min > 32 it is shifted down by the '
   'minimum, else it is left alone, which keeps the survivors inside the int8 '
   'range without a serialise-and-scan loop. Every candidate sum and every '
   'normalised value saturates to [-128,127] and each saturation is counted. '
   'c[31]=1 restarts the trellis (state cleared before this beat, so every '
   'survivor starts at the uninformative 0), c[30]=1 requests the winner metric '
   'instead of the survivor, and c[29:0] must be zero. No multiply: eight '
   'saturating adders, four comparators, one 4-wide max/min tree and four '
   'conditional subtractors. '
   'result[8i+7:8i] = survivor of state i after normalisation (c[30]=0) or the '
   'winning candidate of state i (c[30]=1). '
   'aux[3:0] = survivor predecessor bits (1 = the +2 predecessor won), aux[7:4] '
   '= winner predecessor bits from the previous beat, aux[8] = restart applied, '
   'aux[9] = first beat since the restart, aux[10] = at least one state tied, '
   'aux[11] = the normalisation tree subtracted something, aux[12] = the window '
   'exceeded 64, aux[13] = every survivor is negative (max < 0), aux[17:14] = '
   'saturation events counted this beat (saturating at 15), aux[23:18] = 0, '
   'aux[31:24] = window width (max - min) as an unsigned byte. '
   'State: state[31:0] = the four normalised survivors (byte i), state[35:32] = '
   'the four predecessor bits, state[39:36] = the four winner bits, '
   'state[55:40] = 0, state[87:56] = the four survivors as they entered this '
   'beat, state[95:88] = 0, state[111:96] = sections since the last restart '
   '(saturating at 65535, which raises fault), state[255:112] = 0. A malformed '
   'beat returns result=aux=0, fault=1 and keeps state. Fault = malformed '
   'control or a saturated section counter.',
   """ta_sa=32'sd0; ta_sb=32'sd0; ta_cand=32'sd0; ta_other=32'sd0; ta_cur=32'sd0;
       ta_mx=-32'sd129; ta_mn=32'sd128; ta_win=32'sd0;
       ta_sbit=4'd0; ta_wbit=4'd0; ta_tie=4'd0; ta_clampc=4'd0; ta_cnt=16'd0;
       ta_first=1'b0; wide=0; wide2=0;
       if(ta_bad) f = 1'b1;
       else begin
           for(i=0; i<4; i=i+1) begin
               idx = (i >> 1) << 3;
               ta_sa = $signed({{24{ta_alpha[idx + 7]}}, ta_alpha[idx +: 8]});
               idx = ((i >> 1) + 2) << 3;
               ta_sb = $signed({{24{ta_alpha[idx + 7]}}, ta_alpha[idx +: 8]});
               idx = i << 3;
               ta_cand = ta_sa + $signed({{24{a[idx + 7]}}, a[idx +: 8]});
               ta_other = ta_sb + $signed({{24{b[idx + 7]}}, b[idx +: 8]});
               if(ta_cand < -32'sd128 || ta_cand > 32'sd127 ||
                  ta_other < -32'sd128 || ta_other > 32'sd127) begin
                   if(ta_clampc != 4'd15) ta_clampc = ta_clampc + 4'd1;
               end
               if(ta_cand > 32'sd127) ta_cand = 32'sd127;
               if(ta_cand < -32'sd128) ta_cand = -32'sd128;
               if(ta_other > 32'sd127) ta_other = 32'sd127;
               if(ta_other < -32'sd128) ta_other = -32'sd128;
               if(ta_cand > ta_other) begin
                   ta_sbit[i] = 1'b0;
                   ta_cur = ta_cand;
               end
               else begin
                   ta_sbit[i] = 1'b1;
                   ta_cur = ta_other;
                   if(ta_cand == ta_other) ta_tie[i] = 1'b1;
               end
               wide[(i << 3) +: 8] = ta_cur[7:0];
               if(ta_cur > ta_mx) ta_mx = ta_cur;
               if(ta_cur < ta_mn) ta_mn = ta_cur;
               ta_wbit[i] = ta_aprev[i];
           end
           ta_win = ta_mx - ta_mn;
           for(i=0; i<4; i=i+1) begin
               idx = i << 3;
               ta_cur = $signed({{24{wide[idx + 7]}}, wide[idx +: 8]});
               if(ta_win > 32'sd64) begin
                   ta_cur = ta_cur - (ta_win - 32'sd64);
                   if(ta_cur > 32'sd127) ta_cur = 32'sd127;
                   if(ta_cur < -32'sd128) ta_cur = -32'sd128;
                   if(ta_clampc != 4'd15) ta_clampc = ta_clampc + 4'd1;
               end
               else if(ta_win > 32'sd32) ta_cur = ta_cur - ta_mn;
               wide2[(i << 3) +: 8] = ta_cur[7:0];
           end
           ta_cnt = (ta_prevcnt == 16'hffff) ? 16'hffff : (ta_prevcnt + 16'd1);
           ta_first = (ta_prevcnt == 16'd0);
           r = c[30] ? wide[31:0] : wide2[31:0];
           x = {ta_win[7:0], 6'd0, ta_clampc, (ta_mx < 32'sd0), (ta_win > 32'sd64),
                (ta_win > 32'sd32), (|ta_tie), ta_first, c[31],
                {ta_wbit, ta_sbit}};
           state_n = {144'd0, ta_cnt, 8'd0, ta_alpha, 16'd0,
                      {ta_wbit, ta_sbit}, wide2[31:0]};
           f = (ta_prevcnt == 16'hffff);
       end""",
   'A log-MAP state update in software is a branch per predecessor, a running '
   'max scan and a second normalisation pass over the state vector; here eight '
   'saturating adds, four comparators and the 4-wide window tree retire one '
   'trellis section every enabled beat at fixed latency, which is what keeps a '
   'turbo decoder inside its interleave-depth budget.',
   4, decl=TA_DECL, stateful=True)


# ---------------------------------------------------------------------------
# 9  hamming74_correct : four SECDED(8,4) lanes, syndrome XOR trees
# ---------------------------------------------------------------------------
H7_DECL = """
reg [7:0] h_w, h_flip;
reg [2:0] h_syn;
reg h_d1, h_d2, h_d3, h_d4, h_par, h_d7;
reg [3:0] h_zero, h_ded, h_corr, h_pf, h_nz, h_n, h_nib0;
reg [15:0] h_cnt, h_beats;
reg h_first, h_sameword;
wire h_bad = (b != 32'd0) || (c[29:0] != 30'd0);
wire [255:0] h_base = c[31] ? 256'd0 : state_r;
wire [15:0] h_prevcnt = h_base[79:64];
wire [15:0] h_prevbeats = h_base[95:80];
wire [31:0] h_preva = h_base[31:0];
"""

core('hamming74_correct',
   'Four independent SECDED(8,4) lanes -- extended Hamming code with the four '
   'published check equations of the standard (7,4) code plus one overall '
   'parity bit -- decoded in one accepted beat. Lane k reads the received byte '
   'w = a[8k+7:8k] in the standard bit order: w[0]=p1, w[1]=p2, w[2]=d1, '
   'w[3]=p3, w[4]=d2, w[5]=d3, w[6]=d4, w[7]=p0 (overall parity), with the '
   'published equations p1 = d1^d2^d4, p2 = d1^d3^d4, p3 = d2^d3^d4. Three '
   '3-input XOR trees give the syndrome s = {p3check, p2check, p1check} = the '
   'binary index of the failing bit, and p0 ^ ^(w[6:0]) decides between the four '
   'published cases (odd total parity with a nonzero syndrome is the single error '
   'the code corrects, even total parity with a nonzero syndrome is the double '
   'error it only detects): clean, single-error corrected by flipping bit s (one '
   'barrel-selected XOR gate, no loop), parity-bit-only corrected, and '
   'double-error detected but NOT corrected (fault raised, data left untouched). '
   'The output byte is the corrected codeword: bit 7 is re-paritied over bits '
   '6:0, so a single-error lane always leaves as a valid SECDED codeword and a '
   'double-error lane leaves its data untouched (the fault flag is what forbids '
   'the write-back). b must be zero (the encoder half of the lane is exercised '
   'by the selftest instead) and c[29:0] must be zero; c[31]=1 restarts '
   'the correction '
   'and beat counters before this beat. '
   'result[8k+7:8k] = {p0, d4, d3, d2, p3, d1, p2, p1} for lane k: the four data '
   'bits in their published positions, the two code parities that the syndrome '
   'did not contradict, and the repaired overall parity in bit 7. '
   'aux[3:0] = syndrome nonzero per lane, aux[7:4] = single-error correction '
   'applied per lane, aux[11:8] = double error detected per lane, aux[15:12] = '
   'syndrome zero per lane, aux[19:16] = parity bit repaired per lane, aux[20] = '
   'restart applied, aux[21] = first beat since the restart, aux[22] = the '
   'correction counter has saturated, aux[23] = at least one lane corrected, '
   'aux[27:24] = lanes corrected this beat (0..4), aux[31:28] = the four '
   'recovered data bits of lane 0 ({d4,d3,d2,d1}). '
   'State: state[31:0] = the previous beat a, state[63:32] = the previous '
   'result, state[79:64] = single-bit corrections since the last restart '
   '(saturating at 65535, which raises fault), state[95:80] = beats since the '
   'last restart (saturating), state[96] = started latch, state[255:97] = 0. '
   'A malformed beat returns result=aux=0, fault=1 and keeps state. Fault = '
   'malformed input, any double-error lane, or a saturated correction counter.',
   """h_w=8'd0; h_flip=8'd0; h_syn=3'd0; h_d1=1'b0; h_d2=1'b0; h_d3=1'b0;
       h_d4=1'b0; h_par=1'b0; h_d7=1'b0; h_zero=4'd0; h_ded=4'd0; h_corr=4'd0;
       h_pf=4'd0; h_nz=4'd0; h_n=4'd0; h_nib0=4'd0; h_cnt=16'd0; h_beats=16'd0;
       h_first=1'b0; h_sameword=1'b0;
       if(h_bad) f = 1'b1;
       else begin
           for(lane=0; lane<4; lane=lane+1) begin
               sh = lane << 3;
               h_w = a[sh +: 8];
               h_d1 = h_w[2]; h_d2 = h_w[4]; h_d3 = h_w[5]; h_d4 = h_w[6];
               h_par = ^h_w[6:0];
               h_d7 = h_w[7] ^ h_par;
               h_syn = {h_w[3] ^ h_d2 ^ h_d3 ^ h_d4,
                        h_w[1] ^ h_d1 ^ h_d3 ^ h_d4,
                        h_w[0] ^ h_d1 ^ h_d2 ^ h_d4};
               if(h_syn != 3'd0) begin
                   h_nz[lane] = 1'b1;
                   if(h_d7) begin
                       h_flip = 8'h1 << (h_syn - 3'd1);
                       h_w = h_w ^ h_flip;
                       h_corr[lane] = 1'b1;
                       if(h_n != 4'd4) h_n = h_n + 4'd1;
                   end
                   else h_ded[lane] = 1'b1;
               end
               else begin
                   h_zero[lane] = 1'b1;
                   if(h_d7) begin
                       h_pf[lane] = 1'b1;
                   end
               end
               h_w[7] = ^h_w[6:0];
               if(lane == 0) h_nib0 = {h_w[6], h_w[5], h_w[4], h_w[2]};
               r = r | ({24'd0, h_w} << sh);
           end
           if(h_prevcnt > 32'hffff - {28'd0, h_n}) h_cnt = 16'hffff;
           else h_cnt = h_prevcnt + {12'd0, h_n};
           h_beats = (h_prevbeats == 16'hffff) ? 16'hffff
                                               : (h_prevbeats + 16'd1);
           h_first = (h_prevbeats == 16'd0);
           h_sameword = (a == h_preva);
           x = {h_nib0, h_n, (|h_corr), (h_prevcnt == 16'hffff), h_first, c[31],
                h_pf, h_zero, h_ded, h_corr, h_nz};
           state_n = {159'd0, 1'b1, h_beats, h_cnt, r, a};
           f = (|h_ded) || (h_prevcnt == 16'hffff);
       end""",
   'A SECDED lane in software is three parity computations, a syndrome-to-bit '
   'table lookup and a conditional store; here four lanes each close three '
   '3-input XOR trees, an 8-way barrel bit-flip and a re-parity in one enabled '
   'beat, which is the per-beat memory-rank scrub rate an ECC memory controller '
   'needs, with clean/double-error verdicts bit-exact against software.',
   4, decl=H7_DECL, stateful=True)


# ---------------------------------------------------------------------------
# 10 interleave_convex : stride-skew convex interleave address network
# ---------------------------------------------------------------------------
IL_DECL = """
reg [255:0] il_block, il_clear;
reg [31:0] il_addr, il_sym, il_sum, il_gath;
reg [15:0] il_addrn, il_beats;
reg [3:0] il_base, il_stride, il_a0, il_a1, il_a2, il_a3, il_newbase;
reg il_illegal, il_first, il_dup, il_overlap, il_started;
wire [1:0] il_mode = c[1:0];
wire [3:0] il_ctrl = c[5:2];
wire il_bad = (c[29:6] != 24'd0) || (il_mode == 2'b11);
wire [255:0] il_sb = c[31] ? 256'd0 : state_r;
wire [15:0] il_prevbeats = il_sb[143:128];
wire [15:0] il_prevaddr = il_sb[159:144];
wire [31:0] il_preva = il_sb[191:160];
"""

core('interleave_convex',
   'Convex (stride-skew) interleave address network over a 16-slot symbol '
   'window, four symbols per accepted beat. The block lives in state[127:0] as '
   'sixteen 8-bit slots; lane j of this beat writes or reads slot '
   'a_j = (base + j*stride) mod 16 for j = 0..3, with base held in state and '
   'advanced by four every scatter or gather beat, and j*stride built from two '
   'conditional adds of stride and stride<<1 because the fabric $mul is not '
   'usable here. c[1:0] selects the mode: 0 = scatter the four symbols of '
   'a[31:0] (byte j = symbol j) into the permuted slots, 1 = gather the four '
   'permuted slots into result bytes 0..3 in lane order, 2 = block reset (the '
   'stored block is kept, no symbol is moved and only the counters advance), '
   '3 = malformed. c[5:2] = stride (0..15); stride 0 and stride 8 map two lanes '
   'onto one slot for every base, which is the illegal convex pattern and '
   'returns result=aux=0 with fault while still advancing the counters. c[29:6] '
   'must be zero and c[31]=1 clears the block and the counters before this beat. '
   'The whole cone is four add-and-mask address generators, one 128-bit masked '
   'write network and a six-comparator duplicate detector: no multiplier, no '
   'divider and no memory beyond the state register itself. '
   'result[7:0] = block slots 0..3 (mode 0), result = the four gathered symbols '
   'in lane order (mode 1), result = 0 (mode 2, or an illegal stride). '
   'aux[3:0] = base slot this beat, aux[7:4] = stride this beat, aux[8] = '
   'restart applied, aux[9] = illegal stride, aux[10] = first beat since the '
   'restart, aux[11] = the block has been written at least once, aux[12] = this '
   'stride makes consecutive beats overlap the same slots, aux[13] = two lanes '
   'of this beat address the same slot, aux[14] = gather mode, aux[15] = scatter '
   'mode, aux[23:16] = the previous beat lane-0 and lane-1 addresses, aux[31:24] '
   '= the sum of the four symbols touched this beat. '
   'State: state[127:0] = the sixteen interleave slots, state[143:128] = beats '
   'since the last restart (saturating at 65535, which raises fault), '
   'state[159:144] = the four lane addresses of the last beat (nibble j), '
   'state[191:160] = the previous beat a, state[223:192] = the previous result, '
   'state[227:224] = the next base slot, state[231:228] = the last stride used, '
   'state[232] = block-touched latch, state[255:233] = 0. A malformed beat '
   'returns result=aux=0, fault=1 and keeps state. Fault = malformed control, an '
   'illegal stride, or a saturated beat counter.',
   """il_block=256'd0; il_clear=256'd0; il_addr=32'd0; il_sym=32'd0; il_sum=32'd0;
       il_gath=32'd0; il_addrn=16'd0; il_beats=16'd0; il_base=4'd0; il_stride=4'd0;
       il_newbase=4'd0; il_a0=4'd0; il_a1=4'd0; il_a2=4'd0; il_a3=4'd0;
       il_illegal=1'b0; il_first=1'b0; il_dup=1'b0; il_started=1'b0;
       il_overlap=1'b0;
       if(il_bad) f = 1'b1;
       else begin
           il_block = il_sb[127:0];
           il_base = il_sb[227:224];
           il_stride = il_ctrl;
           il_started = |il_sb[127:0];
           il_illegal = (il_mode != 2'b10) &&
                        ((il_stride == 4'd0) || (il_stride == 4'd8));
           il_overlap = (il_mode == 2'b00) && (il_stride != 4'd0) &&
                        (il_stride[1:0] == 2'b00);
           if(il_mode == 2'b00 || il_mode == 2'b01) begin
               for(i=0; i<4; i=i+1) begin
                   il_addr = {28'd0, il_base};
                   if(i & 1) il_addr = il_addr + {28'd0, il_stride};
                   if(i & 2) il_addr = il_addr + ({28'd0, il_stride} << 1);
                   il_addr = il_addr & 32'd15;
                   il_addrn = il_addrn | ({12'd0, il_addr[3:0]} << (i << 2));
                   if(i == 0) il_a0 = il_addr[3:0];
                   if(i == 1) il_a1 = il_addr[3:0];
                   if(i == 2) il_a2 = il_addr[3:0];
                   if(i == 3) il_a3 = il_addr[3:0];
                   if(!il_illegal) begin
                       if(il_mode == 2'b00) begin
                           il_sym = {24'd0, a[(i << 3) +: 8]};
                           il_clear = {248'd0, 8'hff} << (il_addr << 3);
                           il_block = (il_block & ~il_clear) |
                                      ({248'd0, il_sym[7:0]} << (il_addr << 3));
                       end
                       else begin
                           il_sym = {24'd0, il_block[(il_addr << 3) +: 8]};
                           il_gath = il_gath | ({24'd0, il_sym[7:0]} << (i << 3));
                       end
                       il_sum = il_sum + {24'd0, il_sym[7:0]};
                   end
               end
           end
           il_dup = (il_mode != 2'b10) && !il_illegal &&
                    ((il_a0 == il_a1) || (il_a0 == il_a2) || (il_a0 == il_a3) ||
                     (il_a1 == il_a2) || (il_a1 == il_a3) || (il_a2 == il_a3));
           il_beats = (il_prevbeats == 16'hffff) ? 16'hffff
                                                 : (il_prevbeats + 16'd1);
           il_first = (il_prevbeats == 16'd0);
           il_newbase = (il_mode == 2'b10) ? il_base
                                          : ((il_base + 4'd4) & 4'hf);
           if(il_illegal) begin
               r = 32'd0;
               x = 32'd0;
               f = 1'b1;
           end
           else begin
               r = (il_mode == 2'b01) ? il_gath
                   : ((il_mode == 2'b00) ? il_block[31:0] : 32'd0);
               x = {il_sum[7:0], il_prevaddr[7:0], (il_mode == 2'b00),
                    (il_mode == 2'b01), il_dup, il_overlap, il_started,
                    il_first, il_illegal, c[31], il_stride, il_base};
               f = (il_prevbeats == 16'hffff);
           end
           state_n = {23'd0,
                      (il_started || ((il_mode == 2'b00) && !il_illegal)),
                      il_stride, il_newbase, r, a, il_addrn, il_beats,
                      il_block[127:0]};
       end""",
   'An interleave/deinterleave pass in software is a modulo multiply and a '
   'conditional store per symbol behind a data-dependent address chain; this '
   'network resolves four skewed addresses, the 128-bit masked write, the gather '
   'and the duplicate/overlap checks in one enabled beat at fixed latency, so a '
   'turbo decoder pays no bubble between the two half-block passes that need the '
   'permutation.',
   4, decl=IL_DECL, stateful=True)


# ---------------------------------------------------------------------------
# Independent integer models: one exact function per core, threaded state.
# ---------------------------------------------------------------------------
def s8(value):
    value &= 0xff
    return value - 256 if value >> 7 else value


def s16(value):
    value &= 0xffff
    return value - 65536 if value >> 15 else value


def sat8(value):
    return -128 if value < -128 else (127 if value > 127 else value)


def bit(word, index):
    return (word >> index) & 1


def popcount(word):
    return bin(word & MASK).count('1')


def _cn_model(a, b, c, state):
    """ldpc_cn_minsum: two min trees over eight beta-offset magnitudes."""
    if c & 0x7FFFFFF0:
        return 0, 0, 1, state
    base = 0 if (c >> 31) & 1 else state
    beta = c & 0xF
    sign_mask = 0
    saturated = 0
    magnitudes = []
    for edge in range(8):
        word = a if edge < 4 else b
        message = (word >> (8 * (edge & 3))) & 0xFF
        if message >> 7:
            sign_mask |= 1 << edge
        magnitude = (0x100 - message) & 0xFF if message >> 7 else message
        if magnitude == 128:
            saturated = 1
        if magnitude > 127:
            magnitude = 127
        magnitude = magnitude - beta if magnitude > beta else 0
        magnitudes.append(magnitude)
    mag1, mag2, argmin = 255, 255, 0
    for edge, value in enumerate(magnitudes):
        if value < mag1:
            mag2, mag1, argmin = mag1, value, edge
        elif value < mag2:
            mag2 = value
    tie = sum(1 for value in magnitudes if value == mag1)
    zero = sum(1 for value in magnitudes if value == 0)
    parity = popcount(sign_mask) & 1
    out_sign, outgoing = 0, 0
    for edge in range(8):
        value = mag2 if edge == argmin else mag1
        if (((sign_mask >> edge) & 1) ^ parity):
            out_sign |= 1 << edge
            value = ((~value & 0xFF) + 1) & 0xFF
        outgoing |= (value & 0xFF) << (8 * edge)
    history = bit(base, 192)
    previous_min = bit_slice(base, 128, 8)
    previous_count = bit_slice(base, 160, 16)
    if not history:
        trend = 3
    elif mag1 == previous_min:
        trend = 0
    elif mag1 < previous_min:
        trend = 1
    else:
        trend = 2
    count = 0xFFFF if previous_count == 0xFFFF else previous_count + 1
    result = ((saturated << 25) | (parity << 24) | (sign_mask << 16)
              | (mag2 << 8) | mag1)
    aux = (((zero & 0xF) << 28) | (history << 27) | (trend << 25)
           | ((0 if history else 1) << 24) | ((tie & 0xF) << 20)
           | (argmin << 17) | (parity << 16) | ((out_sign & 0xFF) << 8)
           | ((1 << argmin) & 0xFF))
    new_state = ((1 << 192) | (count << 160) | (result << 128)
                 | (outgoing << 64) | (b << 32) | a)
    return result, aux, (saturated or previous_count == 0xFFFF), new_state


def _vn_model(a, b, c, state):
    """ldpc_vn_update: four saturating 16-bit posteriors plus an 8-bit clamp."""
    if c & 0x3FFFFFFF:
        return 0, 0, 1, state
    seed = (c >> 31) & 1
    base = 0 if seed else state
    result, posteriors = 0, 0
    hard = clamp = saturated = zero = smaller = 0
    for lane in range(4):
        message = s8((a >> (8 * lane)) & 0xFF)
        if seed:
            prior = s8((b >> (8 * lane)) & 0xFF)
        else:
            prior = s16((base >> (16 * lane)) & 0xFFFF)
        total = prior + message
        if total > 32767:
            total, saturated = 32767, saturated | (1 << lane)
        elif total < -32768:
            total, saturated = -32768, saturated | (1 << lane)
        if total > 0:
            hard |= 1 << lane
        if total == 0:
            zero |= 1 << lane
        if abs(total) < abs(prior):
            smaller |= 1 << lane
        if total > 127:
            byte, clamp = 0x7F, clamp | (1 << lane)
        elif total < -127:
            byte, clamp = 0x81, clamp | (1 << lane)
        else:
            byte = total & 0xFF
        result |= byte << (8 * lane)
        posteriors |= (total & 0xFFFF) << (16 * lane)
    previous_count = bit_slice(base, 64, 16)
    count = 0xFFFF if previous_count == 0xFFFF else previous_count + 4
    count_sat = bit(base, 80) or previous_count == 0xFFFF
    seeded = bit(base, 81)
    aux = (((count & 0xF) << 28) | ((1 if hard == 0xF else 0) << 27)
           | (int(bool(count_sat)) << 26) | ((0 if (seeded or seed) else 1) << 25)
           | (seed << 24) | (((~zero) & 0xF) << 20) | (hard << 16)
           | (smaller << 12) | (zero << 8) | (saturated << 4) | clamp)
    new_state = (posteriors | (count << 64) | (int(bool(count_sat)) << 80)
                 | (int(bool(seeded or seed)) << 81) | (a << 96)
                 | (result << 128))
    return result, aux, (saturated != 0 or previous_count == 0xFFFF), new_state


def _rs_model(a, b, c, state):
    """rs255_syndrome_acc: four Horner folds, each a chain of xtime doublings."""
    count = b & 7
    if (b >> 3) or (c & 0x3FFFFFFF) or count > 4:
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    base = 0 if restart else state
    syndromes = [bit_slice(base, 8 * i, 8) for i in range(4)]
    previous_count = bit_slice(base, 32, 16)
    sticky_previous = bit(base, 48)
    last_block = (state & 0xFFFFFFFF) if restart else bit_slice(base, 96, 32)
    for symbol_index in range(count):
        symbol = (a >> (8 * symbol_index)) & 0xFF
        for i in range(4):
            value = syndromes[i]
            for _ in range(i):
                value = xtime(value)
            syndromes[i] = value ^ symbol
    mask = nz = 0
    for i in range(4):
        if syndromes[i]:
            mask |= 1 << i
            nz += 1
    clean = 1 if mask == 0 else 0
    count_total = (0xFFFF if previous_count == 0xFFFF
                   else previous_count + count)
    sticky = int(bool(sticky_previous or mask))
    result = sum(syndromes[i] << (8 * i) for i in range(4))
    aux = ((count_total << 16) | ((1 if previous_count == 0xFFFF else 0) << 12)
           | ((1 if count < 4 else 0) << 11) | ((1 if last_block == 0 else 0) << 10)
           | (restart << 9) | (sticky << 8) | (clean << 7) | (nz << 4) | mask)
    new_state = (result | (count_total << 32) | (sticky << 48) | (a << 64)
                 | (last_block << 96))
    return result, aux, int(previous_count == 0xFFFF), new_state


def _pe_model(a, b, c, state):
    """gf256_poly_eval: Horner at alpha^k through the log/antilog image."""
    k = c & 0xFF
    if k == 255 or ((c >> 8) & 0x7FFFFF):
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    base = 0 if restart else state
    log, antilog = gf8_tables()
    value = bit_slice(base, 0, 8)
    previous_count = bit_slice(base, 8, 24)
    previous_entered = bit_slice(base, 96, 8)
    stage, zeroed = 0, 0
    for step_index in range(4):
        if value == 0:
            product, zeroed = 0, 1
        else:
            folded = log[value] + k
            if folded >= 255:
                folded -= 255
            product = antilog[folded]
        value = product ^ ((a >> (8 * step_index)) & 0xFF)
        stage |= value << (8 * (3 - step_index))
    count = (0xFFFFFF if previous_count == 0xFFFFFF
            else previous_count + 4)
    saturated = 1 if previous_count == 0xFFFFFF else 0
    aux = (((count & 0xFFF) << 20) | (saturated << 19)
           | ((1 if previous_entered == ((stage >> 24) & 0xFF) else 0) << 18)
           | (zeroed << 17) | (restart << 16) | (k << 8) | bit_slice(base, 0, 8))
    new_state = ((stage & 0xFF) | (count << 8) | (a << 32)
                 | (bit_slice(base, 32, 32) << 64) | (bit_slice(base, 0, 8) << 96)
                 | (1 << 128) | (int(bool(bit(base, 129) or saturated)) << 129))
    return stage, aux, saturated, new_state


def bit_slice(word, offset, width):
    return (word >> offset) & ((1 << width) - 1)


def _bch_model(a, b, c, state):
    """bch31_syndrome: 20 GF(2) check parities plus the 31-way locator."""
    if (a >> 31) or (c & 0x3FFFFFFF):
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    accumulate = (c >> 30) & 1
    base = 0 if restart else state
    powers = gf5_beta_powers()
    rows = _bch_rows(powers)
    columns = _bch_columns(powers)
    word = a & 0x7FFFFFFF
    syndrome = 0
    for index in range(BCH_PARITY):
        if popcount(word & rows[index]) & 1:
            syndrome |= 1 << index
    stored = bit_slice(base, 0, 20)
    if accumulate:
        syndrome ^= stored
    position, matched = 31, 0
    for index in range(BCH_N):
        if not matched and syndrome == columns[index]:
            matched, position = 1, index
    uncorrectable = 1 if (syndrome and not matched) else 0
    count = (bit_slice(base, 64, 32) + 1) & 0xFFFFFFFF
    clean = 1 if syndrome == 0 else 0
    result = (syndrome | (clean << 20) | (matched << 21) | (uncorrectable << 22)
              | (accumulate << 23))
    aux = (position | (matched << 5) | (clean << 6) | (uncorrectable << 7)
           | (accumulate << 8) | (restart << 9) | (popcount(syndrome) << 10)
           | (popcount(word) << 16) | ((1 if syndrome != stored else 0) << 22)
           | ((1 if word == bit_slice(base, 32, 31) else 0) << 23))
    new_state = syndrome | (word << 32) | (count << 64) | (stored << 112)
    return result, aux, uncorrectable, new_state


def _acs_model(a, b, c, state):
    """convk7_acs16: sixteen saturating ACS units and a 16-wide min tree."""
    if c & 0x3FFFFFFF:
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    bypass = (c >> 30) & 1
    base = 0 if restart else state
    metrics = [bit_slice(base, 8 * j, 8) for j in range(16)]
    bank_a = [s8((a >> (8 * k)) & 0xFF) for k in range(4)]
    bank_b = [s8((b >> (8 * k)) & 0xFF) for k in range(4)]
    survivors, winners, tie, clamp = 0, [], 0, 0
    for j in range(16):
        first = metrics[j >> 1] + bank_a[j & 3]
        second = metrics[(j >> 1) + 8] + bank_b[j & 3]
        if first < 0 or first > 255 or second < 0 or second > 255:
            clamp = 1
        first = min(255, max(0, first))
        second = min(255, max(0, second))
        if second > first:
            survivors |= 1 << j
            winners.append(second)
        else:
            winners.append(first)
            if first == second:
                tie = 1
    low, high = min(winners), max(winners)
    normalised = [value if bypass else value - low for value in winners]
    minlanes = 0
    increased = 0
    for j in range(16):
        if winners[j] == low:
            minlanes = 15 if minlanes == 15 else minlanes + 1
        if normalised[j] > metrics[j] and increased != 16:
            increased += 1
    previous_count = bit_slice(base, 144, 16)
    count = 0xFFFF if previous_count == 0xFFFF else previous_count + 1
    history = bit(base, 192)
    result = (low | (high << 8) | ((high - low) << 16) | ((0 if bypass else 1) << 24)
              | (clamp << 25) | (tie << 26))
    aux = ((survivors & 0xFF) | ((survivors >> 8) << 8) | (restart << 16)
           | ((0 if history else 1) << 17) | ((1 if high - low > 127 else 0) << 18)
           | ((1 if previous_count == 0xFFFF else 0) << 19)
           | (minlanes << 20) | (increased << 24))
    new_state = sum(normalised[j] << (8 * j) for j in range(16))
    new_state |= survivors << 128 | count << 144 | result << 160 | (1 << 192)
    return result, aux, (clamp or previous_count == 0xFFFF), new_state


def _pu_model(a, b, c, state):
    """puncture_map_r13: rank-packed compression and its exact inverse."""
    if c & 0x7FFFFFF0:
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    expansion = (c >> 3) & 1
    base = 0 if restart else state
    patterns = puncture_image()
    mask = patterns[c & 3]
    illegal = 1 if mask == 0 else 0
    output = rank = total = skip = 0
    for position in range(32):
        if (mask >> position) & 1:
            if not ((a >> position) & 1) and skip != 15:
                skip += 1
            if not expansion:
                if (a >> position) & 1:
                    output |= 1 << rank
            elif (a >> rank) & 1:
                output |= 1 << position
            rank += 1
            total += 1
    previous_beats = bit_slice(base, 64, 16)
    previous_total = bit_slice(base, 80, 16)
    beats = 0xFFFF if previous_beats == 0xFFFF else previous_beats + 1
    emit = (0xFFFF if previous_total > 0xFFFF - total
            else previous_total + total)
    aux = ((total & 0x3F) | (expansion << 6) | (illegal << 7) | (restart << 8)
           | ((1 if previous_beats == 0 else 0) << 9)
           | ((1 if output == bit_slice(base, 0, 32) else 0) << 10)
           | ((1 if mask == bit_slice(base, 32, 32) else 0) << 11)
           | (skip << 12) | ((emit & 0xFF) << 16) | ((beats & 0xFF) << 24))
    new_state = output | (mask << 32) | (beats << 64) | (emit << 80) | (a << 96)
    return output, aux, (illegal or previous_beats == 0xFFFF), new_state


def _ta_model(a, b, c, state):
    """turbo_alpha_step: one log-MAP forward section of four states."""
    if c & 0x3FFFFFFF:
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    winner_mode = (c >> 30) & 1
    base = 0 if restart else state
    alpha = bit_slice(base, 0, 32)
    previous_survivors = bit_slice(base, 32, 4)
    previous_count = bit_slice(base, 96, 16)
    sbit = wbit = tie = clampc = 0
    raw = []
    high, low = -129, 128
    for i in range(4):
        idx = 8 * i
        current = s8((alpha >> (8 * (i >> 1))) & 0xFF)
        other = s8((alpha >> (8 * ((i >> 1) + 2))) & 0xFF) \
            + s8((b >> idx) & 0xFF)
        cand = current + s8((a >> idx) & 0xFF)
        if (cand < -128 or cand > 127 or other < -128 or other > 127) and clampc != 15:
            clampc += 1
        cand = min(127, max(-128, cand))
        other = min(127, max(-128, other))
        if cand > other:
            best = cand
        else:
            best = other
            sbit |= 1 << i
            if cand == other:
                tie |= 1 << i
        wbit |= ((previous_survivors >> i) & 1) << i
        raw.append(best)
        if best > high:
            high = best
        if best < low:
            low = best
    window = high - low
    survivors = []
    for i in range(4):
        best = raw[i]
        if window > 64:
            best = min(127, max(-128, best - (window - 64)))
            if clampc != 15:
                clampc += 1
        elif window > 32:
            best = best - low
        survivors.append(best)
    count = 0xFFFF if previous_count == 0xFFFF else previous_count + 1
    pre_norm = sum((raw[i] & 0xFF) << (8 * i) for i in range(4))
    post_norm = sum((survivors[i] & 0xFF) << (8 * i) for i in range(4))
    aux = ((sbit & 0xF) | ((wbit & 0xF) << 4) | (restart << 8)
           | ((1 if previous_count == 0 else 0) << 9) | ((1 if tie else 0) << 10)
           | ((1 if window > 32 else 0) << 11) | ((1 if window > 64 else 0) << 12)
           | ((1 if high < 0 else 0) << 13) | (clampc << 14)
           | ((window & 0xFF) << 24))
    new_state = (post_norm | (sbit << 32) | (wbit << 36) | (alpha << 56)
                 | (count << 96))
    result = pre_norm if winner_mode else post_norm
    return result, aux, (1 if previous_count == 0xFFFF else 0), new_state


def _h_model(a, b, c, state):
    """hamming74_correct: four SECDED(8,4) lanes with the published equations."""
    if b or (c & 0x3FFFFFFF):
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    base = 0 if restart else state
    previous_count = bit_slice(base, 64, 16)
    previous_beats = bit_slice(base, 80, 16)
    result = nz = corr = ded = zero = pf = nib0 = 0
    corrected = 0
    for lane in range(4):
        shift = 8 * lane
        word = (a >> shift) & 0xFF
        d1 = (word >> 2) & 1
        d2 = (word >> 4) & 1
        d3 = (word >> 5) & 1
        d4 = (word >> 6) & 1
        overall = ((word >> 7) & 1) ^ (popcount(word & 0x7F) & 1)
        syndrome = ((((word >> 3) & 1) ^ d2 ^ d3 ^ d4) << 2) \
            | (((word >> 1) & 1) ^ d1 ^ d3 ^ d4) << 1 \
            | (((word >> 0) & 1) ^ d1 ^ d2 ^ d4)
        if syndrome:
            nz |= 1 << lane
            if overall:
                word ^= 1 << (syndrome - 1)
                corr |= 1 << lane
                if corrected != 4:
                    corrected += 1
            else:
                ded |= 1 << lane
        else:
            zero |= 1 << lane
            if overall:
                pf |= 1 << lane
        word = (word & 0x7F) | ((popcount(word & 0x7F) & 1) << 7)
        if lane == 0:
            nib0 = (((word >> 6) & 1) << 3) | (((word >> 5) & 1) << 2) \
                | (((word >> 4) & 1) << 1) | ((word >> 2) & 1)
        result |= word << shift
    count = (0xFFFF if previous_count > 0xFFFF - corrected else
             previous_count + corrected)
    beats = 0xFFFF if previous_beats == 0xFFFF else previous_beats + 1
    aux = (nz | (corr << 4) | (ded << 8) | (zero << 12) | (pf << 16)
           | (restart << 20) | ((1 if previous_beats == 0 else 0) << 21)
           | ((1 if previous_count == 0xFFFF else 0) << 22)
           | ((1 if corr else 0) << 23) | (corrected << 24) | (nib0 << 28))
    new_state = (a | (result << 32) | (count << 64) | (beats << 80) | (1 << 96))
    fault = 1 if (ded or previous_count == 0xFFFF) else 0
    return result, aux, fault, new_state


def _il_model(a, b, c, state):
    """interleave_convex: stride-skew address network over a 16-slot window."""
    mode = c & 3
    if (c & 0x3FFFFFC0) or mode == 3:
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    saved = 0 if restart else state
    block = bit_slice(saved, 0, 128)
    base_slot = bit_slice(saved, 224, 4)
    previous_beats = bit_slice(saved, 128, 16)
    previous_addr = bit_slice(saved, 144, 16)
    stride = bit_slice(c, 2, 4)
    illegal = 1 if (mode != 2 and (stride == 0 or stride == 8)) else 0
    started = 1 if block else 0
    overlap = 1 if (mode == 0 and stride != 0 and (stride & 3) == 0) else 0
    addrn = gather = total = 0
    lanes = []
    if mode in (0, 1):
        for i in range(4):
            addr = base_slot
            if i & 1:
                addr += stride
            if i & 2:
                addr += stride << 1
            addr &= 15
            addrn |= addr << (4 * i)
            lanes.append(addr)
            if not illegal:
                if mode == 0:
                    symbol = (a >> (8 * i)) & 0xFF
                    block = (block & ~(0xFF << (8 * addr))) | (symbol << (8 * addr))
                else:
                    symbol = (block >> (8 * addr)) & 0xFF
                    gather |= symbol << (8 * i)
                total = (total + symbol) & MASK
    dup = 0
    if mode != 2 and not illegal:
        pairs = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]
        dup = 1 if any(lanes[x] == lanes[y] for x, y in pairs) else 0
    beats = 0xFFFF if previous_beats == 0xFFFF else previous_beats + 1
    first = 1 if previous_beats == 0 else 0
    newbase = base_slot if mode == 2 else ((base_slot + 4) & 0xF)
    if illegal:
        result, aux, fault = 0, 0, 1
    else:
        result = (gather if mode == 1
                  else ((block & 0xFFFFFFFF) if mode == 0 else 0))
        aux = (base_slot | (stride << 4) | (restart << 8) | (illegal << 9)
               | (first << 10) | (started << 11) | (overlap << 12) | (dup << 13)
               | ((1 if mode == 1 else 0) << 14) | ((1 if mode == 0 else 0) << 15)
               | ((previous_addr & 0xFF) << 16) | ((total & 0xFF) << 24))
        fault = 1 if previous_beats == 0xFFFF else 0
    touched = 1 if (started or (mode == 0 and not illegal)) else 0
    new_state = (block | ((beats & 0xFFFF) << 128) | (addrn << 144) | (a << 160)
                 | (result << 192) | (newbase << 224) | (stride << 228)
                 | (touched << 232))
    return result, aux, fault, new_state


MODELS = {
    'ldpc_cn_minsum': _cn_model,
    'ldpc_vn_update': _vn_model,
    'rs255_syndrome_acc': _rs_model,
    'gf256_poly_eval': _pe_model,
    'bch31_syndrome': _bch_model,
    'convk7_acs16': _acs_model,
    'puncture_map_r13': _pu_model,
    'turbo_alpha_step': _ta_model,
    'hamming74_correct': _h_model,
    'interleave_convex': _il_model,
}


def step(name, a, b, c, state=0):
    return MODELS[name](a & MASK, b & MASK, c & MASK, state)


def _entries(name):
    return next(entry for entry in CORES if entry['name'] == name)


# ---------------------------------------------------------------------------
# Stimulus: legal-shaped random rows plus a curated head that carries the
# restart, the fault rows and the boundary patterns the gates ask for.
# ---------------------------------------------------------------------------
def _word(rng):
    return rng.getrandbits(32)


def _llr_word(rng):
    """Four byte LLRs, biased towards the saturating corners 0x80 and 0x7F."""
    out = 0
    for lane in range(4):
        pick = rng.random()
        if pick < 0.12:
            byte = 0x80
        elif pick < 0.24:
            byte = 0x7F
        elif pick < 0.32:
            byte = 0x00
        else:
            byte = rng.getrandbits(8)
        out |= byte << (8 * lane)
    return out


def _cand_cn(rng, bad):
    c = rng.randrange(16)
    if rng.random() < 0.1:
        c |= 1 << 31
    if bad:
        c |= 1 << rng.randrange(4, 31)
    return _llr_word(rng), _llr_word(rng), c


def _cand_vn(rng, bad):
    c = (1 << 31) if rng.random() < 0.12 else 0
    if bad:
        c |= 1 << rng.randrange(0, 31)
    return _llr_word(rng), _llr_word(rng), c


def _cand_rs(rng, bad):
    a = _word(rng)
    b = rng.randrange(5)
    c = (1 << 31) if rng.random() < 0.12 else 0
    if bad:
        if rng.random() < 0.5:
            b |= 1 << rng.randrange(3, 32)
        else:
            c |= 1 << rng.randrange(0, 31)
    return a, b, c


def _cand_pe(rng, bad):
    c = rng.randrange(255)
    if rng.random() < 0.12:
        c |= 1 << 31
    if bad:
        c = (255 | (c & (1 << 31))) if rng.random() < 0.5 else (c | 1 << rng.randrange(8, 31))
    return _word(rng), 0, c


def _cand_bch(rng, bad):
    a = rng.getrandbits(31)
    c = 0
    if rng.random() < 0.12:
        c |= 1 << 31
    if rng.random() < 0.25:
        c |= 1 << 30
    if bad:
        if rng.random() < 0.5:
            a |= 1 << 31
        else:
            c |= 1 << rng.randrange(0, 30)
    return a, 0, c


def _cand_acs(rng, bad):
    c = 0
    if rng.random() < 0.12:
        c |= 1 << 31
    if rng.random() < 0.2:
        c |= 1 << 30
    if bad:
        c |= 1 << rng.randrange(0, 30)
    return _llr_word(rng), _llr_word(rng), c


def _cand_pu(rng, bad):
    c = rng.randrange(4)
    if rng.random() < 0.5:
        c |= 1 << 3
    if rng.random() < 0.12:
        c |= 1 << 31
    if bad:
        c |= 1 << rng.randrange(4, 31)
    return _word(rng), 0, c


def _cand_ta(rng, bad):
    c = 0
    if rng.random() < 0.12:
        c |= 1 << 31
    if rng.random() < 0.2:
        c |= 1 << 30
    if bad:
        c |= 1 << rng.randrange(0, 30)
    return _llr_word(rng), _llr_word(rng), c


def _cand_h(rng, bad):
    a = _word(rng)
    b = 0
    c = (1 << 31) if rng.random() < 0.12 else 0
    if bad:
        if rng.random() < 0.5:
            b = 1 << rng.randrange(0, 32)
        else:
            c |= 1 << rng.randrange(0, 30)
    return a, b, c


def _cand_il(rng, bad):
    c = rng.choice((0, 1, 2)) | (rng.randrange(16) << 2)
    if rng.random() < 0.12:
        c |= 1 << 31
    if bad:
        if rng.random() < 0.5:
            c = (c & ~3) | 3
        else:
            c |= 1 << rng.randrange(6, 30)
    return _word(rng), 0, c


CANDIDATES = {
    'ldpc_cn_minsum': _cand_cn,
    'ldpc_vn_update': _cand_vn,
    'rs255_syndrome_acc': _cand_rs,
    'gf256_poly_eval': _cand_pe,
    'bch31_syndrome': _cand_bch,
    'convk7_acs16': _cand_acs,
    'puncture_map_r13': _cand_pu,
    'turbo_alpha_step': _cand_ta,
    'hamming74_correct': _cand_h,
    'interleave_convex': _cand_il,
}


R = 1 << 31                       # restart strobe
B = 1 << 30                       # second control bit where the core has one

HEADS = {
    'ldpc_cn_minsum': [
        (0, 0, R), (0x80808080, 0x80808080, 15 | R), (0x7F7F7F7F, 0x00000000, 0),
        (0xFFFFFFFF, 0xFFFFFFFF, 1), (0x01020304, 0x05060708, R),
        (0x80000000, 0, 0), (0, 0x80000000, 3), (0x0F0F0F0F, 0xF0F0F0F0, 2 | R),
        (0, 0, 1 << 20), (0, 0, 1 << 4), (0xAAAA5555, 0x336699CC, 7),
    ],
    'ldpc_vn_update': [
        (0, 0, R), (0x7F7F7F7F, 0, R), (0x80808080, 0x80808080, R),
        (0xFFFFFFFF, 0, 0), (0x01020304, 0x7F7F7F7F, R), (0x40404040, 0, 0),
        (0x7F7F0000, 0, 0), (0, 0x7F7F7F7F, R), (0x81818181, 0, 0),
        (0, 0, 1 << 17), (0, 0, 1), (0x20202020, 0x30303030, R),
    ],
    'rs255_syndrome_acc': [
        (0, 4, R), (0x11223344, 4, 0), (0xFFFFFFFF, 0, 0), (0x80808080, 4, 0),
        (0x01020304, 2, R), (0x7F7F7F7F, 4, 0), (0x000000FF, 1, 0),
        (0xA5A5A5A5, 3, 0), (0, 8, 0), (0, 0, 1 << 12), (0x10203040, 4, R),
    ],
    'gf256_poly_eval': [
        (0, 0, R), (0x01010101, 0, 1), (0, 0, 1 | R), (0xFFFFFFFF, 0, 2),
        (0x80402010, 0, 254 | R), (0x11223344, 0, 17), (0x00FF00FF, 0, 200),
        (0x7F7F7F7F, 0, 3 | R), (0, 0, 255), (0, 0, 1 << 20), (0xA5A5A5A5, 0, 90),
    ],
    'bch31_syndrome': [
        (0, 0, R), (0x7FFFFFFF, 0, 0), (0x40000000, 0, 1 << 30),
        (0x00000001, 0, 0), (0x00000002, 0, R), (0x5ABCDCEF, 0, 1 << 30),
        (0x23456789, 0, 0), (0x0F0F0F0F, 0, R | (1 << 30)), (0x12345678, 0, 0),
        (1 << 31, 0, 0), (0, 0, 1 << 13), (0x7ACAFE01, 0, 0),
    ],
    'convk7_acs16': [
        (0, 0, R), (0x80808080, 0x80808080, R), (0x7F7F7F7F, 0x7F7F7F7F, 0),
        (0xFFFFFFFF, 0, B), (0x01020304, 0x05060708, R), (0x40404040, 0xC0C0C0C0, 0),
        (0, 0x7F7F7F7F, B), (0x11111111, 0x22222222, R), (0x80808080, 0, 0),
        (0, 0, 1 << 21), (0, 0, 1 << 8), (0xAAAAAAAA, 0x55555555, B | R),
    ],
    'puncture_map_r13': [
        (0, 0, R), (0xFFFFFFFF, 0, 0), (0x00000000, 0, 3), (0xAAAA5555, 0, 8),
        (0x12345678, 0, 1 | R), (0xFFFFFFFF, 0, 11), (0x80008000, 0, 2),
        (0x0F0F0F0F, 0, 3 | R), (0x55555555, 0, 0), (0, 0, 1 << 20),
        (0, 0, 1 << 4), (0x1234ABCDEF & MASK, 0, 9),
    ],
    'turbo_alpha_step': [
        (0, 0, R), (0x80808080, 0x80808080, R), (0x7F7F7F7F, 0x00000000, 0),
        (0xFFFFFFFF, 0, B), (0x01020304, 0x05060708, R), (0x40404040, 0xC0C0C0C0, 0),
        (0x00000080, 0x00000080, B), (0x11111111, 0x22222222, R),
        (0x80808080, 0x7F7F7F7F, 0), (0, 0, 1 << 22), (0, 0, 1 << 9),
        (0xAAAAAAAA, 0x55555555, B | R),
    ],
    'hamming74_correct': [
        (0, 0, R), (0xFFFFFFFF, 0, 0), (0x00000000, 0, 0), (0x03030303, 0, R),
        (0x0C335599, 0, 0), (0x01020408, 0, 0), (0x80808080, 0, R),
        (0x2A2A2A2A, 0, 0), (0x00FF00FF, 0, R), (0, 1 << 20, 0), (0, 0, 1 << 15),
        (0x5A5A5A5A, 0, 0),
    ],
    'interleave_convex': [
        (0, 0, R), (0x01020304, 0, 5 << 2), (0x05060708, 0, 1 | (5 << 2)),
        (0xFFFFFFFF, 0, 2 | (3 << 2)), (0x0000FFFF, 0, R | (7 << 2)),
        (0x11223344, 0, 2), (0x0A0B0C0D, 0, 1 | (11 << 2)), (0, 0, 8 << 2),
        (0, 0, R | (9 << 2)), (0x80808080, 0, 1 | (13 << 2)),
        (0, 0, 3), (0, 0, 1 << 20), (0xF0F0F0F0, 0, 6 << 2),
    ],
}


def vectors(name, count=320):
    """Deterministic board-quality rows: curated head, then distinct-by-search."""
    if name not in MODELS:
        raise KeyError(name)
    index = next(i for i, entry in enumerate(CORES) if entry['name'] == name)
    rng = Random((0x5EFEC0DE + 7919 * index) & 0xFFFFFFFF)
    rows, seen, state = [], set(), 0

    def emit(a, b, c, fresh_only=False):
        nonlocal state
        a, b, c = a & MASK, b & MASK, c & MASK
        r, x, f, state = step(name, a, b, c, state)
        if fresh_only and (r, x, f) in seen:
            return False
        seen.add((r, x, f))
        rows.append((a, b, c))
        return True

    for a, b, c in HEADS[name]:
        emit(a, b, c)
    pick = CANDIDATES[name]
    attempts = 0
    while len(rows) < BOARD_ROWS and attempts < 60000:
        attempts += 1
        emit(*pick(rng, attempts < 400 and len(rows) < 6), fresh_only=True)
    while len(rows) < count:
        emit(*pick(rng, False))
    return rows


# ---------------------------------------------------------------------------
# Family selftest. Nothing here reads a value produced by step(): every
# constant is derived in place from a published polynomial, or is a hand
# computable field fact, and the models are then checked against it.
# ---------------------------------------------------------------------------
def _check(label, condition):
    if not condition:
        raise AssertionError('fec selftest failed: ' + label)
    return 1


def _poly_reduce2(product, modulus):
    """GF(2)[x] remainder by long division: independent of gf8_mul's shape."""
    shift = modulus.bit_length() - 1
    for bit in range(product.bit_length() - 1, shift - 1, -1):
        if (product >> bit) & 1:
            product ^= modulus << (bit - shift)
    return product


def _poly_mul2(left, right):
    out = 0
    for bit in range(right.bit_length()):
        if (right >> bit) & 1:
            out ^= left << bit
    return out


def _poly_mul_gf32(left, right):
    """Monic polynomial product with GF(32) coefficients, descending powers."""
    out = [0] * (len(left) + len(right) - 1)
    for i, first in enumerate(left):
        for j, second in enumerate(right):
            out[i + j] ^= gf5_mul(first, second)
    return out


def _st_gf256():
    """GF(2^8) on the published primitive polynomial 0x11D used by RS kernels."""
    checks = 0
    log, antilog = gf8_tables()
    seen, value = set(), 1
    for _ in range(255):
        seen.add(value)
        value = xtime(value)
    checks += _check('gf256 alpha = x has order 255 (0x11D is primitive)',
                     len(seen) == 255 and value == 1 and seen == set(range(1, 256)))
    checks += _check('gf256 x^8 = x^4+x^3+x^2+1 = 0x1D', gf8_pow(8) == 0x1D)
    checks += _check('gf256 alpha^0 = 1', antilog[0] == 1 and gf8_pow(0) == 1)
    checks += _check('gf256 antilog wraps at 255', antilog[255] == antilog[0])
    for value in range(1, 256):
        checks += _check('gf256 log/antilog inverse', antilog[log[value]] == value)
    for left in range(256):
        for right in range(0, 255, 11):
            raw = 0
            for bit in range(8):
                if (left >> bit) & 1:
                    raw ^= right << bit
            checks += _check('gf256 shift-xor product equals long division',
                             gf8_mul(left, right) == _poly_reduce2(raw, POLY8))
    image = poly_eval_image()
    for k in (0, 1, 2, 7, 31, 97, 128, 254):
        scale = gf8_pow(k)
        for value in range(1, 256, 7):
            folded = log[value] + k
            if folded >= 255:
                folded -= 255
            checks += _check('gf256 poly-eval ROM product matches the field',
                             (image[folded] & 0xFF) == gf8_mul(value, scale))
    checks += _check('gf256 ROM image width', len(image) == 256
                     and all(word >> 16 == 0 for word in image))
    return checks


def _st_bch():
    """BCH(31,11) over GF(32)/x^5+x^2+1: generator, distance, locator, sums."""
    checks = 0
    powers = gf5_beta_powers()
    checks += _check('gf32 beta = x has order 31 (0x25 is primitive)',
                     powers[0] == 1 and len(set(powers)) == 31
                     and gf5_mul(powers[30], 2) == 1)
    minimal = []
    for cls in BCH_CLASSES:
        poly, element = [1], powers[cls]
        for _ in range(5):
            poly = _poly_mul_gf32(poly, [1, element])
            element = gf5_mul(element, element)     # conjugacy class = squaring
        checks += _check('gf32 minimal polynomial of beta^%d is binary' % cls,
                         all(coefficient in (0, 1) for coefficient in poly))
        binary = 0
        for position, coefficient in enumerate(poly):
            binary |= coefficient << (len(poly) - 1 - position)
        minimal.append(binary)
        checks += _check('gf32 minimal polynomial has degree 5', binary.bit_length() == 6)
    generator = 1
    for factor in minimal:
        generator = _poly_mul2(generator, factor)
    checks += _check('bch31 generator has 20 parity bits -> a [31,11] code',
                     generator.bit_length() == BCH_PARITY + 1)
    checks += _check('bch31 generator divides x^31 - 1',
                     _poly_reduce2((1 << BCH_N) | 1, generator) == 0)
    codewords = [_poly_mul2(information, generator) for information in range(1 << BCH_K)]
    checks += _check('bch31 code has 2^11 distinct 31-bit blocks',
                     len(set(codewords)) == 1 << BCH_K
                     and all(word >> 31 == 0 for word in codewords))
    distance = min(bin(word).count('1') for word in codewords[1:])
    checks += _check('bch31 minimum weight %d is at least 7 (t = 3)' % distance,
                     distance >= 7)
    rows, columns = _bch_rows(powers), _bch_columns(powers)
    for word in codewords:
        syndrome = 0
        for index in range(BCH_PARITY):
            if popcount(word & rows[index]) & 1:
                syndrome |= 1 << index
        checks += _check('bch31 check rows annihilate every codeword', syndrome == 0)

    def syndrome_of(word):
        result, _, _, _ = _bch_model(word, 0, R, 0)
        return result & ((1 << BCH_PARITY) - 1)

    rng = Random(0xBCC0DE)
    for _ in range(240):
        word = rng.getrandbits(BCH_N)
        expected = 0
        for index, cls in enumerate(BCH_CLASSES):
            element = 0
            for position in range(BCH_N):
                if (word >> position) & 1:
                    element ^= powers[(cls * position) % BCH_N]
            expected |= element << (5 * index)
        checks += _check('bch31 syndrome equals an independent GF(32) evaluation',
                         syndrome_of(word) == expected)
    for position in range(BCH_N):
        result, aux, fault, _ = _bch_model(1 << position, 0, R, 0)
        checks += _check('bch31 single-error locator finds the right bit',
                         (result & 0xFFFFF) == columns[position]
                         and (aux & 0x1F) == position and ((result >> 21) & 1) == 1
                         and fault == 0 and ((result >> 20) & 1) == 0)
    for _ in range(240):
        first, second = rng.randrange(BCH_N), rng.randrange(BCH_N)
        if first == second:
            continue
        result, aux, fault, _ = _bch_model((1 << first) ^ (1 << second), 0, R, 0)
        checks += _check('bch31 double-error pattern detects without locating',
                         fault == 1 and ((result >> 21) & 1) == 0
                         and ((result >> 22) & 1) == 1 and result & 0xFFFFF)
    first_word, second_word = rng.getrandbits(BCH_N), rng.getrandbits(BCH_N)
    _, _, _, stored = _bch_model(first_word, 0, R, 0)
    merged, _, _, _ = _bch_model(second_word, 0, 1 << 30, stored)
    checks += _check('bch31 accumulate mode XORs the two block syndromes',
                     (merged & 0xFFFFF) == (syndrome_of(first_word) ^ syndrome_of(second_word)))
    bad_result, bad_aux, bad_fault, bad_state = _bch_model(1 << 31, 0, 1 << 7, stored)
    checks += _check('bch31 malformed beat faults and holds state',
                     (bad_result, bad_aux, bad_fault, bad_state) == (0, 0, 1, stored))
    return checks


def _st_hamming():
    """SECDED(8,4): built from the published (7,4) check matrix, exhaustively."""
    checks = 0
    # H columns are the binary representations of positions 1..7 (the standard
    # Hamming code); bit b of the syndrome is the parity of the positions whose
    # index has bit b set, which fixes the three published check equations.
    covered = {bit: [position for position in range(1, 8)
                     if (position >> bit) & 1] for bit in range(3)}
    checks += _check('hamming74 covers positions 1..7 once per syndrome bit',
                     covered[0] == [1, 3, 5, 7] and covered[1] == [2, 3, 6, 7]
                     and covered[2] == [4, 5, 6, 7])
    # word bit layout (1-based position p -> bit p-1): p1 p2 d1 p3 d2 d3 d4 p0
    def encode(d1, d2, d3, d4):
        p1 = d1 ^ d2 ^ d4
        p2 = d1 ^ d3 ^ d4
        p3 = d2 ^ d3 ^ d4
        word = (p1 << 0) | (p2 << 1) | (d1 << 2) | (p3 << 3) | (d2 << 4) \
            | (d3 << 5) | (d4 << 6)
        return word | ((bin(word).count('1') & 1) << 7)

    def syndromes(word):
        return [sum((word >> (position - 1)) & 1 for position in covered[bit]) & 1
                for bit in range(3)]

    for nibble in range(16):
        data = [(nibble >> k) & 1 for k in range(4)]      # d1 d2 d3 d4
        word = encode(*data)
        checks += _check('hamming74 encoder is a codeword of the published H',
                         syndromes(word & 0x7F) == [0, 0, 0]
                         and (bin(word).count('1') & 1) == 0)
        result, aux, fault, _ = _h_model(word, 0, R, 0)
        checks += _check('hamming74 clean codeword needs no correction',
                         fault == 0 and (aux & 0xF) == 0 and ((aux >> 4) & 1) == 0
                         and ((aux >> 28) & 0xF) == nibble
                         and (result & 0xFF) == word)
        for position in range(8):
            received = word ^ (1 << position)
            result, aux, fault, state = _h_model(received, 0, R, 0)
            recovered = (aux >> 28) & 0xF
            single = 1 if position < 7 else 0
            parity_only = 1 if position == 7 else 0
            repaired = result & 0xFF
            checks += _check('hamming74 corrects every single-bit error',
                             recovered == nibble and fault == 0 and repaired == word
                             and ((aux >> 4) & 1) == single
                             and ((aux >> 16) & 1) == parity_only
                             and syndromes(repaired & 0x7F) == [0, 0, 0]
                             and bin(repaired).count('1') % 2 == 0
                             and bit_slice(state, 32, 32) == word)
            for other in range(position + 1, 8):
                received = word ^ (1 << position) ^ (1 << other)
                _, aux, fault, _ = _h_model(received, 0, R, 0)
                checks += _check('hamming74 detects every double-bit error',
                                 fault == 1 and ((aux >> 8) & 1) == 1
                                 and ((aux >> 4) & 1) == 0)
    lanes = [encode(*[(k >> i) & 1 for i in range(4)]) for k in (1, 4, 9, 15)]
    clean = sum(lane << (8 * index) for index, lane in enumerate(lanes))
    result, aux, fault, _ = _h_model(clean, 0, R, 0)
    checks += _check('hamming74 runs four lanes independently and cleanly',
                     fault == 0 and result == clean and (aux & 0xF) == 0
                     and ((aux >> 12) & 0xF) == 0xF and ((aux >> 24) & 0xF) == 0)
    result, aux, fault, _ = _h_model(clean ^ 0x00000300, 0, R, 0)
    damaged = clean ^ 0x00000300
    checks += _check('hamming74 one double-error lane faults and leaves its data',
                     fault == 1 and ((aux >> 4) & 0xF) == 0 and ((aux >> 8) & 0xF) == 2
                     and ((aux >> 24) & 0xF) == 0
                     and (result & 0x0000FCFF) == (damaged & 0x0000FCFF)
                     and (result & 0x7400) == (damaged & 0x7400))
    _, _, malformed_fault, malformed_state = _h_model(clean, 1 << 9, 0, 12345)
    checks += _check('hamming74 malformed beat faults and holds state',
                     malformed_fault == 1 and malformed_state == 12345)
    return checks


def _minsum_reference(a, b, beta):
    """Textbook offset min-sum, written from the definition, not from the core."""
    messages = []
    for edge in range(8):
        raw = ((a if edge < 4 else b) >> (8 * (edge % 4))) & 0xFF
        messages.append(raw - 256 if raw >= 128 else raw)
    magnitudes, signs = [], []
    for value in messages:
        size = -value if value < 0 else value
        if size == 128:
            size = 127
        magnitudes.append(max(0, size - beta))
        signs.append(1 if value < 0 else 0)
    parity = sum(signs) % 2
    outgoing = []
    for edge in range(8):
        rest = [magnitudes[other] for other in range(8) if other != edge]
        sign = sum(signs[other] for other in range(8) if other != edge) % 2
        outgoing.append((-min(rest) if sign else min(rest)) & 0xFF)
    return magnitudes, signs, parity, outgoing


def _st_ldpc():
    """The two LDPC nodes against the textbook min-sum and posterior rules."""
    checks = 0
    # Textbook anchor: messages 1..8, beta = 0 -> minima 1 and 2, the argmin edge
    # republishes 2 and every other edge republishes 1.
    a = 1 | (2 << 8) | (3 << 16) | (4 << 24)
    b = 5 | (6 << 8) | (7 << 16) | (8 << 24)
    result, aux, fault, state = _cn_model(a, b, R, 0)
    checks += _check('ldpc_cn textbook minima and argmin',
                     (result & 0xFF) == 1 and ((result >> 8) & 0xFF) == 2
                     and ((aux >> 17) & 7) == 0 and ((aux >> 20) & 0xF) == 1
                     and fault == 0)
    outgoing = [(state >> (64 + 8 * edge)) & 0xFF for edge in range(8)]
    checks += _check('ldpc_cn textbook exclude-min vector',
                     outgoing == [2, 1, 1, 1, 1, 1, 1, 1] and (aux & 0xFF) == 1)
    result, aux, fault, state = _cn_model(a, b, 1 | R, 0)
    outgoing = [(state >> (64 + 8 * edge)) & 0xFF for edge in range(8)]
    checks += _check('ldpc_cn offset beta = 1 floors the smallest magnitude',
                     (result & 0xFF) == 0 and ((result >> 8) & 0xFF) == 1
                     and (aux >> 28) & 0xF == 1 and outgoing[0] == 1
                     and outgoing[1] == 0)
    # -128 has no positive counterpart in int8, so its magnitude 128 is both
    # clamped to 127 and reported as a saturation: put it on every edge.
    allneg = 0x80808080
    result, aux, fault, state = _cn_model(allneg, allneg, R, 0)
    checks += _check('ldpc_cn int8 floor -128 saturates and faults',
                     ((result >> 25) & 1) == 1 and fault == 1
                     and (result & 0xFF) == 127 and ((result >> 8) & 0xFF) == 127)
    checks += _check('ldpc_cn -128 on every edge has even sign parity and '
                     'republishes -127 (0x81) on every edge',
                     ((result >> 16) & 0xFF) == 0xFF and ((result >> 24) & 1) == 0
                     and ((aux >> 8) & 0xFF) == 0xFF
                     and [(state >> (64 + 8 * edge)) & 0xFF for edge in range(8)]
                     == [0x81] * 8)
    # one -128 edge among zeros: the clamp is visible only in the flags, the
    # minima stay on the zero edges.
    result, aux, fault, state = _cn_model(0x80, 0, R, 0)
    checks += _check('ldpc_cn clamps a lone -128 without moving the minima',
                     fault == 1 and (result & 0xFF) == 0 and ((result >> 8) & 0xFF) == 0
                     and ((aux >> 28) & 0xF) == 7 and ((aux >> 20) & 0xF) == 7
                     and ((aux >> 17) & 7) == 1)
    rng = Random(0x1D50CC)
    for _ in range(300):
        a, b = _word(rng), _word(rng)
        beta = rng.randrange(16)
        c = beta | (R if rng.random() < 0.3 else 0)
        magnitudes, signs, parity, outgoing = _minsum_reference(a, b, beta)
        ordered = sorted(magnitudes)
        result, aux, fault, state = _cn_model(a, b, c, 0)
        mask = sum(sign << edge for edge, sign in enumerate(signs))
        emitted = [(state >> (64 + 8 * edge)) & 0xFF for edge in range(8)]
        checks += _check('ldpc_cn minima match the definition',
                         (result & 0xFF) == ordered[0]
                         and ((result >> 8) & 0xFF) == ordered[1])
        checks += _check('ldpc_cn sign mask and parity match',
                         ((result >> 16) & 0xFF) == mask and ((result >> 24) & 1) == parity
                         and ((aux >> 16) & 1) == parity)
        checks += _check('ldpc_cn outgoing vector matches exclude-min min-sum',
                         emitted == outgoing
                         and ((aux >> 8) & 0xFF) == sum(1 << edge for edge in range(8)
                                                        if signs[edge] ^ parity))
        checks += _check('ldpc_cn argmin and tie count match',
                         ((aux >> 17) & 7) == magnitudes.index(ordered[0])
                         and ((aux >> 20) & 0xF) == magnitudes.count(ordered[0])
                         and ((aux >> 28) & 0xF) == magnitudes.count(0))
    # variable node: the posterior is the channel LLR plus every message received
    channel, posterior, count = 0x64646464, 100, 4
    result, aux, fault, state = _vn_model(0, channel, R, 0)
    checks += _check('ldpc_vn seed beat starts from the channel LLR',
                    (bit_slice(state, 0, 16) & 0xFFFF) == posterior and fault == 0
                    and (aux & 1) == 0 and ((aux >> 16) & 1) == 1)
    for _ in range(260):
        result, aux, fault, state = _vn_model(0x7F7F7F7F, 0, 0, state)
        posterior = min(32767, posterior + 127)
        count += 4
        checks += _check('ldpc_vn closed form L + sum of messages',
                         bit_slice(state, 0, 16) == (posterior & 0xFFFF)
                         and (result & 0xFF) == (0x7F if posterior > 127 else posterior)
                         and bit_slice(state, 64, 16) == count)
        if posterior == 32767:
            checks += _check('ldpc_vn int16 clamp sets the saturation flag',
                             ((aux >> 4) & 0xF) == 0xF and (aux & 0xF) == 0xF
                             and result == 0x7F7F7F7F and fault == 1
                             and bit_slice(state, 0, 64) == 0x7FFF7FFF7FFF7FFF)
            break
    grid = 0
    for prior in range(-128, 128, 9):
        for message in range(-128, 128, 9):
            total = prior + message
            clamped = 32767 if total > 32767 else (-32768 if total < -32768 else total)
            byte = 0x7F if clamped > 127 else (0x81 if clamped < -127
                                               else (clamped & 0xFF))
            # lane 1 is an independent variable node: its prior is the int8
            # image of -prior and its message the int8 image of message + 1.
            other_prior = s8((-prior) & 0xFF)
            other_message = s8((message + 1) & 0xFF)
            other_total = other_prior + other_message
            other_clamped = 32767 if other_total > 32767 else (
                -32768 if other_total < -32768 else other_total)
            a = (message & 0xFF) | ((message + 1 & 0xFF) << 8)
            b = (prior & 0xFF) | ((-prior & 0xFF) << 8)
            result, aux, fault, state = _vn_model(a, b, R, 0)
            grid += 1
            checks += _check('ldpc_vn saturating adder matches sat16(L + m)',
                             bit_slice(state, 0, 16) == (clamped & 0xFFFF)
                             and (result & 0xFF) == byte
                             and ((aux >> 16) & 1) == (1 if clamped > 0 else 0)
                             and ((aux >> 8) & 1) == (1 if clamped == 0 else 0)
                             and bit_slice(state, 16, 16) == (other_clamped & 0xFFFF))
    _, _, malformed_fault, malformed_state = _vn_model(1, 1, 1 << 10, 4242)
    checks += _check('ldpc_vn malformed beat faults and holds state',
                     malformed_fault == 1 and malformed_state == 4242)
    return checks


# ---------------------------------------------------------------------------
# turbo_alpha_step: brute-force path enumeration over the published trellis.
# ---------------------------------------------------------------------------
def _ta_paths(sections, pin=None):
    """Exact max-log survivors by enumerating every path of the 4-state trellis.

    The graph is the one the core publishes: state i is entered on the input-0
    edge from p0 = i >> 1 and on the input-1 edge from p1 = (i >> 1) + 2, and the
    edge metric for successor i is A_i (input 0) or B_i (input 1).  A restart
    leaves every state at the uninformative 0, so each of the four states is a
    legal origin with metric 0 and the survivor of state i after len(sections)
    sections is the maximum, over ALL valid paths ending in i, of the exact
    integer sum of their edge metrics.  Nothing here is a recursion: it is a
    enumeration, which is what makes it a check on the recursion.  pin=0/1 keeps
    only the paths whose LAST edge carries that input bit, which is how the
    survivor (winner) bit is settled without asking the core.
    """
    length = len(sections)
    best = [None] * 4
    label = [None] * 4
    for code in range(1 << (2 * (length + 1))):
        path = [(code >> (2 * index)) & 3 for index in range(length + 1)]
        valid = True
        for index in range(1, length + 1):
            previous, state = path[index - 1], path[index]
            if previous != (state >> 1) and previous != (state >> 1) + 2:
                valid = False
                break
        if not valid:
            continue
        metric, last = 0, None
        for index in range(1, length + 1):
            state = path[index]
            branch_a, branch_b = sections[index - 1]
            if path[index - 1] == (state >> 1):
                metric += branch_a[state]
                last = 0
            else:
                metric += branch_b[state]
                last = 1
        if pin is not None and last != pin:
            continue
        end = path[length]
        if best[end] is None or metric > best[end]:
            best[end] = metric
            label[end] = last
    return best, label


def _st_turbo():
    """turbo_alpha_step against enumeration, exact integers and a shift test."""
    checks = 0
    # A state whose two candidates come from DIFFERENT predecessors: alpha[0] is
    # very high and alpha[2] is zero, so the input-0 edge wins although B_0 > A_0.
    # A core that reads alpha[i] for both edges gets the opposite answer, so this
    # row is the regression pin for the survivor-bit fix.
    alpha = (20 | (0 << 8) | (0 << 16) | (0 << 24))     # alpha[0] = 20, rest 0
    state = alpha
    branch_a = [-4, 0, 0, 0]
    branch_b = [5, 0, 0, 0]
    a = sum((branch_a[i] & 0xFF) << (8 * i) for i in range(4))
    b = sum((branch_b[i] & 0xFF) << (8 * i) for i in range(4))
    result, aux, fault, _ = _ta_model(a, b, B, state)
    # state 0: p0 = 0 -> 20 + A_0 = 16,  p1 = 2 -> 0 + B_0 = 5  -> the +2 edge LOSES
    # state 1: p0 = 0 -> 20 + A_1 = 20,  p1 = 2 -> 0 + B_1 = 0  -> the +2 edge LOSES
    # state 2/3: both predecessors carry 0 and both branches are 0 -> tie, bit set
    checks += _check('turbo winner bit follows the predecessor, not the branch',
                     fault == 0 and (aux & 0xF) == 0x0C
                     and s8(result & 0xFF) == 16 and s8((result >> 8) & 0xFF) == 20
                     and s8((result >> 16) & 0xFF) == 0 and s8((result >> 24) & 0xFF) == 0)
    result_zero, aux_zero, _, _ = _ta_model(a, b, B, 0)
    checks += _check('turbo winner bit changes with the incoming survivor vector',
                     (aux_zero & 0xF) == 0x0F and (aux & 0xF) != (aux_zero & 0xF)
                     and s8(result_zero & 0xFF) == 5)
    rng = Random(0x1A80BC)
    chains = 0
    for _ in range(900):
        sections = [([rng.randrange(-3, 4) for _ in range(4)],
                     [rng.randrange(-3, 4) for _ in range(4)])
                    for _ in range(3)]
        # every section of the chain must stay inside int8 with a window the
        # normalisation tree leaves alone, otherwise the comparison is vacuous.
        probe = [0, 0, 0, 0]
        tight = True
        for branch_a, branch_b in sections:
            probe = [max(probe[state >> 1] + branch_a[state],
                         probe[((state >> 1) + 2)] + branch_b[state])
                     for state in range(4)]
            if min(probe) < -100 or max(probe) > 100 or max(probe) - min(probe) > 30:
                tight = False
                break
        if not tight:
            continue
        chains += 1
        state = 0
        for index in range(1, 4):
            branch_a, branch_b = sections[index - 1]
            enum, _ = _ta_paths(sections[:index])
            zero, _ = _ta_paths(sections[:index], pin=0)
            one, _ = _ta_paths(sections[:index], pin=1)
            a = sum((branch_a[i] & 0xFF) << (8 * i) for i in range(4))
            b = sum((branch_b[i] & 0xFF) << (8 * i) for i in range(4))
            result, aux, fault, state = _ta_model(a, b, B, state)
            survivors = [s8((result >> (8 * i)) & 0xFF) for i in range(4)]
            checks += _check('turbo survivor equals the enumerated best path',
                             fault == 0 and survivors == enum
                             and ((aux >> 11) & 3) == 0
                             and ((aux >> 24) & 0xFF) == max(enum) - min(enum))
            picks = [0 if (zero[i] is not None and one[i] is not None
                           and zero[i] > one[i]) else 1 for i in range(4)]
            checks += _check('turbo predecessor bits match the enumerated winning edge',
                             (aux & 0xF) == sum(picks[i] << i for i in range(4))
                             and ((aux >> 10) & 1) == (1 if any(
                                 zero[i] == one[i] for i in range(4)) else 0))
            checks += _check('turbo never averages the two candidates',
                             all(survivors[i] == max(zero[i], one[i])
                                 and survivors[i] != (zero[i] + one[i]) // 2
                                 or zero[i] == one[i] for i in range(4)))
        # survivor mode: the window tree may only shift the whole vector, never
        # re-order or re-weight it, so result - enumeration is one constant.
        state = 0
        for index in range(1, 4):
            branch_a, branch_b = sections[index - 1]
            enum, _ = _ta_paths(sections[:index])
            a = sum((branch_a[i] & 0xFF) << (8 * i) for i in range(4))
            b = sum((branch_b[i] & 0xFF) << (8 * i) for i in range(4))
            result, aux, fault, state = _ta_model(a, b, 0, state)
            offsets = set(s8((result >> (8 * i)) & 0xFF) - enum[i] for i in range(4))
            checks += _check('turbo window normalisation is a pure shift',
                             fault == 0 and len(offsets) == 1)
        chains += 1
        if chains >= 12:
            break
    checks += _check('turbo enumeration covered real chains', chains >= 8)
    # Two hand-computed window cases, worked out from the published rule
    # (window > 64 shifts by window - 64, 32 < window <= 64 shifts by the
    # minimum, otherwise untouched) and not from the kernel.  The trellis the
    # core publishes in its own declaration gives state i the predecessors
    # p0 = i >> 1 and p1 = (i >> 1) + 2, so states 0 and 1 BOTH read alpha[0] and
    # alpha[2] and only their branch metrics differ; reading alpha[i] and
    # alpha[i+2] instead is the bug this row used to teach, and the row that
    # follows it is the proof that it is still a live trap.
    alpha = 10 | (20 << 8) | (30 << 16) | (40 << 24)
    branch_a = [0, 0, 50, 0]
    branch_b = [0, 0, 0, 0]
    a = sum((branch_a[i] & 0xFF) << (8 * i) for i in range(4))
    b = sum((branch_b[i] & 0xFF) << (8 * i) for i in range(4))
    result, aux, fault, _ = _ta_model(a, b, 0, alpha)
    # state 0: p0 = 0, p1 = 2 -> max(10 + A_0, 30 + B_0) = max(10, 30) = 30
    # state 1: p0 = 0, p1 = 2 -> max(10 + A_1, 30 + B_1) = max(10, 30) = 30
    # state 2: p0 = 1, p1 = 3 -> max(20 + A_2, 40 + B_2) = max(70, 40) = 70
    # state 3: p0 = 1, p1 = 3 -> max(20 + A_3, 40 + B_3) = max(20, 40) = 40
    # candidates [30, 30, 70, 40] -> min 30, max 70, window 40.  32 < 40 <= 64
    # therefore shifts the whole vector by the minimum 30: [0, 0, 40, 10].
    # The +2 predecessor wins in states 0, 1 and 3 (survivor bits 0b1011 = 0xB),
    # no candidate left int8 and the min-shift band subtracts nothing that
    # saturates, so the saturation count stays 0 and no state ties.
    checks += _check('turbo 32<window<=64 shifts by the minimum',
                     fault == 0 and result == (0 | (0 << 8) | (40 << 16) | (10 << 24))
                     and (aux & 0xF) == 0x0B and ((aux >> 24) & 0xFF) == 40
                     and ((aux >> 11) & 3) == 1 and ((aux >> 10) & 1) == 0
                     and ((aux >> 14) & 0xF) == 0)
    # Closed-form prediction across the WHOLE middle band, derived from integer
    # arithmetic before the core runs: with alpha = [k,k,k,k] every predecessor
    # metric is k, so with A_i = t_i and B_i = t_i - 1 the candidate of state i
    # is exactly k + t_i (the +0 edge wins, no tie, no saturation) and the vector
    # is rebased onto t by the min-shift.  k = -40 and t = [0, w, w//2, w] put the
    # window at exactly w, so w = 33..64 exercises every band entry.
    k = -40
    band = 0
    for w in range(33, 65):
        t = [0, w, w // 2, w]
        cand = [k + x for x in t]
        window = max(cand) - min(cand)
        shift = min(cand) if 32 < window <= 64 else 0
        expected = sum(((x - shift) & 0xFF) << (8 * i) for i, x in enumerate(cand))
        expected_aux = (((window & 0xFF) << 24) | ((1 if max(cand) < 0 else 0) << 13)
                        | (1 << 11) | (1 << 9))
        aa = sum((t[i] & 0xFF) << (8 * i) for i in range(4))
        bb = sum(((t[i] - 1) & 0xFF) << (8 * i) for i in range(4))
        st = sum((k & 0xFF) << (8 * i) for i in range(4))
        out_r, out_x, out_f, out_state = _ta_model(aa, bb, 0, st)
        if (out_f == 0 and out_r == expected and out_x == expected_aux
                and [s8((out_r >> (8 * i)) & 0xFF) for i in range(4)] == t
                and max(s8((out_state >> (8 * i)) & 0xFF) for i in range(4))
                - min(s8((out_state >> (8 * i)) & 0xFF) for i in range(4)) == window
                and min(s8((out_state >> (8 * i)) & 0xFF) for i in range(4)) == 0):
            band += 1
    checks += _check('turbo all 32 windows 33..64 shift by the exact minimum',
                     band == 32)
    # The band edges: window 32 must be left completely alone (bits 11/12 clear,
    # no saturation counted, the survivors are the raw candidates) and window 65
    # must leave the band and shift by window - 64 = 1 instead of by the minimum.
    # The saturation-count nibble is masked out of the comparison because the
    # core's accounting for the window > 64 band is an internal count the
    # declaration does not pin value-for-value; every other aux bit is asserted
    # against a closed form derived from the published rule.
    edge = 0
    for w, expected_shift in ((32, 0), (65, 1)):
        t = [0, w, w // 2, w]
        cand = [k + x for x in t]
        window = max(cand) - min(cand)
        expected = [min(127, max(-128, x - expected_shift)) for x in cand]
        expected_aux = (((window & 0xFF) << 24)
                        | ((1 if max(cand) < 0 else 0) << 13)
                        | ((1 if window > 64 else 0) << 12)
                        | ((1 if window > 32 else 0) << 11) | (1 << 9))
        aa = sum((t[i] & 0xFF) << (8 * i) for i in range(4))
        bb = sum(((t[i] - 1) & 0xFF) << (8 * i) for i in range(4))
        st = sum((k & 0xFF) << (8 * i) for i in range(4))
        out_r, out_x, out_f, _ = _ta_model(aa, bb, 0, st)
        quiet = ((out_x >> 14) & 0xF) == 0 if w == 32 else True
        if (out_f == 0
                and [s8((out_r >> (8 * i)) & 0xFF) for i in range(4)] == expected
                and (out_x & ~(0xF << 14)) == expected_aux and quiet):
            edge += 1
    checks += _check('turbo window 32 untouched and window 65 shifts by w-64',
                     edge == 2)
    branch_a = [0, 0, 0, 0]
    branch_b = [0, 0, 0, 100]
    a = 0
    b = sum((branch_b[i] & 0xFF) << (8 * i) for i in range(4))
    result, aux, fault, _ = _ta_model(a, b, 0, 0)
    # winners = [0, 0, 0, 100], window = 100 > 64 -> subtract 100 - 64 = 36.
    checks += _check('turbo window>64 clips the spread to 64',
                     fault == 0 and result == ((-36 & 0xFF) | ((-36 & 0xFF) << 8)
                                               | ((-36 & 0xFF) << 16) | (64 << 24))
                     and ((aux >> 24) & 0xFF) == 100 and ((aux >> 12) & 1) == 1
                     and ((aux >> 11) & 1) == 1)
    bad_result, bad_aux, bad_fault, bad_state = _ta_model(1, 1, 1 << 12, 777)
    checks += _check('turbo malformed beat faults and holds state',
                     (bad_result, bad_aux, bad_fault, bad_state) == (0, 0, 1, 777))
    return checks


# ---------------------------------------------------------------------------
# puncture_map_r13: the four period-32 keep masks re-derived here from the
# published puncturing rules, then compression / expansion checked as exact
# rank packing and as an exact inverse pair.  Nothing below reads the ROM image
# the core itself builds, so the rule text is the only shared premise.
# ---------------------------------------------------------------------------
def _st_puncture():
    """puncture_map_r13 against the published rate-1/3 keep rules by hand."""
    name = 'puncture_map_r13'
    checks = 0
    kept = []
    for stream in range(4):
        if stream == 0:
            kept.append([j for j in range(32) if j not in (7, 15, 23, 31)])
        elif stream == 1:
            kept.append([j for j in range(32) if j % 4 != 3])
        elif stream == 2:
            kept.append([j for j in range(32) if j % 8 < 4])
        else:
            kept.append([])
    checks += _core_check(
        name, 'the published rules keep 28, 24, 16 and 0 chips',
        [len(p) for p in kept] == [28, 24, 16, 0]
        and kept[0] == [j for j in range(32) if j % 8 != 7])
    # Rank packing: output bit k is the chip of the k-th kept position, counted
    # from position 0.  0x9E3779B9 has chips set exactly at 0,3,4,7,8,9,13,16,17,
    # 20,21,24,26,28,29 so the packing is not a mirror of the input word.
    word = 0x9E3779B9
    packed = 0
    for stream in range(3):
        expected = sum(((word >> p) & 1) << k for k, p in enumerate(kept[stream]))
        result, aux, fault, _ = step(name, word, 0, stream, 0)
        checks += _core_check(
            name, 'stream %d compresses to the rank order of its kept chips' % stream,
            fault == 0 and result == expected and expected != word
            and (aux & 0x3F) == len(kept[stream]) and ((aux >> 6) & 1) == 0
            and ((aux >> 7) & 1) == 0 and ((aux >> 15) & 1) == 0)
        # Depuncture is the exact inverse on the kept subspace: every kept
        # position returns its own chip and every dropped position is an erasure.
        mask = sum(1 << p for p in kept[stream])
        out, aux_x, fault_x, _ = step(name, expected, 0, stream | (1 << 3), 0)
        checks += _core_check(
            name, 'stream %d depuncture is the exact inverse on the kept subspace'
            % stream,
            fault_x == 0 and out == (word & mask)
            and (out & ~mask) == 0 and ((aux_x >> 6) & 1) == 1
            and (aux_x & 0x3F) == len(kept[stream]))
    # Dropped chips are invisible and kept chips are not: two words that differ
    # only at dropped positions must compress to the same word, and a single
    # flipped kept chip must flip exactly the rank of that position.
    dropped = [j for j in range(32) if j not in kept[0]]
    other = word ^ sum(1 << j for j in dropped[:5])
    a_out, _, _, _ = step(name, word, 0, 0, 0)
    b_out, _, _, _ = step(name, other, 0, 0, 0)
    rank_of_13 = kept[0].index(13)
    one_out, one_aux, _, _ = step(name, word ^ (1 << 13), 0, 0, 0)
    checks += _core_check(
        name, 'puncture drops only the masked chips and keeps rank order',
        a_out == b_out and one_out == (a_out ^ (1 << rank_of_13))
        and one_out != a_out and bin(one_out ^ a_out).count('1') == 1
        and (one_aux & 0x3F) == 28)
    # Erasure accounting: aux[15:12] counts kept positions whose input chip is
    # zero, saturating at 15, and it must ignore dropped zeros entirely.
    sparse = sum(1 << p for p in kept[1][:20])          # 20 kept chips set, 4 kept clear
    _, aux_s, _, _ = step(name, sparse, 0, 1, 0)
    zeros_dropped = sum(1 << j for j in dropped)        # every dropped chip zero
    _, aux_d, _, _ = step(name, zeros_dropped, 0, 0, 0)
    checks += _core_check(
        name, 'erasure count is the kept zeros only and saturates at 15',
        ((aux_s >> 12) & 0xF) == 24 - 20 and ((aux_d >> 12) & 0xF) == 0
        and ((aux_d >> 14) & 3) == 0)
    all_kept_clear, _, aux_z, _ = step(name, 0, 0, 0, 0)
    checks += _core_check(
        name, 'an all-zero word saturates the erasure count at 15',
        all_kept_clear == 0 and ((aux_z >> 12) & 0xF) == 15)
    # The empty pattern is illegal: no chip survives, aux[7] says so and the beat
    # faults instead of silently passing the word through.
    z_out, z_aux, z_fault, _ = step(name, word, 0, 3, 0)
    checks += _core_check(
        name, 'the empty pattern faults rather than aliasing to a real mask',
        z_fault == 1 and z_out == 0 and (z_aux & 0x3F) == 0
        and ((z_aux >> 7) & 1) == 1 and ((z_aux >> 6) & 1) == 0)
    # Running totals on the counter beat: three fresh beats count themselves in
    # aux[31:24] and accumulate the kept chips in aux[23:16].
    trace = []
    state = 0
    for beat in range(3):
        result, aux, fault, state = step(name, word, 0, 2, state)
        trace.append((result, aux, fault, state))
    counts = [len(kept[2])] * 3
    checks += _core_check(
        name, 'beats and kept-chip totals accumulate over the threaded state',
        [((t[1] >> 24) & 0xFF) for t in trace] == [1, 2, 3]
        and [((t[1] >> 16) & 0xFF) for t in trace] == [sum(counts[:i + 1])
                                                       for i in range(3)]
        and ((trace[0][1] >> 9) & 1) == 1 and ((trace[1][1] >> 9) & 1) == 0
        and ((trace[1][1] >> 10) & 1) == 1 and ((trace[0][1] >> 10) & 1) == 0
        and all(t[2] == 0 for t in trace))
    _, _, _, restarted = step(name, word, 0, 2 | (1 << 31), state)
    checks += _core_check(
        name, 'restart re-bases the beat counter without touching the crossbar',
        (restarted >> 64) & 0xFFFF == 1 and ((restarted >> 8) & 1) == 1)
    bad_r, bad_x, bad_f, bad_state = step(name, word, 0, 1 << 4, 0xDEADBEEF)
    checks += _core_check(
        name, 'malformed control faults and holds state',
        bad_f == 1 and (bad_r, bad_x) == (0, 0) and bad_state == 0xDEADBEEF)
    return checks


# ---------------------------------------------------------------------------
# interleave_convex: the lane addresses come from the declaration's own formula
# slot_j = (base + j*stride) mod 16, the collision set from elementary number
# theory, and the round trip from the fact that a scatter pass followed by a
# gather pass over the same permutation must return the symbols in lane order.
# ---------------------------------------------------------------------------
def _st_interleave():
    """interleave_convex against the published stride-skew address network."""
    name = 'interleave_convex'
    checks = 0

    def slots(base, stride):
        return [(base + j * stride) % 16 for j in range(4)]

    # Two lanes collide exactly when (i - j) * stride is a multiple of 16 with
    # 1 <= i - j <= 3, and only stride 0 (any multiple) and stride 8 (i - j = 2)
    # satisfy that, which is the illegal convex pattern the core publishes.
    collide = {s for s in range(16) if len(set(slots(0, s))) != 4}
    checks += _core_check(
        name, 'exactly strides 0 and 8 fold two lanes onto one slot',
        collide == {0, 8})

    def pack_bytes(values):
        return sum((v & 0xFF) << (8 * i) for i, v in enumerate(values))

    symbols = [11 + 5 * j for j in range(4)]
    legal = [s for s in range(1, 16) if s not in (8,)]
    for stride in legal:
        addresses = slots(0, stride)
        expected_block = 0
        for j, slot in enumerate(addresses):
            expected_block = (expected_block & ~(0xFF << (8 * slot))) \
                | (symbols[j] << (8 * slot))
        result, aux, fault, state = step(name, pack_bytes(symbols), 0, stride, 0)
        checks += _core_check(
            name, 'stride %d scatters lane j into slot (j*stride) mod 16' % stride,
            fault == 0 and field(state, 0, 127) == expected_block
            and result == (expected_block & 0xFFFFFFFF)
            and field(aux, 0, 3) == 0 and field(aux, 4, 7) == stride
            and field(aux, 12, 12) == (1 if stride % 4 == 0 else 0)
            and field(aux, 13, 13) == 0 and field(aux, 15, 15) == 1
            and field(aux, 24, 31) == sum(symbols) & 0xFF
            and field(state, 224, 227) == 4)
    # A full 16-slot block: base advances by four every scatter beat, so stride 1
    # writes slots 0..3, 4..7, 8..11, 12..15 and stride 5 writes four disjoint
    # cosets; both must touch all sixteen slots exactly once and be invertible.
    for stride in (1, 5):
        plan = [slots(4 * b % 16, stride) for b in range(4)]
        flat = [slot for beat in plan for slot in beat]
        checks += _core_check(
            name, 'stride %d over four beats is a permutation of all 16 slots' % stride,
            sorted(flat) == list(range(16)))
        state = 0
        stored = []
        for beat in range(4):
            symbols = [1 + 16 * beat + j for j in range(4)]
            stored += symbols
            _, _, fault, state = step(name, pack_bytes(symbols), 0,
                                      (R if beat == 0 else 0) | stride, state)
            if fault:
                break
        checks += _core_check(
            name, 'stride %d scatters the whole block without loss' % stride,
            fault == 0 and [field(state, 8 * s, 8 * s + 7) for s in range(16)] == stored)
        # Gather the same permutation back: base has advanced to 0 (mod 16) after
        # four beats, so restart is not needed, and lane order must be restored.
        read = []
        gather_flags = []
        for beat in range(4):
            result, aux, fault, state = step(name, 0, 0, 1 | (stride << 2), state)
            read += [field(result, 8 * j, 8 * j + 7) for j in range(4)]
            gather_flags.append((fault, field(aux, 14, 14), field(aux, 15, 15)))
        checks += _core_check(
            name, 'the matching gather pass returns the symbols in lane order',
            fault == 0 and read == stored
            and gather_flags == [(0, 1, 0)] * 4)
    # Illegal strides fault with no data moved but with the counters alive, which
    # is what keeps a bad pattern from being mistaken for a legal beat.
    seed = step(name, pack_bytes([1, 2, 3, 4]), 0, 1 << 2, 0)[3]
    for stride in (0, 8):
        result, aux, fault, state = step(name, pack_bytes([9, 9, 9, 9]), 0,
                                         stride << 2, seed)
        checks += _core_check(
            name, 'illegal stride %d faults, moves nothing and still counts' % stride,
            fault == 1 and (result, aux) == (0, 0)
            and field(state, 0, 127) == field(seed, 0, 127)
            and field(state, 128, 143) == field(seed, 128, 143) + 1
            and field(state, 224, 227) == field(seed, 224, 227) + 4)
    # Mode 2 is the block reset: nothing moves and the base is held, but the beat
    # counter advances and the touched latch survives because the block is kept.
    held = step(name, pack_bytes([5, 6, 7, 8]), 0, (4 << 2), seed)[3]
    result, aux, fault, state = step(name, pack_bytes([0xFF] * 4), 0, 2, held)
    checks += _core_check(
        name, 'mode 2 holds the block and the base and only advances counters',
        fault == 0 and result == 0 and field(state, 0, 127) == field(held, 0, 127)
        and field(state, 224, 227) == field(held, 224, 227)
        and field(state, 128, 143) == field(held, 128, 143) + 1
        and field(aux, 4, 7) == 0 and field(aux, 11, 11) == 1
        and field(aux, 24, 31) == 0)
    # Malformed beats: mode 3 and a control bit outside the published window.
    for bad in (3, 1 << 6, 1 << 20):
        result, aux, fault, state = step(name, 0x01020304, 0, bad, 0xFEED)
        checks += _core_check(
            name, 'malformed control %d faults and holds state' % bad,
            fault == 1 and (result, aux) == (0, 0) and state == 0xFEED)
    return checks


# ---------------------------------------------------------------------------
# Public gate. Every section below attacks one core from a direction the
# kernel does not take: published polynomials and field facts, exhaustive
# enumeration of a small code or trellis, algebraic invariants (order
# preservation, bijection, round-trip identity) and the three corners this
# project has been burned by before (signed saturation of the most-negative
# code, near-cancellation inside a wide accumulator, restart semantics).
# ---------------------------------------------------------------------------
def selftest():
    """Independent readiness gate: returns the number of checks performed."""
    checks = 0
    checks += _st_structure()
    checks += _st_gf256()
    checks += _st_pe()
    checks += _st_bch()
    checks += _st_rs()
    checks += _st_hamming()
    checks += _st_ldpc()
    checks += _st_turbo()
    checks += _st_conv()
    checks += _st_puncture()
    checks += _st_interleave()
    checks += _st_corners()
    assert checks > 0, 'selftest must perform at least one check'
    return checks


# ---------------------------------------------------------------------------
# Support pieces for the gate: per-core check accounting, a beat runner and a
# two's-complement field extractor that matches the spec field tables.
# ---------------------------------------------------------------------------
_COVER = {}


def _core_check(name, label, condition):
    """Like _check(), but also records that this named core was attacked."""
    if not condition:
        raise AssertionError('fec selftest failed: core %s: %s' % (name, label))
    _COVER[name] = _COVER.get(name, 0) + 1
    return 1


def _run(name, beats, state=0):
    """Thread (a, b, c) beats through one core, keeping the threaded state.

    Returns the list of (result, aux, fault, state_after) tuples so a caller can
    assert on a whole beat sequence instead of a single cone.
    """
    trace = []
    for a, b, c in beats:
        result, aux, fault, state = step(name, a & MASK, b & MASK, c & MASK, state)
        trace.append((result, aux, fault, state))
    return trace


def field(word, lo, hi):
    """Bits [hi:lo] of a 256-bit state or a 32-bit result, as the spec writes them."""
    return (word >> lo) & ((1 << (hi - lo + 1)) - 1)


def sg(word, lo, hi):
    """The same slice read as a signed two's-complement number."""
    value = field(word, lo, hi)
    return value - (1 << (hi - lo + 1)) if (value >> (hi - lo)) & 1 else value


def _sat(value, lo, hi):
    """Two's-complement saturation into [lo, hi]: the reference every
    saturating lane in this family is checked against."""
    return lo if value < lo else (hi if value > hi else value)


def _gf8(value, exponent):
    """alpha^exponent times value in GF(2^8)/0x11D, by long division only.

    Independent of xtime()'s carry shape and of the generated log/antilog ROM:
    the exponentiation is repeated "shift left, reduce modulo 0x11D", which is
    the definition of multiplying by the field element alpha = x.
    """
    element = value & 0xFF
    for _ in range(exponent % 255):
        element = _poly_reduce2(element << 1, POLY8)
    return element


def _st_structure():
    """The family contract itself: one cone per beat, no fabric multiply, and
    every core covered by the gate."""
    checks = 0
    assert FAMILY == 'fec'
    assert len(CORES) == 10 and len(set(e['name'] for e in CORES)) == 10
    assert sorted(e['name'] for e in CORES) == sorted(MODELS)
    assert sorted(e['name'] for e in CORES) == sorted(HEADS)
    assert sorted(e['name'] for e in CORES) == sorted(CANDIDATES)
    checks += 4
    for entry in CORES:
        name = entry['name']
        body = entry['body']
        # The silicon-proven rule: this fabric's multiplier is unsigned, so any
        # `*` or `/` in a generated kernel is a corruption, not a style issue.
        checks += _core_check(name, 'kernel has no `*` operator', '*' not in body)
        checks += _core_check(name, 'kernel has no `/` operator', '/' not in body)
        assert 'posedge' not in body and 'negedge' not in body, name
        assert body.strip() and entry['stateful'], name
        assert 'c[31]' in entry['spec'] or 'restart' in entry['spec'].lower(), name
        # The vectors the board is graded on must be reproducible and wide
        # enough to be independent of each other.
        rows = vectors(name, BOARD_ROWS)
        assert len(rows) == BOARD_ROWS, name
        outputs = set()
        state = 0
        for a, b, c in rows:
            result, aux, fault, state = step(name, a, b, c, state)
            outputs.add((result, aux, fault))
        assert len(outputs) > BOARD_ROWS // 2, (name, len(outputs))
        checks += 1
    return checks


# ---------------------------------------------------------------------------
# Corners: restart semantics, malformed-beat state hold, signed saturation of
# the most-negative code and near-cancellation inside the wide accumulators.
# ---------------------------------------------------------------------------
# Malformed exemplars, read off each spec's control contract (never off the
# model's guard clause): every one of these must return result = aux = 0,
# fault = 1 and leave the threaded state bit-for-bit untouched.
MALFORMED = {
    'bch31_syndrome': [(1 << 31, 0, 0), (0, 0, 1 << 13), (1, 1, 1 << 29)],
    'ldpc_cn_minsum': [(0, 0, 1 << 4), (0, 0, 1 << 20), (1, 1, 1 << 30)],
    'ldpc_vn_update': [(0, 0, 1), (0, 0, 1 << 17), (1, 1, 1 << 29)],
    'rs255_syndrome_acc': [(0, 8, 0), (0, 1 << 20, 0), (0, 4, 1 << 12)],
    'gf256_poly_eval': [(0, 0, 255), (0, 0, 1 << 20), (0, 0, 1 << 8)],
    'convk7_acs16': [(0, 0, 1 << 21), (0, 0, 1 << 8), (1, 1, 1 << 29)],
    'puncture_map_r13': [(0, 0, 1 << 20), (0, 0, 1 << 4), (1, 1, 1 << 30)],
    'turbo_alpha_step': [(0, 0, 1 << 22), (0, 0, 1 << 9), (1, 1, 1 << 29)],
    'hamming74_correct': [(0, 1 << 20, 0), (0, 0, 1 << 15), (1, 1, 1)],
    'interleave_convex': [(0, 0, 3), (0, 0, 1 << 20), (0, 0, 1 << 6)],
}

# Bits a restart beat is documented to remember across the clear: only the
# RS core, which keeps the block it replaces for block-to-block comparison.
RESTART_MEMORY = {
    'rs255_syndrome_acc': ((1 << 10), (0xFFFFFFFF << 96)),
}


def _restart_beats(name, limit=26):
    """Legal c[31]=1 beats taken from this core's own stimulus stream.

    The beat is kept only when it is not malformed from a cleared state, so the
    restart property is measured on beats that actually run the datapath.
    """
    beats = []
    for a, b, c in vectors(name, 400):
        if not (c >> 31) & 1:
            continue
        result, aux, fault, _s = step(name, a, b, c, 0)
        if (result, aux, fault) == (0, 0, 1):
            continue
        beats.append((a, b, c))
        if len(beats) >= limit:
            break
    return beats


def _st_corners():
    """Restart, malformed-beat hold, and the two arithmetic corners."""
    checks = 0
    rng = Random(0xC0FFEE)

    # ---- restart semantics: c[31] must make the incoming state irrelevant ---
    # Property, not a replay: running the same legal beat from an arbitrary
    # dirty state must produce exactly what it produces from a cleared state.
    for name in sorted(MODELS):
        beats = _restart_beats(name)
        assert len(beats) >= 8, (name, len(beats))
        aux_ignore, state_ignore = RESTART_MEMORY.get(name, (0, 0))
        remembered = 0
        for a, b, c in beats:
            want_r, want_x, want_f, want_s = step(name, a, b, c, 0)
            dirty = rng.getrandbits(256)
            if state_ignore:
                # A random 256-bit word is not a legal encoding of the RS
                # counters, so build the dirty state by really running the core.
                dirty = _run(name, [(a, b, 0)], 0)[-1][3]
            got_r, got_x, got_f, got_s = step(name, a, b, c, dirty)
            if state_ignore:
                remembered += 1
                checks += _core_check(
                    name, 'restart saves exactly the block it replaces',
                    field(got_s, 96, 127) == field(dirty, 0, 31)
                    and bit(got_x, 10) == int(field(dirty, 0, 31) == 0)
                    and bit(want_x, 10) == 1)
                want_x &= ~aux_ignore
                got_x &= ~aux_ignore
                want_s &= ~state_ignore
                got_s &= ~state_ignore
            checks += _core_check(
                name, 'c[31] restart ignores the incoming state entirely',
                (got_r, got_x, got_f, got_s) == (want_r, want_x, want_f, want_s))
        checks += _core_check(name, 'restart beats really carried the strobe',
                              all((c >> 31) & 1 for _a, _b, c in beats))
        if state_ignore:
            checks += _core_check(name, 'the remembered field was exercised',
                                  remembered == len(beats))

    # ---- malformed beats: zero outputs, fault raised, state bit-for-bit held --
    for name in sorted(MODELS):
        rows = vectors(name, 64)
        # Warm the core up so the held state is a real, non-trivial value.
        warm = _run(name, [(a, b, c) for a, b, c in rows[:6]])[-1][3]
        for a, b, c in MALFORMED[name]:
            for state in (0, warm, rng.getrandbits(256)):
                result, aux, fault, kept = step(name, a, b, c, state)
                checks += _core_check(
                    name, 'malformed beat returns zero result/aux, faults and holds',
                    (result, aux, fault, kept) == (0, 0, 1, state))
    return checks


# ---------------------------------------------------------------------------
# gf256_poly_eval and rs255_syndrome_acc: the same field, two algorithms the
# kernels do not use (long division for the products, power sums for the
# evaluation), so the ROM image and the xtime walks are checked from outside.
# ---------------------------------------------------------------------------
def _mul256(left, right):
    """GF(2^8)/0x11D product by shift-xor plus long division. Independent of
    xtime(), of gf8_mul() and of the generated log/antilog ROM."""
    raw = 0
    for bit in range(8):
        if (right >> bit) & 1:
            raw ^= left << bit
    return _poly_reduce2(raw, POLY8)


def _alpha_pow(exponent):
    return _gf8(1, exponent)


def _horner_direct(point_log, coefficients, start=0):
    """Direct power-sum evaluation of a coefficient list (highest degree first)
    at alpha^point_log. Horner is the kernel; a power sum is the definition."""
    total = _mul256(start, _alpha_pow(point_log * len(coefficients)))
    for index, coefficient in enumerate(coefficients):
        total ^= _mul256(coefficient,
                         _alpha_pow(point_log * (len(coefficients) - 1 - index)))
    return total


def _st_pe():
    """gf256_poly_eval: Horner against a power sum, plus the k = 0 parity law."""
    name = 'gf256_poly_eval'
    checks = 0
    rng = Random(0x9E0115)
    for k in (0, 1, 2, 7, 97, 128, 253, 254):
        for _ in range(40):
            coefficients = [rng.randrange(256) for _ in range(4)]
            start = rng.randrange(256) if rng.random() < 0.3 else 0
            a = sum(coefficients[i] << (8 * i) for i in range(4))
            result, aux, fault, state = step(name, a, 0, k | (R if start == 0 else 0),
                                             start if start else 0)
            assert fault == 0
            # result[31:24] .. result[7:0] = the chain after 1, 2, 3, 4 steps
            for lag in range(4):
                consumed = 4 - lag
                want = _horner_direct(
                    k, coefficients[:consumed], start)
                checks += _core_check(
                    name, 'Horner step %d equals the power sum' % consumed,
                    field(result, 8 * lag, 8 * lag + 7) == want)
            checks += _core_check(
                name, 'the entered accumulator and k are echoed',
                field(aux, 0, 7) == start and field(aux, 8, 15) == k)
        # A zero accumulator makes every product zero: 0 * anything = 0.
        result, aux, fault, _s = step(name, 0, 0, k | R, 0)
        checks += _core_check(name, 'all-zero coefficients at alpha^%d give 0' % k,
                              result == 0 and fault == 0 and bit(aux, 17) == 1
                              and field(aux, 20, 31) == 4)
    # The published parity law: evaluating a polynomial at x = alpha^0 = 1 is the
    # sum of its coefficients, which in GF(2^8) is their XOR.
    for _ in range(60):
        coefficients = [rng.randrange(256) for _ in range(8)]
        a = sum(coefficients[i] << (8 * i) for i in range(4))
        a2 = sum(coefficients[i] << (8 * (i - 4)) for i in range(4, 8))
        result, _aux, fault, state = step(name, a, 0, R, 0)
        first = 0
        for coefficient in coefficients[:4]:
            first ^= coefficient
        checks += _core_check(name, 'k = 0 first beat is the XOR of c0..c3',
                              fault == 0 and field(result, 0, 7) == first)
        result, _aux, fault, _s = step(name, a2, 0, 0, state)
        second = 0
        for coefficient in coefficients:
            second ^= coefficient
        checks += _core_check(name, 'k = 0 chains across beats',
                              fault == 0 and field(result, 0, 7) == second)
    # A one-coefficient polynomial is its own value at any point, and a single
    # leading coefficient is that coefficient times the evaluation point.
    for k in (0, 3, 100, 254):
        for value in (1, 2, 0x80, 0xFF):
            result, _aux, _f, _s = step(name, value, 0, k | R, 0)
            checks += _core_check(
                name, 'a lone leading coefficient is c0 * x^3 at alpha^%d' % k,
                field(result, 0, 7) == _mul256(value, _alpha_pow(3 * k)))
            checks += _core_check(
                name, 'and the chain shows every power on the way',
                field(result, 24, 31) == value
                and field(result, 16, 23) == _mul256(value, _alpha_pow(k))
                and field(result, 8, 15) == _mul256(value, _alpha_pow(2 * k)))
    # Out-of-range and malformed points: k = 255 has no antilog entry.
    for bad_c in (255, 255 | R, 0x100):
        result, aux, fault, kept = step(name, 0xA5A5A5A5, 0, bad_c, 0x1234)
        checks += _core_check(name, 'k out of range faults and holds',
                              (result, aux, fault, kept) == (0, 0, 1, 0x1234))
    # The 24-bit coefficient count is a saturating accumulator: park it one beat
    # under the ceiling and cancel almost all of it with a restart.
    trace = _run(name, [(0, 0, R | 7)] + [(0, 0, 7)] * 3)
    checks += _core_check(name, 'count advances four coefficients per beat',
                          field(trace[-1][3], 8, 31) == 16
                          and [row[2] for row in trace] == [0, 0, 0, 0])
    saturated = (0xFFFFFF << 8)
    _r, aux, fault, _s = step(name, 0, 0, 7, saturated)
    checks += _core_check(name, 'near the 24-bit ceiling the count saturates, faults',
                          field(aux, 20, 31) == 0xFFF and bit(aux, 19) == 1
                          and fault == 1)
    _r, aux, fault, _s = step(name, 0, 0, R | 7, saturated)
    checks += _core_check(name, 'restart clears the saturated count',
                          field(aux, 20, 31) == 4 and bit(aux, 19) == 0
                          and fault == 0)
    # DIVERGENCE (same shape as the RS count): four coefficients that jump over
    # the 24-bit ceiling wrap to 1, 2 or 3 instead of holding 0xFFFFFF, and the
    # saturation flag and the fault stay low. The spec promises "saturating at
    # 2^24-1, which raises fault", so the pinned expectations below are the
    # WRONG answer, recorded so the gap stays visible instead of being quietly
    # re-expected as correct.
    for previous, wrapped in ((0xFFFFFD, 0x001), (0xFFFFFE, 0x002), (0xFFFFFF, 0xFFF)):
        _r, aux, fault, _s = step(name, 0, 0, 7, previous << 8)
        crossing = previous + 4 > 0xFFFFFF
        checks += _core_check(
            name, 'DIVERGENCE count %d + 4 wraps instead of saturating' % previous,
            field(aux, 20, 31) == wrapped and bit(aux, 19) == int(previous == 0xFFFFFF)
            and fault == int(previous == 0xFFFFFF) and crossing)
    return checks


def _poly_mul256(left, right):
    """Polynomial product over GF(2^8)/0x11D, descending coefficients.

    A coefficient convolution built from the long-division field product, so it
    shares no arithmetic with the xtime chains the kernels use.
    """
    out = [0] * (len(left) + len(right) - 1)
    for i, first in enumerate(left):
        for j, second in enumerate(right):
            out[i + j] ^= _mul256(first, second)
    return out


def _rs_generator():
    """g(x) = product of (x + alpha^i) for i = 0..3: four consecutive roots."""
    generator = [1]
    for i in range(4):
        generator = _poly_mul256(generator, [1, _alpha_pow(i)])
    return generator


def _rs_syndromes(symbols, count=4):
    """S_i = sum_k sym_k * alpha^(i*(N-1-k)): the definition of the fold."""
    total = len(symbols)
    out = []
    for i in range(count):
        value = 0
        for position in range(total):
            value ^= _mul256(symbols[position],
                             _alpha_pow(i * (total - 1 - position)))
        out.append(value)
    return out


def _rs_feed(name, symbols):
    """Run a symbol stream through the core four symbols per beat."""
    beats = []
    for index in range(0, len(symbols), 4):
        chunk = symbols[index:index + 4]
        word = sum(value << (8 * j) for j, value in enumerate(chunk))
        beats.append((word, len(chunk), R if index == 0 else 0))
    return _run(name, beats)


def _st_rs():
    """rs255_syndrome_acc: the fold against the definition, plus the code it is
    built to check (g(x) with roots alpha^0..alpha^3 has minimum distance 5)."""
    name = 'rs255_syndrome_acc'
    checks = 0
    rng = Random(0x5EED255)
    generator = _rs_generator()
    checks += _core_check(name, 'the RS generator has degree 4 and is monic',
                          len(generator) == 5 and generator[0] == 1)
    for i in range(4):
        checks += _core_check(
            name, 'g(alpha^%d) = 0 by direct evaluation' % i,
            _horner_direct(i, generator) == 0)

    # Encoding a message and correcting zero errors returns the same codeword:
    # every codeword m(x)*g(x) must fold to four zero syndromes.
    for _ in range(24):
        message = [rng.randrange(256) for _ in range(12)]
        while message[0] == 0:
            message[0] = rng.randrange(1, 256)
        codeword = _poly_mul256(message, generator)
        result, aux, fault, _s = _rs_feed(name, codeword)[-1]
        checks += _core_check(
            name, 'a codeword of length %d folds to zero syndromes' % len(codeword),
            result == 0 and fault == 0 and bit(aux, 7) == 1
            and field(aux, 0, 3) == 0 and field(aux, 4, 6) == 0
            and field(aux, 16, 31) == len(codeword)
            and bit(aux, 8) == 1)

    # The GF(2) facts: the parity of an all-zero block is zero, and S_0, the
    # fold at alpha^0 = 1, is the XOR of every symbol in the block.
    trace = _rs_feed(name, [0] * 16)
    checks += _core_check(name, 'all-zero block gives zero syndromes and clean',
                          trace[-1][0] == 0 and trace[-1][2] == 0
                          and bit(trace[-1][1], 7) == 1
                          and all(row[2] == 0 for row in trace))
    for _ in range(12):
        symbols = [rng.randrange(256) for _ in range(16)]
        parity = 0
        for symbol in symbols:
            parity ^= symbol
        want = _rs_syndromes(symbols)
        trace = _rs_feed(name, symbols)
        for index in range(3):
            result, _aux, fault, _s = trace[index]
            partial = _rs_syndromes(symbols[:4 * (index + 1)])
            checks += _core_check(
                name, 'every prefix fold equals the power sum',
                fault == 0 and [field(result, 8 * i, 8 * i + 7)
                                for i in range(4)] == partial)
        result, aux, fault, _s = trace[-1]
        checks += _core_check(
            name, 'the finished block equals the power sum and S0 is the XOR',
            [field(result, 8 * i, 8 * i + 7) for i in range(4)] == want
            and field(result, 0, 7) == parity
            and field(aux, 0, 3) == sum(1 << i for i in range(4) if want[i])
            and field(aux, 4, 6) == sum(1 for v in want if v)
            and bit(aux, 7) == int(all(v == 0 for v in want))
            and bit(aux, 8) == int(any(v != 0 for v in want)))

    # Single-symbol impulse: one 1 at stream position p of an N-symbol block
    # gives S_i = alpha^(i*(N-1-p)), so the syndrome vector is different for
    # every position and never zero.
    for n in (16, 12, 8):
        vectors_seen = set()
        for position in range(n):
            symbols = [0] * n
            symbols[position] = 1
            result, aux, fault, _s = _rs_feed(name, symbols)[-1]
            want = _rs_syndromes(symbols)
            got = [field(result, 8 * i, 8 * i + 7) for i in range(4)]
            checks += _core_check(
                name, 'impulse at %d of %d is alpha^%d in S1' %
                (position, n, n - 1 - position),
                fault == 0 and got == want
                and got[1] == _alpha_pow(n - 1 - position)
                and got[0] == 1 and field(aux, 0, 3) == 0b1111)
            vectors_seen.add(result & MASK)
        checks += _core_check(name, '%d single-symbol blocks give %d distinct '
                              'syndrome vectors' % (n, n), len(vectors_seen) == n)

    # The correction contract for a d >= 5 shortened code: every error pattern
    # of weight at most two is detected, and no two of them share a syndrome.
    seen = {}
    for first in range(16):
        for value in (1, 2, 0x80, 0xFF):
            symbols = [0] * 16
            symbols[first] = value
            result = _rs_feed(name, symbols)[-1][0]
            checks += _core_check(name, 'a one-symbol error is detected',
                                  result != 0)
            seen[('S', result)] = (first, value)
    for first in range(16):
        for second in range(first + 1, 16):
            symbols = [0] * 16
            symbols[first] ^= 1
            symbols[second] ^= 1
            result = _rs_feed(name, symbols)[-1][0]
            checks += _core_check(name, 'a two-symbol error is detected too',
                                  result != 0)
            seen[('D', result)] = (first, second)
    checks += _core_check(name, 'every weight <= 2 error pattern is unique',
                          len(seen) == 64 + 120)

    # Tail chunks: b[2:0] counts the live symbols, so a short last beat folds
    # only what it carries and flags itself partial.
    symbols = [rng.randrange(256) for _ in range(11)]
    trace = _rs_feed(name, symbols)
    for index in range(len(trace)):
        result, aux, fault, _s = trace[index]
        live = min(4, len(symbols) - 4 * index)
        want = _rs_syndromes(symbols[:4 * index + live])
        prefix = symbols[:4 * index + live]
        checks += _core_check(
            name, 'partial tail beat folds only its live symbols',
            fault == 0 and bit(aux, 11) == int(live < 4)
            and [field(result, 8 * i, 8 * i + 7) for i in range(4)] == want
            and field(aux, 16, 31) == len(prefix))

    # Wide-accumulator corner: a symbol count driven one symbol per beat so it
    # lands exactly on the 16-bit ceiling, where the spec promises "saturating at
    # 65535, which raises fault": the held count is a real saturation, and the
    # fault follows on every beat that tries to add past it.
    state = 0xFFFA << 32
    counts = []
    for _ in range(6):
        _result, aux, fault, state = step(name, 0x11, 1, 0, state)
        counts.append((field(aux, 16, 31), bit(aux, 12), fault))
    checks += _core_check(
        name, 'the 16-bit count climbs, holds at the ceiling and then faults',
        counts == [(0xFFFB, 0, 0), (0xFFFC, 0, 0), (0xFFFD, 0, 0),
                   (0xFFFE, 0, 0), (0xFFFF, 0, 0), (0xFFFF, 1, 1)])
    # DIVERGENCE, pinned on purpose so it cannot be forgotten: a four-symbol beat
    # that JUMPS over the ceiling (0xFFFC + 4 = 0x10000) is not saturated, it
    # wraps to 0 with fault = 0. Both the spec sentence ("saturating at 65535,
    # which raises fault") and this family's own puncture_map_r13 guard
    # (`total > 0xFFFF - emit`) say a crossing must saturate and raise the fault.
    # Reported, not silently re-expected: the count kernels of rs255_syndrome_acc
    # and gf256_poly_eval need the saturating-compare form.
    for previous, wrapped in ((0xFFFC, 0x0000), (0xFFFD, 0x0001), (0xFFFE, 0x0002)):
        _result, aux, fault, _state = step(name, 0, 4, 0, previous << 32)
        checks += _core_check(
            name, 'DIVERGENCE count %d + 4 wraps instead of saturating' % previous,
            field(aux, 16, 31) == wrapped and bit(aux, 12) == 0 and fault == 0)
    result, aux, fault, _s = step(name, 0x01020304, 4, R, 0xFFFFFFFF << 32)
    folded = _rs_syndromes([4, 3, 2, 1])
    checks += _core_check(name, 'restart rescues a saturated count and folds fresh',
                          fault == 0 and field(aux, 16, 31) == 4
                          and bit(aux, 12) == 0 and bit(aux, 9) == 1
                          and [field(result, 8 * i, 8 * i + 7)
                               for i in range(4)] == folded)
    return checks


# ---------------------------------------------------------------------------
# convk7_acs16: the published generator polynomials first (they are the code
# the stage decodes), then the add-compare-select graph by exhaustive path
# enumeration, which is a different algorithm from the recursion in the core.
# ---------------------------------------------------------------------------
def _conv_encode(bits, taps):
    """Encode one input stream with a list of K-tap generators (tap bit 0 = u_t).

    Straight from the definition of a convolutional encoder: the output of beat
    t is the XOR of the taps over (u_t, u_{t-1}, ..., u_{t-K+1}), and the encoder
    is terminated by K-1 zero inputs.  K comes from the widest tap, not from the
    number of generators.
    """
    constraint = max(tap.bit_length() for tap in taps)
    window = [0] * constraint
    chips = []
    for bit_value in list(bits) + [0] * (constraint - 1):
        window = [bit_value] + window[:-1]
        for tap in taps:
            value = 0
            for position in range(constraint):
                if (tap >> position) & 1:
                    value ^= window[position]
            chips.append(value)
    return chips


def _conv_free_distance(taps):
    """Minimum Hamming weight of a nonzero terminated codeword: a shortest-cycle
    search over the trellis built from the taps (Viterbi-Wesely), no core."""
    constraint = max(tap.bit_length() for tap in taps)
    states = 1 << (constraint - 1)
    edges = []
    for state in range(states):
        for input_bit in (0, 1):
            register = [input_bit] + [(state >> i) & 1
                                      for i in range(constraint - 1)]
            weight = 0
            for tap in taps:
                value = 0
                for position in range(constraint):
                    if (tap >> position) & 1:
                        value ^= register[position]
                weight += value
            successor = ((state << 1) & (states - 1)) | input_bit
            edges.append((state, input_bit, successor, weight))
    # Node = (encoder state, "some input bit was 1"). The free distance is the
    # cheapest round trip out of (0, 0) back to (0, 1).
    start, goal = (0, 0), (0, 1)
    dist = {start: 0}
    frontier = [(0, start)]
    while frontier:
        cost, node = min(frontier, key=lambda row: row[0])
        frontier.remove((cost, node))
        if dist[node] < cost:
            continue
        state, nonzero = node
        for first, input_bit, successor, weight in edges:
            if first != state:
                continue
            flag = 1 if (nonzero or input_bit) else 0
            target = (successor, flag)
            if target not in dist or dist[target] > cost + weight:
                dist[target] = cost + weight
                frontier.append((cost + weight, target))
    return dist.get(goal)


def _acs_reference(metric, bank_a, bank_b, normalise=True):
    """One ACS stage written from the textbook definition of the unit: add the
    branch metric to each predecessor, keep the larger, subtract the minimum."""
    winners = []
    survivors = []
    clamp = 0
    for j in range(16):
        first = metric[j >> 1] + bank_a[j & 3]
        second = metric[(j >> 1) + 8] + bank_b[j & 3]
        if not 0 <= first <= 255 or not 0 <= second <= 255:
            clamp = 1
        first = _sat(first, 0, 255)
        second = _sat(second, 0, 255)
        winners.append(first if first >= second else second)
        survivors.append(1 if second > first else 0)
    low = min(winners)
    shifted = [value - low for value in winners] if normalise else list(winners)
    return winners, shifted, survivors, clamp, low, max(winners)


def _acs_enumerate(sections):
    """Exact best path metric per state by listing EVERY path of the core's
    16-state graph: state j is entered from j>>1 on the input-0 edge (metric
    A[j&3]) and from (j>>1)+8 on the input-1 edge (metric B[j&3])."""
    length = len(sections)
    best = [None] * 16
    for code in range(1 << (4 * (length + 1))):
        path = [(code >> (4 * index)) & 15 for index in range(length + 1)]
        valid = True
        for index in range(1, length + 1):
            previous, state = path[index - 1], path[index]
            if previous != (state >> 1) and previous != (state >> 1) + 8:
                valid = False
                break
        if not valid:
            continue
        metric = 0
        for index in range(1, length + 1):
            state = path[index]
            bank_a, bank_b = sections[index - 1]
            metric += (bank_a if path[index - 1] == (state >> 1) else bank_b)[state & 3]
        if best[path[length]] is None or metric > best[path[length]]:
            best[path[length]] = metric
    return best


def _st_conv():
    """convk7_acs16 against the published generators, enumeration and algebra."""
    name = 'convk7_acs16'
    checks = 0
    # ---- published code constants ----------------------------------------
    g1, g2 = 0o171, 0o133                # IEEE 802.11a / V.35 / Voyager K=7
    checks += _core_check(
        name, 'the documented K=7 rate-1/2 generators are 0o171 and 0o133',
        (g1, g2) == (121, 91) and [g1, g2] == [0b1111001, 0b1011011]
        and popcount(g1) == 5 and popcount(g2) == 5
        and (g1 & 1) and (g2 & 1))
    small = (0o5, 0o7)                   # the textbook constraint length 3 pair
    checks += _core_check(
        name, 'the documented K=3 generators are 0o5 = 101 and 0o7 = 111',
        small == (0b101, 0b111) and len(small) == 2)
    impulse = _conv_encode([1], small)
    checks += _core_check(
        name, 'the K=3 impulse response is the published 11 01 11',
        impulse == [1, 1, 0, 1, 1, 1])
    zero_weight = _conv_encode([0], small)
    checks += _core_check(name, 'the all-zero input encodes to the all-zero block',
                          sum(zero_weight) == 0)

    # Encoding a single 1 with a terminated register must output exactly the
    # generator tap pattern: that is the definition of a convolutional generator.
    def tap_pattern(tap, constraint):
        return [(tap >> position) & 1 for position in range(constraint)]

    seven = _conv_encode([1], [g1, g2])
    checks += _core_check(
        name, 'the K=7 impulse response is the two generator tap patterns',
        [seven[2 * t] for t in range(7)] == tap_pattern(g1, 7)
        and [seven[2 * t + 1] for t in range(7)] == tap_pattern(g2, 7)
        and sum(seven) == 10)
    # Free distance, derived twice by different algorithms (shortest cycle in the
    # trellis, then brute force over every terminated input of length <= 9) and
    # matched against the published numbers: 10 for the IEEE 802.11a / V.35
    # K=7 rate-1/2 code and 5 for the best K=3 (5,7) code.
    def brute(taps, maxlen=8):
        return min(sum(_conv_encode([(value >> index) & 1
                                     for index in range(length)], taps))
                   for length in range(1, maxlen + 1)
                   for value in range(1, 1 << length))

    for label, taps, published in (('K=7 (171,133)', [g1, g2], 10),
                                   ('K=3 (5,7)', list(small), 5),
                                   ('K=5 (25,37)', [0o25, 0o37], 6),
                                   ('K=2 (3,2)', [0o3, 0o2], 3)):
        derived = _conv_free_distance(taps)
        enumerated = brute(taps)
        checks += _core_check(
            name, '%s free distance is the published %d, found two ways' %
            (label, published),
            derived == published and enumerated == published)

    distances = []
    for length in range(2, 10):
        for value in range(1, 1 << length):
            bits = [(value >> index) & 1 for index in range(length)]
            distances.append(sum(_conv_encode(bits, small)))
    checks += _core_check(
        name, 'the K=3 code weight spectrum bottoms out at 5 over %d inputs' %
        len(distances),
        min(distances) == 5
        and len(distances) == sum((1 << l) - 1 for l in range(2, 10)))

    # ---- the add-compare-select stage ------------------------------------
    def bank(values):
        return sum((value & 0xFF) << (8 * index) for index, value in
                   enumerate(values))

    # Every unit must pick the +8 predecessor when its delta is one better.
    result, aux, fault, state = step(name, bank([0] * 4), bank([1] * 4), R, 0)
    checks += _core_check(
        name, 'a strictly better input-1 bank selects it in all sixteen units',
        fault == 0 and field(result, 0, 7) == 1 and field(result, 8, 15) == 1
        and field(result, 16, 23) == 0 and bit(result, 24) == 1
        and field(aux, 0, 15) == 0xFFFF and bit(aux, 16) == 1
        and bit(aux, 17) == 1 and field(aux, 20, 23) == 15
        and field(aux, 24, 31) == 0 and field(state, 0, 127) == 0)
    result, aux, fault, _s = step(name, bank([1] * 4), bank([0] * 4), R, 0)
    checks += _core_check(
        name, 'a strictly better input-0 bank selects it in all sixteen units',
        fault == 0 and field(aux, 0, 15) == 0 and field(result, 0, 7) == 1)
    # Equal banks tie, and a tie always goes to the lower predecessor.
    result, aux, fault, _s = step(name, bank([3] * 4), bank([3] * 4), R, 0)
    checks += _core_check(
        name, 'equal candidates tie to the lower predecessor and flag it',
        fault == 0 and bit(result, 26) == 1 and field(aux, 0, 15) == 0
        and field(result, 0, 7) == 3 and field(result, 8, 15) == 3)

    rng = Random(0x7AC05)
    chains = 0
    for _ in range(60):
        sections = [([rng.randrange(0, 5) for _ in range(4)],
                    [rng.randrange(0, 5) for _ in range(4)])
                    for _ in range(2)]
        # Bypass mode keeps every metric unshifted, so the lane metric is the
        # exact best two-step path: comparison against an enumeration, not a
        # second recursion.
        metric = 0
        for index in (1, 2):
            bank_a, bank_b = sections[index - 1]
            previous = [field(metric, 8 * j, 8 * j + 7) for j in range(16)]
            result, aux, fault, state = step(
                name, bank(bank_a), bank(bank_b), B | (R if index == 1 else 0),
                metric)
            want = _acs_enumerate(sections[:index])
            got = [field(state, 8 * j, 8 * j + 7) for j in range(16)]
            checks += _core_check(
                name, 'bypass lane metric %d equals the enumerated best path' % index,
                fault == 0 and got == want and bit(result, 24) == 0
                and bit(result, 25) == 0)
            checks += _core_check(
                name, 'the increased-lane count matches the enumerated growth',
                field(aux, 24, 31) == sum(1 for j in range(16)
                                          if want[j] > previous[j]))
            metric = state
        chains += 1
    checks += _core_check(name, 'enough two-step trellises were enumerated',
                          chains == 60)

    # Uniform branch shift: adding the same constant to every candidate moves
    # the raw winners by that constant and leaves the normalised vector alone.
    for _ in range(40):
        metric = [rng.randrange(0, 40) for _ in range(16)]
        bank_a = [rng.randrange(0, 20) for _ in range(4)]
        bank_b = [rng.randrange(0, 20) for _ in range(4)]
        base_state = sum(value << (8 * j) for j, value in enumerate(metric))
        for shift in (0, 5, 17):
            result, aux, fault, state = step(
                name, bank([value + shift for value in bank_a]),
                bank([value + shift for value in bank_b]), 0, base_state)
            winners, normalised, survivors, clamp, low, high = _acs_reference(
                metric, bank_a, bank_b)
            checks += _core_check(
                name, 'normalisation is a pure shift: order and spread survive',
                fault == 0 and clamp == 0
                and [field(state, 8 * j, 8 * j + 7) for j in range(16)]
                    == normalised
                and field(result, 0, 7) == low + shift
                and field(result, 8, 15) == high + shift
                and field(result, 16, 23) == high - low
                and field(aux, 0, 15) == sum(s << j for j, s in enumerate(survivors))
                and min(normalised) == 0)

    # The minimum tree and the 8-bit metric range pressure, both hand-computed.
    # A ramp of metrics with zero deltas pushes every unit onto its +8
    # predecessor, so winner j is (j >> 1) + 9: min 9, max 16, spread 7, and the
    # normalised vector is the pair-wise ramp 0, 0, 1, 1, ... 7, 7.
    metric = [j + 1 for j in range(16)]
    base_state = sum(value << (8 * j) for j, value in enumerate(metric))
    result, aux, fault, state = step(name, 0, 0, 0, base_state)
    winners = [(j >> 1) + 9 for j in range(16)]
    checks += _core_check(
        name, 'a metric ramp ranks exactly as the winners say',
        fault == 0 and field(result, 0, 7) == min(winners)
        and field(result, 8, 15) == max(winners)
        and field(result, 16, 23) == max(winners) - min(winners)
        and field(aux, 20, 23) == winners.count(min(winners))
        and field(aux, 0, 15) == 0xFFFF
        and [field(state, 8 * j, 8 * j + 7) for j in range(16)]
            == [value - min(winners) for value in winners])
    # One hot metric (200 in lanes 0 and 1, 0 elsewhere) with zero deltas: the
    # spread is 200, which is over the 127 range-pressure threshold.
    hot = 200                                             # metric lane 0 only
    result, aux, fault, _s = step(name, 0, 0, 0, hot)
    checks += _core_check(
        name, 'spread above 127 raises the range-pressure flag',
        fault == 0 and field(result, 0, 7) == 0 and field(result, 8, 15) == 200
        and field(result, 16, 23) == 200 and bit(aux, 18) == 1
        and field(aux, 20, 23) == 14)

    # Signed saturation corner: the most-negative int8 delta and the top of the
    # unsigned metric range, both clamped and both reported as a fault.
    result, aux, fault, state = step(name, bank([0x80] * 4), bank([0x80] * 4), R, 0)
    checks += _core_check(
        name, 'delta -128 on a zero metric clamps to zero and faults',
        fault == 1 and bit(result, 25) == 1 and field(result, 0, 7) == 0
        and field(state, 0, 127) == 0 and bit(result, 26) == 1)
    top = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF              # 16 metrics of 255
    result, aux, fault, state = step(name, bank([1] * 4), bank([1] * 4), 0, top)
    checks += _core_check(
        name, 'metric 255 plus 1 clamps to 255, faults and normalises to 0',
        fault == 1 and bit(result, 25) == 1 and field(result, 0, 7) == 255
        and field(result, 8, 15) == 255 and field(result, 16, 23) == 0
        and field(state, 0, 127) == 0)

    # Near-cancellation corner: two very different operand pairs that must land
    # on the same candidate value (255 + (-1) = 128 + 126 = 254). Only a correctly
    # sign-extended adder ties them; a truncated one does not. Then one LSB off
    # one operand has to flip exactly the two units that read that lane.
    high_half = sum(255 << (8 * j) for j in range(8))
    low_half = sum(128 << (8 * (8 + j)) for j in range(8))
    tie_state = high_half | low_half
    result, aux, fault, state = step(name, bank([0xFF] * 4), bank([0x7E] * 4),
                                     0, tie_state)
    checks += _core_check(
        name, '255-1 and 128+126 tie at 254 in all sixteen units, no clamp',
        fault == 0 and bit(result, 25) == 0 and bit(result, 26) == 1
        and field(result, 0, 7) == 254 and field(result, 8, 15) == 254
        and field(result, 16, 23) == 0 and field(aux, 0, 15) == 0
        and field(aux, 20, 23) == 15 and field(state, 0, 127) == 0)
    # One LSB off the high half makes units 0 and 1 lose their tie and take the
    # +8 predecessor, while every winner stays at 254: the comparison, not the
    # arithmetic, is what moves.
    result, aux, fault, state = step(name, bank([0xFF] * 4), bank([0x7E] * 4),
                                     0, tie_state ^ 1)
    checks += _core_check(
        name, 'one LSB off lane 0 flips only the decisions of units 0 and 1',
        fault == 0 and bit(result, 25) == 0 and bit(result, 26) == 1
        and field(aux, 0, 15) == 0b0011
        and field(result, 0, 7) == 254 and field(result, 8, 15) == 254
        and field(result, 16, 23) == 0 and field(aux, 20, 23) == 15
        and field(state, 0, 127) == 0)
    # One LSB on ONE predecessor lane (lane 8: 128 -> 129) has to move the winner
    # of the two units that read that predecessor pair and nobody else: min 254,
    # max 255, spread 1, two survivor bits set, fourteen lanes still on the
    # minimum, and the tie flag still up because units 2..15 still tie.
    raised = tie_state + (1 << 64)
    result, aux, fault, state = step(name, bank([0xFF] * 4), bank([0x7E] * 4),
                                     0, raised)
    checks += _core_check(
        name, 'one LSB in one predecessor lane moves exactly one unit pair',
        fault == 0 and field(result, 0, 7) == 254 and field(result, 8, 15) == 255
        and field(result, 16, 23) == 1 and field(aux, 0, 15) == 0b11
        and bit(result, 26) == 1 and field(aux, 20, 23) == 14
        and [field(state, 8 * j, 8 * j + 7) for j in range(16)]
            == [1, 1] + [0] * 14)

    # The visit counter is a real saturating accumulator (one beat at a time).
    state = sum(j << (8 * j) for j in range(16)) | (0xFFFE << 144)
    for _ in range(3):
        result, aux, fault, state = step(name, 0, 0, 0, state)
    checks += _core_check(
        name, 'the 16-bit visit counter saturates and faults',
        field(aux, 19, 19) == 1 and fault == 1
        and field(state, 144, 159) == 0xFFFF)
    result, aux, fault, state = step(name, 0, 0, R, state)
    checks += _core_check(
        name, 'restart clears the saturated visit counter',
        fault == 0 and field(aux, 16, 19) == (1 | (1 << 1)) and bit(aux, 19) == 0
        and field(state, 144, 159) == 1)
    return checks


# ---------------------------------------------------------------------------
# puncture_map_r13: the published period-32 keep rules re-derived from the rule
# text, compression checked as an order-preserving rank map and depuncture as
# its exact inverse.
# ---------------------------------------------------------------------------
def _pu_keep(stream):
    """One period-32 keep mask, written straight from the published rule text.

    This deliberately does not call puncture_image(): the ROM image is one of the
    things under test here, so the rule has to come from the specification.
    """
    keep = 0
    for chip in range(32):
        if (stream == 0 and chip not in (7, 15, 23, 31)
                or stream == 1 and chip % 4 != 3
                or stream == 2 and chip % 8 < 4):
            keep |= 1 << chip
    return keep


def _pu_rank(mask, position):
    """Number of kept chips below this one: the definition of a rank."""
    return popcount(mask & ((1 << position) - 1))


def _pu_pack(word, mask):
    """Independent compression: the kept chips, in increasing chip order, packed
    down to bit 0. Built from the definition of a rank, not from a shift chain."""
    out = rank = 0
    for chip in range(32):
        if (mask >> chip) & 1:
            out |= ((word >> chip) & 1) << rank
            rank += 1
    return out


def _pu_unpack(word, mask):
    """Independent expansion: compressed bit k back into the k-th kept chip slot,
    every punctured position left as the zero chip, i.e. a hard erasure."""
    out = rank = 0
    for chip in range(32):
        if (mask >> chip) & 1:
            out |= ((word >> rank) & 1) << chip
            rank += 1
    return out


def _st_puncture():
    """puncture_map_r13: rank packing, its exact inverse, and its counters."""
    name = 'puncture_map_r13'
    checks = 0
    keeps = [_pu_keep(s) for s in range(4)]

    # The three published rules have closed forms a broken ROM or a broken rank
    # chain cannot reproduce: 0x7F7F7F7F, 0x77777777, 0x0F0F0F0F and the empty
    # pattern, keeping 28, 24, 16 and 0 chips of every 32.
    checks += _core_check(
        name, 'published rules give 0x7F7F7F7F / 0x77777777 / 0x0F0F0F0F / empty',
        keeps == [0x7F7F7F7F, 0x77777777, 0x0F0F0F0F, 0]
        and [popcount(k) for k in keeps] == [28, 24, 16, 0])
    checks += _core_check(
        name, 'stream 0 drops exactly chips 7, 15, 23 and 31',
        [c for c in range(32) if not (keeps[0] >> c) & 1] == [7, 15, 23, 31])
    checks += _core_check(
        name, 'the generated keep-mask ROM equals the published rules',
        puncture_image() == keeps)

    # Kept count, mode flags and the illegal empty pattern, straight off the wire.
    for stream in range(4):
        result, aux, fault, _s = step(name, 0xDEADBEEF, 0, R | stream, 0)
        checks += _core_check(
            name, 'stream %d reports its kept count and faults only when empty' % stream,
            field(aux, 0, 5) == popcount(keeps[stream]) and bit(aux, 6) == 0
            and bit(aux, 7) == (1 if stream == 3 else 0)
            and bit(aux, 8) == 1 and bit(aux, 9) == 1
            and fault == (1 if stream == 3 else 0)
            and (stream == 3 or (result != 0 and field(aux, 12, 15) <= 15)))

    # An empty pattern faults but is NOT a malformed beat: result is zero and the
    # running counters still move on, which is the documented behaviour.
    trace = _run(name, [(0x55555555, 0, R | 3), (0x55555555, 0, 3)])
    checks += _core_check(
        name, 'empty pattern faults, zeroes result and still advances the counters',
        trace[0][2] == 1 and trace[1][2] == 1 and trace[0][0] == 0 and trace[1][0] == 0
        and field(trace[0][3], 64, 79) == 1 and field(trace[1][3], 64, 79) == 2
        and field(trace[1][3], 80, 95) == 0 and bit(trace[0][1], 7) == 1)

    # ---- compression is the rank map: chip p -> 1 << rank(p), or nothing -----
    landed = 0
    for stream in range(3):
        mask = keeps[stream]
        for chip in range(32):
            want = 1 << _pu_rank(mask, chip) if (mask >> chip) & 1 else 0
            result, _aux, fault, _s = step(name, 1 << chip, 0, R | stream, 0)
            landed += 1 if (fault == 0 and result == want
                            and _pu_pack(1 << chip, mask) == want) else 0
    checks += _core_check(name, 'all 96 single-chip impulses land on their rank',
                          landed == 96)
    # ---- order preservation and the exact inverse, over 36 pattern/word pairs -
    words = (0xDEADBEEF, 0x0000FFFF, 0xF0F0F0F0, 0x0F0F0F0F, 0x80000001,
             0x12345678, 0xFFFFFFFF, 0x00000000, 0x55555555, 0xAAAAAAAA,
             0xC0FFEE00, 0x00FF00FF)
    round_trip = 0
    for stream in range(3):
        mask = keeps[stream]
        for word in words:
            packed, _x1, f1, _s = step(name, word, 0, R | stream, 0)
            back, aux2, f2, _s = step(name, packed, 0, R | 8 | stream, 0)
            # Puncture then depuncture must return exactly the chips the pattern
            # keeps, the packed word must preserve the chip order, and the
            # expansion must leave zeros in the punctured positions.
            round_trip += 1 if (f1 == 0 and f2 == 0
                                and packed == _pu_pack(word, mask)
                                and popcount(packed) == popcount(word & mask)
                                and back == (word & mask)
                                and _pu_unpack(packed, mask) == back
                                and back & ~mask == 0
                                and bit(aux2, 6) == 1
                                and field(aux2, 0, 5) == popcount(mask)) else 0
    checks += _core_check(
        name, 'depuncture is the exact inverse of puncture on 36 pattern/word pairs',
        round_trip == 3 * len(words))

    # ---- aux[15:12]: kept chips read as the zero symbol, saturating at 15 ----
    erasure = 0
    for stream, word in ((0, keeps[0]), (1, keeps[1]), (2, keeps[2]), (2, 0),
                         (2, keeps[2] & ~0x7), (2, keeps[2] & ~0x101), (0, 0),
                         (1, 1), (2, keeps[2] ^ 1), (0, keeps[0] ^ 0x11)):
        mask = keeps[stream]
        _r, aux, fault, _s = step(name, word, 0, R | stream, 0)
        want = min(15, popcount(mask) - popcount(word & mask))
        erasure += 1 if fault == 0 and field(aux, 12, 15) == want else 0
    checks += _core_check(
        name, 'the erasure count is the zero-valued kept chips, clipped at 15',
        erasure == 10)

    # ---- running totals since restart: beats and kept-chip sum ---------------
    trace = _run(name, [(0x11111111, 0, R | 0), (0x22222222, 0, 0),
                        (0x55555555, 0, 1), (0xAAAAAAAA, 0, 1),
                        (0x33333333, 0, R | 0)])
    totals = ((28, 1, 1), (56, 2, 0), (80, 3, 0), (104, 4, 0), (28, 1, 1))
    checks += _core_check(
        name, 'the beat and kept-chip totals accumulate since restart and a second '
              'restart clears them',
        all(fault == 0 and field(aux, 16, 23) == emit and field(aux, 24, 31) == beats
            and field(state, 80, 95) == emit and field(state, 64, 79) == beats
            and bit(aux, 9) == first
            for (emit, beats, first), (result, aux, fault, state)
            in zip(totals, trace)))

    # ---- saturating totals: exact ceiling, then a deliberate overshoot -------
    over = (0xFFFF - 28) << 80
    _r, aux, fault, state = step(name, 0xFFFFFFFF, 0, 0, over)
    checks += _core_check(
        name, 'a total landing exactly on 65535 reports 65535 without faulting',
        fault == 0 and field(aux, 16, 23) == 0xFF and field(state, 80, 95) == 0xFFFF)
    _r, aux, fault, state = step(name, 0xFFFFFFFF, 0, 0, state)
    checks += _core_check(
        name, 'the kept-chip total clips at 65535 instead of wrapping',
        fault == 0 and field(state, 80, 95) == 0xFFFF and field(aux, 16, 23) == 0xFF)
    _r, aux, fault, state = step(name, 0xFFFFFFFF, 0, 0, (0xFFFF - 3) << 80)
    checks += _core_check(
        name, 'a 28-chip beat overshooting the ceiling by 25 clips, not wraps',
        fault == 0 and field(state, 80, 95) == 0xFFFF and field(aux, 16, 23) == 0xFF)

    # ---- the beat counter saturates, faults, and only a restart rescues it ---
    _r, aux, fault, state = step(name, 0, 0, 0, 0xFFFF << 64)
    checks += _core_check(
        name, 'a saturated beat counter stays put and raises fault',
        fault == 1 and field(aux, 24, 31) == 0xFF and field(state, 64, 79) == 0xFFFF
        and bit(aux, 9) == 0)
    _r, aux, fault, state = step(name, 0, 0, R | 0, 0xFFFF << 64)
    checks += _core_check(name, 'c[31] clears the saturated beat counter',
                          fault == 0 and field(state, 64, 79) == 1
                          and bit(aux, 8) == 1)

    # ---- same-word / same-mask flags are comparisons against the real previous
    trace = _run(name, [(0x12345678, 0, R | 1), (0x12345678, 0, 1),
                        (0x12345678, 0, 0)])
    checks += _core_check(
        name, 'the first beat after a restart compares against a cleared previous '
              'word, then repeats report same-word and same-mask',
        bit(trace[0][1], 10) == 0 and bit(trace[0][1], 11) == 0
        and bit(trace[1][1], 10) == 1 and bit(trace[1][1], 11) == 1
        and bit(trace[2][1], 10) == 0 and bit(trace[2][1], 11) == 0)
    return checks


# ---------------------------------------------------------------------------
# interleave_convex: the stride-skew address network attacked with real
# multiplication, set arithmetic (a pass is a permutation exactly when
# gcd(stride, 16) = 1), a whole-block scatter/gather round trip and the
# published stride-1 identity corner.
# ---------------------------------------------------------------------------
def _il_addr(base, stride, lane):
    """This lane's slot: base + lane*stride modulo the 16-slot window."""
    return (base + lane * stride) % 16


def _gcd(left, right):
    while right:
        left, right = right, left % right
    return left


def _st_interleave():
    """interleave_convex: identity map, permutation, collisions, counters."""
    name = 'interleave_convex'
    checks = 0
    symbols = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80,
               0x9A, 0xA5, 0xB6, 0xC7, 0xD8, 0xE9, 0xFA, 0x0B]
    block_words = [sum(symbols[4 * k + j] << (8 * j) for j in range(4))
                   for k in range(4)]

    # ---- the published corner: a stride-1 interleave is the identity map -----
    full = sum(v << (8 * slot) for slot, v in enumerate(symbols))
    ident = 0
    for word in block_words + [0x01020304, 0, 0xFFFFFFFF]:
        result, _aux, fault, _s = step(name, word, 0, R | (1 << 2), full)
        ident += 1 if fault == 0 and result == word else 0
    result, aux, fault, _s = step(name, 0, 0, (1 << 2) | 1, full)
    ident += 1 if (fault == 0 and result == (full & 0xFFFFFFFF)
                   and field(aux, 0, 3) == 0 and field(aux, 4, 7) == 1) else 0
    checks += _core_check(
        name, 'stride 1 scatters lane j into slot j and gathers it back unchanged',
        ident == 8)

    # ---- one whole block, scattered then gathered, for every legal stride ----
    for stride in range(1, 16):
        if stride == 8:
            continue
        beats = [(block_words[k], 0, (R if k == 0 else 0) | (stride << 2))
                 for k in range(4)]
        beats += [(0, 0, (stride << 2) | 1) for _ in range(4)]
        trace = _run(name, beats)
        slots = dict((i, 0) for i in range(16))
        addrn, after, rows = [], [], []
        for k in range(4):
            base = (4 * k) & 15
            row = [_il_addr(base, stride, j) for j in range(4)]
            rows.append(row)
            addrn.append(row[0] | (row[1] << 4) | (row[2] << 8) | (row[3] << 12))
            for j in range(4):
                slots[row[j]] = symbols[4 * k + j]
            after.append(sum(slots[i] << (8 * i) for i in range(16)))
        final = dict(slots)
        distinct = 4 if stride % 4 == 0 else 8
        if _gcd(stride, 16) == 1:
            distinct = 16
        overlap = int(set(rows[0]) == set((4 + s) % 16 for s in rows[0]))
        good = 0
        for k in range(8):
            result, aux, fault, state = trace[k]
            row = rows[k & 3]
            base = (4 * (k & 3)) & 15
            read = [final[s] for s in row]
            want_result = (result if k < 4 else
                           sum(read[j] << (8 * j) for j in range(4)))
            want_sum = (sum(symbols[4 * (k & 3) + j] for j in range(4)) if k < 4
                        else sum(read)) & 0xFF
            want_prev = 0 if k == 0 else addrn[(k - 1) & 3] & 0xFF
            want_block = after[k & 3] if k < 4 else after[3]
            good += 1 if (fault == 0
                          and field(aux, 0, 3) == base
                          and field(aux, 4, 7) == stride
                          and bit(aux, 8) == (1 if k == 0 else 0)
                          and bit(aux, 9) == 0
                          and bit(aux, 10) == (1 if k == 0 else 0)
                          and bit(aux, 11) == (0 if k == 0 else 1)
                          and bit(aux, 12) == (overlap if k < 4 else 0)
                          and bit(aux, 13) == 0
                          and bit(aux, 14) == (1 if k >= 4 else 0)
                          and bit(aux, 15) == (1 if k < 4 else 0)
                          and field(aux, 16, 23) == want_prev
                          and field(aux, 24, 31) == want_sum
                          and result == want_result
                          and field(state, 144, 159) == addrn[k & 3]
                          and field(state, 0, 127) == want_block
                          and field(state, 128, 143) == k + 1
                          and field(state, 224, 227) == ((base + 4) & 15)
                          and field(state, 228, 231) == stride) else 0
        checks += _core_check(
            name, 'stride %d: all 8 beats resolve to base + j*stride mod 16, the '
                  'matching 128-bit write/gather and the documented flags' % stride,
            good == 8)
        # A block pass is a permutation of the sixteen symbols exactly when the
        # stride is coprime with the window; otherwise whole lanes are lost.
        cover = len(set(s for row in rows for s in row))
        used = set(s for row in rows for s in row)
        round_trip = all(trace[4 + k][0] == block_words[k] for k in range(4))
        checks += _core_check(
            name, 'stride %d: the pass touches %d distinct slots and round-trips '
                  'iff gcd(stride, 16) = 1' % (stride, distinct),
            cover == distinct
            and round_trip == (_gcd(stride, 16) == 1)
            and all(final[s] == 0 for s in range(16) if s not in used))

    # ---- illegal convex patterns: stride 0 and stride 8 fold lanes together --
    for mode in (0, 1):
        for stride in (0, 8):
            trace = _run(name, [(0x11223344, 0, R | (stride << 2) | mode),
                                (0x55667788, 0, (stride << 2) | mode)])
            fold = [(0 if stride == 0 else 8) if j & 1 else 0 for j in range(4)]
            checks += _core_check(
                name, 'stride %d mode %d faults with zero result, yet still advances '
                      'the counters and writes no symbol' % (stride, mode),
                trace[0][:3] == (0, 0, 1) and trace[1][:3] == (0, 0, 1)
                and field(trace[0][3], 0, 127) == 0
                and field(trace[0][3], 128, 143) == 1
                and field(trace[1][3], 128, 143) == 2
                and field(trace[1][3], 224, 227) == 8
                and field(trace[0][3], 144, 159)
                    == (fold[0] | (fold[1] << 4) | (fold[2] << 8) | (fold[3] << 12)))
    checks += _core_check(
        name, 'stride 0 and stride 8 are precisely the strides that fold two lanes of '
              'one beat onto one slot, for every base',
        all(len(set(_il_addr(b, s, j) for j in range(4))) == 4
            for s in range(16) if s not in (0, 8) for b in range(16))
        and all(len(set(_il_addr(b, s, j) for j in range(4))) < 4
                for s in (0, 8) for b in range(16)))

    # ---- mode 2: the block reset that moves nothing --------------------------
    warm = _run(name, [(block_words[k], 0, (R if k == 0 else 0) | (1 << 2))
                       for k in range(4)])[-1][3]
    held = _run(name, [(0x12345678, 0, 2), (0xABCDEF01, 0, (8 << 2) | 2)], warm)
    checks += _core_check(
        name, 'mode 2 never faults on an otherwise illegal stride, moves no symbol, '
              'keeps block and base slot and only counts',
        all(r == 0 and f == 0 for r, _x, f, _s in held)
        and field(held[0][1], 4, 7) == 0 and field(held[1][1], 4, 7) == 8
        and bit(held[0][1], 9) == 0 and bit(held[1][1], 9) == 0
        and bit(held[0][1], 11) == 1 and bit(held[1][1], 11) == 1
        and bit(held[0][1], 12) == 0 and bit(held[0][1], 13) == 0
        and bit(held[0][1], 14) == 0 and bit(held[0][1], 15) == 0
        and field(held[0][1], 24, 31) == 0 and field(held[1][1], 24, 31) == 0
        and all(field(s, 0, 127) == full and field(s, 224, 227) == 0
                for _r, _x, _f, s in held)
        and field(held[0][3], 128, 143) == 5 and field(held[1][3], 128, 143) == 6)
    # A gather after the reset pass reads the same slots, untouched.
    again, aux, fault, _s = step(name, 0, 0, (1 << 2) | 1, held[1][3])
    checks += _core_check(
        name, 'the block reset left the whole permutation readable',
        fault == 0 and again == block_words[0] and field(aux, 0, 3) == 0
        and field(aux, 24, 31) == sum(block_words[0] >> (8 * j) & 0xFF
                                      for j in range(4)) % 256)

    # ---- counters: the beat total saturates and faults, restart rescues ------
    saturated = (0xFFFF << 128) | full
    result, _aux, fault, state = step(name, 0, 0, 1 << 2, saturated)
    checks += _core_check(
        name, 'a saturated beat counter holds at 65535 and raises fault',
        fault == 1 and field(state, 128, 143) == 0xFFFF)
    result, aux, fault, state = step(name, 0x0BEEF00D, 0, R | (1 << 2), saturated)
    checks += _core_check(
        name, 'c[31] clears the sixteen slots, the counter and the base slot',
        fault == 0 and result == 0x0BEEF00D and field(state, 128, 143) == 1
        and field(state, 0, 127) == 0x0BEEF00D and field(state, 224, 227) == 4
        and bit(aux, 8) == 1 and bit(aux, 11) == 0 and bit(aux, 10) == 1)
    return checks
