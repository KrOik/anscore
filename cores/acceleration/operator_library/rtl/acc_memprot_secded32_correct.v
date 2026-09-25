// Authored kernel. See ip/memprot_secded32_correct/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_memprot_secded32_correct (
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

assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    pa = a & 32'h56AAAD5B;
pb = a & 32'h9B33366D;
pc = a & 32'hE3C3C78E;
ph = a & 32'h03FC07F0;
pl = a & 32'h03FFF800;
temp = a & 32'hFC000000;
mask = ({^temp, ^pl, ^ph, ^pc, ^pb, ^pa} ^ b[5:0]) & 32'h0000003F;
x[5:0] = mask;
x[6] = (^a) ^ (^b[5:0]) ^ b[6];
r = a;
x[18:13] = 6'd63;
if(mask == 32'd0 && !x[6]) begin
    x[19] = 1'b1;
end else if(x[6]) begin
    sh = 0;
    if(mask[5]) sh = 5; else if(mask[4]) sh = 4; else if(mask[3]) sh = 3;
    else if(mask[2]) sh = 2; else if(mask[1]) sh = 1;
    if(mask == 32'd0) begin
        x[18:13] = 6'd38; x[7] = 1'b1;
    end else if(mask & (mask - 32'd1)) begin
        if(mask <= 32'd38) begin
            idx = mask - 32'd2 - sh;
            r = a ^ (32'd1 << idx);
            x[7] = 1'b1; x[18:13] = idx;
        end else x[9] = 1'b1;
    end else begin
        x[10] = 1'b1; x[7] = 1'b1; x[18:13] = 6'd32 + sh;
    end
end else if(mask != 32'd0) begin
    x[8] = 1'b1;
end
if(x[8] || x[9]) f = 1'b1;
if(r == 32'hFFFFFFFF) begin
    x[11] = 1'b1;
    if(!c[0]) f = 1'b1;
end else if(c[0]) f = 1'b1;
x[12] = c[0];
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
