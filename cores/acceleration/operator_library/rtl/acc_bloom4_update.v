// Authored kernel. See ip/bloom4_update/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_bloom4_update (
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
reg [31:0] n_h0, n_h1, n_acc, n_accw;
reg [255:0] n_pre, n_wren;
reg [127:0] n_pos;
reg [511:0] n_shv;
reg [15:0] n_new, n_abs;
reg [7:0] n_tb;
reg [2:0] n_wsel;
reg [8:0] n_before, n_after, n_set;
reg [3:0] n_hitm, n_newm;
reg [7:0] n_digest;
reg n_query, n_kv, n_dup;
integer n_m, n_w;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_k = 16'd0; n_h0 = 32'd0; n_h1 = 32'd0; n_acc = 32'd0;
       n_before = 9'd0; n_after = 9'd0; n_set = 9'd0; n_hitm = 4'd0;
       n_newm = 4'd0; n_digest = 8'h00; n_query = 1'b0; n_kv = 1'b0;
       n_pre = 256'd0; n_wren = 256'd0; n_pos = 128'd0; n_shv = 512'd0;
       n_new = 16'd0; n_abs = 16'd0; n_tb = 8'd0; n_wsel = 3'd0;
       n_accw = 32'd0; n_dup = 1'b0; n_m = 0; n_w = 0;
       n_kv = (c[30:9] != 22'd0);
       if (n_kv) begin
           f = 1'b1;
       end
       else begin
           n_query = c[8];
           n_pre = c[31] ? 256'd0 : state_r;
           for (lane=0; lane<4; lane=lane+1) begin
               if (lane == 0) n_k = a[15:0];
               else if (lane == 1) n_k = a[31:16];
               else if (lane == 2) n_k = b[15:0];
               else n_k = b[31:16];
               n_h0 = ((n_k >> 8) ^ n_k) & 32'hff;
               n_h0 = (n_h0 ^ c[7:0]) & 32'hff;
               n_h1 = (((n_k >> 12) ^ (n_k >> 8) ^ (n_k >> 4) ^ n_k) & 32'h0f);
               n_h1 = (n_h1 ^ (c[7:0] >> 4)) & 32'h0f;
               n_h1 = n_h1 | 32'h01;
               n_acc = n_h0;
               for (j=0; j<4; j=j+1) begin
                   n_tb = n_acc[7:0];
                   n_pos[8*((lane*4)+j) +: 8] = n_tb;
                   n_abs[(lane*4)+j] = ~n_pre[n_tb];
                   n_shv[32*((lane*4)+j) +: 32] = 32'd1 << n_tb[4:0];
                   n_acc = n_acc + n_h1;
               end
           end
           // A position only counts as new if no earlier position of this very
           // beat claimed the same bit, which is what keeps two colliding keys
           // of one beat from double-counting.
           for (n_m=0; n_m<16; n_m=n_m+1) begin
               n_dup = 1'b0;
               n_tb = n_pos[8*n_m +: 8];
               for (i=0; i<16; i=i+1)
                   if (i < n_m && n_new[i] &&
                       n_pos[8*i +: 8] == n_tb) n_dup = 1'b1;
               n_new[n_m] = ~n_query & ~n_pre[n_tb] & ~n_dup;
           end
           // The 16 writes are decoded in parallel against the pre-beat filter,
           // as eight 32-bit words: position p sets bit p[4:0] of word p[7:5].
           // No bit is named twice by a new position, so ORing the word masks is
           // exact, and state_n never feeds back into its own next-state mux --
           // which is why this is one decode tree instead of 16 chained 256:1
           // multiplexers (those kept ABC9 busy for 45+ minutes and extracted
           // 52748 AND gates).
           for (n_w=0; n_w<8; n_w=n_w+1) begin
               n_wsel = n_w;
               n_accw = 32'd0;
               for (n_m=0; n_m<16; n_m=n_m+1) begin
                   n_tb = n_pos[8*n_m +: 8];
                   if (n_new[n_m] && n_tb[7:5] == n_wsel)
                       n_accw = n_accw | n_shv[32*n_m +: 32];
               end
               n_wren[32*n_w +: 32] = n_accw;
           end
           n_digest = 8'h00;
           for (n_m=0; n_m<16; n_m=n_m+1)
               if (n_new[n_m]) n_digest = n_digest ^ n_pos[8*n_m +: 8];
           n_before = 9'd0;
           for (i=0; i<256; i=i+1) if (n_pre[i]) n_before = n_before + 9'd1;
           n_set = 9'd0;
           for (n_m=0; n_m<16; n_m=n_m+1) if (n_new[n_m]) n_set = n_set + 9'd1;
           // The write enable only names bits that were clear, so occupancy
           // after the beat is a sum instead of a second 256-bit popcount.
           n_after = n_before + n_set;
           state_n = n_pre | n_wren;
           n_hitm = 4'd0;
           n_newm = 4'd0;
           for (lane=0; lane<4; lane=lane+1) begin
               n_hitm[lane] = ~(|n_abs[lane*4 +: 4]);
               n_newm[lane] = |n_new[lane*4 +: 4];
           end
           r[3:0] = n_hitm;
           r[7:4] = n_newm;
           r[15:8] = n_digest;
           x[8:0] = n_after;
           x[15:9] = n_set[6:0];
           x[16] = n_query;
           x[17] = (n_after > 9'd224);
           x[26:18] = n_before;
           x[27] = c[31];
           f = (n_after > 9'd224);
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
