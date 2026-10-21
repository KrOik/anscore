// Authored kernel. See ip/envelope_ar/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_envelope_ar (
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
reg signed [63:0] xin, mag;
reg [19:0] eq8, tgt, enr, dec;
reg [15:0] gv;
reg [12:0] lvl;
reg [3:0] kk;
reg [1:0] gg;
reg at, rl, ocl, bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    bad = (c[30:6] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    xin = $signed({{20{a[11]}}, a[11:0]});
    mag = xin < 0 ? -xin : xin;
    gg = c[5:4];
    kk = {1'b0, c[2:0]} + 4'd1;
    eq8 = c[31] ? 20'd0 : state_r[19:0];
    tgt = mag <<< 8;
    at = (tgt > eq8);
    dec = eq8 >>> kk;
    enr = at ? tgt : (c[3] ? eq8 : (eq8 - dec));
    lvl = enr >> 8;
    gv = lvl << gg;
    ocl = gv > 16'd2047;
    rl = (~at) & (~c[3]);
    r = (ocl ? 12'd2047 : gv[11:0]);
    x = {2'b0, enr, c[3], c[2:0], c[5:4], ocl, at, rl, c[31]};
    f = ocl;
    state_n[19:0] = enr;
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
