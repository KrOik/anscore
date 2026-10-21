module chain256(
    input  wire        clk,
    input  wire        rst_n,
    output wire [5:0]  led
);
reg  [255:0] a, b, c, d, e, f, g, h;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        a <= 256'h1; b <= 256'h2; c <= 256'h3; d <= 256'h4;
        e <= 256'h5; f <= 256'h6; g <= 256'h7; h <= 256'h8;
    end else begin
        a <= a + b;      // 8 independent 256-bit adds = 8 x ~64-ALU chains
        b <= b + c;
        c <= c + d;
        d <= d + e;
        e <= e + f;
        f <= f + g;
        g <= g + h;
        h <= h + a[255:0];
    end
end
assign led = ~a[5:0] ^ h[5:0];
endmodule
