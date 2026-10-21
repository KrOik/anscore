// ============================================================================
// DSP-07 agc_stream: feed-forward automatic gain control, signed16 stream.
//
//   s_tdata/s_tvalid/s_tready + s_tuser(SOF)/s_tlast(EOL) markers
//     -> [slot0 capture] -> [slot1 energy update] -> [slot2 gain update]
//     -> [slot3 output registers] -> m_tdata/m_tuser/m_tlast/m_tvalid/m_tready
//
// II=1, fixed four-slot globally stalled pipeline; fabric registers only, no
// RAM, no clock enable, no gated reads.  Every accepted sample updates the
// energy estimate once (slot0->1 edge) and the gain once (slot1->2 edge) and
// emits exactly one output beat.  tuser/tlast are transport delimiters and do
// not alter AGC state.  All arithmetic is shift/add plus one 16x17 unsigned
// mantissa multiply; attack/release/estimator constants are shifts only.
// ============================================================================
module agc_stream (
    input  wire        clk,
    input  wire        rst_n,
    // sample input stream
    input  wire signed [15:0] s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire        s_tuser,       // SOF marker
    input  wire        s_tlast,       // EOL marker
    // gained output stream
    output reg  signed [15:0] m_tdata,
    output reg         m_tuser,       // carried SOF
    output reg         m_tlast,       // carried EOL
    output wire        m_tvalid,
    input  wire        m_tready,
    // atomic configuration (accepted only when pipeline is empty)
    input  wire        cfg_valid,
    output wire        cfg_ready,
    input  wire [6:0]  cfg_target,    // target level code 0..120 (code120=0dBFS)
    input  wire signed [8:0] cfg_gmin,// gain bounds, code units (~0.7526 dB each)
    input  wire signed [8:0] cfg_gmax,
    input  wire [3:0]  cfg_attack,    // gain-decrease time-constant shift
    input  wire [3:0]  cfg_release,   // gain-increase time-constant shift
    input  wire [3:0]  cfg_est,       // energy estimator time-constant shift
    input  wire        cfg_mode,      // 0: log (exp) smoothing, 1: linear slew
    input  wire        cfg_mute,      // output forced to 0, loop keeps running
    input  wire        cfg_bypass,    // output = input, loop keeps running
    input  wire        cfg_clear,     // clear env/gain state on accept
    output reg         cfg_done,
    output reg         cfg_error,
    // observability sideband
    output reg         clip_sticky,   // set on any gain-path saturation
    output wire [6:0]  env_code,      // current level code of env register
    output wire signed [9:0] gain_code // current integer gain code
);

// ---------------------------------------------------------------------------
// active configuration
// ---------------------------------------------------------------------------
reg [6:0]  c_target;
reg signed [8:0] c_gmin, c_gmax;
reg [3:0]  c_atk, c_rel, c_est;
reg        c_mode, c_mute, c_bypass;

// ---------------------------------------------------------------------------
// pipeline slots; v[i] is the valid bit of slot i.  m_tvalid == v[3].
// ---------------------------------------------------------------------------
reg [3:0]  v;
reg signed [15:0] x0, x1, x2;
reg        u0, u1, u2, l0, l1, l2;
reg [16:0] mant2;            // Q1.15 unsigned mantissa [32768,60104]
reg signed [6:0]  sh2;       // octave shift -32..31
reg [23:0] env;              // mean |x| with 8 fraction bits: |x|<<8 units
reg signed [12:0] gq;        // gain code, 4 fraction bits

