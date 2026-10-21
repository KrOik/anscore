`timescale 1ns / 1ps
// Board-top acceptance testbench: captures the UART byte stream produced by
// top.v and diffs it byte-for-byte against model/expected_uart.txt (exported to
// sim/expected_uart_bytes.txt). Runs several report rounds to prove the
// sequencer restarts the cores deterministically, as the dock test relies on.
module tb_top_uart;
    // DIAG=1 switches the diff from "match the golden stream" to "every report
    // round is byte-identical", which is what the diag build's extra DIAG line
    // and its digest-vs-digest fields are for.
    parameter DIAG = 0;

    localparam EXPECTED_FILE = "expected_uart_bytes.txt";
    localparam EXP_LEN       = (DIAG != 0) ? 165 : 137;
    localparam ROUNDS        = 3;
    localparam CLKS_PER_BIT  = 434;         // 50 MHz / 115200
    localparam BIT_NS        = CLKS_PER_BIT * 20;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_key = 0;
    wire [1:0] led;
    wire uart_tx;

    top #(.RELOAD_CYCLES(27'd20_000), .DIAG(DIAG)) dut (
        .clk(clk), .rst_key(rst_key), .uart_rx(1'b1),
        .led(led), .uart_tx(uart_tx)
    );

    reg [7:0] expected [0:EXP_LEN-1];
    reg [7:0] cap [0:EXP_LEN*ROUNDS-1];
    integer ei;
    integer dumpf;

    initial begin
        dumpf = $fopen("uart_capture_dump.txt", "w");
        $readmemh(EXPECTED_FILE, expected);
    end

    reg [7:0] rx_b;
    integer got = 0;
    integer errs = 0;

    task rx_byte;
        output [7:0] b;
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                #(BIT_NS);
                b[k] = uart_tx;
            end
            #(BIT_NS);
            if (uart_tx !== 1'b1) begin
                $display("TB FAIL: missing stop bit on byte %0d", got);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        while (got < EXP_LEN*ROUNDS) begin
            @(negedge uart_tx);
            #(BIT_NS/2);
            if (uart_tx === 1'b0) begin
                rx_byte(rx_b);
                cap[got] = rx_b;
                $fwrite(dumpf, "%c", rx_b);
                if (DIAG == 0) begin
                    if (rx_b !== expected[got % EXP_LEN]) begin
                        $display("TB FAIL byte %0d: got %02X expected %02X",
                                 got, rx_b, expected[got % EXP_LEN]);
                        errs = errs + 1;
                    end
                end else if (got >= EXP_LEN && rx_b !== cap[got - EXP_LEN]) begin
                    $display("TB FAIL round-diff byte %0d: got %02X round1 %02X",
                             got, rx_b, cap[got - EXP_LEN]);
                    errs = errs + 1;
                end
                got = got + 1;
                if (got % EXP_LEN == 0)
                    $display("TB: round %0d captured (errs=%0d)",
                             got / EXP_LEN, errs);
            end
        end
    end

    initial begin
        #8_000_000_000;
        $display("TB FAIL: timeout, only captured %0d of %0d bytes",
                 got, EXP_LEN*ROUNDS);
        $finish;
    end

    initial begin
        wait (got == EXP_LEN*ROUNDS);
        #1000;
        $display("captured %0d bytes, %0d mismatches, led=%b", got, errs, led);
        if (DIAG == 0) begin
            if (errs == 0) $display("TOP UART PASS D=D79526F7 R=%0d", ROUNDS);
            else           $display("TOP UART FAIL");
        end else begin
            if (errs == 0) $display("TOP UART STABLE R=%0d", ROUNDS);
            else           $display("TOP UART DIAG UNSTABLE");
        end
        $finish;
    end
endmodule
