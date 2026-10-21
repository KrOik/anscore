// Minimal TX-pin activity probe: drives uart_tx_pin with a fast square wave.
// If the FPGA pin reaches the FTDI UART RX, the host sees a stream of garbage
// bytes (framing errors). If nothing arrives, the FPGA is not running or the
// M11->debugger path is broken.
module txprobe_top (
    input  wire clk,
    output wire uart_tx_pin,
    output wire status_pass,
    output wire status_fail
);
    reg [23:0] cnt = 24'd0;
    always @(posedge clk) cnt <= cnt + 24'd1;
    assign uart_tx_pin = cnt[6];    // ~211 kHz square wave on M11
    assign status_pass = cnt[20];   // visible blink if LEDs observable
    assign status_fail = ~cnt[20];
endmodule
