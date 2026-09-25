// Authored kernel. See ip/memprot_mpu_region_check/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_memprot_mpu_region_check (
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
function [23:0] mpb;
    input [31:0] sel;
    input [255:0] st;
    begin
        case(sel[1:0])
            2'd0: mpb = st[23:0];
            2'd1: mpb = st[87:64];
            2'd2: mpb = st[151:128];
            default: mpb = st[215:192];
        endcase
    end
endfunction
function [23:0] mpm;
    input [31:0] sel;
    input [255:0] st;
    begin
        case(sel[1:0])
            2'd0: mpm = st[47:24];
            2'd1: mpm = st[111:88];
            2'd2: mpm = st[175:152];
        default: mpm = st[239:216];
        endcase
    end
endfunction
function [3:0] mpp;
    input [31:0] sel;
    input [255:0] st;
    begin
        case(sel[1:0])
            2'd0: mpp = st[51:48];
            2'd1: mpp = st[115:112];
            2'd2: mpp = st[179:176];
        default: mpp = st[243:240];
        endcase
    end
endfunction
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[31]) begin
    case(c[1:0])
        2'd0: begin
            state_n[23:0] = a[23:0];
            state_n[47:24] = b[23:0];
            state_n[51:48] = c[7:4];
        end
        2'd1: begin
            state_n[87:64] = a[23:0];
            state_n[111:88] = b[23:0];
            state_n[115:112] = c[7:4];
        end
        2'd2: begin
            state_n[151:128] = a[23:0];
            state_n[175:152] = b[23:0];
            state_n[179:176] = c[7:4];
        end
        default: begin
            state_n[215:192] = a[23:0];
            state_n[239:216] = b[23:0];
            state_n[243:240] = c[7:4];
        end
    endcase
    wide[11:8] = c[7:4];
end
temp = a[23:0];
for(i=0; i<4; i=i+1) begin
    pa = mpb(i, state_n);
    pb = mpm(i, state_n);
    pc = mpp(i, state_n);
    if(pc[0]) begin
        mask = mask + 32'd1;
        wide2[7:4] = wide2[7:4] | (4'd1 << i);
        if(pa > pb) begin
            ext[0] = 1'b1;
            if(wide[7:4] == 4'd0) wide[7:4] = i + 4'd1;
        end else begin
            ph[i] = 1'b1;
            wide[19:16] = wide[19:16] + 4'd1;
            if(c[31]) begin
                if(i != c[1:0] && c[4] && (a[23:0] <= b[23:0]) &&
                   (a[23:0] <= pb) && (pa <= b[23:0])) begin
                    pl[i] = 1'b1;
                    wide2[3:0] = wide2[3:0] + 4'd1;
                end
            end else if(pa <= temp && temp <= pb) begin
                pl[i] = 1'b1;
                wide2[3:0] = wide2[3:0] + 4'd1;
                if(wide[3:0] == 4'd0) begin
                    wide[3:0] = i + 4'd1;
                    wide[11:8] = pc;
                end
            end
        end
    end
end
pb = {28'd0, wide[11:8]};
pc = 32'd0;
if(c[31]) begin
    if(pb[0] && a[23:0] > b[23:0]) pc = 32'd6;
    else if(pb[0] && wide2[3:0] != 4'd0) pc = 32'd5;
end else if(wide[3:0] == 4'd0) pc = 32'd1;
else if(b[1] && !pb[3]) pc = 32'd4;
else if(b[0] && !pb[2]) pc = 32'd3;
else if(!b[0] && !pb[1]) pc = 32'd2;
else if(wide2[3:0] > 4'd1) pc = 32'd5;
else if(ext[0]) pc = 32'd6;
ext[2] = (wide[19:16] == 4'd0);
ext[3] = c[31] ? !(pb[0] && a[23:0] <= b[23:0]) : (wide[3:0] == 4'd0);
temp = (pc == 32'd0) && (c[31] ? pb[0] : (wide[3:0] != 4'd0));
r[2:0] = c[31] ? {1'b0, c[1:0]} : (wide[3:0] - 4'd1);
r[3] = temp;
r[7:4] = wide[11:8];
r[11:8] = mask;
r[15:12] = wide2[3:0];
r[19:16] = wide[19:16];
r[20] = (wide2[3:0] > 4'd1);
r[21] = ext[0];
r[22] = c[31];
r[23] = !c[31];
x[3:0] = pl[3:0];
x[7:4] = ph[3:0];
x[11:8] = wide2[7:4];
x[14:12] = pc[2:0];
x[18:15] = wide[7:4];
x[19] = ext[2];
x[20] = ext[3];
x[21] = !c[31] && b[0];
x[22] = !c[31] && b[1];
x[23] = c[31];
x[31:24] = a[23:16];
f = (pc != 32'd0);
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
