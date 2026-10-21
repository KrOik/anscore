module ecc_only(
    input  wire       clk,
    input  wire       rst_n,
    output wire [5:0] led
);
reg  [255:0] k, ax, ay;
reg          start;
wire         busy, done, inf, err;
wire [255:0] rx, ry, rz;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        k <= 256'hDEADBEEF; ax <= 256'h1234; ay <= 256'h5678; start <= 1'b0;
    end else begin
        start <= ~busy;
        if (done) k <= rx ^ ry;
    end
end

sm2_ecc #(.JAC_ONLY(1)) U_ECC(
    .clk(clk), .rst_n(rst_n),
    .start(start), .op_i(2'd1), .k_i(k),
    .ax_i(ax), .ay_i(ay), .bx_i(k), .by_i(ax),
    .busy_o(busy), .done_o(done), .inf_o(inf), .err_o(err),
    .rx_o(rx), .ry_o(ry), .rz_o(rz)
);
assign led = ~{err, inf, done, busy, rx[1], rx[0]};
endmodule
