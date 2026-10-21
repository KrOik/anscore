// Authored kernel. See ip/onewire_slot/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_onewire_slot (
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

reg [15:0] ot, olm, otot, orst_lo, oprs_lo, oprs_hi, oslot_max, oone, ozmin, ozmax;
reg [7:0] osh, osh_n, ocrc, ocrc_n, obytes, obytes_n, obyt, ovr, obtn, orn, opn;
reg [7:0] ocbit, obl4;
reg [3:0] obp, obp_n;
reg olvl, opend, opval, opend_n, orst, oprs, onopr, ostuck, oshort, olong;
reg orec, oslot, oacc, obc, oknown, oover;
reg [15:0] olm_n;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ot=16'd0; olm=16'd0; otot=16'd0; orst_lo=16'd0; oprs_lo=16'd0; oprs_hi=16'd0;
oslot_max=16'd0; oone=16'd0; ozmin=16'd0; ozmax=16'd0; olm_n=16'd0;
osh=8'd0; osh_n=8'd0; ocrc=8'd0; ocrc_n=8'd0; obytes=8'd0; obytes_n=8'd0;
obyt=8'd0; ovr=8'd0; obtn=8'd0; orn=8'd0; opn=8'd0; ocbit=8'd0; obl4=8'd0;
obp=4'd0; obp_n=4'd0;
olvl=1'b0; opend=1'b0; opval=1'b0; opend_n=1'b0; orst=1'b0; oprs=1'b0;
onopr=1'b0; ostuck=1'b0; oshort=1'b0; olong=1'b0; orec=1'b0; oslot=1'b0;
oacc=1'b0; obc=1'b0; oknown=1'b0; oover=1'b0;
if (a[31:17] != 0 || b[15:0] != 0 || c[29:24] != 0) begin
    f = 1'b1;
end else begin
    olvl = a[16];
    ot = a[15:0];
    orst_lo = c[30] ? 16'd30 : 16'd480;
    oprs_lo = c[30] ? 16'd54 : 16'd540;
    oprs_hi = c[30] ? 16'd150 : 16'd720;
    oone  = c[30] ? 16'd6 : 16'd15;
    ozmin = c[30] ? 16'd8 : 16'd60;
    ozmax = c[30] ? 16'd17 : 16'd120;
    oslot_max = ozmax + (ozmax >> 2);
    osh    = c[31] ? 8'd0 : state_r[7:0];
    obp    = c[31] ? 4'd0 : state_r[11:8];
    ocrc   = c[31] ? 8'd0 : state_r[19:12];
    obytes = c[31] ? 8'd0 : state_r[27:20];
    olm    = c[31] ? 16'd0 : state_r[43:28];
    opend  = c[31] ? 1'b0 : state_r[44];
    opval  = c[31] ? 1'b0 : state_r[45];
    obyt   = c[31] ? 8'd0 : state_r[53:46];
    osh_n = osh; obp_n = obp; ocrc_n = ocrc; obytes_n = obytes; olm_n = olm;
    opend_n = opend;
    if (!olvl) begin
        if (opend) oslot = 1'b1;
        opend_n = 1'b0;
        olm_n = ot;
        if (ot > oprs_hi) begin
            ostuck = 1'b1;
        end else if (ot >= orst_lo) begin
            orst = 1'b1;
            osh_n = 8'd0; obp_n = 4'd0; ocrc_n = 8'd0; obytes_n = 8'd0;
            if (ot >= oprs_lo) oprs = 1'b1;
            else               onopr = 1'b1;
        end else if (ot >= 16'd1 && ot <= oone) begin
            opend_n = 1'b1; opval = 1'b1;
        end else if (ot >= ozmin && ot <= ozmax) begin
            opend_n = 1'b1; opval = 1'b0;
        end else if (ot < ozmin) begin
            oshort = 1'b1;
        end else begin
            olong = 1'b1;
        end
    end else if (opend) begin
        otot = olm + ot;
        opend_n = 1'b0;
        if (c[7:0] != 8'd0 && ot < {8'd0, c[7:0]}) begin
            orec = 1'b1;
        end else if (otot < ozmin || otot > oslot_max) begin
            oslot = 1'b1;
        end else begin
            oacc = 1'b1;
            osh_n = {1'b0, osh[7:1]} | (opval ? 8'h80 : 8'h00);
            if (obp == 4'd7) begin
                obp_n = 4'd0;
                obc = 1'b1;
                obyt = osh_n;
                if (c[23:16] != 8'd0 && obytes >= c[23:16]) begin
                    oover = 1'b1;
                end else begin
                    ocrc_n = ocrc ^ osh_n;
                    for (j = 0; j < 8; j = j + 1) begin
                        if (ocrc_n[0]) ocrc_n = (ocrc_n >> 1) ^ 8'h8C;
                        else           ocrc_n = ocrc_n >> 1;
                    end
                    oknown = (obyt == 8'h33) || (obyt == 8'h0F)
                          || (obyt == 8'hCC) || (obyt == 8'hA5)
                          || (obyt == 8'h96) || (obyt == 8'h69)
                          || (obyt == 8'h3C) || (obyt == 8'hEC);
                    obytes_n = obytes + 8'd1;
                end
            end else begin
                obp_n = obp + 4'd1;
            end
        end
    end
    if (ostuck || onopr || oshort || olong || orec || oslot || oover) f = 1'b1;
    ovr = sat8(c[31] ? 8'd0 : state_r[61:54],
               (ostuck || onopr || oshort || olong || orec || oslot || oover)
               ? 8'd1 : 8'd0);
    obtn = sat8(c[31] ? 8'd0 : state_r[69:62], obc ? 8'd1 : 8'd0);
    orn = sat8(c[31] ? 8'd0 : state_r[77:70], orst ? 8'd1 : 8'd0);
    opn = sat8(c[31] ? 8'd0 : state_r[85:78], oprs ? 8'd1 : 8'd0);
    ocbit = sat8(c[31] ? 8'd0 : state_r[93:86], oacc ? 8'd1 : 8'd0);
    obl4 = sat8(c[31] ? 8'd0 : state_r[101:94], 8'd1);
    r[7:0] = osh_n;
    r[15:8] = ocrc_n;
    r[16] = oacc;
    r[17] = obc;
    r[18] = orst;
    r[19] = oprs;
    r[20] = onopr;
    r[21] = oknown;
    r[22] = oshort || olong || oslot;
    r[23] = c[31];
    r[27:24] = obp_n;
    r[28] = opend_n;
    r[29] = olvl;
    r[30] = orec;
    r[31] = oover;
    x[7:0] = obytes_n;
    x[15:8] = otot[7:0];
    x[23:16] = olm_n[7:0];
    x[24] = c[30];
    x[25] = ostuck;
    x[31:28] = ovr[3:0];
    state_n[7:0] = osh_n;
    state_n[11:8] = obp_n;
    state_n[19:12] = ocrc_n;
    state_n[27:20] = obytes_n;
    state_n[43:28] = olm_n;
    state_n[44] = opend_n;
    state_n[45] = opval;
    state_n[53:46] = obyt;
    state_n[61:54] = ovr;
    state_n[69:62] = obtn;
    state_n[77:70] = orn;
    state_n[85:78] = opn;
    state_n[93:86] = ocbit;
    state_n[101:94] = obl4;
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
