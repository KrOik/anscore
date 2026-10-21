`timescale 1ns / 1ps

module tb_doa_uart_reporter;

localparam integer CLK_HALF_PERIOD = 500;
localparam integer BIT_PERIOD = 10000;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg result_valid = 1'b0;
reg [3:0] led_index = 4'd0;
reg direction_active = 1'b0;
reg [31:0] report0 = 32'd0;
reg [31:0] report1 = 32'd0;
reg [31:0] report2 = 32'd0;
reg [31:0] report3 = 32'd0;
reg [31:0] diag0 = 32'd0;
reg [31:0] diag1 = 32'd0;
reg [31:0] diag2 = 32'd0;
reg [31:0] diag3 = 32'd0;
wire uart_tx;

reg [7:0] expected [0:23];
reg [7:0] rx_byte;
integer i;

always #CLK_HALF_PERIOD clk = ~clk;

doa_uart_reporter #(
    .CLK_FRE(1),
    .BAUD_RATE(100000),
    .HEARTBEAT_CYCLES(50)
) dut (
    .clk(clk),
    .rst_n(rst_n),
    .result_valid(result_valid),
    .led_index(led_index),
    .direction_active(direction_active),
    .report0(report0),
    .report1(report1),
    .report2(report2),
    .report3(report3),
    .diag0(diag0),
    .diag1(diag1),
    .diag2(diag2),
    .diag3(diag3),
    .uart_tx(uart_tx)
);

task pulse_result_valid;
    begin
        @(posedge clk);
        result_valid <= 1'b1;
        @(posedge clk);
        result_valid <= 1'b0;
    end
endtask

task automatic uart_read_byte;
    output reg [7:0] value;
    integer bit_index;
    begin
        @(negedge uart_tx);
        #(BIT_PERIOD + BIT_PERIOD / 2);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            value[bit_index] = uart_tx;
            #BIT_PERIOD;
        end
        if (uart_tx !== 1'b1) begin
            $display("FAIL: stop bit not high");
            $finish_and_return(1);
        end
        #(BIT_PERIOD / 2);
    end
endtask

task load_expected_frame;
    input [3:0] expected_flags;
    input [3:0] expected_led;
    input [31:0] expected_energy0;
    input [31:0] expected_energy1;
    input [31:0] expected_energy2;
    input [31:0] expected_energy3;
    input [15:0] expected_seq;
    begin
        expected[0] = 8'hAA;
        expected[1] = 8'h55;
        expected[2] = 8'h01;
        expected[3] = {expected_flags, expected_led};
        expected[4] = expected_energy0[31:24];
        expected[5] = expected_energy0[23:16];
        expected[6] = expected_energy0[15:8];
        expected[7] = expected_energy0[7:0];
        expected[8] = expected_energy1[31:24];
        expected[9] = expected_energy1[23:16];
        expected[10] = expected_energy1[15:8];
        expected[11] = expected_energy1[7:0];
        expected[12] = expected_energy2[31:24];
        expected[13] = expected_energy2[23:16];
        expected[14] = expected_energy2[15:8];
        expected[15] = expected_energy2[7:0];
        expected[16] = expected_energy3[31:24];
        expected[17] = expected_energy3[23:16];
        expected[18] = expected_energy3[15:8];
        expected[19] = expected_energy3[7:0];
        expected[20] = expected_seq[15:8];
        expected[21] = expected_seq[7:0];
        expected[22] = 8'h0D;
        expected[23] = 8'h0A;
    end
endtask

task read_and_check_frame;
    begin
        for (i = 0; i < 24; i = i + 1) begin
            uart_read_byte(rx_byte);
            if (rx_byte !== expected[i]) begin
                $display(
                    "FAIL: byte %0d mismatch, expected %02x got %02x",
                    i,
                    expected[i],
                    rx_byte
                );
                $finish_and_return(1);
            end
        end
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;

    led_index <= 4'd6;
    report0 <= 32'h00010203;
    report1 <= 32'h10213243;
    report2 <= 32'h55667788;
    report3 <= 32'hA0B0C0D0;
    direction_active <= 1'b1;
    load_expected_frame(4'h1, 4'd6, 32'h00010203, 32'h10213243, 32'h55667788, 32'hA0B0C0D0, 16'h0000);
    pulse_result_valid();
    read_and_check_frame();

    led_index <= 4'd9;
    direction_active <= 1'b0;
    report0 <= 32'h01020304;
    report1 <= 32'h11121314;
    report2 <= 32'h21222324;
    report3 <= 32'h31323334;
    load_expected_frame(4'h0, 4'd9, 32'h01020304, 32'h11121314, 32'h21222324, 32'h31323334, 16'h0001);
    pulse_result_valid();
    read_and_check_frame();

    diag0 <= 32'h000000AA;
    diag1 <= 32'h000000BB;
    diag2 <= 32'h000000CC;
    diag3 <= 32'hFFFFFF9C;
    load_expected_frame(4'h1, 4'd9, 32'h000000AA, 32'h000000BB, 32'h000000CC, 32'hFFFFFF9C, 16'h0002);
    read_and_check_frame();

    $display("PASS: doa_uart_reporter frame format test");
    $finish;
end

endmodule
