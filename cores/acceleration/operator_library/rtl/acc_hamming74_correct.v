// Authored kernel. See ip/hamming74_correct/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_hamming74_correct (
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
reg [7:0] h_w, h_flip;
reg [2:0] h_syn;
reg h_d1, h_d2, h_d3, h_d4, h_par, h_d7;
reg [3:0] h_zero, h_ded, h_corr, h_pf, h_nz, h_n, h_nib0;
reg [15:0] h_cnt, h_beats;
reg h_first, h_sameword;
wire h_bad = (b != 32'd0) || (c[29:0] != 30'd0);
wire [255:0] h_base = c[31] ? 256'd0 : state_r;
wire [15:0] h_prevcnt = h_base[79:64];
wire [15:0] h_prevbeats = h_base[95:80];
wire [31:0] h_preva = h_base[31:0];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    h_w=8'd0; h_flip=8'd0; h_syn=3'd0; h_d1=1'b0; h_d2=1'b0; h_d3=1'b0;
       h_d4=1'b0; h_par=1'b0; h_d7=1'b0; h_zero=4'd0; h_ded=4'd0; h_corr=4'd0;
       h_pf=4'd0; h_nz=4'd0; h_n=4'd0; h_nib0=4'd0; h_cnt=16'd0; h_beats=16'd0;
       h_first=1'b0; h_sameword=1'b0;
       if(h_bad) f = 1'b1;
       else begin
           for(lane=0; lane<4; lane=lane+1) begin
               sh = lane << 3;
               h_w = a[sh +: 8];
               h_d1 = h_w[2]; h_d2 = h_w[4]; h_d3 = h_w[5]; h_d4 = h_w[6];
               h_par = ^h_w[6:0];
               h_d7 = h_w[7] ^ h_par;
               h_syn = {h_w[3] ^ h_d2 ^ h_d3 ^ h_d4,
                        h_w[1] ^ h_d1 ^ h_d3 ^ h_d4,
                        h_w[0] ^ h_d1 ^ h_d2 ^ h_d4};
               if(h_syn != 3'd0) begin
                   h_nz[lane] = 1'b1;
                   if(h_d7) begin
                       h_flip = 8'h1 << (h_syn - 3'd1);
                       h_w = h_w ^ h_flip;
                       h_corr[lane] = 1'b1;
                       if(h_n != 4'd4) h_n = h_n + 4'd1;
                   end
                   else h_ded[lane] = 1'b1;
               end
               else begin
                   h_zero[lane] = 1'b1;
                   if(h_d7) begin
                       h_pf[lane] = 1'b1;
                   end
               end
               h_w[7] = ^h_w[6:0];
               if(lane == 0) h_nib0 = {h_w[6], h_w[5], h_w[4], h_w[2]};
               r = r | ({24'd0, h_w} << sh);
           end
           if(h_prevcnt > 32'hffff - {28'd0, h_n}) h_cnt = 16'hffff;
           else h_cnt = h_prevcnt + {12'd0, h_n};
           h_beats = (h_prevbeats == 16'hffff) ? 16'hffff
                                               : (h_prevbeats + 16'd1);
           h_first = (h_prevbeats == 16'd0);
           h_sameword = (a == h_preva);
           x = {h_nib0, h_n, (|h_corr), (h_prevcnt == 16'hffff), h_first, c[31],
                h_pf, h_zero, h_ded, h_corr, h_nz};
           state_n = {159'd0, 1'b1, h_beats, h_cnt, r, a};
           f = (|h_ded) || (h_prevcnt == 16'hffff);
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
