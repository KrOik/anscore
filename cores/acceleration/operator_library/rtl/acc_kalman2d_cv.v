// Authored kernel. See ip/kalman2d_cv/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_kalman2d_cv (
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

reg [11:0] k2a_p, k2a_v;
reg signed [31:0] k2pos, k2vel, k2pp, k2pv, k2r, k2rad, k2cp, k2cv, k2fp, k2fv;
reg signed [11:0] k2gp, k2gv;
reg [12:0] k2maxr;
reg k2ps, k2vs, k2ds, k2cf, k2md;
wire [23:0] k2sp_raw;
wire signed [23:0] k2sp = $signed(k2sp_raw);
MULT12X12 u_k2sp (.DOUT(k2sp_raw), .A(k2gp), .B(k2a_p), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] k2sv_raw;
wire signed [23:0] k2sv = $signed(k2sv_raw);
MULT12X12 u_k2sv (.DOUT(k2sv_raw), .A(k2gv), .B(k2a_v), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    k2a_p=12'd0; k2a_v=12'd0; k2gp=12'd0; k2gv=12'd0;
k2pos=32'sd0; k2vel=32'sd0; k2pp=32'sd0; k2pv=32'sd0; k2r=32'sd0; k2rad=32'sd0;
k2cp=32'sd0; k2cv=32'sd0; k2fp=32'sd0; k2fv=32'sd0;
k2maxr=13'd0; k2ps=1'b0; k2vs=1'b0; k2ds=1'b0; k2cf=1'b0; k2md=1'b0;
if (a[31:24] != 0 || b[31:24] != 0 || c[29:24] != 0) begin
    f = 1'b1;
end else if (c[31]) begin
    if (b[11:0] == 0 || b[23:12] == 0 || c[11:0] == 0 || c[23:12] == 0
        || b[11:0] > 12'h7FF || b[23:12] > 12'h7FF
        || c[11:0] > 12'h7FF || c[23:12] > 12'h7FF) begin
        f = 1'b1;
    end else begin
        k2cf = 1'b1;
        state_n[11:0] = 12'd0;  state_n[23:12] = 12'd0;
        state_n[35:24] = b[11:0];   state_n[47:36] = b[23:12];
        state_n[59:48] = c[11:0];   state_n[71:60] = c[23:12];
        state_n[72] = 1'b1;
        state_n[85:73] = 13'd0;  state_n[98:86] = 13'd0;
        state_n[106:99] = 8'd0;  state_n[114:107] = 8'd0;
        x[17] = 1'b1;
    end
end else if (!state_r[72]) begin
    f = 1'b1;
end else begin
    k2md = c[30];
    k2pos = $signed(state_r[11:0]);
    k2vel = $signed(state_r[23:12]);
    k2pp = k2pos + k2vel;
    if (k2pp > 32'sd2047) begin k2pp = 32'sd2047; k2ds = 1'b1; end
    else if (k2pp < -32'sd2048) begin k2pp = -32'sd2048; k2ds = 1'b1; end
    k2r = (k2md ? ($signed(a[23:12]) - k2vel) : ($signed(a[11:0]) - k2pp));
    k2gp = k2md ? $signed(state_r[59:48]) : $signed(state_r[35:24]);
    k2gv = k2md ? $signed(state_r[71:60]) : $signed(state_r[47:36]);
    k2a_p = k2r >>> 1;  k2a_v = k2r >>> 1;
    k2fp = (k2sp <<< 1) + (k2r[0] ? k2gp : 32'sd0);
    k2fv = (k2sv <<< 1) + (k2r[0] ? k2gv : 32'sd0);
    k2cp = (k2fp + 32'sd2048) >>> 12;
    k2cv = (k2fv + 32'sd2048) >>> 12;
    k2pos = k2pp + k2cp;
    if (k2pos > 32'sd2047) begin k2pos = 32'sd2047; k2ps = 1'b1; end
    else if (k2pos < -32'sd2048) begin k2pos = -32'sd2048; k2ps = 1'b1; end
    k2pv = k2vel + k2cv;
    if (k2pv > 32'sd2047) begin k2pv = 32'sd2047; k2vs = 1'b1; end
    else if (k2pv < -32'sd2048) begin k2pv = -32'sd2048; k2vs = 1'b1; end
    if (k2ps || k2vs || k2ds) f = 1'b1;
    k2rad = k2r[31] ? -k2r : k2r;
    k2maxr = state_r[98:86];
    if (k2rad > $signed({19'd0, k2maxr})) k2maxr = k2rad[12:0];
    r = {8'd0, k2pv[11:0], k2pos[11:0]};
    x[12:0] = k2r;
    x[13] = k2ds;  x[14] = k2ps;  x[15] = k2vs;
    x[16] = k2md;  x[17] = 1'b0;
    x[30:18] = k2maxr;
    state_n[11:0] = k2pos[11:0];
    state_n[23:12] = k2pv[11:0];
    state_n[85:73] = k2r[12:0];
    state_n[98:86] = k2maxr;
    state_n[106:99] = sat8(state_r[106:99], 8'd1);
    state_n[114:107] = sat8(state_r[114:107], {7'd0, (k2ps || k2vs || k2ds)});
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
