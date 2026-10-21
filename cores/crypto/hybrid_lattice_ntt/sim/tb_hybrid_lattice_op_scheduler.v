`timescale 1ns / 1ps

module tb_hybrid_lattice_op_scheduler;

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;
localparam [2:0] OP_KEM_FLOW = 3'd4;
localparam [2:0] OP_DSA_FLOW = 3'd5;
localparam [2:0] OP_HYBRID_RUN = 3'd6;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg [2:0] op_code = OP_KEM_NTT;
wire ready;
wire busy;
wire done;
wire error;
wire [2:0] active_op;
wire [31:0] digest;
wire [31:0] cycle_count;

always #5 clk = ~clk;

hybrid_lattice_op_scheduler dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .op_code(op_code),
    .ready(ready),
    .busy(busy),
    .done(done),
    .error(error),
    .active_op(active_op),
    .digest(digest),
    .cycle_count(cycle_count)
);

task automatic run_op;
    input [2:0] requested_op;
    input [31:0] expected_digest;
    input expect_error;
    integer wait_cycles;
    begin
        wait (ready);
        @(negedge clk);
        op_code = requested_op;
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        wait_cycles = 0;
        while (!done && wait_cycles < 180000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (!done) begin
            $display("tb_hybrid_lattice_op_scheduler FAIL timeout op=%0d", requested_op);
            $fatal(1);
        end
        if (active_op != requested_op) begin
            $display("tb_hybrid_lattice_op_scheduler FAIL active_op=%0d expected=%0d",
                     active_op, requested_op);
            $fatal(1);
        end
        if (error != expect_error) begin
            $display("tb_hybrid_lattice_op_scheduler FAIL error=%0d expected=%0d op=%0d",
                     error, expect_error, requested_op);
            $fatal(1);
        end
        if (!expect_error && digest != expected_digest) begin
            $display("tb_hybrid_lattice_op_scheduler FAIL digest=%08x expected=%08x op=%0d",
                     digest, expected_digest, requested_op);
            $fatal(1);
        end
        @(posedge clk);
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    run_op(OP_KEM_NTT, 32'h1e664367, 1'b0);
    run_op(OP_DSA_NTT, 32'h7fc8e2fc, 1'b0);
    run_op(OP_KEM_INTT, 32'hb88a6c64, 1'b0);
    run_op(OP_DSA_INTT, 32'hd23ecef9, 1'b0);
    run_op(OP_KEM_FLOW, 32'hedaa6354, 1'b0);
    run_op(OP_DSA_FLOW, 32'he9b06052, 1'b0);
    run_op(OP_HYBRID_RUN, 32'd0, 1'b1);

    $display("tb_hybrid_lattice_op_scheduler PASS kem_dsa_ntt_intt_flow_skeleton_and_unsupported_boundary");
    $finish;
end

initial begin
    repeat (260000) @(posedge clk);
    $display("tb_hybrid_lattice_op_scheduler FAIL global timeout");
    $fatal(1);
end

endmodule
