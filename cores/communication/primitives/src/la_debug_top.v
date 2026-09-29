// la_debug_top.v -- board debug variant: wraps production top.v and mirrors
// the UART TX line + status + heartbeat + per-unit done mask to the fx2lafw
// LA header pins so the COMM5 report can be captured even when the FTDI
// COM24 host path is broken.
//   D0=A11 uart_tx   D1=B11 heartbeat   D2=N6 status_pass   D3=D11 status_fail
//   D4=N9 done[0]    D5=N7 done[1]      D6=L9 done[2]       D7=N8 done[3]
//   (done[4]=FIFO is implied by status_pass = all_done && all_pass)
module la_debug_top (
    input  wire clk,
    output wire dbg_uart,
    output wire dbg_hb,
    output wire dbg_pass,
    output wire dbg_fail,
    output wire dbg_d0,
    output wire dbg_d1,
    output wire dbg_d2,
    output wire dbg_d3,
    output wire uart_tx
);

wire tx_pin, sp, sf;
wire [3:0] dmask;

top #(.UNIT_EN(16'h001F)) u_top (
    .clk(clk),
    .uart_tx_pin(tx_pin),
    .status_pass(sp),
    .status_fail(sf),
    .dbg_done_mask(dmask)
);

assign uart_tx  = tx_pin;    // still drives M11 -> BL702 UART path
assign dbg_uart = tx_pin;    // A11 = LA D0
assign dbg_pass = sp;        // N6  = LA D2
assign dbg_fail = sf;        // D11 = LA D3
assign dbg_d0   = dmask[0];  // N9  = LA D4
assign dbg_d1   = dmask[1];  // N7  = LA D5
assign dbg_d2   = dmask[2];  // L9  = LA D6
assign dbg_d3   = dmask[3];  // N8  = LA D7

reg [24:0] hb = 25'd0;
always @(posedge clk) hb <= hb + 25'd1;
assign dbg_hb = hb[24];      // B11 = LA D1, ~0.62 Hz liveness

endmodule
