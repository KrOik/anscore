#!/usr/bin/env python3
"""Independent golden model for cnn_systolic_20k unit selftests.

Each unit of src/cnn_selftest.v is re-modelled in Python (cycle-accurate
for the small blocks, stream-level for input_layer / layer). The script
prints the expected FNV-1a digest per unit and compares against the
digest harvested from iverilog simulation (sim/digest_harvest.txt) plus
the stream dumps written by sim/tb_cnn_selftest.v.

Usage:
    python tools/golden_model.py            # print expected digests
    python tools/golden_model.py --check    # compare vs harvest + dumps
"""
import sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def fnv(h, b):
    return ((h ^ (b & 0xff)) * 0x01000193) & 0xffffffff

def fnv_seq(bytes_):
    h = 0x811c9dc5
    for b in bytes_:
        h = fnv(h, b)
    return h

def s8(v):
    v &= 0xff
    return v - 256 if v >= 128 else v

def s7(v):
    v &= 0x7f
    return v - 128 if v >= 64 else v

def s16(v):
    v &= 0xffff
    return v - 65536 if v >= 32768 else v

def s20(v):
    v &= 0xfffff
    return v - 0x100000 if v >= 0x80000 else v

def readmemb(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(int(line, 2))
    return out

def readmemh(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(int(line, 16))
    return out

# ===========================================================================
# Unit 0/1: pe  D=(i*37+5)&0xff unsigned, W=signed8(i*53-128), y_in=0
# y(t) = D(t-2)*W(t-2) + y_in(t-1); fold y[7:0],y[15:8] for i=3..95
# During reset (10 clk) inputs are f(0); pipeline fills with prod(0).
# ===========================================================================
def model_pe():
    bs = []
    for i in range(3, 96):
        j = i - 3          # input cycle whose product emerges now
        if j < 0:
            j = 0
        d = (j * 37 + 5) & 0xff
        w = s8(j * 53 - 128)
        y = s20(d * w)
        bs += [y & 0xff, (y >> 8) & 0xff]
    return fnv_seq(bs)

# ===========================================================================
# Unit 2: d_manager ROW=4  data_j(t)=t*8+{0,17,34,51}[j], D_j(t)=data_j(t-j-1)
# fold D[3],D[2],D[1],D[0] for c=0..39 (t<0 uses t=0, reset-filled pipes)
# ===========================================================================
def model_dm():
    off = [0, 17, 34, 51]
    def data(j, t):
        if t < 0:
            t = 0
        return (t * 8 + off[j]) & 0xff
    bs = []
    for c in range(40):
        for j in (3, 2, 1, 0):
            bs.append(data(j, c - j - 1))
    return fnv_seq(bs)

# ===========================================================================
# Unit 3: w_manager ROW=4 COL=2 CP=4, wm_test.mem (8 x 32-bit lines)
# tidx(0)=0; nl at c%16==0 -> tidx(c)=0; else tidx=(c-1)%4  (nl aligns w/ wrap)
# W_out[c][r](t) = mem[tidx(t-1)*2+c] byte r ; fold order [0][0..3],[1][0..3]
# ===========================================================================
def model_wm():
    mem = readmemb(os.path.join(ROOT, "wm_test.mem"))
    bs = []
    tidx = 0
    tidx_hist = [0]  # tidx during cycle t (t=0 -> 0 held through reset)
    for c in range(1, 49):
        nl = ((c - 1) % 16 == 0)   # nl(c-1) drives tidx(c)
        if nl:
            tidx = 0
        elif tidx == 3:
            tidx = 0
        else:
            tidx += 1
        tidx_hist.append(tidx)
    for c in range(48):
        t = tidx_hist[c - 1] if c - 1 >= 0 else 0
        for col in (0, 1):
            word = mem[t * 2 + col]
            for r in range(4):
                bs.append((word >> (r * 8)) & 0xff)
    return fnv_seq(bs)

# ===========================================================================
# Unit 4: sdp_ram W=16 D=32. write i<32: mem[i]=(i<<8)|((~i)&0x7f)
# read issued i=34..65 -> q at i+1. fold lo,hi for i=35..69 (q retains after
# last read at i=66 -> mem[31] repeats)
# ===========================================================================
def model_ram():
    mem = [((a << 8) | ((~a) & 0x7f)) & 0xffff for a in range(32)]
    bs = []
    q = None
    for i in range(70):
        # q during cycle i was read at cycle i-1 if re(i-1)
        if 34 <= i - 1 < 66:
            q = mem[(i - 1 - 34) & 31]
        if i >= 35:
            bs += [q & 0xff, (q >> 8) & 0xff]
    return fnv_seq(bs)

# ===========================================================================
# Unit 5: my_fifo DW=8 DEPTH=16 same-clock. write i<40 while !full;
# read i>=48 while !empty; dout delayed 1; fold dout when rd_d.
# ===========================================================================
def model_fifo():
    DEPTH = 16
    mem = [0] * DEPTH
    wr_ptr = rd_ptr = 0          # 5-bit binary
    wr_g_s1 = wr_g_s2 = rd_g_s1 = rd_g_s2 = 0
    dout = None
    got = 0
    bs = []

    def b2g(b): return (b >> 1) ^ b
    def g2b(g):
        b = 0
        for i in range(4, -1, -1):
            bit = (g >> i) & 1
            b |= (bit ^ ((b >> (i + 1)) & 1)) << i
        return b

    rd_d = 0
    for i in range(120):
        wr_sync = g2b(rd_g_s2)          # rd ptr seen in wr domain
        rd_sync = g2b(wr_g_s2)          # wr ptr seen in rd domain
        full = ((wr_ptr >> 4) & 1) != ((wr_sync >> 4) & 1) and \
               (wr_ptr & 0xf) == (wr_sync & 0xf)
        empty = rd_ptr == rd_sync
        wr = (i < 40) and not full
        rd = (i >= 48) and not empty
        # fold uses dout from previous cycle's rd
        if rd_d:
            bs.append(dout & 0xff)
            got += 1
        if rd:
            dout = mem[rd_ptr & 0xf]
            rd_ptr = (rd_ptr + 1) & 0x1f
        if wr:
            mem[wr_ptr & 0xf] = (i * 29 + 7) & 0xff
            wr_ptr = (wr_ptr + 1) & 0x1f
        rd_g_s1, rd_g_s2 = b2g(rd_ptr), rd_g_s1   # NOTE: update order below
        wr_g_s1, wr_g_s2 = b2g(wr_ptr), wr_g_s1
        rd_d = 1 if rd else 0
    return fnv_seq(bs), got

# ===========================================================================
# Unit 6: pe_col ROW=4  D_j(t)=t*7+5+11j ; W_j(t)=s8(t+1+j)
# y(t) = sum_j D_j(t-5+j)*W_j(t-5+j) ; fold lo,hi for c=16..51
# ===========================================================================
def model_col():
    # pe latency: y_out(t)=y_in(t-1)+prod(t-3) -> col chain: y(t)=sum_j prod_j(t-6+j)
    bs = []
    for c in range(16, 52):
        y = 0
        for j in range(4):
            t = c - 6 + j
            if t < 0:
                t = 0
            d = (t * 7 + 5 + 11 * j) & 0xff
            w = s8(t + 1 + j)
            y += d * w
        y = s20(y)
        bs += [y & 0xff, (y >> 8) & 0xff]
    return fnv_seq(bs)

# ===========================================================================
# Unit 7: pe_page ROW=4 COL=2 CP=4 pepage_weight.mem
# data_j(t)=t*5+6+8j ; Ddelay[c]_j(t)=data_j(t-1-j-c)
# y_c(t) = sum_j Ddelay[c]_j(t-5+j) * W_cj(t-5+j)
# W_cj(u) = mem[tidx(u-1)*2+c] byte j ; tidx(u)=0 for u<=0 else (u-1)%4
# fold c=20..59: y0 lo,hi,y1 lo,hi
# ===========================================================================
def model_page():
    mem = readmemb(os.path.join(ROOT, "pepage_weight.mem"))
    def data(j, t):
        if t < 0:
            t = 0
        return (t * 5 + 6 + 8 * j) & 0xff
    def tidx(u):          # w_manager time_idx during cycle u (nl at u%32==0)
        if u <= 0:
            return 0
        return (u - 1) % 4
    def W(c, j, u):       # W_pe[c][j] during cycle u = mem[tidx(u-1)*2+c] byte j
        word = mem[tidx(u - 1) * 2 + c]
        return s8((word >> (j * 8)) & 0xff)
    bs = []
    for c_t in range(20, 60):
        for col in (0, 1):
            y = 0
            for j in range(4):
                # y_c(t) = sum_j prod_j(t-6+j); prod uses Ddelay & W at that cycle
                t = c_t - 6 + j
                d = data(j, t - 1 - j - col)
                w = W(col, j, t)
                y += d * w
            y = s20(y)
            bs += [y & 0xff, (y >> 8) & 0xff]
    return fnv_seq(bs)

# ===========================================================================
# Unit 8: max_pool2d ROW=9. y(t)=max of 9 data elems at t-2 (unsigned).
# fold when input_valid(t-2) i.e. c=2..97. data elems (mod 256):
# [8]=i+8 [7]=i*3+7 [6]=i+6 [5]=i*5+5 [4]=i+4 [3]=i*9+3 [2]=i+2
# [1]=i*11+1 [0]=i
# ===========================================================================
def model_pool():
    bs = []
    for c in range(2, 98):
        i = c - 2
        elems = [(i + 8) & 0xff, (i * 3 + 7) & 0xff, (i + 6) & 0xff,
                 (i * 5 + 5) & 0xff, (i + 4) & 0xff, (i * 9 + 3) & 0xff,
                 (i + 2) & 0xff, (i * 11 + 1) & 0xff, i & 0xff]
        bs.append(max(elems))
    return fnv_seq(bs)

# ===========================================================================
# Unit 9: activation_lut IW=6 lut_test.mem (hex). fold rom[i] for i=0..63
# ===========================================================================
def model_lut():
    # activation_lut has no rst: in_valid is already 1 during reset, so
    # rom[0] is folded once extra before the real stream.
    rom = readmemh(os.path.join(ROOT, "lut_test.mem"))
    return fnv_seq([rom[0]] + rom[:64])

# ===========================================================================
# Unit 11: output_layer  PAGE=2 COL=2 ROW=9 CPO=2 CPI=1 IMG_COL=8 SHIFT=4
# bias_test.mem (4 x 16-bit).  nl at ol_i%64==0 && ol_i<192 -> c=0,64,128
# page(p,c)(t) = s20( t + p*131 + c*77 - 200 )   (ol_i=t)
# pipeline: s1(t)=pagesum(t-1); s2(t)=s1(t-1), biasv_c(t)=bias[btc(t-1)*2+c]
# s3(t)=s2(t-1) (acc cleared always since CPI=1); swb(t)=s3(t-1)+biasv(t-1)
# st5_c(t)=relu_sat(round(swb(t-1))); final0(t)=st5_0(t-1); final1(t)=st5_1(t)
# fold final0,final1 when output_valid.
# ===========================================================================
def model_ol():
    bias = readmemb(os.path.join(ROOT, "bias_test.mem"))
    TOTAL_DELAY = 18
    BIAS_ADDR_DELAY = 14
    # counters
    nlp = [0] * TOTAL_DELAY   # pipe[k](t) = nl(t-1-k)
    btc = 0
    idx_out = 0
    idx_in = 0
    aclr = [0, 0]
    # valid counters
    iov = iiv = icv = 0
    start_out = 0
    # pipeline regs
    s1 = [0, 0]; s2 = [0, 0]; bv = [0, 0]; s3 = [0, 0]; swb = [0, 0]
    st5 = [0, 0]
    bs = []
    def nl(t):
        return 1 if (t in (0, 64, 128)) else 0
    pst5_0 = 0
    for t in range(0, 225):
        pipe13 = nlp[13]; pipe12 = nlp[12]; pipe17 = nlp[17]
        # --- valid counters / output_valid(t) ---
        ov = (iiv == 0) and start_out
        if ov:
            f0 = pst5_0   # final_out[0] = stage5[0] delayed 1 (DESKEW=1)
            f1 = st5[1]   # final_out[1] = stage5[1] (DESKEW=0)
            bs += [f0 & 0xff, f1 & 0xff]
        pst5_0 = st5[0]
        btc_pre = btc; aclr_pre = list(aclr); idx_in_pre = idx_in
        # --- sequential updates (edge t -> t+1) ---
        nlp = [nl(t)] + nlp[:-1]
        if pipe13:
            btc = 0
        else:
            btc = 0 if btc == 1 else btc + 1
        if pipe12:
            idx_out = 0; idx_in = 0
        else:
            if idx_out == 1:
                idx_out = 0
                idx_in = 0 if idx_in == 0 else idx_in + 1  # CPI=1
            else:
                idx_out += 1
        aclr = [1 if idx_in_pre == 0 else 0, aclr_pre[0]]
        # valid window
        if pipe17:
            iov = iiv = icv = 0
            start_out = 1
        else:
            if iov == 1:
                iov = 0
                if iiv == 0:
                    iiv = 0
                    if icv == 7:
                        icv = 0
                        start_out = 0
                    else:
                        icv += 1
                else:
                    iiv += 1
            else:
                iov += 1
        # datapath
        p = lambda pg, c, tt: s20(min(tt, 220) + pg * 131 + c * 77 - 200)
        ns1 = [p(0, c, t) + p(1, c, t) for c in (0, 1)]
        ns2 = [s1[c] for c in (0, 1)]
        nbv = [bias[btc_pre * 2 + c] for c in (0, 1)]
        # s3 uses acc_clear delayed; CPI=1 -> idx_in always 0 -> clear=1
        ns3 = [s2[c] + (0 if aclr_pre[c] else 0) for c in (0, 1)]
        nswb = [s3[c] + s16(bv[c]) for c in (0, 1)]
        nst5 = []
        for c in (0, 1):
            v = swb[c]
            sh = v >> 4                    # python >> is arithmetic
            rnd = sh + ((v >> 3) & 1)
            if rnd < 0:
                o = 0
            elif rnd >= 255:
                o = 255
            else:
                o = rnd & 0xff
            nst5.append(o)
        s1, s2, bv, s3, swb, st5 = ns1, ns2, nbv, ns3, nswb, nst5
    return fnv_seq(bs)

# ===========================================================================
# Unit 13: extrema_finder DW=16 COL=2 CPO=4. nl at i=0,40,80.
# dv: 0<i<97 and not nl. d0=s16(i*17-300) d1=s16(i*29-100)
# ===========================================================================
def model_ef():
    CPO = 4
    INIT = -32768
    cyc = 0; best = INIT; best_ch = 0
    bs = []
    for i in range(110):
        nl = i in (0, 40, 80)
        dv = (0 < i < 97) and not nl
        # data_in = {ef_d0, ef_d1}: concat is MSB-first -> [1]=d0, [0]=d1
        d0 = s16(i * 29 - 100); d1 = s16(i * 17 - 300)
        cycle_best, pe_idx = (d1, 1) if d1 > d0 else (d0, 0)
        gidx = cyc + pe_idx * CPO
        val_v = 0; val = 0; vch = 0
        if nl:
            cyc = 0; best = INIT; best_ch = 0
        elif dv:
            if cyc == 0:
                best = cycle_best; best_ch = gidx
            elif cycle_best > best:
                best = cycle_best; best_ch = gidx
            if cyc == CPO - 1:
                cyc = 0
                val_v = 1
                if cycle_best > best:
                    val = cycle_best; vch = gidx
                else:
                    val = best; vch = best_ch
            else:
                cyc += 1
        if val_v:
            bs += [val & 0xff, (val >> 8) & 0xff, vch & 0xff]
    return fnv_seq(bs)

# ===========================================================================
# Unit 14: lprnet_spatial_sum COL=2 CPO=2 IMG 4x3 (BRAM_DEPTH=8)
# stimulus: nl,8 dv, nl,8 dv, nl,8 dv  data(c)={s8(seq*9-40), s8(seq*5+2)}
# seq = row*16+beat. fold y0 lo,hi,y1 lo,hi when output_valid
# ===========================================================================
def ssum_events():
    """Actual (nl, dv, [d0,d1]) stimulus seen by the DUT, in cycle order.

    The cnn_selftest FSM increments ss_row one edge before the 8th data
    beat, so each nl-delimited group carries seqs {r*16+1..r*16+7,
    (r+1)*16+8}.
    """
    ev = []
    for row in range(3):
        ev.append((1, 0, [0, 0]))
        seqs = [row * 16 + b for b in range(1, 8)] + [(row + 1) * 16 + 8]
        for seq in seqs:
            # data_input = {A, B} MSB-first -> [1]=seq*9-40, [0]=seq*5+2
            # iverilog evaluates the 7'd* arithmetic in 7 bits, then the
            # signed size-cast sign-extends bit 6 -> s7 semantics.
            ev.append((0, 1, [s7(seq * 5 + 2), s7(seq * 9 - 40)]))
    return ev

def model_ssum(ev):
    DEPTH = 8
    mem = [[None] * DEPTH, [None] * DEPTH]
    row_cnt = 2
    cnt = 0
    # pipeline regs
    v1 = v2 = v3 = 0
    f1 = 0
    l1 = l2 = l3 = 0
    c1 = c2 = c3 = 0
    ds1 = [0, 0]
    qa = [None, None]
    oa = [0, 0]; ob = [0, 0]; s3v = [0, 0]
    # output_valid(c)=(v3&l3)(c-1), y_out(c)=s3(c-1): sample previous cycle
    pv3l3 = 0; ps3v = [0, 0]
    bs = []
    for (nl, dv, d) in list(ev) + [(0, 0, [0, 0])] * 8:
        first0 = (row_cnt == 0)
        last0 = (row_cnt == 2)
        if pv3l3:
            for c in (0, 1):
                y = s16(ps3v[c])
                bs += [y & 0xff, (y >> 8) & 0xff]
        pv3l3 = v3 and l3
        ps3v = list(s3v)
        cnt_pre = cnt     # stage regs sample cnt before increment
        qa_pre = qa[:]    # add_op_a uses bram_q reg value (read from prev cycle)
        # bram read: q(next cycle) = mem[cnt(this cycle)] when dv(this cycle)
        if dv:
            for c in (0, 1):
                qa[c] = mem[c][cnt]
        # counters
        if nl:
            row_cnt = row_cnt + 1 if row_cnt < 2 else 0
        if dv:
            cnt = 0 if cnt == DEPTH - 1 else cnt + 1
        # stage regs
        nv1, nv2, nv3 = dv, v1, v2
        nf1 = first0
        nl1, nl2, nl3 = last0, l1, l2
        nc1, nc2, nc3 = cnt_pre, c1, c2
        nds1 = list(d)
        noa = [0 if f1 else (qa_pre[c] if qa_pre[c] is not None else 0) for c in (0, 1)]
        nob = [s16(ds1[c]) for c in (0, 1)]
        ns3 = [s16(oa[c] + ob[c]) for c in (0, 1)]
        # bram write from s3
        if v3:
            for c in (0, 1):
                mem[c][c3] = s3v[c]
        v1, v2, v3 = nv1, nv2, nv3
        f1 = nf1
        l1, l2, l3 = nl1, nl2, nl3
        c1, c2, c3 = nc1, nc2, nc3
        ds1 = nds1
        oa, ob, s3v = noa, nob, ns3
    return fnv_seq(bs)

# ===========================================================================
# Unit 15: lprnet_post_process = ssum -> ef -> ctc decode
# COL=2 CPO=2 -> CHANNEL_OUT=4, BLANK=7->ch3, VALID_CHAR_NUM=8->limit 4
# ===========================================================================
def model_ctc(ev):
    # reuse ssum pipeline but expose per-cycle (output_valid, y, nlo)
    DEPTH = 8
    mem = [[None] * DEPTH, [None] * DEPTH]
    row_cnt = 2; cnt = 0
    v1 = v2 = v3 = 0; f1 = 0; l1 = l2 = l3 = 0; c1 = c2 = c3 = 0
    ds1 = [0, 0]; qa = [None, None]; oa = [0, 0]; ob = [0, 0]; s3v = [0, 0]
    # registered outputs: ss_output_valid(c)=(v3&l3)(c-1), ss_y(c)=s3(c-1),
    # ss_nlo(c)=(v2&l2&c2==0)(c-1)
    pv3l3 = 0; ps3v = [0, 0]; pnlo = 0
    ss_events = []
    for (nl, dv, d) in list(ev) + [(0, 0, [0, 0])] * 12:
        first0 = (row_cnt == 0); last0 = (row_cnt == 2)
        ss_events.append((pv3l3, list(ps3v), pnlo))
        pv3l3 = v3 and l3
        ps3v = list(s3v)
        pnlo = v2 and l2 and (c2 == 0)
        cnt_pre = cnt
        qa_pre = qa[:]
        if dv:
            for c in (0, 1):
                qa[c] = mem[c][cnt]
        if nl:
            row_cnt = row_cnt + 1 if row_cnt < 2 else 0
        if dv:
            cnt = 0 if cnt == DEPTH - 1 else cnt + 1
        nv1, nv2, nv3 = dv, v1, v2
        nf1 = first0
        nl1, nl2, nl3 = last0, l1, l2
        nc1, nc2, nc3 = cnt_pre, c1, c2
        nds1 = list(d)
        noa = [0 if f1 else (qa_pre[c] if qa_pre[c] is not None else 0) for c in (0, 1)]
        nob = [s16(ds1[c]) for c in (0, 1)]
        ns3 = [s16(oa[c] + ob[c]) for c in (0, 1)]
        if v3:
            for c in (0, 1):
                mem[c][c3] = s3v[c]
        v1, v2, v3 = nv1, nv2, nv3
        f1 = nf1; l1, l2, l3 = nl1, nl2, nl3
        c1, c2, c3 = nc1, nc2, nc3
        ds1 = nds1; oa, ob, s3v = noa, nob, ns3
    # note: y_out(t) = s3(t-1) i.e. the value folded is s3v at the SAME cycle
    # ss_events tuples are (ov, y, nlo) sampled during that cycle; y=s3v
    # which was computed last edge -> consistent with y_out<=sum_s3 timing.

    # --- extrema_finder over ss_events ---
    CPO = 2; INIT = -32768
    cyc = 0; best = INIT; best_ch = 0
    ef_out = []   # (val_valid, val, ch)
    for (ov, y, nlo) in ss_events:
        d0, d1 = s16(y[0]), s16(y[1])
        cycle_best, pe_idx = (d1, 1) if d1 > d0 else (d0, 0)
        gidx = cyc + pe_idx * CPO
        vv = 0; val = 0; vch = 0
        if nlo:
            cyc = 0; best = INIT; best_ch = 0
        elif ov:
            if cyc == 0:
                best = cycle_best; best_ch = gidx
            elif cycle_best > best:
                best = cycle_best; best_ch = gidx
            if cyc == CPO - 1:
                cyc = 0; vv = 1
                if cycle_best > best:
                    val = cycle_best; vch = gidx
                else:
                    val = best; vch = best_ch
            else:
                cyc += 1
        ef_out.append((vv, val, vch))
    # --- ctc decode ---
    BLANK = 3; LIMIT = 4
    prefix = BLANK; started = 0
    m_reg = 0; ch_reg = 0
    bs = []
    nff = 0
    for (vv, val, vch), (ov, y, nlo) in zip(ef_out, ss_events):
        if nlo:
            nff = 1
        match = vv and (vch < LIMIT) and (vch != BLANK) and \
                (nff or (vch != prefix))
        if vv:
            if nff:
                if match:
                    prefix = vch; started = 1
                else:
                    prefix = BLANK; started = 0
            else:
                prefix = vch
                if match and not started:
                    started = 1
            nff = 0     # cleared when ef_val_valid
        out_v = m_reg; out_c = ch_reg
        m_reg = 1 if match else 0
        ch_reg = vch
        if out_v:
            bs.append(out_c & 0xff)
    return fnv_seq(bs)

# ===========================================================================
# Unit 10: input_layer functional model.
# 6x8 image, 3x3 kernel, stride 1, zero padding. Data beats carry il_x=1..8
# (il_x is incremented before the dv beat sees it) so image x = il_x-1.
#   ch0(x,r) = (x+1) + 8r        (from 8'(il_x + il_row*8))
#   ch1(x,r) = 3*(x+1) + 7r + 2  (from 8'(il_x*3 + il_row*7 + 2))
# Emits 40 windows (oy=0..4, ox=0..7); each ov beat folds
# dout[r][0],dout[r][1] for r=0..8, r = kr*3+kc row-major.
# Verified byte-exact against sim/dump_il.txt (all 720 bytes).
# ===========================================================================
def il_window_byte(oy, ox, r, ch):
    kr, kc = r // 3, r % 3
    iy, ix = oy + kr - 1, ox + kc - 1
    if iy < 0 or iy >= 6 or ix < 0 or ix >= 8:
        return 0
    xp = ix + 1
    return ((xp + iy * 8) if ch == 0 else (xp * 3 + iy * 7 + 2)) & 0xff

def model_il():
    bs = []
    for oy in range(5):
        for ox in range(8):
            for r in range(9):
                for ch in range(2):
                    bs.append(il_window_byte(oy, ox, r, ch))
    return fnv_seq(bs)

# ===========================================================================
# Unit 12: lprnet_layer_direct functional model.
# Same image as IL fed through the layer: conv 3x3x2ch with all-1 weights
# (weight_layer9_page*.mem = all 0x01), bias=8 (bias_layer9.mem), SHIFT_KEY=4
# with round bit, ReLU, saturate to 8 bits. Both output channels identical.
# Emits 5 rows x 8 positions x CPO=2 duplicate beats; each beat folds
# ly_out[0],ly_out[1]. Verified byte-exact against sim/dump_ly.txt.
# ===========================================================================
def model_layr():
    bs = []
    for oy in range(5):
        for ox in range(8):
            acc = sum(il_window_byte(oy, ox, r, ch) for r in range(9) for ch in range(2))
            acc += 8                        # bias
            rnd = (acc >> 4) + ((acc >> 3) & 1)   # >>4 with rounding
            v = 0 if rnd < 0 else (255 if rnd >= 255 else rnd)
            for _ in range(2):              # CYCLE_PERIOD_OUT dup beats
                bs += [v, v]
    return fnv_seq(bs)

# ===========================================================================
# Expected digests table
# ===========================================================================
def compute_all():
    ev = ssum_events()
    return {
        0:  model_pe(),
        1:  model_pe(),
        2:  model_dm(),
        3:  model_wm(),
        4:  model_ram(),
        5:  model_fifo()[0],
        6:  model_col(),
        7:  model_page(),
        8:  model_pool(),
        9:  model_lut(),
        10: model_il(),
        11: model_ol(),
        12: model_layr(),
        13: model_ef(),
        14: model_ssum(ev),
        15: model_ctc(ev),
    }

if __name__ == "__main__":
    names = {0:"PE",1:"PED",2:"DM",3:"WM",4:"RAM",5:"FIFO",6:"COL",7:"PAGE",
             8:"POOL",9:"ALUT",10:"IL",11:"OL",12:"LAYR",13:"EXTR",14:"SSUM",15:"CTC"}
    exp = compute_all()
    for k in sorted(exp):
        print(f"UNIT {k:2d} {names[k]:4s} expected={exp[k]:08x}")
