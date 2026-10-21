// ============================================================================
// tb_ip25k_uart -- run ip25k_top at 50 MHz, receive the UART report byte
// stream, dump it for byte-exact comparison against sim/expected_report.hex
// (generated from the 20K golden digest tables, not from RTL).
// ============================================================================
`timescale 1ns/1ps
module tb_ip25k_uart;

    localparam integer BIT_NS = 8681;    // 1 / 115200 baud

    reg clk = 1'b0;
    always #10 clk = ~clk;               // 50 MHz board oscillator

    wire uart_tx, led;

    ip25k_top #(
        .CLK_DIV2(1),
        .W2_MASK (40'hE3_18_08_00_00),
        .CR_MASK (8'h1F),
        .CLK_FRE (25)
    ) dut (
        .clk(clk), .uart_tx(uart_tx), .led(led)
    );

    integer fdh, fdt;
    initial begin
        fdh = $fopen("sim/rx_capture.hex", "w");
        fdt = $fopen("sim/rx_capture.txt", "w");
    end

    reg        run = 1'b0;
    reg [7:0]  b;
    integer    i, rx_n = 0;

    initial begin
        #1_000_000;                       // ignore POR / config glitches
        run = 1'b1;
    end

    always begin
        @(negedge uart_tx);
        #(BIT_NS + BIT_NS / 2);
        b = 8'h00;
        for (i = 0; i < 8; i = i + 1) begin
            b[i] = uart_tx;               // LSB first
            #(BIT_NS);
        end
        if (run) begin
            $fwrite(fdh, "%02x ", b);
            if (b == 8'h0d || b == 8'h0a || (b >= 8'h20 && b < 8'h7f))
                $fwrite(fdt, "%c", b);
            rx_n = rx_n + 1;
            if (rx_n == 420) begin
                $display("RX_BYTES=%0d -- captured one full report cycle", rx_n);
                $finish;
            end
        end
    end

    initial begin
        #800_000_000;                     // 800 ms wall-clock sim budget
        $display("TIMEOUT rx_n=%0d (no full report)", rx_n);
        $finish;
    end

    // ---- progress monitor -------------------------------------------------
    initial begin
        $display("t_ms  w2done_mask              w2pass_mask              crdone crpass alldone tx");
        forever begin
            #2_000_000;
            $display("%6.3f %h %h %h %h %b %b | st=%b vld=%b rdy=%b gap=%0d line=%0d pos=%0d",
                     $time / 1.0e6,
                     dut.u_w2.done_mask, dut.u_w2.pass_mask,
                     dut.u_cr.done_mask, dut.u_cr.pass_mask,
                     dut.all_done, uart_tx,
                     dut.st, dut.tx_valid, dut.tx_ready, dut.gap,
                     dut.line, dut.pos);
        end
    end

endmodule
