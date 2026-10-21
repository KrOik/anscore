// SPI mode-0 slave model for selftest loopback (test fixture, synthesizable).
// clk-sampled sclk edge detection (sclk period must be >> clk period, which
// holds when the master runs on clk_en-paced SCLK_DIV ticks).
//   - while cs_n low: MOSI bits are captured on rising sclk into rx_shift;
//     MISO streams an LFSR sequence re-seeded with SEED at every cs_n fall
//   - at cs_n rise: cap_valid raises (held until cap_ack), cap_data carries
//     the captured word (right-justified), cap_bits the bit count
// LFSR8: next = {l[6:0], l[7]^l[5]^l[4]^l[3]}  (x^8+x^6+x^5+x^4+1)
module spi_slave_model #(
    parameter [7:0] SEED = 8'hB7
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sclk,
    input  wire        mosi,
    output reg         miso,
    input  wire        cs_n,
    output reg  [31:0] cap_data,
    output reg  [5:0]  cap_bits,
    output reg         cap_valid,
    input  wire        cap_ack
);

reg        sclk_d, cs_d;
reg [7:0]  lfsr;
reg [31:0] rx_shift;
reg [5:0]  bit_cnt;

wire sclk_rise =  sclk && !sclk_d;
wire sclk_fall = !sclk &&  sclk_d;
wire cs_fall   = !cs_n &&  cs_d;
wire cs_rise   =  cs_n && !cs_d;

wire [7:0] lfsr_next = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sclk_d    <= 1'b0;
        cs_d      <= 1'b1;
        lfsr      <= SEED;
        rx_shift  <= 32'd0;
        bit_cnt   <= 6'd0;
        miso      <= 1'b0;
        cap_data  <= 32'd0;
        cap_bits  <= 6'd0;
        cap_valid <= 1'b0;
    end else begin
        sclk_d <= sclk;
        cs_d   <= cs_n;

        if (cs_fall) begin
            lfsr     <= SEED;
            miso     <= SEED[7];
            rx_shift <= 32'd0;
            bit_cnt  <= 6'd0;
        end else if (!cs_n) begin
            if (sclk_rise) begin
                rx_shift <= {rx_shift[30:0], mosi};
                bit_cnt  <= bit_cnt + 6'd1;
            end
            if (sclk_fall) begin
                lfsr <= lfsr_next;
                miso <= lfsr_next[7];
            end
        end

        if (cs_rise) begin
            cap_data  <= rx_shift;
            cap_bits  <= bit_cnt;
            cap_valid <= 1'b1;
        end else if (cap_valid && cap_ack) begin
            cap_valid <= 1'b0;
        end
    end
end

endmodule
