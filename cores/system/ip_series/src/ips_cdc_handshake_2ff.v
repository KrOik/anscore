`timescale 1ns / 1ps
// ips_cdc_handshake_2ff : 4-phase req/ack handshake crossing a multi-bit word.
//
// Trap T13 of docs/IP_CORE_SOP.md is the point of this core: src_start writes
// data_hold on the launch beat and req only rises on the NEXT source tick, so
// the payload is stable for a whole source cycle before the request crosses.
// The destination synchronises req in two flops, captures the word in full and
// hands it to its consumer; the consumer's accept then raises ack, which is
// synchronised back into the source domain.  Source sees ack -> pulls req low,
// destination sees req low -> pulls ack low, which is the four phase transition
// that returns the pair to idle.  busy marks an unfinished transfer, so a
// second src_start while one is crossing is refused, counted in err_count and
// latched into err_sticky.  hop_count counts the level changes that cross the
// request synchroniser.  Counters are CNT_W bits and wrap.  Every register is
// gated by clk_en and its own domain tick; rst_n is the active-low
// asynchronous reset (traps T2 and T6).
module ips_cdc_handshake_2ff #(
    parameter DATA_W = 16,
    parameter CNT_W = 4
)(
    input  wire              clk,
    input  wire              clk_en,
    input  wire              rst_n,

    input  wire              src_tick,
    input  wire              dst_tick,
    input  wire              src_start,
    input  wire [DATA_W-1:0] src_data,
    input  wire              dst_take,

    output reg  [DATA_W-1:0] data_hold,
    output reg               req,
    output reg               pend,
    output reg               busy,
    output reg               phase,
    output reg  [CNT_W-1:0]  tx_count,
    output reg  [CNT_W-1:0]  err_count,
    output reg               err_sticky,
    output reg               ack_s1,
    output reg               ack_s2,

    output reg  [DATA_W-1:0] data_dst,
    output reg               valid,
    output reg               ack,
    output reg  [CNT_W-1:0]  rx_count,
    output reg  [CNT_W-1:0]  hop_count,
    output reg               req_s1,
    output reg               req_s2
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        data_hold   <= {DATA_W{1'b0}};
        req         <= 1'b0;
        pend        <= 1'b0;
        busy        <= 1'b0;
        phase       <= 1'b0;
        tx_count    <= {CNT_W{1'b0}};
        err_count   <= {CNT_W{1'b0}};
        err_sticky  <= 1'b0;
        ack_s1      <= 1'b0;
        ack_s2      <= 1'b0;
    end else if (clk_en && src_tick) begin
        if (src_start && !busy) begin
            data_hold   <= src_data;
            pend        <= 1;
            busy        <= 1;
            tx_count    <= tx_count + 1;
        end
        if (src_start && busy) begin
            err_count  <= err_count + 1;
            err_sticky <= 1;
        end
        if (pend) begin
            req  <= 1;
            pend <= 0;
        end
        ack_s1 <= ack;
        ack_s2 <= ack_s1;
        if (busy && req && ack_s2) begin
            req   <= 0;
            phase <= 1;
        end
        if (phase && !ack_s2) begin
            phase <= 0;
            busy  <= 0;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        data_dst  <= {DATA_W{1'b0}};
        valid     <= 1'b0;
        ack       <= 1'b0;
        rx_count  <= {CNT_W{1'b0}};
        hop_count <= {CNT_W{1'b0}};
        req_s1    <= 1'b0;
        req_s2    <= 1'b0;
    end else if (clk_en && dst_tick) begin
        req_s1 <= req;
        req_s2 <= req_s1;
        if (req_s2 != req_s1) begin
            hop_count <= hop_count + 1;
        end
        if (req_s2 && !valid && !ack) begin
            data_dst <= data_hold;
            valid    <= 1;
            rx_count <= rx_count + 1;
        end
        if (dst_take && valid) begin
            ack   <= 1;
            valid <= 0;
        end
        if (!req_s2 && ack) begin
            ack   <= 0;
        end
    end
end

endmodule
