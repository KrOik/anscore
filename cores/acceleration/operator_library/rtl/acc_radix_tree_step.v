// Authored kernel. See ip/radix_tree_step/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_radix_tree_step (
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
// Image generated from the family model; read combinationally here.
reg [15:0] radmap [0:63];
initial $readmemh("tables/radix_tree_step_nodes.mem", radmap);
reg [7:0] n_idx, n_addr;
reg [15:0] n_w1, n_w2;
reg [11:0] n_pay, n_first, n_xorb;
reg [1:0] n_child, n_fidx;
reg [2:0] n_cause;
reg [3:0] n_ind, n_hitm, n_absm, n_flm, n_colm, n_deepm;
reg [3:0] n_chasem, n_rep;
reg [23:0] n_hist, n_histprev;
reg [31:0] n_digest;
reg [7:0] n_look, n_hit8, n_col8, n_abs8, n_fl8, n_ind8, n_beat;
reg n_kv, n_expect, n_second, n_anyfirst, n_stkfl, n_stkab;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_kv = (c[30:4] != 27'd0) || (b != 32'd0);
       if (n_kv) begin
           f = 1'b1;
       end
       else begin
           state_n = c[31] ? 256'd0 : state_r;
           n_hitm = 4'd0;
           n_absm = 4'd0;
           n_flm = 4'd0;
           n_colm = 4'd0;
           n_deepm = 4'd0;
           n_chasem = 4'd0;
           n_rep = 4'd0;
           n_xorb = 12'h000;
           n_first = 12'h000;
           n_fidx = 2'd0;
           n_anyfirst = 1'b0;
           n_ind = 4'd0;
           n_look = state_n[7:0];
           n_hit8 = state_n[15:8];
           n_col8 = state_n[23:16];
           n_abs8 = state_n[31:24];
           n_fl8 = state_n[39:32];
           n_ind8 = state_n[47:40];
           n_beat = state_n[55:48];
           n_digest = state_n[87:56];
           n_histprev = state_n[113:90];
           n_hist = state_n[113:90];
           for (lane=0; lane<4; lane=lane+1) begin
               if (lane == 0) n_idx = a[7:0];
               else if (lane == 1) n_idx = a[15:8];
               else if (lane == 2) n_idx = a[23:16];
               else n_idx = a[31:24];
               n_expect = c[lane];
               n_pay = 12'h000;
               n_second = 1'b0;
               n_addr = {2'd0, n_idx[7:4]};
               n_w1 = radmap[n_addr];
               n_ind = n_ind + 4'd1;
               if (n_ind8 != 8'hff) n_ind8 = n_ind8 + 8'd1;
               if (!n_w1[15]) n_cause = 3'd2;
               else if (n_w1[14]) begin
                   n_pay = n_w1[11:0];
                   n_cause = n_expect ? 3'd5 : 3'd3;
               end
               else begin
                   if (n_expect) n_cause = 3'd4;
                   else begin
                       n_child = n_w1[13:12];
                       n_addr = {n_child, n_idx[3:0]};
                       n_w2 = radmap[n_addr];
                       n_second = 1'b1;
                       n_ind = n_ind + 4'd1;
                       if (n_ind8 != 8'hff) n_ind8 = n_ind8 + 8'd1;
                       if (!n_w2[15]) n_cause = 3'd2;
                       else if (n_w2[14]) begin
                           n_pay = n_w2[11:0];
                           n_cause = 3'd1;
                       end
                       else n_cause = 3'd4;
                   end
               end
               if (n_look != 8'hff) n_look = n_look + 8'd1;
               if (n_cause == 3'd1 || n_cause == 3'd5) begin
                   n_hitm[lane] = 1'b1;
                   if (n_cause == 3'd5) begin
                       n_colm[lane] = 1'b1;
                       if (n_col8 != 8'hff) n_col8 = n_col8 + 8'd1;
                   end
                   else if (n_hit8 != 8'hff) n_hit8 = n_hit8 + 8'd1;
                   if (!n_anyfirst) begin
                       n_anyfirst = 1'b1;
                       n_first = n_pay;
                       n_fidx = lane;
                   end
               end
               if (n_cause == 3'd2) begin
                   n_absm[lane] = 1'b1;
                   if (n_abs8 != 8'hff) n_abs8 = n_abs8 + 8'd1;
               end
               if (n_cause == 3'd3) begin
                   n_flm[lane] = 1'b1;
                   if (n_fl8 != 8'hff) n_fl8 = n_fl8 + 8'd1;
                   f = 1'b1;
               end
               if (n_cause == 3'd4) begin
                   n_flm[lane] = 1'b1;
                   n_deepm[lane] = 1'b1;
                   if (n_fl8 != 8'hff) n_fl8 = n_fl8 + 8'd1;
                   f = 1'b1;
               end
               if (n_second) n_chasem[lane] = 1'b1;
               if (!c[31] && (n_cause == 3'd1 || n_cause == 3'd5))
                   if (n_addr == n_histprev[(lane << 2) + (lane << 1) +: 6])
                       n_rep[lane] = 1'b1;
               n_hist = (n_hist << 6) | {2'd0, n_addr};
               n_xorb = n_xorb ^ n_pay;
               n_digest = n_digest ^ {20'd0, n_pay};
           end
           if (n_beat != 8'hff) n_beat = n_beat + 8'd1;
           n_stkfl = state_n[88] || (n_flm != 4'd0);
           n_stkab = state_n[89] || (n_absm != 4'd0);
           r[3:0] = n_hitm;
           r[7:4] = n_absm;
           r[11:8] = n_flm;
           r[15:12] = n_colm;
           r[19:16] = n_deepm;
           r[23:20] = n_ind;
           r[24] = c[31];
           r[25] = (n_chasem != 4'd0);
           r[26] = (n_flm == 4'd0);
           r[27] = (n_hitm == 4'hf);
           r[28] = (n_absm == 4'hf);
           r[29] = (n_hitm != 4'd0);
           r[30] = (n_absm != 4'd0);
           r[31] = (n_flm != 4'd0);
           x[11:0] = n_xorb;
           x[23:12] = n_first;
           x[25:24] = n_fidx;
           x[29:26] = n_rep;
           x[30] = n_stkfl;
           x[31] = n_stkab;
           state_n[7:0] = n_look;
           state_n[15:8] = n_hit8;
           state_n[23:16] = n_col8;
           state_n[31:24] = n_abs8;
           state_n[39:32] = n_fl8;
           state_n[47:40] = n_ind8;
           state_n[55:48] = n_beat;
           state_n[87:56] = n_digest;
           state_n[88] = n_stkfl;
           state_n[89] = n_stkab;
           state_n[113:90] = n_hist;
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
