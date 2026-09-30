`timescale 1ns / 1ps
// replicate sm2_ecc's reg-driven inv start pattern
module tb_inv_ctx;
reg clk = 0, rst_n = 0;
reg start, inv_start;
reg [255:0] inv_a, inv_m;
wire busy, done, err;
wire [255:0] r;
reg [255:0] z;

localparam [255:0] P256 = 256'hFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF;
localparam [255:0] Z2  = 256'h786E6D46E9ECEF38B37B9DC6D6D242A7A1530EFA8C548E7F05BE65CA4273E141;

sm2_mod_inv dut(.clk(clk), .rst_n(rst_n), .start(inv_start), .a_i(inv_a), .m_i(inv_m),
                .busy(busy), .done(done), .err(err), .r_o(r));

always #5 clk = ~clk;

// idle sm2_ecc instance (never started) to test elaboration interaction
wire e_busy,e_done,e_inf,e_err; wire [255:0] e_rx,e_ry;
sm2_ecc idle_ecc(.clk(clk),.rst_n(rst_n),.start(1'b0),.op_i(2'd0),.k_i(256'd0),
    .ax_i(256'd0),.ay_i(256'd0),.bx_i(256'd0),.by_i(256'd0),
    .busy_o(e_busy),.done_o(e_done),.inf_o(e_inf),.err_o(e_err),.rx_o(e_rx),.ry_o(e_ry));

reg [1:0] st;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin st <= 0; inv_start <= 0; inv_a <= 0; inv_m <= 0; end
    else case (st)
        0: if (start) begin inv_a <= z; inv_m <= P256; inv_start <= 1; st <= 1; end
        1: inv_start <= 0;
    endcase
end

integer invcyc = 0;
reg tracing = 0;
always @(posedge clk) begin
    if (inv_start && !tracing) begin tracing = 1; invcyc = 0; end
    if (tracing && dut.busy && invcyc < 12) begin
        $display("INV iu=%h iv=%h ix=%h iy=%h st=%0d", dut.iu, dut.iv, dut.ix, dut.iy, dut.state);
        invcyc = invcyc + 1;
    end
    if (tracing && dut.done) begin
        $display("INV DONE r=%h", dut.r_o);
        tracing = 0;
    end
end

initial begin
    start = 0; st = 0;
    repeat (6) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);
    z = Z2; start = 1;
    @(negedge clk); start = 0;
    wait (done);
    $display("r=%h want=BD6E428202E23159407B8820A55AA74912A8EDE43F77DE02F4CE5BA1B126394F", r);
    $finish;
end
endmodule
