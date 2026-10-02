`timescale 1ns/1ps
// Delivery-bundle composition test for agc_power_stream.
//
// The three leaves (two DSP-07 AGC lanes and DSP-05 mag_squared) are each
// board-verified against their own models, so this bench does not re-derive AGC
// arithmetic.  It proves the *composition*: the {Q,I} bit slices go to the right
// lanes, both lanes are fed every accepted beat and no beat, the shared
// backpressure does not drop, duplicate or reorder results, the single
// configuration word reaches all three stages, and the magnitude stage's shift is
// the bundle's.  The reference is the same three leaves instantiated as an
// independent chain with m_tready tied high and fed by the DUT's own accept
// pulses, so the two paths differ in handshake structure but must agree in value
// order.
module tb_agc_power;

localparam integer N = 64;          // stereo samples per frame
localparam integer FRAMES = 4;

reg clk = 0;
always #5 clk = ~clk;

reg rst_n = 0;
reg [31:0] s_tdata;
reg s_tvalid, s_tuser, s_tlast;
reg m_tready, cfg_valid;
reg [27:0] cfg_word;
wire s_tready;
wire [31:0] m_tdata;
wire m_tvalid, m_tuser, cfg_ready, cfg_done, cfg_error;

agc_power_stream dut (
    .clk(clk), .rst_n(rst_n), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
    .s_tuser(s_tuser), .s_tlast(s_tlast), .s_tready(s_tready),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tuser(m_tuser),
    .m_tready(m_tready), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
    .cfg_word(cfg_word), .cfg_done(cfg_done), .cfg_error(cfg_error));

// ---------------------------------------------------------------------------
// independent reference chain: same beats, no backpressure
// ---------------------------------------------------------------------------
wire accept = s_tvalid && s_tready;
wire signed [15:0] ref_i_data, ref_q_data;
wire ref_i_vld, ref_q_vld;
wire ref_i_ready, ref_q_ready;
wire ref_mag_vld;
wire [31:0] ref_mag_data;
wire ref_mag_user;

agc_stream ref_i (
    .clk(clk), .rst_n(rst_n), .s_tdata(s_tdata[15:0]), .s_tvalid(accept),
    .s_tuser(s_tuser), .s_tlast(s_tlast), .s_tready(ref_i_ready),
    .m_tdata(ref_i_data), .m_tuser(), .m_tlast(), .m_tvalid(ref_i_vld),
    .m_tready(1'b1), .cfg_valid(cfg_valid), .cfg_ready(),
    .cfg_target(cfg_word[6:0]), .cfg_gmin(-9'sd96), .cfg_gmax(9'sd32),
    .cfg_attack(cfg_word[10:7]), .cfg_release(cfg_word[14:11]),
    .cfg_est(cfg_word[18:15]), .cfg_mode(cfg_word[19]), .cfg_mute(cfg_word[20]),
    .cfg_bypass(cfg_word[21]), .cfg_clear(cfg_word[22]),
    .cfg_done(), .cfg_error(), .clip_sticky(), .env_code(), .gain_code());

agc_stream ref_q (
    .clk(clk), .rst_n(rst_n), .s_tdata(s_tdata[31:16]), .s_tvalid(accept),
    .s_tuser(s_tuser), .s_tlast(s_tlast), .s_tready(ref_q_ready),
    .m_tdata(ref_q_data), .m_tuser(), .m_tlast(), .m_tvalid(ref_q_vld),
    .m_tready(1'b1), .cfg_valid(cfg_valid), .cfg_ready(),
    .cfg_target(cfg_word[6:0]), .cfg_gmin(-9'sd96), .cfg_gmax(9'sd32),
    .cfg_attack(cfg_word[10:7]), .cfg_release(cfg_word[14:11]),
    .cfg_est(cfg_word[18:15]), .cfg_mode(cfg_word[19]), .cfg_mute(cfg_word[20]),
    .cfg_bypass(cfg_word[21]), .cfg_clear(cfg_word[22]),
    .cfg_done(), .cfg_error(), .clip_sticky(), .env_code(), .gain_code());

mag_squared ref_mag (
    .clk(clk), .rst_n(rst_n), .s_tdata({ref_q_data, ref_i_data}),
    .s_tvalid(ref_i_vld), .s_tready(), .m_tdata(ref_mag_data),
    .m_tuser(ref_mag_user), .m_tvalid(ref_mag_vld), .m_tready(1'b1),
    .cfg_valid(cfg_valid), .cfg_ready(), .cfg_shift(cfg_word[27:23]),
    .cfg_done(), .cfg_error());

// lane valids coincide because both lanes see identical accept pulses and an
// always-ready pipeline; a divergence would be a composition bug, so check it.
reg lane_skew;

reg [31:0] dut_val [0:FRAMES*N-1];
reg [31:0] ref_val [0:FRAMES*N-1];
integer dut_n, ref_n, sent, frame, mism, waits, rng, rng_r, err_pulses;
reg [31:0] i_sig, q_sig;

task drive_sample;
    input [31:0] w;
    input u, l;
    begin
        s_tdata = w; s_tuser = u; s_tlast = l; s_tvalid = 1;
        @(negedge clk);
        waits = waits + 1;
        while (!s_tready && waits < 2000) begin
            @(negedge clk);
            waits = waits + 1;
        end
        if (!s_tready) begin
            $display("AGCPOWER FAIL: input stalled for 2000 cycles at frame %0d sample %0d",
                     frame, sent);
            $finish;
        end
        s_tvalid = 0;
        s_tuser = 0; s_tlast = 0;
        if (rng & 1) @(negedge clk);          // occasional inter-sample gap
    end
endtask

initial begin
    dut_n = 0; ref_n = 0; sent = 0; frame = 0; mism = 0; waits = 0;
    err_pulses = 0; rng_r = 32'h1BA3E7C1;
    rng = 32'h5EED1234;
    s_tdata = 0; s_tvalid = 0; s_tuser = 0; s_tlast = 0;
    m_tready = 1; cfg_valid = 0; lane_skew = 0;
    // target 100, attack 3, release 10, est 6, log mode, live, shift 2
    cfg_word = {5'd2, 1'd0, 1'd0, 1'd0, 1'd0, 4'd6, 4'd10, 4'd3, 7'd100};
    if ({cfg_word[27:23], cfg_word[22], cfg_word[21], cfg_word[20], cfg_word[19],
         cfg_word[18:15], cfg_word[14:11], cfg_word[10:7], cfg_word[6:0]}
        !== {5'd2, 1'd0, 1'd0, 1'd0, 1'd0, 4'd6, 4'd10, 4'd3, 7'd100}) begin
        $display("AGCPOWER FAIL: testbench config word is misaligned");
        $finish;
    end
    repeat (6) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    for (frame = 0; frame < FRAMES; frame = frame + 1) begin
        if (frame == 1) cfg_word[21] = 1;              // bypass both lanes
        if (frame == 2) begin
            cfg_word[21] = 0;
            cfg_word[27:23] = 5'd10;                  // heavier power shift
        end
        if (frame == 3) begin
            cfg_word[27:23] = 5'd0;
            cfg_word[20] = 0; cfg_word[22] = 1;       // clear the AGC state
        end
        cfg_valid = 1;
        @(negedge clk);
        waits = 0;
        while (!cfg_ready && waits < 200) begin
            @(negedge clk);
            waits = waits + 1;
        end
        if (!cfg_ready) begin
            $display("AGCPOWER FAIL: config never became ready (frame %0d)", frame);
            $finish;
        end
        cfg_valid = 0;
        @(negedge clk);

        for (sent = 0; sent < N; sent = sent + 1) begin
            rng = rng * 32'd1103515245 + 32'd12345;
            i_sig = {16'd0, rng[15:0]};
            rng = rng * 32'd1103515245 + 32'd12345;
            q_sig = {16'd0, rng[15:0]};
            // sweep both channels through the rails so clip paths are exercised
            if (sent % 16 == 0) begin
                i_sig = 32'shFFFF8000;                    // I = -32768
                q_sig = 32'sh00007FFF;                    // Q = +32767
            end
            drive_sample({q_sig[15:0], i_sig[15:0]}, sent == 0, sent == N-1);
        end

        // drain, then compare this frame's value sequences
        waits = 0;
        while ((dut_n < (frame+1)*N || ref_n < (frame+1)*N) && waits < 4000) begin
            @(negedge clk);
            waits = waits + 1;
        end
        if (dut_n != (frame+1)*N || ref_n != (frame+1)*N) begin
            $display("AGCPOWER FAIL: frame %0d produced dut=%0d ref=%0d want %0d",
                     frame, dut_n, ref_n, (frame+1)*N);
            $finish;
        end
        for (sent = frame*N; sent < (frame+1)*N; sent = sent + 1) begin
            if (dut_val[sent] !== ref_val[sent]) begin
                if (mism < 10)
                    $display("AGCPOWER MISMATCH frame %0d beat %0d dut=%08x ref=%08x",
                             frame, sent - frame*N, dut_val[sent], ref_val[sent]);
                mism = mism + 1;
            end
        end
    end

    if (lane_skew)
        $display("AGCPOWER FAIL: reference lanes drifted apart (composition invalid)");
    else if (err_pulses != 0)
        $display("AGCPOWER FAIL: %0d cfg_error pulses on legal configs, so a cfg field is mis-routed",
                 err_pulses);
    else if (mism != 0)
        $display("AGCPOWER FAIL: %0d of %0d bundle outputs differ from the leaf chain",
                 mism, FRAMES*N);
    else
        $display("AGCPOWER RESULT: PASS %0d beats match the independent leaf chain (%0d frames)",
                 dut_n, FRAMES);
    $finish;
end

// capture both output streams in value order (posedge: this only reads the DUT)
always @(posedge clk) begin
    if (rst_n) begin
        if (m_tready) begin
            if (m_tvalid) begin
                if (dut_n < FRAMES*N) dut_val[dut_n] = m_tdata;
                dut_n = dut_n + 1;
                if (m_tuser !== 1'b0)
                    $display("AGCPOWER NOTE: dut saturation flag set at beat %0d", dut_n);
            end
        end
        if (ref_mag_vld) begin
            if (ref_n < FRAMES*N) ref_val[ref_n] = ref_mag_data;
            ref_n = ref_n + 1;
        end
        if (ref_i_vld !== ref_q_vld) lane_skew = 1;
        // every config used here is legal, so a flagged error means a stage was
        // fed a field it considers out of range -- i.e. mis-routed cfg bits
        if (cfg_error) err_pulses = err_pulses + 1;
    end
end

// random backpressure, driven off the clock edge so the DUT sees a stable value
always @(negedge clk) begin
    if (rst_n) begin
        rng_r = rng_r * 32'd1103515245 + 32'd12345;
        m_tready = (rng_r[7:5] != 3'd0);
    end
end

endmodule
