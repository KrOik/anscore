// Authored kernel. See ip/countmin_update/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_countmin_update (
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
reg [15:0] n_k;
reg [3:0] n_inc;
reg [31:0] n_h0, n_h1, n_acc, n_sum;
reg [7:0] n_old, n_val, n_min, n_max, n_isum, n_base;
reg [4:0] n_ops;
reg [2:0] n_zero;
reg n_query, n_kv, n_clamp, n_full;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_kv = (c[30:25] != 6'd0) || (c[23:16] != 8'd0);
       if (n_kv) begin
           f = 1'b1;
       end
       else begin
           n_query = c[24];
           state_n = c[31] ? 256'd0 : state_r;
           n_ops = 5'd0;
           n_isum = 8'd0;
           n_clamp = 1'b0;
           n_zero = 3'd0;
           for (lane=0; lane<4; lane=lane+1) begin
               if (lane == 0) begin n_k = a[15:0]; n_inc = c[3:0]; end
               else if (lane == 1) begin n_k = a[31:16]; n_inc = c[7:4]; end
               else if (lane == 2) begin n_k = b[15:0]; n_inc = c[11:8]; end
               else begin n_k = b[31:16]; n_inc = c[15:12]; end
               n_h0 = ((n_k >> 8) ^ n_k) & 32'h07;
               n_h1 = (((n_k >> 12) ^ (n_k >> 6) ^ n_k) & 32'h07) | 32'h01;
               n_acc = n_h0;
               if (!n_query) begin
                   for (j=0; j<4; j=j+1) begin
                       n_base = (j << 6) | {n_acc[2:0], 3'd0};
                       n_old = state_n[n_base +: 8];
                       n_sum = {24'd0, n_old} + {28'd0, n_inc};
                       if (n_sum > 32'hff) begin
                           n_sum = 32'hff;
                           n_clamp = 1'b1;
                       end
                       if (n_sum[7:0] != n_old) n_ops = n_ops + 5'd1;
                       state_n[n_base +: 8] = n_sum[7:0];
                       n_isum = n_isum + {4'd0, n_inc};
                       n_acc = n_acc + n_h1;
                   end
               end
           end
           for (lane=0; lane<4; lane=lane+1) begin
               if (lane == 0) n_k = a[15:0];
               else if (lane == 1) n_k = a[31:16];
               else if (lane == 2) n_k = b[15:0];
               else n_k = b[31:16];
               n_h0 = ((n_k >> 8) ^ n_k) & 32'h07;
               n_h1 = (((n_k >> 12) ^ (n_k >> 6) ^ n_k) & 32'h07) | 32'h01;
               n_acc = n_h0;
               n_min = 8'hff;
               for (j=0; j<4; j=j+1) begin
                   n_base = (j << 6) | {n_acc[2:0], 3'd0};
                   n_val = state_n[n_base +: 8];
                   if (n_val < n_min) n_min = n_val;
                   n_acc = n_acc + n_h1;
               end
               r = r | ({24'd0, n_min} << (lane << 3));
               if (n_min == 8'd0) n_zero = n_zero + 3'd1;
           end
           n_max = 8'h00;
           n_full = 1'b0;
           for (i=0; i<32; i=i+1) begin
               n_base = i << 3;
               n_val = state_n[n_base +: 8];
               if (n_val > n_max) n_max = n_val;
               if (n_val == 8'hff) n_full = 1'b1;
           end
           x[7:0] = n_ops;
           x[15:8] = n_max;
           x[16] = n_query;
           x[17] = n_clamp;
           x[18] = c[31];
           x[26:19] = n_isum;
           x[27] = n_full;
           x[30:28] = n_zero;
           x[31] = (n_ops == 5'd0);
           f = n_clamp;
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
