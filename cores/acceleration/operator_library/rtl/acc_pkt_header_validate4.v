// Authored kernel. See ip/pkt_header_validate4/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pkt_header_validate4 (
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
reg [15:0] runt, lim, tmax, lenf, tyf, verf, flf;
reg [7:0] vmask;
reg vb, e0, e1, e2, e3, g;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    runt = c[7:0];
lim = {c[15:8], 8'h00};
tmax = c[23:16];
vmask = c[31:24];
lenf = a[15:0];
tyf = a[31:16];
verf = b[15:0];
flf = b[31:16];
e0 = 1'b0; e1 = 1'b0; e2 = 1'b0; e3 = 1'b0; g = 1'b0;
vb = vmask[verf[2:0]];
if (lenf < runt) begin x[0] = 1'b1; e0 = 1'b1; end
if (lenf > lim) begin x[1] = 1'b1; e0 = 1'b1; end
if (lenf[1:0] != 2'd0) begin x[2] = 1'b1; e0 = 1'b1; end
x[3] = e0;
if (tyf == 16'd0) begin x[4] = 1'b1; e1 = 1'b1; end
if (tyf > tmax) begin x[5] = 1'b1; e1 = 1'b1; end
x[6] = e1; x[7] = 1'b0;
if (verf[15:4] != 12'd0) begin x[8] = 1'b1; e2 = 1'b1; end
if (verf[3]) begin x[9] = 1'b1; e2 = 1'b1; end
else if (!vb) begin x[10] = 1'b1; e2 = 1'b1; end
x[11] = e2;
if (flf[15:6] != 10'd0) begin x[12] = 1'b1; e3 = 1'b1; end
if (flf[4] && flf[5]) begin x[13] = 1'b1; e3 = 1'b1; end
x[14] = e3;
g = e0 | e1 | e2 | e3;
x[15] = g;
r[0] = !e0; r[1] = !e1; r[2] = !e2; r[3] = !e3;
r[4] = !g;
r[19:8] = (lenf + 16'd31) >> 5;
f = g;
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
