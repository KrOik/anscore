`timescale 1ns / 1ps
// tb_sm2_alu: unit test mul_add_sub_mod_module (mod-p add/sub/mul)
module tb_sm2_alu;

reg clk = 0, rst_n = 0;
reg         vld = 0;
reg  [1:0]  sel;
reg  [255:0] a, b;
wire        done;
wire [255:0] r;
integer errors = 0;

localparam [255:0] P256 = 256'hFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF;

mul_add_sub_mod_module dut(
    .clk(clk), .rst_n(rst_n), .op_vld_i(vld), .op_sel_i(sel),
    .op_mod_num_i(P256), .op_a_i(a), .op_b_i(b),
    .op_done_o(done), .op_rslt_o(r)
);

always #5 clk = ~clk;

task chk(input [1:0] s, input [255:0] aa, input [255:0] bb, input [255:0] exp, input [31:0] tag);
integer to;
begin
    sel = s; a = aa; b = bb;
    @(negedge clk); vld = 1;
    to = 0;
    // add/sub done pulses mid-cycle while vld is still high; poll at #1 granularity
    while (!done && to < 2000) begin #1; to = to + 1; end
    @(negedge clk); vld = 0;
    if (to >= 2000) begin
        errors = errors + 1;
        $display("ALU TIMEOUT tag=%h sel=%b", tag, s);
    end else begin
    if (r === exp) $display("ALU PASS tag=%h", tag);
    else begin
        errors = errors + 1;
        $display("ALU FAIL tag=%h sel=%b", tag, s);
        $display("  a    %h", aa);
        $display("  b    %h", bb);
        $display("  got  %h", r);
        $display("  want %h", exp);
    end
    end
    repeat (2) @(negedge clk);
end
endtask

initial begin
    repeat (6) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);

    // ADD: a+b < p
    chk(2'b01, 256'd5, 256'd7, 256'd12, 32'hA1);
    // ADD: a+b >= p -> wraps
    chk(2'b01, P256-1, 256'd7, 256'd6, 32'hA2);
    // SUB: a >= b
    chk(2'b10, 256'd9, 256'd4, 256'd5, 32'hA3);
    // SUB: a < b -> +p
    chk(2'b10, 256'd4, 256'd9, P256-5, 32'hA4);
    // MUL small
    chk(2'b00, 256'd6, 256'd7, 256'd42, 32'hA5);
    // MUL large (Gx*Gy mod p) - computed by python
    chk(2'b00,
        256'h32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7,
        256'hBC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0,
        256'hEDD7E745BDC4630CCFA1DA1057033A525346DBF202F082F3C431349991ACE76A, 32'hA6);

    if (errors == 0) $display("SM2_ALU ALL PASS");
    else             $display("SM2_ALU ERRORS=%0d", errors);
    $finish;
end
endmodule
