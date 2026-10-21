`timescale 1ns / 1ps
// ips_rr_arbiter4 : four-master round-robin arbiter with lock-on-grant, per-master
// saturating starvation counters and a lock-step fairness history, for the
// ip_series_20k production line.
//
// Written contract, replayed cycle-exactly by models/ips_rr_arbiter4.py.  Neither
// side is back-filled from simulation output (docs/IP_CORE_SOP.md trap T1).  One
// step of the arbiter is one enabled rising edge (clk_en high and rst_n high);
// every register is gated by clk_en and rst_n is the active-low asynchronous reset
// (trap T2).  req and ack are sampled in the window before that edge, and grant,
// grant_valid, grant_idx, prio_ptr, hold_cnt, starve_*, svc_hist, txn_count and the
// error words are the registered state that edge produced, so every reported value
// is settled for the whole beat.
//
//   releasing  = rvalid && ( !req[cur] || (ack[cur] && hold >= HOLD_MIN) )
//   sel_active = !rvalid || releasing, with cur the index of the held grant.  While
//   sel_active the request vector is scanned cyclically upward from prio_ptr and the
//   first requester wins: grant_valid = |req, grant is its one-hot.  While
//   !sel_active the held master is kept, so no other master can be granted in
//   between (lock-on-grant).
//   A requester that drops its request is therefore never granted, and an ack cannot
//   release a grant until hold - the number of enabled steps this grant has been
//   held, 0 on the step that issues it, saturating at 3'h6 - has reached HOLD_MIN.
//   Rotation: prio_ptr <= grant_idx + 1 on any step that issues a grant, and
//   prio_ptr does not move while grant_valid is low, so the restart point after a
//   release is the next master in strict cyclic order.
//   txn_count steps once per released transaction and saturates at 8'hFF.
//   Starvation, per master j, with pd_j = req[j] and gr_j = grant_valid && grant[j]
//   of the grant this step decided: starve_j <= 0 unless pd_j && !gr_j, otherwise
//   starve_j <= starve_j when starve_j >= STARVE_LIMIT and starve_j + 1 below it.  A
//   counter therefore only grows while its master is pending and ungranted, it
//   saturates at STARVE_LIMIT and it never wraps.  The step that leaves a counter at
//   STARVE_LIMIT while that master is still pending and ungranted sets the sticky
//   starve_hit bit.
//   Lock-step fairness: svc_hist shifts grant_idx in on every step that selects, so
//   {h3,h2,h1,h0} is the last four selections oldest-first and fair_ok marks those
//   four indices pairwise distinct - with four masters that is exactly one full
//   round-robin revolution.
//   Error causes: the first captured cause latches err_cause and every cause ever
//   seen sets its own err_seen bit, with precedence ERR_MPOP_ACK, then ERR_ACK_NOG,
//   then ERR_STARVE.
//     ERR_NONE      nothing latched
//     ERR_MPOP_ACK  two or more ack bits were high in one enabled step
//     ERR_ACK_NOG   an ack was pulsed while the step started with no grant held
//     ERR_STARVE    a master reached STARVE_LIMIT while pending and ungranted
//   grant is zero whenever grant_valid is low, so an idle bus never shows a grant,
//   and grant is one-hot whenever grant_valid is high.
module ips_rr_arbiter4 #(
    parameter [5:0] STARVE_LIMIT = 6'd20,
    parameter [2:0] HOLD_MIN     = 3'd2,
    parameter [1:0] PRIO_INIT    = 2'd0
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire [3:0]  req,
    input  wire [3:0]  ack,

    output wire [3:0]  grant,
    output wire        grant_valid,
    output wire [1:0]  grant_idx,
    output wire        fair_ok,
    output wire [2:0]  hold_cnt,
    output wire [23:0] starve_all,
    output wire [5:0]  starve_max,
    output reg  [1:0]  prio_ptr,
    output reg  [7:0]  svc_hist,
    output reg  [3:0]  starve_hit,
    output reg  [7:0]  txn_count,
    output reg  [1:0]  err_cause,
    output reg  [3:0]  err_seen
);

localparam [1:0] ERR_NONE     = 2'd0;
localparam [1:0] ERR_MPOP_ACK = 2'd1;
localparam [1:0] ERR_ACK_NOG  = 2'd2;
localparam [1:0] ERR_STARVE   = 2'd3;
localparam [2:0] HOLD_SAT     = 3'h6;
localparam [7:0] TXN_SAT      = 8'hFF;

reg        rvalid;
reg [3:0]  rgnt;
reg [2:0]  hold;
reg [1:0]  cur;
reg [5:0]  s0;
reg [5:0]  s1;
reg [5:0]  s2;
reg [5:0]  s3;

assign grant       = rgnt;
assign grant_valid = rvalid;
assign grant_idx   = cur;

wire       rel_drop   = rvalid && !req[cur];
wire       rel_ack    = rvalid && ack[cur] && (hold >= HOLD_MIN);
wire       releasing  = rel_drop || rel_ack;
wire       sel_active = !rvalid || releasing;

wire [7:0] dup    = {req, req};
wire [7:0] rot    = dup >> prio_ptr;
wire [7:0] lowbit = rot & (~rot + 8'h01);
wire [7:0] back   = lowbit << prio_ptr;
wire [3:0] scan_g = back[3:0] | back[7:4];
wire [1:0] scan_i = {scan_g[3] | scan_g[2], scan_g[3] | scan_g[1]};
wire       anyreq = |req;

wire       nvalid = sel_active ? anyreq : 1'b1;
wire [3:0] ngnt   = sel_active ? (anyreq ? scan_g : 4'b0000) : rgnt;
wire [1:0] nidx   = sel_active ? scan_i   : cur;

wire gr0 = nvalid && ngnt[0];
wire gr1 = nvalid && ngnt[1];
wire gr2 = nvalid && ngnt[2];
wire gr3 = nvalid && ngnt[3];

wire [5:0] sn0 = starve_nx(s0, req[0], gr0);
wire [5:0] sn1 = starve_nx(s1, req[1], gr1);
wire [5:0] sn2 = starve_nx(s2, req[2], gr2);
wire [5:0] sn3 = starve_nx(s3, req[3], gr3);

wire hit0 = (sn0 == STARVE_LIMIT) && req[0] && !gr0;
wire hit1 = (sn1 == STARVE_LIMIT) && req[1] && !gr1;
wire hit2 = (sn2 == STARVE_LIMIT) && req[2] && !gr2;
wire hit3 = (sn3 == STARVE_LIMIT) && req[3] && !gr3;
wire [3:0] hit_new = {hit3, hit2, hit1, hit0};
wire       any_hit = |hit_new;

wire       ack_one   = |ack;
wire [3:0] ack_clear = ack & (ack - 4'b0001);
wire       ack_multi = ack_one && (ack_clear != 4'b0000);
wire       ack_nog   = ack_one && !rvalid;

assign hold_cnt   = hold;
assign starve_all = {s3, s2, s1, s0};

wire [1:0] h0 = svc_hist[1:0];
wire [1:0] h1 = svc_hist[3:2];
wire [1:0] h2 = svc_hist[5:4];
wire [1:0] h3 = svc_hist[7:6];
assign fair_ok = (h0 != h1) && (h0 != h2) && (h0 != h3) &&
                 (h1 != h2) && (h1 != h3) && (h2 != h3);

wire [5:0] starve_max_w = mx2(mx2(s0, s1), mx2(s2, s3));
assign starve_max = starve_max_w;

function [5:0] starve_nx;
    input [5:0] cur_v;
    input       pd;
    input       gr;
    begin
        if (!pd || gr) begin
            starve_nx = 6'h00;
        end else if (cur_v >= STARVE_LIMIT) begin
            starve_nx = cur_v;
        end else begin
            starve_nx = cur_v + 6'h01;
        end
    end
endfunction

function [5:0] mx2;
    input [5:0] a;
    input [5:0] b;
    begin
        mx2 = (a > b) ? a : b;
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rvalid     <= 1'b0;
        rgnt       <= 4'b0000;
        cur        <= 2'd0;
        hold       <= 3'd0;
        prio_ptr   <= PRIO_INIT;
        s0         <= 6'h00;
        s1         <= 6'h00;
        s2         <= 6'h00;
        s3         <= 6'h00;
        starve_hit <= 4'b0000;
        svc_hist   <= 8'h00;
        txn_count  <= 8'h00;
        err_cause  <= ERR_NONE;
        err_seen   <= 4'b0000;
    end else if (clk_en) begin
        rvalid <= nvalid;
        rgnt   <= ngnt;
        cur    <= nidx;
        if (nvalid) begin
            prio_ptr <= nidx + 2'd1;
        end
        if (!nvalid || sel_active) begin
            hold <= 3'd0;
            if (nvalid && sel_active) begin
                svc_hist <= {svc_hist[5:0], nidx};
            end
        end else if (hold < HOLD_SAT) begin
            hold <= hold + 3'd1;
        end
        if (releasing && (txn_count != TXN_SAT)) begin
            txn_count <= txn_count + 8'h01;
        end
        s0 <= sn0;
        s1 <= sn1;
        s2 <= sn2;
        s3 <= sn3;
        starve_hit <= starve_hit | hit_new;
        if (ack_multi) begin
            err_seen[ERR_MPOP_ACK] <= 1'b1;
        end
        if (ack_nog) begin
            err_seen[ERR_ACK_NOG] <= 1'b1;
        end
        if (any_hit) begin
            err_seen[ERR_STARVE] <= 1'b1;
        end
        if (err_cause == ERR_NONE) begin
            if (ack_multi) begin
                err_cause <= ERR_MPOP_ACK;
            end else if (ack_nog) begin
                err_cause <= ERR_ACK_NOG;
            end else if (any_hit) begin
                err_cause <= ERR_STARVE;
            end
        end
    end
end

endmodule
