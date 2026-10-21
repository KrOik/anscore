`timescale 1ns / 1ps
// ips_modbus_rtu_fsm : Modbus RTU slave framing over a byte pipe, for the
// ip_series_20k line.
//
// The 3.5 character silence that closes an RTU frame is measured against an
// explicit tick input, and the bytes are handed over one per enabled cycle, so
// models/ips_modbus_rtu_fsm.py replays every frame, CRC state and exception
// response cycle-exactly.  There is no internal baud counter.
//
// Written contract:
//   * a byte is consumed on any enabled cycle with rx_valid high, and it resets
//     the silence counter.  The first byte of a burst opens a frame, seeds the
//     CRC with CRC_SEED and is captured as rx_addr; the second byte is captured
//     as rx_func.  rx_len counts the bytes of the open frame and holds at 255.
//   * while a frame is open, every tick without a byte increments silence; when
//     silence would reach T35 the frame ends and is evaluated once.  Longer
//     silences do not re-close it, and no byte is consumed while a response is
//     being sent (those bytes are lost, which is what a single-buffered slave
//     does).
//   * rx_len is the size of the ADU on the wire, the two CRC bytes included: a
//     supported function with the supported length therefore has rx_len ==
//     FUNC_LEN, and MIN_LEN is the shortest wire frame worth evaluating.
//   * evaluation order is fixed: rx_len below MIN_LEN is a short frame
//     (short_count); otherwise the running CRC must have folded to 16'h0000,
//     which is the CRC16/Modbus property of a frame whose own two CRC bytes are
//     included (crc_err_count on failure); then the address filter: a frame for
//     another node is counted and dropped (not_addr_count) and address 8'h00 is
//     a broadcast that is executed without any response (broadcast_count).
//   * function dispatch of an addressed, CRC-valid frame: FUNC_READ and
//     FUNC_WRITE are supported and need exactly FUNC_LEN bytes; anything else
//     gets an explicit illegal-function exception, never a silent alias.  A
//     supported function with the wrong length gets an illegal-data exception.
//     A supported, correctly sized function is acknowledged.
//   * the response is always five bytes on the tx pipe, one per enabled cycle:
//     rx_addr, rx_func (bit 7 set for an exception), the exception code (0 for an
//     acknowledge), then the CRC16 of those three bytes low byte first.  The
//     response CRC is folded by the same CRC register, reseeded with CRC_SEED
//     when the response starts.
//   * CRC16/Modbus: reflected polynomial CRC_POLY (8'hA001 form), seed
//     CRC_SEED, xor-in at the low byte, eight shift/XOR steps per byte, no final
//     complement.
//   * counters saturate at 8'hFF.  exc_count counts answered exceptions and
//     frame_count counts acknowledged frames.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).
module ips_modbus_rtu_fsm #(
    parameter T35 = 40,
    parameter MIN_LEN = 4,
    parameter FUNC_LEN = 8,
    parameter FUNC_READ = 8'h03,
    parameter FUNC_WRITE = 8'h06,
    parameter EXC_FUNC = 8'h01,
    parameter CRC_POLY = 16'hA001,
    parameter CRC_SEED = 16'hFFFF
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,
    input  wire       tick,
    input  wire       rx_valid,
    input  wire [7:0] rx_byte,
    input  wire [7:0] slv_addr,
    output reg [7:0]  rx_addr,
    output reg [7:0]  rx_func,
    output reg [7:0]  rx_len,
    output reg [15:0] crc_state,
    output reg [7:0]  silence,
    output reg [2:0]  state,
    output reg        tx_valid,
    output reg [7:0]  tx_byte,
    output reg [2:0]  tx_idx,
    output reg [7:0]  crc_err_count,
    output reg [7:0]  short_count,
    output reg [7:0]  not_addr_count,
    output reg [7:0]  broadcast_count,
    output reg [7:0]  exc_count,
    output reg [7:0]  frame_count
);

localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_RX = 3'd1;
localparam [2:0] S_ANS = 3'd2;
localparam [7:0] SIL_END = T35 - 1;
localparam [2:0] TX_LAST = 3'd4;
localparam [7:0] EXC_DATA = 8'h03;
localparam [7:0] ACK_CODE = 8'h00;
localparam [15:0] CRC_GOOD = 16'h0000;

reg [7:0] resp_addr;
reg [7:0] resp_func;
reg [7:0] resp_code;

function [15:0] crc_upd;
    input [15:0] c;
    input [7:0] d;
    integer k;
    reg [15:0] x;
    begin
        x = c ^ {8'h00, d};
        for (k = 0; k < 8; k = k + 1) begin
            if (x[0]) begin
                x = {1'b0, x[15:1]} ^ CRC_POLY;
            end else begin
                x = {1'b0, x[15:1]};
            end
        end
        crc_upd = x;
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_addr        <= 8'h00;
        rx_func        <= 8'h00;
        rx_len         <= 8'h00;
        crc_state      <= 16'h0000;
        silence        <= 8'h00;
        state          <= S_IDLE;
        tx_valid       <= 1'b0;
        tx_byte        <= 8'h00;
        tx_idx         <= 3'd0;
        crc_err_count  <= 8'h00;
        short_count    <= 8'h00;
        not_addr_count <= 8'h00;
        broadcast_count <= 8'h00;
        exc_count      <= 8'h00;
        frame_count    <= 8'h00;
        resp_addr      <= 8'h00;
        resp_func      <= 8'h00;
        resp_code      <= 8'h00;
    end else if (clk_en) begin
        if (rx_valid && (state != S_ANS)) begin
            if (state == S_IDLE) begin
                state     <= S_RX;
                rx_len    <= 8'd1;
                rx_addr   <= rx_byte;
                crc_state <= crc_upd(CRC_SEED, rx_byte);
            end else begin
                crc_state <= crc_upd(crc_state, rx_byte);
                if (rx_len != 8'hFF) begin
                    rx_len <= rx_len + 8'd1;
                end
                if (rx_len == 8'd1) begin
                    rx_func <= rx_byte;
                end
            end
            silence <= 8'h00;
        end else if (state == S_ANS) begin
            tx_valid <= 1'b1;
            case (tx_idx)
                3'd0: begin
                    tx_byte   <= resp_addr;
                    crc_state <= crc_upd(crc_state, resp_addr);
                end
                3'd1: begin
                    tx_byte   <= resp_func;
                    crc_state <= crc_upd(crc_state, resp_func);
                end
                3'd2: begin
                    tx_byte   <= resp_code;
                    crc_state <= crc_upd(crc_state, resp_code);
                end
                3'd3: begin
                    tx_byte   <= crc_state[7:0];
                end
                3'd4: begin
                    tx_byte   <= crc_state[15:8];
                end
                default: begin
                    tx_byte   <= tx_byte;
                end
            endcase
            if (tx_idx == TX_LAST) begin
                tx_idx   <= 3'd0;
                tx_valid <= 1'b0;
                state    <= S_IDLE;
                silence  <= 8'h00;
            end else begin
                tx_idx <= tx_idx + 3'd1;
            end
        end else if (tick) begin
            if (silence != 8'hFF) begin
                silence <= silence + 8'd1;
            end
            if ((state == S_RX) && (silence == SIL_END)) begin
                state <= S_IDLE;
                if (rx_len < MIN_LEN) begin
                    if (short_count != 8'hFF) begin
                        short_count <= short_count + 8'h01;
                    end
                end else if (crc_state != CRC_GOOD) begin
                    if (crc_err_count != 8'hFF) begin
                        crc_err_count <= crc_err_count + 8'h01;
                    end
                end else if ((rx_addr != slv_addr) && (rx_addr != 8'h00)) begin
                    if (not_addr_count != 8'hFF) begin
                        not_addr_count <= not_addr_count + 8'h01;
                    end
                end else if (rx_addr == 8'h00) begin
                    if (broadcast_count != 8'hFF) begin
                        broadcast_count <= broadcast_count + 8'h01;
                    end
                end else begin
                    resp_addr <= rx_addr;
                    tx_idx    <= 3'd0;
                    state     <= S_ANS;
                    crc_state <= CRC_SEED;
                    if ((rx_func != FUNC_READ) && (rx_func != FUNC_WRITE)) begin
                        resp_func <= rx_func | 8'h80;
                        resp_code <= EXC_FUNC;
                        if (exc_count != 8'hFF) begin
                            exc_count <= exc_count + 8'h01;
                        end
                    end else if (rx_len != FUNC_LEN) begin
                        resp_func <= rx_func | 8'h80;
                        resp_code <= EXC_DATA;
                        if (exc_count != 8'hFF) begin
                            exc_count <= exc_count + 8'h01;
                        end
                    end else begin
                        resp_func <= rx_func;
                        resp_code <= ACK_CODE;
                        if (frame_count != 8'hFF) begin
                            frame_count <= frame_count + 8'h01;
                        end
                    end
                end
            end
        end
    end
end

endmodule
