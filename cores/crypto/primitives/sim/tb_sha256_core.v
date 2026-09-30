`timescale 1ns / 1ps
// Standalone check of sha256_core against hashlib-derived digests
// (tools/golden_model.py output, independent of RTL).
module tb_sha256_core;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg init = 1'b0;
reg [7:0] din = 8'd0;
reg dv = 1'b0, dl = 1'b0;
wire ready;
wire [255:0] digest;
wire dvld;
integer failures = 0;

always #5 clk = ~clk;

sha256_core dut (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .init(init), .din(din), .din_valid(dv), .din_last(dl),
    .din_ready(ready), .digest(digest), .digest_valid(dvld)
);

localparam [447:0] MSG1 =
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";

localparam [23:0] MSG0 = "abc";

function [7:0] msg_byte;
    input [1:0] m;
    input [6:0] i;
    begin
        if (m == 2'd0)
            msg_byte = MSG0[23 - {i,3'b000} -: 8];
        else if (m == 2'd1)
            msg_byte = MSG1[447 - {i,3'b000} -: 8];
        else
            msg_byte = ({i,5'b00000} - {5'b00000,i}) + {7'b0,i[6:2]} + 12'd7;
    end
endfunction

function [6:0] msg_len;
    input [1:0] m;
    begin
        case (m)
            2'd0: msg_len = 7'd3;
            2'd1: msg_len = 7'd56;
            default: msg_len = 7'd100;
        endcase
    end
endfunction

task run_msg;
    input [1:0] m;
    input [255:0] exp;
    integer i;
    begin
        @(posedge clk); init <= 1'b1;
        @(posedge clk); init <= 1'b0;
        for (i = 0; i < msg_len(m); i = i + 1) begin
            @(posedge clk);
            while (!ready) @(posedge clk);
            din <= msg_byte(m, i[6:0]);
            dv  <= 1'b1;
            dl  <= (i == msg_len(m) - 1);
        end
        @(posedge clk); dv <= 1'b0; dl <= 1'b0;
        wait (dvld === 1'b1);
        @(posedge clk);
        if (digest !== exp) begin
            $display("FAIL msg%0d got=%064x", m, digest);
            $display("          exp=%064x", exp);
            failures = failures + 1;
        end else begin
            $display("ok   msg%0d -> %064x", m, digest);
        end
    end
endtask

initial begin
    repeat (8) @(posedge clk);
    rst_n <= 1'b1;
    repeat (4) @(posedge clk);

    run_msg(2'd0, 256'hba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad);
    run_msg(2'd1, 256'h248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1);
    run_msg(2'd2, 256'h522cf4d3d7fbab6fe9d0fe47f254a407639986722a4fb54027635b0827db84ea);

    if (failures == 0) $display("tb_sha256_core PASS");
    else               $display("tb_sha256_core FAIL failures=%0d", failures);
    $finish;
end

initial begin
    repeat (200000) @(posedge clk);
    $display("tb_sha256_core FAIL timeout");
    $fatal(1);
end

endmodule
