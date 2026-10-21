`timescale 1ns / 1ps

module tb_fused_butterfly;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg mode_dsa = 1'b0;
reg [22:0] a = 23'd0;
reg [22:0] b = 23'd0;
reg [22:0] twiddle = 23'd0;
wire [22:0] y0;
wire [22:0] y1;
wire busy;
wire done;

integer failures = 0;

always #5 clk = ~clk;

fused_butterfly dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .mode_dsa(mode_dsa),
    .inverse_mode(1'b0),
    .a(a),
    .b(b),
    .twiddle(twiddle),
    .y0(y0),
    .y1(y1),
    .busy(busy),
    .done(done)
);

task automatic run_case;
    input [80*8-1:0] name;
    input mode_dsa_i;
    input [22:0] a_i;
    input [22:0] b_i;
    input [22:0] twiddle_i;
    input [22:0] expect_y0_i;
    input [22:0] expect_y1_i;
    integer cycles;
    begin
        @(posedge clk);
        #1;
        mode_dsa = mode_dsa_i;
        a = a_i;
        b = b_i;
        twiddle = twiddle_i;
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;

        cycles = 0;
        while (!done && cycles < 80) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (!done) begin
            $display("FAIL %0s timeout", name);
            failures = failures + 1;
        end else if ((y0 !== expect_y0_i) || (y1 !== expect_y1_i)) begin
            $display("FAIL %0s y0=%0d expected=%0d y1=%0d expected=%0d",
                     name, y0, expect_y0_i, y1, expect_y1_i);
            failures = failures + 1;
        end else begin
            $display("PASS %0s cycles=%0d y0=%0d y1=%0d", name, cycles, y0, y1);
        end
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    run_case("ML-KEM q=3329 mixed butterfly", 1'b0, 23'd1234, 23'd2020, 23'd17, 23'd2284, 23'd184);
    run_case("ML-DSA q=8380417 mixed butterfly", 1'b1, 23'd1234567, 23'd7654321, 23'd1753, 23'd2211663, 23'd257471);
    run_case("ML-KEM wraparound", 1'b0, 23'd3328, 23'd3328, 23'd3328, 23'd0, 23'd3327);
    run_case("ML-DSA wraparound", 1'b1, 23'd8380416, 23'd8380415, 23'd8380414, 23'd5, 23'd8380410);
    run_case("ML-DSA high product", 1'b1, 23'd42, 23'd8380000, 23'd123456, 23'd7181809, 23'd1198692);

    if (failures == 0) begin
        $display("tb_fused_butterfly PASS");
        $finish;
    end else begin
        $display("tb_fused_butterfly FAIL failures=%0d", failures);
        $fatal(1);
    end
end

endmodule
