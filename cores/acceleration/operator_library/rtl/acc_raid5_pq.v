// Authored kernel. See ip/raid5_pq/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_raid5_pq (
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
function [7:0] gf_mul;
    input [7:0] gu;
    input [7:0] gv;
    integer gi;
    reg [7:0] gp, gr;
    begin
        gp = 8'd0;
        gr = gv;
        for (gi = 0; gi < 8; gi = gi + 1) begin
            if (gu[gi]) gp = gp ^ gr;
            gr = {gr[6:0], 1'b0} ^ (gr[7] ? 8'h1D : 8'h00);
        end
        gf_mul = gp;
    end
endfunction
reg [2:0] rp_nd, rp_col;
reg [3:0] rp_err4;
reg [7:0] rp_pow, rp_st, rp_fd, rp_lf;
reg [11:0] rp_seq;
reg [31:0] rp_newp, rp_newq, rp_dp, rp_dq;
reg [7:0] rp_q0, rp_q1, rp_q2, rp_q3, rp_ppar, rp_qpar;
reg [31:0] rp_status, rp_sx;
reg [2:0] rp_op;
reg rp_bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    rp_nd = state_r[77:75];
rp_col = state_r[74:72];
rp_pow = state_r[71:64];
rp_err4 = state_r[82:79];
rp_st = state_r[90:83];
rp_fd = state_r[98:91];
rp_lf = state_r[118:111];
rp_seq = state_r[110:99] + 12'd1;
rp_op = c[2:0];
rp_ppar = state_r[7:0] ^ state_r[15:8] ^ state_r[23:16] ^ state_r[31:24];
rp_qpar = state_r[39:32] ^ state_r[47:40] ^ state_r[55:48] ^ state_r[63:56];
rp_status = {rp_lf[3:0], rp_st, rp_pow, rp_err4, 1'b1, 1'b1, rp_col, rp_nd};
rp_sx = {5'd0, rp_fd, rp_col, rp_ppar, rp_qpar};
if (c[31]) begin
    if ((rp_op == 3'd0) || (rp_op > 3'd6)) begin
        f = 1'b1;
        x = 32'd5;
    end else begin
        state_n[77:75] = rp_op;
        state_n[78] = 1'b1;
        state_n[74:72] = 3'd0;
        state_n[71:64] = 8'd1;
        state_n[31:0] = 32'd0;
        state_n[63:32] = 32'd0;
        state_n[110:99] = rp_seq;
        r = {rp_lf[3:0], rp_st, 8'd1, rp_err4, 1'b1, 1'b1, 3'd0, rp_op};
        x = {5'd0, rp_fd, 3'd0, 8'd0, 8'd0};
    end
end else if (!state_r[78]) begin
    f = 1'b1;
    x = 32'd1;
end else if (rp_op > 3'd3) begin
    f = 1'b1;
    x = 32'd2;
end else if ((rp_op == 3'd0) && (rp_col == rp_nd)) begin
    f = 1'b1;
    x = 32'd4;
end else if ((rp_op == 3'd2) && (rp_col != rp_nd)) begin
    f = 1'b1;
    x = 32'd6;
end else begin
    state_n[110:99] = rp_seq;
    if (rp_op == 3'd0) begin
        rp_newp = state_r[31:0] ^ a;
        rp_q0 = gf_mul(rp_pow, a[7:0]);
        rp_q1 = gf_mul(rp_pow, a[15:8]);
        rp_q2 = gf_mul(rp_pow, a[23:16]);
        rp_q3 = gf_mul(rp_pow, a[31:24]);
        rp_newq = {rp_q3, rp_q2, rp_q1, rp_q0} ^ state_r[63:32];
        state_n[31:0] = rp_newp;
        state_n[63:32] = rp_newq;
        state_n[71:64] = {rp_pow[6:0], 1'b0} ^ (rp_pow[7] ? 8'h1D : 8'h00);
        state_n[74:72] = rp_col + 3'd1;
        if (rp_fd != 8'hFF) state_n[98:91] = rp_fd + 8'd1;
        r = rp_newp;
        x = rp_newq;
    end else if (rp_op == 3'd1) begin
        rp_dp = state_r[31:0] ^ a;
        rp_dq = state_r[63:32] ^ b;
        rp_bad = (rp_dp != 32'd0) || (rp_dq != 32'd0);
        if (rp_bad) begin
            if (rp_err4 != 4'hF) state_n[82:79] = rp_err4 + 4'd1;
            state_n[118:111] = rp_st;
        end
        r = rp_dp;
        x = rp_dq;
        f = rp_bad;
    end else if (rp_op == 3'd2) begin
        r = state_r[31:0];
        x = state_r[63:32];
        state_n[31:0] = 32'd0;
        state_n[63:32] = 32'd0;
        state_n[74:72] = 3'd0;
        state_n[71:64] = 8'd1;
        if (rp_st != 8'hFF) state_n[90:83] = rp_st + 8'd1;
    end else begin
        r = rp_status;
        x = rp_sx;
    end
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
