`timescale 1ns / 1ps
// tb_ips_rr_arbiter4 : production-line testbench for the four-master round-robin
// arbiter.
//
// Folding rule (mirrored by models/ips_rr_arbiter4.py): one enabled rising edge is
// one beat; on every beat exactly these five 32-bit words are folded with
// ips_fnv_word, in this order and with these alignments:
//   W0 = {7'd0, svc_hist, starve_hit, hold_cnt, grant_valid, fair_ok,
//         grant_idx, prio_ptr, grant}
//   W1 = {8'd0, starve_all}                       // starve_all = {s3,s2,s1,s0}
//   W2 = {26'd0, starve_max}
//   W3 = {24'd0, txn_count}
//   W4 = {26'd0, err_cause, err_seen}
// then the run closes with {24'd0, txn_count}, {26'd0, err_cause, err_seen},
// {8'd0, starve_all} and BEATS.  Disabled beats (clk_en low) step neither the DUT
// nor the counter, and fold nothing.
//
// The expectation is NOT written here: models/ips_rr_arbiter4.py replays the
// arbiter contract independently and the gate compares the two digests
// (docs/IP_CORE_SOP.md trap T1).  Every check uses === so an X can never read as a
// pass (trap T6).  Stimulus phases, all deterministic:
//   0..19    idle bus                (grant-while-idle must be 0)
//   20..35   one requester at a time (walk masters 0..3, ack on the 4th beat)
//   36..99   all four request, ack echoes the held grant (strict rotation)
//   100..164 all four request, no ack (lock-on-grant + starvation saturation)
//   165..171 the granted master drops while the others keep asking (simultaneous
//            request/release; a dropped requester must never be granted)
//   172..179 idle bus with illegal acks: one stray ack, then two acks at once
//   180..359 randomised legal traffic from the shared LCG, with four disabled
//            clock beats at i % 37 == 11
//   360..419 drain, nothing requests
module tb_ips_rr_arbiter4;

`include "ips_tb_common.vh"

localparam integer BEATS = 420;
localparam [31:0]  SEED  = 32'h2A5B7C04;

reg               rst_n;
reg               clk_en;
reg               en_beat;
reg [3:0]         req;
reg [3:0]         ack;
reg [31:0]        state;

wire [3:0]        grant;
wire              grant_valid;
wire [1:0]        grant_idx;
wire              fair_ok;
wire [2:0]        hold_cnt;
wire [23:0]       starve_all;
wire [5:0]        starve_max;
wire [1:0]        prio_ptr;
wire [7:0]        svc_hist;
wire [3:0]        starve_hit;
wire [7:0]        txn_count;
wire [1:0]        err_cause;
wire [3:0]        err_seen;

