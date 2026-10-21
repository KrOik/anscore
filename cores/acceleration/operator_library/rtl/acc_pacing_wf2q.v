// Authored kernel. See ip/pacing_wf2q/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pacing_wf2q (
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
reg [3:0] n_w, n_len, n_ww;
reg [15:0] n_d, n_q, n_pay, n_dn, n_best;
reg [16:0] n_s;
reg [7:0] n_srv, n_age, n_thresh, n_rounds, n_maxage;
reg [3:0] n_servm, n_starvem, n_idlem, n_backm, n_agedm, n_prevmask;
reg [2:0] n_sc;
reg [1:0] n_win, n_maxflow, n_prevwin;
reg n_kv, n_ok, n_have, n_havemax, n_tie, n_satnow, n_starm, n_blk;
reg n_repeat, n_prevalid, n_stkstarve, n_stksat;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_kv = (c[30:24] != 7'd0);
       if (n_kv) begin
           f = 1'b1;
       end
       else begin
           state_n = c[31] ? 256'd0 : state_r;
           n_thresh = c[23:16];
           n_prevwin = state_n[139:138];
           n_prevmask = state_n[143:140];
           n_prevalid = state_n[144];
           n_rounds = state_n[135:128];
           n_servm = 4'd0;
           n_starvem = 4'd0;
           n_idlem = 4'd0;
           n_backm = 4'd0;
           n_satnow = 1'b0;
           n_starm = 1'b0;
           n_tie = 1'b0;
           n_have = 1'b0;
           n_havemax = 1'b0;
           n_best = 16'h0000;
           n_win = 2'd0;
           n_maxage = 8'd0;
           n_maxflow = 2'd0;
           n_sc = 3'd0;
           for (lane=0; lane<4; lane=lane+1) begin
               if (lane == 0) begin n_w = b[3:0]; n_len = a[3:0]; n_blk = a[16]; end
               else if (lane == 1) begin n_w = b[7:4]; n_len = a[7:4]; n_blk = a[17]; end
               else if (lane == 2) begin n_w = b[11:8]; n_len = a[11:8]; n_blk = a[18]; end
               else begin n_w = b[15:12]; n_len = a[15:12]; n_blk = a[19]; end
               n_d = state_n[(lane << 4) +: 16];
               n_srv = state_n[(64 + (lane << 3)) +: 8];
               n_age = state_n[(96 + (lane << 3)) +: 8];
               n_q = {2'd0, n_w, 6'd0};
               n_pay = {2'd0, n_len, 6'd0};
               n_s = {1'b0, n_d} + {1'b0, n_q};
               if (n_s[16]) begin
                   n_s = 17'h0ffff;
                   n_satnow = 1'b1;
               end
               n_ok = n_blk && (n_s[15:0] >= n_pay);
               if (n_ok) begin
                   n_dn = n_s[15:0] - n_pay;
                   n_servm[lane] = 1'b1;
                   n_sc = n_sc + 3'd1;
                   n_age = 8'd0;
                   if (n_srv != 8'hff) n_srv = n_srv + 8'd1;
               end
               else begin
                   n_dn = n_s[15:0];
                   if (n_blk) begin
                       if (n_age == 8'hff) n_satnow = 1'b1;
                       else n_age = n_age + 8'd1;
                       if ((n_thresh != 8'd0) && (n_age >= n_thresh)) begin
                           n_starvem[lane] = 1'b1;
                           n_starm = 1'b1;
                       end
                   end
                   else begin
                       n_idlem[lane] = 1'b1;
                       n_age = 8'd0;
                   end
               end
               state_n[(lane << 4) +: 16] = n_dn;
               state_n[(64 + (lane << 3)) +: 8] = n_srv;
               state_n[(96 + (lane << 3)) +: 8] = n_age;
               if (n_blk) begin
                   n_backm[lane] = 1'b1;
                   if (!n_have || (n_dn < n_best)) begin
                       n_have = 1'b1;
                       n_best = n_dn;
                       n_win = lane;
                   end
                   else if (n_dn == n_best) n_tie = 1'b1;
                   if (!n_havemax || (n_age > n_maxage)) begin
                       n_havemax = 1'b1;
                       n_maxage = n_age;
                       n_maxflow = lane;
                   end
               end
           end
           if (!n_have) n_ww = 4'h0;
           else if (n_win == 2'd0) n_ww = b[3:0];
           else if (n_win == 2'd1) n_ww = b[7:4];
           else if (n_win == 2'd2) n_ww = b[11:8];
           else n_ww = b[15:12];
           n_agedm = n_backm & ~n_servm;
           n_repeat = n_have && n_prevalid && (n_win == n_prevwin);
           if (n_rounds == 8'hff) n_satnow = 1'b1;
           else n_rounds = n_rounds + 8'd1;
           n_stkstarve = state_n[136] | n_starm;
           n_stksat = state_n[137] | n_satnow;
           r[1:0] = n_have ? n_win : 2'd0;
           r[2] = n_have;
           r[6:3] = n_servm;
           r[10:7] = n_starvem;
           r[14:11] = n_idlem;
           r[15] = n_tie;
           r[19:16] = n_ww;
           r[21:20] = n_havemax ? n_maxflow : 2'd0;
           r[22] = n_stkstarve;
           r[23] = n_stksat;
           r[24] = c[31];
           r[25] = (n_agedm != 4'd0);
           r[28:26] = n_sc;
           r[29] = n_repeat;
           r[31:30] = n_prevwin;
           x[7:0] = n_rounds;
           x[23:8] = n_have ? n_best : 16'hffff;
           x[24] = n_satnow;
           x[25] = n_starm;
           x[26] = n_tie;
           x[27] = (n_prevmask & n_backm) != 4'd0;
           x[31:28] = n_agedm;
           f = n_satnow | n_starm;
           state_n[135:128] = n_rounds;
           state_n[136] = n_stkstarve;
           state_n[137] = n_stksat;
           state_n[139:138] = n_have ? n_win : 2'd0;
           state_n[143:140] = n_servm;
           state_n[144] = n_have;
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
