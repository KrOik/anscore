`timescale 1ns/1ps

module tb_common_uart_smoke_25k;
    localparam integer CLOCK_HZ = 50000000;
    localparam integer BAUD = 115200;
    localparam integer BIT_CLKS = CLOCK_HZ / BAUD;

    reg clk = 1'b0;
    reg uart_rx_pin = 1'b1;
    wire uart_tx;
    wire dbg_uart;
    wire uart_tx_fail;
    wire dbg_uart_fail;
    integer i_success;
    integer i_fail;
    reg [7:0] got_success;
    reg [7:0] got_fail;

    always #10 clk = ~clk;

    common_uart_smoke_25k #(
        .CLK_HZ(CLOCK_HZ), .BAUD(BAUD), .TIMEOUT_CYCLES(300000)
    ) dut (
        .clk(clk), .uart_rx_pin(uart_rx_pin),
        .uart_tx(uart_tx), .dbg_uart(dbg_uart)
    );

    common_uart_smoke_25k #(
        .CLK_HZ(CLOCK_HZ), .BAUD(BAUD), .TIMEOUT_CYCLES(30000)
    ) dut_fail (
        .clk(clk), .uart_rx_pin(uart_rx_pin),
        .uart_tx(uart_tx_fail), .dbg_uart(dbg_uart_fail)
    );

    task automatic receive_uart_byte;
        input use_fail_uart;
        output reg [7:0] value;
        integer bitno;
        begin
            if (use_fail_uart) @(negedge uart_tx_fail);
            else @(negedge uart_tx);
            // Sample the center of data bit zero, then each following bit.
            repeat (BIT_CLKS + BIT_CLKS/2) @(posedge clk);
            value = 8'd0;
            for (bitno = 0; bitno < 8; bitno = bitno + 1) begin
                if (use_fail_uart) value[bitno] = uart_tx_fail;
                else value[bitno] = uart_tx;
                repeat (BIT_CLKS) @(posedge clk);
            end
            if ((use_fail_uart && uart_tx_fail !== 1'b1) ||
                (!use_fail_uart && uart_tx !== 1'b1))
                $fatal(1, "UART stop bit low while receiving byte %02x", value);
        end
    endtask

    function [7:0] expected_pattern;
        input integer index;
        begin
            case (index)
                0: expected_pattern = "C";
                1: expected_pattern = "I";
                2: expected_pattern = "P";
                3: expected_pattern = "2";
                4: expected_pattern = "5";
                default: expected_pattern = "K";
            endcase
        end
    endfunction

    function [7:0] expected_pass;
        input integer index;
        begin
            case (index)
                0: expected_pass = "P";
                1: expected_pass = "A";
                2: expected_pass = "S";
                3: expected_pass = "S";
                4: expected_pass = " ";
                5: expected_pass = "c";
                6: expected_pass = "o";
                7: expected_pass = "m";
                8: expected_pass = "m";
                9: expected_pass = "o";
                10: expected_pass = "n";
                11: expected_pass = "_";
                12: expected_pass = "u";
                13: expected_pass = "a";
                14: expected_pass = "r";
                15: expected_pass = "t";
                16: expected_pass = 8'h0d;
                default: expected_pass = 8'h0a;
            endcase
        end
    endfunction

    function [7:0] expected_fail;
        input integer index;
        begin
            case (index)
                0: expected_fail = "F";
                1: expected_fail = "A";
                2: expected_fail = "I";
                3: expected_fail = "L";
                4: expected_fail = " ";
                5: expected_fail = "c";
                6: expected_fail = "o";
                7: expected_fail = "m";
                8: expected_fail = "m";
                9: expected_fail = "o";
                10: expected_fail = "n";
                11: expected_fail = "_";
                12: expected_fail = "u";
                13: expected_fail = "a";
                14: expected_fail = "r";
                15: expected_fail = "t";
                16: expected_fail = 8'h0d;
                default: expected_fail = 8'h0a;
            endcase
        end
    endfunction

    initial begin : run_test
        // The board harness has a 32768-clock power-on reset. Verify both the
        // normal loopback path and its bounded-timeout failure report.
        fork : test_or_timeout
          begin : all_checks
            fork : concurrent_checks
              begin
                for (i_success = 0; i_success < 6; i_success = i_success + 1) begin
                    receive_uart_byte(1'b0, got_success);
                    if (got_success !== expected_pattern(i_success))
                        $fatal(1, "loopback byte %0d expected %02x got %02x",
                               i_success, expected_pattern(i_success), got_success);
                end
                for (i_success = 0; i_success < 18; i_success = i_success + 1) begin
                    receive_uart_byte(1'b0, got_success);
                    if (got_success !== expected_pass(i_success))
                        $fatal(1, "PASS text byte %0d expected %02x got %02x",
                               i_success, expected_pass(i_success), got_success);
                end
                wait (dbg_uart === 1'b1);
              end
              begin
                wait (dut_fail.rst_n === 1'b1);
                // Hold the failure instance's internal RX high to force a
                // loopback receive timeout; do not disturb the success DUT.
                force dut_fail.core_rx = 1'b1;
                receive_uart_byte(1'b1, got_fail);
                if (got_fail !== "C")
                    $fatal(1, "failure DUT pattern byte expected C got %02x", got_fail);
                for (i_fail = 0; i_fail < 18; i_fail = i_fail + 1) begin
                    receive_uart_byte(1'b1, got_fail);
                    if (got_fail !== expected_fail(i_fail))
                        $fatal(1, "FAIL text byte %0d expected %02x got %02x",
                               i_fail, expected_fail(i_fail), got_fail);
                end
                if (dut_fail.fail_latched !== 1'b1 ||
                    dut_fail.pass_latched !== 1'b0)
                    $fatal(1, "failure DUT status latch incorrect");
              end
            join
            $display("PASS common_uart_smoke_25k: loopback, PASS and FAIL paths verified");
          end
          begin
            repeat (1000000) @(posedge clk);
            $fatal(1, "timeout waiting for complete common_uart smoke output");
          end
        join_any
        disable test_or_timeout;
        $finish;
    end
endmodule
