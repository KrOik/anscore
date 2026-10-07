`timescale 1ns/1ps
// ============================================================================
// tb_st_canny_grad -- standalone TB for st_canny_grad (idx6 CGR).
// reset -> start (1 clk_en beat) -> wait done -> print W2TB line + dump.
// Dump: sim/dump_canny_grad.txt, one hex byte per line (mag then dir per
// pixel), compared offline against sim/golden_canny_grad.txt.
// ============================================================================
module tb_st_canny_grad;
    reg clk = 1'b0, rst_n = 1'b0, clk_en = 1'b1, start = 1'b0;
    always #5 clk = ~clk;

    wire        done, pass;
    wire [31:0] digest;
    wire [15:0] cycles;

    st_canny_grad dut (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .done(done), .pass(pass), .digest(digest), .cycles(cycles)
    );

    integer fd, timeout;
    initial fd = $fopen("sim/dump_canny_grad.txt", "w");

    // one dump line pair per output beat (sampled at the clk edge)
    always @(posedge clk) begin
        if (rst_n && clk_en && dut.d_v === 1'b1)
            $fwrite(fd, "%02x\n%02x\n", dut.d_mag, {6'b0, dut.d_dir});
    end

    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        timeout = 0;
        while (done !== 1'b1 && timeout < 200000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        repeat (32) @(posedge clk);
        if (done !== 1'b1) begin
            $display("W2TB CGR FAIL timeout");
        end else if ((^digest === 1'bx) || (pass !== 1'b1)) begin
            $display("W2TB CGR FAIL D=%08X C=%d pass=%b", digest, cycles, pass);
        end else begin
            $display("W2TB CGR PASS D=%08X C=%d", digest, cycles);
        end
        $fclose(fd);
        $finish;
    end
endmodule
