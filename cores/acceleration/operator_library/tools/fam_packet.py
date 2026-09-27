"""Packet/stream header and policing engines: per-beat parse, realign and meter.

Six cores for the router/bridge datapath that software pays for with loops.
Byte order everywhere: byte 0 is the LOW byte, so a[7:0] is the first byte of
the packet, a[31:24] the fourth, and halfword 0 is a[15:0].

Body vocabulary (declared by the template, reset each evaluation):
    r x f temp mask pa pb pc ph pl ext wide wide2 swide swide2 sa sb sc data
    i j idx lane sh state_r state_n
Restart convention for the stateful cores: c[31]=1 discards the carried state
and re-arms it from that beat's own fields, so a new packet needs no drain.
"""
from random import Random

FAMILY = 'packet'
MASK = (1 << 32) - 1

# A config-restart beat with all other fields zero leaves the state exactly
# zero, which is what the last vector row must do: the testbench replays the
# same image from reset three times, so the state threaded through the model by
# the generator has to land where a hardware reset leaves it.
TERMINATOR = (0, 0, 0x80000000)

CORES = []


def core(name, spec, body, advantage, lanes, **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body,
                      advantage=advantage, lanes=lanes, **kwargs))


# ---------------------------------------------------------------------------
# 1. Four packed 16-bit header fields, each against its own rule set.
# ---------------------------------------------------------------------------
core('pkt_header_validate4',
    'Four packed 16-bit header fields per beat (halfword 0 is the low half): '
    'LEN=a[15:0], TYPE=a[31:16], VERW=b[15:0], FLAGS=b[31:16]. Config '
    'c[7:0]=runt bound, jumbo limit={c[15:8],8\'h00}, c[23:16]=highest legal '
    'TYPE, c[31:24]=bit mask of legal versions over nibble 0..7 (8..15 illegal). '
    'Checks: LEN<runt=runt, LEN>jumbo=jumbo, LEN[1:0]!=0=truncated; TYPE==0='
    'reserved type, TYPE>c[23:16]=unknown type; VERW[15:4]!=0=upper bits set, '
    'version=VERW[3:0]>7=illegal nibble, version bit clear in c[31:24]=disabled; '
    'FLAGS[15:6]!=0=reserved bits set, FLAGS[5](MF)&FLAGS[4](DF) both set='
    'conflict. result[3:0]=per-field PASS mask (1=field clean), result[4]=all '
    'four clean, result[19:8]=ceil(LEN/32) beats, result[31:20]=0. aux[3:0]=LEN '
    '[runt,jumbo,truncated,field-any], aux[7:4]=TYPE [reserved0,unknown,'
    'field-any,0], aux[11:8]=VER [upper_bits,illegal_nib,disabled,field-any], '
    'aux[15:12]=FLAGS [reserved,df_mf,field-any,global]. fault=aux[15], any '
    'check fired. Stateless: c[31] carries no meaning.',
    'runt = c[7:0];\n'
    'lim = {c[15:8], 8\'h00};\n'
    'tmax = c[23:16];\n'
    'vmask = c[31:24];\n'
    'lenf = a[15:0];\n'
    'tyf = a[31:16];\n'
    'verf = b[15:0];\n'
    'flf = b[31:16];\n'
    'e0 = 1\'b0; e1 = 1\'b0; e2 = 1\'b0; e3 = 1\'b0; g = 1\'b0;\n'
    'vb = vmask[verf[2:0]];\n'
    'if (lenf < runt) begin x[0] = 1\'b1; e0 = 1\'b1; end\n'
    'if (lenf > lim) begin x[1] = 1\'b1; e0 = 1\'b1; end\n'
    'if (lenf[1:0] != 2\'d0) begin x[2] = 1\'b1; e0 = 1\'b1; end\n'
    'x[3] = e0;\n'
    'if (tyf == 16\'d0) begin x[4] = 1\'b1; e1 = 1\'b1; end\n'
    'if (tyf > tmax) begin x[5] = 1\'b1; e1 = 1\'b1; end\n'
    'x[6] = e1; x[7] = 1\'b0;\n'
    'if (verf[15:4] != 12\'d0) begin x[8] = 1\'b1; e2 = 1\'b1; end\n'
    'if (verf[3]) begin x[9] = 1\'b1; e2 = 1\'b1; end\n'
    'else if (!vb) begin x[10] = 1\'b1; e2 = 1\'b1; end\n'
    'x[11] = e2;\n'
    'if (flf[15:6] != 10\'d0) begin x[12] = 1\'b1; e3 = 1\'b1; end\n'
    'if (flf[4] && flf[5]) begin x[13] = 1\'b1; e3 = 1\'b1; end\n'
    'x[14] = e3;\n'
    'g = e0 | e1 | e2 | e3;\n'
    'x[15] = g;\n'
    'r[0] = !e0; r[1] = !e1; r[2] = !e2; r[3] = !e3;\n'
    'r[4] = !g;\n'
    'r[19:8] = (lenf + 16\'d31) >> 5;\n'
    'f = g;',
    'Four fields are policed against four different rule sets in one beat with '
    'no branches; a scalar loop pays a load, a compare and a shift per field '
    'and must re-read them to report which checks fired.', 4,
    decl='reg [15:0] runt, lim, tmax, lenf, tyf, verf, flf;\n'
         'reg [7:0] vmask;\n'
         'reg vb, e0, e1, e2, e3, g;')


# ---------------------------------------------------------------------------
# 2. Unaligned 32-bit realignment over a 16-byte residual buffer.
# ---------------------------------------------------------------------------
core('pkt_realign_unaligned32',
    'Barrel-shifter-with-carry realignment of a byte stream. State: state[5:0]='
    'residual byte count (0..16), state[8*i+8+:8]=residual byte i (byte 0 is '
    'the oldest) for i=0..15, bits above 135 read as zero. Beat: a = new bytes '
    '0..3, b = new bytes 4..7, keep=min(c[7:4],8) = valid new bytes, sh=c[3:0] '
    '= byte offset of the destination word inside the window, c[8]=EOP declared '
    'packet end, c[31]=restart (residual and its count cleared before this '
    'beat). Window byte j = residual byte j for j<res, then the keep new bytes; '
    'result = the 32 bits at byte offset sh, merged across the residual/new '
    'boundary. New residual = the bytes above the emitted word, count res\'='
    'clamp(res+keep-sh-4, 0, 16); bytes above 16 are dropped. Fault: EV when '
    'sh+4>res+keep (read past the window) or res+keep-sh-4>16 (residual buffer '
    'overflow); EM when EOP is declared and res\'!=0 (shift illegal for the '
    'declared packet end); KV when c[7:4]>8 (keep field out of range). '
    'aux[4:0]=res\', aux[9:5]=res echo, aux[13:10]=keep echo, aux[17:14]=sh '
    'echo, aux[18]=EV, aux[19]=EM, aux[20]=KV, aux[21]=EOP echo, aux[22] and '
    'aux[31]=restart echo. Result and new residual are still produced on a '
    'fault so the datapath can be observed.',
    'res = c[31] ? 6\'d0 : state_r[5:0];\n'
    'sh4 = c[3:0];\n'
    'kp = c[7:4];\n'
    'kpe = (kp > 4\'d8) ? 4\'d8 : kp;\n'
    'big = {129\'d1} << {res, 3\'d0};\n'
    'bm = big - 129\'d1;\n'
    'resb = {state_r[135:8], 120\'d0} >> 120;\n'
    'resb = resb & bm;\n'
    'nw = {128\'d0, b, a};\n'
    'big = {129\'d1} << {4\'d0, kpe, 3\'d0};\n'
    'bm = big - 129\'d1;\n'
    'nw = nw & bm;\n'
    'win = ({64\'d0, nw} << {res, 3\'d0}) | {64\'d0, resb};\n'
    'need = {2\'d0, sh4} + 6\'d4;\n'
    'avail = res + {2\'d0, kpe};\n'
    'if (avail < need) left = 6\'d0;\n'
    'else if ((avail - need) > 6\'d16) left = 6\'d16;\n'
    'else left = avail - need;\n'
    'r = (win >> {4\'d0, sh4, 3\'d0}) & 32\'hffffffff;\n'
    'nres = (win >> {4\'d0, sh4, 3\'d0}) >> 32;\n'
    'big = {129\'d1} << {left, 3\'d0};\n'
    'bm = big - 129\'d1;\n'
    'nres = nres & bm;\n'
    'if (avail < need) begin x[18] = 1\'b1; f = 1\'b1; end\n'
    'else if (avail > need + 6\'d16) begin x[18] = 1\'b1; f = 1\'b1; end\n'
    'if (c[8] && left != 0) begin x[19] = 1\'b1; f = 1\'b1; end\n'
    'if (kp > 4\'d8) begin x[20] = 1\'b1; f = 1\'b1; end\n'
    'x[4:0] = left[4:0];\n'
    'x[9:5] = res[4:0];\n'
    'x[13:10] = kpe;\n'
    'x[17:14] = sh4;\n'
    'x[21] = c[8];\n'
    'x[22] = c[31];\n'
    'x[31] = c[31];\n'
    'state_n = {120\'d0, nres, 2\'d0, left};',
    'A misaligned 32-bit read costs software two shifts, an OR and a byte carry '
    'held across beats; here the merge over the residual boundary is one '
    'barrel-shifter cone at II=1 for any byte offset 0..15.', 1,
    stateful=True,
    decl='reg [5:0] res, need, avail, left;\n'
         'reg [3:0] sh4, kp, kpe;\n'
         'reg [128:0] big, bm;\n'
         'reg [127:0] resb, nw, nres;\n'
         'reg [191:0] win;')


