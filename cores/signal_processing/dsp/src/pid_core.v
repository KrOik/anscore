// ============================================================================
// pid_core.v -- discrete positional PID, zero DSP.
//
//   i_acc   += err_in            (clamped to +/-I_LIM : anti-windup clamp)
//   d_err    = sat16(err - err_prev)
//   u        = sat16( (err*KP_MUL >>> KP_SH)
//                   + (i_acc*KI_MUL >>> KI_SH)
//                   + (d_err*KD_MUL >>> KD_SH) )
//   u_out   <= u                 (registered, one beat after in_valid)
//
// Gains are (8-bit mantissa, 4-bit shift) pairs: gain = MUL * 2^-SH.
// All multiplies go through smul8(), which folds to a shift-add tree over the
// operand magnitude (constant coefficient at elaboration) -> no DSP.
// ============================================================================
module pid_core #(
    parameter [7:0]  KP_MUL  = 8'd96,    // Kp = 96/64  = 1.5
    parameter [3:0]  KP_SH   = 4'd6,
    parameter [7:0]  KI_MUL  = 8'd4,     // Ki = 4/64   = 0.0625
    parameter [3:0]  KI_SH   = 4'd6,
    parameter [7:0]  KD_MUL  = 8'd32,    // Kd = 32/64  = 0.5
    parameter [3:0]  KD_SH   = 4'd6,
    parameter signed [15:0] I_LIM   = 16'sd16000,   // integrator clamp
    parameter signed [15:0] OUT_LIM = 16'sd32000    // output clamp
) (
    input  wire               clk,
    input  wire               clk_en,
    input  wire               rst_n,
    input  wire               in_valid,
    input  wire signed [15:0] err_in,
    output reg  signed [15:0] u_out,
    output reg                out_valid
);

// signed operand x constant-coefficient multiply via shift-add.
// mag holds |v| (0x8000 -> 32768 handled correctly as unsigned).
function signed [31:0] smul8;
    input signed [15:0] v;
    input [7:0] c;
    integer b;
    reg [15:0] mag;
    reg [31:0] acc;
    begin
        mag = v[15] ? (~v + 16'd1) : v;
        acc = 32'd0;
        for (b = 0; b < 8; b = b + 1) begin
            if (c[b]) acc = acc + ({16'd0, mag} << b);
        end
        smul8 = v[15] ? -$signed(acc) : $signed(acc);
    end
endfunction

function signed [15:0] sat16;
    input signed [31:0] v;
    begin
        if (v > 32'sd32767)        sat16 = 16'sd32767;
        else if (v < -32'sd32768)  sat16 = -16'sd32768;
        else                       sat16 = v[15:0];
    end
endfunction

function signed [15:0] clamp16;
    input signed [31:0] v;
    input signed [15:0] lim;
    reg signed [31:0] limx;   // signed reg: keeps negation/compares signed
    begin
        limx = {{16{lim[15]}}, lim};
        if (v > limx)        clamp16 = lim;
        else if (v < -limx)  clamp16 = -lim;
        else                 clamp16 = v[15:0];
    end
endfunction

reg signed [15:0] i_acc;
reg signed [15:0] err_prev;

// next-state combinational terms (single-beat update; all constant folds)
wire signed [31:0] i_sum   = {{16{i_acc[15]}}, i_acc} + {{16{err_in[15]}}, err_in};
wire signed [15:0] i_next  = clamp16(i_sum, I_LIM);
wire signed [31:0] d_wide  = {{16{err_in[15]}}, err_in} - {{16{err_prev[15]}}, err_prev};
wire signed [15:0] d_err   = sat16(d_wide);
wire signed [31:0] p_term  = smul8(err_in, KP_MUL) >>> KP_SH;
wire signed [31:0] i_term  = smul8(i_next, KI_MUL) >>> KI_SH;
wire signed [31:0] d_term  = smul8(d_err,  KD_MUL) >>> KD_SH;
wire signed [31:0] u_wide  = p_term + i_term + d_term;
wire signed [15:0] u_next  = clamp16(u_wide, OUT_LIM);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        i_acc     <= 16'sd0;
        err_prev  <= 16'sd0;
        u_out     <= 16'sd0;
        out_valid <= 1'b0;
    end else if (clk_en) begin
        out_valid <= in_valid;
        if (in_valid) begin
            i_acc    <= i_next;
            err_prev <= err_in;
            u_out    <= u_next;
        end
    end
end

endmodule
