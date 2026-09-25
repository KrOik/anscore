// Authored kernel. See ip/kalman1d/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_kalman1d (
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

reg [11:0] kla_k, kla_q;
reg signed [31:0] klx, klz, klr, klc, klv, klvn, klad, klcorr, klfull;
reg klxs, klvs, klgj, klpp, klcf;
wire [23:0] klp_raw;
wire signed [23:0] klp = $signed(klp_raw);
MULT12X12 u_klp (.DOUT(klp_raw), .A(kla_k), .B(kla_q), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    kla_k=12'd0; kla_q=12'd0;
klx=32'sd0; klz=32'sd0; klr=32'sd0; klc=32'sd0; klv=32'sd0; klvn=32'sd0;
klad=32'sd0; klcorr=32'sd0; klfull=32'sd0;
klxs=1'b0; klvs=1'b0; klgj=1'b0; klpp=1'b0; klcf=1'b0;
if (a[31:12] != 0 || b[31:12] != 0 || c[28:4] != 0) begin
    f = 1'b1;
end else if (c[31]) begin
    if (b[11:0] == 12'd0 || b[11:0] > 12'h7FF) begin
        f = 1'b1;
    end else begin
        klcf = 1'b1;
        state_n[23:12] = b[11:0];
        state_n[11:0] = 12'd0;   state_n[35:24] = 12'd0; state_n[36] = 1'b1;
        state_n[44:37] = 8'd0;   state_n[52:45] = 8'd0;  state_n[60:53] = 8'd0;
        x[29] = 1'b1;
    end
end else if (!state_r[36]) begin
    f = 1'b1;
end else begin
    klc = $signed(state_r[23:12]);
    klv = $signed({4'd0, state_r[35:24]});
    klx = $signed(state_r[11:0]);
    klz = $signed(a[11:0]);
    if (c[30]) begin
        klpp = 1'b1;
        klr = 32'sd0;
    end else begin
        klr = klz - klx;
        klad = klr[31] ? -klr : klr;
        if (c[29] && (klad > (klv + (klv >>> c[3:0]) + 32'sd1))) begin
            klgj = 1'b1; f = 1'b1;
            state_n[44:37] = sat8(state_r[44:37], 8'd1);
        end else begin
            kla_k = klc[11:0]; kla_q = klr >>> 1;
            klfull = (klp <<< 1) + (klr[0] ? klc : 32'sd0);
            klcorr = (klfull + 32'sd2048) >>> 12;
            klx = klx + klcorr;
            if (klx > 32'sd2047) begin klx = 32'sd2047; klxs = 1'b1; end
            else if (klx < -32'sd2048) begin klx = -32'sd2048; klxs = 1'b1; end
            if (klxs) f = 1'b1;
            klvn = klv + ((klad - klv) >>> 3);
            if (klvn > 32'sd4095) begin klvn = 32'sd4095; klvs = 1'b1; end
            else if (klvn < 32'sd0) begin klvn = 32'sd0; klvs = 1'b1; end
            if (klvs) f = 1'b1;
            state_n[11:0] = klx[11:0];
            state_n[35:24] = klvn[11:0];
            state_n[52:45] = sat8(state_r[52:45], 8'd1);
            state_n[60:53] = sat8(state_r[60:53], {7'd0, (klxs || klvs)});
        end
    end
    r = {{20{klx[31]}}, klx[11:0]};
    x[12:0] = klr;
    x[24:13] = (klpp || klgj) ? state_r[35:24] : klvn[11:0];
    x[25] = klxs;  x[26] = klgj;  x[27] = klpp;  x[28] = klvs;
    state_n[23:12] = klc[11:0];
    state_n[36] = 1'b1;
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
