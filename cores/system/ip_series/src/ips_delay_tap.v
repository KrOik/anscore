`timescale 1ns / 1ps
// ips_delay_tap : programmable tap delay line carrying a valid/payload word.
//
// One accepted beat enters tap 0 and the whole chain advances every enabled
// beat, so a beat never has to be re-aligned after a bubble.  The valid bits and
// the payload words are two flat shift vectors (docs/IP_CORE_SOP.md trap T3),
// tap k of the line being bit k of vline and word k of dline.  The output is the
// tap selected by delay_sel, clamped to MAX_DELAY, and active_lat reports the
// latency that tap actually imposes (registered, tap + 1 cycles).  stall holds
// the chain and de-registers in_ready; beats presented while the line is not
// accepting are counted in drop_count and latch drop_sticky.  Every register is
// gated by clk_en and rst_n is the active-low asynchronous reset (trap T2).
module ips_delay_tap #(
    parameter PAY_W = 8,
    parameter MAX_DELAY = 15
)(
    input  wire             clk,
    input  wire             clk_en,
    input  wire             rst_n,

    input  wire             in_valid,
    input  wire [PAY_W-1:0] in_data,
    input  wire             stall,
    input  wire [7:0]       delay_sel,

    output wire [PAY_W-1:0] out_data,
    output wire             out_valid,
    output reg              in_ready,
    output reg  [7:0]       tap_index,
    output reg  [7:0]       active_lat,
    output reg  [7:0]       beat_count,
    output reg  [7:0]       drop_count,
    output reg  [7:0]       lat_events,
    output reg              drop_sticky
);

localparam [7:0] DLY_MAX = MAX_DELAY;

reg [MAX_DELAY:0]             vline;
reg [(MAX_DELAY + 1)*PAY_W - 1:0] dline;
reg [7:0] tsel;

wire accepted = in_valid && in_ready && !stall;

assign out_valid = vline[tsel];
assign out_data  = dline[tsel*PAY_W +: PAY_W];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vline       <= {(MAX_DELAY + 1){1'b0}};
        dline       <= {((MAX_DELAY + 1)*PAY_W){1'b0}};
        tsel        <= 8'h00;
        in_ready    <= 1'b0;
        tap_index   <= 8'h00;
        active_lat  <= 8'h01;
        beat_count  <= 8'h00;
        drop_count  <= 8'h00;
        lat_events  <= 8'h00;
        drop_sticky <= 1'b0;
    end else if (clk_en) begin
        if (delay_sel > DLY_MAX) begin
            tsel <= DLY_MAX;
        end else begin
            tsel <= delay_sel;
        end
        tap_index  <= tsel;
        active_lat <= tsel + 1;
        in_ready   <= !stall;
        if (delay_sel != tsel) begin
            lat_events <= lat_events + 1;
        end
        if (in_valid && (stall || !in_ready)) begin
            drop_count <= drop_count + 1;
            drop_sticky <= 1;
        end
        if (accepted) begin
            beat_count <= beat_count + 1;
        end
        if (!stall) begin
            vline <= (vline << 1) | accepted;
            dline <= (dline << PAY_W) | in_data;
        end
    end
end

endmodule
