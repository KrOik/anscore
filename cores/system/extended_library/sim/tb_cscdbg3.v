`timescale 1ns/1ps
module tb_cscdbg3;
    reg clk = 0;
    wire tx, sp;
    always #18.5 clk = ~clk;
    top_cscdbg dut (.clk(clk), .uart_tx(tx), .status_pass(sp));
    integer ne = 0, cyc = 0;
    reg txd = 1;
    always @(posedge clk) begin
        txd <= tx;
        if (txd === 1'b1 && tx === 1'b0) ne = ne + 1;
    end
    initial begin
        repeat (300000) @(posedge clk);
        $display("negedges=%0d q_w=%0d q_r=%0d q_n=%0d enq_st=%0d ocnt=%0d",
                 ne, dut.q_w, dut.q_r, dut.q_n, dut.enq_st, dut.ocnt);
        $finish;
    end
endmodule
