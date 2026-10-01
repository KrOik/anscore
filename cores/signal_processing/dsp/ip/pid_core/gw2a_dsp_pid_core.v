// ============================================================================
// gw2a_dsp_pid_core -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: pid_core  (src/pid_core.v)
// Board-validated: selftest unit 4 (PID), digest 5C690862,
//   evidence doc/board_uart_la.txt
// Discrete PID, gains as (mul,shift) shift-add constant products (0 DSP),
// integrator anti-windup clamp, output clamp.
//   gain = KX_MUL / 2^KX_SH   (e.g. KP 96/64 = 1.5)
// ============================================================================
module gw2a_dsp_pid_core #(
    parameter [7:0]  KP_MUL  = 8'd96,     // Kp = 96/64  = 1.5
    parameter [3:0]  KP_SH   = 4'd6,
    parameter [7:0]  KI_MUL  = 8'd4,      // Ki = 4/64   = 0.0625
    parameter [3:0]  KI_SH   = 4'd6,
    parameter [7:0]  KD_MUL  = 8'd32,     // Kd = 32/64  = 0.5
    parameter [3:0]  KD_SH   = 4'd6,
    parameter signed [15:0] I_LIM   = 16'sd16000,   // integrator clamp
    parameter signed [15:0] OUT_LIM = 16'sd32000    // output clamp
)(
    input  wire               clk,
    input  wire               clk_en,
    input  wire               rst_n,
    input  wire               in_valid,
    input  wire signed [15:0] err_in,
    output wire signed [15:0] u_out,
    output wire               out_valid
);

    pid_core #(
        .KP_MUL(KP_MUL), .KP_SH(KP_SH),
        .KI_MUL(KI_MUL), .KI_SH(KI_SH),
        .KD_MUL(KD_MUL), .KD_SH(KD_SH),
        .I_LIM(I_LIM), .OUT_LIM(OUT_LIM)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .err_in(err_in),
        .u_out(u_out),
        .out_valid(out_valid)
    );

endmodule
