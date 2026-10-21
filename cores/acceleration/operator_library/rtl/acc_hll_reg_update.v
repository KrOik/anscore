// Authored kernel. See ip/hll_reg_update/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_hll_reg_update (
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
function [5:0] rho_f;
    input [26:0] field;
    integer k;
    begin
        rho_f = 6'd0;
        for (k=0; k<27; k=k+1) if (field[k]) rho_f = 6'd27 - k;
    end
endfunction
reg [26:0] n_w0, n_w1;
reg [4:0] n_b0, n_b1;
reg [5:0] n_rho0, n_rho1, n_old0, n_old1, n_val, n_max, n_zero;
reg [7:0] n_off0, n_off1, n_off, n_acc8, n_deg8, n_seed8;
reg [11:0] n_sum;
reg [23:0] n_xor;
reg n_kv, n_en0, n_en1, n_deg0, n_deg1, n_ra0, n_ra1, n_proc;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_kv = (c[30:2] != 29'd0);
       if (n_kv) begin
           f = 1'b1;
       end
       else begin
           n_en0 = c[0];
           n_en1 = c[1];
           n_proc = 1'b0;
           n_ra0 = 1'b0;
           n_ra1 = 1'b0;
           state_n[191:0] = c[31] ? 192'd0 : state_r[191:0];
           n_xor = c[31] ? 24'd0 : state_r[231:208];
           n_acc8 = state_r[199:192];
           n_deg8 = state_r[207:200];
           n_seed8 = state_r[239:232];
           if (c[31] && (n_seed8 != 8'hff)) n_seed8 = n_seed8 + 8'd1;
           n_b0 = a[4:0];
           n_w0 = a[31:5];
           n_deg0 = (n_w0 == 27'd0);
           n_rho0 = n_en0 ? rho_f(n_w0) : 6'd0;
           n_off0 = {1'b0, n_b0, 2'd0} + {2'd0, n_b0, 1'd0};
           if (n_en0) begin
               n_proc = 1'b1;
               if (n_deg0) begin
                   f = 1'b1;
                   if (n_deg8 != 8'hff) n_deg8 = n_deg8 + 8'd1;
               end
               else begin
                   if (n_acc8 != 8'hff) n_acc8 = n_acc8 + 8'd1;
                   n_xor = n_xor ^ a[23:0];
                   n_old0 = state_n[n_off0 +: 6];
                   if (n_rho0 > n_old0) begin
                       state_n[n_off0 +: 6] = n_rho0;
                       n_ra0 = 1'b1;
                   end
               end
           end
           n_b1 = b[4:0];
           n_w1 = b[31:5];
           n_deg1 = (n_w1 == 27'd0);
           n_rho1 = n_en1 ? rho_f(n_w1) : 6'd0;
           n_off1 = {1'b0, n_b1, 2'd0} + {2'd0, n_b1, 1'd0};
           if (n_en1) begin
               n_proc = 1'b1;
               if (n_deg1) begin
                   f = 1'b1;
                   if (n_deg8 != 8'hff) n_deg8 = n_deg8 + 8'd1;
               end
               else begin
                   if (n_acc8 != 8'hff) n_acc8 = n_acc8 + 8'd1;
                   n_xor = n_xor ^ b[23:0];
                   n_old1 = state_n[n_off1 +: 6];
                   if (n_rho1 > n_old1) begin
                       state_n[n_off1 +: 6] = n_rho1;
                       n_ra1 = 1'b1;
                   end
               end
           end
           n_zero = 6'd0;
           n_max = 6'd0;
           n_sum = 12'd0;
           n_off = 8'd0;
           for (i=0; i<32; i=i+1) begin
               n_val = state_n[n_off +: 6];
               if (n_val == 6'd0) n_zero = n_zero + 6'd1;
               if (n_val > n_max) n_max = n_val;
               n_sum = n_sum + {1'b0, n_val};
               n_off = n_off + 8'd6;
           end
           r[4:0] = n_b0;
           r[10:5] = n_rho0;
           r[11] = n_ra0;
           r[12] = n_en0;
           r[13] = n_deg0 && n_en0;
           r[18:14] = n_b1;
           r[24:19] = n_rho1;
           r[25] = n_ra1;
           r[26] = n_en1;
           r[27] = n_deg1 && n_en1;
           r[28] = c[31];
           r[29] = n_ra0 || n_ra1;
           r[30] = !(n_en0 || n_en1);
           r[31] = (n_zero == 6'd0);
           x[5:0] = n_zero;
           x[11:6] = n_max;
           x[22:12] = n_sum;
           x[23] = n_ra0 || n_ra1;
           x[24] = n_proc;
           x[25] = c[31];
           x[26] = (n_deg0 && n_en0) || (n_deg1 && n_en1);
           x[27] = (n_zero == 6'd0);
           x[28] = (n_acc8 != 8'd0);
           x[29] = (n_deg8 != 8'd0);
           x[30] = (n_seed8 != 8'd0);
           x[31] = (n_sum > 12'd255);
           state_n[199:192] = n_acc8;
           state_n[207:200] = n_deg8;
           state_n[231:208] = n_xor;
           state_n[239:232] = n_seed8;
           state_n[255:240] = {4'd0, n_sum};
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
