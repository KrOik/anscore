// Authored kernel. See ip/memprot_secded32_encode/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_memprot_secded32_encode (
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
mask = {^temp, ^pl, ^ph, ^pc, ^pb, ^pa};
r[5:0] = mask[5:0];
r[6] = (^a) ^ (^mask[5:0]);
x[0] = ^a[7:0];
x[1] = ^a[15:8];
x[2] = ^a[23:16];
x[3] = ^a[31:24];
x[4] = ^(a & 32'h0000FFFF);
x[5] = ^(a >> 16);
x[31:16] = a[31:16] ^ a[15:0];
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
