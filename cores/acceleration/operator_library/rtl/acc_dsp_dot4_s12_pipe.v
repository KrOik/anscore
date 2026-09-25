module acc_dsp_dot4_s12_pipe (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
// Fixed 512/1536/1536/512 Q12 decimator on four MULT12X12 slices.  Samples,
// products and the adder tree are each registered, so only the requantise shift
// and crop share a pipeline stage: one operator per level at 50 MHz.
localparam signed [11:0] C0 = 12'sd512, C1 = 12'sd1536;
localparam signed [11:0] C2 = 12'sd1536, C3 = 12'sd512;
reg signed [11:0] x0q, x1q, x2q, x3q;
reg signed [23:0] p0q, p1q, p2q, p3q;
reg signed [26:0] sumq;
reg [3:0] s1q, s2q, s3q;
reg v1, v2, v3;
wire [23:0] q0_raw, q1_raw, q2_raw, q3_raw;
wire signed [23:0] q0 = $signed(q0_raw);
wire signed [23:0] q1 = $signed(q1_raw);
wire signed [23:0] q2 = $signed(q2_raw);
wire signed [23:0] q3 = $signed(q3_raw);
MULT12X12 u_q0 (.DOUT(q0_raw), .A(x0q), .B(C0), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
MULT12X12 u_q1 (.DOUT(q1_raw), .A(x1q), .B(C1), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
MULT12X12 u_q2 (.DOUT(q2_raw), .A(x2q), .B(C2), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
MULT12X12 u_q3 (.DOUT(q3_raw), .A(x3q), .B(C3), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire signed [26:0] e0 = {{3{p0q[23]}}, p0q};
wire signed [26:0] e1 = {{3{p1q[23]}}, p1q};
wire signed [26:0] e2 = {{3{p2q[23]}}, p2q};
wire signed [26:0] e3 = {{3{p3q[23]}}, p3q};
wire signed [26:0] sum_next = e0 + e1 + e2 + e3;
reg signed [63:0] shifted;
reg [15:0] res_r;
reg [31:0] res_aux;
reg res_f;
always @* begin
    if(s3q==0) shifted = sumq;
    else shifted = (sumq + (27'sd1<<<(s3q-4'd1))) >>> s3q;
    if(shifted > 64'sd32767) begin res_r=16'h7fff; res_f=1'b1; end
    else if(shifted < -64'sd32768) begin res_r=16'h8000; res_f=1'b1; end
    else begin res_r=shifted[15:0]; res_f=1'b0; end
    res_aux = {s3q, res_f, sumq[26:0]};
end
assign in_ready = clk_en && (!out_valid || out_ready);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x0q<=12'sd0; x1q<=12'sd0; x2q<=12'sd0; x3q<=12'sd0;
        p0q<=24'sd0; p1q<=24'sd0; p2q<=24'sd0; p3q<=24'sd0;
        sumq<=27'sd0; s1q<=0; s2q<=0; s3q<=0;
        v1<=0; v2<=0; v3<=0;
        out_valid<=0; result<=0; aux<=0; fault<=0;
    end else if(in_ready) begin
        x0q<=a[11:0]; x1q<=a[23:12]; x2q<=b[11:0]; x3q<=b[23:12];
        s1q<=c[3:0];
        p0q<=q0; p1q<=q1; p2q<=q2; p3q<=q3;
        s2q<=s1q;
        sumq<=sum_next;
        s3q<=s2q;
        v3<=v2;
        v2<=v1;
        v1<=in_valid;
        result<={16'd0, res_r};
        aux<=res_aux;
        fault<=res_f;
        out_valid<=v3;
    end
end
endmodule
