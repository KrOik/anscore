// tb_hwverify -- simulate top_hwverify end to end:
//   * drives uart_rx with W/R/T commands
//   * decodes uart_tx replies
//   * checks all eight verification results
`timescale 1ns/1ps
module tb_hwverify;
    reg clk = 0;
    wire tx, sp, sf;
    reg  rxd = 1;
    wire [7:0] dbg;
    always #18.5 clk = ~clk;   // ~27 MHz

    top_hwverify #(.TICK_WIN(25'd100_000)) dut (
        .clk(clk), .uart_rx_pin(rxd), .uart_tx(tx),
        .status_pass(sp), .status_fail(sf),
        .dbg7(dbg[7]), .dbg6(dbg[6]), .dbg5(dbg[5]), .dbg4(dbg[4]),
        .dbg3(dbg[3]), .dbg2(dbg[2]), .dbg1(dbg[1]), .dbg0(dbg[0]));

    // ---- UART byte send task (115200 @27MHz) ----
    localparam integer BIT_NS = 8680;
    task txb(input [7:0] b);
        integer k;
        begin
            rxd = 0; #(BIT_NS);                 // start
            for (k = 0; k < 8; k = k + 1) begin
                rxd = b[k]; #(BIT_NS);
            end
            rxd = 1; #(BIT_NS);                 // stop
            #(BIT_NS);                          // inter-byte gap
        end
    endtask
    task cmd_W(input [7:0] a, input [31:0] d);
        begin txb(8'h57); txb(a); txb(d[7:0]); txb(d[15:8]);
              txb(d[23:16]); txb(d[31:24]); end
    endtask
    task cmd_R(input [7:0] a);
        begin txb(8'h52); txb(a); end
    endtask
    task cmd_T; begin txb(8'h54); end endtask

    // ---- UART decode of dut.tx ----
    localparam integer BIT_CLKS = 234;
    reg [7:0] rxq [0:4095];
    integer nrx = 0;
    integer bitcnt = 0;
    reg [9:0] shreg = 10'h3FF;
    reg rx_busy = 0;
    always @(posedge clk) begin
        if (!rx_busy && tx === 1'b0) begin
            rx_busy <= 1; bitcnt <= 0;
        end else if (rx_busy) begin
            bitcnt <= bitcnt + 1;
            if ((bitcnt % BIT_CLKS) == BIT_CLKS/2)
                shreg <= {tx, shreg[9:1]};
            if (bitcnt == 10*BIT_CLKS - BIT_CLKS/2 + 1) begin
                rx_busy <= 0;
                rxq[nrx] <= shreg[8:1];
                nrx <= nrx + 1;
            end
        end
    end

    function [31:0] qhex;           // 8 hex chars at rxq[idx+off .. +7]
        input integer idx, off; integer k; reg [7:0] c; reg [3:0] n;
        begin
            qhex = 0;
            for (k = 0; k < 8; k = k + 1) begin
                c = rxq[idx + off + k];
                n = (c >= "A") ? (c - "A" + 10) : (c - "0");
                qhex = {qhex[27:0], n};
            end
        end
    endfunction

    integer i, errs = 0;
    reg [31:0] v;
    integer base;
    initial begin
        rxd = 1;
        #(600000);                              // ~16k clks: POR + settle
        cmd_W(8'd0, 32'hDEADBEEF);
        cmd_R(8'd0); #(3000000);
        v = qhex(0, 2);
        if (v !== 32'hDEADBEEF) begin
            errs = errs + 1;
            $display("FAIL scratch readback: %08x", v);
        end else $display("T5 scratch R/W PASS (DEADBEEF)");

        cmd_R(8'd31); #(3000000);
        v = qhex(12, 2);
        if (v !== 32'h48375632) begin
            errs = errs + 1; $display("FAIL magic: %08x", v);
        end else $display("T5 magic reg PASS (HV2)");

        cmd_T; #(45000000);
        base = 24;
        $display("--- T report ---");
        for (i = 0; i < 16; i = i + 1)
            $display("R%0d = %08x", i, qhex(base + i*13, 3));

        v = qhex(base + 1*13, 3);                        // por
        if (v !== 32'h00001000 && v !== 32'h00000FFF) begin
            errs = errs + 1; $display("FAIL T0 por_cycles=%08x", v);
        end else $display("T0 POR len PASS (%0d clk)", v);

        v = qhex(base + 2*13, 3);                        // pll
        if (v[16] !== 1'b1) begin
            errs = errs + 1; $display("FAIL T1 pll_lock");
        end else $display("T1 PLL LOCK PASS (lat=%0d clk)", v[15:0]);

        v = qhex(base + 3*13, 3);                        // freq measure
        if (v[25] !== 1'b1) begin
            errs = errs + 1; $display("FAIL T7 tick measure done");
        end else if (v[24:0] < 190000 || v[24:0] > 210000) begin
            errs = errs + 1; $display("FAIL clk54 ticks=%0d", v[24:0]);
        end else $display("T7 freq PASS (clk54 ticks=%0d / win 100000)",
                          v[24:0]);

        v = qhex(base + 4*13, 3);                        // csc54 digest
        if (v !== 32'hCE41D92D) begin
            errs = errs + 1; $display("FAIL T7 csc54 digest=%08x", v);
        end else $display("T7 CSC@54MHz digest PASS");

        v = qhex(base + 6*13, 3);                        // cdc xfers
        if (v == 0) begin
            errs = errs + 1; $display("FAIL T2 cdc_xfers=0");
        end else $display("T2 CDC xfers=%0d", v[15:0]);
        v = qhex(base + 7*13, 3);                        // cdc errs
        if (v !== 32'd0) begin
            errs = errs + 1; $display("FAIL T2 cdc_errs=%0d", v);
        end else $display("T2 CDC errs=0 PASS");

        v = qhex(base + 11*13, 3);                       // thru cycles
        if (v < 2000 || v > 2300) begin
            errs = errs + 1; $display("FAIL T3 thru cyc=%0d", v);
        end else $display("T3 throughput PASS (cyc=%0d)", v);
        v = qhex(base + 13*13, 3);                       // digest27
        if (v !== 32'hCE41D92D) begin
            errs = errs + 1; $display("FAIL T3 digest=%08x", v);
        end else $display("T3 digest PASS");

        v = qhex(base + 14*13, 3);                       // edge flags
        if (v[17:16] !== 2'b11) begin
            errs = errs + 1; $display("FAIL T4 edge flags=%08x", v);
        end else $display("T4 boundary PASS (wdt+tmr)");

        v = qhex(base + 15*13, 3);                       // tmr detail
        if (v[16] !== 1'b1) begin
            errs = errs + 1; $display("FAIL T4 tmr done");
        end

        v = qhex(base + 0*13, 3);                        // scratch in report
        if (v !== 32'hDEADBEEF) begin
            errs = errs + 1; $display("FAIL report scratch=%08x", v);
        end

        txb(8'h50); txb(8'd2); #(2000000);
        if (sp !== 1'b1) begin
            errs = errs + 1; $display("FAIL status_pass");
        end else $display("AGGREGATE status_pass=1");
        if (sf !== 1'b0) begin
            errs = errs + 1; $display("FAIL status_fail");
        end

        if (errs == 0) $display("HWVERIFY TB PASS");
        else           $display("HWVERIFY TB FAIL errs=%0d", errs);
        $finish;
    end

    initial begin
        #250000000; $display("TIMEOUT"); $finish;
    end
endmodule
