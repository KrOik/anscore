`timescale 1ns/1ps
module tb_cscdbg2;
    reg clk = 0;
    wire tx, sp;
    always #18.5 clk = ~clk;
    top_cscdbg dut (.clk(clk), .uart_tx(tx), .status_pass(sp));
    integer cyc = 0;
    initial begin
        repeat (300000) begin
            @(posedge clk); cyc = cyc + 1;
            if (cyc % 8192 == 0)
                $display("cyc=%0d rst_n=%b run=%b o_v=%b o_dat=%06x q_n=%0d txv=%b txb=%b done=%b ocnt=%0d fidx=%0d",
                    cyc, dut.rst_n, dut.run, dut.o_v, dut.o_dat, dut.q_n,
                    dut.tx_valid, dut.tx_busy, dut.done_r, dut.ocnt, dut.s_fidx);
        end
        $display("END cyc=%0d done=%b ocnt=%0d digest=%08x", cyc, dut.done_r, dut.ocnt, dut.digest);
        $finish;
    end
endmodule
