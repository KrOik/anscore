// Authored kernel. See ip/mahony_ahrs/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_mahony_ahrs (
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
function [11:0] sin11;                    // Q11 sine, 5.625 degree grid
    input [5:0] k;
    begin
        case (k)
            6'd0: sin11 = 12'sd0;
            6'd1: sin11 = 12'sd201;
            6'd2: sin11 = 12'sd399;
            6'd3: sin11 = 12'sd594;
            6'd4: sin11 = 12'sd783;
            6'd5: sin11 = 12'sd965;
            6'd6: sin11 = 12'sd1137;
            6'd7: sin11 = 12'sd1299;
            6'd8: sin11 = 12'sd1447;
            6'd9: sin11 = 12'sd1582;
            6'd10: sin11 = 12'sd1702;
            6'd11: sin11 = 12'sd1805;
            6'd12: sin11 = 12'sd1891;
            6'd13: sin11 = 12'sd1959;
            6'd14: sin11 = 12'sd2008;
            6'd15: sin11 = 12'sd2037;
            6'd16: sin11 = 12'sd2047;
            6'd17: sin11 = 12'sd2037;
            6'd18: sin11 = 12'sd2008;
            6'd19: sin11 = 12'sd1959;
            6'd20: sin11 = 12'sd1891;
            6'd21: sin11 = 12'sd1805;
            6'd22: sin11 = 12'sd1702;
            6'd23: sin11 = 12'sd1582;
            6'd24: sin11 = 12'sd1447;
            6'd25: sin11 = 12'sd1299;
            6'd26: sin11 = 12'sd1137;
            6'd27: sin11 = 12'sd965;
            6'd28: sin11 = 12'sd783;
            6'd29: sin11 = 12'sd594;
            6'd30: sin11 = 12'sd399;
            6'd31: sin11 = 12'sd201;
            6'd32: sin11 = 12'sd0;
            6'd33: sin11 = -12'sd201;
            6'd34: sin11 = -12'sd399;
            6'd35: sin11 = -12'sd594;
            6'd36: sin11 = -12'sd783;
            6'd37: sin11 = -12'sd965;
            6'd38: sin11 = -12'sd1137;
            6'd39: sin11 = -12'sd1299;
            6'd40: sin11 = -12'sd1447;
            6'd41: sin11 = -12'sd1582;
            6'd42: sin11 = -12'sd1702;
            6'd43: sin11 = -12'sd1805;
            6'd44: sin11 = -12'sd1891;
            6'd45: sin11 = -12'sd1959;
            6'd46: sin11 = -12'sd2008;
            6'd47: sin11 = -12'sd2037;
            6'd48: sin11 = -12'sd2047;
            6'd49: sin11 = -12'sd2037;
            6'd50: sin11 = -12'sd2008;
            6'd51: sin11 = -12'sd1959;
            6'd52: sin11 = -12'sd1891;
            6'd53: sin11 = -12'sd1805;
            6'd54: sin11 = -12'sd1702;
            6'd55: sin11 = -12'sd1582;
            6'd56: sin11 = -12'sd1447;
            6'd57: sin11 = -12'sd1299;
            6'd58: sin11 = -12'sd1137;
            6'd59: sin11 = -12'sd965;
            6'd60: sin11 = -12'sd783;
            6'd61: sin11 = -12'sd594;
            6'd62: sin11 = -12'sd399;
            6'd63: sin11 = -12'sd201;
        endcase
    end
endfunction

