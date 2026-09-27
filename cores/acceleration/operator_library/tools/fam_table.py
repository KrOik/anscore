"""Generated-table and finite-field kernels: fabric LUTs plus exact integer arithmetic.

Family theme. Every table in this family is built once by tables(name): the
generator writes tables/<core>_<suffix>.mem and injects the synthesizable
$readmemh array, and the Python model below reads the very same function, so a
table cell has exactly one definition. The logic around each table (log reduce,
segment search, dyadic interpolation, probe hashing) is written from the
published specification, and no body contains a multiply or a divide: only
shifts, xors, compares, subtracts and conditional adds. Every core is a
combinational template kernel with latency 1 and II 1.

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
"""
from math import floor
from random import Random

FAMILY = 'table'
MASK = (1 << 32) - 1
BOARD_ROWS = 128

CORES = []


def core(name, spec, body, advantage, lanes, **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body,
                      advantage=advantage, lanes=lanes, **kwargs))


# --------------------------------------------------------------------------
# Table images. The first line of every .mem file is index 0 of the array.
# --------------------------------------------------------------------------
def _xtime(byte):
    """GF(2^8) doubling modulo the AES polynomial x^8+x^4+x^3+x+1 = 0x11B."""
    byte <<= 1
    if byte & 0x100:
        byte ^= 0x11B
    return byte & 0xFF


def _gf_image():
    """256 packed words, word i = (log[i] << 8) | antilog[i], generator 3, 0x11B.

    antilog[i] = 3^i mod 0x11B for i = 0..254 and antilog[255] = antilog[0] = 1,
    because 3 has multiplicative order 255: antilog[0] = 1, antilog[1] = 3,
    antilog[254] = 0xF6. log[x] is the exponent of x for x != 0; log[0] is
    undefined and reads 0, and every kernel masks zero out before using it. One
    image carries both tables because the generator emits a single ROM per core.
    """
    antilog, value = [], 1
    for _ in range(255):
        antilog.append(value)
        value = _xtime(value) ^ value           # multiply by 3 = x + 1
    antilog.append(antilog[0])
    log = [0] * 256
    for index in range(255):
        log[antilog[index]] = index
    return [(log[value] << 8) | antilog[value] for value in range(256)]


def _alaw_segment_image():
    """8 A-law segment descriptors, word s = (mantissa_shift << 12) | base.

    ITU-T G.711 A-law, 13-bit signed linear domain (magnitude 0..4095): segment
    s covers [0,32) for s = 0 and [2^(s+4), 2^(s+5)) above, with step 2 for
    s = 0 and 1 and step 2^s for s >= 2. The expanded magnitude of mantissa m is
    (m << shift[s]) + base[s], and the compressor recovers m with the same
    shift: base[0] = 1, base[s] = 2^(s+4) + 2^(s-1), shift = [1,1,2,3,4,5,6,7],
    giving base = [1,33,66,132,264,528,1056,2112] and the top level 15<<7+2112 =
    4032.
    """
    words = []
    for seg in range(8):
        if seg == 0:
            base, shift = 1, 1
        else:
            base, shift = (1 << (seg + 4)) + (1 << (seg - 1)), seg
        words.append((shift << 12) | base)
    return words


def _ulaw_segment_image():
    """8 mu-law segment ends, 14-bit linear domain, word s = 2^(s+6) - 1.

    Values are the canonical G.711 mu-law boundaries {63,127,255,511,1023,2047,
    4095,8191} (word index 0 is segment 0); the compressor compares the biased
    magnitude |x|+33 against them in order and takes the first segment whose end
    is not exceeded, so 8158 = 8191-33 is the largest representable magnitude.
    """
    return [(1 << (seg + 6)) - 1 for seg in range(8)]


def _gamma_image():
    """16 transfer-curve taps, 12 bit: tap i = round(4095 * (i/15)^2.2).

    Tap 0 is exactly 0 and tap 15 is exactly 4095, so both endpoints of the
    curve are hit without arithmetic: [0,11,49,119,224,365,545,766,1027,1331,
    1678,2070,2506,2989,3518,4095] for indices 0..15.
    """
    return [floor(4095.0 * (index / 15.0) ** 2.2 + 0.5) for index in range(16)]


_IMAGES = {}


def tables(name):
    if name not in _IMAGES:
        if name in ('tab_gf256_mul', 'tab_gf256_inv'):
            _IMAGES[name] = {'gf16': _gf_image()}
        elif name == 'tab_alaw_compand13':
            _IMAGES[name] = {'aseg': _alaw_segment_image()}
        elif name == 'tab_ulaw_compress8':
            _IMAGES[name] = {'useg': _ulaw_segment_image()}
        elif name == 'tab_gamma_lut16':
            _IMAGES[name] = {'gamma': _gamma_image()}
        elif name == 'tab_probe3_cuckoo':
            _IMAGES[name] = {}           # table lives in the state register
        else:
            raise KeyError(name)
    return _IMAGES[name]


def _gf_pair(name):
    image = tables(name)['gf16']
    return [word >> 8 for word in image], [word & 0xFF for word in image]


def _alaw_segments(name):
    image = tables(name)['aseg']
    return [word & 0xFFF for word in image], [word >> 12 for word in image]


# --------------------------------------------------------------------------
# Kernels
# --------------------------------------------------------------------------
core('tab_gf256_mul',
   'One GF(2^8) product per accepted beat in the AES field (reduction polynomial '
   '0x11B, generator 3), taken from a generated 256-word image (word i = '
   '(log[i]<<8) | antilog[i], file line 0 = index 0). Operands are a[7:0] and '
   'b[7:0]; bits a[31:8] and b[31:8] are ignored. result[7:0] = antilog of the '
   'reduced log sum, result[31:8] = 0. aux = log[a]+log[b] before reduction '
   '(0..508), the arithmetic the fabric subtracts 255 from exactly once, since '
   '508 < 2*255. Either operand zero gives result = aux = 0. Declared faultless: '
   'the field has no invalid product, so no fault condition exists and the core '
   'is used as a pure throughput element.',
   """pa = a & 32'hff;
       pb = b & 32'hff;
       if(pa != 0 && pb != 0) begin
           temp = gfmap[pa];
           mask = gfmap[pb];
           pl = (temp >> 8) + (mask >> 8);
           x = pl;
           pc = pl;
           if(pc >= 255) pc = pc - 255;
           r = gfmap[pc] & 32'hff;
       end""",
   'A software multiply is a two-loop shift-xor walk of about 16 iterations, '
   'while this retires a full field product in one enabled beat with two LUT '
   'reads and one conditional subtract, and the log sum stays visible on aux.',
   1, rom={'name': 'gfmap', 'suffix': 'gf16', 'width': 16}, faultless=True)

core('tab_gf256_inv',
   'Four independent GF(2^8) multiplicative inverses per accepted beat, packed '
   'lane 0 = a[7:0] ... lane 3 = a[31:24], using the same generated 256-word '
   'log/antilog image as tab_gf256_mul (word i = (log[i]<<8) | antilog[i], file '
   'line 0 = index 0). For a non-zero byte the inverse is antilog[255-log[byte]]. '
   'Lane k of result[8k+:8] is that inverse and lane k of aux[8k+:8] is the '
   'antilog index 255-log, which is 1..255 (byte 1 maps to index 255). b and c '
   'are ignored. Fault rule: the inverse of zero is undefined, so any zero byte '
   'sets fault and that lane keeps result = aux = 0 while the other lanes still '
   'return their own inverse.',
   """for(lane=0; lane<4; lane=lane+1) begin
           sh = lane << 3;
           pa = (a >> sh) & 32'hff;
           if(pa == 0) f = 1'b1;
           else begin
               temp = gfmap[pa];
               pc = 255 - (temp >> 8);
               r = r | ((gfmap[pc] & 32'hff) << sh);
               x = x | (pc << sh);
           end
       end""",
   'AES/Rijndael SubBytes and the inverse step of elliptic-curve software pay a '
   'table indirection per byte; here four inverses plus their exponents come '
   'back from one fabric-LUT read set every enabled beat at II=1.',
   4, rom={'name': 'gfmap', 'suffix': 'gf16', 'width': 16})

