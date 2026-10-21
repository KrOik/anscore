// SPI master, parameterizable CPOL/CPHA, SCLK divider and 1..32-bit frames.
// Board-validated configuration: mode 0 (CPOL=0, CPHA=0).
//
//   tx_data[nbits-1:0]  frame payload, transmitted MSB first
//   rx_data[nbits-1:0]  received bits, first sampled bit ends at MSB position
//                       of the nbits field (right-justified)
//   start               single-cycle pulse while idle
//   done                level, held until the next start
//   SCLK_DIV            clk_en ticks per half SCLK period
//
// clk_en gates all internal state.
module spi_master #(
    parameter integer CPOL     = 0,
    parameter integer CPHA     = 0,
    parameter integer SCLK_DIV = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clk_en,
    input  wire        start,
    input  wire [5:0]  nbits,
    input  wire [31:0] tx_data,
    output reg  [31:0] rx_data,
    output reg         busy,
    output reg         done,
    output reg         sclk,
    output wire        mosi,
    input  wire        miso,
    output reg         cs_n
);

localparam integer CNT_W = (SCLK_DIV <= 1) ? 1 : $clog2(SCLK_DIV);

localparam [1:0] ST_IDLE  = 2'd0;
localparam [1:0] ST_SETUP = 2'd1;
localparam [1:0] ST_RUN   = 2'd2;
localparam [1:0] ST_TAIL  = 2'd3;

reg [1:0]       state;
reg [CNT_W-1:0] hcnt;
reg [5:0]       edge_i;      // sclk transition index, 0..2*nbits-1
reg [5:0]       nbits_r;
reg [31:0]      tx_shift;
reg [31:0]      rx_shift;
reg             mosi_r;
reg             miso_d;

assign mosi = mosi_r;

// left-justified transmit word: bit to send is tx_lj[31]
wire [31:0] tx_lj = tx_data << (7'd32 - {1'b0, nbits});
// CPHA=0: leading (even) edges sample; CPHA=1: trailing (odd) edges sample.
wire sample_edge = (CPHA == 0) ? (edge_i[0] == 1'b0) : (edge_i[0] == 1'b1);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state    <= ST_IDLE;
        hcnt     <= {CNT_W{1'b0}};
        edge_i     <= 6'd0;
        nbits_r  <= 6'd0;
        tx_shift <= 32'd0;
        rx_shift <= 32'd0;
        rx_data  <= 32'd0;
        busy     <= 1'b0;
        done     <= 1'b0;
        sclk     <= CPOL[0];
        cs_n     <= 1'b1;
        mosi_r   <= 1'b0;
        miso_d   <= 1'b0;
    end else if (clk_en) begin
        miso_d <= miso;
        case (state)
            ST_IDLE: begin
                cs_n  <= 1'b1;
                sclk  <= CPOL[0];
                busy  <= 1'b0;
                hcnt  <= {CNT_W{1'b0}};
                edge_i  <= 6'd0;
                if (start) begin
                    nbits_r  <= nbits;
                    rx_shift <= 32'd0;
                    done     <= 1'b0;
                    busy     <= 1'b1;
                    cs_n     <= 1'b0;
                    if (CPHA == 0) begin
                        // first data bit must be on MOSI before the first edge_i
                        mosi_r   <= tx_lj[31];
                        tx_shift <= {tx_lj[30:0], 1'b0};
                    end else begin
                        mosi_r   <= 1'b0;
                        tx_shift <= tx_lj;
                    end
                    state <= ST_SETUP;
                end
            end

            ST_SETUP: begin                 // cs_n setup time = one half period
                if (hcnt == SCLK_DIV - 1) begin
                    hcnt  <= {CNT_W{1'b0}};
                    state <= ST_RUN;
                end else begin
                    hcnt <= hcnt + 1'b1;
                end
            end

            ST_RUN: begin
                if (hcnt == SCLK_DIV - 1) begin
                    hcnt <= {CNT_W{1'b0}};
                    sclk <= ~sclk;
                    if (sample_edge) begin
                        rx_shift <= {rx_shift[30:0], miso_d};
                    end else begin
                        mosi_r   <= tx_shift[31];
                        tx_shift <= {tx_shift[30:0], 1'b0};
                    end
                    edge_i <= edge_i + 6'd1;
                    if (edge_i == (nbits_r * 2 - 1)) state <= ST_TAIL;
                end else begin
                    hcnt <= hcnt + 1'b1;
                end
            end

            ST_TAIL: begin                  // trailing half period, then cs up
                if (hcnt == SCLK_DIV - 1) begin
                    hcnt    <= {CNT_W{1'b0}};
                    cs_n    <= 1'b1;
                    sclk    <= CPOL[0];
                    rx_data <= rx_shift;
                    done    <= 1'b1;
                    busy    <= 1'b0;
                    state   <= ST_IDLE;
                end else begin
                    hcnt <= hcnt + 1'b1;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
