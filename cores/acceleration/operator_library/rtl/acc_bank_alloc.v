// Authored kernel. See ip/bank_alloc/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_bank_alloc (
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
reg [7:0] ba_cur, ba_new, ba_req, ba_sz, ba_best, ba_max;
reg [3:0] ba_slot, ba_besti;
reg [11:0] ba_seq;
reg ba_cfg, ba_fnd;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ba_cfg = state_r[128];
ba_req = b[7:0];
ba_slot = a[3:0];
ba_fnd = 1'b0;
ba_best = 8'd255;
ba_besti = 4'd0;
if (c[31]) begin
    for (i = 0; i < 16; i = i + 1) state_n[(i << 3) +: 8] = a[7:0] + i[7:0];
    state_n[128] = 1'b1;
    state_n[136:129] = 8'd0;
    state_n[144:137] = 8'd0;
    state_n[148:145] = 4'd0;
    state_n[152:149] = 4'd0;
    r[30] = 1'b1;
    r[31] = 1'b1;
end else if (!ba_cfg) begin
    f = 1'b1;
    r[3:0] = 4'd1;
end else if (c[0]) begin
    j = ba_slot;
    ba_cur = state_r[(j << 3) +: 8];
    ext = {24'd0, ba_cur} + {24'd0, ba_req};
    ba_new = (ext > 33'd255) ? 8'hFF : ext[7:0];
    state_n[(j << 3) +: 8] = ba_new;
    if (state_r[144:137] != 8'hFF) state_n[144:137] = state_r[144:137] + 8'd1;
    state_n[152:149] = ba_slot;
    r[3:0] = ba_slot;
    r[11:4] = ba_cur;
    r[19:12] = ba_new;
    r[27:20] = ba_req;
    r[29] = 1'b1;
    r[31] = 1'b1;
end else begin
    for (i = 0; i < 16; i = i + 1) begin
        ba_sz = state_r[(i << 3) +: 8];
        if ((ba_sz >= ba_req) && (!ba_fnd || (ba_sz < ba_best))) begin
            ba_fnd = 1'b1;
            ba_best = ba_sz;
            ba_besti = i[3:0];
        end
    end
    if (!ba_fnd) begin
        f = 1'b1;
        r[3:0] = 4'd2;
        if (state_r[148:145] != 4'hF) state_n[148:145] = state_r[148:145] + 4'd1;
    end else begin
        ba_new = ba_best - ba_req;
        j = ba_besti;
        state_n[(j << 3) +: 8] = ba_new;
        if (state_r[136:129] != 8'hFF) state_n[136:129] = state_r[136:129] + 8'd1;
        state_n[152:149] = ba_besti;
        r[3:0] = ba_besti;
        r[11:4] = ba_best;
        r[19:12] = ba_new;
        r[27:20] = ba_req;
        r[28] = 1'b1;
        r[31] = 1'b1;
    end
end
ba_seq = state_r[164:153] + 12'd1;
state_n[164:153] = ba_seq;
ba_max = 8'd0;
for (i = 0; i < 16; i = i + 1) begin
    if (state_n[(i << 3) +: 8] > ba_max) ba_max = state_n[(i << 3) +: 8];
end
x[11:0] = ba_seq;
x[15:12] = state_n[148:145];
x[19:16] = state_n[152:149];
x[27:20] = ba_max;
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
