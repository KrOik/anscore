`timescale 1ns / 1ps
// ips_err_log_sticky : first-N error capture with timestamp, source code and an
// overflow-protected ring log.
//
// WRITTEN CONTRACT.  src/ips_err_log_sticky.v and models/ips_err_log_sticky.py are
// both derived from this text.  Neither is back-filled from simulation output
// (docs/IP_CORE_SOP.md trap T1).  Every register is gated by clk_en and rst_n is
// the active-low asynchronous reset (trap T2).  The ring log is NSLOTS independent
// slot registers joined into one flat vector through constant part-selects, so no
// multi-dimensional packed array is used (trap T3).
//
// Geometry:  NSLOTS = 1<<LOG_SLOTS slots of SLOT_W = TS_W + SRC_W bits each.
//
// Timestamp.  ts_count is a free-running stamp that steps by one on every enabled
// beat and wraps at 2**TS_W.  An event records the value ts_count holds on the beat
// that captures it, so stamps are strictly monotonic inside a wrap window and two
// records can never share a stamp.
//
// Event inputs.  Two independent channels a and b may fire in the same enabled
// beat and exactly one record is written per beat.  When both fire the LOWER
// source code takes the slot and an equal pair resolves to channel a.  The losing
// channel's record is dropped: drop_count steps (4-bit, saturating at DROP_SAT, it
// never wraps) and the duplicate-class sticky bit is set.  Both channels always set
// their own src_sticky bit, so a losing event can never hide from the sticky view.
// A record is {timestamp, source code} with the stamp in the low TS_W bits and the
// source code above it; the slot stride TS_W+SRC_W therefore moves the whole log
// when either width moves.
//
// Write path.  While log_full is clear the record is written into slot wr_ptr,
// wr_ptr steps modulo NSLOTS and n_unread steps up.  The write that lands in the
// last free slot sets log_full and the full-class sticky bit.  From then on later
// events NEVER overwrite a stored record: they step ovf_count (OVF_W bits, clamped
// at 2**OVF_W-1, never wrapping) and set the overflow-class sticky bit.  log_full
// is only cleared by clr_all, so the first NSLOTS records stay authoritative for
// the whole armed period, and they stay readable after every later event.
//
// Occupancy.  log_used[k] says slot k holds a record that has not been read yet.
// A write sets exactly the bit of the slot it fills and a pop clears exactly the
// bit of the slot it returns, so popcount(log_used) == n_unread at all times and a
// write can never land on an unread record.  Slot data is only ever replaced by a
// write into an unused slot: neither a pop nor clr_all scrubs data, clr_all simply
// drops the occupancy, which is what makes the stale words unreachable.
//
// Read/clear interface.  rd_en pops the oldest unread record: rd_record takes
// {rd_src, rd_ts}, rd_valid pulses for exactly one beat, that slot's occupancy bit
// falls, rd_ptr steps and n_unread steps down.  A pop with nothing unread is
// ignored -- no record moves, no slot changes -- and sets the empty-pop-class
// sticky bit.  A pop and a write in the same beat always address different slots
// whenever a record is unread, so the two paths cannot collide.  clr_all re-arms
// the log: occupancy, wr_ptr, rd_ptr, n_unread, ovf_count, drop_count, log_full,
// log_empty, rd_record, pop_slot and the sticky class word.  clr_all dominates its
// beat, so every other input is ignored while it is high.  src_sticky survives
// clr_all by contract -- it is the ever-errored history -- and only stk_clr empties
// it; events on the same beat as stk_clr still latch their own source bit because
// the clear is applied first.
//
// stk_word carries the event-class sticky bits at the fixed positions STK_*:
// overflow, duplicate collision, log full, event seen, empty pop.
module ips_err_log_sticky #(
    parameter TS_W      = 10,
    parameter SRC_W     = 4,
    parameter LOG_SLOTS = 2,
    parameter OVF_W     = 6
)(
    input  wire                                          clk,
    input  wire                                          clk_en,
    input  wire                                          rst_n,

    input  wire                                          err_a_valid,
    input  wire  [SRC_W-1:0]                             err_a_src,
    input  wire                                          err_b_valid,
    input  wire  [SRC_W-1:0]                             err_b_src,
    input  wire                                          rd_en,
    input  wire                                          clr_all,
    input  wire                                          stk_clr,

    output reg   [TS_W-1:0]                              ts_count,
    output reg   [OVF_W-1:0]                             ovf_count,
    output reg   [3:0]                                   drop_count,
    output reg   [7:0]                                   stk_word,
    output reg   [(1 << SRC_W) - 1 : 0]                  src_sticky,
    output reg   [TS_W + SRC_W - 1 : 0]                  rd_record,
    output wire  [TS_W-1:0]                              rd_ts,
    output wire  [SRC_W-1:0]                             rd_src,
    output reg   [LOG_SLOTS-1:0]                         wr_ptr,
    output reg   [LOG_SLOTS-1:0]                         rd_ptr,
    output reg   [LOG_SLOTS:0]                           n_unread,
    output reg                                           log_full,
    output reg                                           log_empty,
    output reg                                           rd_valid,
    output reg   [LOG_SLOTS-1:0]                         pop_slot,
    output reg   [(1 << LOG_SLOTS) - 1 : 0]              log_used,
    output wire                                          ovf_sticky,
    output wire                                          dup_sticky,
    output wire                                          full_sticky,
    output wire                                          seen_sticky,
    output wire                                          epop_sticky,
    output wire  [((TS_W + SRC_W) << LOG_SLOTS) - 1 : 0] log_flat
);

localparam [3:0]  DROP_SAT = 4'hE;
localparam [7:0]  STK_OVF  = 8'h01, STK_DUP  = 8'h02, STK_FULL = 8'h04, STK_SEEN = 8'h08, STK_EPOP = 8'h10;

localparam integer SLOT_W  = TS_W + SRC_W;
localparam integer NSLOTS  = 1 << LOG_SLOTS;
localparam integer STKW    = 1 << SRC_W;
localparam integer MEM_W   = SLOT_W << LOG_SLOTS;

wire [MEM_W-1:0] slot_vec;
integer k;

// ---------------------------------------------------------------------------
// event selection.  clr_all dominates its beat, so both channels and the read
// and clear strobes are qualified by it before anything else is computed.
// ---------------------------------------------------------------------------
wire             a_live = err_a_valid & ~clr_all;
wire             b_live = err_b_valid & ~clr_all;
wire             rd_live = rd_en & ~clr_all;

wire             evt_any = a_live | b_live;
wire             evt_dup = a_live & b_live;
wire             a_lower = (err_a_src < err_b_src);
wire [SRC_W-1:0] evt_src = a_live ? (b_live ? (a_lower ? err_a_src : err_b_src) : err_a_src) : err_b_src;
wire [SLOT_W-1:0] evt_rec = {ts_count, evt_src};

wire [LOG_SLOTS-1:0] wr_next = wr_ptr + 1'b1;
wire                 wr_last = (wr_next == 0);

wire have_rec  = |n_unread;
wire wr_fire   = evt_any & ~log_full;
wire ovf_fire  = evt_any &  log_full;
wire pop_fire  = rd_live &  have_rec;
wire epop_fire = rd_live & ~have_rec;

// one-hot source decode: every live event sets its own sticky bit, dropped or not
wire [STKW-1:0] dec_a;
wire [STKW-1:0] dec_b;
genvar g;
generate
    for (g = 0; g < STKW; g = g + 1) begin : G_DEC
        assign dec_a[g] = a_live && (err_a_src == g);
        assign dec_b[g] = b_live && (err_b_src == g);
    end
endgenerate

// ---------------------------------------------------------------------------
// ring storage: one write-enabled slot register per record, joined into one flat
// vector by constant part-selects.  Nothing ever muxes the array, which is what
// keeps an unread record from being corrupted by an unrelated beat.
// ---------------------------------------------------------------------------
genvar s;
generate
    for (s = 0; s < NSLOTS; s = s + 1) begin : G_SLOT
        localparam integer LO = s * SLOT_W;
        reg [SLOT_W-1:0] rec_q;
        wire wr_sel = wr_fire && (wr_ptr == s);
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                rec_q <= {(SLOT_W){1'b0}};
            end else if (clk_en && wr_sel) begin
                rec_q <= evt_rec;
            end
        end
        assign slot_vec[LO +: SLOT_W] = rec_q;
    end
endgenerate

// constant-window slot read of the flat vector (no multi-dimensional indexing)
reg [SLOT_W-1:0] rd_win;
always @(*) begin
    rd_win = {(SLOT_W){1'b0}};
    for (k = 0; k < NSLOTS; k = k + 1) begin
        if (rd_ptr == k) begin
            rd_win = slot_vec[k*SLOT_W +: SLOT_W];
        end
    end
end

assign rd_src      = rd_record[SRC_W-1:0];
assign rd_ts       = rd_record[TS_W + SRC_W - 1 : SRC_W];
assign ovf_sticky  = |(stk_word & STK_OVF);
assign dup_sticky  = |(stk_word & STK_DUP);
assign full_sticky = |(stk_word & STK_FULL);
assign seen_sticky = |(stk_word & STK_SEEN);
assign epop_sticky = |(stk_word & STK_EPOP);
assign log_flat    = slot_vec;

// ---------------------------------------------------------------------------
// free-running timestamp
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ts_count <= {(TS_W){1'b0}};
    end else if (clk_en) begin
        ts_count <= ts_count + 1'b1;
    end
end

// ---------------------------------------------------------------------------
// occupancy vector: set by the slot a write fills, cleared by the slot a pop
// returns, dropped wholesale by clr_all.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        log_used <= {(NSLOTS){1'b0}};
    end else if (clk_en) begin
        if (clr_all) begin
            log_used <= {(NSLOTS){1'b0}};
        end else begin
            if (pop_fire) begin
                log_used[rd_ptr] <= 1'b0;
            end
            if (wr_fire) begin
                log_used[wr_ptr] <= 1'b1;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// pointers, saturating counters, sticky words
// ---------------------------------------------------------------------------
reg [LOG_SLOTS:0] nu;
reg [7:0]         stk_nx;
reg [STKW-1:0]    src_nx;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ovf_count  <= {(OVF_W){1'b0}};
        drop_count <= {(4){1'b0}};
        stk_word   <= {(8){1'b0}};
        src_sticky <= {(STKW){1'b0}};
        wr_ptr     <= {(LOG_SLOTS){1'b0}};
        rd_ptr     <= {(LOG_SLOTS){1'b0}};
        n_unread   <= {(LOG_SLOTS + 1){1'b0}};
        log_full   <= 1'b0;
        log_empty  <= 1'b1;
        rd_record  <= {(SLOT_W){1'b0}};
        rd_valid   <= 1'b0;
        pop_slot   <= {(LOG_SLOTS){1'b0}};
    end else if (clk_en) begin
        if (clr_all) begin
            ovf_count  <= {(OVF_W){1'b0}};
            drop_count <= {(4){1'b0}};
            stk_word   <= {(8){1'b0}};
            wr_ptr     <= {(LOG_SLOTS){1'b0}};
            rd_ptr     <= {(LOG_SLOTS){1'b0}};
            pop_slot   <= {(LOG_SLOTS){1'b0}};
            n_unread   <= {(LOG_SLOTS + 1){1'b0}};
            rd_record  <= {(SLOT_W){1'b0}};
            log_full   <= 1'b0;
            log_empty  <= 1'b1;
            rd_valid   <= 1'b0;
            src_sticky <= stk_clr ? {(STKW){1'b0}} : src_sticky;
        end else begin
            nu     = n_unread;
            stk_nx = stk_word;
            src_nx = stk_clr ? {(STKW){1'b0}} : src_sticky;

            if (wr_fire) begin
                nu = nu + 1'b1;
            end
            if (pop_fire) begin
                nu = nu - 1'b1;
            end
            if (evt_any) begin
                src_nx = src_nx | dec_a | dec_b;
                stk_nx = stk_nx | STK_SEEN;
            end
            if (ovf_fire) begin
                stk_nx = stk_nx | STK_OVF;
            end
            if (evt_dup) begin
                stk_nx = stk_nx | STK_DUP;
            end
            if (wr_fire && wr_last) begin
                stk_nx = stk_nx | STK_FULL;
            end
            if (epop_fire) begin
                stk_nx = stk_nx | STK_EPOP;
            end

            rd_valid   <= pop_fire;
            wr_ptr     <= wr_fire ? wr_next : wr_ptr;
            rd_ptr     <= pop_fire ? (rd_ptr + 1'b1) : rd_ptr;
            pop_slot   <= pop_fire ? rd_ptr : pop_slot;
            n_unread   <= nu;
            log_empty  <= (nu == 0);
            log_full   <= log_full | (wr_fire & wr_last);
            src_sticky <= src_nx;
            stk_word   <= stk_nx;
            if (pop_fire) begin
                rd_record <= rd_win;
            end
            if (ovf_fire && !(&ovf_count)) begin
                ovf_count <= ovf_count + 1'b1;
            end
            if (evt_dup && (drop_count < DROP_SAT)) begin
                drop_count <= drop_count + 4'h1;
            end
        end
    end
end

endmodule