# ---------------------------------------------------------------------------
# 3. Runtime-offset multi-field extraction across the a/b word pair.
# ---------------------------------------------------------------------------
core('pkt_field_extract_variable',
    'Four fields read at runtime bit offsets from the 64-bit pair {b,a} (bit 0 '
    '= a[0]). c[3:0]=base bit offset (0..15), widths w0..w3=c[7:4], c[11:8], '
    'c[15:12], c[19:16] (0..8; 0=field absent; 9..15 malformed for a byte '
    'extractor), c[23:20]=ignored, c[31:24]=declared window in bits (0 is read '
    'as 1). Fields are laid back to back: p0=base, p(k+1)=pk+wk. result[8k+7:8k]'
    '=field k right aligned in its byte lane, 0 when the field is absent, '
    'malformed or out of window. aux[3:0]=field k crosses the a|b word edge '
    '(pk<32<pk+wk), aux[7:4]=field k leaves the declared window or the 64-bit '
    'pair, aux[11:8]=field k absent (wk==0), aux[15:12]=field k width '
    'malformed, aux[23:16]=bits consumed (base plus the widths of the fields '
    'actually extracted), aux[31:24]=bit '
    'position of the last field extracted (0 when none). fault=any malformed '
    'width (then no field is extracted and aux[23:16]=aux[31:24]=0), or any '
    'field whose span leaves the window or the pair, or a field starting at or '
    'past the window. Stateless: c[31] carries no meaning.',
    'pair = {b, a};\n'
    'base = c[3:0];\n'
    'lanemax = {1\'b0, c[31:24]};\n'
    'if (lanemax == 9\'d0) lanemax = 9\'d1;\n'
    'pos = {5\'d0, base};\n'
    'tot = {5\'d0, base};\n'
    'lp = 8\'d0;\n'
    'bad = 1\'b0;\n'
    'for (lane = 0; lane < 4; lane = lane + 1) begin\n'
    '    if (c[((lane << 2) + 4) +: 4] > 4\'d8) bad = 1\'b1;\n'
    'end\n'
    'if (bad) begin\n'
    '    f = 1\'b1;\n'
    '    for (lane = 0; lane < 4; lane = lane + 1) begin\n'
    '        if (c[((lane << 2) + 4) +: 4] > 4\'d8) x[12+lane] = 1\'b1;\n'
    '    end\n'
    'end else begin\n'
    '    for (lane = 0; lane < 4; lane = lane + 1) begin\n'
    '        wv = c[((lane << 2) + 4) +: 4];\n'
    '        pk = pos;\n'
    '        if (wv == 4\'d0) begin\n'
    '            x[8+lane] = 1\'b1;\n'
    '        end else if (pk >= lanemax || (pk + {5\'d0, wv}) > lanemax ||\n'
    '                     (pk + {5\'d0, wv}) > 9\'d64) begin\n'
    '            x[4+lane] = 1\'b1; f = 1\'b1;\n'
    '        end else begin\n'
    '            if (pk < 9\'d32 && (pk + {5\'d0, wv}) > 9\'d32) x[lane] = 1\'b1;\n'
    '            wv64 = pair >> pk;\n'
    '            big = {65\'d1} << wv;\n'
    '            r[(lane << 3) +: 8] = wv64 & (big[63:0] - 64\'d1);\n'
    '            tot = tot + {5\'d0, wv};\n'
    '            lp = pk[7:0];\n'
    '        end\n'
    '        pos = pk + {5\'d0, wv};\n'
    '    end\n'
    '    x[23:16] = tot[7:0];\n'
    '    x[31:24] = lp;\n'
    'end',
    'Variable-offset, variable-width fields that straddle the word edge cost a '
    'scalar core a rotate plus a mask per field; this reads all four, including '
    'the ones that roll over a|b, in one enabled beat.', 4,
    decl='reg [63:0] pair, wv64, big;\n'
         'reg [8:0] pos, pk, lanemax;\n'
         'reg [9:0] tot;\n'
         'reg [3:0] wv, base;\n'
         'reg [7:0] lp;\n'
         'reg bad;')


# ---------------------------------------------------------------------------
# 4. Single-rate token meter (RFC 2698 style, two colours).
# ---------------------------------------------------------------------------
core('pkt_token_meter_color',
    'Single-rate two-colour meter over a saturating 24-bit byte token bucket. '
    'State: state[23:0]=tokens, state[39:24]=timestamp (16-bit beat clock), '
    'bits above 39 read as zero. Beat: T=a[31:16] arrival timestamp, LEN=a[15:0] '
    'packet bytes, CBS=b[23:0] burst limit, b[31:24] reserved (nonzero is a '
    'config fault), c[3:0]=scale credit shift, c[30:8]=initial tokens, '
    'c[31]=restart (tokens:=c[30:8], time:=0). Saturing token format: tokens '
    'and credit are 24-bit unsigned byte counts that are clamped, never '
    'wrapped. delta=(T-time) mod 65536, raw credit=delta<<scale, '
    'credit=min(raw,0xFFFFFF), balance=min(tokens+credit,CBS); if LEN<=balance '
    'the packet is GREEN and balance-=LEN, else it is RED, no token is consumed '
    'and the attempt to drive the balance negative is the fault. '
    'state_n[23:0]=balance, state_n[39:24]=T. result[23:0]=balance, result[24]='
    'RED, result[25]=balance clamped to CBS, result[26]=reserved-config fault, '
    'result[31:27]=0. aux[15:0]=delta, aux[27:16]=credit clamped to 12 bits for '
    'the echo, aux[28]=credit saturated at 24 bits, aux[29]=GREEN, aux[30]='
    'reserved nonzero, aux[31]=restart echo. fault=RED or reserved nonzero.',
    't16 = a[31:16];\n'
    'plen = a[15:0];\n'
    'cbs = b[23:0];\n'
    'rsv = b[31:24];\n'
    'scl = c[3:0];\n'
    'ini = c[30:8];\n'
    'if (c[31]) begin tok = {1\'b0, ini}; tm = 16\'d0; end\n'
    'else begin tok = state_r[23:0]; tm = state_r[39:24]; end\n'
    'delta = t16 - tm;\n'
    # delta<<scl reaches at most bit 30, so a 32-bit shift and a byte-wide OR
    # replace the 64-bit raw and its magnitude compare.
    'raw32 = {16\'d0, delta} << scl;\n'
    'xs = |raw32[31:24];\n'
    'cre = xs ? 24\'hffffff : raw32[23:0];\n'
    'sumv = {1\'b0, tok} + {1\'b0, cre};\n'
    'clm = sumv > {1\'b0, cbs};\n'
    # min(a,b)-p = min(a-p,b-p), and RED is the OR of the two borrow-outs: both
    # subtractions start at sumv/cbs in parallel instead of chaining a compare,
    # a mux and a third subtract.
    'cest = {1\'b1, cbs} - {1\'b0, plen};\n'
    'csum = {1\'b1, sumv} - {2\'b0, plen};\n'
    'red = ~csum[25] | ~cest[24];\n'
    'if (red) bal = clm ? cbs : sumv[23:0];\n'
    'else bal = clm ? cest[23:0] : csum[23:0];\n'
    'x[15:0] = delta;\n'
    'x[27:16] = cre[11:0];\n'
    'x[28] = xs;\n'
    'x[29] = !red;\n'
    'x[30] = (rsv != 8\'d0);\n'
    'x[31] = c[31];\n'
    'r[23:0] = bal;\n'
    'r[24] = red;\n'
    'r[25] = clm;\n'
    'r[26] = (rsv != 8\'d0);\n'
    'f = red | (rsv != 8\'d0);\n'
    'state_n = {216\'d0, t16, bal};',
    'A software rate limiter re-reads a clock, multiplies for credit and '
    'branches on the balance; this meters one packet per enabled beat with the '
    'wrap-safe elapsed difference, the saturating add and the colour decision '
    'in one cone.', 1,
    stateful=True,
    decl='reg [15:0] t16, delta, tm, plen;\n'
         'reg [23:0] cbs, tok, cre, bal;\n'
         'reg [24:0] sumv;\n'
         'reg [22:0] ini;\n'
         'reg [7:0] rsv;\n'
         'reg [3:0] scl;\n'
         'reg [31:0] raw32;\n'
         'reg [25:0] csum;\n'
         'reg [24:0] cest;\n'
         'reg red, clm, xs;')


