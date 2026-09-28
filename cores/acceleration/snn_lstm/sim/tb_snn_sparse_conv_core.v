`timescale 1ns / 1ps
// Self-checking testbench for the SNN sparse convolution core.
// Runs the on-board path end to end: deterministic event loader -> core ->
// output spike stream, and compares against model/golden_all.py expectations.
module tb_snn_sparse_conv_core;

    localparam IMG_W = 8, IMG_H = 8, CIN = 2, COUT = 4, KERN = 3, PAD = 1;
    localparam ACC_W = 16, LEAK = 3, VTH = 96, N_STEPS = 8, STEP_BITS = 4, EV_MASK = 7;

    `include "expected_snn.vh"

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;

    wire [CIN*KERN*KERN*COUT*8-1:0] wrom;
    snn_param_rom u_rom (.wrom(wrom));

    reg  start_ld, start_core;
    wire ld_en, ld_done, ld_busy;
    wire [7:0]           ld_addr;
    wire [STEP_BITS+15:0] ld_data;
    wire [8:0]           ld_count;

    snn_event_loader #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .CIN(CIN), .N_STEPS(N_STEPS),
        .STEP_BITS(STEP_BITS), .EV_MASK(EV_MASK), .IDX_MASK(CIN*IMG_W*IMG_H-1),
        .SEED(16'hACE1)
    ) u_gen (
        .clk(clk), .rst_n(rst_n), .start(start_ld),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .ld_count(ld_count), .load_done(ld_done), .busy(ld_busy)
    );

    wire oevt_valid;
    reg  oevt_ready;
    wire [7:0] oevt_idx;
    wire [STEP_BITS-1:0] oevt_step;
    wire done, error, busy;
    wire [7:0] err_code;
    wire [31:0] digest;
    wire [15:0] stat_events, stat_taps, stat_taps_skip, stat_spikes, stat_scan_cells,
                stat_ofifo_ovf, stat_dense_macs;
    wire [23:0] stat_cycles;
    wire [STEP_BITS-1:0] stat_step;

    snn_sparse_conv_core #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .CIN(CIN), .COUT(COUT), .KERN(KERN),
        .PAD(PAD), .ACC_W(ACC_W), .LEAK(LEAK), .VTH(VTH), .N_STEPS(N_STEPS),
        .STEP_BITS(STEP_BITS), .EVT_DEPTH(64), .OFIFO_DEPTH(32)
    ) u_core (
        .clk(clk), .rst_n(rst_n), .start(start_core), .wrom(wrom),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data), .ld_count(ld_count),
        .oevt_valid(oevt_valid), .oevt_ready(oevt_ready),
        .oevt_idx(oevt_idx), .oevt_step(oevt_step),
        .done(done), .error(error), .err_code(err_code), .busy(busy),
        .digest(digest), .stat_events(stat_events), .stat_taps(stat_taps),
        .stat_taps_skip(stat_taps_skip), .stat_spikes(stat_spikes),
        .stat_scan_cells(stat_scan_cells), .stat_ofifo_ovf(stat_ofifo_ovf),
        .stat_cycles(stat_cycles), .stat_step(stat_step),
        .stat_dense_macs(stat_dense_macs)
    );

    integer seen_spikes = 0;
    integer fails = 0;
    reg [31:0] spike_step_hash = 32'd0;

    always @(posedge clk) if (rst_n && oevt_valid && oevt_ready) begin
        seen_spikes    = seen_spikes + 1;
        spike_step_hash = spike_step_hash ^ {oevt_step, oevt_idx, 16'h0001};
        $display("SPIKE t=%0d neuron=%0d", oevt_step, oevt_idx);
    end

    initial begin
        start_ld = 1'b0; start_core = 1'b0; oevt_ready = 1'b1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk); start_ld = 1'b1;
        @(posedge clk); start_ld = 1'b0;

        fork : load_watch
            begin
                integer guard; guard = 0;
                while (!ld_done && guard < 2000) begin @(posedge clk); guard = guard + 1; end
                if (!ld_done) begin
                    $display("FAIL loader did not finish");
                    fails = fails + 1;
                end
            end
        join
        $display("LOADER events=%0d", ld_count);

        @(posedge clk); start_core = 1'b1;
        @(posedge clk); start_core = 1'b0;

        fork : run_watch
            begin
                integer guard2; guard2 = 0;
                while (!done && guard2 < 100000) begin @(posedge clk); guard2 = guard2 + 1; end
                if (!done) begin
                    $display("FAIL core did not finish (timeout)");
                    fails = fails + 1;
                end
            end
        join

        if (error) begin
            $display("FAIL error asserted, code=%h", err_code);
            fails = fails + 1;
        end
        if (digest !== EXP_SNN_DIGEST[31:0]) begin
            $display("FAIL digest got %h want %h", digest, EXP_SNN_DIGEST[31:0]);
            fails = fails + 1;
        end
        if (stat_events   !== EXP_SNN_EVENTS[15:0])    begin $display("FAIL events %0d want %0d", stat_events, EXP_SNN_EVENTS); fails = fails + 1; end
        if (stat_taps     !== EXP_SNN_TAPS[15:0])      begin $display("FAIL taps %0d want %0d", stat_taps, EXP_SNN_TAPS); fails = fails + 1; end
        if (stat_taps_skip!== EXP_SNN_TAPS_SKIP[15:0]) begin $display("FAIL taps_skip %0d want %0d", stat_taps_skip, EXP_SNN_TAPS_SKIP); fails = fails + 1; end
        if (stat_spikes   !== EXP_SNN_SPIKES[15:0])    begin $display("FAIL spikes %0d want %0d", stat_spikes, EXP_SNN_SPIKES); fails = fails + 1; end
        if (stat_scan_cells!== EXP_SNN_SCAN[15:0])     begin $display("FAIL scan_cells %0d want %0d", stat_scan_cells, EXP_SNN_SCAN); fails = fails + 1; end
        if (seen_spikes   !== stat_spikes)             begin $display("FAIL spike stream %0d != counter %0d", seen_spikes, stat_spikes); fails = fails + 1; end
        if (stat_ofifo_ovf !== 16'd0)                  begin $display("FAIL output fifo overflow %0d", stat_ofifo_ovf); fails = fails + 1; end

        $display("SNN RESULT digest=%h events=%0d taps=%0d taps_skip=%0d spikes=%0d cycles=%0d dense_macs=%0d",
                 digest, stat_events, stat_taps, stat_taps_skip, stat_spikes,
                 stat_cycles, stat_dense_macs);
        if (stat_taps * 4 >= stat_dense_macs) begin
            $display("WARN sparse path not cheaper than dense");
        end
        if (fails == 0) $display("SNN TB PASS D=%h S=%0d", digest, stat_spikes);
        else            $display("SNN TB FAIL n=%0d", fails);
        $finish;
    end

    initial begin
        #4000000;
        $display("SNN TB FAIL global timeout");
        $finish;
    end
endmodule
