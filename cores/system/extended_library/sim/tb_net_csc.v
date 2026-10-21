// gate-level check: run the SYNTHESIZED st_isp_csc netlist and report digest.
`timescale 1ns/1ps
module tb_net_csc;
    reg clk = 0, rst_n = 0, start = 0;
    wire done, pass;
    wire [31:0] digest;
    wire [15:0] cycles;
    always #5 clk = ~clk;
    st_isp_csc dut (.clk(clk), .clk_en(1'b1), .rst_n(rst_n), .start(start),
                    .done(done), .pass(pass), .digest(digest), .cycles(cycles));
    integer to = 0;
    initial begin
        repeat (40) @(posedge clk);
        rst_n = 1;
        repeat (40) @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        while (!done && to < 2000000) begin @(posedge clk); to = to + 1; end
        $display("NETCSC done=%b pass=%b digest=%08x cycles=%0d", done, pass, digest, cycles);
        $finish;
    end
endmodule
