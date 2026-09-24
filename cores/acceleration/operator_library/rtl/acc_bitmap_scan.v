// Authored kernel. See ip/bitmap_scan/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_bitmap_scan (
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
reg [31:0] n_sw, n_rot, n_diff, n_evor, n_evorn, n_evand, n_evandn;
reg [4:0] n_ptr, n_pos, n_cur, n_abs, n_next;
reg [5:0] n_sum, n_abs6, n_prev, n_pc, n_pco, n_pca, n_dsum, n_hits, n_empt;
reg [8:0] n_tsum;
reg [7:0] n_words, n_trans;
reg [31:0] n_xor;
reg n_kv, n_found, n_mode, n_wrap, n_sat, n_exp, n_done, n_stkmiss, n_stksat;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_kv = (c[30:7] != 24'd0) || (b[31:1] != 31'd0);
       if (n_kv) begin
           f = 1'b1;
       end
       else begin
           n_mode = b[0];
           n_sw = n_mode ? ~a : a;
           n_exp = c[5];
           n_ptr = n_exp ? c[4:0] : (c[31] ? 5'd0 : state_r[4:0]);
           sh = 32 - n_ptr;
           n_rot = (n_sw << n_ptr) | (n_sw >> sh);
           n_found = (n_rot != 32'd0);
           n_pos = 5'd0;
           n_cur = 5'd0;
           n_done = 1'b0;
           for (i=0; i<32; i=i+1) begin
               if (n_rot[i] && !n_done) begin
                   n_pos = n_cur;
                   n_done = 1'b1;
               end
               n_cur = n_cur + 5'd1;
           end
           n_sum = {1'b0, n_pos} + {1'b0, n_ptr};
           n_abs = n_sum[4:0];
           n_wrap = n_sum[5];
           n_abs6 = {1'b0, n_abs} + 6'd1;
           n_next = n_abs6[4:0];
           n_hits = state_r[11:6];
           n_empt = state_r[17:12];
           n_words = state_r[227:220];
           n_trans = state_r[235:228];
           n_sat = 1'b0;
           n_diff = (n_words == 8'd0) ? 32'd0 : (n_sw ^ state_r[179:148]);
           if (n_found) begin
               if (n_hits == 6'd63) n_sat = 1'b1;
               else n_hits = n_hits + 6'd1;
           end
           else begin
               if (n_empt == 6'd63) n_sat = 1'b1;
               else n_empt = n_empt + 6'd1;
           end
           if (n_words == 8'hff) n_sat = 1'b1;
           else n_words = n_words + 8'd1;
           n_evor = (c[31] ? 32'd0 : state_r[49:18]) | n_sw;
           n_evorn = (c[31] ? 32'd0 : state_r[81:50]) | ~n_sw;
           n_evand = (c[31] ? 32'hffff_ffff : state_r[113:82]) & n_sw;
           n_evandn = (c[31] ? 32'hffff_ffff : state_r[145:114]) & ~n_sw;
           n_xor = state_r[219:188] ^ n_sw;
           n_prev = state_r[185:180];
           n_pc = 6'd0;
           n_pco = 6'd0;
           n_pca = 6'd0;
           n_dsum = 6'd0;
           for (i=0; i<32; i=i+1) begin
               if (n_sw[i]) n_pc = n_pc + 6'd1;
               if (n_evor[i]) n_pco = n_pco + 6'd1;
               if (n_evand[i]) n_pca = n_pca + 6'd1;
               if (n_diff[i]) n_dsum = n_dsum + 6'd1;
           end
           n_tsum = {1'b0, n_trans} + {3'd0, n_dsum};
           if (n_tsum > 9'd255) begin
               n_trans = 8'hff;
               n_sat = 1'b1;
           end
           else n_trans = n_tsum[7:0];
           n_stkmiss = state_r[186] | (n_found ? 1'b0 : 1'b1);
           n_stksat = state_r[187] | n_sat;
           r[4:0] = n_found ? n_abs : 5'd0;
           r[5] = n_found;
           r[6] = n_mode;
           r[11:7] = n_found ? n_pos : 5'd0;
           r[16:12] = n_found ? n_next : n_ptr;
           r[21:17] = n_ptr;
           r[22] = n_wrap && n_found;
           r[23] = c[31];
           r[29:24] = n_hits;
           r[30] = n_stkmiss;
           r[31] = n_stksat;
           x[5:0] = n_pc;
           x[11:6] = n_pco;
           x[17:12] = n_pca;
           x[23:18] = n_dsum;
           x[24] = n_found ? 1'b0 : 1'b1;
           x[25] = n_exp;
           x[26] = n_found && (n_prev == n_abs6);
           x[27] = (n_trans != 8'd0);
           x[28] = (n_hits == 6'd63);
           x[29] = (n_empt == 6'd63);
           x[30] = (n_words == 8'hff);
           x[31] = (n_evand == 32'd0);
           f = (n_found ? 1'b0 : 1'b1) | n_sat;
           state_n[4:0] = n_found ? n_next : n_ptr;
           state_n[11:6] = n_hits;
           state_n[17:12] = n_empt;
           state_n[49:18] = n_evor;
           state_n[81:50] = n_evorn;
           state_n[113:82] = n_evand;
           state_n[145:114] = n_evandn;
           state_n[179:148] = n_sw;
           state_n[185:180] = n_found ? n_abs6 : 6'd0;
           state_n[186] = n_stkmiss;
           state_n[187] = n_stksat;
           state_n[219:188] = n_xor;
           state_n[227:220] = n_words;
           state_n[235:228] = n_trans;
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
