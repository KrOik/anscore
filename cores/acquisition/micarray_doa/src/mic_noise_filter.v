module mic_noise_filter #(
    parameter [21:0] CALIB_SAMPLES = 22'd210000,
    parameter integer DC_SHIFT = 8,
    parameter integer FLOOR_FAST_SHIFT = 6,
    parameter integer FLOOR_SLOW_SHIFT = 10,
    parameter [15:0] NOISE_MARGIN = 16'd64
) (
    input wire clk,
    input wire rst_n,
    input wire sample_valid,
    input wire signed [15:0] mic0,
    input wire signed [15:0] mic1,
    input wire signed [15:0] mic2,
    input wire signed [15:0] mic3,
    input wire signed [15:0] mic4,
    input wire signed [15:0] mic5,
    output reg calibrated,
    output reg signed [15:0] clean0,
    output reg signed [15:0] clean1,
    output reg signed [15:0] clean2,
    output reg signed [15:0] clean3,
    output reg signed [15:0] clean4,
    output reg signed [15:0] clean5,
    output reg [15:0] level0,
    output reg [15:0] level1,
    output reg [15:0] level2,
    output reg [15:0] level3,
    output reg [15:0] level4,
    output reg [15:0] level5,
    output reg [15:0] floor0,
    output reg [15:0] floor1,
    output reg [15:0] floor2,
    output reg [15:0] floor3,
    output reg [15:0] floor4,
    output reg [15:0] floor5
);

reg [21:0] calib_count;
reg signed [23:0] dc0;
reg signed [23:0] dc1;
reg signed [23:0] dc2;
reg signed [23:0] dc3;
reg signed [23:0] dc4;
reg signed [23:0] dc5;

wire signed [15:0] hp0 = mic0 - dc0[23:8];
wire signed [15:0] hp1 = mic1 - dc1[23:8];
wire signed [15:0] hp2 = mic2 - dc2[23:8];
wire signed [15:0] hp3 = mic3 - dc3[23:8];
wire signed [15:0] hp4 = mic4 - dc4[23:8];
wire signed [15:0] hp5 = mic5 - dc5[23:8];

wire [15:0] abs0 = abs16(hp0);
wire [15:0] abs1 = abs16(hp1);
wire [15:0] abs2 = abs16(hp2);
wire [15:0] abs3 = abs16(hp3);
wire [15:0] abs4 = abs16(hp4);
wire [15:0] abs5 = abs16(hp5);

wire [15:0] gate0 = noise_gate(floor0);
wire [15:0] gate1 = noise_gate(floor1);
wire [15:0] gate2 = noise_gate(floor2);
wire [15:0] gate3 = noise_gate(floor3);
wire [15:0] gate4 = noise_gate(floor4);
wire [15:0] gate5 = noise_gate(floor5);

