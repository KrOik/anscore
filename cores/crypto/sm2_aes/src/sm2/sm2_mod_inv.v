`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sm2_mod_inv.iv — 二改新增模块
// Binary extended-GCD modular inversion for 256-bit odd modulus.
//   Computes r = a^{-1} mod m  (m odd, 1 <= a < m)
//   Works for both the SM2 field prime p and the group order n.
// One micro-step per cycle; worst case ~2K cycles, error flag on timeout
// or non-invertible input.
//////////////////////////////////////////////////////////////////////////////////
module sm2_mod_inv(
    input               clk,
    input               rst_n,

    input               start,
    input  [255:0]      a_i,
    input  [255:0]      m_i,

    output reg          busy,
    output reg          done,
    output reg          err,
    output reg [255:0]  r_o
);

localparam S_IDLE  = 3'd0;
localparam S_INIT  = 3'd1;
localparam S_UHALF = 3'd2;
localparam S_VHALF = 3'd3;
localparam S_CMP   = 3'd4;
localparam S_TERM  = 3'd5;

reg [2:0]    state;
reg [255:0]  iu, iv;
reg [256:0]  ix, iy;          // may reach m+ix < 2^257 before halving
reg [256:0]  m_ext;
reg [12:0]   iter;          // bound counter

wire [256:0] x_half = ix[0] ? (ix + m_ext) >> 1 : ix >> 1;
wire [256:0] y_half = iy[0] ? (iy + m_ext) >> 1 : iy >> 1;
wire         u_ge_v = (iu >= iv);
wire [256:0] x_sub_y = (ix >= iy) ? (ix - iy) : (ix - iy + m_ext);
wire [256:0] y_sub_x = (iy >= ix) ? (iy - ix) : (iy - ix + m_ext);
wire [255:0] u_sub_v = iu - iv;
wire [255:0] v_sub_u = iv - iu;
wire [255:0] u_half  = iu >> 1;
wire [255:0] v_half  = iv >> 1;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        state <= S_IDLE;
        busy  <= 1'b0;
        done  <= 1'b0;
        err   <= 1'b0;
        r_o   <= 256'b0;
        iu <= 0; iv <= 0; ix <= 0; iy <= 0; m_ext <= 0; iter <= 0;
    end else begin
        done <= 1'b0;
        case (state)
            S_IDLE: begin
                err <= 1'b0;
                if (start) begin
                    m_ext <= {1'b0, m_i};
                    iu <= a_i;
                    iv <= m_i;
                    ix <= 257'd1;
                    iy <= 257'd0;
                    iter <= 0;
                    busy <= 1'b1;
                    if (a_i == 0 || a_i >= m_i)
                        state <= S_INIT;      // reduce / reject first
                    else
                        state <= S_UHALF;
                end
            end

            S_INIT: begin
                // reduce a mod m (a < 2^256; for SM2's ~256-bit moduli this
                // converges in a single subtract; small m still terminates
                // since iu strictly decreases)
                if (iu == 0) begin
                    busy <= 1'b0; err <= 1'b1; done <= 1'b1;
                    state <= S_IDLE;
                end else if (iu >= m_i) begin
                    iu <= iu - m_i;
                end else begin
                    state <= S_UHALF;
                end
            end

            S_UHALF: begin
                if (iu == 0) begin
                    busy <= 1'b0; err <= 1'b1; done <= 1'b1;
                    state <= S_IDLE;
                end else if (iu[0] == 1'b0) begin
                    iu <= u_half;
                    ix <= x_half;
                    iter <= iter + 1'b1;
                end else begin
                    state <= S_VHALF;
                end
            end

            S_VHALF: begin
                if (iv == 0) begin
                    busy <= 1'b0; err <= 1'b1; done <= 1'b1;
                    state <= S_IDLE;
                end else if (iv[0] == 1'b0) begin
                    iv <= v_half;
                    iy <= y_half;
                    iter <= iter + 1'b1;
                end else begin
                    state <= S_CMP;
                end
            end

            S_CMP: begin
`ifdef INV_DEBUG
                $display("CMPIN iu=%h iv=%h ix=%h iy=%h ge=%b", iu, iv, ix, iy, u_ge_v);
`endif
                if (u_ge_v) begin
                    iu <= u_sub_v;
                    ix <= x_sub_y;
                end else begin
                    iv <= v_sub_u;
                    iy <= y_sub_x;
                end
                iter <= iter + 1'b1;
                state <= S_TERM;
            end

            S_TERM: begin
                if (iu == 1) begin
                    r_o  <= ix[255:0];
                    busy <= 1'b0; done <= 1'b1;
                    state <= S_IDLE;
                end else if (iv == 1) begin
                    r_o  <= iy[255:0];
                    busy <= 1'b0; done <= 1'b1;
                    state <= S_IDLE;
                end else if (iter > 13'd6000) begin
                    busy <= 1'b0; err <= 1'b1; done <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    state <= S_UHALF;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
