`timescale 1ns / 1ps
// ips_perf_event_ctr : eight programmable event counters with a strobe AND/OR
// select mux, an atomic snapshot bank and sticky overflow capture.
//
// EVENT SELECT.  Channel i owns two 4-bit group masks over the 4-line strobe bus:
//   and_ok[i] = ((strb & AM[i]) == AM[i])                  an empty AND group is
//                                                          vacuous (always true)
//   or_ok[i]  = (OM[i] == 4'h0) || ((strb & OM[i]) != 4'h0) an empty OR group passes
//   event[i]  = and_ok[i] && or_ok[i]
// so a channel counts the AND of its first strobe group AND the OR of its second
// group.  Channels 0..3 are re-programmable through cfg_we/cfg_idx; channels 4..7
// keep the shipped reset defaults AM_D4..OM_D7, which is the configuration this
// gate proves.  `ev` is the registered event vector: ev[i] is high exactly for the
// beat whose increment was decided by that event, so ev always explains the counter
// movement observed at the same sample point.
//
// COUNT / HOLD.  A channel increments once per enabled beat in which `en` is high
// and its event is set.  With `en` low every counter HOLDS - counters are true
// accumulators, never re-derived from the strobes - and each channel carries its own
// clock enable, so a busy channel cannot perturb an idle one.
//
// PRESET / CLEAR.  cnt_we copies cnt_wval into the channel selected by cnt_widx;
// clr zeroes all eight counters.  Priority is clr > preset > increment, so a preset
// can place a channel one count below WRAP_AT and force the wrap edge to happen.
// Neither path touches the shadow bank or the flags.
//
// SNAPSHOT.  `snap` copies all eight counters into the shadow bank on one edge
// (atomic, one shared enable).  The shadow takes the value the counter held BEFORE
// that beat's increment, so a snapshot never loses a count: the counter keeps
// running while the shadow freezes the pre-edge value.  snap_n counts snapshots.
//
// OVERFLOW.  ovf[i] is sticky and is set exactly on the wrap edge, the beat whose
// increment really rolls channel i from WRAP_AT to zero (a same-beat clear or preset is
// not a rollover, so it does not raise a flag); `wrap[i]` is the registered one-beat
// strobe of that event.  `clr` never touches the flags - no silent clear - `ov_clr` is
// the only way to drop them, and a same-beat wrap still sets (set has priority).
// ov_seq counts the beats in which at least one channel wrapped, so the operator can
// see how many wrap events an ov_clr swallowed.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous reset
// (docs/IP_CORE_SOP.md trap T2).  No memory is inferred: all banks are flat vectors.
module ips_perf_event_ctr (
    input  wire         clk,
    input  wire         clk_en,
    input  wire         rst_n,

    input  wire         en,
    input  wire   [3:0] strb,

    input  wire         cfg_we,
    input  wire   [2:0] cfg_idx,
    input  wire   [7:0] cfg_amask,
    input  wire   [7:0] cfg_omask,

    input  wire         cnt_we,
    input  wire   [2:0] cnt_widx,
    input  wire   [7:0] cnt_wval,

    input  wire         snap,
    input  wire         clr,
    input  wire         ov_clr,

    output wire  [63:0] cnt,
    output wire  [63:0] shd,
    output reg   [7:0]  ev,
    output reg   [7:0]  wrap,
    output reg   [7:0]  ovf,
    output reg   [7:0]  ov_seq,
    output reg   [3:0]  snap_n
);

localparam [7:0] WRAP_AT = 8'hFF;
localparam [3:0] AM_D4   = 4'b0011;
localparam [3:0] OM_D4   = 4'b1100;
localparam [3:0] AM_D5   = 4'b0101;
localparam [3:0] OM_D5   = 4'b0010;
localparam [3:0] AM_D6   = 4'b1111;
localparam [3:0] OM_D6   = 4'b1101;
localparam [3:0] AM_D7   = 4'b0000;
localparam [3:0] OM_D7   = 4'b0000;

reg [63:0] cnt_r;
reg [63:0] shd_r;
reg [31:0] am;
reg [31:0] om;

reg [7:0] ev_c;
reg [7:0] inc_c;
reg [7:0] wrap_c;
reg [7:0] pre_c;

assign cnt = cnt_r;
assign shd = shd_r;

integer k;
reg       aok;
reg       ook;

// Group-mask file.  Channels 0..3 reset with both groups empty (so they free-run
// until the host programs them); channels 4..7 reset to the shipped groups.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        am <= {AM_D7, AM_D6, AM_D5, AM_D4, 4'h0, 4'h0, 4'h0, 4'h0};
        om <= {OM_D7, OM_D6, OM_D5, OM_D4, 4'h0, 4'h0, 4'h0, 4'h0};
    end else if (clk_en) begin
        if (cfg_we) begin
            for (k = 0; k < 8; k = k + 1) begin
                if (cfg_idx == k) begin
                    am[k*4 +: 4] <= cfg_amask[3:0];
                    om[k*4 +: 4] <= cfg_omask[3:0];
                end
            end
        end
    end
end

// Combinational select, increment and preset decodes.
always @(*) begin
    for (k = 0; k < 8; k = k + 1) begin
        aok      = ((strb & am[k*4 +: 4]) == am[k*4 +: 4]);
        ook      = (om[k*4 +: 4] == 4'h0) || ((strb & om[k*4 +: 4]) != 4'h0);
        ev_c[k]  = aok && ook;
        inc_c[k] = en && ev_c[k];
        pre_c[k] = cnt_we && (cnt_widx == k);
        wrap_c[k] = inc_c[k] && !clr && !pre_c[k]
                    && (cnt_r[k*8 +: 8] == WRAP_AT);
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt_r  <= 64'h0000000000000000;
        shd_r  <= 64'h0000000000000000;
        ev     <= 8'h00;
        wrap   <= 8'h00;
        ovf    <= 8'h00;
        ov_seq <= 8'h00;
        snap_n <= 4'h0;
    end else if (clk_en) begin
        for (k = 0; k < 8; k = k + 1) begin
            if (clr) begin
                cnt_r[k*8 +: 8] <= 8'h00;
            end else if (pre_c[k]) begin
                cnt_r[k*8 +: 8] <= cnt_wval;
            end else if (inc_c[k]) begin
                cnt_r[k*8 +: 8] <= cnt_r[k*8 +: 8] + 8'h01;
            end
        end
        if (snap) begin
            shd_r <= cnt_r;
        end
        for (k = 0; k < 8; k = k + 1) begin
            if (wrap_c[k]) begin
                ovf[k] <= 1'b1;
            end else if (ov_clr) begin
                ovf[k] <= 1'b0;
            end
        end
        ev   <= ev_c;
        wrap <= wrap_c;
        if (|wrap_c) begin
            ov_seq <= ov_seq + 8'h01;
        end
        if (snap) begin
            snap_n <= snap_n + 4'h1;
        end
    end
end

endmodule
