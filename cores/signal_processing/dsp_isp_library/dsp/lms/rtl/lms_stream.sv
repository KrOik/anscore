// ===========================================================================
// lms_stream.sv -- DSP-15 adaptive LMS / NLMS filter (stream variant)
//
// Two implementation variants selected by parameter IMPL; the externally
// visible per-sample numeric contract is IDENTICAL (see SPEC.md /
// models/lms_model.py):
//
//   data    x,d : packed s_tdata = {d[31:16], x[15:0]}, signed Q1.15
//   output      : m_tdata = {e[31:16], y[15:0]}, signed Q1.15
//   coef    c   : signed 24-bit Q4.20 register array, zero-initialized
//   step    mu  : unsigned UQ0.16 (mu_real = mu/65536)
//
//   acc  = sum_{k<taps} c[k]*x[n-k]            (exact integer dot product)
//   y    = sat16( RNE(acc / 2^20) )
//   e    = sat16( d - y )
//   t2   = sat18( RNE(mu*e / 2^15) )           (mu*e in Q1.31 -> Q1.16 units)
//   LMS  : g=t2,             delta[k] = RNE(g*x[n-k]/2^11)
//   NLMS : E_den = min(e2>>16, 2^20-1)         (e2 = sum of squared taps, raw)
//          floor_eff = max(cfg_floor,1); bypass iff E_den < floor_eff
//          g = sat20( RNE(t2*2^8/E_den) ) via fp_div_* (exact RNE division)
//          delta[k] = RNE(g*x[n-k]/2^5);      bypassed or frozen -> delta=0
//   c[k] <- sat24( c[k] + delta[k] ), k<taps
//
//   RNE = round-half-to-even on the magnitude (symmetric for negatives,
//   identical to infra/fixedpoint).  All narrowing saturates; no wrap.
//
//   IMPL=0 serial-MAC: one shared 24x20 multiplier, FSM, one sample per
//     2*NTAPS+4 cycles (LMS) or 3*NTAPS+32 (NLMS, iterative divider).
//     Update committed before the next sample is accepted (VIS=1).
//   IMPL=1 parallel  : rigid fixed-latency pipeline, II=1 for NTAPS<=8,
//     delayed-LMS commit VIS=NL+31 samples (NL=ceil(log2(NTAPS))).
//     Multiplier count 2*NTAPS+3 shared-form 24x20 multipliers when
//     MULT_DSP=1 (exceeds the <=4 DSP image budget for NTAPS>=1 -- see
//     SPEC.md); MULT_DSP=0 uses explicit partial-product logic multipliers.
//
// NLMS division reuses infra/fixedpoint/rtl/recip_div.sv (fp_div_iter /
// fp_div_pipe); compile that file alongside.  Division precision is exact RNE
// (<=1/2 lsb of the Q10 gain); the energy floor bypasses the update entirely
// (never divides by the floor).
//
// Config handshake: cfg_valid&&cfg_ready commits atomically; cfg_done pulses
// on every accept, cfg_error additionally on illegal fields (state and config
// preserved).  Legal config clears sample history and energy; coefficients
// are cleared only when cfg_coef_clr is set.  cfg_ready requires the engine
// completely drained (no in-flight samples, no held output).
// ===========================================================================
module lms_stream #(
  parameter integer NTAPS    = 8,
  parameter integer IMPL     = 0,   // 0=serial-MAC, 1=parallel II=1
  parameter integer MULT_DSP = 1    // 1=infer '*' operator, 0=logic mult
)(
  input  wire        clk,
  input  wire        rst_n,
  input  wire [31:0] s_tdata,        // {d,x}
  input  wire        s_tvalid,
  output wire        s_tready,
  output wire [31:0] m_tdata,        // {e,y}
  output wire [1:0]  m_tuser,        // {nlms_floor_bypass, clip_event}
  output wire        m_tvalid,
  input  wire        m_tready,
  // runtime configuration (atomic commit, only when drained)
  input  wire        cfg_valid,
  output wire        cfg_ready,
  input  wire [6:0]  cfg_taps,       // 1..NTAPS
  input  wire [15:0] cfg_mu,         // UQ0.16
  input  wire        cfg_nlms,       // 0=LMS 1=NLMS
  input  wire        cfg_update_en,  // 0 freezes adaptation
  input  wire [19:0] cfg_floor,      // NLMS energy floor (E_den units); 0=>guard div0 only
  input  wire        cfg_coef_clr,   // zero coefficients on this commit
  output wire        cfg_done,
  output wire        cfg_error,
  // coefficient write port (host init; wins over adaptation for that tap)
  input  wire        cw_en,
  input  wire [6:0]  cw_addr,
  input  wire signed [23:0] cw_data,
  // coefficient readback port (registered read, 1-cycle latency)
  input  wire        rb_en,
  input  wire [6:0]  rb_addr,
  output wire        rb_valid,
  output wire signed [23:0] rb_data
);
generate
  if (IMPL == 0) begin: g_serial
    lms_serial #(.NTAPS(NTAPS), .MULT_DSP(MULT_DSP)) core (
      .clk(clk), .rst_n(rst_n),
      .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready),
      .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid), .m_tready(m_tready),
      .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
      .cfg_taps(cfg_taps), .cfg_mu(cfg_mu), .cfg_nlms(cfg_nlms),
      .cfg_update_en(cfg_update_en), .cfg_floor(cfg_floor), .cfg_coef_clr(cfg_coef_clr),
      .cfg_done(cfg_done), .cfg_error(cfg_error),
      .cw_en(cw_en), .cw_addr(cw_addr), .cw_data(cw_data),
      .rb_en(rb_en), .rb_addr(rb_addr), .rb_valid(rb_valid), .rb_data(rb_data));
  end else begin: g_parallel
    lms_parallel #(.NTAPS(NTAPS), .MULT_DSP(MULT_DSP)) core (
      .clk(clk), .rst_n(rst_n),
      .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready),
      .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid), .m_tready(m_tready),
      .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
      .cfg_taps(cfg_taps), .cfg_mu(cfg_mu), .cfg_nlms(cfg_nlms),
      .cfg_update_en(cfg_update_en), .cfg_floor(cfg_floor), .cfg_coef_clr(cfg_coef_clr),
      .cfg_done(cfg_done), .cfg_error(cfg_error),
      .cw_en(cw_en), .cw_addr(cw_addr), .cw_data(cw_data),
      .rb_en(rb_en), .rb_addr(rb_addr), .rb_valid(rb_valid), .rb_data(rb_data));
  end
