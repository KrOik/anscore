module led_direction_filter #(
    parameter [31:0] LED_ON_ENERGY_GATE = 32'd24576,
    parameter [31:0] LED_OFF_ENERGY_GATE = 32'd12288,
    parameter [15:0] LED_SCORE_GAP_GATE = 16'd128,
    parameter [2:0] LED_CONFIRM_FRAMES = 3'd4
) (
    input wire clk,
    input wire rst_n,
    input wire result_valid,
    input wire [3:0] raw_led_index,
    input wire [31:0] report0,
    input wire [31:0] report1,
    input wire [31:0] report3,
    output reg [3:0] display_led_index,
    output reg direction_active
);

reg [3:0] candidate_led_index;
reg [2:0] candidate_count;
reg result_valid_d;

wire direction_valid = report1[6];
wire direction_confident = (report3[31:16] >= LED_SCORE_GAP_GATE);
wire raw_direction_active = (report0 >= LED_ON_ENERGY_GATE) && direction_valid && direction_confident;
wire display_prev_match = (display_led_index == 4'd0) ?
    (raw_led_index == 4'd11) :
    (raw_led_index == (display_led_index - 1'b1));
wire display_next_match = (display_led_index == 4'd11) ?
    (raw_led_index == 4'd0) :
    (raw_led_index == (display_led_index + 1'b1));
wire display_adjacent_or_same =
    (display_led_index == raw_led_index) || display_prev_match || display_next_match;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        display_led_index <= 4'd0;
        candidate_led_index <= 4'd0;
        candidate_count <= 3'd0;
        direction_active <= 1'b0;
        result_valid_d <= 1'b0;
    end else begin
        result_valid_d <= result_valid;
        if (result_valid_d) begin
            if (raw_direction_active) begin
                if (direction_active && display_adjacent_or_same) begin
                    display_led_index <= raw_led_index;
                    candidate_led_index <= raw_led_index;
                    candidate_count <= LED_CONFIRM_FRAMES;
                    direction_active <= 1'b1;
                end else if (candidate_led_index == raw_led_index) begin
                    if (candidate_count >= LED_CONFIRM_FRAMES - 1'b1) begin
                        display_led_index <= raw_led_index;
                        candidate_count <= LED_CONFIRM_FRAMES;
                        direction_active <= 1'b1;
                    end else begin
                        candidate_count <= candidate_count + 1'b1;
                    end
                end else begin
                    candidate_led_index <= raw_led_index;
                    candidate_count <= 3'd1;
                end
            end else if (report0 < LED_OFF_ENERGY_GATE) begin
                direction_active <= 1'b0;
                candidate_count <= 3'd0;
            end else begin
                candidate_count <= 3'd0;
            end
        end
    end
end

endmodule
