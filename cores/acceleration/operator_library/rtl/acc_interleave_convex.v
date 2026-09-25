// Authored kernel. See ip/interleave_convex/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_interleave_convex (
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
reg [255:0] il_block, il_clear;
reg [31:0] il_addr, il_sym, il_sum, il_gath;
reg [15:0] il_addrn, il_beats;
reg [3:0] il_base, il_stride, il_a0, il_a1, il_a2, il_a3, il_newbase;
reg il_illegal, il_first, il_dup, il_overlap, il_started;
wire [1:0] il_mode = c[1:0];
wire [3:0] il_ctrl = c[5:2];
wire il_bad = (c[29:6] != 24'd0) || (il_mode == 2'b11);
wire [255:0] il_sb = c[31] ? 256'd0 : state_r;
wire [15:0] il_prevbeats = il_sb[143:128];
wire [15:0] il_prevaddr = il_sb[159:144];
wire [31:0] il_preva = il_sb[191:160];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    il_block=256'd0; il_clear=256'd0; il_addr=32'd0; il_sym=32'd0; il_sum=32'd0;
       il_gath=32'd0; il_addrn=16'd0; il_beats=16'd0; il_base=4'd0; il_stride=4'd0;
       il_newbase=4'd0; il_a0=4'd0; il_a1=4'd0; il_a2=4'd0; il_a3=4'd0;
       il_illegal=1'b0; il_first=1'b0; il_dup=1'b0; il_started=1'b0;
       il_overlap=1'b0;
       if(il_bad) f = 1'b1;
       else begin
           il_block = il_sb[127:0];
           il_base = il_sb[227:224];
           il_stride = il_ctrl;
           il_started = |il_sb[127:0];
           il_illegal = (il_mode != 2'b10) &&
                        ((il_stride == 4'd0) || (il_stride == 4'd8));
           il_overlap = (il_mode == 2'b00) && (il_stride != 4'd0) &&
                        (il_stride[1:0] == 2'b00);
           if(il_mode == 2'b00 || il_mode == 2'b01) begin
               for(i=0; i<4; i=i+1) begin
                   il_addr = {28'd0, il_base};
                   if(i & 1) il_addr = il_addr + {28'd0, il_stride};
                   if(i & 2) il_addr = il_addr + ({28'd0, il_stride} << 1);
                   il_addr = il_addr & 32'd15;
                   il_addrn = il_addrn | ({12'd0, il_addr[3:0]} << (i << 2));
                   if(i == 0) il_a0 = il_addr[3:0];
                   if(i == 1) il_a1 = il_addr[3:0];
                   if(i == 2) il_a2 = il_addr[3:0];
                   if(i == 3) il_a3 = il_addr[3:0];
                   if(!il_illegal) begin
                       if(il_mode == 2'b00) begin
                           il_sym = {24'd0, a[(i << 3) +: 8]};
                           il_clear = {248'd0, 8'hff} << (il_addr << 3);
                           il_block = (il_block & ~il_clear) |
                                      ({248'd0, il_sym[7:0]} << (il_addr << 3));
                       end
                       else begin
                           il_sym = {24'd0, il_block[(il_addr << 3) +: 8]};
                           il_gath = il_gath | ({24'd0, il_sym[7:0]} << (i << 3));
                       end
                       il_sum = il_sum + {24'd0, il_sym[7:0]};
                   end
               end
           end
           il_dup = (il_mode != 2'b10) && !il_illegal &&
                    ((il_a0 == il_a1) || (il_a0 == il_a2) || (il_a0 == il_a3) ||
                     (il_a1 == il_a2) || (il_a1 == il_a3) || (il_a2 == il_a3));
           il_beats = (il_prevbeats == 16'hffff) ? 16'hffff
                                                 : (il_prevbeats + 16'd1);
           il_first = (il_prevbeats == 16'd0);
           il_newbase = (il_mode == 2'b10) ? il_base
                                          : ((il_base + 4'd4) & 4'hf);
           if(il_illegal) begin
               r = 32'd0;
               x = 32'd0;
               f = 1'b1;
           end
           else begin
               r = (il_mode == 2'b01) ? il_gath
                   : ((il_mode == 2'b00) ? il_block[31:0] : 32'd0);
               x = {il_sum[7:0], il_prevaddr[7:0], (il_mode == 2'b00),
                    (il_mode == 2'b01), il_dup, il_overlap, il_started,
                    il_first, il_illegal, c[31], il_stride, il_base};
               f = (il_prevbeats == 16'hffff);
           end
           state_n = {23'd0,
                      (il_started || ((il_mode == 2'b00) && !il_illegal)),
                      il_stride, il_newbase, r, a, il_addrn, il_beats,
                      il_block[127:0]};
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