wire advance = !v[3] || m_tready;
assign s_tready = rst_n && advance && !cfg_valid;
assign m_tvalid = v[3];
assign cfg_ready = rst_n && (v == 4'd0);
wire accept = s_tvalid && s_tready;

// ---------------------------------------------------------------------------
// energy estimator (slot0 -> slot1 edge): env += sign*max(1,|d|>>>est)
// |x| in [0,32768]; env tracks |x|<<8 in [0,2^23].  Converges exactly: the
// step is never 0 while a difference remains and never overshoots.
// ---------------------------------------------------------------------------
wire signed [16:0] sx0 = {x0[15], x0};
wire [16:0] ax0 = sx0 < 0 ? (17'd0 - sx0) : sx0;                 // |x0|, 0..32768
wire [24:0] ax8  = {ax0, 8'd0};                                 // |x|<<8, <=2^23
wire signed [25:0] ediff = {1'b0, ax8} - {2'b00, env};
wire [24:0] eabs  = ediff[25] ? (25'd0 - ediff[24:0]) : ediff[24:0];
wire [24:0] estep0 = eabs >> c_est;
wire [24:0] estep = (estep0 == 25'd0) ? 25'd1 : estep0;
wire [23:0] env_next = (ediff == 26'sd0) ? env :
                     ediff[25] ? (env - estep[23:0]) : (env + estep[23:0]);

// ---------------------------------------------------------------------------
// level code: octave code of a 16-bit magnitude (|x| scale, 32768 = 0 dBFS)
// code = 8*msb_index + top-3-bits-below-msb; 0 for zero.  Range 0..120.
// ---------------------------------------------------------------------------
function [6:0] level_code;
    input [15:0] e;
    integer k;
    reg [3:0] idx;
    reg [2:0] fr;
    begin
        idx = 4'd0;
        for (k = 0; k < 16; k = k + 1) if (e[k]) idx = k[3:0];
        if (idx >= 4'd3) fr = (e >> (idx - 4'd3)) & 3'd7;
        else             fr = (e << (4'd3 - idx)) & 3'd7;
        level_code = (e == 16'd0) ? 7'd0 : {idx, fr};
    end
endfunction

// env_code observes the committed env register (pre-edge), not env_next.
wire [6:0] lvl_env  = level_code(env[23:8]);
assign env_code = lvl_env;

// ---------------------------------------------------------------------------
// gain update (slot1 -> slot2 edge): desired code = target - level, clamped;
// attack shift when gain decreases, release shift when it increases.
// log mode: step = max(1, |d|>>rate)   (exponential + linear tail)
// linear mode: step = min(|d|, 32768>>rate) (constant slew quantum)
// ---------------------------------------------------------------------------
wire signed [8:0] gdes_raw = $signed({2'b00, c_target}) - $signed({2'b00, lvl_env});
wire signed [8:0] gdes = (gdes_raw < c_gmin) ? c_gmin :
                         (gdes_raw > c_gmax) ? c_gmax : gdes_raw;
wire signed [13:0] gdes_q4 = {gdes[8], gdes, 4'd0};
wire signed [13:0] gq_ext  = {gq[12], gq};
wire signed [13:0] gdiff = gdes_q4 - gq_ext;
wire [12:0] gdabs = gdiff[13] ? (13'd0 - gdiff[12:0]) : gdiff[12:0];
wire [3:0]  grate = gdiff[13] ? c_atk : c_rel;
wire [12:0] log_step0 = gdabs >> grate;
wire [12:0] log_step  = (log_step0 == 13'd0) ? 13'd1 : log_step0;
wire [15:0] lin_quantum = 16'h8000 >> grate;
wire [12:0] lin_step  = ({3'b000, gdabs} >= lin_quantum) ? lin_quantum[12:0]
                                                       : gdabs;
wire [12:0] gstep = c_mode ? lin_step : log_step;
wire signed [13:0] gq_wide = (gdiff == 14'sd0) ? gq_ext :
                             gdiff[13] ? (gq_ext - {1'b0, gstep})
                                       : (gq_ext + {1'b0, gstep});
wire signed [12:0] gq_next = gq_wide[12:0]; // step<=|diff|: never overshoots

// integer gain code = round-half-up of gq/16
wire signed [13:0] gq_next_ext = {gq_next[12], gq_next};
wire signed [13:0] gc_wide = (gq_next_ext + 14'sd8) >>> 4;
wire signed [9:0]  gc = gc_wide[9:0];
assign gain_code = ((gq_ext + 14'sd8) >>> 4);
wire signed [6:0] sh = gc >>> 3;                 // floor(gc/8), -32..31
wire [2:0]  fr_g = gc[2:0];                      // floor-mod 8
reg [16:0] mant;
always @* begin
    case (fr_g)                                  // round(32768*2^(f/8))
        3'd0: mant = 17'd32768;
        3'd1: mant = 17'd35734;
        3'd2: mant = 17'd38968;
        3'd3: mant = 17'd42495;
        3'd4: mant = 17'd46341;
        3'd5: mant = 17'd50535;
        3'd6: mant = 17'd55109;
        default: mant = 17'd60097;
    endcase
end

// ---------------------------------------------------------------------------
// gain application (slot2 -> slot3 edge): y = sat16(RNE(RNE(x*mant/2^15)<<sh))
// ---------------------------------------------------------------------------
wire signed [32:0] prod = x2 * $signed({1'b0, mant2});       // |prod| < 2^31
wire signed [17:0] scaled0 = prod >>> 15;
wire [14:0] prem = prod[14:0];
wire signed [17:0] scaled = scaled0 +
    ((prem > 15'd16384 || (prem == 15'd16384 && scaled0[0])) ? 18'sd1 : 18'sd0);

// floor-based round-nearest-even right shift; |val| < 2^17 so k>17 yields 0.
function signed [49:0] rne_right;
    input signed [17:0] val;
    input [5:0] k;
    reg signed [17:0] q;
    reg [17:0] rem, half;
    begin
        if (k > 6'd17) begin
            rne_right = 50'sd0;
        end else begin
            q = val >>> k;
            rem = val & ((18'd1 << k) - 18'd1);
            half = (k != 6'd0) ? (18'd1 << (k - 6'd1)) : 18'd0;
            if (k != 6'd0 && (rem > half || (rem == half && q[0])))
                q = q + 18'sd1;
            rne_right = {{32{q[17]}}, q};
        end
    end
endfunction

wire signed [49:0] yshift = (sh2 >= 0)
    ? ({{32{scaled[17]}}, scaled} <<< sh2[4:0])
    : rne_right(scaled, -sh2);
wire clip_int = (yshift > 50'sd32767) || (yshift < -50'sd32768);
wire signed [15:0] y_sat = (yshift > 50'sd32767)  ? 16'sh7fff :
                           (yshift < -50'sd32768) ? 16'sh8000 :
                           yshift[15:0];
wire signed [15:0] y_out = c_bypass ? x2 : (c_mute ? 16'sd0 : y_sat);

// ---------------------------------------------------------------------------
// configuration validation (whole-request reject)
// ---------------------------------------------------------------------------
wire cfg_bad = (cfg_gmin > cfg_gmax) || (cfg_target > 7'd120);
wire signed [13:0] gq_lo = {cfg_gmin[8], cfg_gmin, 4'd0};
wire signed [13:0] gq_hi = {cfg_gmax[8], cfg_gmax, 4'd0};

// ---------------------------------------------------------------------------
// sequential
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        c_target <= 7'd100;                    // ~-15 dBFS
        c_gmin   <= -9'sd96;                   // ~-72 dB
        c_gmax   <= 9'sd32;                    // ~+24 dB
        c_atk    <= 4'd3; c_rel <= 4'd10; c_est <= 4'd6;
        c_mode   <= 1'b0; c_mute <= 1'b0; c_bypass <= 1'b0;
        v <= 4'd0;
        x0 <= 16'sd0; x1 <= 16'sd0; x2 <= 16'sd0;
        u0 <= 1'b0; u1 <= 1'b0; u2 <= 1'b0;
        l0 <= 1'b0; l1 <= 1'b0; l2 <= 1'b0;
        mant2 <= 17'd32768; sh2 <= 7'sd0;
        env <= 24'd0; gq <= 13'sd0;
        m_tdata <= 16'sd0; m_tuser <= 1'b0; m_tlast <= 1'b0;
        cfg_done <= 1'b0; cfg_error <= 1'b0; clip_sticky <= 1'b0;
    end else begin
        cfg_done <= 1'b0;
        cfg_error <= 1'b0;

        if (cfg_valid && cfg_ready) begin
            cfg_done <= 1'b1;
            if (cfg_bad) begin
                cfg_error <= 1'b1;
            end else begin
                c_target <= cfg_target;
                c_gmin   <= cfg_gmin;
                c_gmax   <= cfg_gmax;
                c_atk    <= cfg_attack;
                c_rel    <= cfg_release;
                c_est    <= cfg_est;
                c_mode   <= cfg_mode;
                c_mute   <= cfg_mute;
                c_bypass <= cfg_bypass;
                clip_sticky <= 1'b0;
                if (cfg_clear) begin
                    env <= 24'd0;
                    gq  <= 13'sd0;
                end else if (gq_ext < gq_lo) begin
                    gq <= gq_lo[12:0];
                end else if (gq_ext > gq_hi) begin
                    gq <= gq_hi[12:0];
                end
            end
        end

        if (advance) begin
            v <= {v[2:0], accept};
            if (accept) begin
                x0 <= s_tdata; u0 <= s_tuser; l0 <= s_tlast;
            end
            x1 <= x0; u1 <= u0; l1 <= l0;
            x2 <= x1; u2 <= u1; l2 <= l1;
            mant2 <= mant; sh2 <= sh;
            if (v[0]) env <= env_next;
            if (v[1]) gq <= gq_next;
            if (v[2]) begin
                m_tdata <= y_out; m_tuser <= u2; m_tlast <= l2;
                if (clip_int && !c_bypass) clip_sticky <= 1'b1;
            end
        end
    end
end
endmodule
