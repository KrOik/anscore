// Authored kernel. See ip/dsm2_mod/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_dsm2_mod (
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
reg signed [63:0] xin, x1, x2, v, yd, t1, t2;
reg [11:0] x1n, x2n;
reg [2:0] ns, cnt;
reg pdm, ov, bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    bad = (c[30:2] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    ns = {2'd0, c[1:0]} + 3'd1;
    xin = $signed({{20{a[11]}}, a[11:0]});
    x1 = c[31] ? 64'sd0 : $signed(state_r[11:0]);
    x2 = c[31] ? 64'sd0 : $signed(state_r[23:12]);
    ov = 1'b0;
    cnt = 3'd0;
    pdm = 1'b0;
    for (i = 0; i < 4; i = i + 1) begin
        if (i < ns) begin
            v = x2 + (x1 >>> 1);
            pdm = (v >= 64'sd0);
            yd = pdm ? 64'sd2046 : -64'sd2046;
            cnt = cnt + {2'd0, pdm};
            t1 = x1 + ((xin - yd) >>> 1);
            t2 = x2 + (x1 >>> 1) - (yd >>> 1);
            x1n = (t1 > 64'sd2047) ? 12'h7ff :
                  ((t1 < -64'sd2048) ? 12'h800 : t1[11:0]);
            x2n = (t2 > 64'sd2047) ? 12'h7ff :
                  ((t2 < -64'sd2048) ? 12'h800 : t2[11:0]);
            ov = ov | (t1 > 64'sd2047) | (t1 < -64'sd2048)
                   | (t2 > 64'sd2047) | (t2 < -64'sd2048);
            x1 = $signed({{52{x1n[11]}}, x1n});
            x2 = $signed({{52{x2n[11]}}, x2n});
        end
    end
    r = pdm ? 32'sd2046 : -32'sd2046;
    x = {x2n, x1n, 2'b0, c[31], ov, cnt, pdm};
    f = ov;
    state_n[11:0] = x1n;
    state_n[23:12] = x2n;
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
