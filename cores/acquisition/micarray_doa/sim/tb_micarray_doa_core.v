`timescale 1ns / 1ps

module tb_micarray_doa_core;

localparam integer WINDOW_SAMPLES = 16;
localparam integer MAX_LAG = 4;
localparam integer PULSE_AMPLITUDE = 16'sd1200;

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
wire [3:0] led_index;
wire [31:0] report0;
wire [31:0] report1;
wire [31:0] report2;
wire [31:0] report3;
wire result_valid;

always #5 clk = ~clk;

micarray_doa_core #(
    .WINDOW_SAMPLES(WINDOW_SAMPLES),
    .MAX_LAG(MAX_LAG),
    .MIN_TOTAL_ENERGY(32'd100),
    .MIN_DELAY_SUM(8'd1)
) dut (
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
    .led_index(led_index),
    .report0(report0),
    .report1(report1),
    .report2(report2),
    .report3(report3),
    .result_valid(result_valid)
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

task automatic send_window;
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
            $display("FAIL: pulse index out of range");
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
                16'sd0
            );
        end
    end
endtask

task automatic wait_for_result;
    integer cycles;
    begin
        cycles = 0;
        while (!result_valid && (cycles < 2000)) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (!result_valid) begin
            $display("FAIL: timeout waiting for result_valid");
            $finish_and_return(1);
        end
    end
endtask

task automatic check_result;
    input integer expected_delay03;
    input integer expected_delay14;
    input integer expected_delay25;
    input integer expected_vec_x;
    input integer expected_vec_y;
    input [3:0] expected_led;
    reg signed [7:0] got_delay03;
    reg signed [7:0] got_delay14;
    reg signed [7:0] got_delay25;
    reg [7:0] status;
    reg signed [15:0] got_vec_x;
    reg signed [15:0] got_vec_y;
    begin
        got_delay03 = report1[31:24];
        got_delay14 = report1[23:16];
        got_delay25 = report1[15:8];
        status = report1[7:0];
        got_vec_x = report2[31:16];
        got_vec_y = report2[15:0];

        if (got_delay03 !== expected_delay03[7:0]) begin
            $display("FAIL: delay03 expected %0d got %0d", expected_delay03, got_delay03);
            $finish_and_return(1);
        end
        if (got_delay14 !== expected_delay14[7:0]) begin
            $display("FAIL: delay14 expected %0d got %0d", expected_delay14, got_delay14);
            $finish_and_return(1);
        end
        if (got_delay25 !== expected_delay25[7:0]) begin
            $display("FAIL: delay25 expected %0d got %0d", expected_delay25, got_delay25);
            $finish_and_return(1);
        end
        if (got_vec_x !== expected_vec_x[15:0]) begin
            $display("FAIL: vec_x expected %0d got %0d", expected_vec_x, got_vec_x);
            $finish_and_return(1);
        end
        if (got_vec_y !== expected_vec_y[15:0]) begin
            $display("FAIL: vec_y expected %0d got %0d", expected_vec_y, got_vec_y);
            $finish_and_return(1);
        end
        if (led_index !== expected_led) begin
            $display("FAIL: led expected %0d got %0d", expected_led, led_index);
            $finish_and_return(1);
        end
        if (status[6] !== 1'b1) begin
            $display("FAIL: expected direction_valid status bit");
            $finish_and_return(1);
        end
        if (status[7] !== 1'b0) begin
            $display("FAIL: unexpected overrun status bit");
            $finish_and_return(1);
        end
        if (status[5:0] == 6'd0) begin
            $display("FAIL: confidence should be non-zero");
            $finish_and_return(1);
        end
        if (report0 == 32'd0) begin
            $display("FAIL: report0 total energy should be non-zero");
            $finish_and_return(1);
        end
        if (report3[31:16] == 16'd0) begin
            $display("FAIL: report3 score gap should be non-zero");
            $finish_and_return(1);
        end
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;

    send_window(0, 2, 2);
    wait_for_result();
    check_result(0, 2, 2, 0, 8, 4'd0);

    send_window(4, 0, 0);
    wait_for_result();
    check_result(4, 0, 0, 4, 0, 4'd3);

    send_window(0, -2, -2);
    wait_for_result();
    check_result(0, -2, -2, 0, -8, 4'd6);

    $display("PASS: micarray_doa_core xcorr direction test");
    $finish;
end

endmodule