endgenerate
`ifndef SYNTHESIS
initial begin
  if (NTAPS < 1 || NTAPS > 64) $fatal(1, "lms_stream: NTAPS must be 1..64");
  if (IMPL != 0 && NTAPS < 2) $fatal(1, "lms_stream: parallel IMPL needs NTAPS>=2");
end
`endif
endmodule

// ===========================================================================
// Shared-form signed multiplier 24x20 -> 44 bits.  MULT_DSP=1 infers the '*'
// operator (DSP-capable); MULT_DSP=0 expands an explicit unsigned partial-
// product tree with sign correction (zero DSP primitives).
// ===========================================================================
module lms_mul2420 #(parameter integer MULT_DSP=1)(
  input  wire signed [23:0] a,
  input  wire signed [19:0] b,
  output wire signed [43:0] p
);
generate
  if (MULT_DSP) begin: dsp
    assign p = a * b;
  end else begin: logicm
    wire [23:0] ua = a[23] ? (~a + 1'b1) : a;
    wire [19:0] ub = b[19] ? (~b + 1'b1) : b;
    reg [43:0] rows [1:63];
    integer i;
    always @* begin
      for (i = 0; i < 64; i = i + 1) rows[i] = 44'd0;
      for (i = 0; i < 20; i = i + 1)
        rows[32 + i] = ub[i] ? ({20'd0, ua} << i) : 44'd0;
      for (i = 31; i > 0; i = i - 1) rows[i] = rows[2*i] + rows[2*i+1];
    end
    assign p = (a[23] ^ b[19]) ? -$signed(rows[1]) : $signed(rows[1]);
  end
endgenerate
endmodule

// RNE(v/2^s) on signed 64-bit, ties to even -- floor shift + remainder rule.
module lms_rne64(
  input  wire signed [63:0] v,
  input  wire [6:0]         s,
  output reg  signed [63:0] q
);
reg signed [63:0] qq; reg [63:0] r;
always @* begin
  if (s == 0) qq = v;
  else begin
    qq = v >>> s;
    r  = v & ((64'd1 << s) - 64'd1);       // floor-division remainder
    if (r > (64'd1 << (s - 1)) || (r == (64'd1 << (s - 1)) && qq[0]))
      qq = qq + 1'b1;
  end
  q = qq;
end
endmodule

// ===========================================================================
// IMPL=0 : serial-MAC core -- one shared multiplier, FSM per sample.
// States per accepted sample (NLMS):
//   MACY(taps) -> MACE(taps) -> EERR -> EMU -> DIVI -> DIVW(~26) -> UPD(taps)
//   -> OUT.  LMS skips MACE and the divider: MACY(taps) -> EERR -> EMU ->
//   UPD(taps) -> OUT.
// ===========================================================================
module lms_serial #(parameter integer NTAPS=8, parameter integer MULT_DSP=1)(
  input  wire        clk,
  input  wire        rst_n,
  input  wire [31:0] s_tdata,
  input  wire        s_tvalid,
  output wire        s_tready,
  output reg  [31:0] m_tdata,
  output reg  [1:0]  m_tuser,
  output reg         m_tvalid,
  input  wire        m_tready,
  input  wire        cfg_valid,
  output wire        cfg_ready,
  input  wire [6:0]  cfg_taps,
  input  wire [15:0] cfg_mu,
  input  wire        cfg_nlms,
  input  wire        cfg_update_en,
  input  wire [19:0] cfg_floor,
  input  wire        cfg_coef_clr,
  output reg         cfg_done,
  output reg         cfg_error,
  input  wire        cw_en,
  input  wire [6:0]  cw_addr,
  input  wire signed [23:0] cw_data,
  input  wire        rb_en,
  input  wire [6:0]  rb_addr,
  output reg         rb_valid,
  output reg  signed [23:0] rb_data
);
localparam S_IDLE=0, S_MACY=1, S_MACE=2, S_EERR=3, S_EMU=4,
           S_DIVI=5, S_DIVW=6, S_UPD=7, S_OUT=8;
reg [3:0]  state;
reg [6:0]  k;
reg [6:0]  taps_r; reg [15:0] mu_r; reg nlms_r, uen_r; reg [19:0] floor_r;
reg signed [23:0] coef [0:NTAPS-1];
reg signed [15:0] hist [0:NTAPS-1];
reg signed [15:0] d_r, y_r, e_r;
reg signed [17:0] t2_r;
reg signed [19:0] g_r;
reg        [19:0] eden_r;
reg               bypass_r, clipacc;
reg signed [47:0] acc;
reg        [39:0] accE;
integer i;

// ---- shared multiplier operand mux ---------------------------------------
reg signed [23:0] opa; reg signed [19:0] opb;
always @* begin
  case (state)
    S_MACY: begin opa = coef[k];                             opb = {{4{hist[k][15]}}, hist[k]}; end
    S_MACE: begin opa = {{8{hist[k][15]}}, hist[k]};         opb = {{4{hist[k][15]}}, hist[k]}; end
    S_EMU : begin opa = {{8{e_r[15]}}, e_r};                 opb = {4'b0, mu_r};                  end
    default:begin opa = {{4{g_r[19]}}, g_r};                 opb = {{4{hist[k][15]}}, hist[k]}; end
  endcase
end
wire signed [43:0] prod;
lms_mul2420 #(.MULT_DSP(MULT_DSP)) u_mul(.a(opa), .b(opb), .p(prod));
wire signed [63:0] prod64 = {{20{prod[43]}}, prod};

// ---- combinational helpers ------------------------------------------------
wire signed [63:0] acc64 = {{16{acc[47]}}, acc};
wire signed [63:0] y_full;
lms_rne64 u_ry(.v(acc64), .s(7'd20), .q(y_full));
wire               cl_y  = (y_full > 64'sd32767) || (y_full < -64'sd32768);
wire signed [15:0] y_w   = cl_y ? (y_full[63] ? -16'sd32768 : 16'sd32767)
                                : y_full[15:0];
wire signed [16:0] e_pre = {d_r[15], d_r} - {y_w[15], y_w};
wire               cl_e  = (e_pre > 17'sd32767) || (e_pre < -17'sd32768);
wire signed [15:0] e_w   = cl_e ? (e_pre[16] ? -16'sd32768 : 16'sd32767)
                                : e_pre[15:0];
wire        [39:0] eden_pre = accE >> 16;
wire        [19:0] eden_w  = (eden_pre > 40'hFFFFF) ? 20'hFFFFF : eden_pre[19:0];
wire        [19:0] floor_eff = (floor_r == 0) ? 20'd1 : floor_r;
wire               bypass_w  = nlms_r && (eden_w < floor_eff);
wire signed [63:0] t2_full;
lms_rne64 u_rt(.v(prod64), .s(7'd15), .q(t2_full));
wire               cl_t2 = (t2_full > 64'sd131071) || (t2_full < -64'sd131072);
wire signed [17:0] t2_w  = cl_t2 ? (t2_full[63] ? -18'sd131072 : 18'sd131071)
                                 : t2_full[17:0];
// update-path combinational values (valid during S_UPD)
wire signed [63:0] d_full;
lms_rne64 u_rd(.v(prod64), .s(nlms_r ? 7'd5 : 7'd11), .q(d_full));
wire signed [47:0] csum  = {{24{coef[k][23]}}, coef[k]} + d_full[47:0];
wire               cl_c  = (csum > 48'sd8388607) || (csum < -48'sd8388608);
wire signed [23:0] c_w   = cl_c ? (csum[47] ? -24'sd8388608 : 24'sd8388607)
                                : csum[23:0];

// ---- NLMS iterative divider (reused fixed-point primitive) ----------------
wire        dv_sr, dv_mv;
wire [19:0] dv_q; wire [1:0] dv_usr;
wire [19:0] eden_div = (eden_r == 0) ? 20'd1 : eden_r;
fp_div_iter #(.AW(18), .BW(21), .FB(8), .OUT_W(20)) u_div (
  .clk(clk), .rst_n(rst_n),
  .s_tdata({1'b0, eden_div, t2_r}),
  .s_tvalid(state == S_DIVI), .s_tready(dv_sr),
  .m_tdata(dv_q), .m_tuser(dv_usr), .m_tvalid(dv_mv), .m_tready(1'b1));

assign s_tready  = rst_n && (state == S_IDLE) && !cfg_valid && (!m_tvalid || m_tready);
assign cfg_ready = rst_n && (state == S_IDLE) && !m_tvalid;
wire   accept    = s_tvalid && s_tready;

always @(posedge clk) begin
  if (!rst_n) begin
    state <= S_IDLE; m_tvalid <= 0; cfg_done <= 0; cfg_error <= 0;
    taps_r <= NTAPS[6:0]; mu_r <= 16'h2000; nlms_r <= 0; uen_r <= 1;
    floor_r <= 20'd64;
    rb_valid <= 0; rb_data <= 0;
    acc <= 0; accE <= 0; k <= 0; clipacc <= 0; bypass_r <= 0;
    d_r <= 0; y_r <= 0; e_r <= 0; t2_r <= 0; g_r <= 0; eden_r <= 0;
    for (i = 0; i < NTAPS; i = i + 1) begin coef[i] <= 0; hist[i] <= 0; end
  end else begin
    cfg_done <= 0; cfg_error <= 0; rb_valid <= 0;
    if (m_tready) m_tvalid <= 0;
    if (rb_en) begin
      rb_valid <= 1;
      rb_data  <= (rb_addr < NTAPS) ? coef[rb_addr] : 24'sd0;
    end
    if (cfg_valid && cfg_ready) begin
      cfg_done <= 1;
      if (cfg_taps < 1 || cfg_taps > NTAPS) begin
        cfg_error <= 1;                       // rejected; config/state kept
      end else begin
        taps_r <= cfg_taps; mu_r <= cfg_mu; nlms_r <= cfg_nlms;
        uen_r <= cfg_update_en; floor_r <= cfg_floor;
        acc <= 0; accE <= 0;
        for (i = 0; i < NTAPS; i = i + 1) hist[i] <= 0;
        if (cfg_coef_clr) for (i = 0; i < NTAPS; i = i + 1) coef[i] <= 0;
      end
    end
    case (state)
      S_IDLE: if (accept) begin
        d_r     <= s_tdata[31:16];
        hist[0] <= s_tdata[15:0];
        for (i = 1; i < NTAPS; i = i + 1) hist[i] <= hist[i-1];
        acc <= 0; accE <= 0; k <= 0; clipacc <= 0; bypass_r <= 0;
        state <= S_MACY;
      end
      S_MACY: begin
        acc <= acc + {{4{prod[43]}}, prod};
        if (k == taps_r - 1) begin k <= 0; state <= nlms_r ? S_MACE : S_EERR; end
        else k <= k + 1'b1;
      end
      S_MACE: begin
        accE <= accE + {9'd0, prod[30:0]};     // x*x >= 0, <= 2^30
        if (k == taps_r - 1) begin k <= 0; state <= S_EERR; end
        else k <= k + 1'b1;
      end
      S_EERR: begin
        y_r      <= y_w;
        e_r      <= e_w;
        eden_r   <= eden_w;
        bypass_r <= bypass_w;
        clipacc  <= clipacc | cl_y | cl_e;
        state    <= S_EMU;
      end
      S_EMU: begin
        t2_r    <= t2_w;
        clipacc <= clipacc | cl_t2;
        if (nlms_r && !bypass_w && uen_r) begin
          state <= S_DIVI;                     // t2_r/eden_r live next cycle
        end else begin
          g_r   <= !uen_r ? 20'sd0 : (nlms_r ? 20'sd0 : {{2{t2_w[17]}}, t2_w});
          k     <= 0;
          state <= S_UPD;
        end
      end
      S_DIVI: if (dv_sr) state <= S_DIVW;
      S_DIVW: if (dv_mv) begin
        g_r     <= dv_q;
        clipacc <= clipacc | dv_usr[0] | dv_usr[1];
        k       <= 0;
        state   <= S_UPD;
      end
      S_UPD: begin
        if (k < taps_r) begin
          coef[k] <= c_w;
          clipacc <= clipacc | cl_c;
        end
        if (k == taps_r - 1) begin k <= 0; state <= S_OUT; end
        else k <= k + 1'b1;
      end
      S_OUT: begin
        m_tdata  <= {e_r, y_r};
        m_tuser  <= {bypass_r, clipacc};
        m_tvalid <= 1;
        state    <= S_IDLE;
      end
      default: state <= S_IDLE;
    endcase
    if (cw_en && cw_addr < NTAPS) coef[cw_addr] <= cw_data;   // host write wins
  end
end
endmodule

// ===========================================================================
// IMPL=1 : parallel pipelined core, II=1.
// Rigid global-enable pipeline: adv = !m_tvalid || m_tready.  Every stage
// (input history, energy accumulator, divider, output register) advances only
// on adv, so pipeline position = fixed number of adv-edges and results are
// invariant under backpressure.
//
// Edge budget (accept at edge E, NTAPS>=2, NL=ceil(log2(NTAPS))):
//   E+1          products prod[k]=coef[k]*xv[k]      (NTAPS mults)
//   E+2..E+1+NL  adder-tree levels -> acc            (NL stages)
//   E+2+NL       y / e / flags stage
//   E+3+NL       t2 = RNE(mu*e/2^15) stage           (1 mult)
//   E+4+NL       divider input transfer (NLMS only, committing samples);
//                metadata mirror dm[0]
//   E+30+NL      fp_div_pipe m_tvalid (AW+FB=26 stages + input edge)
//   E+31+NL      commit edge: coef[k] += RNE(g*xv[k]>>sh) (NTAPS mults);
//                output register written; quotient front consumed
//   output transfer earliest at edge E+32+NL -> latency NL+32, II=1.
// Energy: incremental window sum of squares over the last `taps` accepted
// samples, 2 shared-form multipliers per accept.  Total 2*NTAPS+3 instances.
// ===========================================================================
module lms_parallel #(parameter integer NTAPS=8, parameter integer MULT_DSP=1)(
  input  wire        clk,
  input  wire        rst_n,
  input  wire [31:0] s_tdata,
  input  wire        s_tvalid,
  output wire        s_tready,
  output reg  [31:0] m_tdata,
  output reg  [1:0]  m_tuser,
  output reg         m_tvalid,
  input  wire        m_tready,
  input  wire        cfg_valid,
  output wire        cfg_ready,
  input  wire [6:0]  cfg_taps,
  input  wire [15:0] cfg_mu,
  input  wire        cfg_nlms,
  input  wire        cfg_update_en,
  input  wire [19:0] cfg_floor,
  input  wire        cfg_coef_clr,
  output reg         cfg_done,
  output reg         cfg_error,
  input  wire        cw_en,
  input  wire [6:0]  cw_addr,
  input  wire signed [23:0] cw_data,
  input  wire        rb_en,
  input  wire [6:0]  rb_addr,
  output reg         rb_valid,
  output reg  signed [23:0] rb_data
);
localparam integer NL    = (NTAPS > 1) ? $clog2(NTAPS) : 1;
localparam integer DMLEN = 27;               // metadata mirror stages
localparam integer DMB   = NTAPS*16 + 74;    // xv | y e eden t2 clip bypass

reg [6:0]  taps_r; reg [15:0] mu_r; reg nlms_r, uen_r; reg [19:0] floor_r;
reg signed [23:0] coef [0:NTAPS-1];
reg signed [15:0] xsh  [0:NTAPS-1];          // accept-shifted sample history
reg        [36:0] E_sum;

integer i, j;

// ---- stage registers -------------------------------------------------------
reg               v0;
reg signed [15:0] xv0   [0:NTAPS-1];
reg signed [15:0] d0;
reg        [19:0] eden0;

reg               v1;
reg signed [47:0] prod1 [0:NTAPS-1];
reg signed [15:0] xv1   [0:NTAPS-1];
reg signed [15:0] d1;
reg        [19:0] eden1;

reg        [NL-1:0] vt;
reg signed [47:0] tr    [0:NL*NTAPS-1];      // tr[j*NTAPS+i]
reg signed [15:0] xvt   [0:NL*NTAPS-1];
reg signed [15:0] dt    [0:NL-1];
reg        [19:0] edent [0:NL-1];

reg               ve, ce;
reg signed [15:0] y_e, e_e;
reg signed [15:0] xve   [0:NTAPS-1];
reg        [19:0] eden_e;

reg               v2, c2, bp2;
reg signed [15:0] y2, e2;
reg signed [15:0] xv2   [0:NTAPS-1];
reg signed [17:0] t2_2;
reg        [19:0] eden2;

reg        [DMB-1:0] dm  [0:DMLEN-1];
reg        [DMLEN-1:0] dmv;

// ---- handshake --------------------------------------------------------------
wire adv     = !m_tvalid || m_tready;
wire vt_any = |vt;
wire dv_any = |dmv;
wire cbusy  = v0 | v1 | vt_any | ve | v2 | dv_any;
assign s_tready  = rst_n && !cfg_valid && adv;
assign cfg_ready = rst_n && !m_tvalid && !cbusy;
wire   accept = s_tvalid && s_tready;
wire signed [15:0] x_in = s_tdata[15:0];
wire signed [15:0] d_in = s_tdata[31:16];

// ---- accept-edge energy increment (2 shared-form multipliers) ---------------
wire signed [15:0] x_leave = xsh[taps_r - 7'd1];
wire signed [43:0] sq_new, sq_old;
lms_mul2420 #(.MULT_DSP(MULT_DSP)) u_sqn(
  .a({{8{x_in[15]}}, x_in}), .b({{4{x_in[15]}}, x_in}), .p(sq_new));
lms_mul2420 #(.MULT_DSP(MULT_DSP)) u_sqo(
  .a({{8{x_leave[15]}}, x_leave}), .b({{4{x_leave[15]}}, x_leave}), .p(sq_old));
wire [36:0] E_next   = E_sum + {6'd0, sq_new[30:0]} - {6'd0, sq_old[30:0]};
wire [20:0] eden_pre = {1'b0, E_next[36:16]};
wire [19:0] eden0_w  = (eden_pre > 21'hFFFFF) ? 20'hFFFFF : eden_pre[19:0];

// ---- divider-mirror bundle unpack (last stage) ------------------------------
// bundle layout (pack2): [NTAPS*16-1:0]=xv | bp | c | t2pad20 | eden20 | e16 | y16
wire [DMB-1:0] dm_last = dm[DMLEN-1];
wire               dm_bp = dm_last[NTAPS*16+0];
wire               dm_c  = dm_last[NTAPS*16+1];
wire signed [17:0] dm_t2 = dm_last[NTAPS*16+19 : NTAPS*16+2];
wire signed [15:0] dm_e  = dm_last[NTAPS*16+57 -: 16];
wire signed [15:0] dm_y  = dm_last[NTAPS*16+73 -: 16];
wire signed [15:0] dm_xv [0:NTAPS-1];
wire               sh5   = nlms_r;          // NLMS shift 5, LMS shift 11

// ---- quotient reorder queue + divider ----------------------------------------
// fp_div_pipe cannot back-pressure its internal stages: its advance is
// self-derived (!m_tvalid || m_tready), so during a downstream stall it may
// emit a quotient earlier than the matching dm entry reaches dm[DMLEN-1].
// Quotient demand is therefore decoupled through a small in-order queue: the
// divider output slot plus a hold FIFO.  Feeding only samples that will
// actually commit (nlms && uen && !bypass) gives a strict 1:1 quotient/commit
// pairing; at most DMLEN+2 quotients can be outstanding, so a depth-32 hold
// can never fill and a feed can never be blocked.
wire        dv_mv; wire [19:0] dv_q; wire [1:0] dv_usr;
wire [19:0] eden_div = (eden2 == 0) ? 20'd1 : eden2;
wire        div_feed = adv && v2 && nlms_r && uen_r && !bp2;
localparam integer HQN = 32;
reg signed [19:0] hq_q [0:HQN-1];
reg        [1:0]  hq_u [0:HQN-1];
reg        [4:0]  hq_rd, hq_wr;
reg        [5:0]  hq_cnt;
wire        hq_emp  = (hq_cnt == 0);
wire        hq_full = (hq_cnt == 6'd32);
wire signed [19:0] q_fq  = hq_emp ? dv_q   : hq_q[hq_rd];
wire        [1:0]  q_fu  = hq_emp ? dv_usr : hq_u[hq_rd];
fp_div_pipe #(.AW(18), .BW(21), .FB(8), .OUT_W(20)) u_div (
  .clk(clk), .rst_n(rst_n),
  .s_tdata({1'b0, eden_div, t2_2}),
  .s_tvalid(div_feed), .s_tready(),
  .m_tdata(dv_q), .m_tuser(dv_usr), .m_tvalid(dv_mv),
  .m_tready(adv && !hq_full));

// effective scalar gain for the commit stage: oldest pending quotient (NLMS)
// or the metadata-carried t2 (LMS)
wire signed [19:0] g_eff = nlms_r ? q_fq : {{2{dm_t2[17]}}, dm_t2};
wire commit = adv && dmv[DMLEN-1] && uen_r && !dm_bp;
wire qpop   = commit && nlms_r && !hq_emp;       // consume hold entry
wire qdir   = commit && nlms_r &&  hq_emp;       // consume dv output in place
wire qpush  = adv && dv_mv && !qdir && !hq_full; // retire output into hold
wire dcl    = nlms_r && !dm_bp && (q_fu[0] | q_fu[1]);   // divider clip

// ---- per-tap combinational product/commit network ---------------------------
wire signed [43:0] pm   [0:NTAPS-1];        // coef[k]*xv0[k]
wire signed [43:0] upm  [0:NTAPS-1];        // g_eff*dm_xv[k]
wire signed [63:0] udl  [0:NTAPS-1];        // RNE(upm/2^sh)
wire signed [63:0] ucs  [0:NTAPS-1];        // coef[k]+delta
wire               uclp [0:NTAPS-1];
wire signed [23:0] ucnew[0:NTAPS-1];
wire signed [63:0] t2f;                     // RNE(mu*e/2^15) pre-sat
genvar gk;
generate for (gk = 0; gk < NTAPS; gk = gk + 1) begin: gprod
  assign dm_xv[gk] = dm_last[16*gk +: 16];
  lms_mul2420 #(.MULT_DSP(MULT_DSP)) u_pm(
    .a(coef[gk]), .b({{4{xv0[gk][15]}}, xv0[gk]}), .p(pm[gk]));
  lms_mul2420 #(.MULT_DSP(MULT_DSP)) u_um(
    .a({{4{g_eff[19]}}, g_eff}), .b({{4{dm_xv[gk][15]}}, dm_xv[gk]}), .p(upm[gk]));
  lms_rne64 u_ur(.v({{20{upm[gk][43]}}, upm[gk]}), .s(sh5 ? 7'd5 : 7'd11),
                 .q(udl[gk]));
  assign ucs[gk]  = {{40{coef[gk][23]}}, coef[gk]} + udl[gk];
  assign uclp[gk] = (ucs[gk] > 64'sd8388607) || (ucs[gk] < -64'sd8388608);
  assign ucnew[gk]= uclp[gk] ? (ucs[gk][63] ? -24'sd8388608 : 24'sd8388607)
                             : ucs[gk][23:0];
end endgenerate

// ---- t2 multiplier -----------------------------------------------------------
wire signed [43:0] t2p;
lms_mul2420 #(.MULT_DSP(MULT_DSP)) u_t2(
  .a({{8{e_e[15]}}, e_e}), .b({4'b0, mu_r}), .p(t2p));
lms_rne64 u_t2r(.v({{20{t2p[43]}}, t2p}), .s(7'd15), .q(t2f));
wire        cl_t2 = (t2f > 64'sd131071) || (t2f < -64'sd131072);
wire signed [17:0] t2w = cl_t2 ? (t2f[63] ? -18'sd131072 : 18'sd131071)
                               : t2f[17:0];

// ---- e-stage combinational ---------------------------------------------------
wire signed [63:0] acc_w = {{16{tr[NL*NTAPS-NTAPS][47]}}, tr[NL*NTAPS-NTAPS]};
wire signed [63:0] yf;
lms_rne64 u_ry(.v(acc_w), .s(7'd20), .q(yf));
wire        cl_y = (yf > 64'sd32767) || (yf < -64'sd32768);
wire signed [15:0] y_w = cl_y ? (yf[63] ? -16'sd32768 : 16'sd32767) : yf[15:0];
wire signed [16:0] epr = {dt[NL-1][15], dt[NL-1]} - {y_w[15], y_w};
wire        cl_e = (epr > 17'sd32767) || (epr < -17'sd32768);
wire signed [15:0] e_w = cl_e ? (epr[16] ? -16'sd32768 : 16'sd32767) : epr[15:0];
wire [19:0] floor_eff = (floor_r == 0) ? 20'd1 : floor_r;

wire [NTAPS-1:0] uclp_m;
genvar gk2;
generate for (gk2 = 0; gk2 < NTAPS; gk2 = gk2 + 1) begin: gcm
  assign uclp_m[gk2] = (gk2 < taps_r) && uclp[gk2];
end endgenerate
wire cclip = |uclp_m;

always @(posedge clk) begin
  if (!rst_n) begin
    m_tvalid <= 0; cfg_done <= 0; cfg_error <= 0;
    taps_r <= NTAPS[6:0]; mu_r <= 16'h2000; nlms_r <= 0; uen_r <= 1;
    floor_r <= 20'd64;
    rb_valid <= 0; rb_data <= 0; E_sum <= 0;
    v0 <= 0; v1 <= 0; ve <= 0; v2 <= 0; vt <= 0; dmv <= 0;
    hq_cnt <= 0; hq_rd <= 0; hq_wr <= 0;
    for (i = 0; i < NTAPS; i = i + 1) begin coef[i] <= 0; xsh[i] <= 0; end
  end else begin
    cfg_done <= 0; cfg_error <= 0; rb_valid <= 0;
    if (rb_en) begin
      rb_valid <= 1;
      rb_data  <= (rb_addr < NTAPS) ? coef[rb_addr] : 24'sd0;
    end
    if (cfg_valid && cfg_ready) begin
      cfg_done <= 1;
      if (cfg_taps < 1 || cfg_taps > NTAPS) begin
        cfg_error <= 1;
      end else begin
        taps_r <= cfg_taps; mu_r <= cfg_mu; nlms_r <= cfg_nlms;
        uen_r <= cfg_update_en; floor_r <= cfg_floor;
        E_sum <= 0;
        for (i = 0; i < NTAPS; i = i + 1) xsh[i] <= 0;
        if (cfg_coef_clr) for (i = 0; i < NTAPS; i = i + 1) coef[i] <= 0;
      end
    end
    if (adv) begin
      // -------- output / commit edge --------
      m_tvalid <= dmv[DMLEN-1];
      if (dmv[DMLEN-1]) begin
        m_tdata <= {dm_e, dm_y};
        m_tuser <= {dm_bp, dm_c | (commit ? (dcl | cclip) : 1'b0)};
      end
      // -------- stage 0 --------
      v0 <= accept;
      if (accept) begin
        d0    <= d_in;
        eden0 <= eden0_w;
        E_sum <= E_next;
        xsh[0] <= x_in;
        xv0[0] <= x_in;
        for (i = 1; i < NTAPS; i = i + 1) begin
          xsh[i] <= xsh[i-1];
          xv0[i] <= xsh[i-1];
        end
      end
      // -------- stage 1: products --------
      v1 <= v0;
      if (v0) begin
        d1 <= d0; eden1 <= eden0;
        for (i = 0; i < NTAPS; i = i + 1) begin
          xv1[i]   <= xv0[i];
          prod1[i] <= (i < taps_r) ? {{4{pm[i][43]}}, pm[i]} : 48'sd0;
        end
      end
      // -------- adder-tree levels --------
      for (j = 0; j < NL; j = j + 1) begin
        vt[j]    <= (j == 0) ? v1    : vt[j-1];
        dt[j]    <= (j == 0) ? d1    : dt[j-1];
        edent[j] <= (j == 0) ? eden1 : edent[j-1];
        for (i = 0; i < NTAPS; i = i + 1) begin
          xvt[j*NTAPS+i] <= (j == 0) ? xv1[i] : xvt[(j-1)*NTAPS+i];
          if (i < ((NTAPS + (1 << (j+1)) - 1) >> (j+1)))
            tr[j*NTAPS+i] <=
              ((j == 0) ? prod1[2*i] : tr[(j-1)*NTAPS+2*i]) +
              (((2*i+1) < ((NTAPS + (1 << j) - 1) >> j)) ?
               ((j == 0) ? prod1[2*i+1] : tr[(j-1)*NTAPS+2*i+1]) : 48'sd0);
        end
      end
      // -------- error stage --------
      ve <= vt[NL-1];
      if (vt[NL-1]) begin
        y_e <= y_w; e_e <= e_w; eden_e <= edent[NL-1];
        ce  <= cl_y | cl_e;
        for (i = 0; i < NTAPS; i = i + 1) xve[i] <= xvt[(NL-1)*NTAPS+i];
      end
      // -------- t2 stage --------
      v2 <= ve;
      if (ve) begin
        y2 <= y_e; e2 <= e_e; eden2 <= eden_e; t2_2 <= t2w;
        c2  <= ce | cl_t2;
        bp2 <= nlms_r && (eden_e < floor_eff);
        for (i = 0; i < NTAPS; i = i + 1) xv2[i] <= xve[i];
      end
      // -------- divider mirror --------
      dmv[0] <= v2;
      if (v2) dm[0] <= pack2();
      for (i = 1; i < DMLEN; i = i + 1) begin
        dmv[i] <= dmv[i-1];
        if (dmv[i-1]) dm[i] <= dm[i-1];
      end
      // -------- quotient reorder queue --------
      if (qpush) begin
        hq_q[hq_wr] <= dv_q; hq_u[hq_wr] <= dv_usr;
        hq_wr <= hq_wr + 5'd1;
      end
      if (qpop) hq_rd <= hq_rd + 5'd1;
      hq_cnt <= hq_cnt + (qpush ? 6'd1 : 6'd0) - (qpop ? 6'd1 : 6'd0);
    end
    // -------- coefficient commit (uses dm_last + divider output) ------------
    if (commit) begin
      for (i = 0; i < NTAPS; i = i + 1)
        if (i < taps_r) coef[i] <= ucnew[i];
    end
    if (cw_en && cw_addr < NTAPS) coef[cw_addr] <= cw_data;  // host write wins
  end
end

function [DMB-1:0] pack2;
  integer t;
  begin
    for (t = 0; t < NTAPS; t = t + 1) pack2[16*t +: 16] = xv2[t];
    pack2[DMB-1:NTAPS*16] = {y2, e2, eden2, {2'b0, t2_2}, c2, bp2};
  end
endfunction
endmodule
