// ============================================================================
// duc_stream.sv -- DSP-03 digital up-conversion chain.
//
//   signed16 Q1.15 complex I/Q pair stream in (low rate fs_in)
//     -> serialized symmetric compensation/shaping FIR (1:1 at low rate)
//     -> CIC interpolator: N combs at fs_in, zero-stuffed xR burst, then
//        N integrators at output rate (order CIC_STAGES 1..4 static,
//        runtime R 2..64)
//     -> programmable >>shift (round-nearest-even) + saturate to 16 bits
//     -> complex mix by NCO  x*(cos + j*sin)  (3-multiplier form)
//     -> signed16 I/Q pair stream out at R*fs_in.
//
// Rate contract: every accepted input pair produces exactly R output
// transfers (N inputs -> N*R outputs).  Outputs stream back-to-back inside
// a burst (II=1) when downstream keeps ready; the honest sustained input
// interval is max(R, 2*U+3) clocks (the shared-MAC FIR dominates for small
// R).  No tail flush; the trailing FIR convolution terms are not emitted.
//
// Images: the pre-CIC FIR runs at the LOW rate and cannot remove spectral
// images at k*fs_in.  Image attenuation comes only from the CIC sinc^N
// rolloff (nulls at multiples of fs_in); residual images at
// f_lo +/- k*fs_in are expected and measured by the testbench.  For deeper
// rejection chain halfband_interp/polyphase_resampler upstream.
//
// Bit growth: CIC gain R^N, M=1; 40-bit internal width covers R<=64, N<=4
// (16 + 4*6 = 40) with Hogenauer wrap arithmetic.
//
// cfg contract is identical to ddc_stream: atomic commit, clears all state,
// cfg_error on illegal fields, NCO phase reloaded from cfg_phase_init.
// Reuse provenance: NCO follows dsp_20k/src/dds_nco.v; CIC follows
// sigproc_20k/src/cic_dec8.v generalized to interpolation; FIR mirrors
// dsp/halfband/rtl/cic_comp_fir.sv arithmetic via rtl/ddcduc_iq_fir.sv.
// DSP usage: 1 (FIR) + 3 (mixer) = 4 multiplier-class cells.
// Single clk, synchronous active-low rst_n.
// ============================================================================
module duc_stream #(
    parameter integer CIC_STAGES = 3     // 1..4
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire signed [15:0] s_i_tdata,
    input  wire signed [15:0] s_q_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    output reg  signed [15:0] m_i_tdata,
    output reg  signed [15:0] m_q_tdata,
    output reg         m_clip,
    output reg         m_tvalid,
    input  wire        m_tready,
    input  wire        cfg_valid,
    output wire        cfg_ready,
    input  wire [31:0] cfg_phase_inc,
    input  wire [31:0] cfg_phase_init,
    input  wire [6:0]  cfg_rate,
    input  wire [5:0]  cfg_shift,
    input  wire [5:0]  cfg_taps,
    input  wire [287:0] cfg_coeffs,
    output reg         cfg_done,
    output reg         cfg_error,
    output reg  [15:0] input_count,
    output reg  [31:0] output_count,
    output reg  [15:0] sat_count
);
    localparam integer W = 40;

    // ------------------------------------------------- configuration ----
    reg [31:0] inc_r, init_r;
    reg [6:0]  rate_r;
    reg [5:0]  shift_r, taps_r;
    reg [287:0] coef_r;

    wire cfg_legal = (cfg_rate >= 7'd2) && (cfg_rate <= 7'd64) &&
                     (cfg_shift <= 6'd24) &&
                     (cfg_taps == 6'd1 ||
                      (cfg_taps[0] && cfg_taps >= 6'd3 && cfg_taps <= 6'd31));
    assign cfg_ready = rst_n;
    wire commit    = cfg_valid && cfg_ready;
    wire commit_ok = commit && cfg_legal;

    // -------------------------------------------------- head FIR --------
    wire signed [15:0] fir_mi, fir_mq;
    wire        fir_mclip, fir_mvalid, fir_mready, fir_sready;
    reg         pending;
    assign s_tready = rst_n && !cfg_valid && fir_sready;

    ddcduc_iq_fir #(.MAX_TAPS(31)) u_fir (
        .clk(clk), .rst_n(rst_n), .clr(commit_ok),
        .s_i_tdata(s_i_tdata), .s_q_tdata(s_q_tdata),
        .s_tvalid(s_tvalid && s_tready), .s_tready(fir_sready),
        .m_i_tdata(fir_mi), .m_q_tdata(fir_mq), .m_clip(fir_mclip),
        .m_tvalid(fir_mvalid), .m_tready(fir_mready),
        .taps(taps_r), .coeffs(coef_r), .busy()
    );
    assign fir_mready = !pending;
    wire fir_fire = fir_mvalid && fir_mready;

    // ---------------------------------------------- combs at low rate ---
    // Comb cascade evaluated once per FIR output; integrators run per
    // emitted output beat.  All chains use blocking temporaries inside the
    // clocked process -- no combinational reads of the state arrays.
    reg signed [W-1:0] cdel_i [0:CIC_STAGES-1];
    reg signed [W-1:0] cdel_q [0:CIC_STAGES-1];
    integer ki;
    reg signed [W-1:0] ti, tq;
    reg signed [W-1:0] vlow_i, vlow_q;

    // --------------------------------------- burst into integrators -----
    reg        emitting;
    reg [6:0]  emit_cnt;
    reg signed [W-1:0] integ_i [0:CIC_STAGES-1];
    reg signed [W-1:0] integ_q [0:CIC_STAGES-1];

    wire signed [W-1:0] beat_i = (emit_cnt == 7'd0) ? vlow_i : {W{1'b0}};
    wire signed [W-1:0] beat_q = (emit_cnt == 7'd0) ? vlow_q : {W{1'b0}};
    reg fire_clip;      // clip event of the last emitted beat (1-cycle lag)

    // ------------------------------------------- scale + mixer pipe -----
    function signed [15:0] scale_sat;
        input signed [W-1:0] v;
        input [5:0]          s;
        reg signed [W-1:0]   q;
        reg [W-1:0]          rem, half;
        reg                  roundup;
        begin
            if (s == 6'd0) begin
                q = v;
            end else begin
                q       = v >>> s;
                rem     = v & ((40'd1 << s) - 40'd1);
                half    = 40'd1 << (s - 6'd1);
                roundup = (rem > half) || (rem == half && q[0]);
                if (roundup) q = q + 40'sd1;
            end
            if (q > 40'sd32767)        scale_sat = 16'sh7fff;
            else if (q < -40'sd32768)  scale_sat = 16'sh8000;
            else                       scale_sat = q[15:0];
        end
    endfunction
    function clip40;
        input signed [W-1:0] v;
        input [5:0]          s;
        reg signed [W-1:0]   q;
        reg [W-1:0]          rem, half;
        reg                  roundup;
        begin
            if (s == 6'd0) q = v;
            else begin
                q       = v >>> s;
                rem     = v & ((40'd1 << s) - 40'd1);
                half    = 40'd1 << (s - 6'd1);
                roundup = (rem > half) || (rem == half && q[0]);
                if (roundup) q = q + 40'sd1;
            end
            clip40 = (q > 40'sd32767) || (q < -40'sd32768);
        end
    endfunction

    // mix pipe stage p1: holds the scaled baseband pair + LO snapshot
    reg signed [15:0] pvi, pvq, pc1, ps1;
    reg               p1v;
    wire adv_out = !m_tvalid || m_tready;
    wire p1_free = !p1v || adv_out;
    wire fire    = p1_free && (emitting || pending);

    wire signed [15:0] nco_s, nco_c;
    wire [31:0]        nco_phase;
    ddcduc_nco u_nco (
        .clk(clk), .rst_n(rst_n),
        .load(commit_ok), .step(fire),
        .phase_inc(inc_r), .phase_init(cfg_phase_init),
        .sin_out(nco_s), .cos_out(nco_c), .phase_out(nco_phase)
    );

    // stage p2 -> output: 3-multiplier complex product  x*(cos + j sin)
    //   m1=(xi+xq)*s  m2=xi*(c+s)  m3=xq*(c-s)  i'=m2-m1  q'=m3+m1
    wire signed [16:0] d_x   = {pvi[15], pvi} + {pvq[15], pvq};
    wire signed [16:0] e_cp  = {pc1[15], pc1} + {ps1[15], ps1};
    wire signed [16:0] e_cm  = {pc1[15], pc1} - {ps1[15], ps1};
    wire signed [32:0] p_1   = d_x * ps1;
    wire signed [32:0] p_2   = pvi * e_cp;
    wire signed [32:0] p_3   = pvq * e_cm;
    wire signed [33:0] iacc  = {p_2[32], p_2} - {p_1[32], p_1};
    wire signed [33:0] qacc  = {p_3[32], p_3} + {p_1[32], p_1};

    function signed [15:0] rne_sat34;
        input signed [33:0] v;
        reg signed [19:0] q;
        reg [14:0] r;
        begin
            q = v >>> 15;
            r = v[14:0];
            if (r > 15'd16384 || (r == 15'd16384 && q[0])) q = q + 20'sd1;
            if (q > 20'sd32767)       rne_sat34 = 16'sh7fff;
            else if (q < -20'sd32768) rne_sat34 = 16'sh8000;
            else                      rne_sat34 = q[15:0];
        end
    endfunction
    function clip34;
        input signed [33:0] v;
        reg signed [19:0] q;
        reg [14:0] r;
        begin
            q = v >>> 15;
            r = v[14:0];
            if (r > 15'd16384 || (r == 15'd16384 && q[0])) q = q + 20'sd1;
            clip34 = (q > 20'sd32767) || (q < -20'sd32768);
        end
    endfunction

    wire mix_clip_now = adv_out && p1v &&
                        (clip34(iacc) | clip34(qacc));
    wire [1:0] sat_inc = (fire_clip ? 2'd1 : 2'd0) +
                         (mix_clip_now ? 2'd1 : 2'd0) +
                         ((fir_fire && fir_mclip) ? 2'd1 : 2'd0);
    wire [16:0] sat_sum = {1'b0, sat_count} + {15'd0, sat_inc};
    wire out_fire = m_tvalid && m_tready;

    // ------------------------------------------------------------ regs ---
    always @(posedge clk) begin
        if (!rst_n) begin
            inc_r <= 32'h2000_0000; init_r <= 32'd0;
            rate_r <= 7'd8; shift_r <= 6'd9; taps_r <= 6'd1;
            coef_r <= 288'd0;
            cfg_done <= 1'b0; cfg_error <= 1'b0;
            input_count <= 16'd0; output_count <= 32'd0;
            sat_count <= 16'd0;
            pending <= 1'b0; emitting <= 1'b0; emit_cnt <= 7'd0;
            vlow_i <= {W{1'b0}}; vlow_q <= {W{1'b0}};
            p1v <= 1'b0; fire_clip <= 1'b0;
            pvi <= 16'sd0; pvq <= 16'sd0; pc1 <= 16'sd0; ps1 <= 16'sd0;
            m_tvalid <= 1'b0; m_i_tdata <= 16'sd0; m_q_tdata <= 16'sd0;
            m_clip <= 1'b0;
            for (ki = 0; ki < CIC_STAGES; ki = ki + 1) begin
                cdel_i[ki] <= {W{1'b0}}; cdel_q[ki] <= {W{1'b0}};
                integ_i[ki] <= {W{1'b0}}; integ_q[ki] <= {W{1'b0}};
            end
        end else begin
            cfg_done <= 1'b0; cfg_error <= 1'b0;
            if (commit) begin
                cfg_done <= 1'b1;
                if (!cfg_legal) cfg_error <= 1'b1;
            end
            if (commit_ok) begin
                inc_r <= cfg_phase_inc; init_r <= cfg_phase_init;
                rate_r <= cfg_rate; shift_r <= cfg_shift;
                taps_r <= cfg_taps; coef_r <= cfg_coeffs;
                input_count <= 16'd0; output_count <= 32'd0;
                sat_count <= 16'd0;
                pending <= 1'b0; emitting <= 1'b0; emit_cnt <= 7'd0;
                p1v <= 1'b0; m_tvalid <= 1'b0; fire_clip <= 1'b0;
                for (ki = 0; ki < CIC_STAGES; ki = ki + 1) begin
                    cdel_i[ki] <= {W{1'b0}}; cdel_q[ki] <= {W{1'b0}};
                    integ_i[ki] <= {W{1'b0}}; integ_q[ki] <= {W{1'b0}};
                end
            end else begin
                fire_clip <= 1'b0;          // one-cycle clip-event flag
                // low-rate comb stage consumes one FIR pair
                if (fir_fire) begin
                    ti = {{24{fir_mi[15]}}, fir_mi};
                    tq = {{24{fir_mq[15]}}, fir_mq};
                    for (ki = 0; ki < CIC_STAGES; ki = ki + 1) begin
                        cdel_i[ki] <= ti;
                        ti = ti - cdel_i[ki];
                        cdel_q[ki] <= tq;
                        tq = tq - cdel_q[ki];
                    end
                    vlow_i  <= ti;
                    vlow_q  <= tq;
                    pending <= 1'b1;
                end else if (fire && !emitting)
                    pending <= 1'b0;

                // high-rate emit engine + integrators
                if (p1_free) begin
                    p1v <= fire;
                    if (fire) begin
                        ti = beat_i;
                        tq = beat_q;
                        for (ki = 0; ki < CIC_STAGES; ki = ki + 1) begin
                            integ_i[ki] <= integ_i[ki] + ti;
                            ti = integ_i[ki] + ti;
                            integ_q[ki] <= integ_q[ki] + tq;
                            tq = integ_q[ki] + tq;
                        end
                        pvi <= scale_sat(ti, shift_r);
                        pvq <= scale_sat(tq, shift_r);
                        fire_clip <= clip40(ti, shift_r) ||
                                     clip40(tq, shift_r);
                        pc1 <= nco_c; ps1 <= nco_s;
                        if (emitting) begin
                            if (emit_cnt == rate_r - 7'd1) begin
                                emitting <= 1'b0; emit_cnt <= 7'd0;
                            end else emit_cnt <= emit_cnt + 7'd1;
                        end else begin
                            emitting <= (rate_r != 7'd1);
                            emit_cnt <= 7'd1;
                        end
                    end
                end

                // output stage: p1 -> m through the mixer
                if (adv_out) begin
                    m_tvalid <= p1v;
                    if (p1v) begin
                        m_i_tdata <= rne_sat34(iacc);
                        m_q_tdata <= rne_sat34(qacc);
                        m_clip    <= clip34(iacc) | clip34(qacc);
                    end
                end

                if (s_tvalid && s_tready && input_count != 16'hffff)
                    input_count <= input_count + 16'd1;
                if (out_fire && output_count != 32'hffff_ffff)
                    output_count <= output_count + 32'd1;
                if (sat_inc != 2'd0)
                    sat_count <= (sat_sum > 17'hffff) ? 16'hffff
                                                      : sat_sum[15:0];
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (CIC_STAGES < 1 || CIC_STAGES > 4)
            $fatal(1, "unsupported static configuration");
    end
`endif
endmodule