core('tab_alaw_compand13',
   'G.711 A-law compressor and expander in one core, 13-bit signed linear '
   'domain, direction selected by c[31] (1 = compress, 0 = expand); c[30:0] are '
   'ignored. Segment geometry comes from a generated 8-word image (word s = '
   '(mantissa_shift<<12) | base, s = 0..7, file line 0 = segment 0), so the '
   'expander is one table read plus a shift and an add and the compressor is a '
   'priority encoder plus the same table, with no multiplier anywhere. '
   'Compress: the sample is the signed value in a[12:0], magnitude 4096 (reachable '
   'only from -4096) saturates to segment 7 mantissa 15, result[7:0] = the '
   'transmitted code (the natural segment/mantissa byte XOR 0xD5 for a '
   'non-negative sample and XOR 0x55 for a negative one), result[31:8] = 0. '
   'Expand: the code is a[7:0], it is complemented through 0x55 internally, and '
   'result = the sign-extended 13-bit linear value. aux = (positive<<8) | '
   '(segment<<4) | mantissa in both directions, i.e. the natural-code '
   'decomposition of the A-law code involved. Fault rules: compress faults '
   'unless a[31:13] is the sign extension of a[12], expand faults unless a[31:8] '
   'is zero; on a fault result = aux = 0.',
   """if(c[31]) begin
           ext = a[12] ? (a | 32'hffffe000) : (a & 32'h1fff);
           mask = a ^ ext;
           if(mask != 0) f = 1'b1;
           else begin
               pb = a[12];
               ph = pb ? (0 - ext) : ext;
               j = 0;
               for(i=0; i<13; i=i+1) if(ph[i]) j = i;
               idx = (j <= 4) ? 0 : (j - 4);
               if(idx > 7) idx = 7;
               temp = asegmap[idx];
               pl = (ph >> (temp >> 12)) & 32'hf;
               if(ph > 4095) pl = 15;
               pa = (idx << 4) | pl;
               r = pa ^ (pb ? 32'h55 : 32'hd5);
               x = pa | (pb ? 32'h0 : 32'h100);
           end
       end
       else begin
           mask = a & 32'hffffff00;
           if(mask != 0) f = 1'b1;
           else begin
               pa = (a & 32'hff) ^ 32'h55;
               idx = (pa >> 4) & 32'h7;
               pl = pa & 32'hf;
               pb = pa[7];
               temp = asegmap[idx];
               ph = (pl << (temp >> 12)) + (temp & 32'hfff);
               r = pb ? ph : (0 - ph);
               x = (pb << 8) | (idx << 4) | pl;
           end
       end""",
   'A C library does A-law with a search loop over a static table and a branch '
   'per sample; this expands or compresses every enabled beat combinationally, '
   'keeps the segment and mantissa fields on aux for trace, and costs one 8-word '
   'fabric LUT instead of a code table in memory.',
   1, rom={'name': 'asegmap', 'suffix': 'aseg', 'width': 16})

core('tab_ulaw_compress8',
   'G.711 mu-law compressor, 14-bit signed linear input domain, 8-bit code out, '
   'one sample per accepted beat. The sample is the signed value in a[13:0] and '
   'the stored bias is the canonical 33 (= 0x84 >> 2); segment boundaries come from a '
   'generated 8-word image (word s = 2^(s+6)-1, i.e. 63,127,255,511,1023,2047,'
   '4095,8191; file line 0 = segment 0) scanned with compares only, so the '
   'segment is the first end not exceeded by |x|+33 and the mantissa field is '
   'the exact dyadic shift (|x|+33) >> (segment+1): no divide and no multiply. '
   'result[7:0] = ((segment<<4)|mantissa) XOR 0xFF for a non-negative sample and '
   'XOR 0x7F for a negative one (result[31:8] = 0): 0xFF is positive silence, and '
   'because amplitude zero carries no sign, every zero sample encodes as 0xFF '
   'while the expander side reads 0x7F as negative silence. aux = '
   '(negative<<8) | ((segment<<4)|mantissa), and aux[9] marks a magnitude '
   'clamped to 8158, the largest value whose biased sum still fits segment 7. '
   'Fault rule: a[31:14] must be the sign extension of a[13]; otherwise result = '
   'aux = 0 and fault = 1. b and c are ignored.',
   """ext = a[13] ? (a | 32'hffffc000) : (a & 32'h3fff);
       mask = a ^ ext;
       if(mask != 0) f = 1'b1;
       else begin
           pb = a[13];
           ph = pb ? (0 - ext) : ext;
           if(ph > 8158) begin
               ph = 8158;
               x = 1 << 9;
           end
           pa = ph + 33;
           idx = 8;
           for(i=0; i<8; i=i+1)
               if(idx == 8 && pa <= usegmap[i]) idx = i;
           pl = (pa >> (idx + 1)) & 32'hf;
           pc = (idx << 4) | pl;
           r = pc ^ (pb ? 32'h7f : 32'hff);
           x = x | pc | (pb << 8);
       end""",
   'mu-law coding in software is a bias add, a table walk and a magic shift per '
   'sample; the fabric retires one sample every enabled beat and exposes the '
   'segment, mantissa, sign and clamp as a single aux word for verification.',
   1, rom={'name': 'usegmap', 'suffix': 'useg', 'width': 13})

core('tab_gamma_lut16',
   'Interpolated 16-tap transfer curve (12-bit code domain, 12-bit value out) in '
   'one accepted beat. The curve is a generated 16-word image, tap i = '
   'round(4095*(i/15)^2.2), word width 12, file line 0 = tap 0, so tap 0 is '
   'exactly 0 and tap 15 exactly 4095. Inputs: a[3:0] = low tap index, c[4:0] = '
   'sub-step weight w in 0..16 (sixteenths of the way to the next tap), b[11:0] = '
   'black offset added after interpolation. The high tap is index+1, clamped to '
   '15, so index 15 is a flat highlight hold. w = 16 returns the high tap exactly; '
   'for w <= 15 the weight is applied as the dyadic sum of shifted differences, '
   'sum over bit j of w of floor((v1-v0) / 2^(4-j)) - conditional shifts and adds '
   'only, never a product. That sum is monotone in w and at most 3 LSB below the '
   'exact one-sixteenth lerp, because a sum of floors of the leading bits never '
   'exceeds floor(diff*w/16). result = min(v0 + delta + offset, 4095). aux[3:0] = '
   'low tap, aux[7:4] = high tap, aux[8] = weight 16 (endpoint hit), aux[9] = '
   'output clamped to 4095, aux[13:10] = weight[3:0], so aux states exactly which '
   'two taps bracketed the result. Fault rule: a[31:4], c[31:5] and b[31:12] must '
   'be zero and c[4:0] must be <= 16 (17..31 is a malformed weight field); on any '
   'fault result = aux = 0.',
   """if(a[31:4] != 0 || c[31:5] != 0 || b[31:12] != 0 || (c & 32'h1f) > 16) f = 1'b1;
       else begin
           idx = a & 32'hf;
           lane = (idx == 15) ? 15 : (idx + 1);
           pa = gammamap[idx];
           pb = gammamap[lane];
           ph = pb - pa;
           pc = c & 32'h1f;
           pl = 0;
           if(pc == 16) pl = ph;
           else for(i=0; i<4; i=i+1) if(pc[3-i]) pl = pl + (ph >> (i + 1));
           temp = pa + pl + (b & 32'hfff);
           mask = 0;
           if(temp > 4095) begin
               temp = 4095;
               mask = 1 << 9;
           end
           r = temp;
           x = idx | (lane << 4) | ((pc == 16) ? (1 << 8) : 0) | mask | ((pc & 32'hf) << 10);
       end""",
   'A powf() call or a 4096-byte gamma table costs a function call or a memory '
   'round trip per pixel; sixteen LUT taps plus a dyadic shift-add interpolator '
   'give a smooth curve every enabled beat and keep the interpolation bracket '
   'observable.',
   1, rom={'name': 'gammamap', 'suffix': 'gamma', 'width': 12})

