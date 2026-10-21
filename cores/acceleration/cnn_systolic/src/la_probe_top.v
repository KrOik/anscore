// Logic-analyzer channel-mapping probe: drives the 8 dock pins with a
// rotating one-hot slot pulse. Pin k (order: A11,B11,N6,D11,N9,N7,L9,N8)
// is high only during slot k of a repeating 8-slot cycle (~10 us/slot).
// A logic analyzer channel that pulses during slot k is wired to pin k.
module la_probe_top (
    input  wire clk,
    output wire pin_a11,
    output wire pin_b11,
    output wire pin_n6,
    output wire pin_d11,
    output wire pin_n9,
    output wire pin_n7,
    output wire pin_l9,
    output wire pin_n8
);

reg [18:0] cnt = 19'd0;
always @(posedge clk) cnt <= cnt + 19'd1;

// slot = top 3 bits; slot period = 2^16 clk = ~2.43 ms at 27 MHz
// (long enough to capture several cycles at low LA sample rates)
wire [2:0] slot = cnt[18:16];
wire [7:0] onehot = 8'b1 << slot;

assign pin_a11 = onehot[0];
assign pin_b11 = onehot[1];
assign pin_n6  = onehot[2];
assign pin_d11 = onehot[3];
assign pin_n9  = onehot[4];
assign pin_n7  = onehot[5];
assign pin_l9  = onehot[6];
assign pin_n8  = onehot[7];

endmodule