# ---------------------------------------------------------------------------
# 5. Two-rate three-color marker (RFC 2697 arithmetic, power-of-two rates).
# ---------------------------------------------------------------------------
core('pkt_trtcm_coloring',
    'Two-rate three-colour marker, 1 token = 1 byte, rates forced to powers of '
    'two (CIR=2^kc, PIR=2^kp bytes per time unit) so no multiplier is needed. '
    'State: state[15:0]=CBC committed byte counter, state[31:16]=EBC excess '
    'byte counter, state[47:32]=timestamp, bits above 47 read as zero. Beat: '
    'T=a[31:16], B=a[15:0] packet bytes, CBS=b[15:0], EBS=b[31:16], c[3:0]=kc, '
    'c[7:4]=kp, c[8]=E (declared excess-counter overflow request), c[31]='
    'restart (CBC:=CBS, EBC:=EBS, time:=0). delta=(T-time) mod 65536, '
    'backwards when delta>=32768; Tcir=min(delta<<kc,0x1FFFF) and '
    'Tpir=min(delta<<kp,0x1FFFF) saturate at 17 bits; CBC=max(0,CBC-Tcir), '
    'EBC=max(0,EBC-Tpir). Marking: if CBC+B<=CBS GREEN and CBC+=B; else if '
    'EBC+B<=EBS YELLOW and EBC+=B; else RED and then CBC:=0 when B>CBS and '
    'EBC:=0 when B>EBS, so the counters drain instead of overflowing. '
    'result[15:0]=CBC, result[31:16]=EBC after the beat. aux[15:0]=delta, '
    'aux[17:16]=colour (00=green, 01=yellow, 10=red), aux[20:18]=Tcir[17:15], '
    'aux[23:21]=Tpir[17:15], aux[24]=Tcir saturated, aux[25]=Tpir saturated, '
    'aux[26]=backwards timestamp, aux[27]=restart echo, aux[28]=E echo, '
    'aux[29]=B>CBS, aux[30]=B>EBS, aux[31]=0. fault=RED with B>EBS, or the E '
    'flag, or a backwards timestamp.',
    't16 = a[31:16];\n'
    'blen = {1\'b0, a[15:0]};\n'
    'cbs = b[15:0];\n'
    'ebs = b[31:16];\n'
    'kc = c[3:0];\n'
    'kp = c[7:4];\n'
    'if (c[31]) begin cbc0 = {1\'b0, cbs}; ebc0 = {1\'b0, ebs}; end\n'
    'else begin cbc0 = {1\'b0, state_r[15:0]}; ebc0 = {1\'b0, state_r[31:16]};\n'
    '     end\n'
    'dlt = t16 - state_r[47:32];\n'
    'delta = c[31] ? t16 : dlt;\n'
    'bw = delta[15];\n'
    'rawc = {16\'d0, delta} << kc;\n'
    'rawp = {16\'d0, delta} << kp;\n'
    'cs = |rawc[31:17];\n'
    'ps = |rawp[31:17];\n'
    'uc = rawc[17:0];\n'
    'up = rawp[17:0];\n'
    'tcir = cs ? 18\'h1ffff : uc;\n'
    'tpir = ps ? 18\'h1ffff : up;\n'
    'qc = {2\'b00, cbc0} + {2\'b0, blen};\n'
    'qe = {2\'b00, ebc0} + {2\'b0, blen};\n'
    'wcb = qc - {3\'b000, cbs};\n'
    'web = qe - {3\'b000, ebs};\n'
    'drc = {2\'b00, cbc0} - {1\'b0, uc};\n'
    'dre = {2\'b00, ebc0} - {1\'b0, up};\n'
    'drc18 = drc[17:0];\n'
    'dre18 = dre[17:0];\n'
    'satc = cs | drc[18];\n'
    'sate = ps | dre[18];\n'
    'acm = satc ? 18\'d0 : drc18;\n'
    'aex = sate ? 18\'d0 : dre18;\n'
    'smc = qc - {1\'b0, uc};\n'
    'sme = qe - {1\'b0, up};\n'
    'smc18 = smc[17:0];\n'
    'sme18 = sme[17:0];\n'
    'vcm = satc ? {1\'b0, blen} : smc18;\n'
    'vex = sate ? {1\'b0, blen} : sme18;\n'
    'btc = (blen > {1\'b0, cbs});\n'
    'bte = (blen > {1\'b0, ebs});\n'
    'ltc = (wcb[17:0] <= uc);\n'
    'lte = (web[17:0] <= up);\n'
    'gre = (!btc) && (satc | wcb[18] | ltc);\n'
    'yel = (!bte) && (sate | web[18] | lte);\n'
    'red = !gre && !yel;\n'
    'yel = yel && !gre;\n'
    'cbc_n = gre ? vcm : ((btc && !yel) ? 18\'d0 : acm);\n'
    'ebc_n = yel ? vex : ((!gre && bte) ? 18\'d0 : aex);\n'
    'x[15:0] = delta;\n'
    'x[17:16] = {red, yel};\n'
    'x[20:18] = tcir[17:15];\n'
    'x[23:21] = tpir[17:15];\n'
    'x[24] = cs;\n'
    'x[25] = ps;\n'
    'x[26] = bw;\n'
    'x[27] = c[31];\n'
    'x[28] = c[8];\n'
    'x[29] = btc;\n'
    'x[30] = bte;\n'
    'r[15:0] = cbc_n[15:0];\n'
    'r[31:16] = ebc_n[15:0];\n'
    'f = bw | c[8] | (red && bte);\n'
    'state_n = {208\'d0, t16, ebc_n[15:0], cbc_n[15:0]};',
    'RFC 2697 marking needs two counters, two saturating subtractions and a '
    'three-way colour decision per packet; the CPU path pays a multiply and '
    'several branches, the hardware needs neither because the rates are powers '
    'of two.', 1,
    stateful=True,
    decl='reg [15:0] t16, delta, dlt, cbs, ebs;\n'
         'reg [16:0] blen, cbc0, ebc0;\n'
         'reg [3:0] kc, kp;\n'
         'reg [31:0] rawc, rawp;\n'
         'reg [17:0] uc, up, tcir, tpir, drc18, dre18, smc18, sme18;\n'
         'reg [17:0] acm, aex, vcm, vex, cbc_n, ebc_n;\n'
         'reg [18:0] qc, qe, wcb, web, drc, dre, smc, sme;\n'
         'reg bw, cs, ps, btc, bte, gre, yel, red, satc, sate, ltc, lte;')


# ---------------------------------------------------------------------------
# 6. TLV walk of one 32-bit TCP option word.
# ---------------------------------------------------------------------------
core('pkt_tcp_option_walk32',
    'Walk the TLV option bytes of one 32-bit option word (byte 0=a[7:0]) for up '
    'to 4 records. start=c[3:0] byte offset, win=b[2:0]=option bytes left in '
    'the option area (it may exceed 4 when the area continues in the next '
    'word). Kinds: 0=EOL (1 byte, stops the walk), 1=NOP (1 byte), 2=MSS (4), '
    '3=Window Scale (3), 4=SACK-Permitted (2), any other kind is generic and '
    'takes its length from the following byte (0 or 1 is malformed and forces '
    '2). The walk stops when the running offset reaches win or passes byte 3. '
    'result[3:0]=first option offset after parsing (clamped to 15), result[7:4]='
    'records walked, result[12:8]=kinds seen bitmask in order [EOL,NOP,MSS,'
    'WinScale,SACKperm], result[13]=generic kind seen, result[14]=walk complete '
    'inside this word, result[15]=walk spilled into the next option word, '
    'result[21:16]=0, result[29:22]=last kind byte parsed, result[31:30]=0. '
    'aux[3:0]=start echo, aux[6:4]=win echo, aux[7]=nothing to parse, aux[8]='
    'generic length byte below 2, aux[9]=an option span runs past the declared '
    'option area (malformed nesting: a multi-byte option truncated by EOL), '
    'aux[10]=a needed byte lies outside this word, aux[11]=walk stopped at the '
    '4-record limit while still inside the option area, aux[12]=EOL seen, '
    'aux[13]=NOP seen, aux[14]=a multi-byte option was parsed, aux[15]=generic '
    'seen, aux[19:16]=records walked echo, aux[23:20]=offset of the first '
    'offence, aux[31:24]=kind byte of the first offence (0xff when the offence '
    'is the record limit). fault=aux[8] or aux[9] or aux[11]. Stateless: c[31] '
    'carries no meaning.',
    'ptr = c[3:0];\n'
    'st0 = c[3:0];\n'
    'win = b[2:0];\n'
    'run = 1\'b1; nrec = 4\'d0; kb = 5\'d0; flg = 4\'d0; gen = 1\'b0;\n'
    'lastk = 8\'d0; cmpw = 1\'b0; spl = 1\'b0; offk = 8\'d0; offp = 4\'d0;\n'
    'for (idx = 0; idx < 4; idx = idx + 1) begin\n'
    '    if (run) begin\n'
    '        if ({1\'b0, ptr} > {2\'d0, win} || ptr > 4\'d3) begin\n'
    '            run = 1\'b0; cmpw = 1\'b1;\n'
    '        end else begin\n'
    '            multi = 1\'b1;\n'
    '            kind = a[{ptr, 3\'d0} +: 8];\n'
    '            nrec = nrec + 4\'d1;\n'
    '            lastk = kind;\n'
    '            if (kind == 8\'d0) begin\n'
    '                kb[0] = 1\'b1; ptr = ptr + 4\'d1;\n'
    '                run = 1\'b0; cmpw = 1\'b1; l = 9\'d0;\n'
    '            end else if (kind == 8\'d1) begin\n'
    '                kb[1] = 1\'b1; ptr = ptr + 4\'d1; l = 9\'d0;\n'
    '            end else begin\n'
    '                if (kind == 8\'d2) begin kb[2] = 1\'b1; l = 9\'d4; end\n'
    '                else if (kind == 8\'d3) begin kb[3] = 1\'b1; l = 9\'d3; end\n'
    '                else if (kind == 8\'d4) begin kb[4] = 1\'b1; l = 9\'d2; end\n'
    '                else begin\n'
    '                    gen = 1\'b1; multi = 1\'b0;\n'
    '                    if (ptr == 4\'d3) begin\n'
    '                        flg[2] = 1\'b1; spl = 1\'b1; run = 1\'b0; l = 9\'d1;\n'
    '                        if (offk == 8\'d0) begin offk = kind; offp = ptr; end\n'
    '                    end else begin\n'
    '                        pl = {28\'d0, ptr} + 32\'d1;\n'
    '                        lb = a[{pl[3:0], 3\'d0} +: 8];\n'
    '                        if (lb < 8\'d2) begin\n'
    '                            flg[0] = 1\'b1; l = 9\'d2;\n'
    '                            if (offk == 8\'d0) begin offk = kind; offp = ptr; end\n'
    '                        end else l = {1\'b0, lb};\n'
    '                    end\n'
    '                end\n'
    '                span = {5\'d0, ptr} + l;\n'
    '                if (span > {2\'d0, win}) begin\n'
    '                    flg[1] = 1\'b1; run = 1\'b0; cmpw = 1\'b1;\n'
    '                    if (offk == 8\'d0) begin offk = kind; offp = ptr; end\n'
    '                end else if (span > 9\'d4 && (multi || ptr != 4\'d3)) begin\n'
    '                    flg[2] = 1\'b1; spl = 1\'b1; run = 1\'b0;\n'
    '                end\n'
    '                ptr = (span > 9\'d15) ? 4\'d15 : span[3:0];\n'
    '            end\n'
    '        end\n'
    '    end\n'
    'end\n'
    'if (run) begin\n'
    '    flg[3] = 1\'b1;\n'
    '    if (offk == 8\'d0) begin offk = 8\'hff; offp = ptr; end\n'
    'end\n'
    'x[3:0] = st0;\n'
    'x[6:4] = win;\n'
    'x[7] = (nrec == 4\'d0);\n'
    'x[8] = flg[0]; x[9] = flg[1]; x[10] = flg[2]; x[11] = flg[3];\n'
    'x[12] = kb[0]; x[13] = kb[1];\n'
    'x[14] = kb[2] | kb[3] | kb[4];\n'
    'x[15] = gen;\n'
    'x[19:16] = nrec;\n'
    'x[23:20] = offp;\n'
    'x[31:24] = offk;\n'
    'r[3:0] = ptr;\n'
    'r[7:4] = nrec;\n'
    'r[12:8] = kb;\n'
    'r[13] = gen;\n'
    'r[14] = cmpw;\n'
    'r[15] = spl;\n'
    'r[29:22] = lastk;\n'
    'f = flg[0] | flg[1] | flg[3];',
    'An option walk is a byte-at-a-time software loop with a switch per option; '
    'this retires up to four option records per enabled beat together with the '
    'malformed-span verdict, so no beat is wasted on loop bookkeeping.', 4,
    decl='reg [3:0] ptr, st0, nrec, offp, flg, win;\n'
         'reg [4:0] kb;\n'
         'reg [8:0] l, span;\n'
         'reg [7:0] kind, lb, lastk, offk;\n'
         'reg run, gen, cmpw, spl, multi;')


def half(value, index):
    return (value >> (16 * index)) & 0xffff


def byte_at(value, index):
    return (value >> (8 * index)) & 0xff


def step(name, a, b, c, state=0):                                # noqa: C901
    r = x = f = 0
    new_state = state

    # ------------------------------------------------------------------
    if name == 'pkt_header_validate4':
        runt = c & 0xff
        lim = ((c >> 8) & 0xff) << 8
        tmax = (c >> 16) & 0xff
        vmask = (c >> 24) & 0xff
        ln, ty, vw, fl = half(a, 0), half(a, 1), half(b, 0), half(b, 1)
        e = [0, 0, 0, 0]
        if ln < runt:
            x |= 1
            e[0] = 1
        if ln > lim:
            x |= 2
            e[0] = 1
        if ln & 3:
            x |= 4
            e[0] = 1
        if e[0]:
            x |= 8
        if ty == 0:
            x |= 0x10
            e[1] = 1
        if ty > tmax:
            x |= 0x20
            e[1] = 1
        if e[1]:
            x |= 0x40
        if vw >> 4:
            x |= 0x100
            e[2] = 1
        ver = vw & 0xf
        if ver > 7:
            x |= 0x200
            e[2] = 1
        elif not (vmask >> ver) & 1:
            x |= 0x400
            e[2] = 1
        if e[2]:
            x |= 0x800
        if fl >> 6:
            x |= 0x1000
            e[3] = 1
        if (fl & 0x30) == 0x30:
            x |= 0x2000
            e[3] = 1
        if e[3]:
            x |= 0x4000
        g = e[0] | e[1] | e[2] | e[3]
        if g:
            x |= 0x8000
        for k in range(4):
            if not e[k]:
                r |= 1 << k
        if not g:
            r |= 0x10
        r |= ((ln + 31) >> 5) << 8
        f = g

    # ------------------------------------------------------------------
    elif name == 'pkt_realign_unaligned32':
        res = 0 if c >> 31 else state & 0x3f
        sh = c & 0xf
        kp = (c >> 4) & 0xf
        kpe = min(kp, 8)
        resb = ((state >> 8) & ((1 << 128) - 1)) & ((1 << (8 * res)) - 1)
        nw = ((b << 32) | a) & ((1 << (8 * kpe)) - 1)
        win = (nw << (8 * res)) | resb
        r = (win >> (8 * sh)) & MASK
        need = sh + 4
        avail = res + kpe
        ev = avail < need or avail > need + 16
        left = 0 if avail < need else min(avail - need, 16)
        nres = (win >> (8 * sh + 32)) & ((1 << (8 * left)) - 1)
        em = bool(c & 0x100) and left != 0
        x |= left
        x |= (res & 31) << 5
        x |= kpe << 10
        x |= sh << 14
        if ev:
            x |= 1 << 18
        if em:
            x |= 1 << 19
        if kp > 8:
            x |= 1 << 20
        if c & 0x100:
            x |= 1 << 21
        if c >> 31:
            x |= 1 << 22
            x |= 1 << 31
        f = 1 if (ev or em or kp > 8) else 0
        new_state = (nres << 8) | left

    # ------------------------------------------------------------------
    elif name == 'pkt_field_extract_variable':
        pair = (b << 32) | a
        base = c & 0xf
        lanemax = max((c >> 24) & 0xff, 1)
        widths = [(c >> (4 * k + 4)) & 0xf for k in range(4)]
        if any(w > 8 for w in widths):
            f = 1
            for k, w in enumerate(widths):
                if w > 8:
                    x |= 1 << (12 + k)
        else:
            pos, tot, lp = base, base, 0
            for k, w in enumerate(widths):
                pk = pos
                if w == 0:
                    x |= 1 << (8 + k)
                elif pk >= lanemax or pk + w > lanemax or pk + w > 64:
                    x |= 1 << (4 + k)
                    f = 1
                else:
                    if pk < 32 < pk + w:
                        x |= 1 << k
                    r |= ((pair >> pk) & ((1 << w) - 1)) << (8 * k)
                    tot += w
                    lp = pk
                pos = pk + w
            x |= (tot & 0xff) << 16
            x |= lp << 24
        new_state = state

    # ------------------------------------------------------------------
    elif name == 'pkt_token_meter_color':
        t16 = (a >> 16) & 0xffff
        ln = a & 0xffff
        cbs = b & 0xffffff
        rsv = (b >> 24) & 0xff
        scl = c & 0xf
        ini = (c >> 8) & 0x7fffff
        if c >> 31:
            tok, tm = ini, 0
        else:
            tok, tm = state & 0xffffff, (state >> 24) & 0xffff
        delta = (t16 - tm) & 0xffff
        raw = delta << scl
        cre = min(raw, 0xffffff)
        total = tok + cre
        clm = total > cbs
        bal = cbs if clm else total
        red = ln > bal
        if not red:
            bal -= ln
        x |= delta
        x |= (cre & 0xfff) << 16
        if raw > 0xffffff:
            x |= 1 << 28
        if not red:
            x |= 1 << 29
        if rsv:
            x |= 1 << 30
        if c >> 31:
            x |= 1 << 31
        r |= bal
        if red:
            r |= 1 << 24
        if clm:
            r |= 1 << 25
        if rsv:
            r |= 1 << 26
        f = 1 if (red or rsv) else 0
        new_state = (t16 << 24) | bal

    # ------------------------------------------------------------------
    elif name == 'pkt_trtcm_coloring':
        t16 = (a >> 16) & 0xffff
        blen = a & 0xffff
        cbs = b & 0xffff
        ebs = (b >> 16) & 0xffff
        kc = c & 0xf
        kp = (c >> 4) & 0xf
        ee = bool(c & 0x100)
        if c >> 31:
            cbc, ebc, tm = cbs, ebs, 0
        else:
            cbc = state & 0xffff
            ebc = (state >> 16) & 0xffff
            tm = (state >> 32) & 0xffff
        delta = (t16 - tm) & 0xffff
        bw = delta >= 0x8000
        rawc, rawp = delta << kc, delta << kp
        tcir, tpir = min(rawc, 0x1ffff), min(rawp, 0x1ffff)
        cbc = max(0, cbc - tcir)
        ebc = max(0, ebc - tpir)
        if cbc + blen <= cbs:
            col, cbc = 0, cbc + blen
        elif ebc + blen <= ebs:
            col, ebc = 1, ebc + blen
        else:
            col = 2
            if blen > cbs:
                cbc = 0
            if blen > ebs:
                ebc = 0
        x |= delta
        x |= col << 16
        x |= ((tcir >> 15) & 7) << 18
        x |= ((tpir >> 15) & 7) << 21
        if rawc > 0x1ffff:
            x |= 1 << 24
        if rawp > 0x1ffff:
            x |= 1 << 25
        if bw:
            x |= 1 << 26
        if c >> 31:
            x |= 1 << 27
        if ee:
            x |= 1 << 28
        if blen > cbs:
            x |= 1 << 29
        if blen > ebs:
            x |= 1 << 30
        r |= cbc & 0xffff
        r |= (ebc & 0xffff) << 16
        f = 1 if (bw or ee or (col == 2 and blen > ebs)) else 0
        new_state = (t16 << 32) | ((ebc & 0xffff) << 16) | (cbc & 0xffff)

    # ------------------------------------------------------------------
    elif name == 'pkt_tcp_option_walk32':
        ptr = c & 0xf
        win = b & 7
        nrec = kb = flg = gen = lastk = cmpw = spl = offk = offp = 0
        run = True
        for _ in range(4):
            if not run:
                continue
            if ptr > win or ptr > 3:
                run, cmpw = False, 1
                continue
            kind = byte_at(a, ptr)
            nrec += 1
            lastk = kind
            if kind == 0:
                kb |= 1
                ptr += 1
                run, cmpw, length = False, 1, 0
                continue
            if kind == 1:
                kb |= 2
                ptr += 1
                continue
            multi = True
            if kind == 2:
                kb |= 4
                length = 4
            elif kind == 3:
                kb |= 8
                length = 3
            elif kind == 4:
                kb |= 16
                length = 2
            else:
                gen, multi = 1, False
                if ptr == 3:
                    flg |= 4
                    spl = 1
                    run = False
                    length = 1
                    if offk == 0:
                        offk, offp = kind, ptr
                else:
                    lb = byte_at(a, ptr + 1)
                    if lb < 2:
                        flg |= 1
                        length = 2
                        if offk == 0:
                            offk, offp = kind, ptr
                    else:
                        length = lb
            span = ptr + length
            if span > win:
                flg |= 2
                run, cmpw = False, 1
                if offk == 0:
                    offk, offp = kind, ptr
            elif span > 4 and (multi or ptr != 3):
                flg |= 4
                spl = 1
                run = False
            ptr = min(span, 15)
        if run:
            flg |= 8
            if offk == 0:
                offk, offp = 0xff, ptr
        x |= c & 0xf
        x |= win << 4
        if nrec == 0:
            x |= 1 << 7
        for k in range(4):
            if flg >> k & 1:
                x |= 1 << (8 + k)
        if kb & 1:
            x |= 1 << 12
        if kb & 2:
            x |= 1 << 13
        if kb & 0x1c:
            x |= 1 << 14
        if gen:
            x |= 1 << 15
        x |= (nrec & 0xf) << 16
        x |= offp << 20
        x |= offk << 24
        r |= ptr & 0xf
        r |= (nrec & 0xf) << 4
        for k in range(5):
            if kb >> k & 1:
                r |= 1 << (8 + k)
        if gen:
            r |= 1 << 13
        if cmpw:
            r |= 1 << 14
        if spl:
            r |= 1 << 15
        r |= lastk << 22
        f = 1 if (flg & (1 | 2 | 8)) else 0
        new_state = state

    else:
        raise ValueError(name)
    return r & MASK, x & MASK, int(bool(f)), new_state