reg signed [11:0] mah_ah, mah_gv, mav_av, mav_gh;
reg [5:0] msid;
wire [11:0] mgh = sin11(msid);
wire [11:0] mgv = sin11(msid + 6'd16);
reg [3:0] mps, mis, mqs;
reg signed [63:0] mer, mdp, mdi, md, msum;
reg signed [31:0] micur, minew;
reg [15:0] mroll, mpitch, mth, mthn, miother;
reg mplane, mis_s, mds_s, mwrap, mzerog;
wire [23:0] mah_p1_raw;
wire signed [23:0] mah_p1 = $signed(mah_p1_raw);
MULT12X12 u_mah_p1 (.DOUT(mah_p1_raw), .A(mah_ah), .B(mah_gv), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] mah_p2_raw;
wire signed [23:0] mah_p2 = $signed(mah_p2_raw);
MULT12X12 u_mah_p2 (.DOUT(mah_p2_raw), .A(mav_av), .B(mav_gh), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    mah_ah=12'sd0; mah_gv=12'sd0; mav_av=12'sd0; mav_gh=12'sd0; msid=6'd0;
mps=c[3:0]; mis=c[7:4]; mqs=c[11:8];
mer=64'sd0; mdp=64'sd0; mdi=64'sd0; md=64'sd0; msum=64'sd0;
micur=32'sd0; minew=32'sd0;
mroll=16'd0; mpitch=16'd0; mth=16'd0; mthn=16'd0; miother=16'd0;
mplane=1'b0; mis_s=1'b0; mds_s=1'b0; mwrap=1'b0; mzerog=1'b0;
if (a[31:24] != 0 || b[31:16] != 0 || c[15:12] != 0 || c[29:16] != 0) begin
    f = 1'b1;
end else if (c[31] && c[30]) begin
    r = {b[15:0], b[15:0]};
    x[12] = 1'b1;
    state_n[15:0] = b[15:0]; state_n[31:16] = b[15:0];
    state_n[47:32] = 16'd0;  state_n[63:48] = 16'd0; state_n[64] = 1'b0;
end else begin
    mah_ah = a[11:0]; mav_av = a[23:12];
    mplane = c[31] ? 1'b0 : state_r[64];
    mroll  = c[31] ? 16'd0 : state_r[15:0];
    mpitch = c[31] ? 16'd0 : state_r[31:16];
    mth    = mplane ? mpitch : mroll;
    msid   = mth[15:10];
    mah_gv = mgv;    mav_gh = mgh;
    mzerog = (a[11:0] == 12'sd0) && (a[23:12] == 12'sd0);
    micur  = c[31] ? 32'sd0
           : (mplane ? $signed(state_r[63:48]) : $signed(state_r[47:32]));
    miother = c[31] ? 16'd0
           : (mplane ? state_r[47:32] : state_r[63:48]);
    mer = mah_p1 - mah_p2;
    minew = micur;
    if (mzerog) begin
        f = 1'b1;
    end else begin
        mdp = mer >>> mps;
        minew = micur + (mer >>> mis);
        if (minew > 32'sd32767) begin minew = 32'sd32767; mis_s = 1'b1; end
        else if (minew < -32'sd32768) begin minew = -32'sd32768; mis_s = 1'b1; end
        mdi = minew >>> mqs;
        md = mdp + mdi;
    end
    if (md > 64'sd8388607) begin md = 64'sd8388607; mds_s = 1'b1; end
    else if (md < -64'sd8388608) begin md = -64'sd8388608; mds_s = 1'b1; end
    if (mis_s || mds_s) f = 1'b1;
    msum = $signed({48'd0, mth}) + $signed({48'd0, b[15:0]}) + md;
    mwrap = (msum < 64'sd0) || (msum > 64'sd65535);
    mthn = msum[15:0];
    r = mplane ? {mthn, mroll} : {mpitch, mthn};
    x[11:0] = mer >>> 11;
    x[12] = c[31];
    x[13] = mzerog;
    x[14] = mis_s;
    x[15] = mds_s;
    x[16] = mwrap;
    x[17] = mplane;
    x[31:20] = md[11:0];
    state_n[15:0]  = mplane ? mroll  : mthn;
    state_n[31:16] = mplane ? mthn   : mpitch;
    state_n[47:32] = mplane ? miother : minew[15:0];
    state_n[63:48] = mplane ? minew[15:0] : miother;
    state_n[64] = ~mplane;
    state_n[79:72] = sat8(c[31] ? 8'd0 : state_r[79:72], 8'd1);
    state_n[87:80] = sat8(c[31] ? 8'd0 : state_r[87:80],
                          {7'd0, (mzerog || mis_s || mds_s)});
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
