// SPI mode-0 byte engine for SD card access on Tang Primer 20K.
// CPOL=0/CPHA=0: MOSI changes on falling SCK edge, MISO sampled on rising edge.
// Two clock rates: slow (~400 kHz) for card init, fast (~13.5 MHz at 27 MHz clk)
// for data transfer. CS is owned by the caller.
module sd_spi_master #(
    parameter integer CLK_HZ      = 27000000,
    parameter integer SCK_SLOW_HZ = 200000,
    parameter integer SCK_FAST_HZ = 13500000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       fast,        // 1 = fast SCK, 0 = slow init SCK
    input  wire       start,       // pulse: shift one byte
    input  wire [7:0] tx_byte,
    input  wire       miso,
    output reg  [7:0] rx_byte,
    output reg        busy,
    output reg        sck,
    output reg        mosi
);

    // half-period counts; guard against zero for tiny clocks in simulation
    localparam integer SLOW_HALF = (CLK_HZ / (2*SCK_SLOW_HZ) < 1) ? 1 : CLK_HZ / (2*SCK_SLOW_HZ);
    localparam integer FAST_HALF = (CLK_HZ / (2*SCK_FAST_HZ) < 1) ? 1 : CLK_HZ / (2*SCK_FAST_HZ);

    reg [15:0] div_cnt;
    reg [3:0]  bit_cnt;
    reg [7:0]  shreg;
    reg        phase;   // 0 = low half, 1 = high half

    wire [15:0] half = fast ? FAST_HALF[15:0] : SLOW_HALF[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck     <= 1'b0;
            mosi    <= 1'b1;
            busy    <= 1'b0;
            rx_byte <= 8'd0;
            shreg   <= 8'd0;
            div_cnt <= 16'd0;
            bit_cnt <= 4'd0;
            phase   <= 1'b0;
        end else begin
            if (!busy) begin
                sck <= 1'b0;
                if (start) begin
                    busy    <= 1'b1;
                    shreg   <= tx_byte;
                    mosi    <= tx_byte[7];
                    div_cnt <= 16'd0;
                    bit_cnt <= 4'd0;
                    phase   <= 1'b0;
                    sck     <= 1'b0;
                end
            end else begin
                if (div_cnt == half - 16'd1) begin
                    div_cnt <= 16'd0;
                    if (phase == 1'b0) begin
                        // rising edge: sample MISO
                        sck   <= 1'b1;
                        phase <= 1'b1;
                        shreg <= {shreg[6:0], miso};
                    end else begin
                        // falling edge: next MOSI bit
                        sck   <= 1'b0;
                        phase <= 1'b0;
                        if (bit_cnt == 4'd7) begin
                            busy    <= 1'b0;
                            rx_byte <= shreg;
                            mosi    <= 1'b1;
                        end else begin
                            bit_cnt <= bit_cnt + 4'd1;
                            mosi    <= shreg[7];
                        end
                    end
                end else begin
                    div_cnt <= div_cnt + 16'd1;
                end
            end
        end
    end

endmodule
