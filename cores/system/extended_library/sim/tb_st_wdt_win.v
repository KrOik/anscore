`timescale 1ns/1ps
// ============================================================================
// tb_st_wdt_win -- standalone TB for st_wdt_win (TAG WDT).
// ============================================================================
module tb_st_wdt_win;
    reg clk = 1'b0, rst_n = 1'b0, start = 1'b0;
    reg [3:0] ced = 4'd0;
    wire clk_en = (ced == 4'd15);
    always #5 clk = ~clk;
    always @(posedge clk) ced <= ced + 4'd1;

    wire        done, pass;
    wire [31:0] digest;
    wire [15:0] cycles;
    st_wdt_win u_st (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .done(done), .pass(pass), .digest(digest), .cycles(cycles));

    integer fd, k;
    initial fd = $fopen("sim/dump_wdt_win.txt", "w");
    always @(posedge clk) if (clk_en) begin
        for (k = 0; k < 4; k = k + 1)
            if (k < u_st.dbg_cnt)
                $fwrite(fd, "%02x\n", u_st.dbg_data[k*8 +: 8]);
    end

    initial begin
        repeat (8) @(posedge clk);
        rst_n <= 1'b1;
        // exact one-clk_en-beat start pulse: enter a clk_en cycle, set
        // start mid-cycle so it covers the following ce posedge exactly once
        wait (clk_en);
        @(negedge clk); start = 1'b1;
        @(posedge clk);                 // ce edge: cell samples start
        @(negedge clk); start = 1'b0;
        wait (done === 1'b1);
        repeat (64) @(posedge clk);
        if (done === 1'b1 && pass === 1'b1 && (^digest) !== 1'bx)
            $display("W2TB WDT PASS D=%08X C=%d", digest, cycles);
        else
            $display("W2TB WDT FAIL D=%08X done=%b pass=%b", digest, done, pass);
        $fclose(fd);
        $finish;
    end

    initial begin
        #5000000;
        $display("W2TB WDT FAIL timeout");
        $fclose(fd);
        $finish;
    end
endmodule
