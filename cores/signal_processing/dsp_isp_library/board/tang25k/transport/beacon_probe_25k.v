// 25K dock transport differential: does the image run, is the TX pad wired, and
// is the RX pad wired -- three questions that a pure echo probe cannot separate,
// because an echo is silent whenever either direction is dead.
//
//   uart_tx <- 'B','C','N',cnt repeating, emitted by the design itself
//             (proves the 50 MHz clock, the SRAM-loaded image and pad C3)
//   uart_tx <- (received byte ^ 0xA5), preferred over the beacon
//             (proves pad B3 is driven by the host's USB debugger TXD)
//   uart_tx <- held low while pad B3 is low (passthrough window)
//             (a baud-independent loopback: if the debugger drives B3 at all,
//             the host reads back the byte it sent, framed or not)
//
// The host classifies the three streams independently, so a failure names the
// broken direction instead of "nothing came back".
module beacon_probe_25k #(parameter integer CLK_FRE = 50)(
    input wire clk, uart_rx_pin,
    output wire uart_tx, dbg_uart);
    reg [15:0] por = 0;
    always @(posedge clk) if (!por[15]) por <= por + 1'b1;
    wire rst_n = por[15];

    // Synchronous view of the async RX pad, used only for the loopback window.
    reg watch_meta = 1, watch_sync = 1;
    always @(posedge clk) begin
        watch_meta <= uart_rx_pin;
        watch_sync <= watch_meta;
    end

    wire [7:0] rx_data;
    wire rx_valid, framing_error, tx_ready;
    reg rx_pend = 0;
    reg [7:0] rx_echo = 0;
    // Same held-level rule as the 20K injection probe: acknowledge the receiver
    // only when the transmitter can take the response.
    wire rx_ack = rx_valid && (!rx_pend || tx_ready);
    uart_rx #(.CLK_FRE(CLK_FRE)) rx (.clk(clk), .rst_n(rst_n), .clk_en(1'b1),
        .rx_pin(uart_rx_pin), .rx_data(rx_data), .rx_valid(rx_valid),
        .rx_ack(rx_ack), .framing_err(framing_error));

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_pend <= 1'b0;
            rx_echo <= 8'h00;
        end else begin
            if (tx_ready) rx_pend <= 1'b0;
            if (rx_ack && !framing_error) begin
                rx_pend <= 1'b1;
                rx_echo <= rx_data ^ 8'ha5;
            end
        end
    end

    localparam [18:0] TICK_MAX = CLK_FRE * 5000;   // 5 ms per beacon symbol
    reg [18:0] tick = 0;
    reg [1:0] phase = 0;
    reg [7:0] cnt = 0;
    reg [7:0] bcn_byte = 8'h42;
    reg bcn_pend = 0;
    wire tick_done = (tick >= TICK_MAX);
    wire bcn_fire = tick_done && !bcn_pend && !rx_pend;

    always @(posedge clk) begin
        if (!rst_n) begin
            tick <= 0;
            phase <= 2'd0;
            cnt <= 8'h00;
            bcn_pend <= 1'b0;
            bcn_byte <= 8'h42;
        end else begin
            if (tx_ready && !rx_pend) bcn_pend <= 1'b0;
            if (bcn_fire) begin
                tick <= 0;
                bcn_pend <= 1'b1;
                case (phase)
                    2'd0: bcn_byte <= 8'h42;      // 'B'
                    2'd1: bcn_byte <= 8'h43;      // 'C'
                    2'd2: bcn_byte <= 8'h4e;      // 'N'
                    default: bcn_byte <= cnt;     // ramp byte
                endcase
                if (phase == 2'd3) cnt <= cnt + 1'b1;
                phase <= (phase == 2'd3) ? 2'd0 : phase + 2'd1;
            end else if (!tick_done) tick <= tick + 1'b1;
        end
    end

    wire [7:0] tx_data = rx_pend ? rx_echo : bcn_byte;
    wire tx_valid = rx_pend || bcn_pend;
    wire tx_bit;
    uart_tx #(.CLK_FRE(CLK_FRE)) tx (.clk(clk), .rst_n(rst_n),
        .tx_data(tx_data), .tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready), .tx_pin(tx_bit), .tx_busy());

    // Loopback window: a low on the RX pad is repeated on the TX pad without any
    // framing, so the debugger's own transmit direction is testable even if its
    // baud or line state never produces a valid frame here.
    assign uart_tx = watch_sync ? tx_bit : 1'b0;
    assign dbg_uart = uart_tx;
endmodule
