// Authored kernel. See ip/ldpc_cn_minsum/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ldpc_cn_minsum (
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
reg [7:0] cn_mag1, cn_mag2;
reg [2:0] cn_arg;
reg [3:0] cn_tie, cn_zero;
reg [1:0] cn_dir;
reg [15:0] cn_cnt;
reg cn_par, cn_sat, cn_hist;
wire [3:0] cn_beta = c[3:0];
wire cn_bad = (c[30:4] != 27'd0);
wire [255:0] cn_base = c[31] ? 256'd0 : state_r;
wire cn_hist0 = cn_base[192];
wire [7:0] cn_prevmin = cn_base[135:128];
wire [15:0] cn_prevcnt = cn_base[175:160];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    cn_mag1=255; cn_mag2=255; cn_arg=3'd0; cn_tie=4'd0; cn_zero=4'd0;
       cn_dir=2'b00; cn_cnt=16'd0; cn_par=1'b0; cn_sat=1'b0; cn_hist=1'b0;
       wide=0; wide2=0; pa=0; ph=0;
       if(cn_bad) f = 1'b1;
       else begin
           for(i=0; i<8; i=i+1) begin
               idx = (i < 4) ? (i + 8) : i;
               temp = data[(idx << 3) +: 8];
               if(temp[7]) pa = pa | (32'h1 << i);
               pl = temp[7] ? (32'h100 - temp) : temp;
               if(pl == 128) cn_sat = 1'b1;
               if(pl > 127) pl = 127;
               if(pl > cn_beta) pl = pl - cn_beta;
               else pl = 32'd0;
               wide[(i << 3) +: 8] = pl[7:0];
           end
           for(i=0; i<8; i=i+1) begin
               pc = wide[(i << 3) +: 8];
               if(pc < {24'd0, cn_mag1}) begin
                   cn_mag2 = cn_mag1;
                   cn_mag1 = pc[7:0];
                   cn_arg = i[2:0];
               end
               else if(pc < {24'd0, cn_mag2}) cn_mag2 = pc[7:0];
           end
           for(i=0; i<8; i=i+1) begin
               pc = wide[(i << 3) +: 8];
               if(pc == {24'd0, cn_mag1}) cn_tie = cn_tie + 4'd1;
               if(pc == 32'd0) cn_zero = cn_zero + 4'd1;
           end
           cn_par = ^pa;
           cn_hist = cn_hist0;
           if(!cn_hist0) cn_dir = 2'b11;
           else if(cn_mag1 == cn_prevmin) cn_dir = 2'b00;
           else if(cn_mag1 < cn_prevmin) cn_dir = 2'b01;
           else cn_dir = 2'b10;
           for(i=0; i<8; i=i+1) begin
               pc = (i == cn_arg) ? cn_mag2 : cn_mag1;
               pl = (((pa >> i) & 32'h1) ^ cn_par) & 32'h1;
               if(pl) begin
                   ph = ph | (32'h1 << i);
                   mask = (32'h100 - pc) & 32'hff;
               end
               else mask = pc;
               wide2[(i << 3) +: 8] = mask[7:0];
           end
           cn_cnt = (cn_prevcnt == 16'hffff) ? 16'hffff : (cn_prevcnt + 16'd1);
           r = {6'd0, cn_sat, cn_par, pa[7:0], cn_mag2, cn_mag1};
           x = {cn_zero, cn_hist, cn_dir, (!cn_hist0), cn_tie, cn_arg, cn_par,
                ph[7:0], ((8'h1 << cn_arg) & 8'hff)};
           state_n = {32'd0, 32'h1, {16'd0, cn_cnt}, r, wide2, b, a};
           f = cn_sat || (cn_prevcnt == 16'hffff);
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
