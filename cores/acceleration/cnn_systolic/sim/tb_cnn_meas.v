`timescale 1ns / 1ps

// Decodes the UART byte stream from cnn_meas_top and compares the raw
// IL/LY dump regions against golden byte files (tools/gen_meas_golden.py).
// Prints the measured timing header for inspection.
module tb_cnn_meas;

`ifndef IL_FILE
`define IL_FILE "sim/meas_expected_il.mem"
`endif
`ifndef LY_FILE
`define LY_FILE "sim/meas_expected_ly.mem"
`endif

localparam integer UART_CYCLE = 234;
localparam integer MSG_LEN = 954;
localparam integer IL_BASE = 67;
localparam integer IL_LEN  = 720;
localparam integer LY_BASE = 792;
localparam integer LY_LEN  = 160;

reg clk = 1'b0;
wire uart_tx_pin;
wire status_done;

integer failures = 0;
integer index;
reg [7:0] rx_byte;
reg [7:0] exp_il [0:IL_LEN-1];
reg [7:0] exp_ly [0:LY_LEN-1];
reg [8*64-1:0] header;

always #5 clk = ~clk;

cnn_meas_top dut (
    .clk(clk),
    .uart_tx_pin(uart_tx_pin),
    .status_done(status_done)
);

task read_uart_byte;
    output [7:0] value;
    integer bit_index;
    begin
        @(negedge uart_tx_pin);
        repeat (UART_CYCLE + (UART_CYCLE / 2)) @(posedge clk);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            value[bit_index] = uart_tx_pin;
            repeat (UART_CYCLE) @(posedge clk);
        end
        if (uart_tx_pin !== 1'b1) begin
            $display("FAIL UART stop bit low");
            failures = failures + 1;
        end
        repeat (UART_CYCLE / 2) @(posedge clk);
    end
endtask

initial begin
    $readmemh(`IL_FILE, exp_il);
    $readmemh(`LY_FILE, exp_ly);
    wait (status_done);

    for (index = 0; index < MSG_LEN; index = index + 1) begin
        read_uart_byte(rx_byte);
        if (index < 64) begin
            header[(63 - index)*8 +: 8] = rx_byte;
        end else if (index >= IL_BASE && index < IL_BASE + IL_LEN) begin
            if (rx_byte !== exp_il[index - IL_BASE]) begin
                if (failures < 20)
                    $display("FAIL IL byte[%0d]=0x%02x expected=0x%02x",
                             index - IL_BASE, rx_byte, exp_il[index - IL_BASE]);
                failures = failures + 1;
            end
        end else if (index >= LY_BASE && index < LY_BASE + LY_LEN) begin
            if (rx_byte !== exp_ly[index - LY_BASE]) begin
                if (failures < 40)
                    $display("FAIL LY byte[%0d]=0x%02x expected=0x%02x",
                             index - LY_BASE, rx_byte, exp_ly[index - LY_BASE]);
                failures = failures + 1;
            end
        end
    end

    // header is big-endian packed: byte0 in [511:504]
    $display("HEADER %s", header);

    if (failures == 0) begin
        $display("tb_cnn_meas PASS");
        $finish;
    end else begin
        $display("tb_cnn_meas FAIL failures=%0d", failures);
        $fatal(1);
    end
end

initial begin
    repeat (3000000) @(posedge clk);
    $display("tb_cnn_meas FAIL timeout");
    $fatal(1);
end

endmodule
