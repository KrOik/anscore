// Authored kernel. See ip/comm_viterbi_acs4/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_comm_viterbi_acs4 (
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
function [7:0] qd;                         // |x-y| of two signed 9-bit operands
    input signed [8:0] x;
    input signed [8:0] y;
    begin
        qd = (x >= y) ? (x - y) : (y - x);
    end
endfunction

function [10:0] vmin;                      // smaller of two candidate metrics
    input [10:0] p;
    input [10:0] q;
    begin
        vmin = (p <= q) ? p : q;
    end
endfunction

function [7:0] vsat8;                      // unsigned metric view, clipped
    input [9:0] v;
    begin
        vsat8 = (v > 10'd255) ? 8'hFF : v[7:0];
    end
endfunction

wire signed [8:0] vy0 = {{3{a[5]}}, a[5:0]};
wire signed [8:0] vy1 = {{3{a[11]}}, a[11:6]};
wire signed [8:0] vp = {6'd0, b[2:0]};
wire signed [8:0] vm = -vp;
wire vh0 = a[5];
wire vh1 = a[11];
wire [9:0] vpm0 = c[31] ? 10'd0 : state_r[9:0];
wire [9:0] vpm1 = c[31] ? 10'd1023 : state_r[19:10];
wire [9:0] vpm2 = c[31] ? 10'd1023 : state_r[29:20];
wire [9:0] vpm3 = c[31] ? 10'd1023 : state_r[39:30];
wire vrc0 = c[31] ? 1'b1 : state_r[40];
wire vrc1 = c[31] ? 1'b0 : state_r[41];
wire vrc2 = c[31] ? 1'b0 : state_r[42];
wire vrc3 = c[31] ? 1'b0 : state_r[43];
wire [11:0] voff = c[31] ? 12'd0 : state_r[55:44];
// One trellis section of the (7,5) octal rate-1/2 K=3 code. With input u
// and register bits u1, u2 the channel bits are c0 = u^u1^u2 and
// c1 = u^u2, the state is s = u1*2+u2 and the next state is u*2+u1, so
// for a given next state u and the predecessor high bit are fixed and
// every branch distance below is static wiring rather than a mux tree:
// four add-compare-select units plus two minima trees in one cone.
wire [7:0] vsd00 = qd(vy0, vp) + qd(vy1, vp);
wire [2:0] vhd00 = {2'd0, vh0} + {2'd0, vh1};
wire [7:0] vbd00 = c[30] ? {5'd0, vhd00} : vsd00;
wire [7:0] vsd01 = qd(vy0, vp) + qd(vy1, vm);
wire [2:0] vhd01 = {2'd0, vh0} + {2'd0, ~vh1};
wire [7:0] vbd01 = c[30] ? {5'd0, vhd01} : vsd01;
wire [7:0] vsd10 = qd(vy0, vm) + qd(vy1, vp);
wire [2:0] vhd10 = {2'd0, ~vh0} + {2'd0, vh1};
wire [7:0] vbd10 = c[30] ? {5'd0, vhd10} : vsd10;
wire [7:0] vsd11 = qd(vy0, vm) + qd(vy1, vm);
wire [2:0] vhd11 = {2'd0, ~vh0} + {2'd0, ~vh1};
wire [7:0] vbd11 = c[30] ? {5'd0, vhd11} : vsd11;
wire [10:0] vsum00 = {1'b0, vpm0} + {3'b0, vbd00};
wire [10:0] vcd00 = vrc0 ? ((vsum00 > 11'd1023) ? 11'd1023 : vsum00) : 11'd1023;
wire vsat00 = vrc0 && (vsum00 > 11'd1023);
wire [10:0] vsum01 = {1'b0, vpm1} + {3'b0, vbd11};
wire [10:0] vcd01 = vrc1 ? ((vsum01 > 11'd1023) ? 11'd1023 : vsum01) : 11'd1023;
wire vsat01 = vrc1 && (vsum01 > 11'd1023);
wire vdec0 = (vcd01 < vcd00);
wire [10:0] vch0 = vdec0 ? vcd01 : vcd00;
wire vrn0 = vrc0 | vrc1;
wire vtie0 = vrn0 && (vcd00 == vcd01);
wire [10:0] vmn0 = vrn0 ? vch0 : 11'd2047;
wire [10:0] vsum10 = {1'b0, vpm2} + {3'b0, vbd10};
wire [10:0] vcd10 = vrc2 ? ((vsum10 > 11'd1023) ? 11'd1023 : vsum10) : 11'd1023;
wire vsat10 = vrc2 && (vsum10 > 11'd1023);
wire [10:0] vsum11 = {1'b0, vpm3} + {3'b0, vbd01};
wire [10:0] vcd11 = vrc3 ? ((vsum11 > 11'd1023) ? 11'd1023 : vsum11) : 11'd1023;
wire vsat11 = vrc3 && (vsum11 > 11'd1023);
wire vdec1 = (vcd11 < vcd10);
wire [10:0] vch1 = vdec1 ? vcd11 : vcd10;
wire vrn1 = vrc2 | vrc3;
wire vtie1 = vrn1 && (vcd10 == vcd11);
wire [10:0] vmn1 = vrn1 ? vch1 : 11'd2047;
wire [10:0] vsum20 = {1'b0, vpm0} + {3'b0, vbd11};
wire [10:0] vcd20 = vrc0 ? ((vsum20 > 11'd1023) ? 11'd1023 : vsum20) : 11'd1023;
wire vsat20 = vrc0 && (vsum20 > 11'd1023);
wire [10:0] vsum21 = {1'b0, vpm1} + {3'b0, vbd00};
wire [10:0] vcd21 = vrc1 ? ((vsum21 > 11'd1023) ? 11'd1023 : vsum21) : 11'd1023;
wire vsat21 = vrc1 && (vsum21 > 11'd1023);
wire vdec2 = (vcd21 < vcd20);
wire [10:0] vch2 = vdec2 ? vcd21 : vcd20;
wire vrn2 = vrc0 | vrc1;
wire vtie2 = vrn2 && (vcd20 == vcd21);
wire [10:0] vmn2 = vrn2 ? vch2 : 11'd2047;
wire [10:0] vsum30 = {1'b0, vpm2} + {3'b0, vbd01};
wire [10:0] vcd30 = vrc2 ? ((vsum30 > 11'd1023) ? 11'd1023 : vsum30) : 11'd1023;
wire vsat30 = vrc2 && (vsum30 > 11'd1023);
wire [10:0] vsum31 = {1'b0, vpm3} + {3'b0, vbd10};
wire [10:0] vcd31 = vrc3 ? ((vsum31 > 11'd1023) ? 11'd1023 : vsum31) : 11'd1023;
wire vsat31 = vrc3 && (vsum31 > 11'd1023);
wire vdec3 = (vcd31 < vcd30);
wire [10:0] vch3 = vdec3 ? vcd31 : vcd30;
wire vrn3 = vrc2 | vrc3;
wire vtie3 = vrn3 && (vcd30 == vcd31);
wire [10:0] vmn3 = vrn3 ? vch3 : 11'd2047;
wire [10:0] vmn = vmin(vmin(vmn0, vmn1), vmin(vmn2, vmn3));
wire vtie = vtie0 | vtie1 | vtie2 | vtie3;
wire vsat = vsat00 | vsat01 | vsat10 | vsat11 | vsat20 | vsat21 | vsat30 | vsat31;
wire vbest0 = vrn0 && (vch0 == vmn);
wire vbest1 = vrn1 && (vch1 == vmn);
wire vbest2 = vrn2 && (vch2 == vmn);
wire [1:0] vbst = vbest0 ? 2'd0 : vbest1 ? 2'd1 : vbest2 ? 2'd2 : 2'd3;
wire [2:0] vcnt = {2'd0, vrn0} + {2'd0, vrn1} + {2'd0, vrn2} + {2'd0, vrn3};
wire [10:0] vsub0 = vch0 - vmn;
wire [9:0] vpn0 = vrn0 ? vsub0[9:0] : 10'd1023;
wire [10:0] vsec0 = (vrn0 && vbst != 2'd0) ? vch0 : 11'd2047;
wire [10:0] vsub1 = vch1 - vmn;
wire [9:0] vpn1 = vrn1 ? vsub1[9:0] : 10'd1023;
wire [10:0] vsec1 = (vrn1 && vbst != 2'd1) ? vch1 : 11'd2047;
wire [10:0] vsub2 = vch2 - vmn;
wire [9:0] vpn2 = vrn2 ? vsub2[9:0] : 10'd1023;
wire [10:0] vsec2 = (vrn2 && vbst != 2'd2) ? vch2 : 11'd2047;
wire [10:0] vsub3 = vch3 - vmn;
wire [9:0] vpn3 = vrn3 ? vsub3[9:0] : 10'd1023;
wire [10:0] vsec3 = (vrn3 && vbst != 2'd3) ? vch3 : 11'd2047;
wire [10:0] vsec = vmin(vmin(vsec0, vsec1), vmin(vsec2, vsec3));
wire [10:0] vmarw = vsec - vmn;
wire [4:0] vmarg = (vmarw > 11'd31) ? 5'd31 : vmarw[4:0];
wire [12:0] voffw = {1'b0, voff} + {2'b0, vmn};
wire voffo = voffw > 13'd4095;
wire [11:0] voffn = voffo ? 12'hFFF : voffw[11:0];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(a[31:12] != 20'd0 || b[31:3] != 29'd0 || c[29:1] != 29'd0) f = 1'b1;
else begin
    r[7:0] = vsat8(vpn0);
    r[15:8] = vsat8(vpn1);
    r[23:16] = vsat8(vpn2);
    r[31:24] = vsat8(vpn3);
    x[3:0] = {vdec3, vdec2, vdec1, vdec0};
    x[5:4] = vbst;
    x[8:6] = vcnt;
    x[13:9] = vmarg;
    x[14] = vtie;
    x[15] = vsat;
    x[16] = voffo;
    x[17] = c[31];
    x[29:18] = voffn;
    x[31:30] = 2'd0;
    state_n = {200'd0, voffn, vrn3, vrn2, vrn1, vrn0, vpn3, vpn2, vpn1, vpn0};
    if(vsat || voffo) f = 1'b1;
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
