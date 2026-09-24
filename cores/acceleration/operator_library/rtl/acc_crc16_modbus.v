// Authored kernel. See ip/crc16_modbus/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_crc16_modbus (
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
function [5:0] pc32;                        // popcount, pairwise half adds
    input [31:0] v;
    reg [31:0] t;
    begin
        t = (v & 32'h55555555) + ((v >> 1) & 32'h55555555);
        t = (t & 32'h33333333) + ((t >> 2) & 32'h33333333);
        t = (t & 32'h0F0F0F0F) + ((t >> 4) & 32'h0F0F0F0F);
        // The byte fold has to be two sequential half-adds.  Written as one
        // parallel sum t + (t>>8) + (t>>16) the bit 31:24 group lands in byte 1
        // instead of byte 0, so every popcount silently lost its top byte.
        t = t + (t >> 8);
        t = t + (t >> 16);
        pc32 = t[5:0];
    end
endfunction

function [5:0] lo32;                        // index of the lowest set bit, 32 if 0
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        n = 6'd32;
        if (v != 32'd0) begin
            t = v; n = 6'd0;
            if ((t & 32'h0000FFFF) == 32'd0) begin n = n + 6'd16; t = t >> 16; end
            if ((t & 32'h000000FF) == 32'd0) begin n = n + 6'd8;  t = t >> 8;  end
            if ((t & 32'h0000000F) == 32'd0) begin n = n + 6'd4;  t = t >> 4;  end
            if ((t & 32'h00000003) == 32'd0) begin n = n + 6'd2;  t = t >> 2;  end
            if ((t & 32'h00000001) == 32'd0) begin n = n + 6'd1; end
        end
        lo32 = n;
    end
endfunction

function [15:0] sat16;                      // saturating 16-bit unsigned add
    input [15:0] p, q;
    reg [16:0] t;
    begin
        t = {1'b0, p} + {1'b0, q};
        sat16 = (t > 17'hFFFF) ? 16'hFFFF : t[15:0];
    end
endfunction

function [7:0] sat8;                        // saturating 8-bit unsigned add
    input [7:0] p, q;
    reg [8:0] t;
    begin
        t = {1'b0, p} + {1'b0, q};
        sat8 = (t > 9'hFF) ? 8'hFF : t[7:0];
    end
endfunction

function [7:0] nsym;                        // ticks to symbols, saturated at 255
    input [15:0] ticks;
    input [5:0] sh;
    reg [15:0] t;
    begin
        t = ticks >> sh;
        nsym = (t > 16'd255) ? 8'hFF : t[7:0];
    end
endfunction

function [3:0] nlog2;                       // log2 of 2,4,8,16; 0 for anything else
    input [5:0] n;
    begin
        case (n)
            6'd2:  nlog2 = 4'd1;
            6'd4:  nlog2 = 4'd2;
            6'd8:  nlog2 = 4'd3;
            6'd16: nlog2 = 4'd4;
            default: nlog2 = 4'd0;
        endcase
    end
endfunction

reg [15:0] ccrc, ccnt, cmax;
reg [7:0] cd, clast, caddr, covf, crr, csr, cbt;
reg [3:0] cnby, cnf;
reg cok, cseen, covfl, cunchecked;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ccrc=16'd0; ccnt=16'd0; cmax=16'd0;
cd=8'd0; clast=8'd0; caddr=8'd0; covf=8'd0; crr=8'd0; csr=8'd0; cbt=8'd0;
cnby=4'd0; cnf=4'd0;
cok=1'b0; cseen=1'b0; covfl=1'b0; cunchecked=1'b0;
if (b[31:16] != 0 || c[29:4] != 0) begin
    f = 1'b1;
end else begin
    ccrc = c[31] ? 16'hFFFF : state_r[15:0];
    ccnt = c[31] ? 16'd0 : state_r[31:16];
    clast = c[31] ? 8'd0 : state_r[39:32];
    caddr = b[7:0];
    cunchecked = (caddr == 8'd0);
    cok = c[31] ? cunchecked : state_r[40];
    cseen = c[31] ? 8'd0 : state_r[41];
    cmax = (b[15:8] == 8'd0) ? 16'hFFFF : {8'd0, b[15:8]};
    cnby = {2'd0, c[1:0]} + 4'd1;
    for (i = 0; i < 4; i = i + 1) begin
        if (i[2:0] < cnby[2:0]) begin
            if (ccnt >= cmax) begin
                covfl = 1'b1;
            end else begin
                cd = a[(i<<<3) +: 8];
                ccrc = ccrc ^ {8'd0, cd};
                for (j = 0; j < 8; j = j + 1) begin
                    if (ccrc[0]) ccrc = (ccrc >> 1) ^ 16'hA001;
                    else         ccrc = ccrc >> 1;
                end
                ccnt = ccnt + 16'd1;
                clast = cd;
                cnf = cnf + 4'd1;
                if (!cseen) begin
                    cok = cunchecked || (cd == caddr);
                    cseen = 1'b1;
                end
            end
        end
    end
    covf = sat8(c[31] ? 8'd0 : state_r[49:42], covfl ? 8'd1 : 8'd0);
    crr = sat8(c[31] ? 8'd0 : state_r[57:50], (c[3] && ccrc != 16'd0) ? 8'd1 : 8'd0);
    csr = sat8(c[31] ? 8'd0 : state_r[65:58], c[31] ? 8'd1 : 8'd0);
    cbt = sat8(c[31] ? 8'd0 : state_r[73:66], 8'd1);
    if (covfl || (c[3] && ccrc != 16'd0)) f = 1'b1;
    r[15:0] = ccrc;
    r[16] = c[3] && (ccrc == 16'd0);
    r[17] = cok;
    r[18] = c[31];
    r[19] = covfl;
    r[20] = c[3];
    r[31:24] = clast;
    x[15:0] = ccnt;
    x[19:16] = {1'd0, cnf};
    x[24] = cseen;
    x[25] = cunchecked;
    x[26] = c[3];
    x[31:28] = covf[3:0];
    state_n[15:0] = ccrc;
    state_n[31:16] = ccnt;
    state_n[39:32] = clast;
    state_n[40] = cok;
    state_n[41] = cseen;
    state_n[49:42] = covf;
    state_n[57:50] = crr;
    state_n[65:58] = csr;
    state_n[73:66] = cbt;
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
