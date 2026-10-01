// ============================================================================
// gw2a_dsp_dds_nco -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: dds_nco  (src/dds_nco.v)
// Board-validated: selftest unit 2 (DDS), digest 0F185BED,
//   evidence doc/board_uart_la.txt
// 32-bit phase accumulator + 256x16 sine LUT in BSRAM, sine + square outputs.
// LUT file sine256.mem must be resolvable from the build working directory
// (copy shipped alongside this wrapper).
// ============================================================================
module gw2a_dsp_dds_nco #(
    parameter LUT_FILE = "sine256.mem"
)(
    input  wire               clk,
    input  wire               clk_en,
    input  wire               rst_n,
    input  wire               run,
    input  wire [31:0]        tuning_word,
    output wire signed [15:0] sine_out,
    output wire               square_out,
    output wire [31:0]        phase_out
);

    dds_nco #(
        .LUT_FILE(LUT_FILE)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .run(run),
        .tuning_word(tuning_word),
        .sine_out(sine_out),
        .square_out(square_out),
        .phase_out(phase_out)
    );

endmodule
