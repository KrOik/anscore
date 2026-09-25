// Authored kernel. See ip/march_engine/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_march_engine (
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
localparam [1:0] MA_KW = 2'd0, MA_KR = 2'd1, MA_KN = 2'd2;
function [1:0] ma_kind;
    input [2:0] e;
    input ph;
    begin
        case ({e, ph})
            4'd0: ma_kind = 2'd0;
            4'd1: ma_kind = 2'd2;
            4'd2: ma_kind = 2'd1;
            4'd3: ma_kind = 2'd0;
            4'd4: ma_kind = 2'd1;
            4'd5: ma_kind = 2'd0;
            4'd6: ma_kind = 2'd1;
            4'd7: ma_kind = 2'd0;
            4'd8: ma_kind = 2'd1;
            4'd9: ma_kind = 2'd2;
            default: ma_kind = 2'd2;
        endcase
    end
endfunction
function [0:0] ma_val;
    input [2:0] e;
    input ph;
    begin
        case ({e, ph})
            4'd3: ma_val = 1'b1;
            4'd4: ma_val = 1'b1;
            4'd7: ma_val = 1'b1;
            4'd8: ma_val = 1'b1;
            default: ma_val = 1'b0;
        endcase
    end
endfunction
function [0:0] ma_asc;
    input [2:0] e;
    begin
        ma_asc = (e < 3'd2) ? 1'b1 : 1'b0;
    end
endfunction
reg [2:0] ma_el, ma_ad, ma_nel, ma_nad;
reg [1:0] ma_k;
reg ma_ph, ma_np, ma_up, ma_want, ma_bad, ma_fin, ma_wrap;
reg [7:0] ma_pat, ma_cell, ma_obs, ma_wb, ma_exp;
reg [3:0] ma_err;
reg [7:0] ma_ops, ma_wr, ma_rd;
reg [11:0] ma_seq;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ma_el = state_r[75:73];
ma_ad = state_r[78:76];
ma_ph = state_r[79];
ma_pat = state_r[71:64];
ma_err = state_r[83:80];
ma_seq = state_r[124:113] + 12'd1;
if (c[31]) begin
    state_n = 256'd0;
    state_n[71:64] = a[7:0];
    state_n[72] = 1'b1;
    state_n[124:113] = ma_seq;
    r = {1'b0, 1'b1, 22'd0, a[7:0]};
    x = {a[7:0], ma_pat, 8'd0, ma_seq[7:0]};
end else if (!state_r[72]) begin
    f = 1'b1;
    x = 32'd1;
end else if (state_r[88]) begin
    f = 1'b1;
    x = 32'd2;
end else begin
    case (ma_ad)
        3'd0: ma_cell = state_r[7:0];
        3'd1: ma_cell = state_r[15:8];
        3'd2: ma_cell = state_r[23:16];
        3'd3: ma_cell = state_r[31:24];
        3'd4: ma_cell = state_r[39:32];
        3'd5: ma_cell = state_r[47:40];
        3'd6: ma_cell = state_r[55:48];
        default: ma_cell = state_r[63:56];
    endcase
    ma_k = ma_kind(ma_el, ma_ph);
    ma_want = ma_val(ma_el, ma_ph);
    ma_exp = ma_want ? (~ma_pat) : ma_pat;
    ma_up = ma_asc(ma_el);
    ma_bad = 1'b0;
    ma_obs = 8'd0;
    if (ma_k == 2'd0) begin
        ma_obs = ma_exp;
        wide = state_r[63:0];
        wide2 = {56'd0, ma_exp} << {ma_ad, 3'd0};
        wide = wide & ~(64'hFF << {ma_ad, 3'd0});
        state_n[63:0] = wide | wide2;
        if (state_r[104:97] != 8'hFF) state_n[104:97] = state_r[104:97] + 8'd1;
    end else if (ma_k == 2'd1) begin
        ma_obs = b[7:0];
        if (ma_obs != ma_cell) begin
            ma_bad = 1'b1;
            if (ma_err != 4'hF) state_n[83:80] = ma_err + 4'd1;
            if (!state_r[87]) begin
                state_n[87] = 1'b1;
                state_n[86:84] = ma_ad;
            end
        end
        if (state_r[112:105] != 8'hFF) state_n[112:105] = state_r[112:105] + 8'd1;
    end
    state_n[72] = 1'b1;
    state_n[71:64] = ma_pat;
    if (state_r[96:89] != 8'hFF) state_n[96:89] = state_r[96:89] + 8'd1;
    ma_np = ~ma_ph;
    ma_nad = ma_ad;
    ma_nel = ma_el;
    ma_fin = 1'b0;
    if (ma_ph) begin
        ma_wrap = (ma_up && (ma_ad == 3'd7)) || (!ma_up && (ma_ad == 3'd0));
        if (ma_wrap) begin
            ma_nel = ma_el + 3'd1;
            if (ma_nel > 3'd4) begin
                ma_fin = 1'b1;
                ma_nel = 3'd4;
                ma_nad = ma_ad;
                state_n[88] = 1'b1;
            end else begin
                ma_nad = ma_asc(ma_nel) ? 3'd0 : 3'd7;
            end
        end else begin
            ma_nad = ma_up ? (ma_ad + 3'd1) : (ma_ad - 3'd1);
        end
    end
    if (!ma_fin) state_n[79] = ma_np;
    state_n[78:76] = ma_nad;
    state_n[75:73] = ma_nel;
    state_n[124:113] = ma_seq;
    r[7:0] = ma_obs;
    r[10:8] = ma_ad;
    r[13:11] = ma_el;
    r[14] = ~ma_up;
    r[15] = ma_ph;
    r[19:16] = ma_bad ? (ma_err + 4'd1) : ma_err;
    r[20] = ma_fin;
    r[23:21] = ma_nel;
    r[26:24] = ma_nad;
    r[27] = (ma_k == 2'd1);
    r[28] = (ma_k == 2'd0);
    r[29] = (ma_k == 2'd2);
    x[7:0] = (state_r[96:89] == 8'hFF) ? 8'hFF : (state_r[96:89] + 8'd1);
    x[15:8] = state_n[104:97];
    x[23:16] = state_n[112:105];
    x[26:24] = state_n[86:84];
    x[27] = state_n[87];
    x[28] = 1'b1;
    f = ma_bad;
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
