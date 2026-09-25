// Authored kernel. See ip/ws2812_serial/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ws2812_serial (
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

reg [15:0] wh, wl, wtot, wrst, wtol;
reg [23:0] wsh, wsh_n, wlast;
reg [7:0] wdig, wdig_n, wpix, wpix_n, wexp, wdu4;
reg [7:0] wpc8, wfl8, wtr8, wlt8, wbt8;
reg [5:0] wbpos, wbpos_n;
reg wbit, wacc, wpc, wlat, wreq, wdu, wpe, wfl, wtr, widle, wpend, wpend_n;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    wh=16'd0; wl=16'd0; wtot=16'd0; wrst=16'd0; wtol=16'd0;
wsh=24'd0; wsh_n=24'd0; wlast=24'd0;
wdig=8'd0; wdig_n=8'd0; wpix=8'd0; wpix_n=8'd0; wexp=8'd0; wdu4=8'd0;
wbpos=6'd0; wbpos_n=6'd0;
wbit=1'b0; wacc=1'b0; wpc=1'b0; wlat=1'b0; wreq=1'b0; wdu=1'b0; wpe=1'b0;
wfl=1'b0; wtr=1'b0; widle=1'b0; wpend=1'b0; wpend_n=1'b0;
if (c[29:12] != 0 || b[31:8] != 0) begin
    f = 1'b1;
end else begin
    wh = a[15:0];
    wl = a[31:16];
    wtot = wh + wl;
    wrst = (c[11:6] == 6'd0) ? 16'd400 : {4'd0, c[11:6], 4'd0};
    wtol = {14'd0, c[1:0]};
    wreq = c[30];
    wlat = (wtot >= wrst) || wreq;
    wsh   = c[31] ? 24'd0 : state_r[23:0];
    wbpos = c[31] ? 6'd0 : state_r[29:24];
    wpix  = c[31] ? 8'd0 : state_r[37:30];
    wdig  = c[31] ? 8'd0 : state_r[45:38];
    wlast = c[31] ? 24'd0 : state_r[69:46];
    wpend = state_r[70];
    wexp  = b[7:0];
    wsh_n = wsh; wbpos_n = wbpos; wpix_n = wpix; wdig_n = wdig;
    wpend_n = wpend;
    if (wlat) begin
        wtr = (wbpos != 6'd0);
        wfl = (wexp != 8'd0) && (wpix != wexp);
        widle = (wbpos == 6'd0) && (wpix == 8'd0);
        if (!widle) begin
            wpend_n = 1'b1;
            wsh_n = 24'd0; wbpos_n = 6'd0; wpix_n = 8'd0; wdig_n = 8'd0;
        end
    end else begin
        wbit = (wh >= 16'd5);
        wdu = !((wh >= 16'd1 && wh <= 16'd4 && wl >= 16'd5 && wl <= 16'd8)
             || (wh >= 16'd5 && wh <= 16'd8 && wl >= 16'd2 && wl <= 16'd5));
        wpe = !((wtot + wtol >= 16'd9) && (wtot <= 16'd11 + wtol));
        wacc = 1'b1;
        wsh_n = {wsh[22:0], wbit};
        if (wbpos == 6'd23) begin
            wpc = 1'b1;
            wlast = wsh_n;
            wpix_n = sat8(wpix, 8'd1);
            wdig_n = wdig ^ wsh_n[23:16] ^ wsh_n[15:8] ^ wsh_n[7:0];
            wbpos_n = 6'd0;
        end else begin
            wbpos_n = wbpos + 6'd1;
        end
    end
    if (wdu || wpe || wtr || wfl) f = 1'b1;
    wdu4 = sat8(c[31] ? 8'd0 : state_r[86:79], wdu ? 8'd1 : 8'd0);
    wpc8 = sat8(c[31] ? 8'd0 : state_r[94:87], wpe ? 8'd1 : 8'd0);
    wfl8 = sat8(c[31] ? 8'd0 : state_r[102:95], wfl ? 8'd1 : 8'd0);
    wtr8 = sat8(c[31] ? 8'd0 : state_r[110:103], wtr ? 8'd1 : 8'd0);
    wlt8 = sat8(c[31] ? 8'd0 : state_r[78:71], (!widle && wlat) ? 8'd1 : 8'd0);
    wbt8 = sat8(c[31] ? 8'd0 : state_r[118:111], 8'd1);
    r[7:0] = wlast[7:0];
    r[15:8] = wlast[15:8];
    r[23:16] = wlast[23:16];
    r[24] = wacc;
    r[25] = wbit;
    r[26] = wpc;
    r[27] = wlat && !widle;
    r[28] = wdu;
    r[29] = wpe;
    r[30] = wfl;
    r[31] = wtr;
    x[7:0] = wdig_n;
    x[15:8] = wpix_n;
    x[23:16] = {2'd0, wbpos_n};
    x[24] = c[31];
    x[25] = wreq;
    x[26] = wpend_n;
    x[27] = widle;
    x[31:28] = wdu4[3:0];
    state_n[23:0] = wsh_n;
    state_n[29:24] = wbpos_n;
    state_n[37:30] = wpix_n;
    state_n[45:38] = wdig_n;
    state_n[69:46] = wlast;
    state_n[70] = wpend_n;
    state_n[78:71] = wlt8;
    state_n[86:79] = wdu4;
    state_n[94:87] = wpc8;
    state_n[102:95] = wfl8;
    state_n[110:103] = wtr8;
    state_n[118:111] = wbt8;
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