# ---------------------------------------------------------------------------
# Vector sets: the first 128 rows run verbatim on the board, so the structured
# sweeps and every fault path live there; the tail is seeded padding.
# ---------------------------------------------------------------------------
def _pv():
    # 16 lengths landing in 16 distinct ceil(LEN/32) buckets x 8 field-error
    # patterns: every one of the first 128 rows answers with a different triple.
    lens = [0, 32, 64, 96, 128, 160, 192, 224, 256, 512, 1024, 1536, 1568, 2048,
            4096, 8192]
    pats = [(0x0008, 0x0002, 0x0000),   # every field clean
            (0x0000, 0x0002, 0x0000),   # TYPE 0 is reserved
            (0xabcd, 0x0002, 0x0000),   # TYPE above tmax
            (0x00ff, 0x000d, 0x0000),   # version nibble above 7
            (0x0100, 0x0001, 0x0000),   # version disabled by the legal mask
            (0x0200, 0x0010, 0x0000),   # version upper half set
            (0x0300, 0x0002, 0x0030),   # MF together with DF
            (0x0400, 0x0003, 0x00c0)]   # reserved FLAG bits
    cfg = 64 | (6 << 8) | (0xff << 16) | (0x0c << 24)   # runt 64, jumbo 1536
    rows = []
    for ln in lens:
        for ty, vw, fl in pats:
            rows.append((ln | (ty << 16), vw | (fl << 16), cfg))
    # Boundaries again under eight different rule sets, so every check bit is
    # seen both ways against its own threshold.
    cfgs = [(0, 0, 0, 0x0f), (1, 1, 255, 0xff), (255, 255, 0, 0x06),
            (72, 10, 127, 0x0f), (0, 250, 200, 0xaa), (3, 100, 400, 0x55),
            (63, 200, 1500, 0x0c), (64, 6, 255, 0x00)]
    for runt, jsh, tmax, vmask in cfgs:
        for ln in (0, 60, 64, 1536, 1540):
            for ty, vw, fl in pats[:3]:
                rows.append((ln | (ty << 16), vw | (fl << 16),
                             runt | (jsh << 8) | (tmax << 16) | (vmask << 24)))
    fls = [0, 0x10, 0x20, 0x30, 0x3f, 0x40, 0x80, 0x1f, 0x21, 0x01, 0x02, 0xff00,
           0xffff]
    for fl in fls:
        for ver in (2, 3, 8, 0xf000):
            rows.append((0x00560044, ver | (fl << 16), cfg))
    return rows


def _rv():
    rows = []
    # A freshly restarted beat carries the eight new bytes only, so the shift
    # sweep 0..15 runs twice: once alone and once from the residual the
    # previous beat left behind.
    for sh in range(16):
        rows.append((0x03020100, 0x07060504, sh | (8 << 4) | (1 << 31)))
    for sh in range(16):
        rows.append((0x0b0a0908, 0x0f0e0d0c, sh | (8 << 4)))
    for sh in range(16):
        rows.append((0x13121110, 0x17161514, sh | (8 << 4)))
    # The residual now evolves on its own: keep count 0..9 against seven byte
    # offsets, each beat feeding in fresh bytes, which walks EV, the 16-byte
    # overflow and every merge position across the boundary.
    for keep in range(10):
        for sh in (0, 3, 5, 7, 11, 14, 15):
            i = len(rows)
            rows.append((0x10101010 | ((i * 0x01010101) & 0x0f0f0f0f),
                         0x20202020 | ((i * 0x02020202) & 0x0f0f0f0f),
                         sh | (keep << 4)))
    # keep field out of range: KV on every shift.
    for kp in (9, 10, 12, 15):
        for sh in range(0, 16, 3):
            rows.append((0xdeadbeef, 0xcafef00d, sh | (kp << 4) | (1 << 31)))
    # declared packet end on every shift: EM whenever bytes are left behind.
    for sh in range(16):
        rows.append((0xa5a5a5a5, 0x5a5a5a5a, sh | (8 << 4) | (1 << 8) | (1 << 31)))
    # long unbroken chain, EOP declared on a quarter of the beats.
    for sh in range(16):
        for keep in range(6):
            i = len(rows)
            rows.append(((i * 0x01010101) & MASK, ((i * 7 + 1) * 0x01010101) & MASK,
                         sh | (keep << 4) | (1 << 8 if keep == 3 else 0)))
    for keep in (0, 1, 2, 4, 6, 8):
        for sh in (0, 1, 2, 4, 8, 15):
            rows.append((0xffffffff, 0x00000000, sh | (keep << 4)))
    return rows


def _ev():
    rows = []
    # (w0,w1,w2,w3,window) layouts: two bytes, four nibbles, a ragged mix, a
    # window that is too small for the later lanes and a malformed-width pair.
    pats = [(8, 8, 0, 0, 64), (4, 4, 4, 4, 64), (1, 2, 3, 4, 32),
            (8, 1, 8, 1, 20), (0, 8, 0, 8, 16), (2, 2, 2, 2, 4),
            (5, 6, 7, 8, 64), (9, 0, 10, 0, 64)]
    for base in range(16):
        for pi, (w0, w1, w2, w3, lmax) in enumerate(pats):
            k = base * len(pats) + pi
            rows.append(((0x89abcdef + k * 0x01010101) & MASK,
                         (0x01234567 ^ (k * 0x02020202)) & MASK,
                         base | (w0 << 4) | (w1 << 8) | (w2 << 12) |
                         (w3 << 16) | (lmax << 24)))
    for w in range(16):                     # every width, including malformed
        rows.append((0xaabbccdd, 0xeeff0011,
                     w | (w << 4) | (w << 8) | (w << 12) | (64 << 24)))
    for base in range(16):
        for win in (1, 2, 4, 8, 16, 32, 48, 64):
            rows.append((0xf00dbabe, 0x0badc0de,
                         base | (4 << 4) | (4 << 8) | (4 << 12) | (2 << 16) | (win << 24)))
    rows.append((0xdeadbeef, 0xfeedf00d, 0x0000000f))
    rows.append((0xdeadbeef, 0xfeedf00d, 0xffffffff))
    return rows


