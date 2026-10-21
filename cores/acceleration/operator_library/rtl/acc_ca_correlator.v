// Authored kernel. See ip/ca_correlator/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ca_correlator (
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

wire [127:0] cslide = {a, state_r[127:32]};
reg [15:0] ccut, cthr, cmean;
reg [19:0] csum;
reg [5:0] cn;
reg [3:0] clg;
reg cguard, cpow, chit, cmiss, ccut_hi;
reg [7:0] chitc, cmissc, cinvc, cbeatc;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ccut=16'd0; cthr=16'd0; cmean=16'd0; csum=20'd0; cn=6'd0; clg=4'd0;
cguard=1'b0; cpow=1'b0; chit=1'b0; cmiss=1'b0; ccut_hi=1'b0;
chitc=8'd0; cmissc=8'd0; cinvc=8'd0; cbeatc=8'd0;
if (b[31:8] != 0 || c[30:23] != 0) begin
    f = 1'b1;
end else begin
    cn = pc32({16'd0, c[19:4]});
    clg = nlog2(cn);
    cpow = (cn >= 6'd2) && ((cn & (cn - 6'd1)) == 6'd0);
    ccut_hi = ((c[19:4] >> c[3:0]) & 16'h0001) != 16'd0;
    cguard = !cpow || ccut_hi;
    for (i = 0; i < 16; i = i + 1) begin
        if (c[19:4] & (16'd1 << i)) csum = csum + {12'd0, state_r[(i<<<3) +: 8]};
    end
    cmean = csum >> clg;
    cthr = cmean + (cmean >> c[22:20]) + {8'd0, b[7:0]};
    ccut = {8'd0, state_r[({28'd0, c[3:0]} <<< 3) +: 8]};
    chit = (!cguard) && (ccut > cthr);
    cmiss = (!cguard) && (ccut <= cthr);
    chitc = sat8(c[31] ? 8'd0 : state_r[135:128], chit ? 8'd1 : 8'd0);
    cmissc = sat8(c[31] ? 8'd0 : state_r[143:136], cmiss ? 8'd1 : 8'd0);
    cinvc = sat8(c[31] ? 8'd0 : state_r[151:144], cguard ? 8'd1 : 8'd0);
    cbeatc = sat8(c[31] ? 8'd0 : state_r[159:152], 8'd1);
    if (cguard) f = 1'b1;
    r[7:0] = ccut[7:0];
    r[15:8] = cmean[7:0];
    r[16] = chit;
    r[17] = cmiss;
    r[18] = cguard;
    r[19] = c[31];
    r[31:20] = csum[11:0];
    x[12:0] = cthr[12:0];
    x[13] = ~cpow;
    x[14] = ccut_hi;
    x[15] = c[31];
    x[19:16] = clg;
    x[23:20] = cinvc[3:0];
    x[31:24] = cbeatc;
    state_n[127:0] = c[31] ? {a, 96'd0} : cslide;
    state_n[135:128] = chitc;
    state_n[143:136] = cmissc;
    state_n[151:144] = cinvc;
    state_n[159:152] = cbeatc;
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
