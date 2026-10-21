// ============================================================================
// gw2a_cnn_pe -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: pe  (adapted from CNN_FPGA rtl_pds, src/pe.v)
// Board-validated: unit(s) 0 (PE) / 1 (PED, USE_DSP_PE=yes), digest B865EC67, bitstream m00ff
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_pe #(
    parameter DATA_WIDTH = 7,
    parameter WEIGHT_WIDTH = 8,
    parameter ADDER2_WIDTH = 18,
    parameter OUTPUT_WIDTH = 19,
    parameter USE_DSP_PE = "no"  // set "yes" to use DSP mult (PED path)
)(
    input  wire clk,
    input  wire clk_en,
    input  wire [DATA_WIDTH-1:0] D,  // unsigned pixel data
    input  wire signed [WEIGHT_WIDTH-1:0] W,  // signed weight
    input  wire signed [ADDER2_WIDTH-1:0] y_in,  // signed chain input
    output  wire signed [OUTPUT_WIDTH-1:0] y_out   // signed chain output, latency 2
);

    pe #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ADDER2_WIDTH(ADDER2_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .USE_DSP_PE(USE_DSP_PE)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .D(D),
        .W(W),
        .y_in(y_in),
        .y_out(y_out)
    );

endmodule
