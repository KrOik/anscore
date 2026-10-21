`timescale 1ns / 1ps
// ips_irq_priority_ctrl : 16-line nested priority interrupt controller with
// software trigger, mask, vector output and an end-of-interrupt stack.
//
// Written contract.  src/ips_irq_priority_ctrl.v and
// models/ips_irq_priority_ctrl.py are both derived from this text; neither is
// back-filled from simulation output (docs/IP_CORE_SOP.md trap T1).  Every
// register is gated by clk_en and rst_n is the active-low asynchronous reset.
//
// PRIORITY CONVENTION.  Line 0 is the HIGHEST priority and line 15 the LOWEST.
// A line's priority IS its index, so "higher priority" means "smaller index"
// everywhere below: the controller always vectors the lowest set index of the
// candidate word, and a request is servable only while its index is below the
// ceiling in force.
//
// Candidate word - ONE vector path for pins and for software:
//     cand = (pend | swtrig) & ~mask_r
// pend arms on the rising edge of the two-flop synchronised pin
// (rise = sync_q & ~sync_d, newly = rise & ~pend) and is sticky until that line
// is accepted into service or write-1-cleared through the bus.  swtrig is a
// write-1-to-set register.  Both join the same priority path, so a software
// trigger and a hardware pin can never vector differently.  A masked line still
// latches pend, it simply never becomes a candidate; inact = pend & mask_r
// exposes exactly that set, and it is exported and readable.
//
// 16-line priority encoder.  ONE combinational early-exit chain over cand from
// index 0 upward: the first arm that is set wins and the rest of the chain is
// masked off (no multiply, no lookup table).  It produces sel (its index),
// sel_oh (its one-hot) and has_cand.
//
// Ceiling, blocking and nesting.  cur_pri is the priority ceiling in force.  The
// published images of one candidate evaluation are irq_pri / irq_oh / irq_req /
// ge / blocked:
//     ge      = (sel >= cur_pri)              raw ceiling comparison
//     irq_req = has_cand && !ge               a servable request is published
//     blocked = has_cand &&  ge               pending, but not above the ceiling
// IDLE_PRI is the ceiling while nothing is in service, so with the shipped
// IDLE_PRI = 16 every line - including the line-15 boundary - is servable at
// idle, while a line can still be blocked once something is being served.  A
// line can never preempt itself: its own pend bit was cleared when it was
// accepted.
//
//   svc_ack accepts the vector published in the beat in progress and is ignored
//   in a beat that also carries eoi (EOI has precedence).  With irq_req high and
//   nest_depth < NEST_MAX:
//     stk[nest_depth] <= cur_pri     the parent ceiling is parked on the stack
//     cur_pri    <= {1'b0, irq_pri}  the accepted line becomes the ceiling
//     nest_depth <= nest_depth + 1
//     nested     <= (nest_depth != 0)  1 when a higher-priority line nests an
//                                      existing service, 0 for the first level;
//                                      nested is a one-beat pulse
//     svc_cnt    + 1
//   pend and swtrig lose the accepted line (see the clear terms below).  An
//   accept at nest_depth == NEST_MAX is refused with ERR_BASE + 3 and NO state
//   change; an accept without irq_req is a no-op.  A lower-priority line never
//   reaches the accept path at all, because irq_req is low while it is blocked.
//
//   eoi closes the line in service.  It is legal only when nest_depth != 0 AND
//   eoi_idx == cur_pri[3:0], i.e. the EOI names the ACTIVE line.  A legal EOI
//   pops:
//     cur_pri    <= stk[nest_depth - 1]     back to the parent priority
//     nest_depth <= nest_depth - 1
//     nested     <= 0
//     eoi_cnt    + 1
//   An EOI with nest_depth == 0 reports ERR_BASE + 1 and an EOI naming a
//   non-active line reports ERR_BASE + 2; in both cases the stack, the ceiling,
//   pend and swtrig are untouched.  The popped lane is not erased - it is
//   overwritten by the next push at that level - and stk_flat exports the whole
//   vector, so the walk is observable.
//
// Nesting stack (trap T3): eight 8-bit lanes of one flat 64-bit register, entry
// j at stk[8j +: 5].  The write enable is the decode of nest_depth and the read
// is the 8:1 selection by nest_depth - 1 (rd_idx).
//
// Error reporting.  err_code holds the code of the most recent error beat and
// err_count counts error beats, saturating at CNT_SAT.  Precedence inside one
// beat: illegal address > EOI with nothing in service > EOI on a non-active line
// > nesting overflow.
//
// Register map (16-bit data, sampled on the enabled beat where bus_we is high;
// legal addresses are 0..5):
//   0 MASK     write mask_r                        read mask_r
//   1 SWTRIG   write-1-to-set swtrig               read swtrig
//   2 PEND     write-1-to-clear pend               read pend
//   3 INACT    writes ignored                      read inact
//   4 VEC      writes ignored                      read {8'h00, irq_vec}
//   5 STAT     writes ignored                      read {1'h0, inact_hit,
//                                                    cur_pri, nest_depth,
//                                                    err_code, irq_req, blocked}
//   6..15      ILLEGAL: every read returns INVALID_RD, every write steps
//              err_count with code ERR_BASE + 0 and changes no register.
// Both readable status lines return the images HELD AT THE START of the beat:
// mask_r, swtrig, pend, inact, irq_vec, cur_pri, nest_depth and err_code are the
// values the beat began with, so a read of a register never shows that same
// beat's write or service move.
// Synchroniser: every enabled beat shifts sync_meta <= irq_in, sync_q <= sync_meta,
// sync_d <= sync_q, so a pin movement is seen as a rise two beats later.
// Ordering inside one beat: pend is armed first and only then cleared, so a bit
// that rises and is cleared in the same beat ends cleared; swtrig is set first
// and only then cleared by an accept, so a trigger set and accepted in the same
// beat ends cleared.  mask_r takes the write of the beat.
// bus_rdata and bus_ack are registered, so a read returns the value of the beat
// in progress and bus_ack marks a legal write.
module ips_irq_priority_ctrl #(
    parameter [3:0]  VECTOR_BASE = 4'h8,
    parameter [2:0]  NEST_MAX    = 3'd7,
    parameter [4:0]  IDLE_PRI    = 5'd16,
    parameter [15:0] RESET_MASK  = 16'h0300
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [15:0] irq_in,
    input  wire [3:0]  bus_addr,
    input  wire        bus_we,
    input  wire [15:0] bus_wdata,
    input  wire        svc_ack,
    input  wire        eoi,
    input  wire [3:0]  eoi_idx,
    output reg  [15:0] bus_rdata,
    output reg         bus_ack,
    output wire [7:0]  irq_vec,
    output reg  [3:0]  irq_pri,
    output reg         irq_req,
    output reg         blocked,
    output reg         ge,
    output reg         nested,
    output reg  [2:0]  nest_depth,
    output reg  [4:0]  cur_pri,
    output reg  [15:0] pend,
    output reg  [15:0] mask_r,
    output reg  [15:0] swtrig,
    output wire [15:0] inact,
    output reg  [3:0]  err_code,
    output reg  [6:0]  err_count,
    output reg  [6:0]  svc_cnt,
    output reg  [6:0]  eoi_cnt,
    output wire [63:0] stk_flat
);

localparam [15:0] INVALID_RD = 16'hDEAD;
localparam [3:0]  ERR_BASE   = 4'h8;
localparam [6:0]  CNT_SAT    = 7'd100;
localparam [3:0]  A_MASK   = 4'h0, A_SWTRIG = 4'h1, A_PEND = 4'h2,
                  A_INACT  = 4'h3, A_VEC    = 4'h4, A_STAT = 4'h5;

reg [15:0] sync_meta, sync_q, sync_d;
reg [15:0] irq_oh;
reg [3:0]  sel;
reg [15:0] sel_oh;
reg        has_cand;
reg [3:0]  nxt_err;
reg [63:0] stk;

wire [15:0] cand      = (pend | swtrig) & ~mask_r;
wire [15:0] rise      = sync_q & ~sync_d;
wire [15:0] newly     = rise & ~pend;
wire        inact_hit = |inact;
assign      irq_vec   = {VECTOR_BASE, irq_pri};
assign      stk_flat  = stk;
assign      inact     = pend & mask_r;

wire        depth0   = (nest_depth == 3'd0);
wire        active   = ~depth0;
wire        eoi_ok   = eoi && active && (eoi_idx == cur_pri[3:0]);
wire        eoi_idle = eoi && !active;
wire        eoi_bad  = eoi && active && !eoi_ok;
wire        acc_go   = svc_ack && !eoi && irq_req && (nest_depth < NEST_MAX);
wire        acc_of   = svc_ack && !eoi && irq_req && (nest_depth == NEST_MAX);
wire [2:0]  rd_idx   = depth0 ? 3'd0 : (nest_depth - 3'd1);

wire [4:0] sel5  = {1'b0, sel};
wire       ge_n  = (sel5 >= cur_pri);
wire       req_n = has_cand && !ge_n;
wire       blk_n = has_cand && ge_n;

wire       w_mask = bus_we && (bus_addr == A_MASK);
wire       w_sw   = bus_we && (bus_addr == A_SWTRIG);
wire       w_pend = bus_we && (bus_addr == A_PEND);
wire       w_ill  = bus_we && (bus_addr > A_STAT);
wire [15:0] sw_set = w_sw ? bus_wdata : 16'h0000;
wire [15:0] p_clr  = (acc_go ? irq_oh : 16'h0000) |
                     (w_pend ? bus_wdata : 16'h0000);
wire [15:0] s_clr  = acc_go ? irq_oh : 16'h0000;

// 16-line priority chain: one combinational early-exit walk from index 0 up.
integer k;
always @* begin
    sel      = 4'd0;
    sel_oh   = 16'h0001;
    has_cand = 1'b0;
    for (k = 0; k < 16; k = k + 1) begin
        if (!has_cand && cand[k]) begin
            sel      = k[3:0];
            sel_oh   = 16'h0001 << k;
            has_cand = 1'b1;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sync_meta  <= 16'h0000;
        sync_q     <= 16'h0000;
        sync_d     <= 16'h0000;
        pend       <= 16'h0000;
        mask_r     <= RESET_MASK;
        swtrig     <= 16'h0000;
        stk        <= 64'h0000000000000000;
        irq_oh     <= 16'h0001;
        nest_depth <= 3'd0;
        cur_pri    <= IDLE_PRI;
        irq_pri    <= 4'd0;
        irq_req    <= 1'b0;
        blocked    <= 1'b0;
        ge         <= 1'b0;
        nested     <= 1'b0;
        err_code   <= 4'h0;
        err_count  <= 7'd0;
        svc_cnt    <= 7'd0;
        eoi_cnt    <= 7'd0;
        bus_rdata  <= 16'h0000;
        bus_ack    <= 1'b0;
    end else if (clk_en) begin
        // one-beat flags return to idle unless this beat says otherwise
        nested <= 1'b0;

        // --- two-flop synchroniser ------------------------------------------
        sync_meta <= irq_in;
        sync_q    <= sync_meta;
        sync_d    <= sync_q;

        // --- pending latch and software trigger ------------------------------
        pend   <= (pend | newly) & ~p_clr;
        swtrig <= (swtrig | sw_set) & ~s_clr;
        if (w_mask) begin
            mask_r <= bus_wdata;
        end

        // --- accept the published vector ------------------------------------
        if (acc_go) begin
            stk[{nest_depth, 3'b000} +: 5] <= cur_pri;
            cur_pri    <= {1'b0, irq_pri};
            nest_depth <= nest_depth + 3'd1;
            nested     <= active;
            if (svc_cnt < CNT_SAT) begin
                svc_cnt <= svc_cnt + 7'd1;
            end
        end

        // --- end of interrupt -----------------------------------------------
        if (eoi_ok) begin
            cur_pri    <= stk[{rd_idx, 3'b000} +: 5];
            nest_depth <= nest_depth - 3'd1;
            nested     <= 1'b0;
            if (eoi_cnt < CNT_SAT) begin
                eoi_cnt <= eoi_cnt + 7'd1;
            end
        end

        // --- error reporting, documented precedence -------------------------
        nxt_err = 4'h0;
        if (acc_of) begin
            nxt_err = ERR_BASE + 4'd3;
        end
        if (eoi_bad) begin
            nxt_err = ERR_BASE + 4'd2;
        end
        if (eoi_idle) begin
            nxt_err = ERR_BASE + 4'd1;
        end
        if (w_ill) begin
            nxt_err = ERR_BASE + 4'd0;
        end
        if (nxt_err != 4'h0) begin
            err_code <= nxt_err;
            if (err_count < CNT_SAT) begin
                err_count <= err_count + 7'd1;
            end
        end

        // --- published vector images for the next beat ----------------------
        irq_pri  <= sel;
        irq_oh   <= sel_oh;
        irq_req  <= req_n;
        ge       <= ge_n;
        blocked  <= blk_n;
        bus_ack  <= bus_we && !w_ill;
        case (bus_addr)
            A_MASK:   bus_rdata <= mask_r;
            A_SWTRIG: bus_rdata <= swtrig;
            A_PEND:   bus_rdata <= pend;
            A_INACT:  bus_rdata <= inact;
            A_VEC:    bus_rdata <= {8'h00, irq_vec};
            A_STAT:   bus_rdata <= {1'h0, inact_hit, cur_pri, nest_depth,
                                    err_code, irq_req, blocked};
            default:  bus_rdata <= INVALID_RD;
        endcase
    end
end

endmodule
