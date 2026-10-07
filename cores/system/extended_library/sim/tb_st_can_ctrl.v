`timescale 1ns/1ps
// Standalone TB for st_can_ctrl. Runs the cell under a 1-in-16 clk_en beat,
// dumps every folded byte to sim/dump_can_ctrl.txt, prints PASS/FAIL.
module tb_st_can_ctrl;

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

reg [3:0] cdiv = 4'd0;
always @(posedge clk or negedge rst_n)
    if (!rst_n) cdiv <= 4'd0;
    else        cdiv <= cdiv + 4'd1;
wire ce = (cdiv == 4'd15);

reg         start = 1'b0;
wire        done, pass;
wire [31:0] digest;
wire [15:0] cycles;

st_can_ctrl dut (
    .clk(clk), .clk_en(ce), .rst_n(rst_n), .start(start),
    .done(done), .pass(pass), .digest(digest), .cycles(cycles)
);

integer fd;
initial fd = $fopen("sim/dump_can_ctrl.txt", "w");

// dump one line per folded byte (dg_v is one clk_en beat wide)
always @(posedge clk) if (ce && dut.dg_v) $fwrite(fd, "%02x\n", dut.dg_b);

integer to;
reg xd;
initial begin
    repeat (20) @(posedge clk);
    rst_n <= 1'b1;
    repeat (40) @(posedge clk);
    start <= 1'b1;
    repeat (20) @(posedge clk);
    start <= 1'b0;
    to = 0;
    while (!done && to < 8000000) begin
        @(posedge clk);
        to = to + 1;
    end
    repeat (64) @(posedge clk);
    xd = ^digest;                       // X detector (T6)
    if (done === 1'b1 && pass === 1'b1 && (xd === 1'b0 || xd === 1'b1))
        $display("W2TB CAN PASS D=%08X C=%d", digest, cycles);
    else
        $display("W2TB CAN FAIL done=%b pass=%b D=%08X C=%d to=%d",
                 done, pass, digest, cycles, to);
    $fclose(fd);
    $finish;
end

endmodule
