// Authored kernel. See ip/tlb8_lookup/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_tlb8_lookup (
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
reg [15:0] tl_ent;
reg [7:0] tl_vpn, tl_ppn;
reg [2:0] tl_perm, tl_req, tl_slot;
reg tl_cfg, tl_fnd, tl_is_ins, tl_is_hit;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    tl_cfg = state_r[128];
tl_fnd = 1'b0;
tl_is_ins = 1'b0;
tl_is_hit = 1'b0;
tl_ppn = 8'd0;
tl_perm = 3'd0;
tl_slot = 3'd0;
if (c[31]) begin
    for (i = 0; i < 8; i = i + 1) state_n[(i << 4) +: 16] = 16'd0;
    state_n[128] = 1'b1;
    state_n[136:129] = 8'd0;
    state_n[144:137] = 8'd0;
    state_n[152:145] = 8'd0;
    state_n[160:153] = 8'd0;
    state_n[168:161] = 8'd0;
end else if (!tl_cfg) begin
    f = 1'b1;
    x[3:0] = 4'd1;
    x[11:4] = state_r[136:129];
    x[19:12] = state_r[168:161];
end else if (c[0]) begin
    i = a[2:0];
    state_n[(i << 4) +: 16] = {a[15:8], b[3:0], b[6:4], 1'b1};
    if (state_r[136:129] != 8'hFF) state_n[136:129] = state_r[136:129] + 8'd1;
    tl_is_ins = 1'b1;
    tl_slot = a[2:0];
    tl_ppn = {4'd0, b[3:0]};
    tl_perm = b[6:4];
end else begin
    tl_vpn = a[7:0];
    tl_req = a[10:8];
    if (state_r[168:161] != 8'hFF) state_n[168:161] = state_r[168:161] + 8'd1;
    for (i = 0; i < 8; i = i + 1) begin
        tl_ent = state_r[(i << 4) +: 16];
        if (!tl_fnd && tl_ent[0] && (tl_ent[15:8] == tl_vpn)) begin
            tl_fnd = 1'b1;
            tl_slot = i[2:0];
            tl_ppn = {4'd0, tl_ent[7:4]};
            tl_perm = tl_ent[3:1];
        end
    end
    if (!tl_fnd) begin
        f = 1'b1;
        x[3:0] = 4'd2;
        if (state_r[152:145] != 8'hFF) state_n[152:145] = state_r[152:145] + 8'd1;
    end else if ((tl_req & ~tl_perm & 3'h7) != 3'd0) begin
        f = 1'b1;
        x[3:0] = 4'd3;
        if (state_r[160:153] != 8'hFF) state_n[160:153] = state_r[160:153] + 8'd1;
    end else begin
        tl_is_hit = 1'b1;
        if (state_r[144:137] != 8'hFF) state_n[144:137] = state_r[144:137] + 8'd1;
    end
end
if (!f) begin
    r[2:0] = tl_slot;
    r[7:4] = tl_ppn[3:0];
    r[10:8] = tl_perm;
    r[11] = tl_is_ins;
    r[12] = tl_is_hit;
    r[13] = 1'b1;
    x[3:0] = 4'd0;
    x[11:4] = state_n[136:129];
    x[19:12] = state_n[168:161];
    x[27:20] = state_n[144:137];
    x[31:28] = state_n[156:153];
end else begin
    x[11:4] = state_n[136:129];
    x[19:12] = state_n[168:161];
    x[27:20] = state_n[152:145];
    x[31:28] = state_n[156:153];
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
