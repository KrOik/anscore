`timescale 1ns / 1ps
// ips_spi_slave_reg : SPI mode 0-3 slave, 8/16-bit frame, register-indexed
// read/write with CS-edge alignment.
//
// Contract (docs/IP_CORE_SOP.md: clk_en gates every register, rst_n is the
// active-low asynchronous reset):
//   * ss_n / sclk / mosi are sampled pins, miso is the physical tri-state pin.
//     It is released unless o_drive is set, and while driven it equals the
//     registered launch bit o_txb, which takes o_tx[FRAME-1] on every launch
//     (shift) edge and on the edge that loads a new transmit frame.
//   * SPI_MODE is the IEEE mode number, a numeric parameter:
//     cpol = SPI_MODE[1], cpha = SPI_MODE[0].  sclk is sampled through a
//     three-stage chain and an edge is committed only once the level has been
//     sampled three times in a row, so the sampling edge is the rising edge for
//     modes 0 and 3 and the falling edge for modes 1 and 2; the shift edge is
//     the other one.
//   * CS-edge alignment: the falling edge of ss_n restarts the bit counter,
//     clears the receive shifter and puts the core in the command phase.  The
//     first complete frame of an assertion is the command: its MSB is the
//     direction bit (1 = read) and bits 6..0 become the 8-bit register pointer.
//     Every later complete frame of the same assertion is a data frame: a write
//     stores it at ptr, a read shifts out the register at ptr, and ptr
//     increments with 8-bit wrap after each data frame.
//   * The file index is ptr & RF_MASK, so a pointer above RF_MASK aliases onto
//     the low RF_SIZE entries; that aliasing is part of the contract.
//   * A frame that is only partially clocked when ss_n rises increments
//     o_err_short and leaves the leftover bit count in o_rem; a complete frame
//     leaves the counters alone.  A sampling edge seen while ss_n is inactive
//     increments o_err_no_cs and changes no shift state at all.
//   * o_xfer counts every complete frame, o_rx is the last complete received
//     frame and o_tx is the live transmit shift register.
module ips_spi_slave_reg #(
    parameter SPI_MODE = 0,
    parameter FRAME    = 8,
    parameter REG_BITS = 3
)(
    input  wire              clk,
    input  wire              clk_en,
    input  wire              rst_n,
    input  wire              ss_n,
    input  wire              sclk,
    input  wire              mosi,
    inout  wire              miso,
    output reg [FRAME-1:0]   o_rx,
    output reg [FRAME-1:0]   o_tx,
    output reg [7:0]         ptr,
    output reg [2:0]         o_state,
    output reg [3:0]         o_err_no_cs,
    output reg [3:0]         o_err_short,
    output reg [7:0]         o_xfer,
    output reg [3:0]         o_rem,
    output reg               o_drive,
    output reg               o_txb,
    output reg               o_rw
);

localparam integer RF_SIZE = (1 << REG_BITS);
localparam integer RF_MASK = RF_SIZE - 1;

localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_CMD  = 3'd1;
localparam [2:0] S_WR   = 3'd2;
localparam [2:0] S_RD   = 3'd3;

localparam integer RF_SH = $clog2(FRAME);

reg [RF_SIZE*FRAME-1:0] rf;
reg               ss_d1, ss_d2;
reg               sck_d1, sck_d2, sck_d3;
reg               mosi_d1, mosi_d2;
reg               hi_r, lo_r;
reg [7:0]         bit_cnt;
reg [FRAME-1:0]   rx_sh;

wire cpol  = SPI_MODE[1];
wire cpha  = SPI_MODE[0];

wire [FRAME-1:0] rxf = {rx_sh[FRAME-2:0], mosi_d1};
wire [7:0] cptr  = {1'b0, rxf[6:0]};
wire [7:0] cidx  = cptr & RF_MASK;
wire [7:0] idx   = ptr & RF_MASK;
wire [7:0] nptr  = ptr + 8'd1;
wire [7:0] nidx  = nptr & RF_MASK;
wire [7:0] rsel  = (o_state == S_CMD) ? cidx : nidx;
wire [15:0] rbase = {8'd0, rsel} << RF_SH;
wire [15:0] wbase = {8'd0, idx} << RF_SH;
wire [FRAME-1:0] rdata = rf[rbase +: FRAME];
wire       hi3    = sck_d1 & sck_d2 & sck_d3;
wire       lo3    = ~sck_d1 & ~sck_d2 & ~sck_d3;
wire       evt_hi = hi3 & ~hi_r;
wire       evt_lo = lo3 & ~lo_r;
wire       samp_hi = ~(cpol ^ cpha);
wire       evt_samp  = samp_hi ? evt_hi : evt_lo;
wire       evt_shift = samp_hi ? evt_lo : evt_hi;
wire       cs_act    = ~ss_d1;
wire       ev_cs_lo  = ~ss_d1 & ss_d2;
wire       ev_cs_hi  =  ss_d1 & ~ss_d2;
wire       last_bit  = (bit_cnt == (FRAME - 1));

assign miso = o_drive ? o_txb : 1'bz;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ss_d1     <= 1'b1;
        ss_d2     <= 1'b1;
        sck_d1    <= 1'b0;
        sck_d2    <= 1'b0;
        sck_d3    <= 1'b0;
        mosi_d1   <= 1'b1;
        mosi_d2   <= 1'b1;
        hi_r      <= 1'b0;
        lo_r      <= 1'b1;
        o_state   <= S_IDLE;
        bit_cnt   <= 8'd0;
        rx_sh     <= {FRAME{1'b0}};
        o_rx      <= {FRAME{1'b0}};
        o_tx      <= {FRAME{1'b0}};
        ptr       <= 8'h00;
        o_err_no_cs <= 4'h0;
        o_err_short <= 4'h0;
        o_xfer    <= 8'h00;
        o_rem     <= 4'h0;
        o_drive   <= 1'b0;
        o_txb     <= 1'b1;
        o_rw      <= 1'b0;
        rf        <= {(RF_SIZE * FRAME){1'b0}};
    end else if (clk_en) begin
        ss_d1   <= ss_n;
        ss_d2   <= ss_d1;
        sck_d1  <= sclk;
        sck_d2  <= sck_d1;
        sck_d3  <= sck_d2;
        mosi_d1 <= mosi;
        mosi_d2 <= mosi_d1;
        hi_r    <= hi3;
        lo_r    <= lo3;

        if (ev_cs_lo) begin
            bit_cnt <= 8'd0;
            rx_sh   <= {FRAME{1'b0}};
            o_state <= S_CMD;
        end
        else if (ev_cs_hi) begin
            if (bit_cnt != 8'd0) begin
                o_err_short <= o_err_short + 4'd1;
                o_rem       <= bit_cnt[3:0];
            end
            o_state <= S_IDLE;
            o_drive <= 1'b0;
        end
        else if (evt_samp) begin
            if (!cs_act) begin
                o_err_no_cs <= o_err_no_cs + 4'd1;
            end
            else begin
                rx_sh   <= rxf;
                bit_cnt <= bit_cnt + 8'd1;
                if (last_bit) begin
                    o_rx    <= rxf;
                    o_xfer  <= o_xfer + 8'd1;
                    bit_cnt <= 8'd0;
                    case (o_state)
                        S_CMD: begin
                            ptr     <= cptr;
                            o_rw    <= rxf[FRAME-1];
                            o_state <= rxf[FRAME-1] ? S_RD : S_WR;
                            o_txb   <= rdata[FRAME-1];
                            o_tx    <= rdata;
                            o_drive <= rxf[FRAME-1];
                        end
                        S_WR: begin
                            rf[wbase +: FRAME] <= rxf;
                            ptr     <= nptr;
                            o_drive <= 1'b0;
                        end
                        S_RD: begin
                            o_txb   <= rdata[FRAME-1];
                            o_tx    <= rdata;
                            ptr     <= nptr;
                        end
                        default: begin
                            o_drive <= 1'b0;
                        end
                    endcase
                end
            end
        end
        else if (evt_shift) begin
            if (cs_act && o_drive) begin
                o_txb <= o_tx[FRAME-1];
                o_tx  <= {o_tx[FRAME-2:0], 1'b1};
            end
        end
    end
end

endmodule
