`timescale 1ns / 1ps

module tb_i2s_quad_rx_stub;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg mic_d0 = 1'b0;
reg mic_d1 = 1'b0;
reg mic_d2 = 1'b0;
reg mic_d3 = 1'b0;

wire mic_bclk;
wire mic_ws;
wire sample_valid;
wire signed [15:0] sample0;
wire signed [15:0] sample1;
wire signed [15:0] sample2;
wire signed [15:0] sample3;
wire signed [15:0] sample4;
wire signed [15:0] sample5;
wire signed [15:0] sample_center;
wire [31:0] debug_bclk_edges;
wire [31:0] debug_ws_edges;
wire [31:0] debug_sample_frames;
wire [31:0] debug_data_edges;

reg signed [23:0] left0 = 24'sh123456;
reg signed [23:0] right0 = 24'sh234567;
reg signed [23:0] left1 = 24'sh345678;
reg signed [23:0] right1 = 24'sh456789;
reg signed [23:0] left2 = 24'sh56789A;
reg signed [23:0] right2 = 24'sh6789AB;
reg signed [23:0] center = 24'sh789ABC;

always #5 clk = ~clk;

i2s_quad_rx_stub dut (
    .clk(clk),
    .rst_n(rst_n),
    .mic_d0(mic_d0),
    .mic_d1(mic_d1),
    .mic_d2(mic_d2),
    .mic_d3(mic_d3),
    .mic_bclk(mic_bclk),
    .mic_ws(mic_ws),
    .sample_valid(sample_valid),
    .sample0(sample0),
    .sample1(sample1),
    .sample2(sample2),
    .sample3(sample3),
    .sample4(sample4),
    .sample5(sample5),
    .sample_center(sample_center),
    .debug_bclk_edges(debug_bclk_edges),
    .debug_ws_edges(debug_ws_edges),
    .debug_sample_frames(debug_sample_frames),
    .debug_data_edges(debug_data_edges)
);

always @(posedge clk) begin
    if (!rst_n) begin
        mic_d0 <= 1'b0;
        mic_d1 <= 1'b0;
        mic_d2 <= 1'b0;
        mic_d3 <= 1'b0;
    end else if (dut.bit_slot > 0 && dut.bit_slot < 25) begin
        if (mic_ws) begin
            mic_d0 <= right0[24 - dut.bit_slot];
            mic_d1 <= right1[24 - dut.bit_slot];
            mic_d2 <= right2[24 - dut.bit_slot];
        end else begin
            mic_d0 <= left0[24 - dut.bit_slot];
            mic_d1 <= left1[24 - dut.bit_slot];
            mic_d2 <= left2[24 - dut.bit_slot];
        end
        mic_d3 <= center[24 - dut.bit_slot];
    end else begin
        mic_d0 <= 1'b0;
        mic_d1 <= 1'b0;
        mic_d2 <= 1'b0;
        mic_d3 <= 1'b0;
    end
end

initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;

    while (!sample_valid) begin
        @(posedge clk);
    end

    if (sample0 !== left0[23:8]) begin
        $display("FAIL: sample0 expected %h got %h", left0[23:8], sample0);
        $finish_and_return(1);
    end
    if (sample1 !== right0[23:8]) begin
        $display("FAIL: sample1 expected %h got %h", right0[23:8], sample1);
        $finish_and_return(1);
    end
    if (sample2 !== left1[23:8]) begin
        $display("FAIL: sample2 expected %h got %h", left1[23:8], sample2);
        $finish_and_return(1);
    end
    if (sample3 !== right1[23:8]) begin
        $display("FAIL: sample3 expected %h got %h", right1[23:8], sample3);
        $finish_and_return(1);
    end
    if (sample4 !== left2[23:8]) begin
        $display("FAIL: sample4 expected %h got %h", left2[23:8], sample4);
        $finish_and_return(1);
    end
    if (sample5 !== right2[23:8]) begin
        $display("FAIL: sample5 expected %h got %h", right2[23:8], sample5);
        $finish_and_return(1);
    end
    if (sample_center !== center[23:8]) begin
        $display("FAIL: center expected %h got %h", center[23:8], sample_center);
        $finish_and_return(1);
    end

    $display("PASS: i2s_quad_rx_stub channel-order test");
    $finish;
end

endmodule
