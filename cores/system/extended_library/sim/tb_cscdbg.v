// tb_cscdbg -- simulate top_cscdbg, decode UART bytes, compare the 6144-byte
// CSC payload stream + "D=XXXXXXXX" trailer against the golden model file
// sim/golden_isp_csc.txt (byte-per-line hex dump from golden_isp.py).
`timescale 1ns/1ps
module tb_cscdbg;
    reg clk = 0;
    wire tx, sp;
    always #18.5 clk = ~clk;   // 27 MHz

    top_cscdbg dut (.clk(clk), .uart_tx(tx), .status_pass(sp));

    // ---- UART decode (115200 baud = 234 clk/bit) ----
    localparam integer BIT_CLKS = 234;
    reg [7:0] rx [0:8191];
    integer nrx = 0;
    integer bitcnt = 0;
    reg [9:0] shreg = 10'h3FF;
    reg rx_busy = 0;

    always @(posedge clk) begin
        if (!rx_busy && tx === 1'b0) begin
            rx_busy <= 1; bitcnt <= 0;
        end else if (rx_busy) begin
            bitcnt <= bitcnt + 1;
            if (bitcnt == BIT_CLKS/2 && bitcnt < 10*BIT_CLKS) begin end
            // sample mid-bit
            if ((bitcnt % BIT_CLKS) == BIT_CLKS/2)
                shreg <= {tx, shreg[9:1]};
            if (bitcnt == 10*BIT_CLKS - BIT_CLKS/2 + 1) begin
                rx_busy <= 0;
                rx[nrx] <= shreg[8:1];
                nrx <= nrx + 1;
            end
        end
    end

    // ---- golden comparison ----
    reg [7:0] golden [0:8191];
    integer ng = 0, errs = 0, i;
    initial begin
        $readmemh("golden_isp_csc.txt", golden);
        // count until 'D' trailer handled separately; file is 6144 payload bytes
        ng = 6144;
    end

    integer cyc = 0;
    initial begin
        while (dut.tr_done !== 1'b1 && cyc < 40000000) begin
            @(posedge clk); cyc = cyc + 1;
        end
        // let the last bytes drain
        repeat (30000) @(posedge clk);
        $display("CSCDBG bytes=%0d digest_done=%b", nrx, dut.done_r);
        for (i = 0; i < ng && i < nrx; i = i + 1)
            if (rx[i] !== golden[i]) begin
                if (errs < 20)
                    $display("  mismatch byte %0d: got %02x exp %02x", i, rx[i], golden[i]);
                errs = errs + 1;
            end
        if (errs == 0 && nrx >= ng + 12)
            $display("CSCDBG PASS bytes=%0d", nrx);
        else
            $display("CSCDBG FAIL errs=%0d nrx=%0d", errs, nrx);
        $finish;
    end
endmodule
