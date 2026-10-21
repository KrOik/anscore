// ============================================================================
// la_debug_top -- board debug variant of top: identical selftest + UART
// report, with uart_tx mirrored to A11 (fx2lafw LA ch D0) plus status
// mirrors, so the report can be decoded even when the FTDI COM path is dead.
//   D0=A11 uart_tx   D1=B11 status_pass   D2=N6 status_fail   D3=D11 heartbeat
// ============================================================================
module la_debug_top (
    input  wire clk,
    output wire uart_tx,      // M11 (FTDI path, as in top)
    output wire dbg_uart,     // A11 -> LA D0
    output wire dbg_pass,     // B11 -> LA D1
    output wire dbg_fail,     // N6  -> LA D2
    output wire dbg_hb        // D11 -> LA D3 (clk/2^24 heartbeat)
);

wire tx_w, pass_w, fail_w;
reg [23:0] hb = 24'd0;

top #(.UNIT_EN(6'h3F)) u_top (
    .clk(clk),
    .uart_tx(tx_w),
    .status_pass(pass_w),
    .status_fail(fail_w)
);

assign uart_tx  = tx_w;
assign dbg_uart = tx_w;
assign dbg_pass = pass_w;
assign dbg_fail = fail_w;
assign dbg_hb   = hb[23];

always @(posedge clk) hb <= hb + 24'd1;

endmodule
