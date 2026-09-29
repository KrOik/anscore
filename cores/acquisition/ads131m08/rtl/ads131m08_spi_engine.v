// ADS131M08 SPI byte engine.
//
// Protocol (TI SBAS950B, section 8.5.1): SPI mode 1 -- CPOL = 0, CPHA = 1.
// SCLK idles low, both master and slave launch data on the rising edge and
// latch it on the falling edge, and CS may only change while SCLK is low.
//
// The SCLK half period is (SCK_DIV + 1) clocks, so the duty cycle is exactly
// 50 % and
//
//     fSCLK = CLK_HZ / (2 * (SCK_DIV + 1))
//
// On the Tang Primer 25K (50 MHz) SCK_DIV = 1 gives 12.5 MHz, the fastest
// setting that still holds tw(SCH)/tw(SCL) at 40 ns -- twice the 20 ns
// datasheet minimum -- while tc(SC) lands at 80 ns against a 40 ns minimum.
// SCK_DIV = 0 is legal but yields a 2-clock period, i.e. exactly the tc(SC)
// minimum with no margin at all, so it is not used anywhere.
//
// One frame is 27 bytes: a command or NULL in word 0, then eight 24-bit words.
// Commands, register values and their responses are 16 bits MSB-aligned inside
// a 24-bit word, so the low byte of such a word is zero padding.
`timescale 1ns/1ps

module ads131m08_spi_engine #(
    // SCLK half period in clocks, minus one.  See the header note.
    parameter integer SCK_DIV = 1
) (
    input  wire         clk,
    input  wire         rst_n,

    // A one-clock request.  ``busy`` already includes ``start``, so a requester
    // may safely test ``!busy`` on the following cycle without re-triggering.
    input  wire         start,
    input  wire [4:0]   n_bytes,     // 1..27; 27 for a full 24-bit-word frame
    input  wire [215:0] tx_data,     // byte k occupies bits [8*k+7 : 8*k]

    output wire [215:0] rx_data,
    output wire         busy,
    output reg          done,        // one-clock pulse, one cycle after busy falls

    // SPI pads.  CS belongs to this engine because it is the only block that
    // knows where the frame boundaries are, and the datasheet requires CS to
    // move while SCLK is low.
    output reg          cs_n,
    output reg          sclk,
    output reg          din,
    input  wire         dout
);

    localparam [1:0] E_IDLE  = 2'd0,
                     E_SETUP = 2'd1, // CS low, SCLK still low: td(CSSC)
                     E_HI    = 2'd2, // SCLK high, DIN already launched
                     E_LO    = 2'd3; // SCLK low: DOUT is sampled here

    reg [1:0]  st;
    reg [15:0] div;
    reg [4:0]  byte_i;
    reg [2:0]  bit_i;
    reg [7:0]  tx_byte;   // byte currently being shifted out
    reg [7:0]  rx_byte;   // byte currently being shifted in

    // Sized to 32 entries so that the "next byte" index can never fall outside
    // the array even on the final byte, where its value is a don't-care.
    reg [7:0]  tx [0:31];
    reg [7:0]  rx [0:31];

    integer k;
    genvar  gi;

    wire       tick    = (div == SCK_DIV[15:0]);
    wire       last_b  = (bit_i == 3'd7);
    wire       last_by = last_b && (byte_i == n_bytes - 5'd1);

    // The bit and byte that follow the one being sampled right now.
    wire [7:0] tx_next = tx[byte_i + 5'd1];
    wire [7:0] tx_cur  = tx_byte;

    assign busy = (st != E_IDLE) | start;

    // rx_data must be a flat bus so the module stays portable Verilog-2001.
    generate
        for (gi = 0; gi < 27; gi = gi + 1) begin : g_pack
            assign rx_data[8*gi +: 8] = rx[gi];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= E_IDLE;
            div     <= 16'd0;
            byte_i  <= 5'd0;
            bit_i   <= 3'd0;
            tx_byte <= 8'd0;
            rx_byte <= 8'd0;
            cs_n    <= 1'b1;
            sclk    <= 1'b0;
            din     <= 1'b0;
            done    <= 1'b0;
            for (k = 0; k < 32; k = k + 1) begin
                tx[k] <= 8'd0;
                rx[k] <= 8'd0;
            end
        end else begin
            done <= 1'b0;

            case (st)
                E_IDLE: begin
                    cs_n <= 1'b1;
                    if (start) begin
                        for (k = 0; k < 27; k = k + 1) tx[k] <= tx_data[8*k +: 8];
                        tx_byte <= tx_data[7:0];
                        rx_byte <= 8'd0;
                        byte_i  <= 5'd0;
                        bit_i   <= 3'd0;
                        div     <= 16'd0;
                        cs_n    <= 1'b0;
                        sclk    <= 1'b0;
                        din     <= 1'b0;
                        st      <= E_SETUP;
                    end
                end

                // td(CSSC): CS must lead the first rising edge by >= 16 ns.
                // Holding here for a full half period gives 40 ns at
                // SCK_DIV = 1 and scales up with the divider.
                E_SETUP: begin
                    if (tick) begin
                        div  <= 16'd0;
                        sclk <= 1'b1;
                        din  <= tx_byte[3'd7]; // bit_i is 0 on entry
                        st   <= E_HI;
                    end else begin
                        div <= div + 16'd1;
                    end
                end

                // Falling edge: the device latches DIN here and launches DOUT.
                E_HI: begin
                    if (tick) begin
                        div  <= 16'd0;
                        sclk <= 1'b0;
                        st   <= E_LO;
                    end else begin
                        div <= div + 16'd1;
                    end
                end

                // One half period after the device launched DOUT, sample it and
                // move on.  DIN and SCLK change together on the next rising edge.
                default: begin // E_LO
                    if (tick) begin
                        div     <= 16'd0;
                        rx_byte <= {rx_byte[6:0], dout};

                        if (last_b) begin
                            rx[byte_i] <= {rx_byte[6:0], dout};
                            bit_i      <= 3'd0;

                            if (last_by) begin
                                // td(SCCS): a full half period has elapsed since
                                // the final falling edge, so CS may rise now.
                                cs_n <= 1'b1;
                                done <= 1'b1;
                                st   <= E_IDLE;
                            end else begin
                                byte_i  <= byte_i + 5'd1;
                                tx_byte <= tx_next;
                                sclk    <= 1'b1;
                                din     <= tx_next[3'd7];
                                st      <= E_HI;
                            end
                        end else begin
                            bit_i <= bit_i + 3'd1;
                            sclk  <= 1'b1;
                            din   <= tx_cur[3'd7 - (bit_i + 3'd1)];
                            st    <= E_HI;
                        end
                    end else begin
                        div <= div + 16'd1;
                    end
                end
            endcase
        end
    end

endmodule