function [15:0] abs16;
    input signed [15:0] value;
    begin
        abs16 = value[15] ? (~value + 16'd1) : value;
    end
endfunction

function [15:0] noise_gate;
    input [15:0] floor;
    reg [16:0] sum;
    begin
        sum = {1'b0, floor} + {2'b00, floor[15:1]} + {1'b0, NOISE_MARGIN};
        noise_gate = sum[16] ? 16'hFFFF : sum[15:0];
    end
endfunction

function [15:0] subtract_gate;
    input [15:0] value;
    input [15:0] gate;
    begin
        subtract_gate = (value > gate) ? (value - gate) : 16'd0;
    end
endfunction

function signed [15:0] restore_sign;
    input signed [15:0] value;
    input [15:0] magnitude;
    begin
        if (magnitude == 16'd0) begin
            restore_sign = 16'sd0;
        end else begin
            restore_sign = value[15] ? -$signed(magnitude) : $signed(magnitude);
        end
    end
endfunction

function [15:0] floor_update_fast;
    input [15:0] floor;
    input [15:0] value;
    reg signed [16:0] delta;
    begin
        delta = $signed({1'b0, value}) - $signed({1'b0, floor});
        floor_update_fast = floor + (delta >>> FLOOR_FAST_SHIFT);
    end
endfunction

function [15:0] floor_update_slow;
    input [15:0] floor;
    input [15:0] value;
    reg signed [16:0] delta;
    begin
        delta = $signed({1'b0, value}) - $signed({1'b0, floor});
        floor_update_slow = floor + (delta >>> FLOOR_SLOW_SHIFT);
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        calib_count <= 22'd0;
        calibrated <= 1'b0;
        dc0 <= 24'sd0;
        dc1 <= 24'sd0;
        dc2 <= 24'sd0;
        dc3 <= 24'sd0;
        dc4 <= 24'sd0;
        dc5 <= 24'sd0;
        floor0 <= 16'd128;
        floor1 <= 16'd128;
        floor2 <= 16'd128;
        floor3 <= 16'd128;
        floor4 <= 16'd128;
        floor5 <= 16'd128;
        clean0 <= 16'sd0;
        clean1 <= 16'sd0;
        clean2 <= 16'sd0;
        clean3 <= 16'sd0;
        clean4 <= 16'sd0;
        clean5 <= 16'sd0;
        level0 <= 16'd0;
        level1 <= 16'd0;
        level2 <= 16'd0;
        level3 <= 16'd0;
        level4 <= 16'd0;
        level5 <= 16'd0;
    end else if (sample_valid) begin
        dc0 <= dc0 + (({mic0, 8'd0} - dc0) >>> DC_SHIFT);
        dc1 <= dc1 + (({mic1, 8'd0} - dc1) >>> DC_SHIFT);
        dc2 <= dc2 + (({mic2, 8'd0} - dc2) >>> DC_SHIFT);
        dc3 <= dc3 + (({mic3, 8'd0} - dc3) >>> DC_SHIFT);
        dc4 <= dc4 + (({mic4, 8'd0} - dc4) >>> DC_SHIFT);
        dc5 <= dc5 + (({mic5, 8'd0} - dc5) >>> DC_SHIFT);

        if (!calibrated) begin
            floor0 <= floor_update_fast(floor0, abs0);
            floor1 <= floor_update_fast(floor1, abs1);
            floor2 <= floor_update_fast(floor2, abs2);
            floor3 <= floor_update_fast(floor3, abs3);
            floor4 <= floor_update_fast(floor4, abs4);
            floor5 <= floor_update_fast(floor5, abs5);
            clean0 <= 16'sd0;
            clean1 <= 16'sd0;
            clean2 <= 16'sd0;
            clean3 <= 16'sd0;
            clean4 <= 16'sd0;
            clean5 <= 16'sd0;
            level0 <= 16'd0;
            level1 <= 16'd0;
            level2 <= 16'd0;
            level3 <= 16'd0;
            level4 <= 16'd0;
            level5 <= 16'd0;
            if (calib_count == CALIB_SAMPLES - 1'b1) begin
                calibrated <= 1'b1;
            end else begin
                calib_count <= calib_count + 1'b1;
            end
        end else begin
            if (abs0 < gate0) floor0 <= floor_update_slow(floor0, abs0);
            if (abs1 < gate1) floor1 <= floor_update_slow(floor1, abs1);
            if (abs2 < gate2) floor2 <= floor_update_slow(floor2, abs2);
            if (abs3 < gate3) floor3 <= floor_update_slow(floor3, abs3);
            if (abs4 < gate4) floor4 <= floor_update_slow(floor4, abs4);
            if (abs5 < gate5) floor5 <= floor_update_slow(floor5, abs5);

            level0 <= subtract_gate(abs0, gate0);
            level1 <= subtract_gate(abs1, gate1);
            level2 <= subtract_gate(abs2, gate2);
            level3 <= subtract_gate(abs3, gate3);
            level4 <= subtract_gate(abs4, gate4);
            level5 <= subtract_gate(abs5, gate5);
            clean0 <= restore_sign(hp0, subtract_gate(abs0, gate0));
            clean1 <= restore_sign(hp1, subtract_gate(abs1, gate1));
            clean2 <= restore_sign(hp2, subtract_gate(abs2, gate2));
            clean3 <= restore_sign(hp3, subtract_gate(abs3, gate3));
            clean4 <= restore_sign(hp4, subtract_gate(abs4, gate4));
            clean5 <= restore_sign(hp5, subtract_gate(abs5, gate5));
        end
    end
end

endmodule
