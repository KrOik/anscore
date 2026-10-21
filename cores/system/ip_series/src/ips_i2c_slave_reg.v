`timescale 1ns / 1ps
// ips_i2c_slave_reg : 7-bit addressed I2C slave register file.
//
// Contract (docs/IP_CORE_SOP.md: clk_en gates every register, rst_n is the
// active-low asynchronous reset):
//   * scl and sda are the physical open-drain pins.  sda is driven only low
//     (o_lo), never high.  Both pins go through a three-stage sample chain.
//     A data clock is committed only once SCL has been sampled high three
//     times in a row (input filter), so the short SCL pulse of a STOP
//     sequence can never shift a bit in.  START is a SDA low sample edge
//     while SCL has been high for two samples, STOP the rising equivalent.
//     START and STOP have priority over the data clock and over the falling
//     edge action, and they always return the core to the idle state.
//   * Address byte: bits 7..1 are compared with SLAVE_ADDR, bit 0 is R/W#.
//     The compare happens on the eighth data clock; the acknowledge is
//     asserted on the following falling edge and held through the ninth clock.
//     A mismatch increments the wrapping o_err_nam counter and the rest of the
//     transaction is ignored (S_IGN) without ever driving the pin.
//   * Write (R/W#=0): the first data byte loads the 8-bit register pointer and
//     does not store; each later byte is written to the register file at
//     ptr[REG_BITS-1:0] and increments ptr with 8-bit wrap.
//   * Read (R/W#=1): the file word at ptr is shifted out MSB first, ptr
//     increments after every transmitted byte, and a master NACK ends the
//     read through S_END without an error count.
//   * A START or STOP that arrives with a partial byte in flight (bit counter
//     non zero) increments the wrapping o_err_fmt counter.  o_txn counts every
//     STOP that terminated an addressed transaction.  A repeated START landing
//     on a byte boundary is therefore free of both drain and error.
module ips_i2c_slave_reg #(
    parameter SLAVE_ADDR = 7'h34,
    parameter REG_BITS   = 3
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,
    input  wire       scl,
    inout  wire       sda,
    output reg [2:0]  o_state,
    output reg [7:0]  ptr,
    output reg [7:0]  o_rdata,
    output reg [7:0]  o_last,
    output reg [3:0]  o_err_nam,
    output reg [3:0]  o_err_fmt,
    output reg [7:0]  o_txn,
    output reg        o_ack,
    output reg        o_lo
);

localparam integer RF_SIZE = (1 << REG_BITS);
localparam integer RF_MASK = RF_SIZE - 1;

localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_ADR  = 3'd1;
localparam [2:0] S_RX   = 3'd2;
localparam [2:0] S_TX   = 3'd3;
localparam [2:0] S_IGN  = 3'd4;
localparam [2:0] S_END  = 3'd5;

reg [RF_SIZE*8-1:0] rf;
reg                 scl_d1, scl_d2, scl_d3;
reg                 sda_d1, sda_d2;
reg                 hi_r, lo_r;
reg  [3:0]          bits;
reg  [7:0]          shift, byte_r, tx_sh;
reg                 matched, rw, first_b, nack;

wire [7:0] nb      = {shift[6:0], sda_d1};
wire       scl_hi3 = scl_d1 & scl_d2 & scl_d3;
wire       clk_bit = scl_hi3 & ~hi_r;
wire       scl_lo2 = ~scl_d1 & ~scl_d2;
wire       evt_lo  = scl_lo2 & ~lo_r;
wire       scl_hs  = scl_d1 & scl_d2;
wire       ev_st   = scl_hs & ~sda_d1 & sda_d2;
wire       ev_sp   = scl_hs &  sda_d1 & ~sda_d2;
wire [7:0] idx     = ptr & RF_MASK;
wire [7:0] nptr    = ptr + 8'd1;
wire [7:0] nidx    = nptr & RF_MASK;

assign sda = o_lo ? 1'b0 : 1'bz;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scl_d1   <= 1'b0;
        scl_d2   <= 1'b0;
        scl_d3   <= 1'b0;
        sda_d1   <= 1'b0;
        sda_d2   <= 1'b0;
        hi_r     <= 1'b0;
        lo_r     <= 1'b0;
        o_state  <= S_IDLE;
        bits     <= 4'd0;
        shift    <= 8'h00;
        byte_r   <= 8'h00;
        tx_sh    <= 8'hFF;
        matched  <= 1'b0;
        rw       <= 1'b0;
        first_b  <= 1'b1;
        nack     <= 1'b0;
        ptr      <= 8'h00;
        o_rdata  <= 8'h00;
        o_last   <= 8'h00;
        o_err_nam <= 4'h0;
        o_err_fmt <= 4'h0;
        o_txn    <= 8'h00;
        o_ack    <= 1'b0;
        o_lo     <= 1'b0;
        rf       <= {(RF_SIZE * 8){1'b0}};
    end else if (clk_en) begin
        scl_d1 <= scl;
        scl_d2 <= scl_d1;
        scl_d3 <= scl_d2;
        sda_d1 <= sda;
        sda_d2 <= sda_d1;
        hi_r   <= scl_hi3;
        lo_r   <= scl_lo2;

        if (ev_st) begin
            if (o_state != S_IDLE && bits != 4'd0) begin
                o_err_fmt <= o_err_fmt + 4'd1;
            end
            bits    <= 4'd0;
            shift   <= 8'h00;
            byte_r  <= 8'h00;
            matched <= 1'b0;
            nack    <= 1'b0;
            o_ack   <= 1'b0;
            o_lo    <= 1'b0;
            first_b <= 1'b1;
            o_state <= S_ADR;
        end
        else if (ev_sp) begin
            if (o_state != S_IDLE && bits != 4'd0) begin
                o_err_fmt <= o_err_fmt + 4'd1;
            end
            if (matched) begin
                o_txn <= o_txn + 8'd1;
            end
            bits    <= 4'd0;
            matched <= 1'b0;
            o_lo    <= 1'b0;
            o_state <= S_IDLE;
        end
        else if (clk_bit) begin
            if (o_state == S_ADR || o_state == S_RX) begin
                shift <= nb;
                bits  <= bits + 4'd1;
                if (bits == 4'd7) begin
                    byte_r <= nb;
                    o_last <= nb;
                    if (o_state == S_ADR) begin
                        matched <= (nb[7:1] == SLAVE_ADDR);
                        rw      <= nb[0];
                    end
                end
            end
            else if (o_state == S_TX) begin
                bits <= bits + 4'd1;
                if (bits == 4'd8) begin
                    nack <= sda_d1;
                end
            end
        end
        else if (evt_lo) begin
            if (bits == 4'd8) begin
                o_lo  <= matched;
                o_ack <= matched;
            end
            else if (bits == 4'd9) begin
                bits <= 4'd0;
                o_lo <= 1'b0;
                case (o_state)
                    S_ADR: begin
                        if (!matched) begin
                            o_state   <= S_IGN;
                            o_err_nam <= o_err_nam + 4'd1;
                        end
                        else if (rw) begin
                            o_state <= S_TX;
                            tx_sh   <= rf[{idx, 3'd0} +: 8];
                            o_rdata <= rf[{idx, 3'd0} +: 8];
                        end
                        else begin
                            o_state <= S_RX;
                        end
                    end
                    S_RX: begin
                        if (first_b) begin
                            ptr     <= byte_r;
                            first_b <= 1'b0;
                        end
                        else begin
                            rf[{idx, 3'd0} +: 8] <= byte_r;
                            ptr <= nptr;
                        end
                    end
                    S_TX: begin
                        if (nack) begin
                            o_state <= S_END;
                        end
                        else begin
                            ptr     <= nptr;
                            tx_sh   <= rf[{nidx, 3'd0} +: 8];
                            o_rdata <= rf[{nidx, 3'd0} +: 8];
                        end
                    end
                    default: begin
                        o_lo <= 1'b0;
                    end
                endcase
            end
            else if (o_state == S_TX) begin
                o_lo   <= ~tx_sh[7];
                tx_sh  <= {tx_sh[6:0], 1'b1};
            end
        end
    end
end

endmodule
