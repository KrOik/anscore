// ============================================================================
// ISP-08 stage 3: defective pixel correction (DPC).
//
// Detection/replacement rule (bit-exact contract, shared with
// models/reference.py dpc_pixel_window):
//   3x3 window per channel plane via stream_window_padded (K=3, REPLICATE
//   padding, so every output pixel has a full window; edges replicate).
//   Per channel c:  nb = the 8 neighbors of the center tap, sorted
//                   med8 = (s[3] + s[4]) >> 1         (floor of mean of the
//                                                    two middle order stats)
//                   defect = |center - med8| > thr
//                   out_c  = defect ? med8 : center
//   Channels are corrected independently; a defective neighbor still
//   contributes to the median (documented semantics).  thr = MPX disables.
//
// The infra window is limited to DATA_WIDTH<=16, so packed RGB cannot ride a
// single instance: CH channel-parallel windows are fed the same control
// stream, produce identical handshakes (s_tready/wvalid are ANDed) and OR
// their sticky marker_error flags.
//
// Cluster limit (defined bound): with median-of-8, up to 3 defective
// same-direction neighbors inside the 3x3 window cannot displace the two
// middle order statistics, so isolated defects and <=3-neighbor clusters are
// corrected exactly; >=4 like-polarity defective neighbors may shift the
// median and correction is not guaranteed.  See SPEC.md.
//
// Latency: window rows are captured/replayed by stream_window_padded; its
// s_tready is bursty (CAPTURE phase) while the output stream keeps one
// window per pixel.  The correction result is registered, so each accepted
// window produces one output beat after a fixed 1-cycle delay.
// ============================================================================
module isp_dpc #(
    parameter BITS = 8,
    parameter CH   = 3,
    parameter WIDTH  = 32,
    parameter HEIGHT = 24,
    parameter MPX  = (BITS<1) ? 1 : ((1<<BITS)-1)
)(
    input  wire clk, rst_n,
    input  wire [CH*BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output reg  [CH*BITS-1:0] m_tdata,
    output reg  m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    input  wire cfg_commit,
    input  wire [BITS-1:0] cfg_thr,
    output wire marker_error
);
    reg [BITS-1:0] thr;
    wire advance = !m_tvalid || m_tready;

    // ------------- CH parallel 3x3 REPLICATE windows (infra) ---------------
    wire [CH-1:0] wrdy, wv, wu, wl, werr;
    wire [CH*9*BITS-1:0] win;
    genvar gc;
    generate for (gc = 0; gc < CH; gc = gc + 1) begin: wing
        stream_window_padded #(
            .DATA_WIDTH(BITS), .WIDTH(WIDTH), .HEIGHT(HEIGHT), .K(3),
            .PAD_MODE(1), .MAX_WIDTH(WIDTH)
        ) win_i (
            .clk(clk), .rst_n(rst_n),
            .s_tdata(s_tdata[gc*BITS +: BITS]), .s_tvalid(s_tvalid),
            .s_tuser(s_tuser), .s_tlast(s_tlast), .s_tready(wrdy[gc]),
            .m_tdata(win[gc*9*BITS +: 9*BITS]), .m_tvalid(wv[gc]),
            .m_tuser(wu[gc]), .m_tlast(wl[gc]),
            .m_tready(advance), .marker_error(werr[gc]));
    end endgenerate
    // Identical inputs/params make the channel windows strictly identical;
    // AND/OR the interface lines so any divergence would stall, not corrupt.
    assign s_tready = &wrdy;
    assign marker_error = |werr;
    wire wfire = (&wv) && advance;

    // ------------------- per-channel median-8 + replace --------------------
    wire [CH*BITS-1:0] fixed;
    generate for (gc = 0; gc < CH; gc = gc + 1) begin: chc
        // t[0..7] = the 8 neighbors of channel gc's centre tap (tap 4).
        // Tap order in the window is row-major, tap 4 = centre.
        reg [BITS-1:0] t [0:7];
        reg [BITS-1:0] ctr, med;
        always @* begin
            ctr = win[gc*9*BITS + 4*BITS +: BITS];
            t[0] = win[gc*9*BITS + 0*BITS +: BITS];
            t[1] = win[gc*9*BITS + 1*BITS +: BITS];
            t[2] = win[gc*9*BITS + 2*BITS +: BITS];
            t[3] = win[gc*9*BITS + 3*BITS +: BITS];
            t[4] = win[gc*9*BITS + 5*BITS +: BITS];
            t[5] = win[gc*9*BITS + 6*BITS +: BITS];
            t[6] = win[gc*9*BITS + 7*BITS +: BITS];
            t[7] = win[gc*9*BITS + 8*BITS +: BITS];
            // Batcher odd-even mergesort, 8 inputs, 19 comparators.
            if (t[0] > t[1]) {t[0],t[1]} = {t[1],t[0]};
            if (t[2] > t[3]) {t[2],t[3]} = {t[3],t[2]};
            if (t[4] > t[5]) {t[4],t[5]} = {t[5],t[4]};
            if (t[6] > t[7]) {t[6],t[7]} = {t[7],t[6]};
            if (t[0] > t[2]) {t[0],t[2]} = {t[2],t[0]};
            if (t[1] > t[3]) {t[1],t[3]} = {t[3],t[1]};
            if (t[4] > t[6]) {t[4],t[6]} = {t[6],t[4]};
            if (t[5] > t[7]) {t[5],t[7]} = {t[7],t[5]};
            if (t[1] > t[2]) {t[1],t[2]} = {t[2],t[1]};
            if (t[5] > t[6]) {t[5],t[6]} = {t[6],t[5]};
            if (t[0] > t[4]) {t[0],t[4]} = {t[4],t[0]};
            if (t[1] > t[5]) {t[1],t[5]} = {t[5],t[1]};
            if (t[2] > t[6]) {t[2],t[6]} = {t[6],t[2]};
            if (t[3] > t[7]) {t[3],t[7]} = {t[7],t[3]};
            if (t[2] > t[4]) {t[2],t[4]} = {t[4],t[2]};
            if (t[3] > t[5]) {t[3],t[5]} = {t[5],t[3]};
            if (t[1] > t[2]) {t[1],t[2]} = {t[2],t[1]};
            if (t[3] > t[4]) {t[3],t[4]} = {t[4],t[3]};
            if (t[5] > t[6]) {t[5],t[6]} = {t[6],t[5]};
            med = ({1'b0, t[3]} + {1'b0, t[4]}) >> 1;   // floor mean of
        end                                             // the two middle stats
        wire [BITS:0] diff = (ctr >= med) ? ({1'b0, ctr} - {1'b0, med})
                                          : ({1'b0, med} - {1'b0, ctr});
        assign fixed[gc*BITS +: BITS] = (diff > {1'b0, thr}) ? med : ctr;
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            thr <= {BITS{1'b1}};              // reset default: DPC disabled
            m_tvalid <= 0; m_tuser <= 0; m_tlast <= 0;
        end else begin
            if (cfg_commit) thr <= cfg_thr;
            if (advance) begin
                m_tvalid <= wfire;
                if (wfire) begin
                    m_tdata <= fixed;
                    m_tuser <= wu[0];
                    m_tlast <= wl[0];
                end
            end
        end
    end
    initial begin
        if ((BITS != 8 && BITS != 10) || (CH != 1 && CH != 3) ||
            WIDTH < 1 || HEIGHT < 1)
            $fatal(1, "unsupported isp_dpc parameters");
    end
endmodule
