`timescale 1ns/1ps

module tb_image_filter_selftest_25k;
    localparam integer BIT_NS = 8680;
    reg clk = 0;
    reg uart_rx_pin = 1;
    wire uart_tx;
    wire dbg_uart;
    integer bit_index;
    reg [7:0] received_byte;
    string message;
    integer byte_count;

    always #10 clk = ~clk;

    image_filter_selftest_25k dut (
        .clk(clk), .uart_rx_pin(uart_rx_pin), .uart_tx(uart_tx),
        .dbg_uart(dbg_uart)
    );

    function [7:0] expected_uart_byte;
        input integer index;
        begin
            case (index)
                0: expected_uart_byte = "F";
                1: expected_uart_byte = "I";
                2: expected_uart_byte = "L";
                3: expected_uart_byte = "T";
                4: expected_uart_byte = "E";
                5: expected_uart_byte = "R";
                6: expected_uart_byte = " ";
                7: expected_uart_byte = "P";
                8: expected_uart_byte = "A";
                9: expected_uart_byte = "S";
                10: expected_uart_byte = "S";
                11: expected_uart_byte = " ";
                12: expected_uart_byte = "D";
                13: expected_uart_byte = "=";
                14: expected_uart_byte = "3";
                15: expected_uart_byte = "7";
                16: expected_uart_byte = "8";
                17: expected_uart_byte = "E";
                18: expected_uart_byte = "8";
                19: expected_uart_byte = "A";
                20: expected_uart_byte = "A";
                21: expected_uart_byte = "B";
                22: expected_uart_byte = 8'h0d;
                default: expected_uart_byte = 8'h0a;
            endcase
        end
    endfunction

    initial begin
        message = "";
        byte_count = 0;
        @(negedge uart_tx);
        forever begin
            #(BIT_NS * 1.5);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                received_byte[bit_index] = uart_tx;
                #BIT_NS;
            end
            if (uart_tx !== 1'b1) $fatal(1, "UART stop bit low");
            message = {message, received_byte};
            if (received_byte !== expected_uart_byte(byte_count))
                $fatal(1, "UART byte %0d: expected %02x got %02x", byte_count,
                       expected_uart_byte(byte_count), received_byte);
            byte_count = byte_count + 1;
            if (received_byte == 8'h0a) begin
                if (byte_count != 24) $fatal(1, "UART message length %0d", byte_count);
                if (dut.failed || !dut.passed || dut.output_digest != 32'h378e8aab)
                    $fatal(1, "board self-test state/digest mismatch: failed=%0d passed=%0d digest=%08x",
                           dut.failed, dut.passed, dut.output_digest);
                if (dbg_uart !== 1'b1) $fatal(1, "PASS debug pin not asserted");
                $display("PASS image_filter_selftest_25k: %s", message);
                $finish;
            end
            @(negedge uart_tx);
        end
    end

    initial begin
        #20_000_000;
        $fatal(1, "board self-test timed out");
    end
endmodule
