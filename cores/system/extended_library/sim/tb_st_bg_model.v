`timescale 1ns/1ps
// ============================================================================
// tb_st_bg_model -- standalone TB for the BGS selftest cell.
// reset -> start -> wait done -> print W2TB BGS PASS/FAIL.  Dumps the folded
// byte stream to sim/dump_bg_model.txt (diff against golden_bg_model.txt).
// ============================================================================
module tb_st_bg_model;
    reg clk = 1'b0, rst_n = 1'b0, clk_en = 1'b1, start = 1'b0;
    always #5 clk = ~clk;

    wire        done, pass;
    wire [31:0] digest;
    wire [15:0] cycles;

    st_bg_model u_st (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .done(done), .pass(pass), .digest(digest), .cycles(cycles));

    integer fd;
    integer to;

    // byte-stream dump for diff vs sim/golden_bg_model.txt
    always @(posedge clk) begin
        if (rst_n && u_st.dbg_v)
            $fwrite(fd, "%02x\n", u_st.dbg_byte);
    end

    initial begin
        fd = $fopen("sim/dump_bg_model.txt", "w");
        repeat (8) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;
        for (to = 0; to < 300000; to = to + 1) begin
            @(posedge clk);
            if (done === 1'b1) to = 300000;
        end
        if (done !== 1'b1) begin
            $display("W2TB BGS FAIL timeout");
        end else if (pass === 1'b1 && (^digest) !== 1'bx) begin
            $display("W2TB BGS PASS D=%08X C=%d", digest, cycles);
        end else begin
            $display("W2TB BGS FAIL D=%08X P=%b C=%d", digest, pass, cycles);
        end
        $fclose(fd);
        $finish;
    end
endmodule
