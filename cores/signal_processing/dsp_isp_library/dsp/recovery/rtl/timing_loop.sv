// ============================================================================
// timing_loop.sv -- DSP-08 second-order symbol timing recovery loop.
//
// Reference configuration (see SPEC.md): real baseband BPSK-ish stream,
// signed16 samples at an integer oversampling ratio SPS in {4,8}; no
// interpolation (strobe quantization is +-1 input sample by design).
//
// This is a real closed loop: Gardner TED -> PI filter -> phase accumulator
// (NCO-equivalent) whose wrap emits the decision strobe; the TED closes the
// loop by steering the accumulator step.  Per accepted sample:
//
//   step  = STEP0 + clamp(corr, +-STEP0/4)     corr = prop + integ (PI regs)
//   nxt   = acc + step                          acc,step in [0,2^16)
//   acc  <= nxt[15:0]
//   half  = !acc[15] && nxt[15] && !nxt[16]     crossing mid-symbol
//   wrap  = nxt[16]                             crossing symbol boundary
//
//   on half:  m_s <= x                          midpoint sample capture
//   on wrap:  pick <= 1; pick_data <= x; pick_bit <= !x[15]
//             diff = x - s_prev
//             e    = diff>0 ? m_s : diff<0 ? -m_s : 0   Gardner w/ sign(diff)
//             err32 = e <<< 13 (Q31);  pi_loop update;  lock_det update
//             s_prev <= x;  rate_est <= corr
//
// STEP0 = 2^16/SPS (16384 for SPS=4, 8192 for SPS=8).  acc wraps once per
// symbol nominally.  pick marks the first sample at-or-after the estimated
// optimum instant; residual pick quantization is +-1 sample (documented
// jitter tolerance).  |corr| <= STEP0/4 limits the tracked symbol-rate
// offset to +-25% (verified window in SPEC.md is much narrower).
//
// Stream contract: the input models a real-time converter stream --
// s_tready is constant 1 (always-ready sink, II=1, no backpressure is
// possible or needed).  Outputs pick/pick_data/pick_bit are flag-type
// status (no backpressure; one strobe per estimated symbol).  lock,
// lock_level, rate_est and phase_out are status taps.
//
// Configuration (cfg_valid/cfg_ready, done/error pulse one edge after the
// accept edge): sps_code 0->4, 1->8 (2,3 illegal); kp_rsh/ki_rsh PI shifts
// (require ki_rsh > kp_rsh); lthr lock threshold (>= 8); ln lock count
// (>= 4); clear re-zeros loop state (acc, integ, prop, lock) -- see SPEC.
// Illegal requests reject atomically: cfg_error pulses, nothing commits.
//
// Reset defaults: SPS=4, kp_rsh=19, ki_rsh=22, lthr=10000, ln=64.
// Single clk, synchronous active-low rst_n.
// ============================================================================
module timing_loop (
    input  wire               clk,
    input  wire               rst_n,
    // input sample stream (always-ready real-time sink)
    input  wire signed [15:0] s_tdata,
    input  wire               s_tvalid,
    output wire               s_tready,
    // decision strobe outputs (flag-type, one pulse per estimated symbol)
    output reg                pick,
    output reg  signed [15:0] pick_data,
    output reg                pick_bit,
    // atomic configuration
    input  wire               cfg_valid,
    output wire               cfg_ready,
    input  wire        [1:0]  cfg_sps,
    input  wire        [4:0]  cfg_kp,
    input  wire        [4:0]  cfg_ki,
    input  wire        [15:0] cfg_lthr,
    input  wire        [7:0]  cfg_ln,
    input  wire               cfg_clear,
    output reg                cfg_done,
    output reg                cfg_error,
    // status
    output wire               lock,
    output wire        [17:0] lock_level,
    output reg  signed [31:0] rate_est,    // corr applied at last symbol
    output wire        [15:0] phase_out
);

