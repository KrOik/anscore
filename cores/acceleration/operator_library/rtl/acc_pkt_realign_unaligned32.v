// Authored kernel. See ip/pkt_realign_unaligned32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pkt_realign_unaligned32 (
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
reg [5:0] res, need, avail, left;
reg [3:0] sh4, kp, kpe;
reg [128:0] big, bm;
reg [127:0] resb, nw, nres;
reg [191:0] win;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    res = c[31] ? 6'd0 : state_r[5:0];
sh4 = c[3:0];
kp = c[7:4];
kpe = (kp > 4'd8) ? 4'd8 : kp;
big = {129'd1} << {res, 3'd0};
bm = big - 129'd1;
resb = {state_r[135:8], 120'd0} >> 120;
resb = resb & bm;
nw = {128'd0, b, a};
big = {129'd1} << {4'd0, kpe, 3'd0};
bm = big - 129'd1;
nw = nw & bm;
win = ({64'd0, nw} << {res, 3'd0}) | {64'd0, resb};
need = {2'd0, sh4} + 6'd4;
avail = res + {2'd0, kpe};
if (avail < need) left = 6'd0;
else if ((avail - need) > 6'd16) left = 6'd16;
else left = avail - need;
r = (win >> {4'd0, sh4, 3'd0}) & 32'hffffffff;
nres = (win >> {4'd0, sh4, 3'd0}) >> 32;
big = {129'd1} << {left, 3'd0};
bm = big - 129'd1;
nres = nres & bm;
if (avail < need) begin x[18] = 1'b1; f = 1'b1; end
else if (avail > need + 6'd16) begin x[18] = 1'b1; f = 1'b1; end
if (c[8] && left != 0) begin x[19] = 1'b1; f = 1'b1; end
if (kp > 4'd8) begin x[20] = 1'b1; f = 1'b1; end
x[4:0] = left[4:0];
x[9:5] = res[4:0];
x[13:10] = kpe;
x[17:14] = sh4;
x[21] = c[8];
x[22] = c[31];
x[31] = c[31];
state_n = {120'd0, nres, 2'd0, left};
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
