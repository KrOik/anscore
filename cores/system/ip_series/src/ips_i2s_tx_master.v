`timescale 1ns / 1ps
// ips_i2s_tx_master : I2S stereo transmit master for the ip_series_20k line.
//
// SCLK / LRCLK / SD are generated from an explicit `tick` input instead of an
// on-chip oscillator: the board-free testbench derives tick from a deterministic
// divisor, so models/ips_i2s_tx_master.py replays every transition cycle-exactly
// (no board, no bus simulator).
//
// Written contract (the golden model implements the same rules):
//   * SCLK toggles once every BCLK_DIV ticks, therefore one bit is launched per
//     SCLK falling edge and the bit period is 2*BCLK_DIV ticks.
//   * One LRCLK period (one stereo word) is FRAME_B = 2*SLOT_B launches.  Slot 0
//     is LRCLK low (left), slot 1 is LRCLK high (right).  LRCLK is registered on
//     the launch that crosses a slot boundary, i.e. one bit time before that
//     slot's first data bit, which is the standard I2S word-select timing.
//   * ALIGN is the numeric slot-alignment offset: 1 = standard I2S delay, 0 =
//     left justified.  The WORD_W-bit sample is launched starting at bit offset
//     ALIGN inside its slot and the remainder of the slot is zero padded.
//   * ch_valid latches the sample pair into lat_l/lat_r and marks both channels
//     fresh; the fresh flag is consumed by the next slot start of that channel.
//     A sample offered on a slot-start launch is accepted by that very slot.
//   * A slot that starts with no fresh sample re-transmits the latched word and
//     reports an under-run: underflow_sticky is set and under_count increments,
//     saturating at UNDER_MAX.  word_count increments once per completed stereo
//     frame and wraps.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).
module ips_i2s_tx_master #(
    parameter WORD_W = 16,
    parameter SLOT_B = 32,
    parameter BCLK_DIV = 4,
    parameter ALIGN = 1,
    parameter UNDER_MAX = 3
)(
    input  wire                      clk,
    input  wire                      clk_en,
    input  wire                      rst_n,

    input  wire                      tick,
    input  wire                      ch_valid,
    input  wire signed [WORD_W-1:0]  ch_l,
    input  wire signed [WORD_W-1:0]  ch_r,

    output reg                       sclk,
    output reg                       lrclk,
    output reg                       sd,
    output reg                       fresh_l,
    output reg                       fresh_r,
    output reg  [6:0]                bit_idx,
    output reg  [3:0]                div_idx,
    output reg  [7:0]                word_count,
    output reg  [7:0]                under_count,
    output reg                       underflow_sticky
);

localparam integer FRAME_B    = SLOT_B + SLOT_B;
localparam integer TAIL_B     = SLOT_B - WORD_W - ALIGN;
localparam integer BCLK_LAST  = BCLK_DIV - 1;
localparam integer FRAME_LAST = FRAME_B - 1;

reg  [SLOT_B-1:0]        sr;
reg  signed [WORD_W-1:0] lat_l;
reg  signed [WORD_W-1:0] lat_r;

// The right slot starts at launch position SLOT_B and the frame wraps after
// FRAME_LAST; both are widened to the counter type here so the comparisons
// below stay width-clean for every legal parameter setting.
wire [6:0] right_pos   = SLOT_B;
wire [6:0] frame_last_w = FRAME_LAST;

wire signed [WORD_W-1:0] use_l = ch_valid ? ch_l : lat_l;
wire signed [WORD_W-1:0] use_r = ch_valid ? ch_r : lat_r;
wire                     eff_l = ch_valid | fresh_l;
wire                     eff_r = ch_valid | fresh_r;

wire [SLOT_B-1:0] load_l = {{ALIGN{1'b0}}, use_l, {TAIL_B{1'b0}}};
wire [SLOT_B-1:0] load_r = {{ALIGN{1'b0}}, use_r, {TAIL_B{1'b0}}};

wire launch  = tick && sclk && (div_idx == 4'd0);
wire slot_l  = launch && (bit_idx == 7'd0);
wire slot_r  = launch && (bit_idx == right_pos);

wire [SLOT_B-1:0] vec      = slot_l ? load_l : (slot_r ? load_r : sr);
wire [6:0]        bit_next = (bit_idx == frame_last_w) ? 7'd0 : (bit_idx + 7'd1);
wire              clk_next = (bit_next >= right_pos);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sclk             <= 1'b0;
        lrclk            <= 1'b0;
        sd               <= 1'b0;
        fresh_l          <= 1'b0;
        fresh_r          <= 1'b0;
        bit_idx          <= 7'd0;
        div_idx          <= 4'd0;
        word_count       <= 8'h00;
        under_count      <= 8'h00;
        underflow_sticky <= 1'b0;
        sr               <= {SLOT_B{1'b0}};
        lat_l            <= {WORD_W{1'b0}};
        lat_r            <= {WORD_W{1'b0}};
    end else if (clk_en) begin
        if (ch_valid) begin
            lat_l   <= ch_l;
            lat_r   <= ch_r;
            fresh_l <= 1'b1;
            fresh_r <= 1'b1;
        end
        if (tick) begin
            if (div_idx == 4'd0) begin
                div_idx <= BCLK_LAST;
                if (sclk) begin
                    sclk    <= 1'b0;
                    sd      <= vec[SLOT_B-1];
                    sr      <= {vec[SLOT_B-2:0], 1'b0};
                    bit_idx <= bit_next;
                    lrclk   <= clk_next;
                    if (slot_l) begin
                        fresh_l <= 1'b0;
                        if (!eff_l) begin
                            underflow_sticky <= 1'b1;
                            if (under_count < UNDER_MAX) begin
                                under_count <= under_count + 8'd1;
                            end
                        end
                    end
                    if (slot_r) begin
                        fresh_r <= 1'b0;
                        if (!eff_r) begin
                            underflow_sticky <= 1'b1;
                            if (under_count < UNDER_MAX) begin
                                under_count <= under_count + 8'd1;
                            end
                        end
                    end
                    if (bit_idx == frame_last_w) begin
                        word_count <= word_count + 8'd1;
                    end
                end else begin
                    sclk <= 1'b1;
                end
            end else begin
                div_idx <= div_idx - 4'd1;
            end
        end
    end
end

endmodule
