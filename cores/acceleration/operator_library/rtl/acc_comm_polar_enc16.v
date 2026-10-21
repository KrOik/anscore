// Authored kernel. See ip/comm_polar_enc16/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_comm_polar_enc16 (
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
// Polar kernel G_16 = F^x4 with F=[[1,0],[1,1]]: output bit i is the XOR
// of the input bits j that are subsets of i. Input bit 0 therefore
// repeats into all sixteen outputs and input bit 15 only reaches output
// 15, which is the parity of the whole vector; output 0 is the identity.
wire [15:0] pl_u0 = a[15:0];
wire [15:0] pl_fz0 = b[15:0];
wire [15:0] pl_g0 = pl_u0 & ~pl_fz0;
wire pl_cf0 = |(pl_u0 & pl_fz0);
wire [15:0] pl_u1 = a[31:16];
wire [15:0] pl_fz1 = b[31:16];
wire [15:0] pl_g1 = pl_u1 & ~pl_fz1;
wire pl_cf1 = |(pl_u1 & pl_fz1);
wire [15:0] pl_v0 = c[31] ? {pl_g0[15], pl_g0[7], pl_g0[11], pl_g0[3], pl_g0[13], pl_g0[5], pl_g0[9], pl_g0[1], pl_g0[14], pl_g0[6], pl_g0[10], pl_g0[2], pl_g0[12], pl_g0[4], pl_g0[8], pl_g0[0]} : pl_g0;
wire [15:0] pl_v1 = c[31] ? {pl_g1[15], pl_g1[7], pl_g1[11], pl_g1[3], pl_g1[13], pl_g1[5], pl_g1[9], pl_g1[1], pl_g1[14], pl_g1[6], pl_g1[10], pl_g1[2], pl_g1[12], pl_g1[4], pl_g1[8], pl_g1[0]} : pl_g1;
wire [15:0] pl_x0;
assign pl_x0[0] = ^(pl_v0 & 16'h0001);
assign pl_x0[1] = ^(pl_v0 & 16'h0003);
assign pl_x0[2] = ^(pl_v0 & 16'h0005);
assign pl_x0[3] = ^(pl_v0 & 16'h000F);
assign pl_x0[4] = ^(pl_v0 & 16'h0011);
assign pl_x0[5] = ^(pl_v0 & 16'h0033);
assign pl_x0[6] = ^(pl_v0 & 16'h0055);
assign pl_x0[7] = ^(pl_v0 & 16'h00FF);
assign pl_x0[8] = ^(pl_v0 & 16'h0101);
assign pl_x0[9] = ^(pl_v0 & 16'h0303);
assign pl_x0[10] = ^(pl_v0 & 16'h0505);
assign pl_x0[11] = ^(pl_v0 & 16'h0F0F);
assign pl_x0[12] = ^(pl_v0 & 16'h1111);
assign pl_x0[13] = ^(pl_v0 & 16'h3333);
assign pl_x0[14] = ^(pl_v0 & 16'h5555);
assign pl_x0[15] = ^(pl_v0 & 16'hFFFF);
wire [15:0] pl_x1;
assign pl_x1[0] = ^(pl_v1 & 16'h0001);
assign pl_x1[1] = ^(pl_v1 & 16'h0003);
assign pl_x1[2] = ^(pl_v1 & 16'h0005);
assign pl_x1[3] = ^(pl_v1 & 16'h000F);
assign pl_x1[4] = ^(pl_v1 & 16'h0011);
assign pl_x1[5] = ^(pl_v1 & 16'h0033);
assign pl_x1[6] = ^(pl_v1 & 16'h0055);
assign pl_x1[7] = ^(pl_v1 & 16'h00FF);
assign pl_x1[8] = ^(pl_v1 & 16'h0101);
assign pl_x1[9] = ^(pl_v1 & 16'h0303);
assign pl_x1[10] = ^(pl_v1 & 16'h0505);
assign pl_x1[11] = ^(pl_v1 & 16'h0F0F);
assign pl_x1[12] = ^(pl_v1 & 16'h1111);
assign pl_x1[13] = ^(pl_v1 & 16'h3333);
assign pl_x1[14] = ^(pl_v1 & 16'h5555);
assign pl_x1[15] = ^(pl_v1 & 16'hFFFF);

function [5:0] pc32;                       // popcount of a 32-bit word
    input [31:0] v;
    reg [31:0] t;
    begin
        t = v - ((v >> 1) & 32'h55555555);
        t = (t & 32'h33333333) + ((t >> 2) & 32'h33333333);
        t = (t + (t >> 4)) & 32'h0F0F0F0F;
        t = t + (t >> 8);
        t = t + (t >> 16);
        pc32 = t[5:0];
    end
endfunction

function [5:0] tz32;                       // zeros below the lowest set bit, 32 if empty
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        t = v; n = 6'd0;
        if((t & 32'h0000FFFF) == 32'd0) begin n = n + 6'd16; t = t >> 16; end
        if((t & 32'h000000FF) == 32'd0) begin n = n + 6'd8;  t = t >> 8;  end
        if((t & 32'h0000000F) == 32'd0) begin n = n + 6'd4;  t = t >> 4;  end
        if((t & 32'h00000003) == 32'd0) begin n = n + 6'd2;  t = t >> 2;  end
        if((t & 32'h00000001) == 32'd0) begin n = n + 6'd1;  t = t >> 1;  end
        tz32 = (v == 32'd0) ? 6'd32 : n;
    end
endfunction

function [5:0] lz32;                       // zeros above the highest set bit, 32 if empty
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        t = v; n = 6'd0;
        if((t & 32'hFFFF0000) == 32'd0) begin n = n + 6'd16; t = t << 16; end
        if((t & 32'hFF000000) == 32'd0) begin n = n + 6'd8;  t = t << 8;  end
        if((t & 32'hF0000000) == 32'd0) begin n = n + 6'd4;  t = t << 4;  end
        if((t & 32'hC0000000) == 32'd0) begin n = n + 6'd2;  t = t << 2;  end
        if((t & 32'h80000000) == 32'd0) begin n = n + 6'd1;  t = t << 1;  end
        lz32 = (v == 32'd0) ? 6'd32 : n;
    end
endfunction

function [31:0] px32;                      // bit k = XOR of v[k:0], five XOR levels
    input [31:0] v;
    reg [31:0] t;
    begin
        t = v;
        t = t ^ (t << 1);
        t = t ^ (t << 2);
        t = t ^ (t << 4);
        t = t ^ (t << 8);
        t = t ^ (t << 16);
        px32 = t;
    end
endfunction


function [4:0] w16;                          // weight of one 16-bit lane word
    input [15:0] v;
    reg [5:0] t;
    begin
        t = pc32({16'd0, v});
        w16 = t[4:0];
    end
endfunction
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[30:1] != 30'd0) f = 1'b1;
else begin
    r = {pl_x1, pl_x0};
    x[4:0] = w16(pl_x0);
    x[9:5] = w16(pl_x1);
    x[14:10] = 5'd16 - w16(pl_fz0);
    x[19:15] = 5'd16 - w16(pl_fz1);
    x[20] = pl_cf0;
    x[21] = pl_cf1;
    x[22] = c[31];
    x[31:23] = 9'd0;
    if(pl_cf0 || pl_cf1) f = 1'b1;
end
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