// No #() override: the core's declared defaults are the shipped configuration, and
// overriding them here would hide the defaults from the mutation station.
ips_rr_arbiter4 dut (
    .clk         (ips_clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .req         (req),
    .ack         (ack),
    .grant       (grant),
    .grant_valid (grant_valid),
    .grant_idx   (grant_idx),
    .fair_ok     (fair_ok),
    .hold_cnt    (hold_cnt),
    .starve_all  (starve_all),
    .starve_max  (starve_max),
    .prio_ptr    (prio_ptr),
    .svc_hist    (svc_hist),
    .starve_hit  (starve_hit),
    .txn_count   (txn_count),
    .err_cause   (err_cause),
    .err_seen    (err_seen)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer m;
integer j;
integer err_changes;
integer rot_changes;
reg     bad;
reg     got_prev;
reg     sat_seen;
reg     fair_seen;
reg     drop_seen;
reg     [3:0]  prev_grant;
reg     [1:0]  prev_idx;
reg     [1:0]  prev_ptr;
reg     [2:0]  prev_hold;
reg     [7:0]  prev_svc;
reg     [3:0]  prev_starve_hit;
reg     [3:0]  prev_err_seen;
reg     [1:0]  prev_err_cause;
reg     [7:0]  prev_txn;
reg     [23:0] prev_starve;
reg            prev_valid;
reg     [23:0] starve_now;

// The strict fairness expectation is derived here from the contract text: scan the
// request vector cyclically upward from the restart point and take the first
// requester.  It is an independent check of the DUT's rotate/lowest-bit logic.
function [3:0] rr_expect;
    input [3:0] r;
    input [1:0] base;
    reg   [3:0] k;
    reg   [1:0] c;
    reg         found;
    begin
        found     = 1'b0;
        rr_expect = 4'b0000;
        for (k = 4'd0; k < 4'd4; k = k + 4'd1) begin
            c = base + k[1:0];
            if (!found && r[c]) begin
                found     = 1'b1;
                rr_expect = 4'b0001 << c;
            end
        end
    end
endfunction

function [5:0] tb_mx2;
    input [5:0] a;
    input [5:0] b;
    begin
        tb_mx2 = (a > b) ? a : b;
    end
endfunction

function [5:0] tb_max4;
    input [23:0] sv;
    begin
        tb_max4 = tb_mx2(tb_mx2(sv[5:0], sv[11:6]), tb_mx2(sv[17:12], sv[23:18]));
    end
endfunction

function onehot;
    input [3:0] v;
    begin
        onehot = ((v & (v - 4'b0001)) == 4'b0000) && (v != 4'b0000);
    end
endfunction

initial begin
    ips_fnv_reset();
    rst_n           = 1'b0;
    clk_en          = 1'b0;
    req             = 4'h0;
    ack             = 4'h0;
    state           = SEED;
    bad             = 1'b0;
    got_prev        = 1'b0;
    sat_seen        = 1'b0;
    fair_seen       = 1'b0;
    drop_seen       = 1'b0;
    err_changes     = 0;
    rot_changes     = 0;
    prev_grant      = 4'h0;
    prev_idx        = 2'd0;
    prev_ptr        = 2'd0;
    prev_hold       = 3'd0;
    prev_svc        = 8'h00;
    prev_starve_hit = 4'h0;
    prev_err_seen   = 4'h0;
    prev_err_cause  = 2'd0;
    prev_txn        = 8'h00;
    prev_starve     = 24'h000000;
    prev_valid      = 1'b0;

    repeat (4) @(negedge ips_clk);
    rst_n = 1'b1;
    repeat (3) @(negedge ips_clk);
    // Capture the reset state of the outputs without spending an enabled beat, so
    // the comparative checks start from the core's own initial pointer value.
    prev_ptr   = prio_ptr;
    prev_valid = grant_valid;
    prev_grant = grant;
    prev_idx   = grant_idx;
    prev_hold  = hold_cnt;
    got_prev   = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        // ---- deterministic phase schedule --------------------------------------
        if (i < 20) begin
            req = 4'h0;
            ack = 4'h0;
        end else if (i < 36) begin
            m   = ((i - 20) / 4) % 4;
            req = 4'b0001 << m;
            ack = (((i - 20) % 4) == 3) ? grant : 4'h0;
        end else if (i < 100) begin
            req = 4'hF;
            ack = grant;
        end else if (i < 165) begin
            req = 4'hF;
            ack = 4'h0;
        end else if (i < 172) begin
            req = 4'hF & ~grant;
            ack = 4'h0;
        end else if (i < 180) begin
            req = 4'h0;
            case ((i - 172) % 6)
                0:       ack = 4'h4;
                2:       ack = 4'hC;
                4:       ack = 4'h2;
                default: ack = 4'h0;
            endcase
        end else if (i < 360) begin
            req = state[3:0];
            ack = state[15] ? grant : 4'h0;
        end else begin
            req = 4'h0;
            ack = 4'h0;
        end
        state   = state * 32'd1664525 + 32'd1013904223;
        en_beat = !((i >= 180) && ((i % 37) == 11));
        clk_en  = en_beat;

        @(negedge ips_clk);
        // Exactly one rising edge lies between the drive point and this sample
        // point; the next edge is blocked again so one loop iteration is exactly
        // one enabled beat of the DUT and of ips_cycle.
        clk_en = 1'b0;
        if (en_beat === 1'b1) begin
            // ---- property checks ----------------------------------------------
            if ((^grant === 1'bx) || (grant_valid === 1'bx) || (^grant_idx === 1'bx) ||
                (^prio_ptr === 1'bx) || (^starve_all === 1'bx) || (^starve_max === 1'bx) ||
                (^svc_hist === 1'bx) || (^starve_hit === 1'bx) || (^txn_count === 1'bx) ||
                (^err_cause === 1'bx) || (^err_seen === 1'bx) || (fair_ok === 1'bx) ||
                (^hold_cnt === 1'bx)) begin
                bad = 1'b1;
            end

            // grant-while-idle, one-hot and dropped-requester rules
            if (grant_valid === 1'b1 && !onehot(grant)) bad = 1'b1;
            if (grant_valid === 1'b0 && grant !== 4'h0) bad = 1'b1;
            if (grant_valid === 1'b0 && grant_idx !== 2'd0) bad = 1'b1;
            if (req === 4'h0 && grant_valid !== 1'b0) bad = 1'b1;
            if (grant_valid === 1'b1 && req[grant_idx] !== 1'b1) bad = 1'b1;

            // the restart point tracks the grant one step behind it and freezes
            // while the bus is idle
            if (grant_valid === 1'b1 && (prio_ptr !== (grant_idx + 2'd1))) bad = 1'b1;
            if (grant_valid === 1'b0 && (prio_ptr !== prev_ptr)) bad = 1'b1;

            // lock-step fairness: any change of grant is a selection from the
            // restart point observed on the previous beat
            if ((grant !== prev_grant) || (grant_valid !== prev_valid)) begin
                if (grant !== rr_expect(req, prev_ptr)) bad = 1'b1;
                if (grant_valid === 1'b1) begin
                    if (hold_cnt !== 3'd0) bad = 1'b1;
                    if (svc_hist !== {prev_svc[5:0], grant_idx}) bad = 1'b1;
                end
            end
            // lock-on-grant: the held master can only be replaced after it drops
            // its request or acknowledges
            if (grant_valid === 1'b1 && prev_valid === 1'b1 &&
                grant_idx !== prev_idx) begin
                if (req[prev_idx] === 1'b1 && ack[prev_idx] === 1'b0) bad = 1'b1;
                if (req === 4'hF) begin
                    // strict rotation while all four request, not merely "a grant"
                    if (grant_idx !== (prev_idx + 2'd1)) bad = 1'b1;
                    rot_changes = rot_changes + 1;
                end
            end
            if (grant_valid === 1'b1 && prev_valid === 1'b1 && grant !== prev_grant &&
                req[prev_idx] === 1'b0) begin
                drop_seen = 1'b1;
            end

            // hold counter accounting
            if (grant_valid === 1'b0 && hold_cnt !== 3'd0) bad = 1'b1;
            if (grant_valid === 1'b1 && prev_valid === 1'b1 && grant === prev_grant) begin
                if (!(hold_cnt === prev_hold || hold_cnt === (prev_hold + 3'd1) ||
                      hold_cnt === 3'd0)) bad = 1'b1;
            end

            // starvation counters replayed from the folded history: a master that
            // is pending and ungranted grows by one or stays (saturated, never
            // wrapping); any other master reads exactly zero
            starve_now = starve_all;
            for (j = 0; j < 4; j = j + 1) begin
                if (req[j] === 1'b1 &&
                    !(grant_valid === 1'b1 && grant[j] === 1'b1)) begin
                    if (!(starve_now[6*j +: 6] === prev_starve[6*j +: 6] ||
                          starve_now[6*j +: 6] === (prev_starve[6*j +: 6] + 6'd1))) begin
                        bad = 1'b1;
                    end
                    if (starve_now[6*j +: 6] === prev_starve[6*j +: 6]) begin
                        sat_seen = 1'b1;
                    end
                end else if (starve_now[6*j +: 6] !== 6'd0) begin
                    bad = 1'b1;
                end
            end
            if (starve_max !== tb_max4(starve_now)) bad = 1'b1;
            if ((starve_hit & prev_starve_hit) !== prev_starve_hit) bad = 1'b1;
            if (!(txn_count === prev_txn || txn_count === (prev_txn + 8'h01))) bad = 1'b1;
            if ((err_seen & prev_err_seen) !== prev_err_seen) bad = 1'b1;
            if (err_cause !== prev_err_cause) err_changes = err_changes + 1;
            if (err_changes > 1) bad = 1'b1;
            if (fair_ok === 1'b1) fair_seen = 1'b1;

            // ---- fold ----------------------------------------------------------
            ips_fnv_word({7'd0, svc_hist, starve_hit, hold_cnt, grant_valid,
                          fair_ok, grant_idx, prio_ptr, grant});
            ips_fnv_word({8'd0, starve_all});
            ips_fnv_word({26'd0, starve_max});
            ips_fnv_word({24'd0, txn_count});
            ips_fnv_word({26'd0, err_cause, err_seen});
            prev_grant      = grant;
            prev_valid      = grant_valid;
            prev_idx        = grant_idx;
            prev_ptr        = prio_ptr;
            prev_hold       = hold_cnt;
            prev_svc        = svc_hist;
            prev_starve_hit = starve_hit;
            prev_txn        = txn_count;
            prev_err_seen   = err_seen;
            prev_err_cause  = err_cause;
            prev_starve     = starve_now;
        end
    end

    // ---- the run must have exercised what it claims ----------------------------
    if (txn_count === 8'h00) bad = 1'b1;
    if (starve_hit === 4'h0) bad = 1'b1;
    if (err_seen === 4'h0) bad = 1'b1;
    if (sat_seen === 1'b0) bad = 1'b1;
    if (fair_seen === 1'b0) bad = 1'b1;
    if (drop_seen === 1'b0) bad = 1'b1;
    if (rot_changes < 4) bad = 1'b1;
    if (grant_valid !== 1'b0) bad = 1'b1;
    if (starve_max !== 6'h00) bad = 1'b1;

    repeat (2) @(negedge ips_clk);
    ips_fnv_word({24'd0, txn_count});
    ips_fnv_word({26'd0, err_cause, err_seen});
    ips_fnv_word({8'd0, starve_all});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_rr_arbiter4");
end

endmodule
