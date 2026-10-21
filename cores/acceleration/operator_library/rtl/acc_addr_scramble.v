// Authored kernel. See ip/addr_scramble/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_addr_scramble (
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
localparam [15:0] AS_K0 = 16'hA5A5, AS_K1 = 16'h5A5A, AS_K2 = 16'h3C3C;
function [15:0] as_f16;
    input [15:0] ax;
    input [15:0] ak;
    reg [15:0] av, ar;
    begin
        av = ax + ak;
        ar = {av[10:0], av[15:11]};
        as_f16 = ar ^ (ar >> 7) ^ (ax >> 3);
    end
endfunction
function [31:0] as_scr;
    input [31:0] ad;
    input [31:0] k;
    reg [15:0] hi, lo, sv;
    reg [15:0] s0, s1, s2;
    begin
        s0 = k[31:16] ^ AS_K0;
        s1 = k[15:0] ^ AS_K1;
        s2 = k[23:8] ^ AS_K2;
        hi = ad[31:16];
        lo = ad[15:0];
        sv = hi; hi = lo; lo = sv ^ as_f16(lo, s0);
        sv = hi; hi = lo; lo = sv ^ as_f16(lo, s1);
        sv = hi; hi = lo; lo = sv ^ as_f16(lo, s2);
        as_scr = {hi, lo} ^ k;
    end
endfunction
function [31:0] as_uns;
    input [31:0] wd;
    input [31:0] k;
    reg [31:0] aw;
    reg [15:0] hi, lo, sv;
    reg [15:0] s0, s1, s2;
    begin
        s0 = k[31:16] ^ AS_K0;
        s1 = k[15:0] ^ AS_K1;
        s2 = k[23:8] ^ AS_K2;
        aw = wd ^ k;
        hi = aw[31:16];
        lo = aw[15:0];
        sv = hi; hi = lo ^ as_f16(hi, s2); lo = sv;
        sv = hi; hi = lo ^ as_f16(hi, s1); lo = sv;
        sv = hi; hi = lo ^ as_f16(hi, s0); lo = sv;
        as_uns = {hi, lo};
    end
endfunction
reg [31:0] as_key, as_t, as_mid, as_diff;
reg [2:0] as_op;
reg [3:0] as_err;
reg [11:0] as_seq;
reg as_cmp, as_rt, as_bad, as_failv;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    as_key = state_r[31:0];
as_op = c[2:0];
as_err = state_r[36:33];
as_seq = state_r[106:95] + 12'd1;
if (c[31]) begin
    as_t = as_scr(32'd0, a);
    state_n = 256'd0;
    state_n[31:0] = a;
    state_n[32] = 1'b1;
    state_n[70:69] = b[1:0];
    state_n[106:95] = as_seq;
    r = as_t;
    x = {as_t[31:24], 8'd0, b[1:0], as_op, 3'd0, as_err, 4'd0};
end else if (!state_r[32]) begin
    f = 1'b1;
    x = 32'd1;
end else if (as_op > 3'd5) begin
    f = 1'b1;
    x = 32'd2;
end else begin
    as_cmp = (as_op == 3'd2) || (as_op == 3'd3);
    as_rt = (as_op == 3'd4) || (as_op == 3'd5);
    as_bad = 1'b0;
    case (as_op)
        3'd0: as_t = as_scr(a, as_key);
        3'd1: as_t = as_uns(a, as_key);
        3'd2: as_t = as_scr(a, as_key);
        3'd3: as_t = as_uns(a, as_key);
        3'd4: begin
            as_mid = as_scr(a, as_key);
            as_t = as_uns(as_mid, as_key);
        end
        default: begin
            as_mid = as_uns(a, as_key);
            as_t = as_scr(as_mid, as_key);
        end
    endcase
    as_diff = 32'd0;
    if (as_cmp && (as_t != b)) begin
        as_bad = 1'b1;
        as_diff = as_t ^ b;
    end else if (as_rt && (as_t != a)) begin
        as_bad = 1'b1;
        as_diff = as_t ^ a;
    end
    state_n[68:37] = as_t;
    if (state_r[78:71] != 8'hFF) state_n[78:71] = state_r[78:71] + 8'd1;
    if ((as_op == 3'd0) || (as_op == 3'd2) || (as_op == 3'd4) ||
        (as_op == 3'd5)) begin
        if (state_r[86:79] != 8'hFF) state_n[86:79] = state_r[86:79] + 8'd1;
    end
    if ((as_op == 3'd1) || (as_op == 3'd3) || (as_op == 3'd4) ||
        (as_op == 3'd5)) begin
        if (state_r[94:87] != 8'hFF) state_n[94:87] = state_r[94:87] + 8'd1;
    end
    as_failv = state_r[139];
    if (as_bad) begin
        if (as_err != 4'hF) state_n[36:33] = as_err + 4'd1;
        if (!state_r[139]) begin
            state_n[139] = 1'b1;
            state_n[138:107] = a;
            as_failv = 1'b1;
        end
    end
    state_n[106:95] = as_seq;
    f = as_bad;
    r = as_bad ? as_diff : as_t;
    x = {as_t[31:24], state_n[78:71], state_r[70:69], as_op, as_cmp, as_rt,
         as_failv, (as_bad ? ((as_err == 4'hF) ? as_err : as_err + 4'd1) : as_err),
         as_bad ? (as_cmp ? 4'd3 : 4'd4) : 4'd0};
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
