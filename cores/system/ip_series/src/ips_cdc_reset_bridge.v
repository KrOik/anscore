`timescale 1ns / 1ps
// ips_cdc_reset_bridge : power-on counter plus 2FF reset-release bridge.
//
// rst_n is the asynchronous source-domain reset.  In the source domain por_count
// runs on the src_tick enable stream and wraps, por_done latches once the count
// reaches POR_LAST, and a narrow asynchronous arst_req pulse is caught by
// req_latch so the bridge can never miss a late reset request.  src_ok is the
// source-domain reset status; the destination domain synchronises it through a
// two-flop chain clocked by dst_tick, so rst_out_n asserts with the source and
// releases only synchronously.  A re-assert seen while the destination still
// holds the release is counted in glitch_count and latches glitch_sticky; each
// clean release increments rst_events.  Every register is gated by clk_en and
// no output can ever resolve to X (docs/IP_CORE_SOP.md traps T2 and T6).
module ips_cdc_reset_bridge #(
    parameter POR_W = 5,
    parameter POR_LAST = 12
)(
    input  wire             clk,
    input  wire             clk_en,
    input  wire             rst_n,

    input  wire             src_tick,
    input  wire             dst_tick,
    input  wire             arst_req,

    output reg              src_ok,
    output reg              por_done,
    output reg  [POR_W-1:0] por_count,
    output reg              sync1,
    output reg              sync2,
    output wire             rst_out_n,
    output reg              released,
    output reg              glitch_sticky,
    output reg [3:0]        glitch_count,
    output reg [3:0]        rst_events
);

assign rst_out_n = sync2;

// Async-request catcher: holds a narrow arst_req pulse until the next src_tick,
// so a glitch narrower than the source tick period still reaches the bridge.
reg req_latch;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        src_ok   <= 1'b0;
        por_done <= 1'b0;
        por_count <= {POR_W{1'b0}};
    end else if (clk_en && src_tick) begin
        por_count <= por_count + 1;
        if (!por_done && por_count >= POR_LAST - 1) begin
            por_done <= 1;
        end
        src_ok <= por_done && !req_latch;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        req_latch <= 1'b0;
    end else if (clk_en) begin
        if (arst_req) begin
            req_latch <= 1;
        end else if (src_tick) begin
            req_latch <= 0;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sync1         <= 1'b0;
        sync2         <= 1'b0;
        released      <= 1'b0;
        glitch_sticky <= 1'b0;
        glitch_count  <= 4'h0;
        rst_events    <= 4'h0;
    end else if (clk_en && dst_tick) begin
        sync1    <= src_ok;
        sync2    <= sync1;
        released <= sync1 && sync2;
        if (sync2 && !sync1) begin
            glitch_sticky <= 1;
            glitch_count  <= glitch_count + 1;
        end
        if (!sync2 && sync1) begin
            rst_events <= rst_events + 1;
        end
    end
end

endmodule
