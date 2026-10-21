// ============================================================================
// gw2a_dsp_fir16 -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: fir16  (src/fir16.v)
// Board-validated: selftest unit 3 (FIR), digest 20038C18,
//   evidence doc/board_uart_la.txt
// 16-tap symmetric FIR, 8-bit unsigned samples, 8 unique coefficients,
// saturating output, shift-add constant products (0 DSP).
// ============================================================================
module gw2a_dsp_fir16 #(
    parameter [7:0] C0 = 8'd1,
    parameter [7:0] C1 = 8'd2,
    parameter [7:0] C2 = 8'd4,
    parameter [7:0] C3 = 8'd8,
    parameter [7:0] C4 = 8'd16,
    parameter [7:0] C5 = 8'd32,
    parameter [7:0] C6 = 8'd32,
    parameter [7:0] C7 = 8'd16,
    parameter integer OUT_SHIFT = 8
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,
    input  wire       in_valid,
    input  wire [7:0] sample_in,
    output wire [7:0] y_out,
    output wire       out_valid
);

    fir16 #(
        .C0(C0), .C1(C1), .C2(C2), .C3(C3),
        .C4(C4), .C5(C5), .C6(C6), .C7(C7),
        .OUT_SHIFT(OUT_SHIFT)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .sample_in(sample_in),
        .y_out(y_out),
        .out_valid(out_valid)
    );

endmodule
