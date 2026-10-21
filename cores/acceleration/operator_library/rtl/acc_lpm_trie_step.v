// Authored kernel. See ip/lpm_trie_step/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_lpm_trie_step (
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
reg [29:0] fibmap [0:15];
initial $readmemh("tables/lpm_trie_step_fib.mem", fibmap);
reg [4:0] n_depth, n_dnew, n_plen, n_bestpl, n_cand;
reg [15:0] n_key, n_keyn;
reg [7:0] n_bestnh, n_look, n_hits;
reg n_bestv, n_complete;
reg [16:0] n_node;
reg [29:0] n_ent;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_dnew = 5'd0; n_keyn = 16'h0000; n_cand = 5'd0; n_bestv = 1'b0;
       n_bestpl = 5'd0; n_bestnh = 8'h00; n_node = 17'd0; n_complete = 1'b0;
       n_ent = 30'd0; n_plen = 5'd0;
       n_depth = c[31] ? 5'd0 : state_r[4:0];
       n_key = c[31] ? 16'h0000 : state_r[21:6];
       n_look = state_r[43:36];
       n_hits = state_r[51:44];
       if ((b[31:8] != 24'd0) || (c[31] && (a[31:16] != 16'd0))) begin
           f = 1'b1;
       end
       else if (!c[31] && state_r[52]) begin
           r[7:0] = state_r[34:27];
           r[12:8] = state_r[26:22];
           r[13] = state_r[35];
           r[14] = 1'b1;
           r[15] = !state_r[35];
           r[23:16] = n_look;
           r[31:24] = n_hits;
           x[16:0] = state_r[69:53];
           x[17] = 1'b1;
           x[18] = state_r[35];
           x[29] = 1'b1;
           f = 1'b1;
       end
       else begin
           n_dnew = n_depth + 5'd8;
           sh = 16 - n_dnew;
           n_keyn = n_key | (b[7:0] << sh);
           n_cand = 5'd0;
           n_bestv = 1'b0;
           n_bestpl = 5'd0;
           n_bestnh = 8'h00;
           for (i=0; i<16; i=i+1) begin
               n_ent = fibmap[i];
               if (n_ent[29]) begin
                   n_plen = n_ent[28:24];
                   if (n_plen <= n_dnew) begin
                       sh = 16 - n_plen;
                       mask = (32'hffff << sh) & 32'hffff;
                       if (((n_keyn ^ n_ent[23:8]) & mask[15:0]) == 16'h0) begin
                           n_cand = n_cand + 5'd1;
                           if (!n_bestv || (n_plen > n_bestpl)) begin
                               n_bestv = 1'b1;
                               n_bestpl = n_plen;
                               n_bestnh = n_ent[7:0];
                           end
                       end
                   end
               end
           end
           sh = 16 - n_dnew;
           n_node = ((17'd1 << n_dnew) - 17'd1) + {1'b0, (n_keyn >> sh)};
           n_complete = (n_dnew == 5'd16);
           if (n_complete) begin
               if (n_look != 8'hff) n_look = n_look + 8'd1;
               if (n_bestv && (n_hits != 8'hff)) n_hits = n_hits + 8'd1;
           end
           r[7:0] = n_bestnh;
           r[12:8] = n_bestpl;
           r[13] = n_bestv;
           r[14] = n_complete;
           r[15] = n_complete && !n_bestv;
           r[23:16] = n_look;
           r[31:24] = n_hits;
           x[16:0] = n_node;
           x[17] = n_complete;
           x[18] = n_bestv;
           x[28:24] = n_cand;
           state_n[4:0] = n_dnew;
           state_n[21:6] = n_keyn;
           state_n[26:22] = n_bestpl;
           state_n[34:27] = n_bestnh;
           state_n[35] = n_bestv;
           state_n[43:36] = n_look;
           state_n[51:44] = n_hits;
           state_n[52] = n_complete;
           state_n[69:53] = n_node;
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
