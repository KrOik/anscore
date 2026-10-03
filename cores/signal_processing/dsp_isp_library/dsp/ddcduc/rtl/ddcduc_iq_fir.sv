// ============================================================================
// ddcduc_iq_fir.sv -- shared dual-channel serialized symmetric FIR for the
// DSP-03 DDC/DUC chains (compensation / pulse-shaping stage, 1:1 rate).
//
//   One I/Q sample pair in -> one I/Q pair out.  A SINGLE shared multiplier
//   iterates U unique symmetric coefficients for channel I then channel Q:
//   y[c][n] = sum_{j<U-1} g[j]*(x[c][n-j] + x[c][n-(T-1-j)])
//             + g[U-1]*x[c][n-(U-1)]            (T odd, U=(T+1)/2)
//   Per pair the engine spends 2*U MAC cycles plus 2 handshake cycles, so
//   sustained pair interval is 2*U+3 clocks -- a serialized-MAC contract,
//   NOT II=1 (documented in SPEC.md).
//
//   taps==1 selects an identity bypass (coefficients ignored, pair passes
//   through with one cycle latency); taps must otherwise be odd in 3..31.
//   taps/coeffs are plain synchronous inputs owned by the parent core's
//   atomic configuration; `clr` is a synchronous state clear (parent uses
//   it on config commit).  Round-nearest-even then saturate once at output;
//   m_clip flags a beat whose value saturated.  Outputs hold under
//   backpressure.  Single clk, synchronous active-low rst_n.
//
//   Structure mirrors dsp/halfband/rtl/cic_comp_fir.sv folded-pair shared-
//   MAC arithmetic (signed17 pair sums x signed18 coefficients), shrunk to
//   one multiplier lane serving two channels.  That core's contract is
//   unchanged; this is an independent module.
// ============================================================================
module ddcduc_iq_fir #(
    parameter integer MAX_TAPS = 31          // odd, 3..31; U_MAX=(MAX_TAPS+1)/2
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clr,                  // synchronous state clear
    input  wire signed [15:0] s_i_tdata,
    input  wire signed [15:0] s_q_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    output reg  signed [15:0] m_i_tdata,
    output reg  signed [15:0] m_q_tdata,
    output reg         m_clip,
    output reg         m_tvalid,
    input  wire        m_tready,
    input  wire [5:0]  taps,                 // 1 (bypass) or odd 3..MAX_TAPS
    input  wire [(MAX_TAPS+1)/2*18-1:0] coeffs,
    output wire        busy
);
    localparam integer U_MAX = (MAX_TAPS + 1) / 2;
    localparam IDLE = 1'b0, MAC = 1'b1;

    reg state;
    reg signed [15:0] ih [0:MAX_TAPS-1];
    reg signed [15:0] qh [0:MAX_TAPS-1];
    reg [5:0]  tcount;                       // 0..2*U-1 within MAC
    reg [5:0]  u_latched;                    // U of the in-flight pair
    reg [5:0]  taps_latched;
    reg signed [41:0] acc_i, acc_q;

    assign busy  = (state != IDLE) || m_tvalid;
    assign s_tready = rst_n && !clr && (state == IDLE) && !m_tvalid;
    wire take = s_tvalid && s_tready;

    // --- shared-MAC operand for the current (channel, u index) ------------
    wire chq     = (tcount >= u_latched);                  // 0=I, 1=Q
    wire [5:0] j = chq ? (tcount - u_latched) : tcount;
    wire center  = (j == u_latched - 6'd1);
    wire signed [16:0] h_lo = chq ? {qh[j][15], qh[j]}
                                  : {ih[j][15], ih[j]};
    wire signed [16:0] h_hi = chq ? {qh[taps_latched - 6'd1 - j][15],
                                     qh[taps_latched - 6'd1 - j]}
                                  : {ih[taps_latched - 6'd1 - j][15],
                                     ih[taps_latched - 6'd1 - j]};
    wire signed [16:0] operand = center ? h_lo : (h_lo + h_hi);
    wire signed [17:0] coef = coeffs[18*j +: 18];
    wire signed [34:0] prod  = operand * coef;

    // --- round-nearest-even >>15 then signed16 saturate -------------------
    function signed [15:0] rne_sat;
        input signed [41:0] v;
        reg signed [27:0] q;
        reg [14:0] r;
        begin
            q = v >>> 15;
            r = v[14:0];
            if (r > 15'd16384 || (r == 15'd16384 && q[0]))
                q = q + 28'sd1;
            if (q > 28'sd32767)       rne_sat = 16'sh7fff;
            else if (q < -28'sd32768) rne_sat = 16'sh8000;
            else                      rne_sat = q[15:0];
        end
    endfunction
    function clips;
        input signed [41:0] v;
        reg signed [27:0] q;
        reg [14:0] r;
        begin
            q = v >>> 15;
            r = v[14:0];
            if (r > 15'd16384 || (r == 15'd16384 && q[0]))
                q = q + 28'sd1;
            clips = (q > 28'sd32767) || (q < -28'sd32768);
        end
    endfunction

    wire signed [41:0] acc_sel = chq ? acc_q : acc_i;
    wire signed [41:0] acc_n = acc_sel + {{7{prod[34]}}, prod};
    wire last_q = (tcount == {1'b0, u_latched} + u_latched - 6'd1);

    integer k;
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            state <= IDLE; tcount <= 6'd0; u_latched <= 6'd1;
            taps_latched <= 6'd1; acc_i <= 42'sd0; acc_q <= 42'sd0;
            m_tvalid <= 1'b0; m_i_tdata <= 16'sd0; m_q_tdata <= 16'sd0;
            m_clip <= 1'b0;
            for (k = 0; k < MAX_TAPS; k = k + 1) begin
                ih[k] <= 16'sd0; qh[k] <= 16'sd0;
            end
        end else begin
            if (m_tvalid && m_tready) m_tvalid <= 1'b0;
            if (take) begin
                for (k = MAX_TAPS - 1; k > 0; k = k - 1) begin
                    ih[k] <= ih[k-1];
                    qh[k] <= qh[k-1];
                end
                ih[0] <= s_i_tdata;
                qh[0] <= s_q_tdata;
                taps_latched <= taps;
                if (taps == 6'd1) begin
                    // identity bypass: exact pair, one cycle latency
                    m_i_tdata <= s_i_tdata;
                    m_q_tdata <= s_q_tdata;
                    m_clip    <= 1'b0;
                    m_tvalid  <= 1'b1;
                    state     <= IDLE;
                end else begin
                    u_latched  <= (taps + 6'd1) >> 1;
                    tcount     <= 6'd0;
                    acc_i      <= 42'sd0;
                    acc_q      <= 42'sd0;
                    state      <= MAC;
                end
            end else if (state == MAC) begin
                if (chq) acc_q <= acc_n; else acc_i <= acc_n;
                if (last_q) begin
                    m_i_tdata <= rne_sat(acc_i);       // I finished earlier
                    m_q_tdata <= rne_sat(acc_n);
                    m_clip    <= clips(acc_i) | clips(acc_n);
                    m_tvalid  <= 1'b1;
                    state     <= IDLE;
                    tcount    <= 6'd0;
                end else begin
                    tcount <= tcount + 6'd1;
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (MAX_TAPS < 3 || MAX_TAPS > 63 || !MAX_TAPS[0])
            $fatal(1, "unsupported static configuration");
    end
`endif
endmodule
