// Authored kernel. See ip/memprot_cache_tag_compare/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_memprot_cache_tag_compare (
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
function [15:0] tag_of;
    input [31:0] sel;
    input [255:0] st;
    begin
        case(sel[1:0])
            2'd0: tag_of = st[15:0];
            2'd1: tag_of = st[31:16];
            2'd2: tag_of = st[47:32];
            default: tag_of = st[63:48];
        endcase
    end
endfunction
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    mask = {28'd0, state_r[67:64]};
temp = {28'd0, state_r[71:68]};
pl = {28'd0, state_r[74:72]};
pc = a[31:16];
if(c[31]) begin
    state_n[15:0] = a[15:0];
    state_n[31:16] = a[31:16];
    state_n[47:32] = b[15:0];
    state_n[63:48] = b[31:16];
    state_n[67:64] = c[3:0];
    state_n[71:68] = c[7:4];
    state_n[74:72] = c[10:8];
    pa = c[10:8] & 3'd3;
    ext[2] = (c[0] && c[1] && a[15:0] == a[31:16]) ||
             (c[0] && c[2] && a[15:0] == b[15:0]) ||
             (c[0] && c[3] && a[15:0] == b[31:16]) ||
             (c[1] && c[2] && a[31:16] == b[15:0]) ||
             (c[1] && c[3] && a[31:16] == b[31:16]) ||
             (c[2] && c[3] && b[15:0] == b[31:16]);
end else begin
    for(i=0; i<4; i=i+1) begin
        pb = tag_of(i, state_r);
        if(pb == pc) wide2[i] = 1'b1;
        if(mask[i] && pb == pc) begin
            ph[i] = 1'b1;
            wide[3:0] = wide[3:0] + 4'd1;
            if(wide[7:4] == 4'd0) wide[7:4] = i + 4'd1;
        end
        if(mask[i] && pb[3:0] == pc[3:0]) pl[7:4] = pl[7:4] | (4'd1 << i);
    end
    pa = (wide[7:4] != 4'd0) ? (wide[7:4] - 4'd1) : pl[1:0];
    ext[0] = (wide[3:0] > 4'd1);
    state_n[(pa << 4) +: 16] = pc;
    state_n[64 + pa] = 1'b1;
    if(wide[7:4] == 4'd0) state_n[68 + pa] = b[0];
    else if(b[0]) state_n[68 + pa] = 1'b1;
    state_n[74:72] = pa[2:0] + 3'd1;
end
wide[39:24] = tag_of(pa[2:0], state_r);
for(i=0; i<4; i=i+1) begin
    pb = tag_of(i, state_n);
    if(state_n[64 + i]) begin
        wide[19:16] = wide[19:16] + 4'd1;
        if(pb == 16'd0 || pb == 16'hFFFF) begin
            ext[1] = 1'b1;
            if(wide[15:12] == 4'd0) wide[15:12] = i + 4'd1;
        end
    end
end
if(ext[0]) wide2[7:4] = 4'd1;
else if(ext[2]) wide2[7:4] = 4'd2;
else if(ext[1]) wide2[7:4] = 4'd3;
r[2:0] = c[31] ? 3'd7 : (wide[7:4] - 4'd1);
r[5:3] = pa[2:0];
r[6] = (wide[7:4] != 4'd0);
r[7] = !c[31] && (wide[7:4] == 4'd0);
r[8] = r[7] && !mask[pa];
r[9] = r[7] && mask[pa];
r[10] = c[31];
r[11] = ext[0];
r[13:12] = wide2[7:4];
r[17:14] = wide[19:16];
r[18] = ext[1];
r[19] = r[7] && (mask[3:0] == 4'hF);
r[20] = mask[pa];
r[21] = temp[pa];
r[22] = !c[31] && !mask[pa] && (wide[39:24] == pc);
r[23] = !c[31];
r[27:24] = wide[15:12];
r[31:28] = a[31:28];
x[3:0] = mask[3:0];
x[7:4] = ph[3:0];
x[11:8] = wide2[3:0];
x[15:12] = pl[7:4];
x[18:16] = pl[2:0];
x[19] = mask[pl[1:0]];
x[20] = temp[pl[1:0]];
x[24:21] = temp[3:0];
x[25] = !c[31] && b[0];
x[26] = !c[31] && b[0] && !temp[pa];
x[27] = (mask[3:0] == 4'hF);
x[31:28] = a[19:16];
f = (wide2[7:4] != 4'd0);
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
