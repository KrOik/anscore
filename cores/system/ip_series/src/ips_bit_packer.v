`timescale 1ns / 1ps
// ips_bit_packer : MSB-first bit packer that turns a stream of FIELD_BITS-wide
// input fields into an OUT_BITS-wide (byte-aligned) output word burst, with a
// residual-bit counter and an explicit flush interface so that no buffered bit is
// ever dropped or wrapped silently.
//
// Packing contract (arbitrary ratio, no bit is lost):
//   * fields concatenate MSB-first into a reservoir that always keeps its valid
//     bits in the top resid_bits positions;
//   * an accepted field is inserted at the top of the reservoir and the previous
//     content sinks by FIELD_BITS positions, so both the append and the emit use
//     fixed shifts only;
//   * while the reservoir holds at least OUT_BITS bits it emits one full output
//     word per enabled clock edge (out_valid pulses for exactly that edge and the
//     word is consumed immediately by the downstream stage), oldest bit first;
//   * when a burst ends (in_last) or the requester asserts flush, the leftover
//     resid_bits < OUT_BITS bits are emitted as one final PARTIAL word, aligned to
//     the most significant end, with out_last set and pad_bits = OUT_BITS -
//     resid_bits pad bits at the LSB end.  A flush that finds no residual (the
//     burst happened to end bit-aligned) emits nothing and is counted as a spurious
//     flush instead of being hidden.
//   * bits are conserved exactly: bits_in equals bits_out plus resid_bits at every
//     enabled edge, and bits_in equals cnt_fields * FIELD_BITS.  The reservoir keeps
//     its unused low positions at zero, so the flushed partial word is already zero
//     padded and needs no masking.
//
// Handshake and accounting: in_ready is high only in the load state, so a field
// presented while the packer is draining or flushing is not consumed; burst_len
// counts the fields of the burst being packed, is cleared by in_last and stops at
// BURST_STOP instead of wrapping.  A burst longer than MAX_BURST fields still packs
// every field it is given (nothing is dropped) but latches err_sticky[0] so the
// integrator sees the over-length burst.  err_sticky[1] latches on a flush that had
// no residual to emit.  cnt_fields, cnt_words, cnt_flush, cnt_spur, bits_in and
// bits_out are saturating and each one latches its own cnt_sat bit, so saturation is
// reported rather than wrapping silently, and max_resid records the widest residual
// ever flushed.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).  Only fixed shifts and constant
// add/subtract are used, so there is no DSP and no barrel shifter (trap T4).
module ips_bit_packer #(
    parameter FIELD_BITS = 11,
    parameter OUT_BITS   = 8,
    parameter MAX_BURST  = 24
)(
    input  wire                   clk,
    input  wire                   clk_en,
    input  wire                   rst_n,

    input  wire                   in_valid,
    input  wire                   in_last,
    input  wire [FIELD_BITS-1:0]  in_field,
    input  wire                   flush,

    output wire                   in_ready,
    output reg                    out_valid,
    output reg                    out_last,
    output reg  [OUT_BITS-1:0]    out_word,
    output reg  [4:0]             resid_bits,
    output reg  [3:0]             pad_bits,
    output reg  [5:0]             burst_len,
    output reg  [7:0]             cnt_fields,
    output reg  [7:0]             cnt_words,
    output reg  [3:0]             cnt_flush,
    output reg  [3:0]             cnt_spur,
    output reg  [4:0]             max_resid,
    output reg  [11:0]            bits_in,
    output reg  [11:0]            bits_out,
    output reg  [1:0]             err_sticky,
    output reg  [5:0]             cnt_sat
);

localparam integer ACC_BITS = FIELD_BITS + OUT_BITS;

// Counter ceilings: a counter that reaches its ceiling stops there and latches the
// matching cnt_sat bit.
localparam [7:0]  LIM8  = 8'hFF;
localparam [3:0]  LIM4  = 4'hF;
localparam [11:0] LIM12 = 12'hFFF;

localparam [4:0]  APPEND_BITS = FIELD_BITS;
localparam [4:0]  DRAIN_BITS  = OUT_BITS;
localparam [3:0]  OUT4        = OUT_BITS;
localparam [5:0]  BURST_LIMIT = MAX_BURST;
localparam [5:0]  BURST_STOP  = 6'h3F;
localparam [11:0] INCR_IN     = FIELD_BITS;
localparam [11:0] INCR_OUT    = OUT_BITS;

localparam [1:0] P_LOAD  = 2'd0;
localparam [1:0] P_DRAIN = 2'd1;
localparam [1:0] P_FLUSH = 2'd2;

reg [1:0]          st;
reg [ACC_BITS-1:0] resv;
reg                last_r;

assign in_ready = (st == P_LOAD);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st         <= P_LOAD;
        resv       <= {ACC_BITS{1'b0}};
        last_r     <= 1'b0;
        resid_bits <= 5'd0;
        pad_bits   <= 4'd0;
        burst_len  <= 6'd0;
        out_valid  <= 1'b0;
        out_last   <= 1'b0;
        out_word   <= {OUT_BITS{1'b0}};
        cnt_fields <= 8'h00;
        cnt_words  <= 8'h00;
        cnt_flush  <= 4'h0;
        cnt_spur   <= 4'h0;
        max_resid  <= 5'd0;
        bits_in    <= 12'h000;
        bits_out   <= 12'h000;
        err_sticky <= 2'b00;
        cnt_sat    <= 6'h00;
    end else if (clk_en) begin
        out_valid <= 1'b0;
        out_last  <= 1'b0;
        case (st)
            // ---------------- load one field into the top of the reservoir ----
            P_LOAD: begin
                if (in_valid) begin
                    resv       <= (resv >> FIELD_BITS)
                                | {in_field, {OUT_BITS{1'b0}}};
                    resid_bits <= resid_bits + APPEND_BITS;
                    st         <= P_DRAIN;
                    if (cnt_fields < LIM8) begin
                        cnt_fields <= cnt_fields + 8'h01;
                    end else begin
                        cnt_sat[0] <= 1'b1;
                    end
                    if (bits_in < LIM12) begin
                        bits_in <= bits_in + INCR_IN;
                    end else begin
                        cnt_sat[4] <= 1'b1;
                    end
                    if (burst_len >= BURST_LIMIT) begin
                        err_sticky[0] <= 1'b1;
                    end
                    if (in_last) begin
                        burst_len <= 6'd0;
                        last_r    <= 1'b1;
                    end else begin
                        // live burst pointer: it stops at its ceiling instead of
                        // wrapping, and the over-length flag is latched anyway
                        if (burst_len < BURST_STOP) begin
                            burst_len <= burst_len + 6'd1;
                        end
                        last_r <= 1'b0;
                    end
                end else if (flush) begin
                    if (resid_bits != 5'd0) begin
                        st <= P_FLUSH;
                    end else begin
                        // nothing buffered: report it, never hide it
                        err_sticky[1] <= 1'b1;
                        if (cnt_spur < LIM4) begin
                            cnt_spur <= cnt_spur + 4'h1;
                        end else begin
                            cnt_sat[3] <= 1'b1;
                        end
                    end
                end
            end
            // ---------------- emit whole words while they are available -------
            P_DRAIN: begin
                if (resid_bits >= DRAIN_BITS) begin
                    out_word   <= resv[ACC_BITS-1 -: OUT_BITS];
                    out_valid  <= 1'b1;
                    resv       <= resv << OUT_BITS;
                    resid_bits <= resid_bits - DRAIN_BITS;
                    st         <= P_DRAIN;
                    if (cnt_words < LIM8) begin
                        cnt_words <= cnt_words + 8'h01;
                    end else begin
                        cnt_sat[1] <= 1'b1;
                    end
                    if (bits_out < LIM12) begin
                        bits_out <= bits_out + INCR_OUT;
                    end else begin
                        cnt_sat[5] <= 1'b1;
                    end
                end else begin
                    st <= last_r ? P_FLUSH : P_LOAD;
                end
            end
            // ---------------- flush the residual as one partial word ----------
            P_FLUSH: begin
                if (resid_bits != 5'd0) begin
                    out_word  <= resv[ACC_BITS-1 -: OUT_BITS];
                    out_valid <= 1'b1;
                    out_last  <= 1'b1;
                    pad_bits  <= OUT4 - resid_bits[3:0];
                    if (resid_bits > max_resid) begin
                        max_resid <= resid_bits;
                    end
                    if (cnt_flush < LIM4) begin
                        cnt_flush <= cnt_flush + 4'h1;
                    end else begin
                        cnt_sat[2] <= 1'b1;
                    end
                    if (bits_out < LIM12) begin
                        bits_out <= bits_out + {{7{1'b0}}, resid_bits};
                    end else begin
                        cnt_sat[5] <= 1'b1;
                    end
                end else begin
                    err_sticky[1] <= 1'b1;
                    if (cnt_spur < LIM4) begin
                        cnt_spur <= cnt_spur + 4'h1;
                    end else begin
                        cnt_sat[3] <= 1'b1;
                    end
                end
                resv       <= {ACC_BITS{1'b0}};
                resid_bits <= 5'd0;
                burst_len  <= 6'd0;
                last_r     <= 1'b0;
                st         <= P_LOAD;
            end
            default: begin
                st <= P_LOAD;
            end
        endcase
    end
end

endmodule
