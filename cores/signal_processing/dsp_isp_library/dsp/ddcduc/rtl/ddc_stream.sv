// ============================================================================
// ddc_stream.sv -- DSP-03 digital down-conversion chain.
//
//   signed16 Q1.15 complex I/Q pair stream in  (s_i_tdata / s_q_tdata)
//     -> complex mix by NCO  x*(cos - j*sin)   (3-multiplier form, II=1)
//     -> CIC decimator, order CIC_STAGES (1..4 static), runtime rate R 2..64
//     -> programmable >>shift (round-nearest-even) + saturate to 16 bits
//     -> 8-pair skid FIFO -> serialized symmetric compensation FIR (1:1)
//     -> signed16 I/Q pair stream out at fs/R.
//
// Rate contract: every R-th accepted input produces exactly one decimated
// pair; the FIR is 1:1 causal, so N accepted inputs yield floor(N/R) output
// transfers.  There is no tail flush: the FIR's trailing T-1 convolution
// terms beyond the last input are not emitted (streaming truncation).
//
// Bit growth (documented in SPEC.md): CIC gain = R^N, M=1.  Internal CIC
// width is 40 bits, covering worst case R=64,N=4 (16 + 4*log2(64) = 40).
// Integrator/comb stages wrap modulo 2^40 per Hogenauer; the true result is
// provably inside 40 bits for all legal configurations, so wrapping never
// corrupts the (aligned) output word.
//
// cfg_valid/cfg_ready commits atomically and clears all datapath state
// (mixer pipe, CIC, FIFO, FIR history, counters, NCO phase).  Legal config:
// rate 2..64, shift 0..24, taps 1 (FIR bypass) or odd 3..31.  Illegal
// commits pulse cfg_error together with cfg_done and leave the running
// configuration/state untouched.  cfg_ready is always high out of reset;
// input acceptance is gated off during cfg_valid so a commit edge can never
// share an input transfer.
//
// Reuse: NCO structure follows cores/signal_processing/dsp/src/dds_nco.v (rewritten to
// the sync-reset Stream contract, quadrature case-ROM output); CIC order
// follows cores/signal_processing/transforms/src/cic_dec8.v generalized to (N<=4, R<=64);
// skid buffer instantiates infra/stream/stream_sync_fifo.v unchanged; the
// FIR mirrors dsp/halfband/rtl/cic_comp_fir.sv arithmetic conventions.
//
// DSP usage: 3 (mixer) + 1 (FIR) = 4 multiplier-class cells.  Single clk,
// synchronous active-low rst_n.
// ============================================================================
module ddc_stream #(
    parameter integer CIC_STAGES = 3,    // 1..4
    parameter integer FIFO_DEPTH = 8,
    parameter integer FIFO_REGS  = 0     // 1 => skid FIFO uses fabric regs
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire signed [15:0] s_i_tdata,
    input  wire signed [15:0] s_q_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    output wire signed [15:0] m_i_tdata,
    output wire signed [15:0] m_q_tdata,
    output wire        m_clip,
    output wire        m_tvalid,
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
    output reg  [15:0] sat_count,
    output reg         fifo_overflow
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
    wire commit      = cfg_valid && cfg_ready;
    wire commit_ok   = commit && cfg_legal;          // also the state clear

    // --------------------------------------------------- NCO / mixer ----
    wire signed [15:0] nco_s, nco_c;
    wire [31:0]        nco_phase;
    wire [$clog2(FIFO_DEPTH + 2) - 1:0] fifo_level;

    assign s_tready = rst_n && !cfg_valid && (fifo_level <= FIFO_DEPTH - 4);
    wire accept = s_tvalid && s_tready;

    ddcduc_nco u_nco (
        .clk(clk), .rst_n(rst_n),
        .load(commit_ok), .step(accept),
        .phase_inc(inc_r), .phase_init(cfg_phase_init),
        .sin_out(nco_s), .cos_out(nco_c), .phase_out(nco_phase)
    );

    // mix pipe stage 1: capture sample + LO snapshot for this beat
    reg signed [15:0] x1i, x1q, c1, s1;
    reg v1;
    // mix pipe stage 2: 3-multiplier complex product  x*(cos - j sin)
    //   m1=(xi+xq)*s  m2=xi*(c-s)  m3=xq*(c+s)  i'=m1+m2  q'=m3-m1
    wire signed [16:0] d_x  = {x1i[15], x1i} + {x1q[15], x1q};
    wire signed [16:0] e_cm = {c1[15], c1} - {s1[15], s1};
    wire signed [16:0] e_cp = {c1[15], c1} + {s1[15], s1};
    wire signed [32:0] p1   = d_x  * s1;
    wire signed [32:0] p2   = x1i  * e_cm;
    wire signed [32:0] p3   = x1q  * e_cp;
    wire signed [33:0] iacc = {p1[32], p1} + {p2[32], p2};
    wire signed [33:0] qacc = {p3[32], p3} - {p1[32], p1};

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

    reg signed [15:0] i_mix, q_mix;
    reg v2, mix_clip;

    // ------------------------------------------------------- CIC ---------
    // Integrators run at the input rate (on mixer-valid beats), combs once
    // per R beats on the post-update accumulator.  All chains are computed
    // with blocking temporaries inside the clocked process; the decimated
    // (scaled, saturated) pair is REGISTERED and pushed to the skid FIFO one
    // cycle after the decimate event -- no combinational reads of the state
    // arrays exist anywhere (keeps iverilog -Wall quiet and Yosys clean).
    reg signed [W-1:0] integ  [0:CIC_STAGES-1];
    reg signed [W-1:0] cdel   [0:CIC_STAGES-1];
    reg signed [W-1:0] integq [0:CIC_STAGES-1];
    reg signed [W-1:0] cdelq  [0:CIC_STAGES-1];
    reg [6:0] beat_cnt;

    integer ki;
    reg signed [W-1:0] ti, tq;          // clocked-block temporaries

    // registered decimation push slot
    reg               push_v, push_c;
    reg signed [15:0] push_i, push_q;

    // --- variable-shift round-nearest-even + saturate for the FIFO word ---
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



    // ------------------------------------------------ skid FIFO + FIR ---
    wire        fifo_sready;
    wire [31:0] fifo_mdata;
    wire        fifo_mvalid;
    wire        fir_sready;
    wire signed [15:0] fir_mi, fir_mq;
    wire        fir_mclip, fir_mvalid;

    stream_sync_fifo #(.DATA_WIDTH(32), .USER_WIDTH(1),
                       .RAM_DEPTH(FIFO_DEPTH), .MEM_REGS(FIFO_REGS)) u_skid (
        .clk(clk), .rst_n(rst_n && !commit_ok),
        .s_tdata({push_q, push_i}), .s_tuser(1'b0), .s_tlast(1'b0),
        .s_tvalid(push_v), .s_tready(fifo_sready),
        .m_tdata(fifo_mdata), .m_tuser(), .m_tlast(),
        .m_tvalid(fifo_mvalid), .m_tready(fir_sready),
        .level(fifo_level)
    );

    ddcduc_iq_fir #(.MAX_TAPS(31)) u_fir (
        .clk(clk), .rst_n(rst_n), .clr(commit_ok),
        .s_i_tdata(fifo_mdata[15:0]), .s_q_tdata(fifo_mdata[31:16]),
        .s_tvalid(fifo_mvalid), .s_tready(fir_sready),
        .m_i_tdata(fir_mi), .m_q_tdata(fir_mq), .m_clip(fir_mclip),
        .m_tvalid(fir_mvalid), .m_tready(m_tready),
        .taps(taps_r), .coeffs(coef_r), .busy()
    );
    assign m_i_tdata = fir_mi;
    assign m_q_tdata = fir_mq;
    assign m_clip    = fir_mclip;
    assign m_tvalid  = fir_mvalid;
    wire out_fire = fir_mvalid && m_tready;

    // saturation bookkeeping: up to 3 clip events per cycle (mixer beat,
    // decimator scale beat pushed to the FIFO, FIR output beat)
    wire [1:0] sat_inc = (v2 && mix_clip ? 2'd1 : 2'd0) +
                         (push_v && push_c ? 2'd1 : 2'd0) +
                         (out_fire && fir_mclip ? 2'd1 : 2'd0);
    wire [16:0] sat_sum = {1'b0, sat_count} + {15'd0, sat_inc};

    // ------------------------------------------------------------ regs ---
    always @(posedge clk) begin
        if (!rst_n) begin
            inc_r <= 32'h2000_0000; init_r <= 32'd0;
            rate_r <= 7'd8; shift_r <= 6'd9; taps_r <= 6'd1;
            coef_r <= 288'd0;
            cfg_done <= 1'b0; cfg_error <= 1'b0;
            input_count <= 16'd0; output_count <= 32'd0;
            sat_count <= 16'd0; fifo_overflow <= 1'b0;
            v1 <= 1'b0; v2 <= 1'b0; mix_clip <= 1'b0;
            x1i <= 16'sd0; x1q <= 16'sd0; c1 <= 16'sd0; s1 <= 16'sd0;
            i_mix <= 16'sd0; q_mix <= 16'sd0;
            beat_cnt <= 7'd0;
            push_v <= 1'b0; push_c <= 1'b0;
            push_i <= 16'sd0; push_q <= 16'sd0;
            for (ki = 0; ki < CIC_STAGES; ki = ki + 1) begin
                integ[ki] <= {W{1'b0}}; cdel[ki] <= {W{1'b0}};
                integq[ki] <= {W{1'b0}}; cdelq[ki] <= {W{1'b0}};
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
                sat_count <= 16'd0; fifo_overflow <= 1'b0;
                v1 <= 1'b0; v2 <= 1'b0; mix_clip <= 1'b0;
                beat_cnt <= 7'd0; push_v <= 1'b0; push_c <= 1'b0;
                for (ki = 0; ki < CIC_STAGES; ki = ki + 1) begin
                    integ[ki] <= {W{1'b0}}; cdel[ki] <= {W{1'b0}};
                    integq[ki] <= {W{1'b0}}; cdelq[ki] <= {W{1'b0}};
                end
            end else begin
                // mixer pipeline
                v1 <= accept;
                if (accept) begin
                    x1i <= s_i_tdata; x1q <= s_q_tdata;
                    c1  <= nco_c;     s1  <= nco_s;
                end
                v2 <= v1;
                if (v1) begin
                    i_mix <= rne_sat34(iacc);
                    q_mix <= rne_sat34(qacc);
                    mix_clip <= clip34(iacc) | clip34(qacc);
                end
                // CIC integrators on mixer-valid beats; comb cascade on
                // the post-update accumulator once per R beats; the scaled
                // pair is registered and pushed to the FIFO next cycle
                push_v <= 1'b0;
                if (v2) begin
                    ti = {{24{i_mix[15]}}, i_mix};
                    tq = {{24{q_mix[15]}}, q_mix};
                    for (ki = 0; ki < CIC_STAGES; ki = ki + 1) begin
                        integ[ki]  <= integ[ki] + ti;
                        ti = integ[ki] + ti;
                        integq[ki] <= integq[ki] + tq;
                        tq = integq[ki] + tq;
                    end
                    if (beat_cnt == rate_r - 7'd1) begin
                        beat_cnt <= 7'd0;
                        for (ki = 0; ki < CIC_STAGES; ki = ki + 1) begin
                            cdel[ki]  <= ti;
                            ti = ti - cdel[ki];
                            cdelq[ki] <= tq;
                            tq = tq - cdelq[ki];
                        end
                        push_i <= scale_sat(ti, shift_r);
                        push_q <= scale_sat(tq, shift_r);
                        push_c <= clip40(ti, shift_r) ||
                                  clip40(tq, shift_r);
                        push_v <= 1'b1;
                    end else begin
                        beat_cnt <= beat_cnt + 7'd1;
                    end
                end
                if (push_v && !fifo_sready) fifo_overflow <= 1'b1;
                if (accept && input_count != 16'hffff)
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
        if (CIC_STAGES < 1 || CIC_STAGES > 4 ||
            FIFO_DEPTH < 4 || FIFO_DEPTH > 64)
            $fatal(1, "unsupported static configuration");
    end
`endif
endmodule
