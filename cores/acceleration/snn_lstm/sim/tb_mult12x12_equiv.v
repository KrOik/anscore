`timescale 1ns / 1ps
// Exhaustive equivalence check for the SNN core's multiplier swap: the old
// fabric helper computed |a|*|b| then re-applied the sign after truncating to
// ACC_W; the core now takes the low 16 bits of a signed MULT12X12 product.
// Over all 65536 signed 8x8 operand pairs the two must agree bit for bit.
module tb_mult12x12_equiv;
    localparam ACC_W = 16;

    reg  signed [7:0] a, b;
    wire signed [23:0] dout;
    wire signed [ACC_W-1:0] new_pv = dout[15:0];

    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("BYPASS"), .OREG_CLK("BYPASS"))
        u_dut (.DOUT(dout), .A({{4{a[7]}}, a}), .B({{4{b[7]}}, b}),
               .CLK(2'b00), .CE(2'b00), .RESET(2'b00));

    // the retired helper, kept verbatim
    function signed [ACC_W-1:0] smul8;
        input signed [7:0] x;
        input signed [7:0] y;
        reg [8:0]         am, bm;
        reg [17:0]        pp;
        reg signed [17:0] ps;
        begin
            am = x[7] ? ({1'b0, ~x} + 9'd1) : {1'b0, x};
            bm = y[7] ? ({1'b0, ~y} + 9'd1) : {1'b0, y};
            pp = am * bm;
            ps = $signed({1'b0, pp});
            smul8 = x[7] ^ y[7] ? -ps[ACC_W-1:0] : ps[ACC_W-1:0];
        end
    endfunction

    integer i, j, bad;
    initial begin
        bad = 0;
        for (i = 0; i < 256; i = i + 1) begin
            for (j = 0; j < 256; j = j + 1) begin
                a = i[7:0];
                b = j[7:0];
                #1;
                if (new_pv !== smul8(a, b)) begin
                    if (bad < 5)
                        $display("MISMATCH a=%0d b=%0d dsp=%0d old=%0d",
                                 a, b, new_pv, smul8(a, b));
                    bad = bad + 1;
                end
            end
        end
        if (bad == 0)
            $display("MULT12X12 VS SMUL8 PASS (65536 operand pairs, 0 differences)");
        else
            $display("MULT12X12 VS SMUL8 FAIL (%0d differences)", bad);
        $finish;
    end
endmodule
