`timescale 1ns/1ps
// ============================================================================
// tb_st_isp_rgb2gray -- standalone TB for st_isp_rgb2gray.
// Prints "W2TB GRY PASS D=%08X C=%d"; dumps to sim/dump_isp_rgb2gray.txt.
// ============================================================================
module tb_st_isp_rgb2gray;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg [3:0] ce_div = 4'd0;
    always @(posedge clk) ce_div <= ce_div + 4'd1;
    wire ce = (ce_div == 4'd15);

    reg start = 1'b0;
    wire done, pass;
    wire [31:0] digest;
    wire [15:0] cycles;

    st_isp_rgb2gray dut (
        .clk(clk), .clk_en(ce), .rst_n(rst_n), .start(start),
        .done(done), .pass(pass), .digest(digest), .cycles(cycles));

    integer fd;
    initial fd = $fopen("sim/dump_isp_rgb2gray.txt", "w");

    always @(posedge clk) begin
        if (rst_n && ce && dut.o_v === 1'b1)
            $fwrite(fd, "%02x\n", dut.o_dat);
    end

    integer to;
    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (40) @(posedge clk);
        start <= 1'b1;
        to = 0;
        while (done !== 1'b1 && to < 400000) begin
            @(posedge clk); to = to + 1;
        end
        start <= 1'b0;
        repeat (64) @(posedge clk);
        if (done === 1'b1 && pass === 1'b1 && (^digest !== 1'bx))
            $display("W2TB GRY PASS D=%08X C=%d", digest, cycles);
        else
            $display("W2TB GRY FAIL done=%b pass=%b D=%08X C=%d",
                     done, pass, digest, cycles);
        $fclose(fd);
        $finish;
    end
endmodule
