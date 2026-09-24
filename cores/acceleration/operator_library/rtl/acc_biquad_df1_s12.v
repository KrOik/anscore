// Authored kernel. See ip/biquad_df1_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_biquad_df1_s12 (
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
reg signed [63:0] x0, x1, x2, y1, y2, acc;
reg [11:0] ys;
reg cl, bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    x0 = $signed(a[11:0]);
x1 = c[31] ? 64'sd0 : $signed(state_r[11:0]);
x2 = c[31] ? 64'sd0 : $signed(state_r[23:12]);
y1 = c[31] ? 64'sd0 : $signed(state_r[35:24]);
y2 = c[31] ? 64'sd0 : $signed(state_r[47:36]);
case (c[1:0])
    2'd0: acc = (x0<<<11) + (x1<<<12) + (x2<<<11) + (y1<<<13) + (y1<<<12) - (y2<<<13);
    2'd1: acc = (x0<<<13) - (x1<<<13) + (y1<<<13);
    2'd2: acc = (x0<<<10) + (x1<<<11) + (x2<<<10) + (y1<<<14) + (y1<<<12) + (y1<<<11) - (y2<<<13) + (y2<<<10);
    2'd3: acc = (x1<<<12) + (y1<<<14) + (y1<<<12) - (y2<<<13) - (y2<<<12);
endcase
acc = (acc + 64'sd8192) >>> 14;
cl = (acc > 64'sd2047) || (acc < -64'sd2048);
ys = acc > 64'sd2047 ? 12'h7ff : (acc < -64'sd2048 ? 12'h800 : acc[11:0]);
bad = (c[30:2] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    r = {{20{ys[11]}}, ys};
    x[11:0] = state_r[35:24];
    x[23:12] = state_r[11:0];
    x[24] = cl;
    x[25] = c[31];
    f = cl;
    state_n = 0;
    state_n[11:0] = a[11:0];
    state_n[23:12] = state_r[11:0];
    state_n[35:24] = ys;
    state_n[47:36] = state_r[35:24];
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
