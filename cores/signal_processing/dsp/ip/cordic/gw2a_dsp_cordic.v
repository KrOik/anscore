// ============================================================================
// gw2a_dsp_cordic -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: cordic  (src/cordic.v)
// Board-validated: selftest units 0 (CRDR rotation) / 1 (CRDV vectoring),
//   digests 5B8CCF9D / 4A4E2D09, evidence doc/board_uart_la.txt
// 16-stage pipelined CORDIC, Q2.14 fixed point, shift-add only (0 DSP).
// ============================================================================
module gw2a_dsp_cordic #(
    parameter integer IW     = 16,   // x/y port width (Q2.14)
    parameter integer ZW     = 18,   // angle datapath width (radians*2^14)
    parameter integer STAGES = 16
)(
    input  wire               clk,
    input  wire               clk_en,
    input  wire               rst_n,
    input  wire               mode,        // 0=rotation, 1=vectoring
    input  wire               in_valid,
    input  wire signed [IW-1:0] x_in,
    input  wire signed [IW-1:0] y_in,
    input  wire signed [IW-1:0] z_in,
    output wire signed [IW-1:0] x_out,
    output wire signed [IW-1:0] y_out,
    output wire signed [ZW-1:0] z_out,
    output wire               out_valid
);

    cordic #(
        .IW(IW),
        .ZW(ZW),
        .STAGES(STAGES)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .mode(mode),
        .in_valid(in_valid),
        .x_in(x_in),
        .y_in(y_in),
        .z_in(z_in),
        .x_out(x_out),
        .y_out(y_out),
        .z_out(z_out),
        .out_valid(out_valid)
    );

endmodule
