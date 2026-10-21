// Authored kernel. See ip/biquad_cascade_step/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_biquad_cascade_step (
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
reg signed [63:0] xin, px1, px2, py1, py2, qx1, qo1, acc, acc2, yv;
reg [11:0] ys, zs;
reg c1, c2, bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    xin = $signed(a[11:0]);
px1 = c[31] ? 64'sd0 : $signed(state_r[11:0]);
px2 = c[31] ? 64'sd0 : $signed(state_r[23:12]);
py1 = c[31] ? 64'sd0 : $signed(state_r[35:24]);
py2 = c[31] ? 64'sd0 : $signed(state_r[47:36]);
qx1 = c[31] ? 64'sd0 : $signed(state_r[59:48]);
qo1 = c[31] ? 64'sd0 : $signed(state_r[71:60]);
acc = (xin<<<11) + (xin<<<9) + (px1<<<12) + (px1<<<10) + (px2<<<11) + (px2<<<9)
      + (py1<<<14) + (py1<<<10) - (py2<<<13) + (py2<<<11);
acc = (acc + 64'sd8192) >>> 14;
c1 = (acc > 64'sd2047) || (acc < -64'sd2048);
ys = acc > 64'sd2047 ? 12'h7ff : (acc < -64'sd2048 ? 12'h800 : acc[11:0]);
yv = acc > 64'sd2047 ? 64'sd2047 : (acc < -64'sd2048 ? -64'sd2048 : acc);
acc2 = c[0] ? (yv<<<14) : ((yv<<<13) - (qx1<<<13) + (qo1<<<13));
acc2 = (acc2 + 64'sd8192) >>> 14;
c2 = (acc2 > 64'sd2047) || (acc2 < -64'sd2048);
zs = acc2 > 64'sd2047 ? 12'h7ff : (acc2 < -64'sd2048 ? 12'h800 : acc2[11:0]);
bad = (c[30:1] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    r = {{20{zs[11]}}, zs};
    x[11:0] = ys;
    x[12] = c1;
    x[13] = c2;
    x[14] = c[0];
    x[15] = c[31];
    f = c1 | c2;
    state_n = 0;
    state_n[11:0] = a[11:0];
    state_n[23:12] = state_r[11:0];
    state_n[35:24] = ys;
    state_n[47:36] = state_r[35:24];
    state_n[59:48] = ys;
    state_n[71:60] = zs;
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
