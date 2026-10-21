`timescale 1ns / 1ps
// ips_frame_len_crc : length-prefixed packet deframer with an embedded CRC-8
// accumulator, regenerated framing fields, and separate sticky rejection
// counters for over-length and truncated frames.
//
// Wire format, one byte per in_valid beat:
//     [LEN] [P0 .. P(LEN-1)] [CRC]
//   LEN : payload byte count, carried by the byte asserted with in_start.
//   CRC : CRC-8 (poly CRC_POLY, seed CRC_SEED, MSB first, no reflection, no final
//         xor) accumulated over the LEN field and every payload byte.  The check
//         byte itself is not accumulated, so a good frame satisfies
//         out_crc === out_recv_crc.
//
// For every terminated frame the core emits exactly one report beat, one clock
// after the terminating byte: out_valid pulses with out_len, the regenerated
// framer check byte out_crc, the received byte out_recv_crc and out_ok.  Frames
// rejected at the length field report out_crc = 8'h00 and out_recv_crc = 8'h00
// because no check byte was ever seen.  Bytes that arrive while no frame is in
// flight are dropped (the deframer re-synchronises on in_start).  A start pulse
// inside a frame abandons that frame, is logged as a restart event, and the same
// byte is re-parsed as the new length field.
//
// Accounting is explicit and sticky, because this core exists to evidence other
// designs: over-length, truncation, bad-CRC and restart events drive separate
// 4-bit saturating counters, err_sticky latches every cause seen since reset, and
// cnt_sat[n] latches as soon as a further event arrives while counter n already
// holds CNT_MAX -- saturation is reported instead of wrapping silently.
// in_ready is the deframer busy flag, high only while no frame is in flight.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).  The CRC path is a pure XOR tree: no
// multiply, so no DSP (trap T4).
module ips_frame_len_crc #(
    parameter CRC_POLY = 8'h07,
    parameter CRC_SEED = 8'hFF,
    parameter MAX_LEN  = 20
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        in_valid,
    input  wire        in_start,
    input  wire        in_last,
    input  wire  [7:0] in_byte,

    output wire        in_ready,
    output reg         out_valid,
    output reg         out_ok,
    output reg   [7:0] out_len,
    output reg   [7:0] out_crc,
    output reg   [7:0] out_recv_crc,
    output reg   [7:0] crc_run,
    output reg   [3:0] err_sticky,
    output reg   [3:0] cnt_good,
    output reg   [3:0] cnt_bad_crc,
    output reg   [3:0] cnt_over_len,
    output reg   [3:0] cnt_trunc,
    output reg   [3:0] cnt_restart,
    output reg   [4:0] cnt_sat
);

// CRC-8 step over one byte: shift/xor only, unrolled by the constant loop bound.
function [7:0] crc_step;
    input [7:0] c_in;
    input [7:0] d_in;
    integer k;
    reg [7:0] c;
    begin
        c = c_in ^ d_in;
        for (k = 0; k < 8; k = k + 1) begin
            if (c[7]) begin
                c = {c[6:0], 1'b0} ^ CRC_POLY;
            end else begin
                c = {c[6:0], 1'b0};
            end
        end
        crc_step = c;
    end
endfunction

localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_DATA = 2'd1;
localparam [1:0] S_CRC  = 2'd2;
localparam [3:0] CNT_MAX = 4'hF;

localparam [7:0] LEN_MAX  = MAX_LEN;
localparam [7:0] SEED_VAL = CRC_SEED;
localparam [7:0] NO_CHECK_BYTE = 8'h00;

reg [1:0] st;
reg [7:0] rem;
reg [7:0] len_r;

// Combinational busy decode: a new length field is accepted only while idle.
assign in_ready = (st == S_IDLE);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st           <= S_IDLE;
        rem          <= 8'h00;
        len_r        <= 8'h00;
        crc_run      <= 8'h00;
        out_valid    <= 1'b0;
        out_ok       <= 1'b0;
        out_len      <= 8'h00;
        out_crc      <= 8'h00;
        out_recv_crc <= 8'h00;
        err_sticky   <= 4'h0;
        cnt_good     <= 4'h0;
        cnt_bad_crc  <= 4'h0;
        cnt_over_len <= 4'h0;
        cnt_trunc    <= 4'h0;
        cnt_restart  <= 4'h0;
        cnt_sat      <= 5'h0;
    end else if (clk_en) begin
        out_valid <= 1'b0;
        if (in_valid) begin
            if (in_start && (st != S_IDLE)) begin
                // Start pulse inside a frame: abandon it, log the restart, and let
                // this same byte be re-parsed as the new length field below.
                if (cnt_restart < CNT_MAX) begin
                    cnt_restart <= cnt_restart + 4'h1;
                end else begin
                    cnt_sat[4] <= 1'b1;
                end
                err_sticky[3] <= 1'b1;
            end
            if (in_start) begin
                if (in_last) begin
                    // Length field carries the last marker: the frame has no payload
                    // and no check byte, so it is truncated.
                    out_valid    <= 1'b1;
                    out_ok       <= 1'b0;
                    out_len      <= in_byte;
                    out_crc      <= NO_CHECK_BYTE;
                    out_recv_crc <= NO_CHECK_BYTE;
                    st           <= S_IDLE;
                    rem          <= 8'h00;
                    err_sticky[2] <= 1'b1;
                    if (cnt_trunc < CNT_MAX) begin
                        cnt_trunc <= cnt_trunc + 4'h1;
                    end else begin
                        cnt_sat[2] <= 1'b1;
                    end
                end else if (in_byte > LEN_MAX) begin
                    // Over-length frame: rejected at its length field, never allowed
                    // to occupy the payload path.
                    out_valid    <= 1'b1;
                    out_ok       <= 1'b0;
                    out_len      <= in_byte;
                    out_crc      <= NO_CHECK_BYTE;
                    out_recv_crc <= NO_CHECK_BYTE;
                    st           <= S_IDLE;
                    rem          <= 8'h00;
                    err_sticky[1] <= 1'b1;
                    if (cnt_over_len < CNT_MAX) begin
                        cnt_over_len <= cnt_over_len + 4'h1;
                    end else begin
                        cnt_sat[1] <= 1'b1;
                    end
                end else begin
                    len_r   <= in_byte;
                    crc_run <= crc_step(SEED_VAL, in_byte);
                    if (in_byte == 8'h00) begin
                        st  <= S_CRC;
                        rem <= 8'h00;
                    end else begin
                        st  <= S_DATA;
                        rem <= in_byte;
                    end
                end
            end else if (st == S_DATA) begin
                crc_run <= crc_step(crc_run, in_byte);
                if (in_last) begin
                    // The last marker arrived before the check byte position.
                    out_valid    <= 1'b1;
                    out_ok       <= 1'b0;
                    out_len      <= len_r;
                    out_crc      <= crc_step(crc_run, in_byte);
                    out_recv_crc <= NO_CHECK_BYTE;
                    st           <= S_IDLE;
                    rem          <= 8'h00;
                    err_sticky[2] <= 1'b1;
                    if (cnt_trunc < CNT_MAX) begin
                        cnt_trunc <= cnt_trunc + 4'h1;
                    end else begin
                        cnt_sat[2] <= 1'b1;
                    end
                end else if (rem == 8'h01) begin
                    st  <= S_CRC;
                    rem <= 8'h00;
                end else begin
                    rem <= rem - 8'h01;
                end
            end else if (st == S_CRC) begin
                // This byte is the appended check byte.
                out_valid    <= 1'b1;
                out_ok       <= (crc_run == in_byte);
                out_len      <= len_r;
                out_crc      <= crc_run;
                out_recv_crc <= in_byte;
                st           <= S_IDLE;
                rem          <= 8'h00;
                if (crc_run == in_byte) begin
                    if (cnt_good < CNT_MAX) begin
                        cnt_good <= cnt_good + 4'h1;
                    end else begin
                        cnt_sat[0] <= 1'b1;
                    end
                end else begin
                    err_sticky[0] <= 1'b1;
                    if (cnt_bad_crc < CNT_MAX) begin
                        cnt_bad_crc <= cnt_bad_crc + 4'h1;
                    end else begin
                        cnt_sat[3] <= 1'b1;
                    end
                end
            end
        end
    end
end

endmodule
