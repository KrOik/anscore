// Authored kernel. See ip/cam_match/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_cam_match (
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
reg cm_cfg, cm_is_cfg, cm_is_ins, cm_is_hit, cm_vr, cm_found, cm_vj, cm_mj;
reg [2:0] cm_N, cm_n, cm_slot, cm_idx;
reg [4:0] cm_len, cm_blen, cm_sh;
reg [7:0] cm_lbyte, cm_oact;
reg [15:0] cm_key, cm_msk;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    cm_cfg = state_r[192];
cm_N = state_r[195:193];
cm_key = a[15:0];
cm_slot = a[2:0];
cm_idx = 3'd0;
cm_blen = 5'd0;
cm_oact = 8'd0;
cm_is_cfg = 1'b0;
cm_is_ins = 1'b0;
cm_is_hit = 1'b0;
cm_vr = 1'b0;
cm_found = 1'b0;
if (c[31]) begin
    cm_n = c[2:0];
    if (cm_n == 3'd0 || cm_n > 3'd6) begin
        f = 1'b1;
        x[2:0] = 3'd4;
    end else begin
        for (idx = 0; idx < 6; idx = idx + 1) begin
            state_n[(idx << 4) +: 16] = 16'd0;
            state_n[(96 + (idx << 3)) +: 8] = 8'd0;
            state_n[(144 + (idx << 3)) +: 8] = 8'd0;
        end
        state_n[195:193] = cm_n;
        state_n[192] = 1'b1;
        state_n[203:196] = 8'd0;
        state_n[211:204] = 8'd0;
        state_n[219:212] = 8'd0;
        state_n[223:220] = 4'd0;
        cm_N = cm_n;
        cm_is_cfg = 1'b1;
        cm_vr = 1'b1;
    end
end else if (!cm_cfg) begin
    f = 1'b1;
    x[2:0] = 3'd1;
end else if (c[0]) begin
    if (cm_slot >= cm_N) begin
        f = 1'b1;
        x[2:0] = 3'd2;
    end else begin
        i = cm_slot;
        cm_len = b[20:16];
        if (cm_len > 5'd16) cm_len = 5'd16;
        state_n[(i << 4) +: 16] = b[15:0];
        state_n[(96 + (i << 3)) +: 8] = {1'b1, 2'd0, cm_len};
        state_n[(144 + (i << 3)) +: 8] = b[28:21];
        if (state_r[203:196] != 8'hFF) state_n[203:196] = state_r[203:196] + 8'd1;
        cm_idx = cm_slot;
        cm_blen = cm_len;
        cm_oact = b[28:21];
        cm_is_ins = 1'b1;
        cm_vr = 1'b1;
    end
end else begin
    if (state_r[211:204] != 8'hFF) state_n[211:204] = state_r[211:204] + 8'd1;
    for (idx = 0; idx < 6; idx = idx + 1) begin
        if (idx < cm_N) begin
            cm_lbyte = state_r[(96 + (idx << 3)) +: 8];
            cm_len = cm_lbyte[4:0];
            cm_sh = 5'd16 - cm_len;
            cm_msk = 16'hffff << cm_sh;
            cm_vj = cm_lbyte[7];
            cm_mj = ((cm_key ^ state_r[(idx << 4) +: 16]) & cm_msk) == 16'd0;
            if (cm_vj && cm_mj && (!cm_found || (cm_len > cm_blen))) begin
                cm_found = 1'b1;
                cm_idx = idx[2:0];
                cm_blen = cm_len;
                cm_oact = state_r[(144 + (idx << 3)) +: 8];
            end
        end
    end
    if (cm_found) begin
        if (state_r[219:212] != 8'hFF) state_n[219:212] = state_r[219:212] + 8'd1;
        cm_is_hit = 1'b1;
        cm_vr = 1'b1;
    end else begin
        f = 1'b1;
        if (state_r[223:220] != 4'hF) state_n[223:220] = state_r[223:220] + 4'd1;
        x[3:0] = 4'd5;
        x[11:8] = state_n[223:220];
        x[19:12] = state_n[211:204];
    end
end
if (!f) begin
    r[2:0] = cm_idx;
    r[7:3] = cm_blen;
    r[15:8] = cm_oact;
    r[16] = cm_vr;
    r[19:17] = cm_N;
    r[20] = cm_is_cfg;
    r[21] = cm_is_ins;
    r[22] = cm_is_hit;
    x[7:0] = state_n[203:196];
    x[15:8] = state_n[211:204];
    x[23:16] = state_n[219:212];
    x[27:24] = state_n[223:220];
    x[28] = state_n[192];
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
