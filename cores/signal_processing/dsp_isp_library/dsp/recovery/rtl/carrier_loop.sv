// ============================================================================
// carrier_loop.sv -- DSP-08 second-order carrier recovery loop.
//
// Reference configuration (see SPEC.md): complex baseband BPSK, signed16
// I/Q samples at Fs = 4 samples/symbol, residual carrier offset inside
// the verified pull-in range |df| <= Fs/32 (fcw preset extends hold to
// Fs/20 verified; cold Fs/16 never locks -- graceful, see SPEC.md).
//
// Chain per accepted sample (this is a real closed loop -- phase detector,
// PI loop filter, NCO feedback -- not a bare accumulator):
//
//   stage A regs (accept): ia, qa <= input; ca, sa <= sincos(phase)
//   stage B comb:
//       Ir = sat18((ia*ca + qa*sa) >>> 11)      derotate by -phase
//       Qr = sat18((qa*ca - ia*sa) >>> 11)
//       e  = Ir[17] ? -Qr : Qr                   BPSK decision-directed
//                                              (Costas sign(I)*Q) detector
//       err32 = e <<< 13                          normalize to Q31
//   stage B regs (pend && advance):
//       m_i/m_q <= sat16(Ir), sat16(Qr);  m_tvalid <= 1
//       pi_loop update (prop/integ);  lock_det update (|e|)
//       phase <= phase + sat32(fcw + corr)      inc = applied freq word
//       freq_est <= inc
//
// Loop delay = 3 samples (sample n's error reaches the NCO phase used by
// sample n+3).  II = 1, m_tvalid rises 1 edge after the accepting edge.
// All slots hold under backpressure: s_tready = !m_tvalid || m_tready;
// a stall freezes every register (no recompute, no dropped beat).
//
// Stream contract: s_tdata = {Q,I} packed signed16 lanes ([15:0]=I,
// [31:16]=Q).  m_tdata = {Qr,Ir} same packing, saturated signed16.
//
// Configuration (cfg_valid/cfg_ready, 1-cycle done/error pulse after the
// accept edge): fcw signed32 base frequency word, kp_rsh/ki_rsh 5-bit PI
// shifts (require ki_rsh > kp_rsh so the integral path is strictly weaker),
// lthr lock threshold (>= 8), ln lock count (>= 4), clear re-zeros loop
// state.  Illegal requests reject atomically: cfg_error pulses, nothing is
// committed.  cfg_ready = !cfg_pend; configuration never blocks the stream.
//
// Reset defaults: fcw=0, kp_rsh=4, ki_rsh=8, lthr=2500, ln=64.
// Single clk, synchronous active-low rst_n.
// ============================================================================
module carrier_loop (
    input  wire               clk,
    input  wire               rst_n,
    // input sample stream: {Q,I} signed16 lanes
    input  wire signed [31:0] s_tdata,
    input  wire               s_tvalid,
    output wire               s_tready,
    // recovered baseband stream: {Qr,Ir} signed16 lanes
    output reg  signed [31:0] m_tdata,
    output reg                m_tvalid,
    input  wire               m_tready,
    // atomic configuration
    input  wire               cfg_valid,
    output wire               cfg_ready,
    input  wire signed [31:0] cfg_fcw,
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
    output reg  signed [31:0] freq_est,   // last applied NCO increment
    output wire        [31:0] phase_out
);

