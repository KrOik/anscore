`timescale 1ns/1ps
// ============================================================================
// ISP-15 chroma resampler stage 1: 4:4:4 -> 4:2:2 horizontal chroma decimation.
//
// Input  : one 4:4:4 pixel per beat, s_tdata = {Y, Cb, Cr} MSB->LSB
//          (same channel order as isp/csc_stream.v),
//          tuser = SOF at (x==0 && y==0), tlast = EOL at x == WIDTH-1.
// Output : one beat per chroma column pair, ceil(WIDTH/2) beats per line,
//          m_tdata = {Y_even, Cb_f, Y_odd, Cr_f} MSB->LSB (YUYV field order,
//          i.e. serialized MSB-first it produces byte order Y0 Cb Y1 Cr).
//          Odd WIDTH: last pair is a single column, the Y_odd slot repeats
//          the last luma (documented replicate padding).
//
// Chroma siting (cfg_siting, committed only between frames):
//   0 = co-sited left (JPEG/MPEG-1 style): chroma samples sit on even
//       columns; anti-alias FIR [1,2,1]/4 centred on column 2i.
//   1 = centre (MPEG-2 style): chroma midway between columns 2i and 2i+1;
//       symmetric FIR [1,3,3,1]/8 spanning columns 2i-1 .. 2i+2.
//   values 2/3 are rejected with cfg_error and the old config is retained.
//   Columns outside the frame are replicate-extended in both modes.
//
// Rate contract: input accepts at II=1 whenever the output register is not
// stalled; output emits one beat per two accepted pixels on average
// (rate 1/2).  One corner emits two beats for a single accepted pixel
// (centre siting + odd WIDTH + last column): the second beat is parked in
// `pend_*` and the input is held by s_tready until it drains.
//
// Latency: first output beat at the input beat that completes its tap
// window (x==1 for co-sited, x==2 or line end for centre).
// ============================================================================
module chroma_422 #(
    parameter BITS   = 8,
    parameter WIDTH  = 32,
    parameter HEIGHT = 24
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [3*BITS-1:0] s_tdata,
    input  wire             s_tvalid,
    input  wire             s_tuser,
    input  wire             s_tlast,
    output wire             s_tready,
    output reg  [4*BITS-1:0] m_tdata,
    output reg              m_tvalid,
    output reg              m_tuser,
    output reg              m_tlast,
    input  wire             m_tready,
    input  wire             cfg_valid,
    output wire             cfg_ready,
    input  wire [1:0]       cfg_siting,
    output reg              cfg_done,
    output reg              cfg_error,
    output reg              marker_error,
    output wire             busy
);
    localparam OW = (WIDTH + 1) >> 1;                 // chroma columns / line
    localparam XW = (WIDTH  > 1) ? $clog2(WIDTH)  : 1;
    localparam YW = (HEIGHT > 1) ? $clog2(HEIGHT) : 1;
    localparam CW = (OW     > 1) ? $clog2(OW)     : 1;

    reg              site;            // 0 = co-sited [1,2,1]/4, 1 = centre [1,3,3,1]/8
    reg [XW-1:0]     x;
    reg [YW-1:0]     y;
    reg [CW-1:0]     ocnt;            // emitted beats so far on this line
    reg              in_frame;
    reg [BITS-1:0]   cbh0, cbh1, cbh2; // C[x-1], C[x-2], C[x-3]
    reg [BITS-1:0]   crh0, crh1, crh2;
    reg [BITS-1:0]   y_e;             // luma of the open pair's even pixel
    reg [BITS-1:0]   y_pe, y_po;      // luma pair of the previous pair
    reg              pend_valid;      // deferred second beat (odd-W centre tail)
    reg [4*BITS-1:0] pend_data;
    reg              pend_user, pend_last;

    wire [BITS-1:0] cy  = s_tdata[3*BITS-1 -: BITS];
    wire [BITS-1:0] ccb = s_tdata[2*BITS-1 -: BITS];
    wire [BITS-1:0] ccr = s_tdata[BITS-1:0];

    wire xodd  = x[0];
    wire xlast = (x == WIDTH - 1);

    assign busy      = in_frame | m_tvalid | pend_valid;
    assign cfg_ready = rst_n & ~busy;
    wire   out_free  = ~m_tvalid | m_tready;
    assign s_tready  = rst_n & out_free & ~pend_valid & ~(cfg_valid & cfg_ready);
    wire   fire      = s_tvalid & s_tready;

    // emission schedule ------------------------------------------------------
    // e1: the "regular" emission for this input beat.
    // e2: the extra "last pair" emission in centre mode at end of line.
    wire e1 = site ? (~xodd & (x != 0))
                   : (xodd | (xlast & ~xodd));
    wire e2 = site & xlast;

    // -- horizontal decimation primitives (round half up) --------------------
    function [BITS-1:0] dec3;            // [1,2,1]/4
        input [BITS-1:0] l, c, r;
        reg [BITS+2:0] s;
        begin s = l + c + c + r + 2; dec3 = s >> 2; end
    endfunction
    function [BITS-1:0] dec4;            // [1,3,3,1]/8
        input [BITS-1:0] a, b, c, d;
        reg [BITS+3:0] s;
        begin s = a + b + b + b + c + c + c + d + 4; dec4 = s >> 3; end
    endfunction

    // emit1 tap picks ---------------------------------------------------------
    // co-sited odd x   : taps {x-2, x-1, x}      -> {h1,h0,cur}, x==1 clamps to h0
    // co-sited last x  : (odd W, x even) {x-1,x,x+1->x} -> {h0,cur,cur}
    // centre  even x>0 : taps {x-3..x} -> {h2,h1,h0,cur}, x==2 clamps to h1
    wire [BITS-1:0] e1_cbL = xodd ? ((x == 1) ? cbh0 : cbh1)
                                  : ((x != 0) ? cbh0 : ccb);
    wire [BITS-1:0] e1_crL = xodd ? ((x == 1) ? crh0 : crh1)
                                  : ((x != 0) ? crh0 : ccr);
    wire [BITS-1:0] e1_cbM = xodd ? cbh0 : ccb;
    wire [BITS-1:0] e1_crM = xodd ? crh0 : ccr;
    wire [BITS-1:0] e1t0cb = (x == 2) ? cbh1 : cbh2;
    wire [BITS-1:0] e1t0cr = (x == 2) ? crh1 : crh2;
    wire [BITS-1:0] e1_cb = site ? dec4(e1t0cb, cbh1, cbh0, ccb)
                                 : dec3(e1_cbL, e1_cbM, ccb);
    wire [BITS-1:0] e1_cr = site ? dec4(e1t0cr, crh1, crh0, ccr)
                                 : dec3(e1_crL, e1_crM, ccr);
    wire [BITS-1:0] e1_ya = site ? y_pe : (xodd ? y_e : cy);
    wire [BITS-1:0] e1_yb = site ? y_po : cy;

    // emit2 tap picks (centre mode, last column only) -------------------------
    // W even (x odd)   : taps {x-2,x-1,x,x+1->x} = {h1,h0,cur,cur}; x==1 clamps h1->h0
    // W odd  (x even)  : taps {x-1,x,x+1->x,x+2->x} = {h0,cur,cur,cur}; x==0 all cur
    wire [BITS-1:0] e2t0cb = xodd ? ((x == 1) ? cbh0 : cbh1)
                                  : ((x != 0) ? cbh0 : ccb);
    wire [BITS-1:0] e2t0cr = xodd ? ((x == 1) ? crh0 : crh1)
                                  : ((x != 0) ? crh0 : ccr);
    wire [BITS-1:0] e2_cb = xodd ? dec4(e2t0cb, cbh0, ccb, ccb)
                                 : dec4(e2t0cb, ccb, ccb, ccb);
    wire [BITS-1:0] e2_cr = xodd ? dec4(e2t0cr, crh0, ccr, ccr)
                                 : dec4(e2t0cr, ccr, ccr, ccr);
    wire [BITS-1:0] e2_ya = xodd ? y_e : cy;
    wire [BITS-1:0] e2_yb = cy;

    // beat index bookkeeping for sidebands ------------------------------------
    wire [CW:0] idx2   = {1'b0, ocnt} + e1;
    wire        e1_uf  = (y == 0) & (ocnt == 0);
    wire        e1_lf  = (ocnt == OW - 1);
    wire        e2_uf  = (y == 0) & (idx2 == 0);
    wire        e2_lf  = (idx2 == OW - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            site         <= 1'b0;
            x            <= {XW{1'b0}};
            y            <= {YW{1'b0}};
            ocnt         <= {CW{1'b0}};
            in_frame     <= 1'b0;
            cbh0 <= 0; cbh1 <= 0; cbh2 <= 0;
            crh0 <= 0; crh1 <= 0; crh2 <= 0;
            y_e <= 0; y_pe <= 0; y_po <= 0;
            pend_valid   <= 1'b0;
            pend_data    <= {4*BITS{1'b0}};
            pend_user    <= 1'b0;
            pend_last    <= 1'b0;
            m_tdata      <= {4*BITS{1'b0}};
            m_tvalid     <= 1'b0;
            m_tuser      <= 1'b0;
            m_tlast      <= 1'b0;
            cfg_done     <= 1'b0;
            cfg_error    <= 1'b0;
            marker_error <= 1'b0;
        end else begin
            cfg_done  <= 1'b0;
            cfg_error <= 1'b0;
            if (m_tready) m_tvalid <= 1'b0;

            if (cfg_valid && cfg_ready) begin
                if (cfg_siting > 2'd1) cfg_error <= 1'b1;
                else begin
                    site     <= cfg_siting[0];
                    cfg_done <= 1'b1;
                end
            end

            if (pend_valid && out_free) begin
                m_tdata    <= pend_data;
                m_tuser    <= pend_user;
                m_tlast    <= pend_last;
                m_tvalid   <= 1'b1;
                pend_valid <= 1'b0;
            end

            if (fire) begin
                if (s_tuser != (x == 0 && y == 0 && !in_frame))
                    marker_error <= 1'b1;
                if (s_tlast != xlast)
                    marker_error <= 1'b1;

                cbh2 <= cbh1; cbh1 <= cbh0; cbh0 <= ccb;
                crh2 <= crh1; crh1 <= crh0; crh0 <= ccr;
                if (!xodd) y_e <= cy;
                else begin y_pe <= y_e; y_po <= cy; end

                if (s_tuser) in_frame <= 1'b1;
                if (xlast) begin
                    x    <= {XW{1'b0}};
                    ocnt <= {CW{1'b0}};
                    if (y == HEIGHT - 1) begin
                        y        <= {YW{1'b0}};
                        in_frame <= 1'b0;
                    end else y <= y + 1'b1;
                end else begin
                    x    <= x + 1'b1;
                    ocnt <= ocnt + e1 + e2;
                end

                if (e1) begin
                    m_tdata  <= {e1_ya, e1_cb, e1_yb, e1_cr};
                    m_tuser  <= e1_uf;
                    m_tlast  <= e1_lf;
                    m_tvalid <= 1'b1;
                end
                if (e2) begin
                    if (e1) begin                       // two beats owed: park #2
                        pend_data  <= {e2_ya, e2_cb, e2_yb, e2_cr};
                        pend_user  <= e2_uf;
                        pend_last  <= e2_lf;
                        pend_valid <= 1'b1;
                    end else begin
                        m_tdata  <= {e2_ya, e2_cb, e2_yb, e2_cr};
                        m_tuser  <= e2_uf;
                        m_tlast  <= e2_lf;
                        m_tvalid <= 1'b1;
                    end
                end
            end
        end
    end

    initial begin
        if ((BITS != 8 && BITS != 10) || WIDTH < 1 || HEIGHT < 1)
            $fatal(1, "unsupported chroma_422 parameters");
    end
endmodule
