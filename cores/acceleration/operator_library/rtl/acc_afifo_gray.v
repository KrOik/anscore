// Authored kernel. See ip/afifo_gray/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_afifo_gray (
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
function [4:0] af_gray;
    input [4:0] p;
    begin
        af_gray = p ^ (p >> 1);
    end
endfunction
reg [4:0] af_aw, af_ar;
reg af_push, af_pop;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    sh = state_r[140:138];
pa = {27'd0, state_r[132:128]};
pb = {27'd0, state_r[137:133]};
mask = (32'd1 << (sh + 3'd1)) - 32'd1;
ph = (32'd1 << sh) - 32'd1;
pl = (pa - pb) & mask;
pc = 32'd0;
af_aw = pa[4:0];
af_ar = pb[4:0];
af_push = 1'b0;
af_pop = 1'b0;
wide[4:0] = af_gray(pa[4:0]);
wide[9:5] = af_gray(pb[4:0]);
wide[10] = (wide[4:0] == wide[9:5]);
wide[11] = ((wide[4:0] ^ wide[9:5]) ==
            (((32'd1 << sh) | (32'd1 << (sh - 3'd1))) & mask));
wide[16:12] = pl[4:0];
wide2[4:0] = wide[4:0];
wide2[9:5] = wide[9:5];
wide2[10] = wide[10];
wide2[11] = wide[11];
wide2[16:12] = pl[4:0];
wide2[26:19] = 8'd0;
if (c[31]) begin
    if (c[2:0] < 3'd1 || c[2:0] > 3'd4) begin
        pc = 32'd5;
    end else begin
        mask = (32'd1 << (c[2:0] + 3'd1)) - 32'd1;
        ph = (32'd1 << c[2:0]) - 32'd1;
        af_aw = c[3] ? (a & 32'h1f) & mask : 5'd0;
        af_ar = c[3] ? (b & 32'h1f) & mask : 5'd0;
        if (((af_aw - af_ar) & mask) > (ph + 32'd1)) begin
            pc = 32'd6;
        end else if (pc == 32'd0) begin
            state_n[140:138] = c[2:0];
            state_n[141] = 1'b1;
            state_n[132:128] = af_aw;
            state_n[137:133] = af_ar;
            state_n[127:0] = 128'd0;
            state_n[157:142] = 16'd0;
            state_n[168:158] = 11'd0;
            state_n[173:169] = ((af_aw - af_ar) & mask);
            wide[16:12] = pl[4:0];
            wide2[4:0] = af_gray(af_aw);
            wide2[9:5] = af_gray(af_ar);
            wide2[10] = (wide2[4:0] == wide2[9:5]);
            wide2[11] = ((wide2[4:0] ^ wide2[9:5]) ==
                         (((32'd1 << c[2:0]) | (32'd1 << (c[2:0] - 3'd1))) & mask));
            wide2[16:12] = ((af_aw - af_ar) & mask);
        end
    end
end else if (!state_r[141]) begin
    pc = 32'd1;
end else begin
    if (a[0]) begin
        if (wide[11]) begin
            pc = 32'd2;
            if (state_r[161:158] != 4'hF) begin
                state_n[161:158] = state_r[161:158] + 4'd1;
            end
        end else begin
            state_n[((pa & ph) << 3) +: 8] = a[15:8];
            af_aw = (pa[4:0] + 5'd1) & mask[4:0];
            af_push = 1'b1;
            if (state_r[149:142] != 8'hFF) begin
                state_n[149:142] = state_r[149:142] + 8'd1;
            end
        end
    end
    if (a[1]) begin
        if (wide[10]) begin
            if (pc == 32'd0) begin
                pc = 32'd3;
            end
            if (state_r[165:162] != 4'hF) begin
                state_n[165:162] = state_r[165:162] + 4'd1;
            end
        end else begin
            wide2[26:19] = state_r[((pb & ph) << 3) +: 8];
            af_ar = (pb[4:0] + 5'd1) & mask[4:0];
            af_pop = 1'b1;
            if (state_r[157:150] != 8'hFF) begin
                state_n[157:150] = state_r[157:150] + 8'd1;
            end
            if (c[3] && (wide2[26:19] != b[7:0])) begin
                pc = 32'd4;
                if (state_r[168:166] != 3'h7) begin
                    state_n[168:166] = state_r[168:166] + 3'd1;
                end
            end
        end
    end
    state_n[132:128] = af_aw;
    state_n[137:133] = af_ar;
    wide2[4:0] = af_gray(af_aw);
    wide2[9:5] = af_gray(af_ar);
    wide2[10] = (wide2[4:0] == wide2[9:5]);
    wide2[11] = ((wide2[4:0] ^ wide2[9:5]) ==
                 (((32'd1 << sh) | (32'd1 << (sh - 3'd1))) & mask));
    wide2[16:12] = ((32'd0 + af_aw) - (32'd0 + af_ar)) & mask;
    if (wide2[16:12] > state_r[173:169]) begin
        state_n[173:169] = wide2[16:12];
    end
end
if (pc != 32'd0) begin
    f = 1'b1;
    x[3:0] = pc[3:0];
end else begin
    r[4:0] = wide[4:0];
    r[9:5] = wide[9:5];
    r[10] = wide[10];
    r[11] = wide[11];
    r[16:12] = wide[16:12];
    r[21:17] = wide2[16:12];
    r[22] = af_push;
    r[23] = af_pop;
    r[31:24] = wide2[26:19];
    x[4:0] = af_aw;
    x[9:5] = af_ar;
    x[12:10] = c[31] ? state_n[140:138] : sh[2:0];
    x[13] = c[3];
    x[14] = c[31];
    x[15] = !c[31];
    x[19:16] = state_n[161:158];
    x[23:20] = state_n[165:162];
    x[28:24] = state_n[173:169];
    x[31:29] = state_n[168:166];
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
