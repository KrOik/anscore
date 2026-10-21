`timescale 1ns / 1ps
// tb_sm3.v — SM3 testbench against GM/T 0004 standard vectors
//   SM3("abc")            = 66C7F0F4...8F4BA8E0
//   SM3("abcd" x 16)      = DEBE9FF9...9C0C5732  (64-byte message)
module tb_sm3;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg  [63:0] d;
reg  [7:0]  vbyte;
reg         vld, lst;
wire        rdy;
wire [255:0] res;
wire        res_vld;

sm3_top dut(
    .clk(clk), .rst_n(rst_n),
    .msg_inpt_d_i(d), .msg_inpt_vld_byte_i(vbyte),
    .msg_inpt_vld_i(vld), .msg_inpt_lst_i(lst),
    .msg_inpt_rdy_o(rdy),
    .cmprss_otpt_res_o(res), .cmprss_otpt_vld_o(res_vld)
);

integer errors = 0;
integer to;

task send_word(input [63:0] wd, input [7:0] vb, input last);
begin
    @(negedge clk);
    while (!rdy) @(negedge clk);
    d = wd; vbyte = vb; vld = 1; lst = last;
    @(negedge clk);
    vld = 0; lst = 0; d = 0; vbyte = 0;
end
endtask

task wait_res(input [255:0] exp, input [31:0] tag);
begin
    to = 0;
    while (!res_vld && to < 5000) begin @(posedge clk); to = to + 1; end
    if (to >= 5000) begin errors = errors + 1; $display("SM3 TIMEOUT tag=%h", tag); end
    else if (res === exp) $display("SM3 PASS tag=%h", tag);
    else begin
        errors = errors + 1;
        $display("SM3 FAIL tag=%h", tag);
        $display("  got  %h", res);
        $display("  want %h", exp);
    end
end
endtask

integer i;
initial begin
    d = 0; vbyte = 0; vld = 0; lst = 0;
    repeat (6) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);

    // ---- "abc" : one word, 3 valid bytes ----
    send_word(64'h6162630000000000, 8'hE0, 1'b1);
    wait_res(256'h66C7F0F462EEEDD9D1F2D46BDC10E4E24167C4875CF2F7A2297DA02B8F4BA8E0, 32'hC1);

    repeat (10) @(negedge clk);

    // ---- "abcd" x16 : 8 full words ----
    for (i = 0; i < 8; i = i + 1)
        send_word(64'h6162636461626364, 8'hFF, (i == 7));
    wait_res(256'hDEBE9FF92275B8A138604889C18E5A4D6FDB70E5387E5765293DCBA39C0C5732, 32'hC2);

    if (errors == 0) $display("SM3 ALL PASS");
    else             $display("SM3 ERRORS=%0d", errors);
    $finish;
end
endmodule