core('tab_probe3_cuckoo',
   'Three-probe cuckoo search over an eight-slot table held in the 256-bit state '
   'register: slot s occupies state bits [32s+31 : 32s] (the lowest word is slot '
   '0), bit 31 of a slot = valid, bits [23:16] = stored tag, bits [15:0] = stored '
   'key, bits [30:24] = 0. No table image is generated: the table is loaded by '
   'config beats, which are the beats with c[31] = 1. Probe functions are shifts '
   'and xors only, h0 = key[2:0], h1 = (key>>3 ^ key>>6 ^ key>>9 ^ key>>12) & 7, '
   'h2 = (key>>1 ^ key>>4 ^ key>>7 ^ key>>10 ^ key>>13 ^ key>>15) & 7, tried in '
   'that order. Control: c[31] = 1 and c[30] = 0 inserts key a[15:0] with tag '
   'b[7:0]; if the key already sits in one of its three probes the beat is an '
   'in-place tag refresh, otherwise the key is placed in the first empty probe in '
   'probe order; c[31] = 1 with c[30] = 1 is the restart beat and empties the '
   'whole table (result = aux = 0); c[31] = 0 is a lookup of key a[15:0] with no '
   'state change and b ignored. result[15:0] = the search key (echoed on every '
   'non-faulting beat), result[23:16] = the tag of the matching slot for a lookup '
   'or the tag just stored for an insert and 0 on a lookup miss, result[25:24] = '
   'the probe position that answered, 1..3, 0 for a miss. aux[2:0]/[5:3]/[8:6] = '
   'h0/h1/h2, aux[10:9] = how many of the three probes were empty, aux[13:11] = '
   'how many held a foreign key, aux[20:17] = valid slots in the whole table '
   'before this beat. Fault rules, both of which leave state untouched: an insert '
   'whose three probes are all occupied by foreign keys is a full collision, and '
   'a key wider than the 16-bit search field (a[31:16] != 0) is illegal; either '
   'way result = aux = 0.',
   """pa = a & 32'hffff;
       pb = pa & 32'h7;
       pc = ((pa >> 3) ^ (pa >> 6) ^ (pa >> 9) ^ (pa >> 12)) & 32'h7;
       ph = ((pa >> 1) ^ (pa >> 4) ^ (pa >> 7) ^ (pa >> 10) ^ (pa >> 13) ^ (pa >> 15)) & 32'h7;
       if(a[31:16] != 0) f = 1'b1;
       else if(c[31] && c[30]) begin
           state_n = 0;
       end
       else begin
           j = 0;
           lane = 0;
           idx = 0;
           sh = 0;
           mask = 0;
           for(i=0; i<3; i=i+1) begin
               temp = (i == 0) ? pb : ((i == 1) ? pc : ph);
               temp = state_r[(temp << 5) +: 32];
               if(!temp[31]) begin
                   lane = lane + 1;
                   if(sh == 0) sh = i + 1;
               end
               else if(temp[15:0] != pa) j = j + 1;
               else if(idx == 0) idx = i + 1;
           end
           for(i=0; i<8; i=i+1) if(state_r[(i << 5) + 31]) mask = mask + 1;
           if(c[31] && idx == 0 && sh == 0) f = 1'b1;
           else begin
               x = (ph << 6) | (pc << 3) | pb | (lane << 9) | (j << 11) | (mask << 17);
               if(c[31]) begin
                   if(idx == 0) idx = sh;
                   lane = (idx == 1) ? pb : ((idx == 2) ? pc : ph);
                   state_n[(lane << 5) +: 32] = 32'h80000000 | ((b & 32'hff) << 16) | pa;
                   r = pa | ((b & 32'hff) << 16) | (idx << 24);
               end
               else begin
                   temp = 0;
                   if(idx != 0) begin
                       lane = (idx == 1) ? pb : ((idx == 2) ? pc : ph);
                       temp = state_r[(lane << 5) +: 32];
                   end
                   r = pa | (temp & 32'hff0000) | (idx << 24);
               end
           end
       end""",
   'A software three-probe search is three dependent loads, compares and a branch '
   'chain; this issues all three probe reads, the foreign/empty accounting and the '
   'population count from fabric LUTs and the state word in one enabled beat, with '
   'no multiply and no memory port.',
   1, stateful=True)


