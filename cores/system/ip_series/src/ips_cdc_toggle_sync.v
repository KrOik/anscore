`timescale 1ns / 1ps
// ips_cdc_toggle_sync : two-flop toggle synchroniser carrying a stable bus.
//
// Trap T13 of docs/IP_CORE_SOP.md is what this core exists to enforce: the
// payload is written into data_hold on the launch beat and the request toggle
// only flips on the NEXT src_tick, so the bus is stable for a full source cycle
// before the event crosses.  The destination synchronises the toggle in two
// flops and captures the bus when the edge lands in the second flop; the
// consumer acknowledges with a return-path toggle that is itself synchronised
// back into the source domain.  outstanding is set by a launch and only cleared
// by that returning acknowledge, so a source that starts a second transfer while
// the first is still crossing is refused, counted in err_count and latched into
// err_sticky.  Counters are CNT_W bits and wrap.  Every register is gated by
// clk_en and its own domain tick; rst_n is the active-low asynchronous reset
// (traps T2 and T6).
module ips_cdc_toggle_sync #(
    parameter DATA_W = 12,
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

    output reg [DATA_W-1:0]  data_hold,
    output reg               tog_src,
    output reg               pend,
    output reg               outstanding,
    output reg [CNT_W-1:0]   tx_count,
    output reg [CNT_W-1:0]   rx_count,
    output reg [CNT_W-1:0]   err_count,
    output reg               err_sticky,
    output reg [DATA_W-1:0]  dst_data,
    output reg               dst_valid,
    output reg               ack_tog,
    output reg               tog_s1,
    output reg               tog_s2,
    output reg               ack_s1,
    output reg               ack_s2
);

reg ack_seen;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        data_hold   <= {DATA_W{1'b0}};
        tog_src     <= 1'b0;
        outstanding <= 1'b0;
        tx_count    <= {CNT_W{1'b0}};
        err_count   <= {CNT_W{1'b0}};
        err_sticky  <= 1'b0;
        pend        <= 1'b0;
        ack_tog     <= 1'b0;
        ack_seen    <= 1'b0;
        ack_s1      <= 1'b0;
        ack_s2      <= 1'b0;
    end else if (clk_en && src_tick) begin
        if (src_start && !outstanding) begin
            data_hold   <= src_data;
            pend        <= 1;
            outstanding <= 1;
            tx_count    <= tx_count + 1;
        end
        if (src_start && outstanding) begin
            err_count  <= err_count + 1;
            err_sticky <= 1;
        end
        if (pend) begin
            tog_src <= ~tog_src;
            pend    <= 0;
        end
        ack_s1 <= ack_tog;
        ack_s2 <= ack_s1;
        if (ack_s2 != ack_seen) begin
            outstanding <= 0;
            ack_seen    <= ack_s2;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dst_data  <= {DATA_W{1'b0}};
        dst_valid <= 1'b0;
        rx_count  <= {CNT_W{1'b0}};
        tog_s1    <= 1'b0;
        tog_s2    <= 1'b0;
    end else if (clk_en && dst_tick) begin
        if (dst_take && dst_valid) begin
            ack_tog   <= ~ack_tog;
            dst_valid <= 0;
        end
        if (tog_s2 != tog_s1) begin
            dst_data  <= data_hold;
            dst_valid <= 1;
            rx_count  <= rx_count + 1;
        end
        tog_s1 <= tog_src;
        tog_s2 <= tog_s1;
    end
end

endmodule
