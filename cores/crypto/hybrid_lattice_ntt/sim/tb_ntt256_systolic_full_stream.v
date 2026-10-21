`timescale 1ns / 1ps

module tb_ntt256_systolic_full_stream;

reg clk = 1'b0;
reg rst_n = 1'b0;

wire done;
wire pass;
wire fail;
wire [15:0] bubble_count;
wire [15:0] issue_count;
wire [15:0] output_count;
wire [15:0] bank_check_count;
wire [15:0] first_latency;
wire [15:0] transition_mask;
wire [15:0] fail_code;
wire [31:0] signature;

always #5 clk = ~clk;

ntt256_systolic_full_stream_selftest dut (
    .clk(clk),
    .rst_n(rst_n),
    .done(done),
    .pass(pass),
    .fail(fail),
    .bubble_count(bubble_count),
    .issue_count(issue_count),
    .output_count(output_count),
    .bank_check_count(bank_check_count),
    .first_latency(first_latency),
    .transition_mask(transition_mask),
    .fail_code(fail_code),
    .signature(signature)
);

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    wait (done);
    #1;

    if (pass && !fail) begin
        $display("tb_ntt256_systolic_full_stream PASS zero_bubbles latency=%0d issue_slots=%0d outputs=%0d bank_checks=%0d transitions=%04x digest=%08x",
                 first_latency, issue_count, output_count, bank_check_count,
                 transition_mask, signature);
        $finish;
    end else begin
        $display("tb_ntt256_systolic_full_stream FAIL pass=%0d fail=%0d code=%04x bubbles=%0d issue_slots=%0d outputs=%0d bank_checks=%0d latency=%0d transitions=%04x digest=%08x",
                 pass, fail, fail_code, bubble_count, issue_count,
                 output_count, bank_check_count, first_latency, transition_mask,
                 signature);
        $fatal(1);
    end
end

initial begin
    repeat (20000) @(posedge clk);
    $display("tb_ntt256_systolic_full_stream FAIL timeout");
    $fatal(1);
end

endmodule
