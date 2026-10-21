`timescale 1ns/1ps
// ============================================================================
// tb_st_feat_lbp -- standalone TB for st_feat_lbp (idx12, TAG=LBP).
// Prints "W2TB LBP PASS D=%08X C=%d" or FAIL; dumps DUT stream to
// sim/dump_feat_lbp.txt for byte-wise diff vs sim/golden_feat_lbp.txt.
// ============================================================================
module tb_st_feat_lbp;
    reg clk = 1'b0, rst_n = 1'b0, clk_en = 1'b1, start = 1'b0;
    always #5 clk = ~clk;

    wire        done, pass;
    wire [31:0] digest;
    wire [15:0] cycles;

    st_feat_lbp dut (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .done(done), .pass(pass), .digest(digest), .cycles(cycles));

    integer fd, i, any_fail;
    initial begin
        fd = $fopen("sim/dump_feat_lbp.txt", "w");
        any_fail = 0;
    end

    // byte-stream dump + X watch on the valid strobe
    always @(posedge clk) begin
        if (rst_n && dut.o_v === 1'b1)
            $fwrite(fd, "%02x\n%02x\n", dut.o_code, dut.o_uni);
        if (rst_n && dut.o_v !== 1'b0 && dut.o_v !== 1'b1)
            any_fail = 1;
    end

    initial begin
        repeat (8) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        i = 0;
        while (!done && i < 200000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (16) @(posedge clk);
        if (!done) begin
            $display("W2TB LBP FAIL timeout");
            any_fail = 1;
        end
        if (digest === 32'hxxxxxxxx || (^digest) === 1'bx)
            any_fail = 1;
        if (done && pass === 1'b1 && !any_fail)
            $display("W2TB LBP PASS D=%08X C=%d", digest, cycles);
        else
            $display("W2TB LBP FAIL D=%08X C=%d done=%b pass=%b",
                     digest, cycles, done, pass);
        $fclose(fd);
        $finish;
    end
endmodule
