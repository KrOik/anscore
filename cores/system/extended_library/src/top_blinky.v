// minimal sanity top: toggle uart_tx & LEDs with a counter -- no selftest deps
module top_blinky (
    input  wire clk,
    output wire uart_tx,
    output wire status_pass,
    output wire status_fail
);
    reg [24:0] cnt = 0;
    always @(posedge clk) cnt <= cnt + 25'd1;
    assign uart_tx     = cnt[22];          // ~3.2 Hz square wave
    assign status_pass = cnt[24];          // ~0.8 Hz blink
    assign status_fail = ~cnt[24];
endmodule
