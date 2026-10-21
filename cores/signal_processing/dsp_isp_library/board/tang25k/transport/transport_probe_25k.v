// 25K dock transport gate: host -> B3 -> uart_rx -> XOR A5 -> uart_tx -> C3 ->
// host.  Same nonce contract as the 20K uart_injection_probe, but the dock
// oscillator is 50 MHz, so the UART dividers must be built with CLK_FRE=50.
// Passing this proves the full-duplex path every per-core 25K board run uses;
// it qualifies no algorithm.
module transport_probe_25k #(parameter integer CLK_FRE = 50)(
    input wire clk, uart_rx_pin,
    output wire uart_tx, dbg_uart);
    reg [15:0] por = 0;
    always @(posedge clk) if (!por[15]) por <= por + 1'b1;
    wire rst_n = por[15];

    wire [7:0] data;
    wire valid, framing_error, ready;
    reg pending;
    reg [7:0] response;
    reg [31:0] received = 0;

    wire ack = valid && (!pending || ready);
    uart_rx #(.CLK_FRE(CLK_FRE)) rx (.clk(clk), .rst_n(rst_n), .clk_en(1'b1),
        .rx_pin(uart_rx_pin), .rx_data(data), .rx_valid(valid),
        .rx_ack(ack), .framing_err(framing_error));

    always @(posedge clk) begin
        if (!rst_n) begin
            pending <= 0;
            response <= 0;
        end else begin
            if (ready) pending <= 0;
            if (ack) begin
                received <= received + 1;
                if (!framing_error) begin
                    pending <= 1;
                    response <= data ^ 8'ha5;
                end
            end
        end
    end

    // ready is the uart_tx idle handshake and the receiver's backpressure: it
    // must be driven here, or pending never clears and the echo free-runs.
    uart_tx #(.CLK_FRE(CLK_FRE)) tx (.clk(clk), .rst_n(rst_n),
        .tx_data(response), .tx_data_valid(pending),
        .tx_data_ready(ready), .tx_pin(uart_tx), .tx_busy());

    assign dbg_uart = uart_tx;
endmodule