def _mv():
    rows = []
    for scale, cbs, ini in ((0, 0x1000, 0x800), (1, 0x1000, 0),
                            (2, 0xffffff, 0x7fffff), (4, 0x400, 0x400),
                            (8, 0x10000, 0), (12, 0x10, 0x10),
                            (15, 0xabcdef, 0x123456), (0, 0, 0),
                            (3, 0x7fffff, 8)):
        for delta in (0, 1, 2, 3, 7, 16, 100, 255, 256, 1000, 65535):
            ln = (delta * 7 + scale * 13) % 2000
            rows.append(((delta << 16) | ln, cbs, (ini << 8) | scale | (1 << 31)))
            rows.append((((delta + 1) & 0xffff) << 16 | (ln + 17) & 0xffff,
                         cbs, scale))
    for ln in (0, 1, 1500, 65535):
        rows.append((ln, 0x1000, 0x800 << 8))
        rows.append((ln << 16, 0x1000, (1 << 31) | (0x800 << 8)))
    for rsv in (1, 0x80, 0xff):
        rows.append((0, rsv << 24, (1 << 31) | 0x1000))
    rows.append((0xffffffff, 0x00ffffff, (0x7fffff << 8) | 0xf))
    return rows


def _tv():
    rows = []
    cfgs = ((0, 0, 0x1000, 0x2000), (1, 3, 100, 400), (4, 5, 0xffff, 0xffff),
            (8, 10, 100, 100), (12, 15, 0x4000, 0x8000), (2, 2, 0, 0),
            (0, 15, 0x1234, 0x5678), (3, 4, 0x300, 0x600))
    for ci, (kc, kp, cbs, ebs) in enumerate(cfgs):
        for delta in (0, 1, 2, 3, 5, 8, 16, 64, 255, 1000, 4000, 65535):
            blen = (delta * 3 + kc * 101 + ci * 37) % 900
            rows.append(((((delta + 3) & 0xffff) << 16) | blen, (ebs << 16) | cbs,
                         kc | (kp << 4) | (1 << 31) | (0x12345 << 9)))
            rows.append(((((delta + 5) & 0xffff) << 16) | ((blen + 257) & 0xffff),
                         (ebs << 16) | cbs, kc | (kp << 4)))
    for blen in (0, 1, 100, 0xffff):
        rows.append((blen, (4 << 16) | 2, 0))
        rows.append((blen << 16, (4 << 16) | 2, 1 << 31))
    rows.append((0xffff0000, 0, 0xf | (0xf << 4)))
    rows.append((0, 0xffffffff, (1 << 8) | 0xf))
    rows.append((0x80010000, 0x10000, (1 << 31) | 0xf))
    return rows


def _wv():
    rows = []
    kinds = [0, 1, 2, 3, 4, 5, 8, 0x11, 0x20, 0x40, 0x66, 0xfd, 0xfe, 0xff, 0x02,
             0x01]
    # Every first byte is a different kind and the three following bytes are a
    # rotating mix, so the record count, the offset after parsing, the last kind
    # and the offence kind all move together.
    for i, k0 in enumerate(kinds):
        for j in range(8):
            word = (k0 | (kinds[(i + j + 1) % 16] << 8) |
                    (kinds[(i * 3 + j) % 16] << 16) | (kinds[(i + j * 5 + 7) % 16] << 24))
            rows.append((word, 1 + (j % 7), (i + j) % 4))
            rows.append((word, 3 + (j % 5), (i * 2 + j) % 4))
    for wi, word in enumerate((0x02040100, 0x01010101, 0x00000000, 0x02000000,
                               0x0303ffff, 0xffff0401, 0x05020100, 0x0a0a0a0a,
                               0x020100ff, 0x04020103)):
        for start in range(4):
            rows.append((word, (2, 4, 6, 7)[wi % 4], start))
    return rows


BUILDERS = {'pkt_header_validate4': _pv, 'pkt_realign_unaligned32': _rv,
            'pkt_field_extract_variable': _ev, 'pkt_token_meter_color': _mv,
            'pkt_trtcm_coloring': _tv, 'pkt_tcp_option_walk32': _wv}


def vectors(name, count=320):
    rows = BUILDERS[name]()[:count - 1]
    rng = Random(0x9ACCE700 + sum(name.encode()))
    while len(rows) < count - 1:
        if name == 'pkt_realign_unaligned32':
            rows.append((rng.getrandbits(32), rng.getrandbits(32),
                         rng.getrandbits(4) |
                         (rng.choice([0, 1, 2, 4, 6, 8, 9, 15]) << 4) |
                         (rng.getrandbits(31))))
        elif name == 'pkt_field_extract_variable':
            rows.append((rng.getrandbits(32), rng.getrandbits(32),
                         rng.getrandbits(24) | (rng.randint(1, 255) << 24)))
        elif name == 'pkt_header_validate4':
            rows.append((rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32)))
        elif name == 'pkt_tcp_option_walk32':
            rows.append((rng.getrandbits(32), rng.getrandbits(3), rng.getrandbits(4)))
        else:
            rows.append((rng.getrandbits(32), rng.getrandbits(32),
                         rng.getrandbits(9) | (rng.getrandbits(22) << 9)))
    rows.append(TERMINATOR)
    rows = rows[:count]
    state = 0
    for a, b, c in rows:
        _, _, _, state = step(name, a, b, c, state)
    assert state == 0, name + ': vector stream must land the state back at zero'
    return rows


