// STAGED SCRATCH FILE -- not a release artifact; nothing outside tools/_staged/
// was generated or modified.  Timing-oriented rewrite of the bf16_mul authored
// kernel (tools/fam_arith.py: BFM_DECL + the core('bf16_mul', ...) body= text).
//
// Port list, handshake wrapper (enabled-ready-valid-32x3-v1), the 256-bit state
// register, the II=1 / latency-1 semantics and the whole `always @*` body text
// are IDENTICAL to rtl/acc_bf16_mul.v.  Only the two functions that body calls
// were reshaped, so the cone depth drops:
//
//   um8    8x8 unsigned mantissa product.  Release: eight sequential
//          carry-propagate accumulate steps (`acc=acc+(u<<<k)`), 52 of the
//          release's 173 ltp levels.  Here: a balanced partial-product tree
//          (((p0+p1)+(p2+p3)) + ((p4+p5)+(p6+p7))<<4) -> three adder levels.
//          Still one conditional add of `{pad,u}<<<k` per multiplier bit, so
//          there is no `*` and no MULT12X12 (release policy: the fabric $mul is
//          unsigned on GW5A and hand-instantiated hard IP is out of scope).
//
//   bf_num single round-to-nearest-even normalize/round step.  Release: 32-bit
//          quantities everywhere -- 32-bit barrel shifts by a 9-bit amount
//          (1<<<k, 1<<<(k-1), {16'd0,pp}>>>k, {16'd0,pp}<<<(0-k)), a 32-bit
//          mask subtract, 32-bit magnitude compares (rr>hh, rr==hh, q>=128,
//          q>255, q==0) and a 32-bit increment -- 121 of the 173 levels.
//          Here, using bounds that hold for every reachable input:
//            * the product's bit length comes from a two-level 4x4 priority
//              tree instead of a 16-deep `for` mux chain;
//            * the right-shift amount is <= 17 on a 17-bit register (4 mux
//              stages), and a >= 17 shift degenerates correctly: pp17[16]=0
//              gives guard=0, below(16)=all of pp gives sticky=1, inexact=1,
//              increment=0, quotient=0 -- exactly the release's `drop>=17`
//              branch, so that special case costs nothing;
//            * the left-shift amount is <= 7 (subnormal grid: ex+ey<=141
//              because bl>=1; normal grid: 8-bl<=7), 3 mux stages;
//            * guard/sticky replace the rr/hh pair: rr>hh == guard&&sticky and
//              rr==hh == guard&&!sticky, so the 32-bit compare becomes
//              increment = guard & (sticky | quotient[0]) and
//              inexact = guard | sticky, driven from a 5-to-17 index decoder;
//            * the exponent sum is carried as se=ex+ey (available long before
//              the product) plus a 5-bit bl, in 10 bits; the `q>255` clamp is
//              the single carry-out bit of an 8-bit increment, so instead of a
//              second 32-bit barrel shift the field becomes se+bl-142 or
//              se+bl-141, both computed in parallel and selected by that bit,
//              and the infinity test is two compares of (se+bl) against 396/397
//              which run beside the subtracts;
//            * the pattern is one mux tree steered by subnormal/infinity bits
//              rather than four nested `if` returns.
//
// Every temporary is assigned unconditionally before use (no latch inference),
// no loop bound depends on data, and there is no read-modify-write of a wide
// register inside the always @* block.
//
// Authored kernel. See ip/bf16_mul/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_bf16_mul_fast (
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
function [23:0] bf_num;
  input [7:0] ax; input [7:0] ay; input [7:0] ex; input [7:0] ey;
  input sgn; input [15:0] pp;
  reg        g3, g2, g1, g0;
  reg [1:0]  grp, i4;
  reg [3:0]  nib, msb;
  reg [4:0]  bl;
  reg [8:0]  se, t9;
  reg [9:0]  sbl, e0, e1;
  reg [4:0]  raS, raN, ra, gp;
  reg [3:0]  laS, laN, la;
  reg [16:0] p17, qr, oh, bm;
  reg [15:0] ql, qt;
  reg [8:0]  qs;
  reg        subn, pos, g, st, inc, inex, c8, hi, cl, ge, zero;
  reg        isinf, i0, i1;
  reg [7:0]  ef8, exp8;
  reg [6:0]  frs, frn, frac7;
  integer    m;
