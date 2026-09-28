`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// SNN sparse convolution core (event-driven 3x3 conv + leaky integrate & fire)
// Target: Tang Primer 25K / GW5A-LV25MG121NES
// -----------------------------------------------------------------------------
// Semantics, mirrored exactly by cores/acceleration/snn_lstm/model/golden_snn.py:
//   * the input is a queue of spike events {step, idx, val}; a silent input
//     neuron is absent from the queue, so it costs nothing (that is the
//     sparsity being exploited).
//   * each event at input neuron (c,iy,ix) fans out over the KERN*KERN taps:
//         acc[(oy,ox)][ch] += w[c][tap][ch] * val
//     weights are position-shared, so weight state is only
//     CIN*KERN*KERN*COUT bytes and stays in fabric ROM.
//   * when the timestep's events are exhausted a leak+LIF scan pass runs:
//         a = acc - (acc >>> LEAK);  if a >= VTH { spike; a -= VTH }
//   * the accumulator array is a synchronous-read RAM (BRAM candidate) driven
//     by a strictly sequential read/write pair per tap, so no read-after-write
//     forwarding network is required.
// -----------------------------------------------------------------------------
module snn_sparse_conv_core #(
    parameter IMG_W       = 8,
    parameter IMG_H       = 8,
    parameter CIN         = 2,
    parameter COUT        = 4,
    parameter KERN        = 3,
    parameter PAD         = 1,
    parameter ACC_W       = 16,
    parameter LEAK        = 3,
    parameter VTH         = 96,
    parameter N_STEPS     = 8,
    parameter STEP_BITS   = 4,
    parameter EVT_DEPTH   = 64,
    parameter OFIFO_DEPTH = 32
) (
    input  wire  clk,
    input  wire  rst_n,

    input  wire                        start,
    // weight ROM, byte lane index ((c*TAPS + tap)*COUT + ch)
    input  wire [CIN*KERN*KERN*COUT*8-1:0] wrom,

    // event queue load port (written before start)
    input  wire                        ld_en,
    input  wire [7:0]                  ld_addr,
    input  wire [STEP_BITS+15:0]       ld_data,   // {step, idx, val}
    input  wire [8:0]                  ld_count,

    // output spike event stream
    output reg                         oevt_valid,
    input  wire                        oevt_ready,
    output reg  [7:0]                  oevt_idx,   // pix*COUT + ch
    output reg  [STEP_BITS-1:0]        oevt_step,

    output reg                         done,
    output reg                         error,
    output reg  [7:0]                  err_code,
    output reg                         busy,

    output reg  [31:0]                 digest,
    output reg  [15:0]                 stat_events,
    output reg  [15:0]                 stat_taps,
    output reg  [15:0]                 stat_taps_skip,
    output reg  [15:0]                 stat_spikes,
    output reg  [15:0]                 stat_scan_cells,
    output reg  [15:0]                 stat_ofifo_ovf,
    output reg  [23:0]                 stat_cycles,
    output reg  [STEP_BITS-1:0]        stat_step,
    output wire [15:0]                 stat_dense_macs
);

    localparam OW   = IMG_W + 2 * PAD - KERN + 1;
    localparam OH   = IMG_H + 2 * PAD - KERN + 1;
    localparam NPIX = OW * OH;
    localparam TAPS = KERN * KERN;
    localparam NIN  = CIN * IMG_W * IMG_H;
    localparam WORD_W = COUT * ACC_W;
    localparam PW   = 7;                       // pixel address width
    localparam HASHB = 2 * COUT;               // bytes folded per pixel
    localparam DENSE_PER_STEP = NPIX * COUT * CIN * TAPS;
    // VTH arrives as an unsigned parameter; comparisons against signed
    // accumulators must stay signed or a negative cell would look huge.
    localparam signed [ACC_W-1:0] VTH_S = VTH;

    localparam S_IDLE = 3'd0, S_CLEAR = 3'd1, S_EVENT = 3'd2, S_SCAN = 3'd3,
             S_HASH   = 3'd4, S_FIN = 3'd5, S_ERR = 3'd6;
    localparam PH_RD = 2'd0, PH_WR = 2'd1, PH_EMIT = 2'd2, PH_BYTE = 2'd3;

    reg [2:0]            st, ph;
    reg [3:0]            tap;
    reg [PW-1:0]         pix;
    reg [2:0]            lane;
    reg [8:0]            qptr;
    reg [STEP_BITS-1:0]  cur_step;

    // Event queue as a flat register file. GW5A has no distributed-RAM BELs, so
    // an array with the combinational read this FSM needs would map to
    // RAM16SDP4 and fail to place; a packed vector maps to FF + mux logic.
    localparam EW  = STEP_BITS + 16;
    localparam QAW = $clog2(EVT_DEPTH);
    reg [EVT_DEPTH*EW-1:0] evtq;
    // Accumulator array as a flat register file. As a Verilog memory yosys maps
    // it to a Gowin SP BSRAM, where the identical read/write address net trips
    // nextpnr's read-during-write hold check (16 violations) and the cell is an
    // unmodelled black box in this simulation flow. WORD_W is a power of two, so
    // the word offset is a shift and only the 64:1 read mux costs logic.
    localparam WBW = $clog2(WORD_W);
    reg [NPIX*WORD_W-1:0] acc;
    reg [WORD_W-1:0]      acc_q;

    wire [12:0] q_base = qptr[QAW-1:0] * EW;
    wire [12:0] w_base = ld_addr[QAW-1:0] * EW;
    wire [EW-1:0] q_word = evtq[q_base +: EW];

    // ------------------------------------------------------------------ queue
    wire [STEP_BITS-1:0] q_step   = q_word[STEP_BITS+15:STEP_BITS+12];
    wire [7:0]           q_idx    = q_word[STEP_BITS+11:STEP_BITS+4];
    wire signed [7:0]    q_val    = q_word[STEP_BITS+3:0];
    wire                 q_active = (qptr < ld_count);

    wire [3:0] dec_c   = q_idx / (IMG_W * IMG_H);
    wire [7:0] dec_rem = q_idx - dec_c * (IMG_W * IMG_H);
    wire [7:0] dec_iy  = dec_rem / IMG_W;
    wire [7:0] dec_ix  = dec_rem - dec_iy * IMG_W;
    wire [7:0] dec_pix = dec_iy * IMG_W + dec_ix;

    wire [2:0] ky = tap / KERN;
    wire [2:0] kx = tap - ky * KERN;

    wire signed [10:0] oy_s = $signed({1'b0, dec_iy}) + $signed({1'b0, ky}) - PAD;
    wire signed [10:0] ox_s = $signed({1'b0, dec_ix}) + $signed({1'b0, kx}) - PAD;

    wire idx_ok   = (dec_pix < IMG_W * IMG_H) && (dec_c < CIN);
    wire tap_ok   = idx_ok && (oy_s >= 0) && (oy_s < OH) && (ox_s >= 0) && (ox_s < OW);
    wire [PW-1:0] tap_pix = (oy_s[3:0] * OW + ox_s[3:0]);

    // ------------------------------------------------- per-lane arithmetic
    wire [WORD_W-1:0]  evt_wr_data, scan_wr_data;
    wire [COUT-1:0]    fire_mask, ovf_evt, ovf_scan;
    // Multiply-free spike fan-out: a spike event only selects the sign of the
    // shared weight, which is the DSNN conditional-add path. Signedness is
    // explicit because yosys fabric $mul on gw5a is unsigned.
    function signed [ACC_W-1:0] smul8;
        input signed [7:0] a;
        input signed [7:0] b;
        reg [8:0]          am, bm;
        reg [17:0]         pp;
        reg signed [17:0]  ps;
        begin
            am = a[7] ? ({1'b0, ~a} + 9'd1) : {1'b0, a};
            bm = b[7] ? ({1'b0, ~b} + 9'd1) : {1'b0, b};
            pp = am * bm;
            ps = $signed({1'b0, pp});
            smul8 = a[7] ^ b[7] ? -ps[ACC_W-1:0] : ps[ACC_W-1:0];
        end
    endfunction

    genvar gl;
    generate
        for (gl = 0; gl < COUT; gl = gl + 1) begin : g_lane
            wire signed [7:0]      wl  = wrom[((dec_c * TAPS * COUT + tap * COUT + gl) * 8) +: 8];
            wire signed [ACC_W-1:0] pv = smul8(wl, q_val);
            wire signed [ACC_W-1:0] od = acc_q[gl*ACC_W +: ACC_W];
            wire signed [ACC_W-1:0] nv = od + pv;
            wire signed [ACC_W-1:0] lk = od - (od >>> LEAK);
            wire signed [ACC_W-1:0] sn = (lk >= VTH_S) ? (lk - VTH_S) : lk;
            assign evt_wr_data[gl*ACC_W +: ACC_W]  = nv;
            assign scan_wr_data[gl*ACC_W +: ACC_W] = sn;
            assign fire_mask[gl] = (lk >= VTH_S);
            // signed-addition overflow: operands agree, result disagrees
            assign ovf_evt[gl]  = (od[ACC_W-1] == pv[ACC_W-1]) && (nv[ACC_W-1] != od[ACC_W-1]);
            assign ovf_scan[gl] = (lk[ACC_W-1] != sn[ACC_W-1]) &&  lk[ACC_W-1];
        end
    endgenerate
    wire lane_ovf  = |ovf_evt;
    wire scan_ovf  = |ovf_scan;

    // ------------------------------------------------------------ memory port
    wire              mem_rd_en   = (st == S_EVENT && ph == PH_RD && tap_ok)
                                 || (st == S_SCAN   && ph == PH_RD)
                                 || (st == S_HASH   && ph == PH_RD);
    wire [PW-1:0]     mem_rd_addr = (st == S_EVENT) ? tap_pix : pix;
    wire              mem_wr_en   = ((st == S_EVENT && ph == PH_WR) && tap_ok  && !lane_ovf)
                                 || ((st == S_SCAN  && ph == PH_WR) && !scan_ovf)
                                 ||  (st == S_CLEAR);
    wire [PW-1:0]     mem_wr_addr = (st == S_EVENT) ? tap_pix : pix;
    wire [WORD_W-1:0] mem_wr_data = (st == S_CLEAR) ? {WORD_W{1'b0}}
                                  : (st == S_EVENT) ? evt_wr_data : scan_wr_data;
    wire [PW+WBW-1:0] acc_rd_base = {mem_rd_addr, {WBW{1'b0}}};
    wire [PW+WBW-1:0] acc_wr_base = {mem_wr_addr, {WBW{1'b0}}};

    always @(posedge clk) begin
        if (ld_en)     evtq[w_base +: EW] <= ld_data;
        if (mem_rd_en) acc_q <= acc[acc_rd_base +: WORD_W];
        if (mem_wr_en) acc[acc_wr_base +: WORD_W] <= mem_wr_data;
    end

    // ------------------------------------------------------------------- hash
    function [31:0] fnv_mix;
        input [31:0] h;
        input [7:0]  b;
        reg [31:0] x;
        begin
            x = h ^ {24'd0, b};
            fnv_mix = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
        end
    endfunction

    reg [31:0] hash;
    reg [3:0]  hbyte;
    wire [7:0] hsel = acc_q[hbyte*8 +: 8];

    // ---------------------------------------------------------- output FIFO
    localparam FW_AW = 5;
    reg [7:0]           ofifo_idx  [0:OFIFO_DEPTH-1];
    reg [STEP_BITS-1:0] ofifo_step [0:OFIFO_DEPTH-1];
    reg [FW_AW-1:0]     of_wp, of_rp;
    reg [FW_AW:0]       of_cnt;
    wire                of_full = (of_cnt == OFIFO_DEPTH);
    // single owner of of_cnt: push and pop can happen in the same cycle
    wire do_pop  = oevt_valid && oevt_ready;
    wire do_push = (st == S_SCAN && ph == PH_EMIT && lane < COUT &&
                    fire_mask[lane] && !of_full);

    // Payload RAM is written from a plain clocked process; yosys refuses memory
    // writes inside the async-reset FSM process.
    always @(posedge clk) begin
        if (do_push) begin
            ofifo_idx[of_wp]  <= {pix[5:0], lane[1:0]};
            ofifo_step[of_wp] <= cur_step;
        end
    end

    // -------------------------------------------------------------------- FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; ph <= PH_RD; tap <= 4'd0; pix <= {PW{1'b0}};
            lane <= 3'd0; qptr <= 9'd0; cur_step <= {STEP_BITS{1'b0}};
            done <= 1'b0; error <= 1'b0; err_code <= 8'd0; busy <= 1'b0;
            digest <= 32'd0; hash <= 32'd2166136261; hbyte <= 4'd0;
            stat_events <= 16'd0; stat_taps <= 16'd0; stat_taps_skip <= 16'd0;
            stat_spikes <= 16'd0; stat_scan_cells <= 16'd0; stat_ofifo_ovf <= 16'd0;
            stat_cycles <= 24'd0; stat_step <= {STEP_BITS{1'b0}};
            oevt_valid <= 1'b0; oevt_idx <= 8'd0; oevt_step <= {STEP_BITS{1'b0}};
            of_wp <= {FW_AW{1'b0}}; of_rp <= {FW_AW{1'b0}};
            of_cnt <= {(FW_AW+1){1'b0}};
        end else begin
            stat_cycles <= stat_cycles + 24'd1;

            case ({do_push, do_pop})
                2'b10:   of_cnt <= of_cnt + 1'b1;
                2'b01:   of_cnt <= of_cnt - 1'b1;
                default: of_cnt <= of_cnt;
            endcase

            // FIFO pop side
            if (do_pop) begin
                of_rp  <= of_rp + 1'b1;
                if (of_cnt > 1) begin
                    oevt_idx  <= ofifo_idx[of_rp + 1'b1];
                    oevt_step <= ofifo_step[of_rp + 1'b1];
                end else begin
                    oevt_valid <= 1'b0;
                end
            end else if (!oevt_valid && of_cnt != 0) begin
                oevt_valid <= 1'b1;
                oevt_idx   <= ofifo_idx[of_rp];
                oevt_step  <= ofifo_step[of_rp];
            end

            case (st)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        busy     <= 1'b1;
                        done     <= 1'b0;
                        error    <= 1'b0;
                        err_code <= 8'd0;
                        stat_events    <= 16'd0;
                        stat_taps      <= 16'd0;
                        stat_taps_skip <= 16'd0;
                        stat_spikes    <= 16'd0;
                        stat_scan_cells<= 16'd0;
                        stat_ofifo_ovf <= 16'd0;
                        of_wp  <= {FW_AW{1'b0}};
                        of_rp  <= {FW_AW{1'b0}};
                        of_cnt <= {(FW_AW+1){1'b0}};
                        oevt_valid <= 1'b0;
                        st       <= S_CLEAR;
                        ph       <= PH_RD;
                        tap      <= 4'd0;
                        qptr     <= 9'd0;
                        pix      <= {PW{1'b0}};
                        cur_step <= {STEP_BITS{1'b0}};
                        hash     <= 32'd2166136261;
                    end
                end

                // zero the accumulator array in hardware, one word per cycle
                S_CLEAR: begin
                    if (pix == NPIX - 1) begin
                        st <= S_EVENT;
                        ph <= PH_RD;
                        tap <= 4'd0;
                    end else begin
                        pix <= pix + 1'b1;
                    end
                end

                S_EVENT: begin
                    if (q_active && q_step < cur_step) begin
                        error    <= 1'b1;
                        err_code <= 8'h13;          // queue not in timestep order
                        st       <= S_ERR;
                    end else if (!q_active || q_step != cur_step) begin
                        st  <= S_SCAN;
                        ph  <= PH_RD;
                        pix <= {PW{1'b0}};
                        lane<= 3'd0;
                    end else if (ph == PH_RD) begin
                        if (!tap_ok) begin
                            stat_taps_skip <= stat_taps_skip + 16'd1;
                            if (tap == TAPS - 1) begin : blk_skip_evt_done
                                tap         <= 4'd0;
                                qptr        <= qptr + 1'b1;
                                stat_events <= stat_events + 16'd1;
                            end else begin
                                tap <= tap + 1'b1;
                            end
                        end else begin
                            stat_taps <= stat_taps + 16'd1;
                            ph        <= PH_WR;
                        end
                    end else begin
                        if (lane_ovf) begin
                            error    <= 1'b1;
                            err_code <= 8'h12;      // accumulator saturation
                            st       <= S_ERR;
                        end else if (tap == TAPS - 1) begin
                            tap         <= 4'd0;
                            ph          <= PH_RD;
                            qptr        <= qptr + 1'b1;
                            stat_events <= stat_events + 16'd1;
                        end else begin
                            tap <= tap + 1'b1;
                            ph  <= PH_RD;
                        end
                    end
                end

                S_SCAN: begin
                    if (ph == PH_RD) begin
                        ph <= PH_WR;
                    end else if (ph == PH_WR) begin
                        if (scan_ovf) begin
                            error    <= 1'b1;
                            err_code <= 8'h14;
                            st       <= S_ERR;
                        end else begin
                            stat_scan_cells <= stat_scan_cells + 16'd1;
                            lane            <= 3'd0;
                            ph              <= PH_EMIT;
                        end
                    end else if (lane < COUT) begin
                        if (do_push) begin
                            of_wp             <= of_wp + 1'b1;
                            stat_spikes       <= stat_spikes + 16'd1;
                        end else if (fire_mask[lane] && of_full) begin
                            stat_ofifo_ovf <= stat_ofifo_ovf + 16'd1;
                        end
                        lane <= lane + 1'b1;
                    end else if (pix == NPIX - 1) begin
                        if (cur_step == N_STEPS - 1) begin
                            st    <= S_HASH;
                            ph    <= PH_RD;
                            pix   <= {PW{1'b0}};
                            hbyte <= 4'd0;
                        end else begin
                            cur_step  <= cur_step + 1'b1;
                            stat_step <= cur_step + 1'b1;
                            st        <= S_EVENT;
                            ph        <= PH_RD;
                            tap       <= 4'd0;
                        end
                    end else begin
                        pix <= pix + 1'b1;
                        ph  <= PH_RD;
                    end
                end

                S_HASH: begin
                    if (ph == PH_RD) begin
                        ph <= PH_BYTE;
                    end else begin
                        hash <= fnv_mix(hash, hsel);
                        if (hbyte == HASHB - 1) begin
                            hbyte <= 4'd0;
                            ph    <= PH_RD;
                            if (pix == NPIX - 1) begin
                                st <= S_FIN;
                            end else begin
                                pix <= pix + 1'b1;
                            end
                        end else begin
                            hbyte <= hbyte + 1'b1;
                        end
                    end
                end

                S_FIN: begin
                    busy      <= 1'b0;
                    done      <= 1'b1;
                    digest    <= hash;
                    stat_step <= cur_step;
                    st        <= S_FIN;
                    // Accept a fresh run so the board can repeat without a power cycle.
                    if (start) begin
                        done <= 1'b0;
                        st   <= S_IDLE;
                    end
                end

                S_ERR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= S_ERR;
                    if (start) begin
                        done <= 1'b0;
                        st   <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    assign stat_dense_macs = DENSE_PER_STEP * N_STEPS;

endmodule
