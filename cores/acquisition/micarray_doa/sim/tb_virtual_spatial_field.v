`timescale 1ns / 1ps

module tb_virtual_spatial_field;

localparam integer WINDOW_SAMPLES = 16;
localparam integer MAX_LAG = 4;
localparam integer PULSE_AMPLITUDE = 16'sd1600;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg sample_valid = 1'b0;
reg signed [15:0] sample0 = 16'sd0;
reg signed [15:0] sample1 = 16'sd0;
reg signed [15:0] sample2 = 16'sd0;
reg signed [15:0] sample3 = 16'sd0;
reg signed [15:0] sample4 = 16'sd0;
reg signed [15:0] sample5 = 16'sd0;
reg signed [15:0] sample_center = 16'sd0;

wire [3:0] raw_led_index;
wire [31:0] report0;
wire [31:0] report1;
wire [31:0] report2;
wire [31:0] report3;
wire result_valid;
wire [3:0] display_led_index;
wire direction_active;

integer sector;

always #5 clk = ~clk;

micarray_doa_core #(
    .WINDOW_SAMPLES(WINDOW_SAMPLES),
    .MAX_LAG(MAX_LAG),
    .MIN_TOTAL_ENERGY(32'd100),
    .MIN_DELAY_SUM(8'd1)
) doa_core (
    .clk(clk),
    .rst_n(rst_n),
    .sample_valid(sample_valid),
    .sample0(sample0),
    .sample1(sample1),
    .sample2(sample2),
    .sample3(sample3),
    .sample4(sample4),
    .sample5(sample5),
    .sample_center(sample_center),
    .led_index(raw_led_index),
    .report0(report0),
    .report1(report1),
    .report2(report2),
    .report3(report3),
    .result_valid(result_valid)
);

led_direction_filter #(
    .LED_ON_ENERGY_GATE(32'd100),
    .LED_OFF_ENERGY_GATE(32'd50),
    .LED_SCORE_GAP_GATE(16'd1),
    .LED_CONFIRM_FRAMES(3'd4)
) led_filter (
    .clk(clk),
    .rst_n(rst_n),
    .result_valid(result_valid),
    .raw_led_index(raw_led_index),
    .report0(report0),
    .report1(report1),
    .report3(report3),
    .display_led_index(display_led_index),
    .direction_active(direction_active)
);

task automatic send_sample6;
    input signed [15:0] value0;
    input signed [15:0] value1;
    input signed [15:0] value2;
    input signed [15:0] value3;
    input signed [15:0] value4;
    input signed [15:0] value5;
    input signed [15:0] center_value;
    begin
        @(posedge clk);
        sample0 <= value0;
        sample1 <= value1;
        sample2 <= value2;
        sample3 <= value3;
        sample4 <= value4;
        sample5 <= value5;
        sample_center <= center_value;
        sample_valid <= 1'b1;
        @(posedge clk);
        sample_valid <= 1'b0;
    end
endtask

task automatic sector_delays;
    input integer sector_index;
    output integer delay03;
    output integer delay14;
    output integer delay25;
    begin
        case (sector_index)
            0: begin delay03 = 0;  delay14 = 4;  delay25 = 4;  end
            1: begin delay03 = 3;  delay14 = 4;  delay25 = 1;  end
            2: begin delay03 = 4;  delay14 = 4;  delay25 = -1; end
            3: begin delay03 = 3;  delay14 = 4;  delay25 = -4; end
            4: begin delay03 = 4;  delay14 = 1;  delay25 = -4; end
            5: begin delay03 = 3;  delay14 = -1; delay25 = -4; end
            6: begin delay03 = 0;  delay14 = -4; delay25 = -4; end
            7: begin delay03 = -3; delay14 = -4; delay25 = -1; end
            8: begin delay03 = -4; delay14 = -4; delay25 = 1;  end
            9: begin delay03 = -3; delay14 = -4; delay25 = 4;  end
            10: begin delay03 = -4; delay14 = -1; delay25 = 4; end
            default: begin delay03 = -3; delay14 = 1; delay25 = 4; end
        endcase
    end
endtask

task automatic send_spatial_window;
    input integer delay03;
    input integer delay14;
    input integer delay25;
    integer index;
    integer pulse0;
    integer pulse1;
    integer pulse2;
    integer pulse3;
    integer pulse4;
    integer pulse5;
    begin
        pulse0 = 8;
        pulse1 = 8;
        pulse2 = 8;
        pulse3 = pulse0 + delay03;
        pulse4 = pulse1 + delay14;
        pulse5 = pulse2 + delay25;

        if ((pulse3 < 0) || (pulse3 >= WINDOW_SAMPLES) ||
            (pulse4 < 0) || (pulse4 >= WINDOW_SAMPLES) ||
            (pulse5 < 0) || (pulse5 >= WINDOW_SAMPLES)) begin
            $display("FAIL: pulse index out of range d=(%0d,%0d,%0d)", delay03, delay14, delay25);
            $finish_and_return(1);
        end

        for (index = 0; index < WINDOW_SAMPLES; index = index + 1) begin
            send_sample6(
                (index == pulse0) ? PULSE_AMPLITUDE : 16'sd0,
                (index == pulse1) ? PULSE_AMPLITUDE : 16'sd0,
                (index == pulse2) ? PULSE_AMPLITUDE : 16'sd0,
                (index == pulse3) ? PULSE_AMPLITUDE : 16'sd0,
                (index == pulse4) ? PULSE_AMPLITUDE : 16'sd0,
                (index == pulse5) ? PULSE_AMPLITUDE : 16'sd0,
                (index == pulse0) ? PULSE_AMPLITUDE : 16'sd0
            );
        end
    end
endtask

task automatic wait_for_filter_update;
    integer cycles;
    begin
        cycles = 0;
        while (!result_valid && (cycles < 3000)) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!result_valid) begin
            $display("FAIL: timeout waiting for result_valid");
            $finish_and_return(1);
        end

        repeat (3) @(posedge clk);
    end
endtask

task automatic drive_and_check_sector;
    input integer expected_sector;
    integer d03;
    integer d14;
    integer d25;
    begin
        sector_delays(expected_sector, d03, d14, d25);

        send_spatial_window(d03, d14, d25);
        wait_for_filter_update();
        send_spatial_window(d03, d14, d25);
        wait_for_filter_update();
        send_spatial_window(d03, d14, d25);
        wait_for_filter_update();
        send_spatial_window(d03, d14, d25);
        wait_for_filter_update();

        if (raw_led_index !== expected_sector[3:0]) begin
            $display(
                "FAIL: raw sector expected %0d got %0d report1=%08x report2=%08x report3=%08x",
                expected_sector,
                raw_led_index,
                report1,
                report2,
                report3
            );
            $finish_and_return(1);
        end

        if (direction_active !== 1'b1) begin
            $display("FAIL: direction_active not asserted for sector %0d", expected_sector);
            $finish_and_return(1);
        end

        if (display_led_index !== expected_sector[3:0]) begin
            $display(
                "FAIL: display sector expected %0d got %0d raw=%0d",
                expected_sector,
                display_led_index,
                raw_led_index
            );
            $finish_and_return(1);
        end

        $display(
            "sector=%0d d=(%0d,%0d,%0d) leds=(%0d,%0d,%0d) level=%0d",
            expected_sector,
            d03,
            d14,
            d25,
            (display_led_index == 0) ? 11 : display_led_index - 1,
            display_led_index,
            (display_led_index == 11) ? 0 : display_led_index + 1,
            report0
        );
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;

    for (sector = 0; sector < 12; sector = sector + 1) begin
        drive_and_check_sector(sector);
    end

    $display("PASS: virtual spatial-field DOA and 3-LED tracking test");
    $finish;
end

endmodule
