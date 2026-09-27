// STAGED SCRATCH FILE -- not a release artifact, nothing in rtl/ was touched.
// Timing-oriented rewrite of the pkt_trtcm_coloring (RFC 2697 trtcm marker)
// authored kernel. Same port list, same handshake wrapper, same 256-bit state
// register and the same enabled-ready-valid-32x3-v1 semantics as
// rtl/acc_pkt_trtcm_coloring.v. Only the cone shape changes.
//
// Semantics come from ip/pkt_trtcm_coloring/SPEC.md and are unchanged:
//   result[15:0]=CBC, result[31:16]=EBC after the beat;
//   aux[15:0]=delta, aux[17:16]=colour, aux[20:18]=Tcir[17:15],
//   aux[23:21]=Tpir[17:15], aux[24]=Tcir saturated, aux[25]=Tpir saturated,
//   aux[26]=backwards timestamp, aux[27]=restart echo, aux[28]=E echo,
//   aux[29]=B>CBS, aux[30]=B>EBS, aux[31]=0;
//   fault = backwards timestamp, or the E flag, or RED with B>EBS;
//   state_n = {208'd0, T, EBC[15:0], CBC[15:0]}.
//
// Serial structure in the release kernel (per colour level, then twice):
//   64-bit delta<<kc -> 64-bit magnitude compare -> 18-bit Tcir mux ->
//   (Tcir>counter compare -> zero mux) -> saturating subtract -> add B ->
//   compare to CBS -> colour mux -> RED-case conditional zero mux, and the
//   EBC decision hangs off the CBC decision through the if/else-if chain.
// Flattened here with four identities:
//   1. delta is 16 bits and kc/kp are 4, so delta<<k reaches at most bit 30.
//      A 32-bit shift plus a 15-input reduction OR replaces the 64-bit raw and
//      the 64-bit magnitude compare: cs = |rawc[31:17].
//   2. 0x1FFFF is larger than any 16-bit bucket, so the 17-bit saturation never
//      changes a saturated drain: max(0,C-Tcir) = (cs | borrow(C-Tcir)) ? 0 :
//      C-Tcir. One subtraction and one select replace compare -> mux ->
//      subtract -> mux.
//   3. max(0,C-T)+B = max(B, C+B-T), and C+B is built from state/config only,
//      so "bucket after the packet" is one subtraction off the same T with the
//      SAME already-computed saturation select, instead of a second carry chain
//      behind the drained-bucket mux.
//   4. bucket+B<=CBS is moved onto an early total: with W=C+B-CBS (independent
//      of the token cone) and NB=(B<=CBS),
//        green = NB & (saturated | W<0 | (W>=0 ? W<=Tcir : -)),
//      because a green packet forces B<=CBS and an unsaturated drain gives
//      C+B-Tcir<=CBS <=> C+B <= CBS+Tcir. So the colour test is one 18-bit
//      compare that starts at W, not a compare of the muxed bucket sum, and the
//      committed and excess decisions no longer wait on each other.
// Authored kernel. See ip/pkt_trtcm_coloring/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pkt_trtcm_coloring_fast (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [255:0] state_r, state_n;
reg [31:0] r, x, temp, mask, pa, pb, pc, ph, pl;
reg [32:0] ext;
reg [63:0] wide, wide2;
reg signed [63:0] swide, swide2;
reg signed [31:0] sa, sb, sc;
reg [95:0] data;
reg f;
integer i, j, idx, lane, sh;
reg [15:0] t16, delta, dlt, cbs, ebs;
reg [16:0] blen, cbc0, ebc0;
reg [3:0] kc, kp;
reg [31:0] rawc, rawp;          // 32-bit: delta<<k cannot pass bit 30
reg [17:0] uc, up;              // unclamped Tcir/Tpir low 18 bits
reg [18:0] qc, qe, drc, dre, smc, sme, wcb, web;
reg [17:0] drc18, dre18, smc18, sme18;
reg [17:0] acm, aex, vcm, vex, cbc_n, ebc_n, tcir, tpir;
reg bw, cs, ps, btc, bte, gre, yel, red, satc, sate, ltc, lte;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    delta=0; dlt=0; qc=0; qe=0; drc=0; dre=0; smc=0; sme=0; wcb=0; web=0;
    drc18=0; dre18=0; smc18=0; sme18=0; uc=0; up=0; rawc=0; rawp=0;
    acm=0; aex=0; vcm=0; vex=0; cbc_n=0; ebc_n=0; tcir=0; tpir=0; cbc0=0;
    ebc0=0; bw=0; cs=0; ps=0; btc=0; bte=0; gre=0; yel=0; red=0; satc=0;
    sate=0; ltc=0; lte=0;
    t16 = a[31:16];
    blen = {1'b0, a[15:0]};
    cbs = b[15:0];
    ebs = b[31:16];
    kc = c[3:0];
    kp = c[7:4];
    if (c[31]) begin cbc0 = {1'b0, cbs}; ebc0 = {1'b0, ebs}; end
    else begin cbc0 = {1'b0, state_r[15:0]}; ebc0 = {1'b0, state_r[31:16]}; end
    dlt = t16 - state_r[47:32];
    delta = c[31] ? t16 : dlt;
    bw = delta[15];
    rawc = {16'd0, delta} << kc;
    rawp = {16'd0, delta} << kp;
    cs = |rawc[31:17];
    ps = |rawp[31:17];
    uc = rawc[17:0];
    up = rawp[17:0];
    tcir = cs ? 18'h1ffff : uc;
    tpir = ps ? 18'h1ffff : up;
    qc = {2'b00, cbc0} + {2'b0, blen};
    qe = {2'b00, ebc0} + {2'b0, blen};
    wcb = qc - {3'b000, cbs};
    web = qe - {3'b000, ebs};
    drc = {2'b00, cbc0} - {1'b0, uc};
    dre = {2'b00, ebc0} - {1'b0, up};
    drc18 = drc[17:0];
    dre18 = dre[17:0];
    satc = cs | drc[18];
    sate = ps | dre[18];
    acm = satc ? 18'd0 : drc18;
    aex = sate ? 18'd0 : dre18;
    smc = qc - {1'b0, uc};
    sme = qe - {1'b0, up};
    smc18 = smc[17:0];
    sme18 = sme[17:0];
    vcm = satc ? {1'b0, blen} : smc18;
    vex = sate ? {1'b0, blen} : sme18;
    btc = (blen > {1'b0, cbs});
    bte = (blen > {1'b0, ebs});
    ltc = (wcb[17:0] <= uc);
    lte = (web[17:0] <= up);
    gre = (!btc) && (satc | wcb[18] | ltc);
    yel = (!bte) && (sate | web[18] | lte);
    red = !gre && !yel;
    yel = yel && !gre;
    cbc_n = gre ? vcm : ((btc && !yel) ? 18'd0 : acm);
    ebc_n = yel ? vex : ((!gre && bte) ? 18'd0 : aex);
    x[15:0] = delta;
    x[17:16] = {red, yel};
    x[20:18] = tcir[17:15];
    x[23:21] = tpir[17:15];
    x[24] = cs;
    x[25] = ps;
    x[26] = bw;
    x[27] = c[31];
    x[28] = c[8];
    x[29] = btc;
    x[30] = bte;
    r[15:0] = cbc_n[15:0];
    r[31:16] = ebc_n[15:0];
    f = bw | c[8] | (red && bte);
    state_n = {208'd0, t16, ebc_n[15:0], cbc_n[15:0]};
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f; state_r<=state_n;
            end
        end
    end
end
endmodule
