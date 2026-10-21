`timescale 1ns / 1ps
// Standalone check of crc_core: "123456789" check values for all three modes
// plus the 64-byte selftest stream values (independent golden model).
module tb_crc_core;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg [1:0] mode = 2'd0;
reg init = 1'b0;
reg [7:0] din = 8'd0;
reg dv = 1'b0;
wire [31:0] crc_out;
integer failures = 0;

always #5 clk = ~clk;

crc_core dut (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .mode(mode), .init(init), .din(din), .din_valid(dv),
    .crc_out(crc_out)
);

function [7:0] crc_byte;
    input [6:0] j;
    begin
        if (j < 7'd9) crc_byte = 8'h31 + j[3:0];
        else crc_byte = {j,5'b00000} + {3'b000,j,2'b00} + {5'b00000,j}
                        + {6'b000000,j[6:1]} + 12'h011;
    end
endfunction

task feed_byte;
    input [7:0] b;
    begin
        @(posedge clk); din <= b; dv <= 1'b1;
        @(posedge clk); dv <= 1'b0;
    end
endtask

task run_check;
    input [1:0] m;
    input integer n;      // 9 = "123456789", 64 = selftest stream
    input [31:0] exp;
    integer j;
    begin
        @(posedge clk); mode <= m; init <= 1'b1;
        @(posedge clk); init <= 1'b0;
        for (j = 0; j < n; j = j + 1) feed_byte(crc_byte(j[6:0]));
        @(posedge clk);
        if (crc_out !== exp) begin
            $display("FAIL mode=%0d n=%0d got=%08x exp=%08x",
                     m, n, crc_out, exp);
            failures = failures + 1;
        end else begin
            $display("ok   mode=%0d n=%0d crc=%08x", m, n, crc_out);
        end
    end
endtask

initial begin
    repeat (8) @(posedge clk);
    rst_n <= 1'b1;
    repeat (4) @(posedge clk);

    // standard check values over "123456789"
    run_check(2'd0, 9, 32'h000000F4);        // CRC-8/SMBUS
    run_check(2'd1, 9, 32'h000029B1);        // CRC-16/CCITT-FALSE
    run_check(2'd2, 9, 32'hCBF43926);        // CRC-32/ISO-HDLC
    // 64-byte selftest stream (golden model values)
    run_check(2'd0, 64, 32'h000000DE);
    run_check(2'd1, 64, 32'h00000CF3);
    run_check(2'd2, 64, 32'hBF4ACFD5);

    if (failures == 0) $display("tb_crc_core PASS");
    else               $display("tb_crc_core FAIL failures=%0d", failures);
    $finish;
end

initial begin
    repeat (100000) @(posedge clk);
    $display("tb_crc_core FAIL timeout");
    $fatal(1);
end

endmodule
