// STAGED SCRATCH FILE -- not a release artifact, generated nothing in rtl/.
// Timing-oriented rewrite of the pkt_token_meter_color authored kernel.
// Same port list, same handshake wrapper, same 256-bit state register and the
// same enabled-ready-valid-32x3-v1 semantics as rtl/acc_pkt_token_meter_color.v.
//
// Semantics come from ip/pkt_token_meter_color/SPEC.md and are unchanged:
//   result[23:0]=balance, [24]=RED, [25]=balance clamped to CBS,
//   [26]=reserved-config fault, [31:27]=0;
//   aux[15:0]=delta, aux[27:16]=credit[11:0], aux[28]=credit saturated,
//   aux[29]=GREEN, aux[30]=reserved nonzero, aux[31]=restart echo;
//   state_n[23:0]=balance, state_n[39:24]=T; fault = RED or reserved nonzero.
//
// What changed is only the cone shape (see tools/_staged/ notes in the report):
//   1. delta is 16 bits and scl is 4 bits, so delta<<scl never exceeds bit 30;
//      the 64-bit raw and its 64-bit magnitude compare are replaced by a 32-bit
//      shift plus a 7-input reduction OR (saturation is |raw32[31:24]).
//   2. min(a,b)-p = min(a-p,b-p) for p<=min(a,b), so the post-consume balance
//      is a select between the two independent subtractions sumv-plen and
//      cbs-plen, steered by the pre-existing clamp flag (sumv>cbs) instead of a
//      third carry chain that compares the two differences.
//   3. RED is the OR of the two borrow-outs of exactly those subtractions, so
//      the old clamp-compare -> balance-mux -> red-compare -> balance-subtract
//      chain becomes two parallel chains that both start at sumv, followed by
//      one two-level mux.
// Authored kernel. See ip/pkt_token_meter_color/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pkt_token_meter_color_fast (
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
reg [15:0] t16, delta, tm, plen;
reg [23:0] cbs, tok, cre, bal;
reg [24:0] sumv;
reg [22:0] ini;
reg [7:0] rsv;
reg [3:0] scl;
reg [31:0] raw32;          // delta<<scl fits 32 bits; bits 31:24 are saturation
reg [25:0] csum;           // {1'b1,sumv}-plen: [25]=no-borrow, [23:0]=sumv-plen
reg [24:0] cest;           // {1'b1,cbs}-plen:   [24]=no-borrow, [23:0]=cbs-plen
reg red, clm, xs;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    csum=26'd0; cest=25'd0; raw32=32'd0; xs=1'b0; clm=1'b0; red=1'b0;
    sumv=25'd0; cre=24'd0; bal=24'd0; tok=24'd0; tm=16'd0;
    t16 = a[31:16];
plen = a[15:0];
cbs = b[23:0];
rsv = b[31:24];
scl = c[3:0];
ini = c[30:8];
if (c[31]) begin tok = {1'b0, ini}; tm = 16'd0; end
else begin tok = state_r[23:0]; tm = state_r[39:24]; end
delta = t16 - tm;
raw32 = {16'd0, delta} << scl;
xs = |raw32[31:24];
cre = xs ? 24'hffffff : raw32[23:0];
sumv = {1'b0, tok} + {1'b0, cre};
cest = {1'b1, cbs} - {1'b0, plen};
csum = {1'b1, sumv} - {2'b0, plen};
clm = sumv > {1'b0, cbs};
red = ~csum[25] | ~cest[24];
if (red) bal = clm ? cbs : sumv[23:0];
else bal = clm ? cest[23:0] : csum[23:0];
x[15:0] = delta;
x[27:16] = cre[11:0];
x[28] = xs;
x[29] = !red;
x[30] = (rsv != 8'd0);
x[31] = c[31];
r[23:0] = bal;
r[24] = red;
r[25] = clm;
r[26] = (rsv != 8'd0);
f = red | (rsv != 8'd0);
state_n = {216'd0, t16, bal};
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