def selftest():
    """Independent-model checks against hand-derived expected values."""
    n = 0

    # ---- header validate ------------------------------------------------
    # config runt=64, jumbo=0x0600=1536, tmax=0xff, vmask=0x0c.
    # LEN=68 is clean, TYPE=0xabcd exceeds tmax, VERW nibble 0xd is >7,
    # FLAGS=0x0010 is DF alone so it is clean.
    r, x, f, _ = step('pkt_header_validate4', 0xabcd0044, 0x0010000d, 0x0cff0640)
    assert x == (0x20 | 0x40) | (0x200 | 0x800) | 0x8000, hex(x)
    assert f == 1 and (r & 0xf) == 0b1001 and (r & 0x10) == 0, hex(r)
    assert (r >> 8) & 0xfff == 3, hex(r)          # ceil(68/32) = 3
    n += 3
    # all four fields clean: LEN=1500 -> ceil(1500/32)=47 beats, TYPE=8 <= 0xff,
    # version nibble 2 legal under vmask bit 2, FLAGS=0.
    r, x, f, _ = step('pkt_header_validate4', 0x000805dc, 0x00000002, 0x0cff0640)
    assert (r & 0x1f, x, f) == (0x1f, 0, 0), hex(r)
    assert r == (47 << 8) | 0x1f, hex(r)
    n += 2
    # runt (8 < 64) plus MF&DF conflict only; 8 is 4-aligned so it is not
    # truncated and TYPE=8 is legal -> LEN and FLAGS groups fire.
    r, x, f, _ = step('pkt_header_validate4', 0x00080008, 0x00300002, 0x0cff0640)
    assert x == 0x1 | 0x8 | 0x2000 | 0x4000 | 0x8000, hex(x)
    assert f == 1 and (r & 0xf) == 0b0110, hex(r)
    assert (r >> 8) & 0xfff == 1, hex(r)          # ceil(8/32) = 1
    n += 2
    # jumbo only: LEN=9000 > 1536 and 9000%4==0, ceil(9000/32)=282.
    r, x, f, _ = step('pkt_header_validate4', 0x00082328, 0x00000002, 0x0cff0640)
    assert (x, f) == (0x2 | 0x8 | 0x8000, 1), hex(x)
    assert (r & 0xf) == 0b1110 and (r >> 8) & 0xfff == 282, hex(r)
    n += 2
    # version enabled vs disabled under vmask 0x0c (legal nibbles 2 and 3).
    _, x, f, _ = step('pkt_header_validate4', 0x00080040, 0x00000003, 0x0cff0640)
    assert (x, f) == (0, 0)
    r, x, f, _ = step('pkt_header_validate4', 0x00080040, 0x00000001, 0x0cff0640)
    assert (x, f) == (0x400 | 0x800 | 0x8000, 1), hex(x)
    assert (r & 0xf) == 0b1011 and (r >> 8) & 0xfff == 2, hex(r)
    n += 3
    # LEN=0 is a runt against runt=64 and TYPE=0 is reserved at the same time.
    r, x, f, _ = step('pkt_header_validate4', 0x00000000, 0x00000002, 0x0cff0640)
    assert x == 0x1 | 0x8 | 0x10 | 0x40 | 0x8000, hex(x)
    assert (r & 0xf) == 0b1100 and f == 1, hex(r)
    n += 2

    # ---- realignment: 16 residual bytes 0x00..0x0f then new bytes 0x10..0x17,
    # so window byte j is exactly j for every j in 0..23 and every shift 0..15
    # has a closed-form answer.
    state = 16
    for i in range(16):
        state |= i << (8 * i + 8)                 # byte i at state[8i+8 +: 8]
    for sh in range(16):
        r, x, f, ns = step('pkt_realign_unaligned32', 0x13121110, 0x17161514,
                           sh | (8 << 4), state)
        expect = sum((sh + i) << (8 * i) for i in range(4))
        assert r == expect, (sh, hex(r), hex(expect))
        left = min(20 - sh, 16)                   # res+keep-sh-4, capped at 16
        assert (x & 31) == left, (sh, x & 31, left)
        assert f == (1 if sh < 4 else 0), (sh, f)  # buffer overflow sh 0..3
        assert (x >> 18) & 1 == f, (sh, hex(x))
        assert (ns >> 8) & ((1 << (8 * left)) - 1) == sum(
            (sh + 4 + i) << (8 * i) for i in range(left)), (sh, hex(ns))
        n += 1
    # ---- merge across the residual/new boundary: 5 residual bytes 0x10..0x14
    # then new bytes 0x18..0x1f, so byte j of the window is 0x10+j below 5 and
    # 0x13+j from 5 up.
    st = 5
    for i in range(5):
        st |= (0x10 + i) << (8 * i + 8)
    r, x, f, ns = step('pkt_realign_unaligned32', 0x1b1a1918, 0x1f1e1d1c,
                       1 | (8 << 4), st)
    assert r == 0x14131211, hex(r)                # 3 residual + 1 new byte
    assert (x & 31) == 8 and f == 0, hex(x)       # 13 window bytes - 5
    assert ns == (0x1f1e1d1c1b1a1918 << 8) | 8, hex(ns)
    assert (x >> 5) & 0x1f == 5 and (x >> 10) & 0xf == 8 and (x >> 14) & 0xf == 1
    n += 4
    r, x, f, ns = step('pkt_realign_unaligned32', 0x1b1a1918, 0x1f1e1d1c,
                       3 | (8 << 4), st)
    assert r == 0x19181413, hex(r)                # 2 residual + 2 new bytes
    assert (x & 31) == 6 and f == 0 and ns == (0x1f1e1d1c1b1a << 8) | 6, hex(ns)
    n += 2
    # ---- declared packet end with an exact word left over: legal, drains.
    r, x, f, ns = step('pkt_realign_unaligned32', 0x07060504, 0,
                       0 | (4 << 4) | (1 << 8) | (1 << 31), 0)
    assert (r, f, ns) == (0x07060504, 0, 0), hex(r)
    assert (x >> 21) & 1 == 1 and (x >> 18) & 1 == 0, hex(x)
    # ---- the same EOP two bytes into the window leaves 2 bytes -> EM.
    r, x, f, ns = step('pkt_realign_unaligned32', 0x07060504, 0x0b0a0908,
                       2 | (8 << 4) | (1 << 8) | (1 << 31), 0)
    assert r == 0x09080706 and f == 1 and (x & 31) == 2, hex(r)
    assert (x >> 19) & 1 == 1 and ns == (0x0b0a << 8) | 2, hex(ns)
    # ---- keep field 9 is out of range: KV, the shifter still emits a word.
    r, x, f, ns = step('pkt_realign_unaligned32', 0x03020100, 0x07060504,
                       9 << 4, 0)
    assert f == 1 and (x >> 20) & 1 == 1 and (x & 31) == 4, hex(x)
    # ---- shift 15 with only 8 bytes in the window: EV, nothing emitted.
    r, x, f, ns = step('pkt_realign_unaligned32', 0x03020100, 0x07060504,
                       0xf | (8 << 4) | (1 << 31), 0)
    assert (r, f, x & 31, ns) == (0, 1, 0, 0) and (x >> 18) & 1 == 1
    n += 4

    # ---- variable field extraction --------------------------------------
    def ecfg(base, w0, w1=0, w2=0, w3=0, lmax=64):
        return base | (w0 << 4) | (w1 << 8) | (w2 << 12) | (w3 << 16) | \
            (lmax << 24)

    # pair = 0x01234567_89abcdef: two byte fields at bit 0 and bit 8, window 16.
    r, x, f, _ = step('pkt_field_extract_variable', 0x89abcdef, 0x01234567,
                      ecfg(0, 8, 8, lmax=16))
    assert (r, x, f) == (0xcdef, 0x08100c00, 0), (hex(r), hex(x))
    # ---- four byte fields from bit 15: lane 2 starts at bit 31 so it straddles
    # the a|b edge (aux[2]); consumed 15+32=47 bits, last field at bit 39.
    r, x, f, _ = step('pkt_field_extract_variable', 0x89abcdef, 0x01234567,
                     ecfg(15, 8, 8, 8, 8))
    assert (r, x, f) == (0x8acf1357, 0x272f0004, 0), (hex(r), hex(x))
    # ---- a zero width in the middle leaves a hole but does not shift lanes:
    # byte 0 = pair[7:0] = 0x44, byte 2 = pair[23:16] = 0x33, byte 3 = bit 16.
    r, x, f, _ = step('pkt_field_extract_variable', 0x11223344, 0x55667788,
                      ecfg(0, 8, 0, 8, 1, lmax=24))
    assert (r, x, f) == (0x00330044, 0x10110200, 0), (hex(r), hex(x))
    # ---- two 4-bit nibbles at bit 12 and bit 16 of 0x12345678: 5 then 4.
    r, x, f, _ = step('pkt_field_extract_variable', 0x12345678, 0x00000000,
                      ecfg(12, 4, 4))
    assert (r, x, f) == (0x0405, 0x10140c00, 0), (hex(r), hex(x))
    # ---- width 15 is malformed for a byte extractor: no field is extracted.
    r, x, f, _ = step('pkt_field_extract_variable', 0x89abcdef, 0x01234567,
                      ecfg(0, 15))
    assert (r, x, f) == (0, 0x1000, 1), (hex(r), hex(x))
    # ---- a 3-bit window rejects all four bytes: aux[7:4] and nothing consumed.
    r, x, f, _ = step('pkt_field_extract_variable', 0xffffffff, 0xffffffff,
                      ecfg(0, 8, 8, 8, 8, lmax=3))
    assert f == 1 and x == 0xf0 and (x >> 16) & 0xff == 0, hex(x)
    n += 6

    # ---- token meter: restart at 1000 tokens, CBS 4096, scale 0 (one token
    # per elapsed beat), a 600-byte packet leaves 400.
    r, x, f, s1 = step('pkt_token_meter_color', 600, 4096, (1000 << 8) | (1 << 31), 0)
    assert (r & 0xffffff, f, s1) == (400, 0, 400), (hex(r), s1)
    assert (x >> 29) & 1 == 1 and (x >> 31) & 1 == 1, hex(x)     # GREEN, restart
    # beat clock 1: delta 1 earns 1 token -> balance 401, a 5000-byte packet is
    # RED, consumes nothing and is the fault.
    r, x, f, s2 = step('pkt_token_meter_color', (1 << 16) | 5000, 4096, 0, s1)
    assert (r & 0xffffff, r >> 24, f, s2) == (401, 1, 1, (1 << 24) | 401), hex(r)
    # beats 2 and 3: 1-byte packets keep the arithmetic visible (402, then 393).
    r, x, f, s3 = step('pkt_token_meter_color', (3 << 16) | 1, 4096, 0, s2)
    assert (r & 0xffffff, f, x & 0xffff, s3) == (402, 0, 2, (3 << 24) | 402)
    r, x, f, s4 = step('pkt_token_meter_color', (4 << 16) | 10, 4096, 0, s3)
    assert (r & 0xffffff, f, s4) == (393, 0, (4 << 24) | 393)
    # scale 2 over 4 elapsed beats adds 4<<2=16 tokens, no packet bytes.
    r, x, f, _ = step('pkt_token_meter_color', (8 << 16), 4096, 2, s4)
    assert (r & 0xffffff, f, (x >> 16) & 0xfff) == (409, 0, 16), hex(x)
    n += 6
    # saturating credit: delta 5, scale 12 -> 20480 tokens, one consumed.
    r, x, f, s = step('pkt_token_meter_color', (5 << 16) | 1, 0x10000,
                      (1 << 31) | 12, 0)
    assert (r & 0xffffff, f, s) == (20479, 0, (5 << 24) | 20479), hex(s)
    # clamped by CBS: restart INIT 0x7fffff with CBS 0x10000.
    r, x, f, s = step('pkt_token_meter_color', 0, 0x10000,
                      (1 << 31) | (0x7fffff << 8), 0)
    assert (r & 0xffffff, (r >> 25) & 1, f, s) == (0x10000, 1, 0, 0x10000)
    # raw credit saturation at 24 bits: delta 0x1000, scale 15.
    r, x, f, s = step('pkt_token_meter_color', (0x1000 << 16) | 1, 0xffffff,
                      (1 << 31) | 15, 0)
    assert (r & 0xffffff, (x >> 28) & 1, f) == (0xfffffe, 1, 0)
    r, x, f, _ = step('pkt_token_meter_color', 0, 0xff000100, 1 << 8, 0)
    assert f == 1 and (r >> 26) & 1 == 1 and (x >> 30) & 1 == 1
    n += 4

    # ---- trtcm: CBS=100, EBS=200, restart loads both buckets full and pays
    # the elapsed 10 units at kc=1 / kp=2 -> Tcir=20, Tpir=40 -> CBC 80, EBC 160.
    # 80+50 > 100 and 160+50 > 200 so the packet is RED, but 50 fits both CBS
    # and EBS so the drained counters survive and there is no fault.
    cfg = (200 << 16) | 100
    r, x, f, st = step('pkt_trtcm_coloring', (10 << 16) | 50, cfg,
                       (1 << 31) | 1 | (2 << 4), 0)
    assert (r, f, (x >> 16) & 3) == ((160 << 16) | 80, 0, 2), hex(r)
    assert (x >> 27) & 1 == 1 and (x & 0xffff) == 10, hex(x)
    n += 2
    # elapsed 2 at kc=kp=0 -> CBC 78, EBC 158; 78+10 <= 100 -> GREEN.
    r, x, f, st = step('pkt_trtcm_coloring', (12 << 16) | 10, cfg, 0, st)
    assert (r, f, (x >> 16) & 3) == ((158 << 16) | 88, 0, 0), hex(r)
    assert x == 2, hex(x)
    n += 2
    # same timestamp -> elapsed 0; 88+200 beats CBS and 158+200 beats EBS so it
    # is RED, and B=200 > CBS drains CBC while 200 == EBS leaves EBC alone.
    r, x, f, st = step('pkt_trtcm_coloring', (12 << 16) | 200, cfg, 0, st)
    assert (r, f, (x >> 16) & 3) == (158 << 16, 0, 2), hex(r)
    assert (x >> 29) & 1 == 1 and (x >> 30) & 1 == 0 and x == 0x20020000, hex(x)
    n += 2
    # elapsed 1 -> EBC 157; B=300 exceeds both sizes so both counters drain.
    r, x, f, st = step('pkt_trtcm_coloring', (13 << 16) | 300, cfg, 0, st)
    assert (r, f, (x >> 16) & 3) == (0, 1, 2), hex(r)
    assert x == 0x60020001, hex(x)
    n += 2
    # ---- yellow decision: CBS=4, EBS=8, kc=0, kp=1, restart with both buckets
    # full; elapsed 2 drains Tcir=2 and Tpir=4 -> CBC 2, EBC 4. 2+3 > CBS so not
    # green, 4+3 <= EBS so YELLOW and EBC becomes 7.
    r, x, f, st = step('pkt_trtcm_coloring', (2 << 16) | 3, (8 << 16) | 4,
                       (1 << 31) | (1 << 4), 0)
    assert (r, (x >> 16) & 3, f) == ((7 << 16) | 2, 1, 0), hex(r)
    assert x == 0x08010002, hex(x)
    n += 2
    # CBS=2, EBS=4, kc=kp=0, elapsed 3: both subtractions saturate at 0, then
    # 0+1 <= 2 -> GREEN with CBC=1 and EBC untouched at 1.
    r, x, f, st = step('pkt_trtcm_coloring', (3 << 16) | 1, (4 << 16) | 2,
                       1 << 31, 0)
    assert (r, (x >> 16) & 3, f, (st >> 32) & 0xffff) == ((1 << 16) | 1, 0, 0, 3)
    r, x, f, st = step('pkt_trtcm_coloring', (4 << 16) | 1, (4 << 16) | 2, 0, st)
    # elapsed 1 drains CBC 1->0 and EBC 1->0, then 0+1 <= 2 -> GREEN again.
    assert (r & 0xffff, (r >> 16) & 0xffff, (x >> 16) & 3, f) == (1, 0, 0, 0)
    assert x == 1, hex(x)
    n += 3
    # ---- clock wrap: stored time 1, arrival 0 -> delta = 0xffff (mod 2^16) is
    # backwards, and both 17-bit increments echo bit 15 of that delta.
    _, x, f, _ = step('pkt_trtcm_coloring', 0, (4 << 16) | 2, 0, 1 << 32)
    assert f == 1 and (x >> 26) & 1 == 1 and (x & 0xffff) == 0xffff
    assert (x >> 18) & 7 == 1 and (x >> 21) & 7 == 1, hex(x)
    # ---- kc=15: 0x1000<<15 saturates Tcir at 0x1ffff (top three bits 0b011,
    # sat flag) while Tpir stays 0x1000 (top three bits 0, no sat flag).
    r, x, f, _ = step('pkt_trtcm_coloring', (0x1000 << 16) | 1, (4 << 16) | 2,
                      (1 << 31) | 15, 0)
    assert (r & 0xffff, (x >> 24) & 3, f) == (1, 1, 0), hex(x)
    assert (x >> 18) & 7 == 3 and (x >> 21) & 7 == 0 and x == 0x090c1000, hex(x)
    n += 2

    # ---- option walk ----------------------------------------------------
    # bytes 00 01 02 00, window 4: EOL at byte 0 ends the walk after one record
    # -> offset after parsing 1, 1 record, kind mask EOL only, complete in word.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x00020100, 4, 0)
    assert (r, x, f) == (0x4111, 0x00011040, 0), (hex(r), hex(x))
    assert (r & 0xf) == 1 and ((r >> 4) & 0xf) == 1 and ((r >> 8) & 0x1f) == 1
    n += 2
    # bytes 04 02 01 01, window 4: SACK-Permitted (2 bytes) then two NOPs, so
    # three records retire inside the word and the walk is complete.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x01010204, 4, 0)
    assert (r, x, f) == (0x00405234, 0x00036040, 0), (hex(r), hex(x))
    assert ((r >> 8) & 0x1f) == 0b10010 and (r & 0xf) == 4, hex(r)
    assert (r >> 22) & 0xff == 1 and ((r >> 4) & 0xf) == 3, hex(r)
    assert (x >> 14) & 1 == 1 and (x >> 13) & 1 == 1 and (x >> 12) & 1 == 0
    n += 4
    # bytes ff 02 01 00, window 4: generic kind 0xff takes its length 2 from the
    # next byte, then NOP, then EOL: three records, no fault, no multi-byte flag.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x000102ff, 4, 0)
    assert (r, x, f) == (0x6334, 0x0003b040, 0), (hex(r), hex(x))
    assert (r >> 13) & 1 == 1 and (x >> 15) & 1 == 1 and (x >> 14) & 1 == 0
    n += 2
    # bytes ff 01 00 00, window 4: a generic length byte below 2 is malformed,
    # forced to 2, and the first offence is kind 0xff at offset 0.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x000001ff, 4, 0)
    assert (r, x, f) == (0x6123, 0xff029140, 1), (hex(r), hex(x))
    assert (x >> 8) & 1 == 1 and (x >> 24) == 0xff and (x >> 20) & 0xf == 0
    assert (r & 0xf) == 3 and ((r >> 4) & 0xf) == 2 and (r >> 22) & 0xff == 0
    n += 3
    # a 4-byte MSS at offset 0 with only 3 option bytes declared is truncated by
    # the end of the area: aux[9] fault, offence kind 2 at offset 0.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x00000002, 3, 0)
    assert (r, x, f) == (0x804414, 0x02014230, 1), (hex(r), hex(x))
    assert (x >> 9) & 1 == 1 and (x >> 24) == 2 and (r & 0xf) == 4, hex(r)
    n += 2
    # the same MSS with window 4 fills the word exactly: complete, no fault.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x00000002, 4, 0)
    assert (r, x, f) == (0x804414, 0x00014040, 0), (hex(r), hex(x))
    n += 1
    # MSS at offset 1 with window 5 needs a byte from the next option word:
    # aux[10] and result[15] report the spill, and a spill is not a fault.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x000102ff, 5, 1)
    assert (r, x, f) == (0x808415, 0x00014451, 0), (hex(r), hex(x))
    assert (r >> 15) & 1 == 1 and (r >> 14) & 1 == 0 and (x >> 10) & 1 == 1
    n += 2
    # generic kind 0x0a claiming 10 bytes inside a 7-byte area: malformed
    # nesting, offence kind 0x0a at offset 0, walk stopped with ptr clamped.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x0a0a0a0a, 7, 0)
    assert (r, x, f) == (0x0280601a, 0x0a018270, 1), (hex(r), hex(x))
    assert (x >> 9) & 1 == 1 and (x >> 24) == 0x0a and (r & 0xf) == 10
    n += 2
    # five NOP records inside a 7-byte area do not fit in four iterations: the
    # walk is still running at the record limit, which is the aux[11] fault and
    # reports kind 0xff at the offset it stopped on (byte 4).
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x01010101, 7, 0)
    assert (r, x, f) == (0x00400244, 0xff442870, 1), (hex(r), hex(x))
    assert (x >> 11) & 1 == 1 and (x >> 24) == 0xff and (x >> 20) & 0xf == 4
    n += 2
    # three NOPs then a generic kind at byte 3: its length byte is outside this
    # word, so aux[10]/result[15] report the spill and the offence is kind 8.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0x08010101, 7, 0)
    assert (r, x, f) == (0x0200a244, 0x0834a470, 0), (hex(r), hex(x))
    assert (x >> 24) == 8 and (x >> 20) & 0xf == 3 and ((r >> 4) & 0xf) == 4
    n += 2
    # start at or past the declared area parses nothing.
    r, x, f, _ = step('pkt_tcp_option_walk32', 0xdeadbeef, 2, 3)
    assert (r, x, f) == (0x4003, 0xa3, 0), (hex(r), hex(x))
    assert (x >> 7) & 1 == 1 and (x >> 4) & 7 == 2 and (x & 0xf) == 3
    n += 2

    # ---- interface discipline for every core ----------------------------
    for entry_name in ('pkt_header_validate4', 'pkt_realign_unaligned32',
                       'pkt_field_extract_variable', 'pkt_token_meter_color',
                       'pkt_trtcm_coloring', 'pkt_tcp_option_walk32'):
        for probe in ((0, 0, 0), (MASK, MASK, MASK), (0x5a5a5a5a, 0x33333333, 0x11111111),
                      (0, 0, 1 << 31)):
            rr, xx, ff, ss = step(entry_name, probe[0], probe[1], probe[2], MASK)
            assert 0 <= rr <= MASK and 0 <= xx <= MASK and ff in (0, 1)
            assert 0 <= ss < (1 << 256)
            n += 1
    return n
