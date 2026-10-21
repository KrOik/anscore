module sk9822_driver #(
    parameter LED_COUNT = 12,
    parameter CLK_DIV_BITS = 5
) (
    input wire clk,
    input wire rst_n,
    input wire [3:0] led_index,
    input wire direction_active,
    input wire [31:0] sound_level,
    input wire [15:0] mic0_level,
    input wire [15:0] mic1_level,
    input wire [15:0] mic2_level,
    input wire [15:0] mic3_level,
    input wire [15:0] mic4_level,
    input wire [15:0] mic5_level,
    output reg sk9822_ck,
    output reg sk9822_da
);

localparam FRAME_BITS = 32;
localparam [31:0] START_FRAME = 32'h00000000;
localparam [31:0] END_FRAME = 32'hFFFFFFFF;
localparam [4:0] BRIGHTNESS = 5'b11111;
localparam [23:0] LED_OFF = 24'h000000;

reg [CLK_DIV_BITS - 1:0] clk_div;
wire tick = &clk_div;

reg [31:0] shift_frame;
reg [4:0] bit_count;
reg [4:0] frame_count;
reg [3:0] active_led_index;
reg active_direction;
reg [31:0] active_sound_level;
reg [15:0] active_mic0_level;
reg [15:0] active_mic1_level;
reg [15:0] active_mic2_level;
reg [15:0] active_mic3_level;
reg [15:0] active_mic4_level;
reg [15:0] active_mic5_level;

wire [3:0] frame_led_index = frame_count[3:0];
wire [3:0] prev_led_index = (active_led_index == 4'd0) ? 4'd11 : (active_led_index - 1'b1);
wire [3:0] next_led_index = (active_led_index == 4'd11) ? 4'd0 : (active_led_index + 1'b1);
wire [7:0] center_red = strength_to_red(active_sound_level);
wire [7:0] side_red = center_red >> 1;
wire [7:0] activity_blue = mic_activity_blue(frame_led_index);
wire [23:0] led_rgb =
    (active_direction && (frame_led_index == active_led_index)) ? {16'd0, center_red} :
    (active_direction && (frame_led_index == prev_led_index)) ? {16'd0, side_red} :
    (active_direction && (frame_led_index == next_led_index)) ? {16'd0, side_red} :
    (activity_blue != 8'd0) ? {activity_blue, 16'd0} :
    ((frame_led_index == 4'd0) ? 24'h060000 : LED_OFF);
wire [31:0] led_frame = {3'b111, BRIGHTNESS, led_rgb};

function [7:0] strength_to_red;
    input [31:0] value;
    begin
        if (|value[31:13]) begin
            strength_to_red = 8'hFF;
        end else if (value[12:5] < 8'd8) begin
            strength_to_red = 8'd8;
        end else begin
            strength_to_red = value[12:5];
        end
    end
endfunction

function [7:0] level_to_blue;
    input [15:0] value;
    begin
        if (|value[15:9]) begin
            level_to_blue = 8'h80;
        end else if (value[8:3] < 6'd2) begin
            level_to_blue = 8'd0;
        end else begin
            level_to_blue = {2'b00, value[8:3]};
        end
    end
endfunction

function [7:0] mic_activity_blue;
    input [3:0] led;
    begin
        case (led)
            4'd0: mic_activity_blue = level_to_blue(active_mic0_level);
            4'd2: mic_activity_blue = level_to_blue(active_mic1_level);
            4'd4: mic_activity_blue = level_to_blue(active_mic2_level);
            4'd6: mic_activity_blue = level_to_blue(active_mic3_level);
            4'd8: mic_activity_blue = level_to_blue(active_mic4_level);
            4'd10: mic_activity_blue = level_to_blue(active_mic5_level);
            default: mic_activity_blue = 8'd0;
        endcase
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clk_div <= 0;
        sk9822_ck <= 1'b0;
        sk9822_da <= 1'b0;
        shift_frame <= START_FRAME;
        bit_count <= 0;
        frame_count <= 0;
        active_led_index <= 4'd0;
        active_direction <= 1'b0;
        active_sound_level <= 32'd0;
        active_mic0_level <= 16'd0;
        active_mic1_level <= 16'd0;
        active_mic2_level <= 16'd0;
        active_mic3_level <= 16'd0;
        active_mic4_level <= 16'd0;
        active_mic5_level <= 16'd0;
    end else begin
        clk_div <= clk_div + 1'b1;

        if (tick) begin
            sk9822_ck <= ~sk9822_ck;

            if (sk9822_ck) begin
                sk9822_da <= shift_frame[FRAME_BITS - 1 - bit_count];
                if (bit_count == FRAME_BITS - 1) begin
                    bit_count <= 0;
                    if (frame_count == LED_COUNT + 1) begin
                        frame_count <= 0;
                        shift_frame <= START_FRAME;
                        active_led_index <= led_index;
                        active_direction <= direction_active;
                        active_sound_level <= sound_level;
                        active_mic0_level <= mic0_level;
                        active_mic1_level <= mic1_level;
                        active_mic2_level <= mic2_level;
                        active_mic3_level <= mic3_level;
                        active_mic4_level <= mic4_level;
                        active_mic5_level <= mic5_level;
                    end else begin
                        frame_count <= frame_count + 1'b1;
                        if (frame_count == LED_COUNT) begin
                            shift_frame <= END_FRAME;
                        end else begin
                            shift_frame <= led_frame;
                        end
                    end
                end else begin
                    bit_count <= bit_count + 1'b1;
                end
            end
        end
    end
end

endmodule
