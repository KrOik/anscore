`timescale 1ns / 1ps
// tb_sm2_inv: unit test sm2_mod_inv (binary extended-GCD inversion mod p)
module tb_sm2_inv;

reg clk = 0, rst_n = 0;
reg start = 0;
reg  [255:0] a, m;
wire busy, done, err;
wire [255:0] r;
integer errors = 0;

localparam [255:0] P256 = 256'hFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF;

sm2_mod_inv dut(.clk(clk), .rst_n(rst_n), .start(start), .a_i(a), .m_i(m),
                .busy(busy), .done(done), .err(err), .r_o(r));

always #5 clk = ~clk;

task chk(input [255:0] aa, input [255:0] mm, input [255:0] exp, input [31:0] tag);
integer to;
begin
    a = aa; m = mm;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    to = 0;
    while (!done && to < 10000) begin @(negedge clk); to = to + 1; end
    if (to >= 10000) begin errors = errors + 1; $display("INV TIMEOUT tag=%h", tag); end
    else if (err)    begin errors = errors + 1; $display("INV ERR tag=%h", tag); end
    else if (r === exp) $display("INV PASS tag=%h", tag);
    else begin
        errors = errors + 1;
        $display("INV FAIL tag=%h got=%h want=%h", tag, r, exp);
    end
    @(negedge clk);
end
endtask

initial begin
    repeat (6) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);

    chk(256'd3, P256,
        256'h55555554FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFAAAAAAAB0000000000000000, 32'hB1); // 3^-1 mod p
    // Z2jac inverse: expect BD6E428202E23159407B8820A55AA74912A8EDE43F77DE02F4CE5BA1B126394F
    chk(256'h786E6D46E9ECEF38B37B9DC6D6D242A7A1530EFA8C548E7F05BE65CA4273E141, P256,
        256'hBD6E428202E23159407B8820A55AA74912A8EDE43F77DE02F4CE5BA1B126394F, 32'hB2);
    chk(256'd1, P256, 256'd1, 32'hB3);

    if (errors == 0) $display("SM2_INV ALL PASS");
    else             $display("SM2_INV ERRORS=%0d", errors);
    $finish;
end
endmodule
