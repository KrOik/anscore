`timescale 1ns / 1ps
// ips_secded64_ecc : extended-Hamming SECDED(72,64) encoder / decoder pair.
//
// Coding theory used here (written independently of any RTL structure):
//   Codeword layout, one flat 72-bit vector, low check field first:
//       code[63:0]   data bits d0 .. d63
//       code[70+j]   Hamming check bit c_j, j = 0..6
//       code[71]     overall parity bit P (the extension bit)
//   The 64 data bits live at the 64 codeword POSITIONS that are not powers of
//   two inside 1..71, in ascending order: data bit i takes the (i+1)-th such
//   number, so position(0) = 3, position(1) = 5, position(2) = 6, ...
//   position(63) = 71.  The seven Hamming check bits take the positions
//   1, 2, 4, 8, 16, 32, 64 and the parity bit takes position 72.
//   Row j of the generator is therefore "the data bits whose position has bit
//   j set", which is exactly the ROW mask block below; a column is read back
//   out of the same masks, so encoder and decoder can never drift apart.
//   Syndrome basis: the raw Hamming syndrome is h[6:0] = H7 * code and the raw
//   parity check is p = XOR of all 72 bits.  The reported 8-bit syndrome is the
//   odd-weight basis s = {p ^ ^h, h}, i.e. the parity row replaced by
//   (parity row XOR the sum of the Hamming rows).  That row operation leaves
//   the code untouched and makes EVERY one of the 72 H columns an odd-weight
//   8-bit vector: column(q) = {1 ^ parity(q), q} for q = 1..71 and column(72)
//   = 8'h80.  Odd weight plus pairwise distinctness is the textbook proof of
//   d_min = 4: three odd-weight columns can never XOR to zero, two distinct
//   columns can never XOR to zero, so single errors are correctable and double
//   errors are always detected.
//   Classification: s == 0 -> clean; s != 0 with odd popcount -> correctable,
//   the flipped bit is at position h (position 72 when h == 0); s != 0 with
//   even popcount -> uncorrectable double error, and the core never attempts a
//   correction in that case (data_out passes the received bits through).
//
// Behaviour: one operation per start beat, one registered result per started
// beat (one clock of latency).  mode = 0 runs the encoder (the payload is read
// from code_in[63:0], the check field is ignored and forced to zero so the
// encoder's own syndrome is identically zero); mode = 1 runs the decoder over
// the full received codeword and writes back the corrected codeword.
// ce / ue / syndrome / syn_wt / err_pos report the decode result and the two
// 4-bit log counters saturate at CE_MAX / UE_MAX, with err_sticky latching the
// cause classes.  The datapath is pure XOR / compare logic: no adder other than
// the small popcount and counter increments, so no DSP is inferred (SOP trap
// T4).  The 72-bit codeword is one flat vector, never a packed 2-D array (T3).
// Every register, including the counters, sits in a clk_en-gated block behind
// the asynchronous reset (T2).
module ips_secded64_ecc (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        start,
    input  wire        mode,
    input  wire [71:0] code_in,

    output reg         done,
    output reg         ce,
    output reg         ue,
    output reg  [63:0] data_out,
    output reg   [7:0] chk_out,
    output reg  [71:0] code_out,
    output reg   [7:0] syndrome,
    output reg   [3:0] syn_wt,
    output reg   [6:0] err_pos,
    output reg   [3:0] ce_cnt,
    output reg   [3:0] ue_cnt,
    output reg   [1:0] err_sticky
);

// Reporting geometry: the overall parity bit sits at codeword position 72, and
// the two error log counters stop counting once they reach their ceiling.
localparam [6:0]  PAR_POS = 7'd72;
localparam [3:0]  CE_MAX  = 4'hF;
localparam [3:0]  UE_MAX  = 4'hF;

// Generator rows: ROWj bit i is set when data bit i sits at a codeword position
// whose bit j is set.  These seven masks are the whole H matrix.
localparam [63:0] ROW0 = 64'hAB55555556AAAD5B;
localparam [63:0] ROW1 = 64'hCD9999999B33366D;
localparam [63:0] ROW2 = 64'hF1E1E1E1E3C3C78E;
localparam [63:0] ROW3 = 64'h01FE01FE03FC07F0;
localparam [63:0] ROW4 = 64'h01FFFE0003FFF800;
localparam [63:0] ROW5 = 64'h01FFFFFFFC000000;
localparam [63:0] ROW6 = 64'hFE00000000000000;

function [3:0] bit_weight;
    input [7:0] v;
    integer k;
    reg [3:0] acc;
    begin
        acc = 4'd0;
        for (k = 0; k < 8; k = k + 1) begin
            if (v[k]) begin
                acc = acc + 4'd1;
            end
        end
        bit_weight = acc;
    end
endfunction

wire [63:0] dat  = code_in[63:0];

// Seven shared XOR trees: they are the encoder's check bits and, XORed against
// the received check field, the decoder's Hamming syndrome.  dpar is the data
// half of the overall parity equation.
wire [6:0] nat;
assign nat[0] = ^(dat & ROW0);
assign nat[1] = ^(dat & ROW1);
assign nat[2] = ^(dat & ROW2);
assign nat[3] = ^(dat & ROW3);
assign nat[4] = ^(dat & ROW4);
assign nat[5] = ^(dat & ROW5);
assign nat[6] = ^(dat & ROW6);
wire       dpar  = ^dat;
wire       calc_par = dpar ^ (^nat);

// An encode beat presents the freshly computed check field to the syndrome
// network, so the encoder's self-check syndrome is identically zero.
wire [6:0] rchk = mode ? code_in[70:64] : nat;
wire       rpar = mode ? code_in[71]    : calc_par;

wire [6:0] syn_h = nat ^ rchk;
wire       pchk  = dpar ^ (^rchk) ^ rpar;
wire [7:0] syn   = {pchk ^ (^syn_h), syn_h};

// Odd-weight syndromes are correctable, non-zero even-weight ones are the
// detected double-error signature.
wire any_err = (|syn);
wire ce_w    = any_err &  (^syn);
wire ue_w    = any_err & ~(^syn);

// One correction term per data bit, built from the column read back out of the
// generator masks, so a moved column moves encoder and decoder together.
wire [63:0] flip;
genvar g;
generate
    for (g = 0; g < 64; g = g + 1) begin : g_flip
        wire [6:0] col_c = {ROW6[g], ROW5[g], ROW4[g], ROW3[g], ROW2[g], ROW1[g], ROW0[g]};
        wire       hit_c = (col_c != 7'd0) && (col_c == syn_h);
        assign flip[g] = ce_w & hit_c;
    end
endgenerate

wire [63:0] corr_data = dat ^ flip;
wire        data_err  = ce_w & (|flip);
wire [6:0]  dec_chk   = nat ^ (syn_h & {7{data_err}});
wire [6:0]  raw_chk   = code_in[70:64];
wire [6:0]  corr_chk  = ce_w ? dec_chk : (mode ? raw_chk : nat);
wire        par_fix   = code_in[71] ^ ~(|syn_h);
wire        out_par   = mode ? (ce_w ? par_fix : code_in[71]) : calc_par;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done       <= 1'b0;
        ce         <= 1'b0;
        ue         <= 1'b0;
        data_out   <= 64'h0;
        chk_out    <= 8'h00;
        code_out   <= 72'h0;
        syndrome   <= 8'h00;
        syn_wt     <= 4'h0;
        err_pos    <= 7'd0;
        ce_cnt     <= 4'h0;
        ue_cnt     <= 4'h0;
        err_sticky <= 2'b00;
    end else if (clk_en) begin
        done <= start;
        if (start) begin
            ce       <= ce_w;
            ue       <= ue_w;
            data_out <= corr_data;
            chk_out  <= {out_par, corr_chk};
            code_out <= {out_par, corr_chk, corr_data};
            syndrome <= syn;
            syn_wt   <= bit_weight(syn);
            err_pos  <= ce_w ? ((|syn_h) ? syn_h : PAR_POS) : 7'd0;
            if (ce_w) begin
                err_sticky[0] <= 1'b1;
                if (ce_cnt < CE_MAX) begin
                    ce_cnt <= ce_cnt + 4'h1;
                end
            end
            if (ue_w) begin
                err_sticky[1] <= 1'b1;
                if (ue_cnt < UE_MAX) begin
                    ue_cnt <= ue_cnt + 4'h1;
                end
            end
        end
    end
end

endmodule
