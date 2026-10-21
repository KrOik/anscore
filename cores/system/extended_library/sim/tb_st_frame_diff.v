`timescale 1ns/1ps
// ============================================================================
// tb_st_frame_diff -- standalone TB for the FDIF selftest cell.
// reset -> start -> wait done -> print W2TB FDIF PASS/FAIL.  Dumps the folded
// byte stream to sim/dump_frame_diff.txt (diff against golden_frame_diff.txt).
// ============================================================================
module tb_st_frame_diff;
    reg clk = 1'b0, rst_n = 1'b0, clk_en = 1'b1, start = 1'b0;
    always #5 clk = ~clk;

    wire        done, pass;
    wire [31:0] digest;
    wire [15:0] cycles;

    st_frame_diff u_st (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .done(done), .pass(pass), .digest(digest), .cycles(cycles));

    integer fd;
    integer to;

    // byte-stream dump for diff vs sim/golden_frame_diff.txt
    always @(posedge clk) begin
        if (rst_n && u_st.dbg_v)
            $fwrite(fd, "%02x\n", u_st.dbg_byte);
    end

    initial begin
        fd = $fopen("sim/dump_frame_diff.txt", "w");
        repeat (8) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;
        for (to = 0; to < 200000; to = to + 1) begin
            @(posedge clk);
            if (done === 1'b1) to = 200000;
        end
        if (done !== 1'b1) begin
            $display("W2TB FDIF FAIL timeout");
        end else if (pass === 1'b1 && (^digest) !== 1'bx) begin
            $display("W2TB FDIF PASS D=%08X C=%d", digest, cycles);
        end else begin
            $display("W2TB FDIF FAIL D=%08X P=%b C=%d", digest, pass, cycles);
        end
        $fclose(fd);
        $finish;
    end
endmodule
