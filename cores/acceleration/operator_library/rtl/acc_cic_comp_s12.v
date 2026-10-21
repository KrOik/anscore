// Authored kernel. See ip/cic_comp_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_cic_comp_s12 (
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
reg signed [63:0] xin, i1, i2, d1, d2, t1, t2, t3, t4, yv;
reg [19:0] n1v, n2v, w3;
reg [11:0] h12;
reg [2:0] l2, msk, oldph, phn;
reg [3:0] gsh;
reg [4:0] ov;
reg fin, bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    xin = $signed(a[11:0]);
l2 = c[2:0];
msk = (3'd1 << l2) - 3'd1;
gsh = {l2, 1'b0};
oldph = c[31] ? 3'd0 : state_r[82:80];
i1 = c[31] ? 64'sd0 : $signed(state_r[19:0]);
i2 = c[31] ? 64'sd0 : $signed(state_r[39:20]);
d1 = c[31] ? 64'sd0 : $signed(state_r[59:40]);
d2 = c[31] ? 64'sd0 : $signed(state_r[79:60]);
w3 = 20'd0;
t3 = 64'sd0;
t4 = 64'sd0;
yv = 64'sd0;
ov = 5'd0;
fin = (oldph == msk);
phn = (oldph + 3'd1) & msk;
t1 = i1 + xin;
n1v = (t1 > 64'sd524287) ? 20'h7ffff : ((t1 < -64'sd524288) ? 20'h80000 : t1[19:0]);
t2 = i2 + $signed(n1v);
n2v = (t2 > 64'sd524287) ? 20'h7ffff : ((t2 < -64'sd524288) ? 20'h80000 : t2[19:0]);
ov[0] = (t1 > 64'sd524287) || (t1 < -64'sd524288);
ov[1] = (t2 > 64'sd524287) || (t2 < -64'sd524288);
if (fin) begin
    t3 = $signed(n2v) - d1;
    w3 = (t3 > 64'sd524287) ? 20'h7ffff : ((t3 < -64'sd524288) ? 20'h80000 : t3[19:0]);
    t4 = $signed(w3) - d2;
    yv = (t4 + (64'sd1 <<< (gsh - 4'd1))) >>> gsh;
    ov[2] = (t3 > 64'sd524287) || (t3 < -64'sd524288);
    ov[3] = (t4 > 64'sd524287) || (t4 < -64'sd524288);
    ov[4] = (yv > 64'sd2047) || (yv < -64'sd2048);
    h12 = (yv > 64'sd2047) ? 12'h7ff : ((yv < -64'sd2048) ? 12'h800 : yv[11:0]);
end else begin
    h12 = state_r[95:84];
end
bad = (c[30:3] != 0) || (l2 < 2) || (l2 > 3);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    r = {{20{h12[11]}}, h12};
    x[4:0] = ov;
    x[5] = fin;
    x[8:6] = phn;
    x[28:9] = n1v;
    f = (ov != 0);
    state_n = 0;
    state_n[19:0] = n1v;
    state_n[39:20] = n2v;
    state_n[59:40] = fin ? n2v : state_r[59:40];
    state_n[79:60] = fin ? w3 : state_r[79:60];
    state_n[82:80] = phn;
    state_n[95:84] = h12;
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
