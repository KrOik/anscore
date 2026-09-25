// Authored kernel. See ip/mt_speed/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_mt_speed (
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
// Image generated from the family model; read combinationally here.
reg [10:0] rec [0:127];
initial $readmemh("tables/mt_speed_recip.mem", rec);
reg [11:0] ms_a, ms_b;
reg signed [11:0] nv, rn;
reg signed [13:0] magx, an;
reg [11:0] pv, pp;
reg [11:0] to, to0;
reg [8:0] un, rni;
reg [4:0] shf;
reg signed [6:0] sgn;
reg [3:0] mb, Sv, Tv;
reg signed [31:0] mag, sp, spc;
reg ovr, und, npr, tf;
wire [23:0] ms1_raw;
wire signed [23:0] ms1 = $signed(ms1_raw);
MULT12X12 u_ms1 (.DOUT(ms1_raw), .A(ms_a), .B(ms_b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    nv = $signed(a[10:0]);
pv = b[11:0];
Sv = c[7:4];
Tv = c[11:8];
if(c[31]) begin pp = 12'd0; to0 = 12'd0; end
else begin
    pp = state_r[11:0];
    to0 = state_r[35:24];
end
magx = nv;
an = (nv < 12'sd0) ? -magx : magx;
mb = 4'd0;
for(i=1; i<12; i=i+1) if(pv[i]) mb = i;
un = (mb > 4'd7) ? (pv >> (mb - 4'd7)) : (pv << (4'd7 - mb));
rni = (un >= 9'd128 && un <= 9'd255) ? (un - 9'd128) : 9'd0;
rn = rec[rni[7:0]];
ms_a = an[11:0];
ms_b = rn;
shf = {1'b0, mb} + 5'd10;
sgn = $signed({2'b00, shf}) - $signed({3'b000, Sv});
if(nv == 12'sd0 || pv == 12'd0) mag = 32'sd0;
else if(sgn >= 7'sd0) begin
    swide = ms1 + (sgn == 7'd0 ? 64'sd0 : (64'sd1 <<< (sgn - 7'd1)));
    mag = swide >>> sgn;
end else begin
    swide = ms1 <<< (-sgn);
    mag = swide;
end
sp = (nv < 12'sd0) ? -mag : mag;
ovr = (sp > 32'sd2047) || (sp < -32'sd2048);
und = (nv != 12'sd0) && (pv != 12'd0) && (mag == 32'sd0);
npr = (pv == 12'd0) && (nv != 12'sd0);
if(sp > 32'sd2047)         spc = 32'sd2047;
else if(sp < -32'sd2048)   spc = -32'sd2048;
else                       spc = sp;
if(nv != 12'sd0)           to = 12'd0;
else if(to0 == 12'hfff)    to = 12'hfff;
else                       to = to0 + 12'd1;
tf = (Tv != 4'd0) && (to > {8'd0, Tv});
if(a[31:11]!=0 || b[31:12]!=0 || c[3:0]!=0 || c[30:12]!=0) f=1'b1;
else begin
    state_n[11:0] = pv;
    state_n[23:12] = nv[11:0];
    state_n[35:24] = to;
    state_n[47:36] = spc[11:0];
    r = {15'd0, c[31], npr, tf, und, ovr, spc[11:0]};
    x = {Sv, mb, to, pv - pp};
    f = ovr || und || npr || tf;
end
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
