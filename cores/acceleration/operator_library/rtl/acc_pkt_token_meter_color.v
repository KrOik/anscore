// Authored kernel. See ip/pkt_token_meter_color/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pkt_token_meter_color (
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
reg [31:0] raw32;
reg [25:0] csum;
reg [24:0] cest;
reg red, clm, xs;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
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
clm = sumv > {1'b0, cbs};
cest = {1'b1, cbs} - {1'b0, plen};
csum = {1'b1, sumv} - {2'b0, plen};
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