# --------------------------------------------------------------------------
# Independent integer models
# --------------------------------------------------------------------------
def _sign_extend(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if (value >> (bits - 1)) & 1 else value


def _is_sign_extended(a, bits):
    """True when a[31:bits] is the replication of a[bits-1], as the RTL checks."""
    want = 0 if not (a >> (bits - 1)) & 1 else (1 << (32 - bits)) - 1
    return (a >> bits) == want


def _m_gf_mul(a, b, state):
    log, antilog = _gf_pair('tab_gf256_mul')
    left, right = a & 0xFF, b & 0xFF
    if left == 0 or right == 0:
        return 0, 0, 0, state
    total = log[left] + log[right]
    return antilog[total % 255], total, 0, state


def _m_gf_inv(a, state):
    log, antilog = _gf_pair('tab_gf256_inv')
    r = x = f = 0
    for lane in range(4):
        byte = (a >> 8 * lane) & 0xFF
        if byte == 0:
            f = 1
            continue
        index = 255 - log[byte]
        r |= antilog[index] << 8 * lane
        x |= index << 8 * lane
    return r, x, f, state


def _m_alaw(a, c, state):
    base, shift = _alaw_segments('tab_alaw_compand13')
    if (c >> 31) & 1:                               # compress
        if not _is_sign_extended(a, 13):
            return 0, 0, 1, state
        sample = _sign_extend(a, 13)
        negative = sample < 0
        magnitude = -sample if negative else sample
        if magnitude > 4095:                        # only -4096 reaches this
            seg, mant = 7, 15
        else:
            seg = 0 if magnitude < 32 else magnitude.bit_length() - 5
            mant = (magnitude >> shift[seg]) & 0xF
        natural = (seg << 4) | mant
        code = natural ^ (0x55 if negative else 0xD5)
        return code, ((0 if negative else 1) << 8) | natural, 0, state
    if a >> 8:                                      # expand, code must be a byte
        return 0, 0, 1, state
    natural = (a & 0xFF) ^ 0x55
    seg, mant = (natural >> 4) & 7, natural & 0xF
    magnitude = (mant << shift[seg]) + base[seg]
    positive = (natural >> 7) & 1
    value = magnitude if positive else -magnitude
    # aux mirrors the RTL field split: the sign lives in bit 8, so the natural
    # code contributes only its segment and mantissa nibbles.
    return value & MASK, (positive << 8) | (natural & 0x7F), 0, state


def _m_ulaw(a, state):
    ends = tables('tab_ulaw_compress8')['useg']
    if not _is_sign_extended(a, 14):
        return 0, 0, 1, state
    sample = _sign_extend(a, 14)
    negative = sample < 0
    magnitude = -sample if negative else sample
    aux = 0
    if magnitude > 8158:
        magnitude = 8158
        aux = 1 << 9
    biased = magnitude + 33
    seg = 7
    for index in range(8):
        if biased <= ends[index]:
            seg = index
            break
    mant = (biased >> (seg + 1)) & 0xF
    natural = (seg << 4) | mant
    code = natural ^ (0x7F if negative else 0xFF)
    return code, aux | ((1 if negative else 0) << 8) | natural, 0, state


def _m_gamma(a, b, c, state):
    taps = tables('tab_gamma_lut16')['gamma']
    weight = c & 0x1F
    if (a >> 4) or (c >> 5) or (b >> 12) or weight > 16:
        return 0, 0, 1, state
    low = a & 0xF
    high = 15 if low == 15 else low + 1
    first, last = taps[low], taps[high]
    difference = last - first
    if weight == 16:
        delta = difference
    else:
        delta = 0
        for bit in range(4):
            if (weight >> bit) & 1:
                delta += difference >> (4 - bit)
    total = first + delta + (b & 0xFFF)
    clamped = total > 4095
    if clamped:
        total = 4095
    aux = low | (high << 4) | ((1 if weight == 16 else 0) << 8) | \
        ((1 if clamped else 0) << 9) | ((weight & 0xF) << 10)
    return total, aux, 0, state


def _probes(key):
    return (key & 7,
            ((key >> 3) ^ (key >> 6) ^ (key >> 9) ^ (key >> 12)) & 7,
            ((key >> 1) ^ (key >> 4) ^ (key >> 7) ^ (key >> 10) ^
             (key >> 13) ^ (key >> 15)) & 7)


def _unpack(state):
    return [(state >> 32 * index) & 0xFFFFFFFF for index in range(8)]


def _pack(slots):
    return sum(word << 32 * index for index, word in enumerate(slots))


def _m_cuckoo(a, b, c, state):
    if a >> 16:                                     # key wider than the field
        return 0, 0, 1, state
    slots = _unpack(state)
    key, tag = a & 0xFFFF, b & 0xFF
    triple = _probes(key)
    empty = foreign = hit = first_free = 0
    for position, slot in enumerate(triple):
        word = slots[slot]
        if not (word >> 31) & 1:
            empty += 1
            if not first_free:
                first_free = position + 1
        elif (word & 0xFFFF) != key:
            foreign += 1
        elif not hit:
            hit = position + 1
    population = sum((word >> 31) & 1 for word in slots)
    aux = (triple[2] << 6) | (triple[1] << 3) | triple[0] | \
        (empty << 9) | (foreign << 11) | (population << 17)
    if (c >> 31) & 1:                               # config beat
        if (c >> 30) & 1:                           # restart: empty the table
            return 0, 0, 0, 0
        if not hit and not first_free:              # full collision
            return 0, 0, 1, state
        position = hit or first_free
        slots[triple[position - 1]] = (1 << 31) | (tag << 16) | key
        return key | (tag << 16) | (position << 24), aux, 0, _pack(slots)
    stored = (slots[triple[hit - 1]] >> 16) & 0xFF if hit else 0
    return key | (stored << 16) | (hit << 24), aux, 0, state


def step(name, a, b, c, state=0):
    if name == 'tab_gf256_mul':
        return _m_gf_mul(a, b, state)
    if name == 'tab_gf256_inv':
        return _m_gf_inv(a, state)
    if name == 'tab_alaw_compand13':
        return _m_alaw(a, c, state)
    if name == 'tab_ulaw_compress8':
        return _m_ulaw(a, state)
    if name == 'tab_gamma_lut16':
        return _m_gamma(a, b, c, state)
    if name == 'tab_probe3_cuckoo':
        return _m_cuckoo(a, b, c, state)
    raise ValueError(name)


# --------------------------------------------------------------------------
# Vector sets: rows 0..127 run verbatim on the board
# --------------------------------------------------------------------------
def _pack4(bytes_of):
    return sum((value & 0xFF) << 8 * lane for lane, value in enumerate(bytes_of))


def _nz(value):
    """Fold any integer into 1..255 so a packed lane never holds the zero byte."""
    return (value % 255) + 1


def _inv_byte(byte, log, antilog):
    return antilog[255 - log[byte]]


def _alaw_level(base, shift, natural):
    """Linear magnitude of a natural A-law code, from the generated descriptors."""
    seg, mant = (natural >> 4) & 7, natural & 0xF
    return (mant << shift[seg]) + base[seg]


def _ulaw_level(natural):
    """Linear magnitude of a natural mu-law code: ((2m+33) << s) - 33."""
    return ((2 * (natural & 0xF) + 33) << ((natural >> 4) & 7)) - 33


def _board_rows(name):
    """The 128 rows the hardware runs: structured, exhaustive and edge cases.

    Row 0 is never all-zero for a ROM core so the testbench re-evaluates the
    combinational block after $readmemh has filled the image.
    """
    rows = []
    if name == 'tab_gf256_mul':
        log, antilog = _gf_pair(name)
        for value in range(40):                     # a*1 walks the field
            rows.append((value, 1, 0))
        for value in range(40, 80):                 # one fixed left operand
            rows.append((0x53, value, 0))
        for value in range(80, 110):                # one fixed right operand
            rows.append((value, 0x8F, 0))
        rows.append((0, 0, 0))                      # zero annihilates
        rows.append((0x5A, 0, 0))
        rows.append((0, 0xC3, 0))
        rows.append((0x57, 0x5A, 0))                # log sum 324: one wrap
        rows.append((0x8F, 0x8F, 0))                # log sum 464: largest wrap
        rows.append((0xFF, 0xFE, 0))                # log sum 119: no wrap
        rows.append((0x53, 0x8D, 0))                # log sum 278
        rows.append((0xC3, 0xC3, 0))                # log sum 288
        for value in (2, 0x57, 0x53, 0x8F):         # a*a^-1 = 1
            rows.append((value, _inv_byte(value, log, antilog), 0))
        rows.append((0x12345657, 0x89ABCD83, 0))    # upper operand bits ignored
        rows.append((0x0000AB57, 0xFFFF0013, 0))
        rows.append((0xDEADBEEF, 0x0BADC0DE, 0))
        rows.append((0x80, 0x80, 0))
        rows.append((0x01, 0xFF, 0))
        rows.append((0xFE, 0x02, 0))
    elif name == 'tab_gf256_inv':
        for value in range(110):                    # four live lanes per row
            rows.append((_pack4([_nz(value), _nz(3 * value + 1),
                                 _nz(7 * value + 2), _nz(11 * value + 3)]),
                         value, 0))
        for value in (1, 2, 3, 0x57, 0x53, 0x8F, 0xFF, 0x80):
            rows.append((value, 0xFFFF_FFFF, 0))    # lane 0 only: other lanes zero
        rows.append((_pack4([1, 2, 3, 4]), 0x5AA5_0000, 0))
        rows.append((_pack4([0x57, 0x8D, 0x53, 0x8F]), 0, 7))
        rows.append((_pack4([0xFF, 0xFE, 0x7F, 0x01]), 0xFFFF_FFFF, 0x8000_0000))
        rows.append((_pack4([0xAA, 0x55, 0xF0, 0x0D]), 0, 1))
        rows.append((_pack4([0x02, 0x00, 0x03, 0x00]), 0, 0))    # zero lanes: fault
        rows.append((_pack4([0x00, 0x00, 0x00, 0x00]), 0, 0))    # all lanes: fault
        rows.append((0x0000_0100, 0xFFFF_FFFF, 0))               # lane 1 only
        rows.append((0x0102_0004, 0, 3))                         # lane 1: fault
        rows.append((0x7F80_6B55, 0, 0))
        rows.append((0xDEAD_BEEF, 0xFFFF_FFFF, 0xFFFF_FFFF))
    elif name == 'tab_alaw_compand13':
        base, shift = _alaw_segments(name)
        rows.append((0xD5, 0, 0))                   # expand silence first
        for code in range(64):                      # expand half the code space
            rows.append((code, 0, 0))
        for code in range(64, 114):                 # compress what those decode to
            natural = code ^ 0x55
            magnitude = _alaw_level(base, shift, natural)
            sample = -magnitude if not (natural >> 7) else magnitude
            rows.append((sample & MASK, 0, 0x8000_0000 | (code & 0xF)))
        rows.append((0, 0, 0x8000_0000))            # silence compress
        rows.append((4095, 0, 0x8000_0000))         # top positive level
        rows.append(((-4096) & MASK, 0, 0x8000_0000))   # saturates to seg 7/15
        rows.append(((-4095) & MASK, 0, 0x8000_0000))
        rows.append((2048, 0, 0x8000_0000))         # segment 7 lower edge
        rows.append(((-2049) & MASK, 0, 0x8000_0000))
        rows.append((40, 0, 0x8000_0000))           # segment 1, mantissa 4
        rows.append((MASK, 0, 0x8000_0000))         # -1: legal, not a fault
        rows.append((0x0000_3FFF, 0, 0x8000_0000))  # sign extension broken: fault
        rows.append((0x0000_2000, 0, 0x8000_0000))  # sign extension broken: fault
        rows.append((0xFFFF_E000, 0, 0x8000_0000))  # sign extension broken: fault
        rows.append((0x0001_00FF, 0, 0))            # expand width: fault
        rows.append((0x00FF_0055, 0, 0))            # expand width: fault
    elif name == 'tab_ulaw_compress8':
        for natural in range(1, 97):                # every natural code, positive
            rows.append((_ulaw_level(natural), 0, 0))
        for natural in range(1, 21):                # the mirrored negative side
            rows.append(((-_ulaw_level(natural)) & MASK, 0, 0))
        rows.append((0, 0, 0))                      # positive silence, code 0xFF
        rows.append((8158, 0, 0))                   # largest unclamped magnitude
        rows.append((8159, 0, 0))                   # first clamped magnitude
        rows.append((8191, 0, 0))                   # clamped, aux[9]
        rows.append(((-8192) & MASK, 0, 0))         # clamped negative
        rows.append(((-8158) & MASK, 0, 0))
        rows.append((31, 0, 0))                     # segment 0/1 boundary
        rows.append((4191, 0, 0))                   # segment 7 first level
        rows.append((0x0000_4000, 0, 0))            # width fault
        rows.append((0x0001_0000, 0, 0))            # width fault
        rows.append((0xFFFF_3FFF, 0, 0))            # width fault
        rows.append((0x0000_FFFF, 0, 0))            # width fault
    elif name == 'tab_gamma_lut16':
        for idx in range(15):
            for weight in (1, 2, 3, 4, 8, 9, 12, 16):
                rows.append((idx, 0, weight))
        rows.append((15, 0x0FF, 0))                 # highlight hold plus offset
        rows.append((14, 0x100, 16))                # exact top tap plus offset
        rows.append((0, 4090, 1))                   # offset drives the clamp
        for bad in ((0x0000_0010, 0, 1),           # index field too wide
                    (0xFFFF_FFFF, 0, 2),            # every field too wide
                    (0, 0, 17),                     # malformed weight field
                    (3, 0, 0x0000_0020),            # weight field too wide
                    (5, 0x0001_0000, 8)):           # offset field too wide
            rows.append(bad)
    elif name == 'tab_probe3_cuckoo':
        rows.append((0x0000, 0x00, 0xC000_0000))    # restart on an empty table
        for key, tag in ((0x0002, 0x2A), (0x004A, 0x4A), (0x0092, 0x92)):
            rows.append((key, tag, 0x8000_0000))    # all three share probes (2,0,1)
        rows.append((0x00DA, 0xDA, 0x8000_0000))    # full collision: fault
        for key in (0x0002, 0x004A, 0x0092, 0x00DA):
            rows.append((key, 0, 0))                # three hits plus one miss
        rows.append((0x0002, 0x77, 0x8000_0000))    # in-place tag refresh
        rows.append((0x0002, 0, 0))
        rows.append((0xFFFF, 0xFF, 0xC000_0000))    # restart again
        for key, tag in ((0x0000, 0x70), (0x0001, 0x71), (0x0100, 0x72),
                         (0x01FF, 0x73), (0x1555, 0x74), (0x2AAA, 0x75),
                         (0x3FFF, 0x76), (0x00FF, 0x77), (0x0011, 0x78),
                         (0x0012, 0x79), (0x0055, 0x7A), (0x0155, 0x7B),
                         (0x02AA, 0x7C)):
            rows.append((key, tag, 0x8000_0000))
        rows.append((0x0001_0000, 0, 0x8000_0000))  # oversized key: fault
        rows.append((0xFFFF_0001, 0, 0))            # oversized key: fault
        rows.append((0x0002_ABCD, 0x11, 0x8000_0000))   # oversized key: fault
        for block in range(10):                     # ten fresh tables, four keys each
            rows.append((0x0000, 0x00, 0xC000_0000))    # restart, then fill
            keys = []
            for lane in range(4):
                key = ((block * 131 + lane * 977) * 3 + 5 + block * 7) & 0xFFFF
                keys.append(key)
                rows.append((key, 0x80 + ((block * 4 + lane) & 0xFF), 0x8000_0000))
            for lane in range(5):                   # hits and misses, unique keys
                rows.append((((block * 259 + lane * 613) * 5 + 11) & 0xFFFF, 0, 0))
    else:
        raise ValueError(name)
    assert len(rows) == BOARD_ROWS, f'{name}: {len(rows)} board rows'
    return rows


def vectors(name, count=320):
    """Structured board set first (rows 0..127), seeded random only afterwards."""
    rows = _board_rows(name)
    rng = Random(0x7AB1E + sum(name.encode()))
    while len(rows) < count:
        if name == 'tab_probe3_cuckoo':
            key = rng.randrange(1 << 16)
            control = 0x8000_0000 if rng.getrandbits(1) else 0
            if rng.getrandbits(3) == 0:
                control |= 0x4000_0000
            rows.append((key, rng.randrange(1 << 8), control))
        elif name == 'tab_alaw_compand13':
            if rng.getrandbits(1):
                rows.append((rng.randrange(-4096, 4096) & MASK, 0, 0x8000_0000))
            else:
                rows.append((rng.randrange(256), rng.getrandbits(32),
                             rng.getrandbits(31)))
        elif name == 'tab_ulaw_compress8':
            rows.append((rng.randrange(-8192, 8192) & MASK, 0, 0)
                        if rng.getrandbits(1) else
                        (rng.getrandbits(32), rng.getrandbits(32), 0))
        elif name == 'tab_gamma_lut16':
            rows.append((rng.randrange(16), rng.randrange(4096), rng.randrange(17)))
        else:
            rows.append((rng.getrandbits(32), rng.getrandbits(32),
                         rng.getrandbits(32)))
    return rows[:count]


# --------------------------------------------------------------------------
# Reference checks against hand-derived values
# --------------------------------------------------------------------------
def _poly_mul(left, right):
    """Direct GF(2^8) shift-xor product modulo 0x11B, independent of any table."""
    product = 0
    for bit in range(8):
        if right & (1 << bit):
            product ^= left << bit
    for bit in range(15, 7, -1):
        if product & (1 << bit):
            product ^= 0x11B << (bit - 8)
    return product & 0xFF


def selftest():
    """Hand-derived expectations for the table images and for every kernel."""
    checks = 0
    log, antilog = _gf_pair('tab_gf256_mul')

    # ---- GF image provenance ----------------------------------------------
    # 3^0 = 1, 3^1 = 3, 3^254 = 0xF6 and 3^255 must be 1 again (order 255).
    assert antilog[0] == 1 and antilog[1] == 3 and antilog[254] == 0xF6
    assert antilog[255] == 1 and len(set(antilog[:255])) == 255
    checks += 2
    # log is the inverse of antilog on 1..255, and 2 = 3^25, 3 = 3^1.
    assert log[1] == 0 and log[3] == 1 and log[2] == 25
    assert all(log[antilog[i]] == i for i in range(255))
    checks += 2
    # Exponents used by the vector set: 0x53 = 3^48, 0x8F = 3^232,
    # 0x57 = 3^98, 0x83 = 3^80, 0x13 = 3^14, 0x5A = 3^226.
    assert (log[0x53], log[0x8F], log[0x57], log[0x83]) == (48, 232, 98, 80)
    assert (log[0x13], log[0x5A]) == (14, 226)
    checks += 2

    # ---- GF multiply against the field definition, exhaustive -------------
    for left in range(256):
        for right in range(256):
            assert step('tab_gf256_mul', left, right, 0)[0] & 0xFF == \
                _poly_mul(left, right), (left, right)
        checks += 1
    # Field identities: a*1 = a, a*0 = 0, both operand orders.
    for value in range(256):
        assert step('tab_gf256_mul', value, 1, 0)[0] == value
        assert step('tab_gf256_mul', 1, value, 0)[0] == value
        assert step('tab_gf256_mul', value, 0, 0)[0] == 0
        assert step('tab_gf256_mul', 0, value, 0)[0] == 0
    checks += 1
    # Hand polynomial long division: {57}*{13} = {57}x^4 ^ {57}x ^ {57} = 0x589,
    # 0x589 ^ 0x11B<<2 ^ 0x11B = 0x0FE. And {57}*{83} reduces 0x2B79 -> 0x0819
    # -> 0x0C1.
    assert step('tab_gf256_mul', 0x57, 0x13, 0)[0] == 0xFE
    assert step('tab_gf256_mul', 0x57, 0x83, 0)[0] == 0xC1
    checks += 2
    # aux is the unreduced log sum and the single conditional subtract:
    # 98+80 = 178 stays put, 98+226 = 324 becomes 69, 232+232 = 464 becomes 209.
    assert step('tab_gf256_mul', 0x57, 0x83, 0)[:2] == (0xC1, 178)
    assert step('tab_gf256_mul', 0x57, 0x5A, 0)[:2] == (antilog[69], 324)
    assert step('tab_gf256_mul', 0x8F, 0x8F, 0)[:2] == (antilog[209], 464)
    assert step('tab_gf256_mul', 1, 1, 0)[:2] == (1, 0)
    checks += 4
    # Upper operand bits are ignored, and the log sum is commutative.
    assert step('tab_gf256_mul', 0x1234_5657, 0x89AB_CD83, 0)[0] == 0xC1
    for value in (0x01, 0x03, 0x7F, 0x80, 0xFF):
        assert step('tab_gf256_mul', value, 0x9C, 0)[1] == \
            step('tab_gf256_mul', 0x9C, value, 0)[1]
    checks += 6
    # Distributivity a*(b^c) = a*b ^ a*c over a hand-built triple set.
    for left in (0x02, 0x57, 0x8D, 0x53, 0xFF):
        for mid in (0x01, 0x4F, 0xC1):
            for right in (0x13, 0x83, 0xAA):
                lhs = step('tab_gf256_mul', left, mid ^ right, 0)[0]
                rhs = step('tab_gf256_mul', left, mid, 0)[0] ^ \
                    step('tab_gf256_mul', left, right, 0)[0]
                assert lhs == rhs, (left, mid, right)
                checks += 1

    # ---- GF inverse -------------------------------------------------------
    # a*a^-1 = 1 for every non-zero element, and the inverse is an involution.
    for value in range(1, 256):
        inverse = step('tab_gf256_inv', value, 0, 0)[0] & 0xFF
        assert step('tab_gf256_mul', value, inverse, 0)[0] == 1
        assert step('tab_gf256_inv', inverse, 0, 0)[0] & 0xFF == value
        checks += 2
    # Hand exponents: 1 = 3^0 so 255-0 = 255 and antilog[255] = 1; 2 = 3^25 so
    # index 230 and 2^-1 = 0x8D; 0x57 = 3^98 so index 157 and inverse 0xBF.
    assert step('tab_gf256_inv', 0x01, 0, 0)[:2] == (0x01, 0xFF)
    assert step('tab_gf256_inv', 0x02, 0, 0)[:2] == (0x8D, 230)
    assert step('tab_gf256_inv', 0x57, 0, 0)[:2] == (0xBF, 157)
    assert _inv_byte(0x02, log, antilog) == 0x8D
    checks += 4
    # Zero is the only undefined lane and it must not poison the other lanes.
    r, x, f, _ = step('tab_gf256_inv', 0x0000_0100, 0xFFFF_FFFF, 7)
    assert (r, x, f) == (0x0000_0100, 0x0000_FF00, 1)
    r, x, f, _ = step('tab_gf256_inv', 0x0000_0000, 0, 0)
    assert (r, x, f) == (0, 0, 1)
    # 0x01020004 = lanes 4, 0, 2, 1: lane 1 is undefined, lanes 0, 2, 3 answer.
    r, x, f, _ = step('tab_gf256_inv', 0x0102_0004, 0, 0)
    assert f == 1 and (r >> 8) & 0xFF == 0 and (x >> 8) & 0xFF == 0
    assert r & 0xFF == _inv_byte(4, log, antilog)
    assert (r >> 16) & 0xFF == 0x8D and (r >> 24) & 0xFF == 0x01
    assert (x >> 16) & 0xFF == 230 and (x >> 24) & 0xFF == 255
    checks += 4
    # All four lanes at once: inverses packed, aux lanes are the indices.
    packed = _pack4([1, 2, 3, 4])
    r, x, f, _ = step('tab_gf256_inv', packed, 0, 0)
    assert f == 0
    for lane, byte in enumerate([1, 2, 3, 4]):
        assert (r >> 8 * lane) & 0xFF == _inv_byte(byte, log, antilog)
        assert (x >> 8 * lane) & 0xFF == 255 - log[byte]
    checks += 1

    # ---- A-law: segment descriptors ---------------------------------------
    base, shift = _alaw_segments('tab_alaw_compand13')
    assert base == [1, 33, 66, 132, 264, 528, 1056, 2112]
    assert shift == [1, 1, 2, 3, 4, 5, 6, 7]
    assert 15 * 128 + 2112 == 4032                     # top A-law level
    checks += 3
    # Hand expansions: silence, both polarities, top level, segment 2.
    assert step('tab_alaw_compand13', 0xD5, 0, 0)[:2] == (1, 0x100)
    assert step('tab_alaw_compand13', 0x55, 0, 0)[:2] == ((-1) & MASK, 0x000)
    assert step('tab_alaw_compand13', 0xAA, 0, 0)[:2] == (4032, 0x17F)
    assert step('tab_alaw_compand13', 0x2A, 0, 0)[:2] == ((-4032) & MASK, 0x07F)
    # 0xFF -> natural 0xAA -> segment 2, mantissa 10 -> 10*4 + 66 = 106.
    assert step('tab_alaw_compand13', 0xFF, 0, 0)[:2] == (106, 0x12A)
    checks += 5
    # Hand compressions: 0 -> D5, 4095 -> AA, -4096 saturates to 2A, -1 -> 55,
    # 40 -> segment 1 mantissa 4 -> natural 0x14 -> C1,
    # 1008 -> segment 5 mantissa 15 -> natural 0x5F -> 8A,
    # -656 -> segment 5 (base 528, step 32), mantissa 4 -> natural 0x54 -> 0x01,
    # the smallest transmitted A-law code.
    assert step('tab_alaw_compand13', 0, 0, 0x8000_0000)[:2] == (0xD5, 0x100)
    assert step('tab_alaw_compand13', 4095, 0, 0x8000_0000)[:2] == (0xAA, 0x17F)
    assert step('tab_alaw_compand13', (-4096) & MASK, 0, 0x8000_0000)[:2] == (0x2A, 0x07F)
    assert step('tab_alaw_compand13', MASK, 0, 0x8000_0000)[:2] == (0x55, 0x000)
    assert step('tab_alaw_compand13', 40, 0, 0x8000_0000)[:2] == (0xC1, 0x114)
    assert step('tab_alaw_compand13', 1008, 0, 0x8000_0000)[:2] == (0x8A, 0x15F)
    assert step('tab_alaw_compand13', (-656) & MASK, 0, 0x8000_0000)[:2] == (0x01, 0x054)
    checks += 7
    # Exhaustive round trip over all 256 codewords, plus sign symmetry: the
    # transmitted code of the negated sample is the code with bit 7 complemented.
    for code in range(256):
        value = step('tab_alaw_compand13', code, 0, 0)[0]
        assert step('tab_alaw_compand13', value, 0, 0x8000_0000)[0] == code
        assert step('tab_alaw_compand13', code ^ 0x80, 0, 0)[0] == (-value) & MASK
        checks += 2
    # Monotone within each segment band, and the reconstruction error never
    # exceeds half the band step (2^(seg-1)) in the 13-bit domain.
    edges = [0, 32, 64, 128, 256, 512, 1024, 2048, 4096]
    for seg in range(8):
        previous = None
        for sample in range(edges[seg], edges[seg + 1]):
            code, natural = step('tab_alaw_compand13', sample, 0, 0x8000_0000)[:2]
            natural &= 0x7F
            value = step('tab_alaw_compand13', code, 0, 0)[0]    # expand it back
            assert natural >> 4 == seg
            assert abs(value - sample) <= (1 << max(seg - 1, 0))
            if previous is not None:
                assert natural >= previous
            previous = natural
        checks += 1
    # Segment boundaries from the G.711 table: [0,32) is segment 0 and every
    # later segment starts at 2^(seg+4).
    for boundary in (31, 32, 63, 64, 127, 128, 255, 256, 511, 512,
                     1023, 1024, 2047, 2048):
        seg = (step('tab_alaw_compand13', boundary, 0, 0x8000_0000)[1] >> 4) & 7
        assert seg == (0 if boundary < 32 else boundary.bit_length() - 5)
        checks += 1
    # Width faults in both directions; 0xFFFFFFFF is the legal sample -1 and
    # 0xFFFFFFF0 the legal sample -16 (13-bit sign extension, so no fault).
    assert step('tab_alaw_compand13', 0x0000_3FFF, 0, 0x8000_0000)[:3] == (0, 0, 1)
    assert step('tab_alaw_compand13', 0x0000_2000, 0, 0x8000_0000)[:3] == (0, 0, 1)
    assert step('tab_alaw_compand13', 0xFFFF_E000, 0, 0x8000_0000)[:3] == (0, 0, 1)
    assert step('tab_alaw_compand13', 0xFFFF_FFF0, 0, 0x8000_0000)[:2] == (0x5D, 0x08)
    assert step('tab_alaw_compand13', 0x0001_0055, 0, 0)[:3] == (0, 0, 1)
    assert step('tab_alaw_compand13', 0x00FF_00D5, 0, 0)[:3] == (0, 0, 1)
    assert step('tab_alaw_compand13', MASK, 0, 0x8000_0000)[2] == 0
    assert step('tab_alaw_compand13', 0xD5, 0, 0)[2] == 0
    assert step('tab_alaw_compand13', 0, 0, 0xFFFF_FFFF)[2] == 0    # c[30:0] ignored
    checks += 8

    # ---- mu-law: descriptors, published levels, exhaustive round trip -----
    ends = tables('tab_ulaw_compress8')['useg']
    assert ends == [63, 127, 255, 511, 1023, 2047, 4095, 8191]
    assert 8158 + 33 == 8191 and 63 * 128 - 33 == 8031
    checks += 2
    # Hand encodings: 0 -> bias 33 -> seg 0 mant 0 -> FF; 1 -> bias 34 -> mant 1
    # -> FE; 30 -> bias 63 -> mant 15 -> F0; 31 -> bias 64 -> seg 1 mant 0 -> EF;
    # 8031 -> bias 8064 -> seg 7 mant 15 -> natural 7F -> 80 (published max);
    # 4191 -> bias 4224 -> seg 7 mant 0 -> natural 70 -> 8F.
    assert step('tab_ulaw_compress8', 0, 0, 0)[:2] == (0xFF, 0x00)
    assert step('tab_ulaw_compress8', 1, 0, 0)[:2] == (0xFE, 0x01)
    assert step('tab_ulaw_compress8', 30, 0, 0)[:2] == (0xF0, 0x0F)
    assert step('tab_ulaw_compress8', 31, 0, 0)[:2] == (0xEF, 0x10)
    assert step('tab_ulaw_compress8', 8031, 0, 0)[:2] == (0x80, 0x7F)
    assert step('tab_ulaw_compress8', 4191, 0, 0)[:2] == (0x8F, 0x70)
    assert step('tab_ulaw_compress8', (-30) & MASK, 0, 0)[:2] == (0x70, 0x10F)
    assert step('tab_ulaw_compress8', (-8031) & MASK, 0, 0)[0] == 0x00
    checks += 8
    # Exhaustive round trip against the published decode law: the transmitted
    # byte is the one-complement of (sign<<7)|(segment<<4)|mantissa, and the
    # magnitude is ((2*mantissa+33) << segment) - 33. 0xFF and 0x7F both have
    # amplitude zero, so the negative-silence code re-encodes as 0xFF.
    for code in range(256):
        raw = code ^ 0xFF
        magnitude = _ulaw_level(raw)
        value = -magnitude if (raw >> 7) & 1 else magnitude
        got = step('tab_ulaw_compress8', value & MASK, 0, 0)[0]
        assert got == (0xFF if code in (0x7F, 0xFF) else code), (code, value, got)
        checks += 1
    # Saturation rule: 8158 is the last magnitude that fits segment 7, so 8159
    # and 8191 clamp and flag on aux[9].
    assert step('tab_ulaw_compress8', 8158, 0, 0)[:2] == (0x80, 0x07F)
    assert step('tab_ulaw_compress8', 8159, 0, 0)[:2] == (0x80, 0x27F)
    assert step('tab_ulaw_compress8', 8191, 0, 0)[:2] == (0x80, 0x27F)
    assert step('tab_ulaw_compress8', (-8192) & MASK, 0, 0)[:2] == (0x00, 0x37F)
    checks += 4
    # Monotone natural code across each segment band. Segment s owns the biased
    # magnitudes (2^(s+6)-1, 2^(s+7)-1], i.e. |x| in [2^(s+6)-34, 2^(s+7)-34],
    # which gives the un-biased band edges below (band 7 stops at the clamp).
    ulaw_edges = [0, 31, 95, 223, 479, 991, 2015, 4063, 8159]
    for seg in range(8):
        previous = None
        for sample in range(ulaw_edges[seg], ulaw_edges[seg + 1]):
            natural = step('tab_ulaw_compress8', sample, 0, 0)[1] & 0x7F
            assert natural >> 4 == seg
            if previous is not None:
                assert natural >= previous
            previous = natural
        checks += 1
    for bad in (0x0000_4000, 0x0000_FFFF, 0x0001_0000, 0xFFFF_3FFF):
        assert step('tab_ulaw_compress8', bad, 0, 0)[:3] == (0, 0, 1)
        checks += 1

    # ---- gamma curve: endpoints, monotonicity, interpolation law ---------
    taps = tables('tab_gamma_lut16')['gamma']
    assert taps[0] == 0 and taps[15] == 4095
    assert taps == [0, 11, 49, 119, 224, 365, 545, 766, 1027, 1331, 1678,
                    2070, 2506, 2989, 3518, 4095]
    assert taps == sorted(taps) and len(set(taps)) == 16
    checks += 3
    # w = 0 lands exactly on the low tap and w = 16 exactly on the high tap;
    # index 15 holds because both taps are 4095.
    for index in range(16):
        assert step('tab_gamma_lut16', index, 0, 0)[0] == taps[index]
        assert step('tab_gamma_lut16', index, 0, 16)[0] == taps[min(index + 1, 15)]
        assert step('tab_gamma_lut16', index, 0, 0)[1] == (index |
                                                           (min(index + 1, 15) << 4))
        checks += 1
    # Dyadic weights, hand-computed for segment 0 (diff = 11):
    # w = 8 -> 11>>1 = 5, w = 4 -> 11>>2 = 2, w = 1 -> 11>>4 = 0,
    # w = 15 -> 0 + 1 + 2 + 5 = 8 while the exact lerp is 11*15/16 = 10.
    assert step('tab_gamma_lut16', 0, 0, 8)[0] == 5
    assert step('tab_gamma_lut16', 0, 0, 4)[0] == 2
    assert step('tab_gamma_lut16', 0, 0, 1)[0] == 0
    assert step('tab_gamma_lut16', 0, 0, 15)[0] == 8
    checks += 4
    # Never above the exact lerp, never more than 3 LSB below it, and monotone.
    previous = None
    for index in range(16):
        for weight in range(17):
            value = step('tab_gamma_lut16', index, 0, weight)[0]
            high = taps[min(index + 1, 15)]
            exact = taps[index] + (high - taps[index]) * weight // 16
            assert 0 <= exact - value <= 3, (index, weight, exact, value)
            if previous is not None:
                assert value >= previous, (index, weight, value, previous)
            previous = value
            checks += 1
    # Black offset and the highlight clamp; aux reports the clamp bit.
    assert step('tab_gamma_lut16', 0, 5, 0)[0] == 5
    assert step('tab_gamma_lut16', 15, 7, 0)[:2] == (4095, 0xFF | (1 << 9))
    assert step('tab_gamma_lut16', 0, 4090, 16)[:2] == (4095, 0x10 | (1 << 8) | (1 << 9))
    assert step('tab_gamma_lut16', 14, 4095, 16)[0] == 4095
    checks += 4
    # Weight field: aux[13:10] echoes w[3:0], aux[8] marks w = 16.
    assert step('tab_gamma_lut16', 3, 0, 12)[1] == 3 | (4 << 4) | (12 << 10)
    assert step('tab_gamma_lut16', 3, 0, 16)[1] == 3 | (4 << 4) | (1 << 8)
    checks += 2
    for bad in ((0x0000_0010, 0, 1), (0xFFFF_FFFF, 0, 2), (0, 0, 17),
                (3, 0, 0x0000_0020), (5, 0x0001_0000, 8), (0, 0x1000, 4)):
        assert step('tab_gamma_lut16', bad[0], bad[1], bad[2])[:3] == (0, 0, 1)
        checks += 1

    # ---- three-probe cuckoo: hand-built collision ------------------------
    # Five keys deliberately share the triple (2,0,1); other probes are hand
    # reductions of the xor/shift hash: 0x0100 -> (0,4,2), 0x1555 -> (5,4,0),
    # 0x00FF -> (7,4,1).
    for key in (0x0002, 0x004A, 0x0092, 0x00DA, 0x2AAA):
        assert _probes(key) == (2, 0, 1)
    assert _probes(0x0100) == (0, 4, 2) and _probes(0x1555) == (5, 4, 0)
    assert _probes(0x00FF) == (7, 4, 1) and _probes(0x0000) == (0, 0, 0)
    checks += 8
    state = 0
    r, x, f, state = step('tab_probe3_cuckoo', 0x0002, 0x2A, 0x8000_0000, state)
    # probes (2,0,1) all empty, placed at probe 1 = slot 2, table was empty.
    assert r == 0x0002 | (0x2A << 16) | (1 << 24)
    assert x == (1 << 6) | (0 << 3) | 2 | (3 << 9)
    assert (x >> 11) & 7 == 0 and (x >> 17) & 0xF == 0 and f == 0
    assert state == ((1 << 31) | (0x2A << 16) | 0x0002) << (32 * 2)
    checks += 4
    r, x, f, state = step('tab_probe3_cuckoo', 0x004A, 0x4A, 0x8000_0000, state)
    # slot 2 holds a foreign key, slot 0 is the first empty probe -> position 2.
    assert r == 0x004A | (0x4A << 16) | (2 << 24)
    assert x == (1 << 6) | 2 | (2 << 9) | (1 << 11) | (1 << 17) and f == 0
    assert state & 0xFFFFFFFF == (1 << 31) | (0x4A << 16) | 0x004A
    checks += 3
    r, x, f, state = step('tab_probe3_cuckoo', 0x0092, 0x92, 0x8000_0000, state)
    assert r >> 24 == 3 and f == 0
    assert x == (1 << 6) | 2 | (1 << 9) | (2 << 11) | (2 << 17)
    checks += 2
    # Fourth key with the same triple: all three probes hold foreign keys, so
    # the beat faults and the table is untouched.
    r, x, f, after = step('tab_probe3_cuckoo', 0x00DA, 0xDA, 0x8000_0000, state)
    assert (r, x, f) == (0, 0, 1) and after == state
    checks += 2
    # The three stored keys stay findable and 0x00DA is a clean miss. Each was
    # inserted at its own probe position, so the tag field must come back.
    for key, want, tag in ((0x0002, 1, 0x2A), (0x004A, 2, 0x4A), (0x0092, 3, 0x92)):
        r, x, f, again = step('tab_probe3_cuckoo', key, 0, 0, state)
        assert (r >> 24) & 3 == want and f == 0 and again == state
        assert (r >> 16) & 0xFF == tag
        assert (x >> 17) & 0xF == 3                     # three valid slots
        checks += 3
    r, x, f, again = step('tab_probe3_cuckoo', 0x00DA, 0, 0, state)
    assert r >> 24 == 0 and (r & 0xFFFF) == 0xDA and f == 0 and again == state
    assert (x >> 11) & 7 == 3 and (x >> 9) & 3 == 0    # three foreign, none empty
    checks += 2
    # Tag refresh is an in-place update at the matching probe, not a new insert.
    r, x, f, refreshed = step('tab_probe3_cuckoo', 0x0002, 0x77, 0x8000_0000, state)
    assert (r >> 24) & 3 == 1 and ((r >> 16) & 0xFF) == 0x77 and f == 0
    assert (refreshed >> (32 * 2)) & 0xFFFFFFFF == (1 << 31) | (0x77 << 16) | 0x0002
    assert refreshed & 0xFFFFFFFF == (1 << 31) | (0x4A << 16) | 0x004A
    checks += 3
    r, x, f, _ = step('tab_probe3_cuckoo', 0x0002, 0, 0, refreshed)
    assert (r >> 16) & 0xFF == 0x77 and (r >> 24) & 3 == 1
    checks += 1
    # Restart empties the table; oversized keys fault without touching state.
    r, x, f, cleared = step('tab_probe3_cuckoo', 0xFFFF, 0xFF, 0xC000_0000, refreshed)
    assert (r, x, f, cleared) == (0, 0, 0, 0)
    r, x, f, same = step('tab_probe3_cuckoo', 0x0001_0000, 0, 0x8000_0000, cleared)
    assert (r, x, f, same) == (0, 0, 1, 0)
    r, x, f, same = step('tab_probe3_cuckoo', 0x8000_0001, 0, 0, cleared)
    assert (r, x, f, same) == (0, 0, 1, 0)
    checks += 3
    # After a fresh restart the first three keys of the collision family take
    # probes 1, 2 and 3, so the fourth one of the same triple finds no free
    # probe and faults even though only three of eight slots are valid.
    for key, tag in ((0x0002, 0xE1), (0x004A, 0xE2), (0x0092, 0xE3)):
        _, _, f, cleared = step('tab_probe3_cuckoo', key, tag, 0x8000_0000, cleared)
        assert f == 0
    r, x, f, same = step('tab_probe3_cuckoo', 0x00DA, 0xE4, 0x8000_0000, cleared)
    assert (r, x, f) == (0, 0, 1) and same == cleared
    checks += 2
    # Empty-table lookup reports three empty probes and no foreign keys.
    r, x, f, _ = step('tab_probe3_cuckoo', 0x00FF, 0, 0, 0)
    assert (x >> 9) & 3 == 3 and (x >> 11) & 7 == 0 and (x >> 17) & 0xF == 0
    assert x & 0xFF == (1 << 6) | (4 << 3) | 7 and r & 0x0300_0000 == 0 and f == 0
    checks += 2
    # Slot addressing: key 0x0001 has probe triple (1,0,0), so it lands in slot 1.
    _, _, _, placed = step('tab_probe3_cuckoo', 0x0001, 0x33, 0x8000_0000, 0)
    assert (placed >> 32) & 0xFFFFFFFF == (1 << 31) | (0x33 << 16) | 0x0001
    assert placed & 0xFFFFFFFF == 0
    checks += 1
    return checks
