// Probe 2: can a DIRECT primitive instance of the GW5A hard multiplier survive
// yosys -> nextpnr -> gowin_pack on GW5A-LV25MG121NES?  synth_gowin's dsp_map.v
// only knows the GW1N/GW2A MULT9X9/MULT18X18/MULT36X36 cells, so automatic
// inference cannot reach the 25K's MULT12X12/MULTALU27X18/MULTADDALU12X12.
`default_nettype none

module gw5a_hardip2(input wire clk, input wire rst, output wire [7:0] mon);
    reg [17:0] cnt = 18'd0;
    always @(posedge clk) cnt <= cnt + 18'd1;
    wire [11:0] a = cnt[11:0];
    wire [11:0] b = ~cnt[17:6];
    wire [23:0] p0, p1, p2, p3, p4, p5, p6, p7;

    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("ENABLE"), .OREG_CLK("BYPASS")) u0
        (.DOUT(p0), .A(a),       .B(b),      .CLK({clk, clk}), .CE(2'b11), .RESET({rst, rst}));
    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("ENABLE"), .OREG_CLK("BYPASS")) u1
        (.DOUT(p1), .A(a + 12'd1), .B(b + 12'd1), .CLK({clk, clk}), .CE(2'b11), .RESET({rst, rst}));
    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("ENABLE"), .OREG_CLK("BYPASS")) u2
        (.DOUT(p2), .A(a + 12'd2), .B(b + 12'd2), .CLK({clk, clk}), .CE(2'b11), .RESET({rst, rst}));
    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("ENABLE"), .OREG_CLK("BYPASS")) u3
        (.DOUT(p3), .A(a + 12'd3), .B(b + 12'd3), .CLK({clk, clk}), .CE(2'b11), .RESET({rst, rst}));
    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("ENABLE"), .OREG_CLK("BYPASS")) u4
        (.DOUT(p4), .A(a + 12'd4), .B(b + 12'd4), .CLK({clk, clk}), .CE(2'b11), .RESET({rst, rst}));
    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("ENABLE"), .OREG_CLK("BYPASS")) u5
        (.DOUT(p5), .A(a + 12'd5), .B(b + 12'd5), .CLK({clk, clk}), .CE(2'b11), .RESET({rst, rst}));
    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("ENABLE"), .OREG_CLK("BYPASS")) u6
        (.DOUT(p6), .A(a + 12'd6), .B(b + 12'd6), .CLK({clk, clk}), .CE(2'b11), .RESET({rst, rst}));
    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("ENABLE"), .OREG_CLK("BYPASS")) u7
        (.DOUT(p7), .A(a + 12'd7), .B(b + 12'd7), .CLK({clk, clk}), .CE(2'b11), .RESET({rst, rst}));

    // XOR-reduce, not a bit slice: every product bit must stay live or wreduce
    // shrinks the operation and the probe stops measuring what it meant to.
    assign mon = {^p7, ^p6, ^p5, ^p4, ^p3, ^p2, ^p1, ^p0};
endmodule
