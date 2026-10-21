`timescale 1ns/1ps
// Delivery-bundle composition test for morph_median_stream.
//
// Both leaves are board-verified on their own (isp CORE=3 morphology, isp
// CORE=0 median), so this bench does not re-derive order-statistic arithmetic.
// It proves the *composition*: morphology's eight-pixel rows reach the median
// stage with the frame/row delimiters the stage expects, the single
// configuration word reaches only the structuring-element stage, downstream
// backpressure drops/duplicates/reorders nothing, and the bundle's sideband
// flags match the leaf chain's.
//
// The reference is the same two leaves as an independent chain, connected to
// each other with a real valid/ready handshake (a window stage is not
// initiation-interval 1, so tying its ready high would silently drop beats).
// Both the DUT and the reference are fed the *same beat sequence* through
// separate stimulus paths, because neither side may be held up by the other.
module tb_morph_median;

localparam integer BITS = 8;
localparam integer N = 64;              // one 8x8 frame
localparam integer FRAMES = 4;
localparam integer TOTAL = FRAMES * N;

reg clk = 0;
always #5 clk = ~clk;

reg rst_n = 0;
reg run;

// --- DUT stimulus path -----------------------------------------------------
reg [BITS-1:0] s_tdata;
reg s_tvalid, s_tuser, s_tlast;
reg m_tready, cfg_valid;
wire s_tready;

// --- reference stimulus path ----------------------------------------------
reg [BITS-1:0] r_s_tdata;
reg r_s_tvalid, r_s_tuser, r_s_tlast;
wire r_s_tready;

// --- shared configuration --------------------------------------------------
reg [1:0] cfg_op;
reg cfg_binary;
reg [8:0] cfg_mask;
wire cfg_ready, cfg_done, cfg_error, busy, marker_error;
wire [BITS-1:0] m_tdata;
wire m_tvalid, m_tuser, m_tlast;

morph_median_stream #(.BITS(BITS), .WIDTH(8), .HEIGHT(8), .K(3), .PAD_MODE(1))
dut (
    .clk(clk), .rst_n(rst_n), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
    .s_tuser(s_tuser), .s_tlast(s_tlast), .s_tready(s_tready),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tuser(m_tuser),
    .m_tlast(m_tlast), .m_tready(m_tready), .cfg_valid(cfg_valid),
    .cfg_ready(cfg_ready), .cfg_op(cfg_op), .cfg_binary(cfg_binary),
    .cfg_mask(cfg_mask), .cfg_done(cfg_done), .cfg_error(cfg_error),
    .marker_error(marker_error), .busy(busy));

// ---------------------------------------------------------------------------
// independent reference chain: same beat sequence, handshaken leaf to leaf
// ---------------------------------------------------------------------------
wire [BITS-1:0] ref_shape_data;
wire ref_shape_vld, ref_shape_user, ref_shape_last, ref_shape_rdy;
wire ref_median_rdy;
wire [BITS-1:0] ref_out_data;
wire ref_out_vld, ref_out_user, ref_out_last;
wire ref_marker_shape, ref_marker_median;

morphology_stream #(.BITS(BITS), .WIDTH(8), .HEIGHT(8), .K(3), .PAD_MODE(1))
ref_shape (
    .clk(clk), .rst_n(rst_n), .s_tdata(r_s_tdata), .s_tvalid(r_s_tvalid),
    .s_tuser(r_s_tuser), .s_tlast(r_s_tlast), .s_tready(r_s_tready),
    .m_tdata(ref_shape_data), .m_tvalid(ref_shape_vld),
    .m_tuser(ref_shape_user), .m_tlast(ref_shape_last), .m_tready(ref_median_rdy),
    .cfg_valid(cfg_valid), .cfg_ready(), .cfg_op(cfg_op),
    .cfg_binary(cfg_binary), .cfg_mask(cfg_mask), .cfg_done(), .cfg_error(),
    .marker_error(ref_marker_shape), .busy());

median_stream #(.BITS(BITS), .WIDTH(8), .HEIGHT(8), .K(3), .PAD_MODE(1))
ref_denoise (
    .clk(clk), .rst_n(rst_n), .s_tdata(ref_shape_data),
    .s_tvalid(ref_shape_vld), .s_tuser(ref_shape_user),
    .s_tlast(ref_shape_last), .s_tready(ref_median_rdy),
    .m_tdata(ref_out_data), .m_tvalid(ref_out_vld), .m_tuser(ref_out_user),
    .m_tlast(ref_out_last), .m_tready(1'b1),
    .marker_error(ref_marker_median));

reg [BITS-1:0] stim [0:TOTAL-1];
reg [BITS-1:0] dut_val [0:TOTAL-1];
reg [BITS-1:0] ref_val [0:TOTAL-1];
reg [1:0] dut_side [0:TOTAL-1];
reg [1:0] ref_side [0:TOTAL-1];
integer ia, ib, dut_n, ref_n, frame, sent, mism, side_mism, waits, rng, rng_r;
integer gap_a, gap_b, err_dut, err_ref;
reg [BITS-1:0] pix;

// Both paths present stim[ia] / stim[ib] and hold them until their consumer
// accepts; the gap counters inject idle cycles independently on each side.
always @(negedge clk) begin
    rng = rng * 32'd1103515245 + 32'd12345;
    gap_a = (rng[5:0] == 6'd7);
    if (run && ia < TOTAL && !gap_a) begin
        s_tvalid = 1; s_tdata = stim[ia];
        s_tuser = (ia % N == 0); s_tlast = (ia % 8 == 7);
    end else begin
        s_tvalid = 0; s_tuser = 0; s_tlast = 0;
    end
    rng = rng * 32'd1103515245 + 32'd12345;
    gap_b = (rng[5:0] == 6'd9);
    if (run && ib < TOTAL && !gap_b) begin
        r_s_tvalid = 1; r_s_tdata = stim[ib];
        r_s_tuser = (ib % N == 0); r_s_tlast = (ib % 8 == 7);
    end else begin
        r_s_tvalid = 0; r_s_tuser = 0; r_s_tlast = 0;
    end
end

always @(posedge clk) begin
    if (s_tvalid && s_tready) ia = ia + 1;
    if (r_s_tvalid && r_s_tready) ib = ib + 1;
end

initial begin
    ia = 0; ib = 0; dut_n = 0; ref_n = 0; mism = 0; side_mism = 0;
    err_dut = 0; err_ref = 0; waits = 0;
    rng_r = 32'h2C0DE5E7;
    rng = 32'h5EED1234;
    run = 0; s_tvalid = 0; s_tdata = 0; s_tuser = 0; s_tlast = 0;
    r_s_tvalid = 0; r_s_tdata = 0; r_s_tuser = 0; r_s_tlast = 0;
    m_tready = 1; cfg_valid = 0;
    cfg_op = 2'd0; cfg_binary = 0; cfg_mask = 9'h1FF;   // full 3x3, grey
    for (sent = 0; sent < TOTAL; sent = sent + 1) begin
        rng = rng * 32'd1103515245 + 32'd12345;
        // grey speckle plus saturated blobs: erosion and dilation both bite, and
        // the median window sees ties and rail runs rather than an easy mean
        case (rng[17:16])
            2'd0: pix = 8'hFF;
            2'd2: pix = 8'h00;
            default: pix = rng[BITS-1:0];
        endcase
        stim[sent] = pix;
    end
    repeat (6) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    for (frame = 0; frame < FRAMES; frame = frame + 1) begin
        // sweep the structuring element: op, mask shape and binary mode
        cfg_op = frame[1:0];
        cfg_mask = (frame == 0) ? 9'h1FF :
                   (frame == 1) ? 9'h0AA :      // cross element
                   (frame == 2) ? 9'h101 :      // side columns only
                   9'h155;                      // checkerboard element
        cfg_binary = (frame == 1) || (frame == 3);
        cfg_valid = 1;
        @(negedge clk);
        waits = 0;
        while (!cfg_ready && waits < 200) begin
            @(negedge clk);
            waits = waits + 1;
        end
        if (!cfg_ready) begin
            $display("MORPHMED FAIL: config never became ready (frame %0d)", frame);
            $finish;
        end
        cfg_valid = 0;
        @(negedge clk);

        run = 1;
        waits = 0;
        while ((ia < (frame+1)*N || ib < (frame+1)*N) && waits < 20000) begin
            @(negedge clk);
            waits = waits + 1;
        end
        if (ia < (frame+1)*N || ib < (frame+1)*N) begin
            $display("MORPHMED FAIL: frame %0d inputs never drained (dut=%0d ref=%0d)",
                     frame, ia, ib);
            $finish;
        end
        run = 0;

        waits = 0;
        while ((dut_n < (frame+1)*N || ref_n < (frame+1)*N) && waits < 20000) begin
            @(negedge clk);
            waits = waits + 1;
        end
        if (dut_n != (frame+1)*N || ref_n != (frame+1)*N) begin
            $display("MORPHMED FAIL: frame %0d produced dut=%0d ref=%0d want %0d",
                     frame, dut_n, ref_n, (frame+1)*N);
            $finish;
        end
        for (sent = frame*N; sent < (frame+1)*N; sent = sent + 1) begin
            if (dut_val[sent] !== ref_val[sent]) begin
                if (mism < 10)
                    $display("MORPHMED MISMATCH frame %0d pixel %0d dut=%02x ref=%02x",
                             frame, sent - frame*N, dut_val[sent], ref_val[sent]);
                mism = mism + 1;
            end
            if (dut_side[sent] !== ref_side[sent]) begin
                if (side_mism < 6)
                    $display("MORPHMED SIDEBAND frame %0d pixel %0d dut=%b ref=%b",
                             frame, sent - frame*N, dut_side[sent], ref_side[sent]);
                side_mism = side_mism + 1;
            end
        end
    end

    if (err_dut != 0)
        $display("MORPHMED FAIL: %0d marker_error pulses from the bundle on legal frames",
                 err_dut);
    else if (err_ref != 0)
        $display("MORPHMED FAIL: reference chain itself flagged %0d marker errors",
                 err_ref);
    else if (side_mism != 0)
        $display("MORPHMED FAIL: %0d sideband flags disagree, delimiters are wrong",
                 side_mism);
    else if (mism != 0)
        $display("MORPHMED FAIL: %0d of %0d bundle outputs differ from the leaf chain",
                 mism, TOTAL);
    else
        $display("MORPHMED RESULT: PASS %0d beats match the independent leaf chain (%0d frames)",
                 dut_n, FRAMES);
    $finish;
end

// capture both output streams in value order (posedge: this only reads)
always @(posedge clk) begin
    if (rst_n) begin
        if (m_tready && m_tvalid) begin
            if (dut_n < TOTAL) begin
                dut_val[dut_n] = m_tdata;
                dut_side[dut_n] = {m_tuser, m_tlast};
            end
            dut_n = dut_n + 1;
        end
        if (ref_out_vld) begin
            if (ref_n < TOTAL) begin
                ref_val[ref_n] = ref_out_data;
                ref_side[ref_n] = {ref_out_user, ref_out_last};
            end
            ref_n = ref_n + 1;
        end
        if (marker_error) err_dut = err_dut + 1;
        if (ref_marker_shape || ref_marker_median) err_ref = err_ref + 1;
    end
end

// random backpressure on the DUT output only, driven off the clock edge
always @(negedge clk) begin
    if (rst_n) begin
        rng_r = rng_r * 32'd1103515245 + 32'd12345;
        m_tready = (rng_r[7:5] != 3'd0);
    end
end

endmodule
