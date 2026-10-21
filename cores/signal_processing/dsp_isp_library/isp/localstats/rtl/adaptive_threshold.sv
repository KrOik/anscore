// ISP-10 mean/variance quantization and mean-C adaptive threshold.
// Pure combinational; instantiated inside integral_stats stage B.
//
// bin uses the exact integer rule (pixel + C) * area > wsum, which equals
// pixel > floor-free real mean - C for any positive integer area.  No divider
// is needed for the threshold decision.  mean and var are reporting
// quantities: mean = floor(wsum/area), var = floor(wsq/area) - mean*mean
// (always >= 0 since floor(wsq/area) >= floor(wsum/area)^2).
module adaptive_threshold #(
    parameter BITS = 8,
    parameter SW   = 18,   // wsum width
    parameter SQW  = 28,   // wsq width
    parameter AW   = 8,    // area width
    parameter VW   = 2*BITS
)(
    input  wire [SW-1:0]  wsum,
    input  wire [SQW-1:0] wsq,
    input  wire [AW-1:0]  area,     // always >= 1
    input  wire [BITS-1:0] pixel,
    input  wire signed [7:0] c,
    output wire bin_o,
    output wire [BITS-1:0] mean_o,
    output wire [VW-1:0] var_o
);
    wire [SW-1:0]  mean_i = wsum / area;              // <= max pixel value
    wire [SQW-1:0] var_i  = wsq / area;
    wire signed [BITS+1:0] pc   = $signed({1'b0, pixel}) + c;
    wire signed [AW+BITS+2:0] prod = pc * $signed({1'b0, area});
    assign bin_o  = prod > $signed({1'b0, wsum});
    assign mean_o = mean_i[BITS-1:0];
    wire [2*BITS-1:0] msq = mean_o * mean_o;
    wire [SQW-1:0] msq_e = msq;   // implicit zero extension
    wire [SQW-1:0] vraw = var_i - msq_e;
    assign var_o  = (var_i >= msq_e) ? vraw[VW-1:0] : {VW{1'b0}};
    initial begin
        if (BITS < 1 || SW < 1 || SQW < 1 || AW < 1 || VW < 1)
            $fatal(1, "unsupported adaptive_threshold parameters");
    end
endmodule
