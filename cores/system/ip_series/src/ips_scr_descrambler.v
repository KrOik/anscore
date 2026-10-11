`timescale 1ns / 1ps
// ips_scr_descrambler : self-synchronising (multiplicative) additive scrambler /
// descrambler pair over a 43-bit channel history register.
//
// Generator polynomial (delay form, taps TAP_MASK bit k = lag 1+k):
//     scrambler    y[n] = d[n] XOR y[n-1] XOR y[n-43]
//     descrambler  r[n] = a[n] XOR a[n-1] XOR a[n-43]     (a = bits received)
// With x = advance, the scrambler transfer is 1 / (1 + x^-1 + x^-43), i.e. the
// standard characteristic polynomial x^43 + x^42 + 1, and the descrambler is the
// multiplier that cancels it.  Both paths tap the SAME TAP_MASK, so the pair is
// consistent for any tap set: on a clean link r[n] == d[n] exactly, from the
// very first beat, because the receiver's line holds the received bits and the
// transmitter's line holds its own outputs, which are the same bits.
//
// Self-synchronisation: the descrambler is FIR over the received stream and
// never feeds its own output back, so a receiver that joins mid-stream only has
// to flush its 43-bit line -- it is provably exact 43 channel bits later, no
// side channel, no state transfer.  sync_pos counts those bits and resync_pos
// reports the LAST bit position that was still wrong, which is what the
// testbench measures against the 43-bit flush bound.
//
// Error multiplication bound: an error on the channel hits the descrambler
// output once per term of the descrambler polynomial, so ONE injected bit error
// becomes exactly 3 output bit errors (1 direct + weight(TAP_MASK) = 2
// propagated), at positions t, t+1 and t+43.  Two injected bits one beat apart
// share a tap and cancel mod 2, which is why the counters are measured per
// injection event (burst_tot / burst_prop, latched into burst_max / prop_max
// over a BURST_WIN-beat attribution window) instead of being claimed.
// chan_err counts injected channel bits, err_tot counts every descrambler bit
// that came out wrong, scr_ones balances the scrambled stream (an all-zero
// payload must still leave the transmitter as a pseudo-random run).
//
// scr_raw / desc_raw are the live combinational datapath outputs (a link taps
// the scrambler output directly); scr_bit / desc_bit and both 43-bit states are
// registered.  rst_n is the active-low asynchronous reset and it seeds BOTH
// lines with SEED, which is what makes the pair transparent from beat zero.
// Every register, counters included, sits in a clk_en-gated branch behind that
// reset (docs/IP_CORE_SOP.md trap T2).  The states are two flat 43-bit vectors,
// never packed 2-D arrays (trap T3).  The datapath is XOR trees and shift logic
// only -- no multiply, no carry chain, so no DSP and no ALU slice (trap T4).
module ips_scr_descrambler #(
    parameter [42:0] TAP_MASK  = 43'h40000000001,
    parameter [42:0] SEED      = 43'h1A7F0C3D5E9,
    parameter [6:0]  BURST_WIN = 7'd44,
    parameter [7:0]  ERR_CAP   = 8'hFF,
    parameter [7:0]  ONE_CAP   = 8'hFF,
    parameter [3:0]  BURST_CAP = 4'hF
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        start,
    input  wire        data_in,
    input  wire        chan_in,
    input  wire        chan_bad,
    input  wire        restart,
    input  wire [42:0] seed_in,

    output wire        scr_raw,
    output wire        desc_raw,
    output reg         done,
    output reg         scr_bit,
    output reg         desc_bit,
    output reg  [42:0] scr_state,
    output reg  [42:0] desc_state,
    output reg  [7:0]  chan_err,
    output reg  [7:0]  err_tot,
    output reg  [7:0]  scr_ones,
    output reg  [3:0]  burst_tot,
    output reg  [3:0]  burst_prop,
    output reg  [3:0]  burst_max,
    output reg  [3:0]  prop_max,
    output reg  [6:0]  win,
    output reg  [6:0]  sync_pos,
    output reg  [6:0]  resync_pos,
    output reg  [2:0]  err_sticky
);

// The receiver's line is provably clean SYNC_WIN channel bits after a restart.
localparam [6:0] SYNC_WIN = 7'd43;
localparam [6:0] CNT_FULL = 7'h7F;

// The two taps are read out of one mask, so the transmitter's feedback and the
// receiver's multiplier can never disagree about the polynomial.
wire [42:0] rx_hist = restart ? seed_in : desc_state;
wire        tx_fb   = ^(scr_state & TAP_MASK);
wire        rx_fb   = ^(rx_hist   & TAP_MASK);

assign scr_raw  = data_in ^ tx_fb;
assign desc_raw = chan_in ^ rx_fb;

// A descrambler bit that differs from the payload bit that owns it.
wire out_err_w = desc_raw ^ data_in;

// One attribution window is open per injected channel bit and it is stepped by
// every started beat, so the window test is shared by both burst counters.
wire        win_open = (win != 7'd0);
wire [6:0]  sync_n = restart ? 7'd0
                             : ((sync_pos < CNT_FULL) ? (sync_pos + 7'd01) : sync_pos);
wire [3:0]  bt_n = chan_bad ? {3'd0, out_err_w}
                             : ((win_open && out_err_w && burst_tot  < BURST_CAP)
                                 ? (burst_tot  + 4'h1) : burst_tot);
wire [3:0]  bp_n = chan_bad ? 4'h0
                             : ((win_open && out_err_w && burst_prop < BURST_CAP)
                                 ? (burst_prop + 4'h1) : burst_prop);

// Every next-state below is written as a load condition plus a load value rather
// than as `q <= cond ? new_q : q`.  The function is the same -- the else branch of
// each chain is the register holding -- but it lets the back end take the holds
// apart into flip-flop clock enables instead of mux trees.  Together with the
// redundant resync max compare noted below, that is what keeps this core at 158 of
// its 160 LUT-class cells.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done       <= 1'b0;
        scr_bit    <= 1'b0;
        desc_bit   <= 1'b0;
        scr_state  <= SEED;
        desc_state <= SEED;
        chan_err   <= 8'h00;
        err_tot    <= 8'h00;
        scr_ones   <= 8'h00;
        burst_tot  <= 4'h0;
        burst_prop <= 4'h0;
        burst_max  <= 4'h0;
        prop_max   <= 4'h0;
        win        <= 7'h00;
        sync_pos   <= 7'h00;
        resync_pos <= 7'h00;
        err_sticky <= 3'b000;
    end else if (clk_en) begin
        done <= start;
        if (start) begin
            scr_bit    <= scr_raw;
            desc_bit   <= desc_raw;
            scr_state  <= {scr_state[41:0], scr_raw};
            desc_state <= {rx_hist[41:0], chan_in};
            if (chan_bad) begin
                win       <= BURST_WIN;
                burst_tot <= {3'd0, out_err_w};
                burst_prop <= 4'h0;
                err_sticky[0] <= 1'b1;
                if (chan_err < ERR_CAP) begin
                    chan_err <= chan_err + 8'h01;
                end
            end else if (win_open) begin
                win <= win - 7'd01;
                if (out_err_w) begin
                    if (burst_tot  < BURST_CAP) burst_tot  <= burst_tot  + 4'h1;
                    if (burst_prop < BURST_CAP) burst_prop <= burst_prop + 4'h1;
                end
            end
            if (restart) begin
                sync_pos   <= 7'd0;
                resync_pos <= 7'd0;
                err_sticky[2] <= 1'b1;
            end else begin
                if (sync_pos < CNT_FULL) begin
                    sync_pos <= sync_pos + 7'd01;
                end
                if (out_err_w && sync_n < SYNC_WIN) begin
                    // resync_pos reports the LAST position that was still wrong.
                    // Between two restarts sync_n only counts up and a load here is
                    // only allowed below SYNC_WIN, so sync_n is always >= the stored
                    // resync_pos -- the max compare that used to guard this load was
                    // redundant logic (dropping it is what keeps the core at 158 of
                    // its 160 LUT-class budget); the register still holds between
                    // errors, because an unconditional load on the error beats only
                    // writes the same or a larger position.
                    resync_pos <= sync_n;
                end
            end
            if (bt_n > burst_max) burst_max <= bt_n;
            if (bp_n > prop_max)  prop_max  <= bp_n;
            if (out_err_w) begin
                err_sticky[1] <= 1'b1;
                if (err_tot < ERR_CAP) begin
                    err_tot <= err_tot + 8'h01;
                end
            end
            if (scr_raw) begin
                if (scr_ones < ONE_CAP) begin
                    scr_ones <= scr_ones + 8'h01;
                end
            end
        end
    end
end

endmodule