// ---------------------------------------------------------------------------
// legality of a pending config request (combinational, whole request)
// ---------------------------------------------------------------------------
wire cfg_bad = (cfg_ki <= cfg_kp)                       ||
               (cfg_fcw > 32'sd1073741824)              ||   // > +Fs/4
               (cfg_fcw < -32'sd1073741824)             ||   // < -Fs/4
               (cfg_lthr < 16'd8)                       ||
               (cfg_ln < 8'd4);

// ---------------------------------------------------------------------------
// committed configuration registers
// ---------------------------------------------------------------------------
reg signed [31:0] fcw;
reg        [4:0]  kp_rsh, ki_rsh;
reg        [15:0] lthr;
reg        [7:0]  ln;
reg               cfg_pend;
reg               cfg_err_latch;
reg               clr_pulse;      // one-edge clear into loop state

// config fields sampled at the accept edge so the commit edge uses stable
// values even if the requester drops them after cfg_ready deasserts
reg signed [31:0] cfg_fcw_q;
reg        [4:0]  cfg_kp_q, cfg_ki_q;
reg        [15:0] cfg_lthr_q;
reg        [7:0]  cfg_ln_q;
reg               cfg_clear_q;

assign cfg_ready = !cfg_pend && rst_n;

// ---------------------------------------------------------------------------
// pipeline advance / accept
// ---------------------------------------------------------------------------
// stage A registers
reg               av;
reg signed [15:0] ia, qa;
reg signed [11:0] ca, sa;

wire adv    = !m_tvalid || m_tready;
wire accept = s_tvalid && s_tready;
assign s_tready = adv && rst_n;
wire upd = av && adv;   // one loop update per processed sample

// ---------------------------------------------------------------------------
// NCO: phase register + comb sincos (phase used by the accepted sample is
// the value BEFORE this edge's loop update -- see header)
// ---------------------------------------------------------------------------
wire signed [31:0] corr;
wire signed [32:0] inc_w = {fcw[31], fcw} + {corr[31], corr};
wire signed [31:0] inc   = (inc_w > 33'sd2147483647)  ? 32'sd2147483647  :
                           (inc_w < -33'sd2147483648) ? -32'sd2147483648 :
                                                        inc_w[31:0];
wire signed [11:0] nco_sin, nco_cos;

nco u_nco (
    .clk   (clk),
    .rst_n (rst_n),
    .en    (upd),
    .inc   (inc),
    .phase (phase_out),
    .sin_o (nco_sin),
    .cos_o (nco_cos)
);

// ---------------------------------------------------------------------------
// stage B combinational: derotate + phase detector + error normalize
// ---------------------------------------------------------------------------
wire signed [27:0] p_ii = ia * ca;
wire signed [27:0] p_qs = qa * sa;
wire signed [28:0] isum = {p_ii[27], p_ii} + {p_qs[27], p_qs};
wire signed [27:0] p_qq = qa * ca;
wire signed [27:0] p_is = ia * sa;
wire signed [28:0] qsum = {p_qq[27], p_qq} - {p_is[27], p_is};

function signed [17:0] sat18(input signed [28:0] v);
    sat18 = (v > 29'sd131071)  ? 18'sd131071  :
            (v < -29'sd131072) ? -18'sd131072 : v[17:0];
endfunction

wire signed [17:0] ir18 = sat18(isum >>> 11);
wire signed [17:0] qr18 = sat18(qsum >>> 11);
wire signed [17:0] e18  = ir18[17] ? -qr18 : qr18;
wire signed [31:0] err32 = {{14{e18[17]}}, e18} <<< 13;
wire        [17:0] emag = e18[17] ? (~e18 + 18'd1) : e18;

function signed [15:0] sat16(input signed [17:0] v);
    sat16 = (v > 18'sd32767)  ? 16'sd32767  :
            (v < -18'sd32768) ? -16'sd32768 : v[15:0];
endfunction

// ---------------------------------------------------------------------------
// PI loop filter + lock detector
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

// ---------------------------------------------------------------------------
// sequential
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        av            <= 1'b0;
        ia            <= 16'sd0;
        qa            <= 16'sd0;
        ca            <= 12'sd2046;   // cos(0) from LUT
        sa            <= 12'sd0;
        m_tvalid      <= 1'b0;
        m_tdata       <= 32'sd0;
        freq_est      <= 32'sd0;
        fcw           <= 32'sd0;
        kp_rsh        <= 5'd4;
        ki_rsh        <= 5'd8;
        lthr          <= 16'd2500;
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
                fcw    <= cfg_fcw_q;
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

        if (adv) begin
            av <= accept;
            if (accept) begin
                ia <= s_tdata[15:0];
                qa <= s_tdata[31:16];
                ca <= nco_cos;
                sa <= nco_sin;
            end
            if (av) begin
                m_tvalid <= 1'b1;
                m_tdata  <= {sat16(qr18), sat16(ir18)};
                freq_est <= inc;
            end else begin
                m_tvalid <= 1'b0;
            end
        end
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        cfg_fcw_q   <= 32'sd0;
        cfg_kp_q    <= 5'd0;
        cfg_ki_q    <= 5'd0;
        cfg_lthr_q  <= 16'd0;
        cfg_ln_q    <= 8'd0;
        cfg_clear_q <= 1'b0;
    end else if (!cfg_pend && cfg_valid) begin
        cfg_fcw_q   <= cfg_fcw;
        cfg_kp_q    <= cfg_kp;
        cfg_ki_q    <= cfg_ki;
        cfg_lthr_q  <= cfg_lthr;
        cfg_ln_q    <= cfg_ln;
        cfg_clear_q <= cfg_clear;
    end
end

endmodule
