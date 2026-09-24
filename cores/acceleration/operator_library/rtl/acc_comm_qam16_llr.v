// Authored kernel. See ip/comm_qam16_llr/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_comm_qam16_llr (
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

function [7:0] qm8;                        // the smaller unsigned distance
    input [7:0] p;
    input [7:0] q;
    begin
        qm8 = (p <= q) ? p : q;
    end
endfunction

function [1:0] qarg;                       // argmin level, lowest index on a tie
    input [7:0] d0;
    input [7:0] d1;
    input [7:0] d2;
    input [7:0] d3;
    begin
        if(d0 <= d1 && d0 <= d2 && d0 <= d3) qarg = 2'd0;
        else if(d1 <= d2 && d1 <= d3)        qarg = 2'd1;
        else if(d2 <= d3)                    qarg = 2'd2;
        else                                 qarg = 2'd3;
    end
endfunction

function [8:0] qscale;                     // {saturated, value} of a scaled LLR
    input signed [9:0] v;
    input [2:0] s;
    reg signed [16:0] acc;
    begin
        acc = v;
        acc = acc <<< s;
        qscale = (acc > 17'sd127) ? 9'h17F
                 : (acc < -17'sd128) ? 9'h180 : {1'b0, acc[7:0]};
    end
endfunction
// Gray-labelled 16-QAM: one axis holds the four levels -3S, -S, +S, +3S
// numbered 0..3 and labelled gray(k) = k ^ (k >> 1), so bit 1 selects the
// half of the axis and bit 0 selects inner against outer. A rectangular
// constellation separates per axis under max-log MAP, so eight absolute
// differences and six minima give both LLRs of both axes: no 2-D search
// over 16 points and no multiplier anywhere.
wire signed [8:0] qs = {6'd0, b[2:0]};
wire signed [8:0] qns = -qs;
wire [5:0] q3v = {3'd0, b[2:0]} + {2'd0, b[2:0], 1'b0};
wire signed [8:0] q3s = {3'd0, q3v};
wire signed [8:0] qn3s = -q3s;
wire [7:0] q7v = {2'd0, b[2:0], 3'd0} - {5'd0, b[2:0]};
wire signed [8:0] qvi = {{1{a[7]}}, a[7:0]};
wire [7:0] qdi0 = qd(qvi, qn3s);
wire [7:0] qdi1 = qd(qvi, qns);
wire [7:0] qdi2 = qd(qvi, qs);
wire [7:0] qdi3 = qd(qvi, q3s);
wire [7:0] qai = qm8(qdi0, qdi3);
wire [7:0] qbi = qm8(qdi1, qdi2);
wire [7:0] qci = qm8(qdi0, qdi1);
wire [7:0] qgi = qm8(qdi2, qdi3);
wire signed [9:0] qli0 = $signed({2'b0, qbi}) - $signed({2'b0, qai});
wire signed [9:0] qli1 = $signed({2'b0, qgi}) - $signed({2'b0, qci});
wire [1:0] qki = qarg(qdi0, qdi1, qdi2, qdi3);
wire [7:0] qzi = qd(qvi, 9'sd0);
wire [7:0] qmi = qm8(qm8(qm8(qdi0, qdi1), qdi2), qdi3);
wire signed [8:0] qvq = {{1{a[15]}}, a[15:8]};
wire [7:0] qdq0 = qd(qvq, qn3s);
wire [7:0] qdq1 = qd(qvq, qns);
wire [7:0] qdq2 = qd(qvq, qs);
wire [7:0] qdq3 = qd(qvq, q3s);
wire [7:0] qaq = qm8(qdq0, qdq3);
wire [7:0] qbq = qm8(qdq1, qdq2);
wire [7:0] qcq = qm8(qdq0, qdq1);
wire [7:0] qgq = qm8(qdq2, qdq3);
wire signed [9:0] qlq0 = $signed({2'b0, qbq}) - $signed({2'b0, qaq});
wire signed [9:0] qlq1 = $signed({2'b0, qgq}) - $signed({2'b0, qcq});
wire [1:0] qkq = qarg(qdq0, qdq1, qdq2, qdq3);
wire [7:0] qzq = qd(qvq, 9'sd0);
wire [7:0] qmq = qm8(qm8(qm8(qdq0, qdq1), qdq2), qdq3);
wire [8:0] qmd = {1'b0, qmi} + {1'b0, qmq};
wire qor = (qzi > q7v) || (qzq > q7v);
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(a[31:16] != 16'd0 || b[31:3] != 29'd0 || b[2:0] == 3'd0 || c[31:3] != 29'd0) f = 1'b1;
else begin
    pa = qscale(qli0, c[2:0]);
    r[7:0] = pa[7:0];
    x[11] = pa[8];
    pa = qscale(qli1, c[2:0]);
    r[15:8] = pa[7:0];
    x[12] = pa[8];
    pa = qscale(qlq0, c[2:0]);
    r[23:16] = pa[7:0];
    x[13] = pa[8];
    pa = qscale(qlq1, c[2:0]);
    r[31:24] = pa[7:0];
    x[14] = pa[8];
    x[0] = qli0[9];
    x[1] = qli1[9];
    x[2] = qlq0[9];
    x[3] = qlq1[9];
    x[5:4] = qki;
    x[7:6] = qkq;
    x[10:8] = c[2:0];
    x[15] = qor;
    x[24:16] = qmd;
    x[27:25] = b[2:0];
    x[31:28] = 4'd0;
    if(x[15] || x[14] || x[13] || x[12] || x[11]) f = 1'b1;
end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f;
            end
        end
    end
end
endmodule
