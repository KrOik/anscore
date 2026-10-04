// ============================================================================
// ISP-08 basic ISP pipeline (basic_isp_top):
//     input -> isp_blc -> isp_wb_gain -> isp_dpc -> isp_gamma -> output
//                   \-> isp_awb_stats (observer on the post-BLC bus)
//
// Pixel word: CH*BITS bits; CH=3 packs {R,G,B} MSB->LSB (channel c in slice
// [c*BITS +: BITS], c0 = B); CH=1 is a single channel (gray).  Geometry is
// STATIC (WIDTH x HEIGHT parameters) because the DPC stage builds on the
// fixed-geometry infra stream_window_padded; the runtime cfg_img_w/img_h
// fields must match it, else cfg_error.
//
// Atomic config (cfg_valid/cfg_ready, all-or-nothing):
//   cfg_img_w, cfg_img_h   - must equal WIDTH/HEIGHT
//   cfg_blc[3*BITS]        - per-channel unsigned black offsets, LSB-first
//   cfg_wb [3*12]          - per-channel UQ4.8 gains, LSB-first
//   cfg_dpc_thr[BITS]      - defect detect threshold (MPX disables)
//   cfg_gamma_sel[1:0]     - 0 bypass, 1 encode 1/2.2, 2 decode 2.2
// cfg_ready asserts only when the pipeline is empty (busy==0); a legal commit
// pulses cfg_done and cfg_commit (broadcast to every stage in the same edge);
// illegal fields pulse cfg_error and leave every stage's config intact.
// While cfg_valid && cfg_ready, the input beat is deferred one cycle so the
// commit edge can never coincide with a pixel take.
//
// busy = fopen (input frame started, not finished) || outstanding != 0
// (accepted-but-not-emitted pixels anywhere in the pipe).  Covers mid-frame
// input gaps and the drain tail, so config can never straddle a frame.
//
// marker_error: sticky flag from the window core's SOF/EOL checking against
// the static geometry (propagated to the top-level output).
// ============================================================================
module basic_isp_top #(
    parameter BITS   = 8,
    parameter CH     = 3,              // 1 = gray, 3 = packed {R,G,B}
    parameter WIDTH  = 32,
    parameter HEIGHT = 24,
    parameter MPX    = (BITS<1) ? 1 : ((1<<BITS)-1),
    parameter FP     = (WIDTH<1 || HEIGHT<1) ? 1 : WIDTH*HEIGHT,
    parameter XW     = (WIDTH<2) ? 1 : $clog2(WIDTH),
    parameter YW     = (HEIGHT<2) ? 1 : $clog2(HEIGHT),
    parameter CWX    = (WIDTH<1) ? 1 : $clog2(WIDTH+1),
    parameter CWY    = (HEIGHT<1) ? 1 : $clog2(HEIGHT+1),
    parameter OW     = (FP<1) ? 1 : $clog2(FP+8),
    parameter SUMW   = $clog2(FP*MPX+1)    // >= BITS for legal params
)(
    input  wire clk, rst_n,
    input  wire [CH*BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output wire [CH*BITS-1:0] m_tdata,
    output wire m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    // Atomic configuration (all fields committed or rejected together).
    input  wire cfg_valid, output wire cfg_ready,
    input  wire [CWX-1:0] cfg_img_w,
    input  wire [CWY-1:0] cfg_img_h,
    input  wire [3*BITS-1:0] cfg_blc,
    input  wire [3*12-1:0] cfg_wb,
    input  wire [BITS-1:0] cfg_dpc_thr,
    input  wire [1:0] cfg_gamma_sel,
    output reg  cfg_done, cfg_error,
    // AWB statistics readout (post-BLC frame sums of the last full frame).
    output wire [SUMW-1:0] awb_sum0, awb_sum1, awb_sum2,
    output wire awb_new,
    output wire [7:0] awb_frame,
    output wire marker_error,
    output wire busy
);
    // ------------------------- inter-stage buses ---------------------------
    wire [CH*BITS-1:0] b_d, w_d, d_d;
    wire b_v, b_u, b_l, b_r;
    wire w_v, w_u, w_l, w_r;
    wire d_v, d_u, d_l, d_r;

    localparam [CWX-1:0] WCFG = WIDTH;
    localparam [CWY-1:0] HCFG = HEIGHT;
    localparam [XW-1:0]  WL   = WIDTH - 1;
    localparam [YW-1:0]  HL   = HEIGHT - 1;

    wire cfg_fire = cfg_valid && cfg_ready;
    wire cfg_bad  = (cfg_img_w != WCFG) || (cfg_img_h != HCFG) ||
                    (cfg_gamma_sel > 2'd2);
    wire cfg_commit = cfg_fire && !cfg_bad;

    // The commit edge must never take a pixel: hold the input off while a
    // pending config fires (one-cycle deferral at a frame gap).
    wire s_tvalid_i = s_tvalid && !cfg_fire;
    wire s_tready_i;
    assign s_tready = s_tready_i && !cfg_fire;
    wire take = s_tvalid && s_tready;
    wire mfire = m_tvalid && m_tready;

    isp_blc #(.BITS(BITS), .CH(CH)) u_blc (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid_i), .s_tuser(s_tuser),
        .s_tlast(s_tlast), .s_tready(s_tready_i),
        .m_tdata(b_d), .m_tvalid(b_v), .m_tuser(b_u), .m_tlast(b_l),
        .m_tready(b_r),
        .cfg_commit(cfg_commit), .cfg_blc(cfg_blc));

    isp_wb_gain #(.BITS(BITS), .CH(CH)) u_wb (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(b_d), .s_tvalid(b_v), .s_tuser(b_u), .s_tlast(b_l),
        .s_tready(b_r),
        .m_tdata(w_d), .m_tvalid(w_v), .m_tuser(w_u), .m_tlast(w_l),
        .m_tready(w_r),
        .cfg_commit(cfg_commit), .cfg_wb(cfg_wb));

    isp_dpc #(.BITS(BITS), .CH(CH), .WIDTH(WIDTH), .HEIGHT(HEIGHT)) u_dpc (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(w_d), .s_tvalid(w_v), .s_tuser(w_u), .s_tlast(w_l),
        .s_tready(w_r),
        .m_tdata(d_d), .m_tvalid(d_v), .m_tuser(d_u), .m_tlast(d_l),
        .m_tready(d_r),
        .cfg_commit(cfg_commit), .cfg_thr(cfg_dpc_thr),
        .marker_error(marker_error));

    isp_gamma #(.BITS(BITS), .CH(CH)) u_gamma (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(d_d), .s_tvalid(d_v), .s_tuser(d_u), .s_tlast(d_l),
        .s_tready(d_r),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tuser(m_tuser),
        .m_tlast(m_tlast), .m_tready(m_tready),
        .cfg_commit(cfg_commit), .cfg_sel(cfg_gamma_sel));

    // AWB statistics tap: post-BLC / pre-WB transfers.
    isp_awb_stats #(.BITS(BITS), .CH(CH), .WIDTH(WIDTH), .HEIGHT(HEIGHT))
    u_awb (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(b_d), .s_tvalid(b_v && b_r), .s_tready(1'b1),
        .awb_sum0(awb_sum0), .awb_sum1(awb_sum1), .awb_sum2(awb_sum2),
        .awb_new(awb_new), .awb_frame(awb_frame));

    // ------------------------- busy / cfg handshake ------------------------
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg fopen;
    reg [OW-1:0] outstanding;
    wire pix_last = (x == WL) && (y == HL);
    assign busy = fopen || (outstanding != {OW{1'b0}});
    assign cfg_ready = rst_n && !busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            x <= 0; y <= 0; fopen <= 0; outstanding <= 0;
            cfg_done <= 0; cfg_error <= 0;
        end else begin
            cfg_done <= 0; cfg_error <= 0;
            if (cfg_fire) begin
                if (cfg_bad) cfg_error <= 1;
                else         cfg_done  <= 1;
            end
            if (take) begin
                if (x == WL) begin
                    x <= 0;
                    y <= (y == HL) ? {YW{1'b0}} : y + 1'b1;
                end else x <= x + 1'b1;
                if (x == {XW{1'b0}} && y == {YW{1'b0}}) fopen <= 1;
                if (pix_last) fopen <= 0;
            end
            case ({take, mfire})
                2'b10: outstanding <= outstanding + 1'b1;
                2'b01: outstanding <= outstanding - 1'b1;
                default: outstanding <= outstanding;
            endcase
        end
    end
    initial begin
        if ((BITS != 8 && BITS != 10) || (CH != 1 && CH != 3) ||
            WIDTH < 1 || HEIGHT < 1)
            $fatal(1, "unsupported basic_isp_top parameters");
    end
endmodule