// ---------------------------------------------------------------------------
// legality of a pending config request (combinational, whole request)
// ---------------------------------------------------------------------------
wire cfg_bad = (cfg_sps > 2'd1)   ||
               (cfg_ki <= cfg_kp) ||
               (cfg_lthr < 16'd8) ||
               (cfg_ln < 8'd4);

// ---------------------------------------------------------------------------
// committed configuration registers
// ---------------------------------------------------------------------------
reg               sps8;             // 0 -> SPS=4, 1 -> SPS=8
reg        [4:0]  kp_rsh, ki_rsh;
reg        [15:0] lthr;
reg        [7:0]  ln;
reg               cfg_pend;
reg               cfg_err_latch;
reg               clr_pulse;

// config fields sampled at the accept edge
reg        [1:0]  cfg_sps_q;
reg        [4:0]  cfg_kp_q, cfg_ki_q;
reg        [15:0] cfg_lthr_q;
reg        [7:0]  cfg_ln_q;
reg               cfg_clear_q;

assign cfg_ready = !cfg_pend && rst_n;

// ---------------------------------------------------------------------------
// loop state
// ---------------------------------------------------------------------------
reg        [15:0] acc;
reg signed [15:0] s_prev;           // previous symbol-tick sample
reg signed [15:0] m_s;              // midpoint sample since last tick
reg               have_mid;

wire signed [31:0] corr;
wire        [15:0] step0 = sps8 ? 16'd8192 : 16'd16384;

// clamp corr to +-STEP0/4 (tracked rate offset bound)
wire signed [31:0] clim = {16'b0, step0} >>> 2;
wire signed [31:0] corr_c = (corr > clim)  ? clim  :
                            (corr < -clim) ? -clim : corr;

// acc + step; step is always positive and < 2^15 (STEP0 +- STEP0/4)
// corr_c is in [-STEP0/4, STEP0/4] so the mod-2^18 sum equals the true sum
wire [17:0] step  = {2'b00, step0} + corr_c[17:0];
wire [16:0] nxt   = {1'b0, acc} + step[16:0];
wire        wrap  = nxt[16];
wire        half  = !acc[15] && nxt[15];   // never coincides with wrap

wire accept = s_tvalid;             // always ready

// TED error (combinational on accept&&wrap)
wire signed [16:0] diff  = {s_tdata[15], s_tdata} - {s_prev[15], s_prev};
wire signed [16:0] m_ext = {m_s[15], m_s};
wire signed [16:0] e17   = (diff > 17'sd0) ? m_ext :
                           (diff < 17'sd0) ? -m_ext : 17'sd0;
wire signed [16:0] e17q  = have_mid ? e17 : 17'sd0;
wire signed [31:0] err32 = {{15{e17q[16]}}, e17q} <<< 13;
wire        [17:0] emag  = {1'b0, (e17q[16] ? (~e17q + 17'd1) : e17q)};

wire upd = accept && wrap;

// ---------------------------------------------------------------------------
// PI loop filter + lock detector (update once per symbol tick)
// ---------------------------------------------------------------------------
wire signed [31:0] prop_w, integ_w;
pi_loop u_pi (
    .clk    (clk),
    .rst_n  (rst_n),
    .upd    (upd),
    .clear  (clr_pulse),
    .err    (err32),
    .kp_rsh (kp_rsh),
    .ki_rsh (ki_rsh),
    .prop   (prop_w),
    .integ  (integ_w),
    .corr   (corr)
);

lock_det u_lock (
    .clk   (clk),
    .rst_n (rst_n),
    .en    (upd),
    .clear (clr_pulse),
    .mag   (emag),
    .thr   (lthr),
    .nreq  (ln),
    .lock  (lock),
    .level (lock_level)
);

assign s_tready  = rst_n;
assign phase_out = acc;

// ---------------------------------------------------------------------------
// sequential
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        acc           <= 16'd0;
        s_prev        <= 16'sd0;
        m_s           <= 16'sd0;
        have_mid      <= 1'b0;
        pick          <= 1'b0;
        pick_data     <= 16'sd0;
        pick_bit      <= 1'b0;
        rate_est      <= 32'sd0;
        sps8          <= 1'b0;
        kp_rsh        <= 5'd19;
        ki_rsh        <= 5'd22;
        lthr          <= 16'd10000;
        ln            <= 8'd64;
        cfg_pend      <= 1'b0;
        cfg_err_latch <= 1'b0;
        cfg_done      <= 1'b0;
        cfg_error     <= 1'b0;
        clr_pulse     <= 1'b0;
    end else begin
        // config handshake: accept -> 1-cycle-later done/error pulse
        cfg_done  <= 1'b0;
        cfg_error <= 1'b0;
        clr_pulse <= 1'b0;
        if (cfg_pend) begin
            cfg_pend  <= 1'b0;
            cfg_done  <= 1'b1;
            cfg_error <= cfg_err_latch;
            if (!cfg_err_latch) begin
                sps8   <= cfg_sps_q[0];
                kp_rsh <= cfg_kp_q;
                ki_rsh <= cfg_ki_q;
                lthr   <= cfg_lthr_q;
                ln     <= cfg_ln_q;
                if (cfg_clear_q)
                    clr_pulse <= 1'b1;
            end
        end else if (cfg_valid) begin
            cfg_pend      <= 1'b1;
            cfg_err_latch <= cfg_bad;
        end

        if (clr_pulse) begin
            // cfg clear: re-zero loop state; the concurrent sample (if any)
            // is dropped from the accumulator this edge only
            acc      <= 16'd0;
            s_prev   <= 16'sd0;
            m_s      <= 16'sd0;
            have_mid <= 1'b0;
            pick     <= 1'b0;
        end else if (accept) begin
            acc <= nxt[15:0];
            if (half) begin
                m_s      <= s_tdata;
                have_mid <= 1'b1;
            end
            if (wrap) begin
                pick      <= 1'b1;
                pick_data <= s_tdata;
                pick_bit  <= ~s_tdata[15];
                s_prev    <= s_tdata;
                rate_est  <= corr_c;
                have_mid  <= 1'b0;
            end else begin
                pick <= 1'b0;
            end
        end else begin
            pick <= 1'b0;
        end
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        cfg_sps_q   <= 2'd0;
        cfg_kp_q    <= 5'd0;
        cfg_ki_q    <= 5'd0;
        cfg_lthr_q  <= 16'd0;
        cfg_ln_q    <= 8'd0;
        cfg_clear_q <= 1'b0;
    end else if (!cfg_pend && cfg_valid) begin
        cfg_sps_q   <= cfg_sps;
        cfg_kp_q    <= cfg_kp;
        cfg_ki_q    <= cfg_ki;
        cfg_lthr_q  <= cfg_lthr;
        cfg_ln_q    <= cfg_ln;
        cfg_clear_q <= cfg_clear;
    end
end

endmodule