begin
  se   = {1'b0, ex} + {1'b0, ey};                 // max(E,1) sum, early
  g3 = |pp[15:12]; g2 = |pp[11:8];
  g1 = |pp[7:4];   g0 = |pp[3:0];                 // product bit length
  grp = g3 ? 2'd3 : (g2 ? 2'd2 : (g1 ? 2'd1 : 2'd0));
  nib = (grp == 2'd3) ? pp[15:12] :
        ((grp == 2'd2) ? pp[11:8] :
         ((grp == 2'd1) ? pp[7:4] : pp[3:0]));
  i4  = nib[3] ? 2'd3 : (nib[2] ? 2'd2 : (nib[1] ? 2'd1 : 2'd0));
  msb = {grp, i4};
  bl  = msb + 5'd1;                               // 1..16
  sbl = {1'b0, se} + {5'd0, bl};                  // se+bl, 10 bits
  subn = (sbl <= 10'd142);                        // eo = sbl-142 <= 0
  pos  = subn ? (se <= 9'd134) : (bl >= 5'd9);    // drop >= 1
  t9   = 9'd135 - se;                             // subnormal grid shift
  raS  = (se <= 9'd118) ? 5'd17 : ((se >= 9'd135) ? 5'd0 : t9[4:0]);
  laS  = (se >= 9'd142) ? 4'd7 : (se[3:0] - 4'd7);
  raN  = (bl >= 5'd9) ? (bl - 5'd8) : 5'd0;
  laN  = (bl <= 5'd8) ? (5'd8 - bl) : 4'd0;
  ra   = pos ? (subn ? raS : raN) : 5'd0;         // right shift 0..17
  la   = pos ? 4'd0 : (subn ? laS : laN);         // left shift 0..7
  gp   = pos ? (ra - 5'd1) : 5'd0;                // guard bit index 0..16
  p17  = {1'b0, pp};
  qr   = p17 >> ra;
  ql   = pp << la;
  oh   = 17'd0; bm = 17'd0;
  for (m = 0; m < 17; m = m + 1) begin
      oh[m] = (gp == m);
      bm[m] = (gp > m);
  end
  g    = pos & (|(p17 & oh));                     // guard = pp[drop-1]
  st   = pos & (|(p17 & bm));                     // sticky below the guard
  qt   = pos ? qr[15:0] : ql;                     // truncated quotient
  inc  = g & (st | qt[0]);                        // ties-to-even step
  inex = g | st;
  qs   = {1'b0, qt[7:0]} + {8'd0, inc};           // quotient + increment
  c8   = qs[8];
  hi   = |qt[15:8];
  cl   = hi | c8;                                 // the release's `q > 255`
  ge   = cl | qs[7];                              // the release's `q >= 128`
  zero = ~ge & (qs[7:0] == 9'd0);
  e0   = sbl - 10'd142;
  e1   = sbl - 10'd141;
  i0   = (sbl >= 10'd397);
  i1   = (sbl >= 10'd396);
  isinf = ~subn & (i0 | (cl & i1));
  ef8  = cl ? e1[7:0] : e0[7:0];
  exp8 = subn ? (ge ? 8'd1 : 8'd0) : (isinf ? 8'hff : ef8);
  frs  = qs[6:0];
  frn  = cl ? qs[6:1] : qs[6:0];
  frac7 = subn ? (ge ? 7'd0 : frs) : (isinf ? 7'd0 : frn);
  bf_num = {~subn & isinf, inex | isinf, inc, subn, subn & zero, 3'd0,
            {sgn, exp8, frac7}};
end
endfunction
reg [7:0] bax0, bay0, bex0, bey0, bax1, bay1, bex1, bey1;
reg bs0, bs1, bzero0, bzero1, binf0, binf1, bbad0, bbad1;
reg [15:0] bbx0, bby0, bbx1, bby1;
reg [23:0] bp0, bp1;
reg [15:0] bpr0, bpr1;
function [15:0] um8;
  input [7:0] u, v;
  reg [15:0] q0, q1, q2, q3, r0, r1;
begin
  q0 = {8'd0, u}  + (v[1] ? {7'd0, u, 1'b0} : 16'd0);
  q1 = (v[2] ? {6'd0, u, 2'd0} : 16'd0) + (v[3] ? {5'd0, u, 3'd0} : 16'd0);
  q2 = (v[4] ? {4'd0, u, 4'd0} : 16'd0) + (v[5] ? {3'd0, u, 5'd0} : 16'd0);
  q3 = (v[6] ? {2'd0, u, 6'd0} : 16'd0) + (v[7] ? {1'd0, u, 7'd0} : 16'd0);
  r0 = q0 + q1;
  r1 = q2 + q3;
  um8 = r0 + (r1 << 4);
end
endfunction
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    bbx0=a[15:0]; bby0=b[15:0]; bbx1=a[31:16]; bby1=b[31:16];
bex0=bbx0[14:7]; bey0=bby0[14:7]; bex1=bbx1[14:7]; bey1=bby1[14:7];
bax0=(bex0==8'd0) ? {1'b0,bbx0[6:0]} : {1'b1,bbx0[6:0]};
bay0=(bey0==8'd0) ? {1'b0,bby0[6:0]} : {1'b1,bby0[6:0]};
bax1=(bex1==8'd0) ? {1'b0,bbx1[6:0]} : {1'b1,bbx1[6:0]};
bay1=(bey1==8'd0) ? {1'b0,bby1[6:0]} : {1'b1,bby1[6:0]};
bs0=bbx0[15]^bby0[15]; bs1=bbx1[15]^bby1[15];
bzero0=1'b0; bzero1=1'b0; binf0=1'b0; binf1=1'b0;
bbad0=1'b0; bbad1=1'b0; bp0=24'd0; bp1=24'd0;
bpr0=um8(bax0,bay0); bpr1=um8(bax1,bay1);
if((bex0==8'hff && bbx0[6:0]!=7'd0) || (bey0==8'hff && bby0[6:0]!=7'd0))
    bbad0=1'b1;
if((bex1==8'hff && bbx1[6:0]!=7'd0) || (bey1==8'hff && bby1[6:0]!=7'd0))
    bbad1=1'b1;
if((bex0==8'hff && bay0==8'd0) || (bey0==8'hff && bax0==8'd0))
    bbad0=1'b1;
if(!bbad0) begin
    if((bex0==8'hff) || (bey0==8'hff)) begin
        binf0=1'b1; bp0={1'b1,1'b0,1'b0,1'b0,1'b0,3'd0,
                          {bs0,8'hff,7'd0}};
    end else if(bax0==8'd0 || bay0==8'd0) begin
        bzero0=1'b1; bp0={1'b0,1'b0,1'b0,1'b0,1'b1,3'd0,
                          {bs0,8'd0,7'd0}};
    end else bp0=bf_num(bax0,bay0,(bex0==8'd0)?8'd1:bex0,
                         (bey0==8'd0)?8'd1:bey0,bs0,bpr0[15:0]);
end
if((bex1==8'hff && bay1==8'd0) || (bey1==8'hff && bax1==8'd0))
    bbad1=1'b1;
if(!bbad1) begin
    if((bex1==8'hff) || (bey1==8'hff)) begin
        binf1=1'b1; bp1={1'b1,1'b0,1'b0,1'b0,1'b0,3'd0,
                          {bs1,8'hff,7'd0}};
    end else if(bax1==8'd0 || bay1==8'd0) begin
        bzero1=1'b1; bp1={1'b0,1'b0,1'b0,1'b0,1'b1,3'd0,
                          {bs1,8'd0,7'd0}};
    end else bp1=bf_num(bax1,bay1,(bex1==8'd0)?8'd1:bex1,
                         (bey1==8'd0)?8'd1:bey1,bs1,bpr1[15:0]);
end
if(bbad0 || bbad1) f=1'b1;
else begin
    r={bp1[15:0],bp0[15:0]};
    x[0]=bp0[23]; x[1]=bp0[19]; x[2]=bp0[22]; x[3]=bp0[21];
    x[4]=bp0[20]; x[5]=bp1[23]; x[6]=bp1[19]; x[7]=bp1[22];
    x[8]=bp1[21]; x[9]=bp1[20]; x[15:10]=6'd0; x[31:16]=bpr0[15:0];
end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f;
            end
        end
    end
end
endmodule
