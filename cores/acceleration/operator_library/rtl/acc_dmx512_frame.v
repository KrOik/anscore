// Authored kernel. See ip/dmx512_frame/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_dmx512_frame (
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

reg [15:0] dw, dnom, djit;
reg [7:0] dby, dby_n, dxor, dxor_n, dlow, dhigh, dlow_n, dhigh_n;
reg [7:0] dlastx, dcx, dvt, dvf, dvb, dframes;
reg [8:0] dslots, dslots_n, dlasts, dcs;
reg [3:0] dpos, dpos_n;
reg dlevel, dbreak, dmab, dflush, dcommit, dbyte_c, dfv, dover, dtviol;
reg darmed, darmed_n, dval;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    dw=16'd0; dnom=16'd0; djit=16'd0;
dby=8'd0; dby_n=8'd0; dxor=8'd0; dxor_n=8'd0; dlow=8'd0; dhigh=8'd0;
dlow_n=8'd0; dhigh_n=8'd0; dlastx=8'd0; dcx=8'd0; dvt=8'd0; dvf=8'd0; dvb=8'd0;
dframes=8'd0;
dslots=9'd0; dslots_n=9'd0; dlasts=9'd0; dcs=9'd0;
dpos=4'd0; dpos_n=4'd0;
dlevel=1'b0; dbreak=1'b0; dmab=1'b0; dflush=1'b0; dcommit=1'b0; dbyte_c=1'b0;
dfv=1'b0; dover=1'b0; dtviol=1'b0; darmed=1'b0; darmed_n=1'b0; dval=1'b0;
if (a[31:17] != 0 || b[31:16] != 0 || c[29:12] != 0 || b[7:0] < 8'd10
    || b[15:8] == 8'd0 || c[5:0] == 6'd0 || c[5:0] > 6'd15) begin
    f = 1'b1;
end else begin
    dlevel = a[16];
    dw = a[15:0];
    dnom = 16'd1 << c[5:0];
    djit = (c[11:8] == 4'd0) ? 16'h7FFF : (dnom >> c[11:8]);
    dtviol = (c[11:8] != 4'd0) && ((dw < (dnom - djit - 16'd1))
                                || (dw > (dnom + djit + 16'd1)));
    dlow   = c[31] ? 8'd0 : state_r[25:18];
    dhigh  = c[31] ? 8'd0 : state_r[33:26];
    dpos   = c[31] ? 4'd0 : state_r[37:34];
    dby    = c[31] ? 8'd0 : state_r[45:38];
    dslots = c[31] ? 9'd0 : state_r[8:0];
    dxor   = c[31] ? 8'd0 : state_r[16:9];
    darmed = c[31] ? 1'b0 : state_r[17];
    dval   = state_r[46];
    dlastx = state_r[54:47];
    dlasts = state_r[63:55];
    dlow_n  = dlevel ? 8'd0 : sat8(dlow, 8'd1);
    dhigh_n = dlevel ? sat8(dhigh, 8'd1) : 8'd0;
    dbreak  = (!dlevel) && (dlow_n == b[7:0]);
    dpos_n = dpos; dby_n = dby; dslots_n = dslots; dxor_n = dxor;
    darmed_n = darmed;
    if (dbreak) begin
        dpos_n = 4'd0; dby_n = 8'd0; dslots_n = 9'd0; dxor_n = 8'd0;
        darmed_n = 1'b1;
    end else if (!dlevel) begin
        if (dpos == 4'd0) begin
            dpos_n = 4'd1;
        end else if (dpos <= 4'd8) begin
            dby_n = dby | (8'h01 << (dpos - 4'd1));
            dpos_n = dpos + 4'd1;
        end else begin
            dfv = 1'b1;
        end
    end else if (!darmed && dlow != 8'd0) begin
        dfv = 1'b1;
        dpos_n = 4'd0;
        dby_n = 8'd0;
    end else if (dpos == 4'd0) begin
        dpos_n = 4'd0;
    end else if (dpos <= 4'd8) begin
        dpos_n = dpos + 4'd1;
    end else if (dslots == 10'd512) begin
        dover = 1'b1;
        dpos_n = 4'd0; dby_n = 8'd0;
    end else begin
        dslots_n = dslots + 9'd1;
        dxor_n = dxor ^ dby;
        dbyte_c = 1'b1;
        dpos_n = 4'd0; dby_n = 8'd0;
    end
    dmab = dlevel && (dpos == 4'd0) && darmed && (dhigh_n == b[15:8])
           && (dslots_n != 9'd0);
    dflush = c[30] && darmed && (!dbreak) && (dslots_n != 9'd0);
    dcommit = (dbreak && darmed && (dslots != 9'd0)) || dmab || dflush;
    dcs = dbreak ? dslots : dslots_n;
    dcx = dbreak ? dxor : dxor_n;
    if (dcommit) begin
        dval = 1'b1; dlasts = dcs; dlastx = dcx;
        dframes = sat8(c[31] ? 8'd0 : state_r[87:80], 8'd1);
        if (!dbreak) begin
            dslots_n = 9'd0; dxor_n = 8'd0; dpos_n = 4'd0; dby_n = 8'd0;
            darmed_n = 1'b0;
        end
    end else begin
        dframes = c[31] ? 8'd0 : state_r[87:80];
    end
    dvt = sat8(c[31] ? 8'd0 : state_r[71:64], dtviol ? 8'd1 : 8'd0);
    dvf = sat8(c[31] ? 8'd0 : state_r[79:72], (dfv || dover) ? 8'd1 : 8'd0);
    dvb = sat8(c[31] ? 8'd0 : state_r[95:88], 8'd1);
    if (dtviol || dfv || dover) f = 1'b1;
    r[7:0] = dby_n;
    r[16:8] = dslots_n;
    r[17] = dbyte_c;
    r[18] = dbreak;
    r[19] = dcommit;
    r[20] = dtviol;
    r[21] = dfv;
    r[22] = dover;
    r[23] = c[31];
    r[27:24] = dpos_n;
    r[28] = darmed_n;
    r[29] = dlevel;
    x[7:0] = dxor_n;
    x[15:8] = dlow_n;
    x[23:16] = dhigh_n;
    x[24] = dval;
    x[25] = c[30];
    x[31:28] = dvt[3:0];
    state_n[8:0] = dslots_n;
    state_n[16:9] = dxor_n;
    state_n[17] = darmed_n;
    state_n[25:18] = dlow_n;
    state_n[33:26] = dhigh_n;
    state_n[37:34] = dpos_n;
    state_n[45:38] = dby_n;
    state_n[46] = dval;
    state_n[54:47] = dlastx;
    state_n[63:55] = dlasts;
    state_n[71:64] = dvt;
    state_n[79:72] = dvf;
    state_n[87:80] = dframes;
    state_n[95:88] = dvb;
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
