`timescale 1ns/1ps
// ============================================================================
// ISP-15 chroma resampler stage 2: 4:4:4 or 4:2:2 -> 4:2:0.
//
// Two pieces:
//   chroma420_v : vertical decimation stage.  Consumes 4:2:2 pair beats
//                 {Y_even, Cb, Y_odd, Cr} (chroma_422 output format), one
//                 per chroma column pair, and emits tagged interleaved
//                 4:2:0 beats on m_tdata = {tag, A, B}:
//                   tag 0 -> luma pair {Y_even, Y_odd}
//                   tag 1 -> chroma    {Cb, Cr}
//                 Vertical anti-alias filter is [1,2,1]/4 co-sited with the
//                 even line of each two-line group; frame edges replicate.
//                 One synchronous-RAM chroma line buffer of NCOLS entries,
//                 each entry {A,B} = two 2*BITS chroma words (previous odd
//                 line / current even line of a group).
//   chroma_420  : wrapper.  SRC422==0 prepends chroma_422 (horizontal
//                 decimation, runtime siting config).  SRC422==1 feeds the
//                 pair stream straight into chroma420_v.
//
// Output beat order per input line y (NCOLS = ceil(W/2) pair beats in):
//   even line (not last of odd H): {0,Ye,Yo} x NCOLS
//   odd line or last line of odd-H frame: ({0,Ye,Yo},{1,Cb,Cr}) x NCOLS
// tuser on the very first beat of a frame; tlast on the last beat of each
// line group.  Odd WIDTH pairs carry a replicated last luma (from stage 1
// or the upstream 422 source).  Odd HEIGHT: the last even line also emits
// chroma computed with the missing odd line replicated.
//
// Rate contract: one input pair beat needs one (even line) or two (emit-
// chroma line) output beats; the stage holds each accepted beat until its
// beats are emitted, so the upstream/input pair rate is 1 beat / 2 cycles
// on even lines and 1 beat / 3 cycles on emit-chroma lines.
// ============================================================================
module chroma420_v #(
    parameter BITS   = 8,
    parameter NCOLS  = 16,       // pair beats per line = ceil(WIDTH/2)
    parameter HEIGHT = 24
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire [4*BITS-1:0]  s_tdata,
    input  wire               s_tvalid,
    input  wire               s_tuser,
    input  wire               s_tlast,
    output wire               s_tready,
    output reg  [2*BITS:0]    m_tdata,
    output reg                m_tvalid,
    output reg                m_tuser,
    output reg                m_tlast,
    input  wire               m_tready,
    output reg                marker_error,
    output wire               busy
);
    localparam CW = (NCOLS  > 1) ? $clog2(NCOLS)  : 1;
    localparam YW = (HEIGHT > 1) ? $clog2(HEIGHT) : 1;
    localparam IDLE = 2'd0, HAVE = 2'd1, EMITC = 2'd2;

    reg [1:0]        state;
    reg [4*BITS-1:0] hold;          // accepted pair beat {Ye,Cb,Yo,Cr}
    reg [CW-1:0]     c;             // column-pair counter (marker check)
    reg [YW-1:0]     yy;            // line counter
    reg [CW-1:0]     hc;            // held beat's column
    reg [YW-1:0]     hy;            // held beat's line
    reg              in_frame;
    // {A,B} chroma line buffer: A = previous odd line, B = this group even line
    reg [4*BITS-1:0] cmem [0:((NCOLS > 0) ? NCOLS : 1)-1];
    reg [4*BITS-1:0] rd;

    wire out_free = ~m_tvalid | m_tready;
    assign s_tready = rst_n & (state == IDLE);
    wire take = s_tvalid & s_tready;

    wire [BITS-1:0] h_ye = hold[4*BITS-1 -: BITS];
    wire [BITS-1:0] h_cb = hold[3*BITS-1 -: BITS];
    wire [BITS-1:0] h_yo = hold[2*BITS-1 -: BITS];
    wire [BITS-1:0] h_cr = hold[BITS-1:0];
    wire [BITS-1:0] rdAcb = rd[4*BITS-1 -: BITS];
    wire [BITS-1:0] rdAcr = rd[3*BITS-1 -: BITS];
    wire [BITS-1:0] rdBcb = rd[2*BITS-1 -: BITS];
    wire [BITS-1:0] rdBcr = rd[BITS-1:0];

    wire odd_line  = hy[0];
    wire last_line = (hy == HEIGHT - 1);
    wire emit_c    = odd_line | last_line;   // odd lines + odd-H last line
    // vertical [1,2,1]/4: v = (A + 2B + C + 2) >> 2
    //   odd line         : A = stored previous-odd chroma, B = stored even
    //                      chroma, C = this line's chroma
    //   last even line   : replicate the missing odd line -> B = C = cur;
    //   line 0           : A replicates to cur (line -1 == line 0)
    wire [BITS-1:0] tA_cb = (odd_line || hy != 0) ? rdAcb : h_cb;
    wire [BITS-1:0] tA_cr = (odd_line || hy != 0) ? rdAcr : h_cr;
    wire [BITS-1:0] tB_cb = odd_line ? rdBcb : h_cb;
    wire [BITS-1:0] tB_cr = odd_line ? rdBcr : h_cr;
    wire [BITS+2:0] vcb = tA_cb + (tB_cb << 1) + h_cb + 2;
    wire [BITS+2:0] vcr = tA_cr + (tB_cr << 1) + h_cr + 2;

    // buffer write-back for the current column (idempotent while in HAVE)
    wire [2*BITS-1:0] wrA = (hy == 0 && !odd_line) ? {h_cb, h_cr}
                                                 : {rdAcb, rdAcr};
    wire [4*BITS-1:0] wdat = odd_line ? {h_cb, h_cr, h_cb, h_cr}
                                      : {wrA, h_cb, h_cr};

    wire luma_u = (hc == 0) & (hy == 0);
    wire luma_l = (hc == NCOLS - 1) & ~emit_c;
    wire chrm_l = (hc == NCOLS - 1);

    assign busy = (state != IDLE) | m_tvalid | in_frame;

    // synchronous-read chroma line buffer (one chroma line, SDP pattern)
    always @(posedge clk) begin
        if (take)          rd      <= cmem[c];
        if (state == HAVE) cmem[hc] <= wdat;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= IDLE;
            hold         <= {4*BITS{1'b0}};
            c            <= {CW{1'b0}};
            yy           <= {YW{1'b0}};
            hc           <= {CW{1'b0}};
            hy           <= {YW{1'b0}};
            in_frame     <= 1'b0;
            m_tdata      <= {2*BITS+1{1'b0}};
            m_tvalid     <= 1'b0;
            m_tuser      <= 1'b0;
            m_tlast      <= 1'b0;
            marker_error <= 1'b0;
        end else begin
            if (m_tready) m_tvalid <= 1'b0;

            if (take) begin
                if (s_tuser != (c == 0 && yy == 0 && !in_frame))
                    marker_error <= 1'b1;
                if (s_tlast != (c == NCOLS - 1))
                    marker_error <= 1'b1;
                hold <= s_tdata;
                hc   <= c;
                hy   <= yy;
                if (s_tuser) in_frame <= 1'b1;
                if (c == NCOLS - 1) begin
                    c <= {CW{1'b0}};
                    if (yy == HEIGHT - 1) begin
                        yy       <= {YW{1'b0}};
                        in_frame <= 1'b0;
                    end else yy <= yy + 1'b1;
                end else c <= c + 1'b1;
                state <= HAVE;
            end else if (state == HAVE) begin
                if (out_free) begin
                    m_tdata  <= {1'b0, h_ye, h_yo};
                    m_tuser  <= luma_u;
                    m_tlast  <= luma_l;
                    m_tvalid <= 1'b1;
                    state    <= emit_c ? EMITC : IDLE;
                end
            end else if (state == EMITC) begin
                if (out_free) begin
                    m_tdata  <= {1'b1, vcb[BITS+1:2], vcr[BITS+1:2]};
                    m_tuser  <= 1'b0;
                    m_tlast  <= chrm_l;
                    m_tvalid <= 1'b1;
                    state    <= IDLE;
                end
            end
        end
    end

    initial begin
        if ((BITS != 8 && BITS != 10) || NCOLS < 1 || HEIGHT < 1)
            $fatal(1, "unsupported chroma420_v parameters");
    end
endmodule

// ----------------------------------------------------------------------------
module chroma_420 #(
    parameter BITS   = 8,
    parameter WIDTH  = 32,
    parameter HEIGHT = 24,
    parameter SRC422 = 0        // 0: 4:4:4 pixel input, 1: 4:2:2 pair-word input
)(
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire [((SRC422 == 1) ? 4*BITS : 3*BITS)-1:0] s_tdata,
    input  wire                                  s_tvalid,
    input  wire                                  s_tuser,
    input  wire                                  s_tlast,
    output wire                                  s_tready,
    output wire [2*BITS:0]                       m_tdata,
    output wire                                  m_tvalid,
    output wire                                  m_tuser,
    output wire                                  m_tlast,
    input  wire                                  m_tready,
    input  wire                                  cfg_valid,
    output wire                                  cfg_ready,
    input  wire [1:0]                            cfg_siting,
    output wire                                  cfg_done,
    output wire                                  cfg_error,
    output wire                                  marker_error,
    output wire                                  busy
);
    localparam OW = (WIDTH + 1) >> 1;

    wire [4*BITS-1:0] i_tdata;
    wire i_tvalid, i_tuser, i_tlast, i_tready;
    wire merr_v, busy_v;
    wire merr_h, busy_h, cr_h, cd_h, ce_h;

    generate
        if (SRC422 == 0) begin: hstage
            chroma_422 #(.BITS(BITS), .WIDTH(WIDTH), .HEIGHT(HEIGHT)) h (
                .clk(clk), .rst_n(rst_n),
                .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tuser(s_tuser),
                .s_tlast(s_tlast), .s_tready(s_tready),
                .m_tdata(i_tdata), .m_tvalid(i_tvalid), .m_tuser(i_tuser),
                .m_tlast(i_tlast), .m_tready(i_tready),
                .cfg_valid(cfg_valid & ~busy_v), .cfg_ready(cr_h),
                .cfg_siting(cfg_siting),
                .cfg_done(cd_h), .cfg_error(ce_h),
                .marker_error(merr_h), .busy(busy_h));
        end else begin: noh
            assign i_tdata   = s_tdata;
            assign i_tvalid  = s_tvalid;
            assign i_tuser   = s_tuser;
            assign i_tlast   = s_tlast;
            assign s_tready  = i_tready;
            assign merr_h    = 1'b0;
            assign busy_h    = 1'b0;
            assign cr_h      = 1'b0;
            assign cd_h      = 1'b0;
            assign ce_h      = 1'b0;
        end
    endgenerate

    chroma420_v #(.BITS(BITS), .NCOLS(OW), .HEIGHT(HEIGHT)) v (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(i_tdata), .s_tvalid(i_tvalid), .s_tuser(i_tuser),
        .s_tlast(i_tlast), .s_tready(i_tready),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tuser(m_tuser),
        .m_tlast(m_tlast), .m_tready(m_tready),
        .marker_error(merr_v), .busy(busy_v));

    assign marker_error = merr_v | merr_h;
    assign busy         = busy_v | busy_h;

    generate
        if (SRC422 == 0) begin: cfgfw
            // commit only when both stages are drained
            assign cfg_ready = cr_h & ~busy_v;
            assign cfg_done  = cd_h;
            assign cfg_error = ce_h;
        end else begin: cfgdirect
            // SRC422=1 has no horizontal filter to program; cfg_siting is
            // stored-but-unused, values >1 still reject.
            reg [1:0] site_r;
            reg       cd_r, ce_r;
            assign cfg_ready = rst_n & ~busy_v;
            assign cfg_done  = cd_r;
            assign cfg_error = ce_r;
            always @(posedge clk) begin
                if (!rst_n) begin
                    site_r <= 2'd0;
                    cd_r   <= 1'b0;
                    ce_r   <= 1'b0;
                end else begin
                    cd_r <= 1'b0;
                    ce_r <= 1'b0;
                    if (cfg_valid && cfg_ready) begin
                        if (cfg_siting > 2'd1) ce_r <= 1'b1;
                        else begin
                            site_r <= cfg_siting;
                            cd_r   <= 1'b1;
                        end
                    end
                end
            end
        end
    endgenerate

    initial begin
        if ((BITS != 8 && BITS != 10) || WIDTH < 1 || HEIGHT < 1
            || (SRC422 != 0 && SRC422 != 1))
            $fatal(1, "unsupported chroma_420 parameters");
    end
endmodule
