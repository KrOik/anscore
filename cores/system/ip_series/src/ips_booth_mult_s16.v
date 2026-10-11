`timescale 1ns / 1ps
// ips_booth_mult_s16 : signed 16x16 -> 32-bit radix-4 Booth multiplier built as
// one accumulator walked by four pipeline stages.
//
// Written contract, mirrored independently by models/ips_booth_mult_s16.py:
//   stage 0 = idle, 1 = operand capture, 2 = ITER radix-4 partial-product beats
//   (one digit per enabled clock, counted in ppc), 3 = collect, PIPE = output.
//   Digit d_i = -2*b(2i+1) + b(2i) + b(2i-1) with b(-1) = 0, partial product
//   d_i * (operand_a << 2i); every step is summed modulo 2**32, so the collected
//   product equals operand_a * operand_b in two's complement.
//   ovf marks a collected product outside the signed 16-bit operand range
//   [-32768, 32767], which is the same test as product[31:16] differing from the
//   sign extension of product[15].  valid pulses for exactly one enabled beat
//   after collect.  product and ovf clear when a new operation is captured, so
//   the flags always describe the registered product.
//   start asserted while busy is dropped and counted in err_start (8-bit, wraps).
//   Every register is gated by clk_en and rst_n is the active-low asynchronous
//   reset (docs/IP_CORE_SOP.md trap T2).
module ips_booth_mult_s16 #(
    parameter ITER = 8,
    parameter PIPE = 4
)(
    input  wire               clk,
    input  wire               clk_en,
    input  wire               rst_n,

    input  wire               start,
    input  wire signed [15:0] operand_a,
    input  wire signed [15:0] operand_b,

    output reg  signed [31:0] product,
    output reg                ovf,
    output reg                valid,
    output wire               busy,
    output reg  [3:0]         stage,
    output reg  [3:0]         ppc,
    output reg  [7:0]         err_start
);

localparam [3:0] S_IDLE = 4'sd0;
localparam [3:0] S_CAP  = 4'sd1;
localparam [3:0] S_ACC  = 4'sd2;
localparam [3:0] S_COL  = 4'sd3;
localparam [3:0] S_END  = ITER - 4'sd1;
localparam signed [31:0] FIT_HI = 32'sd32767;
localparam signed [31:0] FIT_LO = -32'sd32768;

assign busy = (stage != S_IDLE);

reg signed [31:0] acc;
reg signed [31:0] ash;
reg signed [15:0] qreg;
reg               qm1;

wire signed [31:0] a_sext = operand_a;
wire        [2:0]  digit  = {qreg[1], qreg[0], qm1};
wire signed [31:0] ash2   = $signed({ash[30:0], 1'b0});
wire               d_dbl  = (digit[2] && !digit[1] && !digit[0])
                         || (!digit[2] &&  digit[1] &&  digit[0]);
wire               d_neg  = digit[2] && !(digit[1] && digit[0]);
wire               d_zero = (!digit[2] && !digit[1] && !digit[0])
                         || ( digit[2] &&  digit[1] &&  digit[0]);
wire signed [31:0] mag    = d_dbl ? ash2 : ash;
wire signed [31:0] pprod  = d_zero ? 32'sd0 : (d_neg ? -mag : mag);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        product   <= 32'sd0;
        ovf       <= 1'sb0;
        valid     <= 1'sb0;
        stage     <= S_IDLE;
        ppc       <= 4'sd0;
        err_start <= 8'sd0;
        acc       <= 32'sd0;
        ash       <= 32'sd0;
        qreg      <= 16'sd0;
        qm1       <= 1'sb0;
    end else if (clk_en) begin
        if (start && (stage == S_IDLE)) begin
            product <= 32'sd0;
            ovf     <= 1'sb0;
            valid   <= 1'sb0;
            acc     <= 32'sd0;
            ash     <= a_sext;
            qreg    <= operand_b;
            qm1     <= 1'sb0;
            ppc     <= 4'sd0;
            stage   <= S_CAP;
        end else if (start && busy) begin
            err_start <= err_start + 8'h01;
        end else begin
            case (stage)
                S_CAP: begin
                    stage <= S_ACC;
                end
                S_ACC: begin
                    acc  <= acc + pprod;
                    ppc  <= ppc + 4'd1;
                    ash  <= ash <<< 2;
                    qm1  <= qreg[0];
                    qreg <= qreg >>> 2;
                    if (ppc == S_END) begin
                        stage <= S_COL;
                    end
                end
                S_COL: begin
                    product <= acc;
                    ovf     <= ((acc > FIT_HI) || (acc < FIT_LO));
                    stage   <= PIPE;
                end
                default: begin
                    if (stage == PIPE) begin
                        valid <= 1'sb1;
                        stage <= S_IDLE;
                    end else begin
                        valid <= 1'sb0;
                    end
                end
            endcase
        end
    end
end

endmodule
