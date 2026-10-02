// Sim-only plumbing check for mul12_silicon_probe: replaces the black-box
// MULT12X12 with an unsigned behavioural model, decodes the UART frame, and
// prints the products so the host can compare against the operand table.
`timescale 1ns/1ps
`default_nettype none

module MULT12X12 #(
    parameter AREG_CLK = "BYPASS", parameter BREG_CLK = "BYPASS",
    parameter PREG_CLK = "BYPASS", parameter OREG_CLK = "BYPASS"
) (
    output wire [23:0] DOUT,
    input wire [11:0] A, B,
    input wire [1:0] CLK, CE, RESET
);
    assign DOUT = A * B;
endmodule

module tb_mulprobe_sim;
    localparam real TBIT = 8680.0;   // 434 clk @ 20 ns = 115200 baud

    reg clk = 1'b0;
    always #10 clk = ~clk;

    wire uart_tx;
    mul12_silicon_probe dut(.clk(clk), .uart_tx(uart_tx));

    byte frame [0:63];
    integer n = 0;

    initial begin : rx
        integer i;
        while (n < 31) begin
            @(negedge uart_tx);
            #(1.5 * TBIT);
            for (i = 0; i < 8; i = i + 1) begin
                frame[n][i] = uart_tx;
                #TBIT;
            end
            n = n + 1;
        end
        $display("FRAME_BYTES %0d", n);
        for (i = 0; i < n; i = i + 1) $display("BYTE %2d = %02h", i, frame[i]);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TB timeout after %0d bytes", n);
        $finish;
    end
endmodule
