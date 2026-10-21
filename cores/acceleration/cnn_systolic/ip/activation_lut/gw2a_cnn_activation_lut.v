// ============================================================================
// gw2a_cnn_activation_lut -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: activation_lut  (adapted from CNN_FPGA rtl_pds, src/activation_lut.v)
// Board-validated: unit(s) 9 (ALUT), digest 830A5F5F, bitstream mff00
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_activation_lut #(
    parameter INPUT_WIDTH = 13,
    parameter OUTPUT_WIDTH = 8,
    parameter CONV_POSITIVE = 1,
    parameter LUT_FILE = "sigmoid_lut_8bit_to_8bit_h.mem"  // $readmemh init
)(
    input  wire clk,
    input  wire  in_valid,  // input beat valid
    input  wire [INPUT_WIDTH-1:0] val_in,  // LUT address / value
    output  wire  out_valid,  // result valid (1-cycle latency)
    output  wire [OUTPUT_WIDTH-1:0] confidence_out   // activation result
);

    activation_lut #(
        .INPUT_WIDTH(INPUT_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .CONV_POSITIVE(CONV_POSITIVE),
        .LUT_FILE(LUT_FILE)
    ) u_core (
        .clk(clk),
        .in_valid(in_valid),
        .val_in(val_in),
        .out_valid(out_valid),
        .confidence_out(confidence_out)
    );

endmodule
