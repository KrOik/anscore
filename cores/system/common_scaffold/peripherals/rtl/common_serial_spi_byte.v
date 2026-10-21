`default_nettype none
// Physical-clock MSB-first shifter; clk_en retained for interface compatibility.
module common_serial_spi_byte (
    input wire clk, rst_n, clk_en, start, input wire [7:0] tx_data,
    input wire [31:0] half_period, input wire cpol, cpha,
    output reg busy, done, output reg [7:0] rx_data,
    output reg sclk, mosi, input wire miso
);
    reg [31:0] timer, divider;
    reg [7:0] tx_latch, rx_shift;
    reg [2:0] bit_index;
    reg polarity, phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy<=0; done<=0; rx_data<=0; sclk<=0; mosi<=1;
            timer<=0; divider<=1; tx_latch<=0; rx_shift<=0;
            bit_index<=0; polarity<=0; phase<=0;
        end else begin
            done<=0;
            if (!busy) begin
                sclk<=cpol;
                if (start) begin
                    busy<=1; polarity<=cpol; phase<=cpha;
                    divider<=(half_period==0)?1:half_period;
                    timer<=(half_period==0)?0:half_period-1;
                    tx_latch<=tx_data; rx_shift<=0; bit_index<=0;
                    mosi<=tx_data[7]; sclk<=cpol;
                end
            end else if (timer!=0) timer<=timer-1;
            else begin
                timer<=divider-1;
                if (sclk==polarity) begin
                    sclk<=~polarity;
                    if (phase) mosi<=tx_latch[7-bit_index];
                    else rx_shift[7-bit_index]<=miso;
                end else begin
                    sclk<=polarity;
                    if (phase) rx_shift[7-bit_index]<=miso;
                    if (bit_index==7) begin
                        busy<=0; done<=1;
                        rx_data<=phase?{rx_shift[7:1],miso}:rx_shift;
                    end else begin
                        bit_index<=bit_index+1;
                        if (!phase) mosi<=tx_latch[6-bit_index];
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire

