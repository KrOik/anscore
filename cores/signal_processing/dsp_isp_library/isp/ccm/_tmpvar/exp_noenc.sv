// ============================================================================
// ISP-14 color correction matrix + tone mapping (ccm_stream).
//
// Per input RGB pixel, one output RGB pixel, same-size stream, elastic
// tdata/tvalid/tready with tuser(SOF)/tlast(EOL) passthrough (no geometry
// checking; markers travel with their pixel).  Channel c occupies slice
// [c*BITS +: BITS] of the pixel word (c0=B, c1=G, c2=R), matching
// isp/csc_stream.v and basic_isp packing.
//
// Datapath (II=1, 5-stage pipeline, latency 5):
//   x_j   = unsigned input channel j (0 .. MPX)
//   acc_c = sum_j M[c][j] * x_j  + (bias_c <<< 13)      exact Q2.13 domain
//   q_c   = clamp(round_half_away(acc_c / 2^13), 0, MPX)
//   y_c   = tone_en[c] ? PWL(q_c) : q_c   (table = domain? enc : lin bank)
//
// M[c][j] is a signed Q2.13 coefficient (16-bit field, range [-4, 4)).
// bias_c is a signed 16-bit pixel-unit offset (range [-32768, 32767]).
// Products use a transposed-accumulate form of the csc_stream shift-add
// idiom (per-bit input selects summed over coefficient bits), so NO
// multiplier/DSP primitive is consumed.
//
// Tone curve: per channel, 33 nodes over 32 uniform segments of [0, MPX]
// (idx = top 5 bits, frac = low BITS-5 bits, STEP = 2^(BITS-5)):
//   out = y0 + ((y1 - y0) * frac + STEP/2) >> (BITS-5)    round-half-up
// Nodes must be non-decreasing and <= MPX, so dy >= 0 and out <= y1 <= MPX;
// no output clamp is needed.  The interpolation product uses shift-add too.
// Two full per-channel node banks are resident in the shadow image:
// `lin` (intended for linear-light tone curves, e.g. toe/shoulder
// compression on linear data) and `enc` (intended for code-value /
// encode-decode style curves applied on encoded-domain samples).  At the
// apply edge the committed `domain` bit selects which bank is copied into
// the single per-channel active table, so a domain switch is just a ctrl
// write + commit and still lands atomically at a frame boundary.
//
// Configuration is a 16-bit write port into a SHADOW bank plus an atomic
// commit.  Address map (all writes are cfg_valid/cfg_ready beats):
//   0x00        ctrl: bit0-2 tone_en[c], bit3 domain, bits15:4 must be 0
//   0x01..0x09  matrix c00,c01,c02,c10,...,c22  (signed 16-bit Q2.13)
//   0x0A..0x0C  bias0..bias2                     (signed 16-bit, pixel units)
//   0x10..0x72  lin nodes, flat index n = c*33 + i (ch0 0x10-0x30,
//               ch1 0x31-0x51, ch2 0x52-0x72)
//   0x80..0xE2  enc nodes, same flat order
// Any other address pulses cfg_error and leaves the shadow untouched.
//
// Atomic commit / update boundary:
//   cfg_commit (one-cycle pulse; cfg_valid must be low that cycle because
//   cfg_ready is deasserted) validates the WHOLE shadow image:
//     * ctrl[15:4] == 0
//     * every matrix row obeys sum_j |M[c][j]| <= ROW_GAIN_MAX = 7.0
//       (i.e. 7<<13); this is the supported coefficient range and bounds
//       the internal accumulator to < 2^30 (see SPEC.md)
//     * every node <= MPX in both banks
//     * every per-channel node sequence in both banks is non-decreasing
//       (checked for all three channels even when tone_en disables some)
//   Header checks (ctrl bits, row bounds) are immediate; the node scan runs
//   one flat index per cycle for 99 cycles (shadow locked, SOF held as for
//   a pending apply), so a node violation pulses cfg_error up to ~100
//   cycles after the commit edge while a header violation pulses it on the
//   commit edge.  A commit while a scan or apply is pending -> cfg_error
//   immediately.  Legal scan -> pending_apply; shadow stays locked
//   (cfg_ready=0) until apply, so the image cannot be mutated mid-flight.
//   Apply boundary = the next SOF presentation once the pipeline is empty:
//     * mid-frame beats always flow under the OLD active config;
//     * while pending_apply && s_tvalid && s_tuser, s_tready is held low
//       (the SOF is deferred), remaining old pixels drain, then the whole
//       shadow image copies into the active registers in ONE edge and
//       cfg_done pulses;
//     * a commit issued while the stream is idle waits (cfg_pending=1)
//       until the next SOF is presented; since no frame-end marker exists,
//       an idle gap is never mistaken for a frame boundary;
//     * the commit edge and the apply edge never take a pixel, so no pixel
//       ever sees a mixed configuration.
//   Worst-case boundary deferral is the 99-cycle scan plus LAT cycles of
//   drain plus one held SOF cycle; there is no frame-length assumption
//   (markers are not decoded).
//
// Reset: low-active synchronous rst_n clears valid/marker/pending state and
// loads BOTH banks (shadow and active) with the legal default: identity
// matrix (diagonal 1.0 = 8192), zero bias, tone disabled, domain=0,
// identity node tables.  A commit issued right after reset is legal.
//
// busy = pending_apply || (in-flight beats != 0).  stat_domain mirrors the
// committed domain bit so a host can observe which bank generation is live.
// cfg_pending mirrors pending_apply.
// ============================================================================
module ccm_stream #(
    parameter BITS = 8,
    parameter MPX  = (BITS<1) ? 1 : ((1<<BITS)-1),
    parameter FB   = BITS - 5,                 // PWL fraction bits (8->3, 10->5)
    parameter FRAC = 13,                       // Q2.13 coefficient scale
    parameter ROW_GAIN_MAX = 7 << 13,          // per-row sum|c| bound (7.0)
    parameter LAT  = 5                         // pipeline latency (stages)
)(
    input  wire clk, rst_n,
    input  wire [3*BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output reg  [3*BITS-1:0] m_tdata,
    output wire m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    // shadow config write port (one 16-bit word per beat)
    input  wire cfg_valid,
    output wire cfg_ready,
    input  wire [7:0]  cfg_addr,
    input  wire [15:0] cfg_wdata,
    // atomic commit / status
    input  wire cfg_commit,
    output reg  cfg_done,
    output reg  cfg_error,
    output wire cfg_pending,
    output wire stat_domain,
    output wire busy
);
    // ---------------------------- shadow + active ---------------------------
    reg  [15:0]        sh_ctrl, a_ctrl;
    reg  signed [15:0] sh_c [0:8], a_c [0:8];
    reg  signed [15:0] sh_b [0:2], a_b [0:2];
    // shadow holds BOTH node banks; at apply the committed domain bit selects
    // which bank fills the single per-channel active table.
    reg  [15:0]        sh_lin[0:98];
    reg  [BITS-1:0]    a_tab[0:98];
    reg                pending_apply;
    reg                checking;             // serial legality scan running
    reg  [6:0]         chk;                  // flat node index 0..98
    reg                chk_bad;              // sticky violation
    localparam CHK_LAST = 7'd98;

    assign cfg_pending = pending_apply || checking;
    assign stat_domain = a_ctrl[3];

    // ------------------------- config legality ------------------------------
    // Commit-time header checks (ctrl reserved bits + per-row gain bound)
    // are combinational; the 99-node range/monotone scan runs serially, one
    // flat index per cycle (CHK_LAST cycles), because a commit is rare and
    // frame-scale latencies dwarf the scan.  During the scan the shadow is
    // locked (cfg_ready=0) and a presented SOF is held like a pending apply.
    function integer absc;
        input signed [15:0] v;
        begin absc = (v < 0) ? -v : v; end
    endfunction

    function cfg_bad_head;
        integer r, rsum;
        begin
            cfg_bad_head = |sh_ctrl[15:4];
            for (r = 0; r < 3; r = r + 1) begin
                rsum = absc(sh_c[3*r]) + absc(sh_c[3*r+1]) + absc(sh_c[3*r+2]);
                if (rsum > ROW_GAIN_MAX) cfg_bad_head = 1'b1;
            end
        end
    endfunction

    // node[chk] within range; monotone pair chk->chk+1 unless chk is a
    // channel's last node (flat index 32/65/98 ends a 33-node channel).
    wire node_bad =
        (sh_lin[chk] > MPX) ||
        ((chk % 33) != 7'd32 && (sh_lin[chk] > sh_lin[chk+1]));

    // ------------------------------ datapath --------------------------------
    // channel c is slice [c*BITS +: BITS]; matrix row c uses coefficients
    // a_c[3c..3c+2] against input channels 0..2.
    wire [11:0] xin [0:2];                   // zero-extended pixel channel
    assign xin[0] = {4'b0000, s_tdata[0*BITS +: BITS]};
    assign xin[1] = {4'b0000, s_tdata[1*BITS +: BITS]};
    assign xin[2] = {4'b0000, s_tdata[2*BITS +: BITS]};

    // Matrix products use the transposed-accumulate form of the csc_stream
    // shift-add idiom, which keeps the whole datapath free of multiplier
    // (DSP) primitives:
    //     sum_j x_j*c_j = sum_{k<15} 2^k (sum_j c_j[k]*x_j)
    //                       - 2^15 (sum_j c_j[15]*x_j)
    // The inner term s_k = sum_j c_j[k]*x_j selects among three unsigned
    // channels, so the per-bit selects are shared across the row's three
    // products; x_j <= MPX <= 1023 so s_k <= 3069 (12 bits) and the shifted
    // accumulation fits signed 28 bits with margin.
    wire [11:0] ssel [0:47];                 // flat index r*16 + k
    genvar gr, gk;
    generate
        for (gr = 0; gr < 3; gr = gr + 1) begin: row_sel
            for (gk = 0; gk < 16; gk = gk + 1) begin: bit_sel
                assign ssel[gr*16+gk] =
                      (a_c[3*gr  ][gk] ? xin[0] : 12'd0)
                    + (a_c[3*gr+1][gk] ? xin[1] : 12'd0)
                    + (a_c[3*gr+2][gk] ? xin[2] : 12'd0);
            end
        end
    endgenerate
    reg [11:0] s_k [0:47];

    function signed [27:0] acc_lo;           // row r, coefficient bits 0..7
        input integer r;
        integer k;
        reg signed [27:0] t;
        begin
            t = 0;
            for (k = 0; k < 8; k = k + 1)
                t = t + ({16'd0, s_k[r*16+k]} <<< k);
            acc_lo = t;
        end
    endfunction
    function signed [27:0] acc_hi;           // bits 8..14, minus sign bit 15
        input integer r;
        integer k;
        reg signed [27:0] t;
        begin
            t = 0;
            for (k = 8; k < 15; k = k + 1)
                t = t + ({16'd0, s_k[r*16+k]} <<< k);
            acc_hi = t - ({16'd0, s_k[r*16+15]} <<< 15);
        end
    endfunction

    // tone interpolation product dy*frac by shift-add (frac < 2^FB, FB<=5).
    function [BITS+FB:0] tone_prod;
        input [BITS:0]  dy;
        input [FB-1:0]  f;
        reg [BITS+FB:0] t;
        integer k;
        begin
            t = 0;
            for (k = 0; k < FB; k = k + 1)
                if (f[k]) t = t + (dy << k);
            tone_prod = t;
        end
    endfunction

    // round-half-away-from-zero at the single Q2.13 quantization boundary,
    // then clamp to [0, MPX] (mirrors csc_stream quantize with FRAC=13).
    function [BITS-1:0] quantize;
        input signed [29:0] a;
        reg signed [29:0] q;
        begin
            if (a < 0) q = -(((-a) + (30'd1 <<< (FRAC-1))) >>> FRAC);
            else       q = (a + (30'd1 <<< (FRAC-1))) >>> FRAC;
            if (q < 0)            quantize = {BITS{1'b0}};
            else if (q > MPX)     quantize = MPX[BITS-1:0];
            else                  quantize = q[BITS-1:0];
        end
    endfunction

    // |acc| < 1023*(7<<13) + 32767*2^13 < 2^28.5: the row accumulator path
    // needs only signed 30 bits (bias <<13 dominates the magnitude).
    reg  [4:0]         valid_pipe, user_pipe, last_pipe;
    reg  signed [27:0] plo [0:2], phi [0:2];
    reg  signed [29:0] bias1 [0:2], bias2 [0:2], sums [0:2];
    reg  [BITS-1:0]    qv [0:2];

    wire advance = !valid_pipe[4] || m_tready;
    wire take    = s_tvalid && s_tready;
    wire mfire   = m_tvalid && m_tready;
    assign m_tvalid = valid_pipe[4];
    assign m_tuser  = user_pipe[4];
    assign m_tlast  = last_pipe[4];

    // SOF deferral while a commit waits for an empty-pipe boundary (and
    // during the legality scan, so the boundary stays the presented SOF).
    wire sof_hold = (pending_apply || checking) && s_tvalid && s_tuser;
    assign s_tready = rst_n && advance && !sof_hold;

    reg [7:0] outstanding;                   // accepted-but-not-emitted beats
    assign busy = pending_apply || checking || (outstanding != 8'd0);

    // Apply ONLY at a presented SOF once the pipe is empty.  There is no
    // frame-end marker, so an idle gap cannot be distinguished from a
    // mid-line bubble; committing only on s_tuser guarantees whole-frame
    // atomicity.  A commit issued while idle simply waits (cfg_pending)
    // until the next SOF is presented, then defers it for the drain.
    wire apply = pending_apply && s_tvalid && s_tuser && (outstanding == 8'd0);

    assign cfg_ready = rst_n && !pending_apply && !checking && !cfg_commit;
    wire cfg_fire  = cfg_valid && cfg_ready;
    wire addr_bad  = !(cfg_addr == 8'h00 ||
                       (cfg_addr >= 8'h01 && cfg_addr <= 8'h0C) ||
                       (cfg_addr >= 8'h10 && cfg_addr <= 8'h72));

    // -------------------- tone stage combinational map ----------------------
    localparam [BITS+FB:0] HALF = {{(BITS+FB){1'b0}}, 1'b1} <<< (FB-1);
    genvar g;
    wire [3*BITS-1:0] mapped;
    generate for (g = 0; g < 3; g = g + 1) begin: tone_ch
        wire [BITS-1:0] v    = qv[g];
        wire [4:0]      idx  = v[BITS-1 -: 5];
        wire [FB-1:0]   frac = v[FB-1:0];
        wire [BITS-1:0] n0   = a_tab[g*33 + idx];
        wire [BITS-1:0] n1   = a_tab[g*33 + idx + 1];
        wire [BITS:0]   dy   = {1'b0, n1} - {1'b0, n0};
        wire [BITS+FB:0] prod = tone_prod(dy, frac);
        wire [BITS+1:0] interp = {2'b00, n0} + ((prod + HALF) >> FB);
        assign mapped[g*BITS +: BITS] =
            a_ctrl[g] ? interp[BITS-1:0] : v;
    end endgenerate

    // ------------------------------ registers -------------------------------
    integer k;
    wire signed [29:0] bb [0:2];
    assign bb[0] = {{14{a_b[0][15]}}, a_b[0]};
    assign bb[1] = {{14{a_b[1][15]}}, a_b[1]};
    assign bb[2] = {{14{a_b[2][15]}}, a_b[2]};

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_pipe <= 0; user_pipe <= 0; last_pipe <= 0;
            m_tdata <= 0;
            outstanding <= 0; pending_apply <= 0;
            checking <= 0; chk <= 0; chk_bad <= 0;
            cfg_done <= 0; cfg_error <= 0;
            sh_ctrl <= 16'd0; a_ctrl <= 16'd0;
            for (k = 0; k < 9; k = k + 1) begin
                sh_c[k] <= ((k % 4) == 0) ? 16'sd8192 : 16'sd0;
                a_c[k]  <= ((k % 4) == 0) ? 16'sd8192 : 16'sd0;
            end
            for (k = 0; k < 3; k = k + 1) begin
                sh_b[k] <= 16'sd0; a_b[k] <= 16'sd0;
            end
            for (k = 0; k < 99; k = k + 1) begin
                // identity node table: node[i] = min(i*STEP, MPX)
                if (((k % 33) << FB) > MPX) begin
                    sh_lin[k] <= MPX; a_tab[k] <= MPX;
                end else begin
                    sh_lin[k] <= (k % 33) << FB;
                    a_tab[k]  <= (k % 33) << FB;
                end
            end
        end else begin
            cfg_done <= 0; cfg_error <= 0;

            // shadow write port
            if (cfg_fire) begin
                if (addr_bad) cfg_error <= 1'b1;
                else if (cfg_addr == 8'h00) sh_ctrl <= cfg_wdata;
                else if (cfg_addr <= 8'h09) sh_c[cfg_addr - 8'h01] <= cfg_wdata;
                else if (cfg_addr <= 8'h0C) sh_b[cfg_addr - 8'h0A] <= cfg_wdata;
                else if (cfg_addr <= 8'h72) sh_lin[cfg_addr - 8'h10] <= cfg_wdata;
                else                        cfg_error <= 1'b1;
            end

            // commit request: header checks now; node scan serially.
            if (cfg_commit) begin
                if (pending_apply || checking || cfg_bad_head())
                    cfg_error <= 1'b1;
                else begin
                    checking <= 1'b1;
                    chk      <= 7'd0;
                    chk_bad  <= 1'b0;
                end
            end else if (checking) begin
                chk_bad <= chk_bad || node_bad;
                if (chk == CHK_LAST) begin
                    checking <= 1'b0;
                    if (chk_bad || node_bad) cfg_error <= 1'b1;
                    else                     pending_apply <= 1'b1;
                end else
                    chk <= chk + 7'd1;
            end

            // atomic apply at empty-pipe SOF boundary
            if (apply) begin
                pending_apply <= 1'b0;
                cfg_done <= 1'b1;
                a_ctrl <= sh_ctrl;
                for (k = 0; k < 9; k = k + 1) a_c[k] <= sh_c[k];
                for (k = 0; k < 3; k = k + 1) a_b[k] <= sh_b[k];
                // domain selects which resident shadow bank becomes the
                // active tone table
                for (k = 0; k < 99; k = k + 1)
                    a_tab[k] <= sh_lin[k][BITS-1:0];
            end

            // in-flight beat accounting
            case ({take, mfire})
                2'b10:   outstanding <= outstanding + 8'd1;
                2'b01:   outstanding <= outstanding - 8'd1;
                default: outstanding <= outstanding;
            endcase

            if (advance) begin
                // `take` (not raw s_tvalid): a deferred SOF must not enter a
                // ghost valid beat or misalign its markers into the pipe.
                valid_pipe <= {valid_pipe[3:0], take};
                user_pipe  <= {user_pipe[3:0], s_tuser && take};
                last_pipe  <= {last_pipe[3:0], s_tlast && take};
                // stage 1: per-(row,coefficient-bit) selected channel sums
                if (take) begin
                    for (k = 0; k < 48; k = k + 1) s_k[k] <= ssel[k];
                    for (k = 0; k < 3; k = k + 1) bias1[k] <= bb[k] <<< FRAC;
                end
                // stage 2: two shifted partial accumulations + delayed bias
                if (valid_pipe[0]) begin
                    for (k = 0; k < 3; k = k + 1) begin
                        plo[k] <= acc_lo(k);
                        phi[k] <= acc_hi(k);
                        bias2[k] <= bias1[k];
                    end
                end
                // stage 3: full row accumulation, no intermediate quantization
                if (valid_pipe[1]) begin
                    for (k = 0; k < 3; k = k + 1)
                        sums[k] <= plo[k] + phi[k] + bias2[k];
                end
                // stage 4: the only matrix-domain quantization boundary
                if (valid_pipe[2]) begin
                    for (k = 0; k < 3; k = k + 1) qv[k] <= quantize(sums[k]);
                end
                // stage 5: optional per-channel PWL tone map
                if (valid_pipe[3]) m_tdata <= mapped;
            end
        end
    end

    initial begin
        if (BITS != 8 && BITS != 10)
            $fatal(1, "unsupported ccm_stream parameters");
    end
endmodule
