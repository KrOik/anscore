// ============================================================================
// tb_cnn_engine.v - iverilog testbench for cnn_engine (cores/acceleration/cnn_inference)
// Run from repo root:
//   iverilog -g2012 -o cores/acceleration/cnn_inference/sim/tb_cnn_engine.vvp \
//       cores/acceleration/cnn_inference/sim/tb_cnn_engine.v \
//       cores/acceleration/cnn_inference/src/cnn_engine.v
//   vvp cores/acceleration/cnn_inference/sim/tb_cnn_engine.vvp
//
// Loads img.mem through the in_we port, runs the engine, reads back
// fmap_a / fmap_b / scores through the rd port and compares against
// exp_*.mem golden vectors. Checks digest == f0981d37.
// ============================================================================
`timescale 1ns/1ps

module tb_cnn_engine;

    reg         clk, rst_n, start, in_we;
    reg  [9:0]  in_waddr;
    reg  [7:0]  in_wdata;
    reg  [2:0]  rd_sel;
    reg  [14:0] rd_addr;
    wire        busy, done, err;
    wire [31:0] rd_data, digest, cycles;

    cnn_engine dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .busy     (busy),
        .done     (done),
        .err      (err),
        .in_we    (in_we),
        .in_waddr (in_waddr),
        .in_wdata (in_wdata),
        .rd_sel   (rd_sel),
        .rd_addr  (rd_addr),
        .rd_data  (rd_data),
        .digest   (digest),
        .cycles   (cycles)
    );

    // 50 MHz
    initial clk = 1'b0;
    always #10 clk = ~clk;

    reg [7:0]  img    [0:783];
    reg [7:0]  exp_fa [0:3135];
    reg [7:0]  exp_fb [0:783];
    reg [31:0] exp_sc [0:9];

    integer i, mism, tmo;
    reg [31:0] rdv;

    // present sel/addr for one cycle, capture registered rd_data next cycle
    task rd32;
        input  [1:0]  sel;
        input  [11:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            rd_sel  = sel;
            rd_addr = addr;
            @(negedge clk);
            data = rd_data;
        end
    endtask

    initial begin
        $readmemh("cores/acceleration/cnn_inference/mem/img.mem",        img);
        $readmemh("cores/acceleration/cnn_inference/mem/exp_fmap_a.mem", exp_fa);
        $readmemh("cores/acceleration/cnn_inference/mem/exp_fmap_b.mem", exp_fb);
        $readmemh("cores/acceleration/cnn_inference/mem/exp_scores.mem", exp_sc);

        rst_n    = 1'b0;
        start    = 1'b0;
        in_we    = 1'b0;
        in_waddr = 10'd0;
        in_wdata = 8'd0;
        rd_sel   = 3'd0;
        rd_addr  = 15'd0;

        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // host image upload over the in_we port
        for (i = 0; i < 784; i = i + 1) begin
            @(negedge clk);
            in_we    = 1'b1;
            in_waddr = i;
            in_wdata = img[i];
        end
        @(negedge clk);
        in_we = 1'b0;

        // pulse start
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // wait for done with timeout guard
        tmo = 0;
        while (!done && tmo < 200000) begin
            @(posedge clk);
            tmo = tmo + 1;
        end
        if (!done) begin
            $display("CNNENG FAIL timeout after %0d cycles, state stuck", tmo);
            $finish;
        end
        $display("engine done: cycles=%0d digest=%08x err=%b", cycles, digest, err);

        // read-back compare: fmap_a (3136 bytes), fmap_b (784), scores (10)
        mism = 0;
        for (i = 0; i < 3136; i = i + 1) begin
            rd32(2'd1, i, rdv);
            if (rdv[7:0] !== exp_fa[i]) begin
                mism = mism + 1;
                if (mism <= 20)
                    $display("  fmap_a[%0d] got %02x exp %02x",
                             i, rdv[7:0], exp_fa[i]);
            end
        end
        for (i = 0; i < 784; i = i + 1) begin
            rd32(2'd2, i, rdv);
            if (rdv[7:0] !== exp_fb[i]) begin
                mism = mism + 1;
                if (mism <= 20)
                    $display("  fmap_b[%0d] got %02x exp %02x",
                             i, rdv[7:0], exp_fb[i]);
            end
        end
        for (i = 0; i < 10; i = i + 1) begin
            rd32(2'd0, i, rdv);
            if (rdv !== exp_sc[i]) begin
                mism = mism + 1;
                $display("  score[%0d] got %08x exp %08x", i, rdv, exp_sc[i]);
            end
        end

        if (digest !== 32'hf0981d37) begin
            mism = mism + 1;
            $display("  digest got %08x exp f0981d37", digest);
        end
        if (err !== 1'b0) begin
            mism = mism + 1;
            $display("  err flag set");
        end

        if (mism == 0)
            $display("CNNENG PASS D=%08x C=%0d", digest, cycles);
        else
            $display("CNNENG FAIL mism=%0d D=%08x C=%0d", mism, digest, cycles);
        $finish;
    end

endmodule
