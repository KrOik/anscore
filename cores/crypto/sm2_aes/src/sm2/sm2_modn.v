`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sm2_modn.v — 二改新增模块
// Serial modular arithmetic over an arbitrary 256-bit modulus m
// (used for SM2 group-order n arithmetic: r*d, k-r*d, s*(...), r+s, e+x1).
//   op_i: 0 = (a+b) mod m   (1 cycle)
//         1 = (a-b) mod m   (1 cycle)
//         2 = (a*b) mod m   (~512 cycles, shift-add-reduce)
//         3 = reserved
//////////////////////////////////////////////////////////////////////////////////
module sm2_modn(
    input               clk,
    input               rst_n,

    input               start,
    input  [1:0]        op_i,
    input  [255:0]      a_i,
    input  [255:0]      b_i,
    input  [255:0]      m_i,

    output reg          busy,
    output reg          done,
    output reg [255:0]  r_o
);

localparam OP_ADD = 2'd0;
localparam OP_SUB = 2'd1;
localparam OP_MUL = 2'd2;

localparam S_IDLE   = 3'd0;
localparam S_SHIFT  = 3'd1;
localparam S_ADDB   = 3'd2;
localparam S_FIN    = 3'd3;

reg [2:0]    state;
reg [8:0]    bit_cnt;
reg [255:0]  acc;
reg [255:0]  a_reg, b_reg;
reg [255:0]  m_reg;

// combinational helper results
// NOTE: single-cycle ADD/SUB ops must use the *input* operands — a_reg/b_reg
// only become valid one cycle after start.
wire [256:0] sum_i    = {1'b0, a_i} + {1'b0, b_i};
wire [256:0] dif_i    = {1'b0, a_i} - {1'b0, b_i};
wire [256:0] dif_i_m  = {1'b0, a_i} + {1'b0, m_i} - {1'b0, b_i};
wire [256:0] sum_ab   = {1'b0, a_reg} + {1'b0, b_reg};
wire [256:0] dif_ab   = {1'b0, a_reg} - {1'b0, b_reg};
wire [256:0] dif_ab_m = {1'b0, a_reg} + {1'b0, m_reg} - {1'b0, b_reg};
wire [257:0] acc_sh   = {acc, 1'b0};                    // 258-bit shift
wire [257:0] acc_sh_m = acc_sh - {2'b00, m_reg};
wire [256:0] acc_pa   = {1'b0, acc} + {1'b0, a_reg};
wire [256:0] acc_pa_m = acc_pa - {1'b0, m_reg};

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        state <= S_IDLE;
        busy  <= 1'b0;
        done  <= 1'b0;
        r_o   <= 256'b0;
        bit_cnt <= 0;
        acc <= 0; a_reg <= 0; b_reg <= 0; m_reg <= 0;
    end else begin
        done <= 1'b0;
        case (state)
            S_IDLE: begin
                if (start) begin
                    a_reg <= a_i;
                    b_reg <= b_i;
                    m_reg <= m_i;
                    busy  <= 1'b1;
                    if (op_i == OP_MUL) begin
                        acc <= 0;
                        bit_cnt <= 9'd256;   // bits 255..0 of b
                        state <= S_SHIFT;
                    end else if (op_i == OP_ADD) begin
                        // (a+b) mod m: a,b < m assumed; one conditional sub
                        r_o <= sum_i[256] || sum_i >= {1'b0, m_i}
                               ? sum_i[255:0] - m_i
                               : sum_i[255:0];
                        busy <= 1'b0; done <= 1'b1;
                    end else if (op_i == OP_SUB) begin
                        r_o <= dif_i[256] ? dif_i_m[255:0] : dif_i[255:0];
                        busy <= 1'b0; done <= 1'b1;
                    end else begin
                        busy <= 1'b0; done <= 1'b1;
                    end
                end
            end

            // res = 2*res mod m
            S_SHIFT: begin
                acc <= acc_sh[257] || acc_sh >= {2'b00, m_reg}
                       ? acc_sh_m[255:0]
                       : acc_sh[255:0];
                state <= S_ADDB;
            end

            // if b[bit]: res = res + a mod m ; then next bit
            S_ADDB: begin
                if (b_reg[bit_cnt - 9'd1]) begin
                    acc <= acc_pa[256] || acc_pa >= {1'b0, m_reg}
                           ? acc_pa_m[255:0]
                           : acc_pa[255:0];
                end
                if (bit_cnt == 9'd1)
                    state <= S_FIN;
                else begin
                    bit_cnt <= bit_cnt - 9'd1;
                    state <= S_SHIFT;
                end
            end

            S_FIN: begin
                r_o <= acc;
                busy <= 1'b0;
                done <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
