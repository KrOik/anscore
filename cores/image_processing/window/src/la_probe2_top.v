// ============================================================================
// la_probe2_top -- instrumented debug top: img_stim -> win3x3_gen at ce=clk/16
// (identical to selftest U0) with internal signals on the fx2lafw header:
//   D0=A11 uart_tx mirror   D1=B11 win_valid   D2=N6 done
//   D3=D11 pix_valid        D4=N9 new_line     D5=N7 ce
//   D6=L9 win_valid|done    D7=N8 heartbeat(clk/2^23)
// ============================================================================
module la_probe2_top (
    input  wire clk,
    output wire uart_tx,
    output wire dbg_uart,
    output wire dbg_wv,
    output wire dbg_done,
    output wire dbg_pv,
    output wire dbg_nl,
    output wire dbg_ce,
    output wire dbg_mix,
    output wire dbg_hb
);
localparam IMG_W = 16;
localparam IMG_H = 16;

reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];
always @(posedge clk) if (!rst_n) reset_count <= reset_count + 13'd1;

reg [3:0] ce_div = 4'd0;
wire ce = (ce_div == 4'd15);
always @(posedge clk) ce_div <= ce_div + 4'd1;

wire [7:0]  s_pix;
wire        s_pv, s_nl;
wire [71:0] w_win;
wire        w_v, w_nlo, w_done;

img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_stim (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl), .stim_done());
win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
    .win(w_win), .win_valid(w_v), .new_line_out(w_nlo), .done(w_done));

// uart mirror: drive uart_tx with a simple repeating pattern so the LA sees
// SOMETHING even if the selftest path misbehaves (uart_tx kept for pin compat)
assign uart_tx = 1'b1;
assign dbg_uart = w_win[0];          // LSB of tap0 -- activity probe
assign dbg_wv   = w_v;
assign dbg_done = w_done;
assign dbg_pv   = s_pv;
assign dbg_nl   = s_nl;
assign dbg_ce   = ce;
assign dbg_mix  = w_v | w_done;

reg [22:0] hb = 23'd0;
always @(posedge clk) hb <= hb + 23'd1;
assign dbg_hb = hb[22];

endmodule
