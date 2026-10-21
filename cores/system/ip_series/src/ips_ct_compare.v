`timescale 1ns / 1ps
// ips_ct_compare : whole-stream content/length comparator with an accumulate-
// never-exit difference register and per-beat match/mismatch accounting.
//
// Candidate and reference words are compared beat by beat.  Every beat is
// processed even after a difference has been seen and even after end-of-stream:
// the difference is folded into a rotating OR accumulator (rotate-xor-add style,
// no early exit, no cancellation) and the matched / mismatched beat counters keep
// counting.  The stream length is checked against the length latched at
// cmp_start; a length violation sets len_err and folds LEN_BAD_CONST into the
// accumulator so a short or overlong stream cannot read back as equal.
//
// PROTOTYPE / TEST-GATED: this core only proves functional whole-stream
// accumulation; constant-time and power/EM leakage behaviour is NOT verified
// here (no TVLA, no formal evidence) and board evidence is DEFERRED.
module ips_ct_compare #(
    parameter WIDTH         = 32,
    parameter LEN_BITS      = 12,
    parameter ROT_BITS      = 5,
    parameter LEN_BAD_CONST = 32'hD2E7_0001
)(
    input  wire                   clk,
    input  wire                   clk_en,
    input  wire                   rst_n,

    input  wire                   cmp_start,
    input  wire  [LEN_BITS-1:0]   exp_len,
    input  wire                   in_valid,
    input  wire                   in_last,
    input  wire  [WIDTH-1:0]      cand_word,
    input  wire  [WIDTH-1:0]      ref_word,

    output reg   [WIDTH-1:0]      diff_acc,
    output reg   [LEN_BITS-1:0]   match_cnt,
    output reg   [LEN_BITS-1:0]   mismatch_cnt,
    output reg   [LEN_BITS-1:0]   beat_cnt,
    output reg   [LEN_BITS-1:0]   exp_cnt,
    output reg                    len_err,
    output reg                    cmp_done
);

// Unrolled difference of the current beat: zero exactly when the two words are
// identical.  d_zero only steers the counters; the accumulator always updates.
wire [WIDTH-1:0] dword = cand_word ^ ref_word;
wire             d_zero = (dword == {WIDTH{1'b0}});

wire [WIDTH-1:0] rol_acc  = (diff_acc << ROT_BITS) | (diff_acc >> (WIDTH - ROT_BITS));
wire [WIDTH-1:0] acc_next = rol_acc | dword;

wire [LEN_BITS-1:0] beat_next    = beat_cnt + 1;
wire [LEN_BITS-1:0] match_next   = match_cnt + 1;
wire [LEN_BITS-1:0] unmatch_next = mismatch_cnt + 1;
wire                length_bad   = (beat_next != exp_cnt);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        diff_acc     <= {WIDTH{1'b0}};
        match_cnt    <= {LEN_BITS{1'b0}};
        mismatch_cnt <= {LEN_BITS{1'b0}};
        beat_cnt     <= {LEN_BITS{1'b0}};
        exp_cnt      <= {LEN_BITS{1'b0}};
        len_err      <= 1'b0;
        cmp_done     <= 1'b0;
    end else if (clk_en) begin
        if (cmp_start) begin
            diff_acc     <= {WIDTH{1'b0}};
            match_cnt    <= {LEN_BITS{1'b0}};
            mismatch_cnt <= {LEN_BITS{1'b0}};
            beat_cnt     <= {LEN_BITS{1'b0}};
            exp_cnt      <= exp_len;
            len_err      <= 1'b0;
            cmp_done     <= 1'b0;
        end else if (in_valid) begin
            // No early exit: the accumulator and both counters move on every
            // beat, including beats that arrive after in_last.
            if (in_last && length_bad) begin
                diff_acc <= acc_next ^ LEN_BAD_CONST;
                len_err  <= 1'b1;
            end else begin
                diff_acc <= acc_next;
            end
            beat_cnt <= beat_next;
            if (d_zero) begin
                match_cnt <= match_next;
            end else begin
                mismatch_cnt <= unmatch_next;
            end
            if (in_last) begin
                cmp_done <= 1'b1;
            end
        end
    end
end

endmodule
