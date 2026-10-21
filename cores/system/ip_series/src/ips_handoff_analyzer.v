`timescale 1ns / 1ps
// ips_handoff_analyzer : valid/ready interface analyser.  It watches one producer
// burst at a time, kept open by the `win` level, and books a per-burst ledger of
// handoffs, dead cycles, the longest dead-cycle run, underruns and overruns.
//
// BURST WINDOW.  `busy` is the registered window state: the window OPENS on the beat
// where `win` is high and no window was open, and CLOSES on the beat where `win` is low
// while a window was open.  A beat is OBSERVED (counted) exactly on the beats where
// `busy` and `win` are both high, i.e. after the opening beat and up to but not
// including the closing beat.  The opening beat itself is not observed: the window is
// armed one beat before the stream is measured.
//
// PER-BURST DEFINITIONS (these are the contract models/ips_handoff_analyzer.py
// re-derives independently; they are never relaxed to make numbers agree):
//   handoff   - observed beat with valid && ready.            hnd   counts them.
//   dead cycle- observed beat INSIDE the burst (valid held high across a stall) with
//               valid high and ready low.                     dead  counts them.
//   stall run - maximal run of consecutive dead cycles; `stall` is the run in progress
//               and `mxstall` the longest run booked by this burst.  A run that is
//               still growing when the window closes is folded into the ledger, so the
//               recorded maximum is never short by one burst tail.
//   overrun   - valid DEASSERTED on an observed beat while the beat it presented was
//               still not accepted (the previous observed beat held valid high with
//               ready low).  The producer withdrew a beat the consumer never took.
//   underrun  - ready asserted on an observed beat with no valid: the consumer is ready
//               with nothing to take while the burst window is open.
// COUNTS ARE PER BURST.  On the closing beat everything live (hnd, dead, stall, mxstall,
// undr, ovr, flags) re-zeros in the SAME beat that books the ledger, so two back-to-back
// bursts can never leak into each other.  `done` is the one-beat strobe of that closing
// beat and burst_n counts completed bursts.  The ledger (lhnd, ldead, lmxstall, lundr,
// lovr, lflags) holds the last completed burst, and top_hnd is the handoff high-water
// mark over every completed burst.
//
// FLAGS are sticky inside a burst and are cleared only by the window closing:
// FL_OVR / FL_UNDR / FL_LONG / FL_TRIM / FL_RUN / FL_XFER.  lflags adds the two
// burst-level verdicts FL_CLEAN (the burst had no dead cycle at all) and FL_EMPTY (the
// burst booked no handoff).  `dead` and `stall` are saturating counters: they stop at
// TRIM_AT and FL_TRIM marks the beat that tried to push `dead` past it, because a burst
// that stalls forever must still be reportable.  FL_LONG marks that a dead-cycle run
// reached TRIP_AT beats, the interface being late by more than a tolerated burst.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous reset
// (docs/IP_CORE_SOP.md trap T2).  No memory is inferred: the ledger is flat vectors.
module ips_handoff_analyzer (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        win,
    input  wire        valid,
    input  wire        ready,

    output reg  [7:0]  hnd,
    output reg  [7:0]  dead,
    output reg  [7:0]  stall,
    output reg  [7:0]  mxstall,
    output reg  [7:0]  undr,
    output reg  [7:0]  ovr,
    output reg  [7:0]  flags,
    output reg  [7:0]  lhnd,
    output reg  [7:0]  ldead,
    output reg  [7:0]  lmxstall,
    output reg  [7:0]  lundr,
    output reg  [7:0]  lovr,
    output reg  [7:0]  lflags,
    output reg  [7:0]  burst_n,
    output reg  [7:0]  top_hnd,
    output reg         busy,
    output reg         done,
    output reg         opening_r
);

localparam [7:0] TRIP_AT  = 8'h08;
localparam [7:0] TRIM_AT  = 8'h3F;
localparam [7:0] FL_OVR   = 8'h01;
localparam [7:0] FL_UNDR  = 8'h02;
localparam [7:0] FL_LONG  = 8'h04;
localparam [7:0] FL_TRIM  = 8'h08;
localparam [7:0] FL_CLEAN = 8'h10;
localparam [7:0] FL_EMPTY = 8'h20;
localparam [7:0] FL_RUN   = 8'h40;
localparam [7:0] FL_XFER  = 8'h80;

reg p_open;
reg p_valid;
reg p_ready;

wire opening = win & ~busy;
wire closing = busy & ~win;
wire open    = busy & win;

wire acc    = open &  valid &  ready;
wire stl    = open &  valid & ~ready;
wire und    = open & ~valid &  ready;
wire ovr_e  = open & ~valid & p_open & p_valid & ~p_ready;

// dead and stall both saturate at TRIM_AT, so a run that never ends cannot outrun the
// ledger width; `fold` books a run the moment it stops being a dead cycle.
wire grow      = stl & (stall != TRIM_AT);
wire dead_grow = stl & (dead  != TRIM_AT);
wire trip      = grow & ((stall + 8'h01) == TRIP_AT);
wire saturate  = stl & (dead == TRIM_AT);
wire fold      = ~stl & (stall > mxstall);
wire [7:0] mx_n = fold ? stall : mxstall;

wire [7:0] set_n = ({8{ovr_e}}     & FL_OVR)
                 | ({8{und}}       & FL_UNDR)
                 | ({8{trip}}      & FL_LONG)
                 | ({8{saturate}}  & FL_TRIM)
                 | ({8{open}}      & FL_RUN)
                 | ({8{acc}}       & FL_XFER);

wire [7:0] verd_n = ((dead == 8'h00) ? FL_CLEAN : 8'h00)
                  | ((hnd  == 8'h00) ? FL_EMPTY : 8'h00);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hnd       <= 8'h00;
        dead      <= 8'h00;
        stall     <= 8'h00;
        mxstall   <= 8'h00;
        undr      <= 8'h00;
        ovr       <= 8'h00;
        flags     <= 8'h00;
        lhnd      <= 8'h00;
        ldead     <= 8'h00;
        lmxstall  <= 8'h00;
        lundr     <= 8'h00;
        lovr      <= 8'h00;
        lflags    <= 8'h00;
        burst_n   <= 8'h00;
        top_hnd   <= 8'h00;
        busy      <= 1'b0;
        done      <= 1'b0;
        opening_r <= 1'b0;
        p_open    <= 1'b0;
        p_valid   <= 1'b0;
        p_ready   <= 1'b0;
    end else if (clk_en) begin
        busy      <= win;
        done      <= closing;
        opening_r <= opening;
        p_open    <= open;
        p_valid   <= valid;
        p_ready   <= ready;
        if (closing) begin
            lhnd     <= hnd;
            ldead    <= dead;
            lundr    <= undr;
            lovr     <= ovr;
            lmxstall <= mx_n;
            lflags   <= flags | verd_n;
            hnd      <= 8'h00;
            dead     <= 8'h00;
            stall    <= 8'h00;
            mxstall  <= 8'h00;
            undr     <= 8'h00;
            ovr      <= 8'h00;
            flags    <= 8'h00;
            burst_n  <= burst_n + 8'h01;
            if (hnd > top_hnd) begin
                top_hnd <= hnd;
            end
        end else begin
            if (acc) begin
                hnd <= hnd + 8'h01;
            end
            if (dead_grow) begin
                dead <= dead + 8'h01;
            end
            if (und) begin
                undr <= undr + 8'h01;
            end
            if (ovr_e) begin
                ovr <= ovr + 8'h01;
            end
            if (stl) begin
                if (grow) begin
                    stall <= stall + 8'h01;
                end
            end else if (stall != 8'h00) begin
                stall <= 8'h00;
            end
            if (fold) begin
                mxstall <= stall;
            end
            if (set_n != 8'h00) begin
                flags <= flags | set_n;
            end
        end
    end
end

endmodule
