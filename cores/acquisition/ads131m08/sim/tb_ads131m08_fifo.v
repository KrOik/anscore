`timescale 1ns/1ps
module tb_ads131m08_fifo;
    localparam integer WIDTH = 16;
    localparam integer DEPTH = 4;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0, wr_en = 1'b0, rd_en = 1'b0, clear = 1'b0;
    reg [WIDTH-1:0] wr_data = 0;
    wire [WIDTH-1:0] rd_data;
    wire full, empty, overflow;
    wire [15:0] level;
    wire [31:0] drop_count;
    integer errors = 0;

    ads131m08_sample_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .wr_en(wr_en), .wr_data(wr_data),
        .rd_en(rd_en), .rd_data(rd_data), .full(full), .empty(empty),
        .level(level), .drop_count(drop_count), .overflow(overflow), .clear(clear)
    );
    task push(input [WIDTH-1:0] value);
        begin @(negedge clk); wr_data=value; wr_en=1'b1; @(negedge clk); wr_en=1'b0; end
    endtask
    task pop_check(input [WIDTH-1:0] expected);
        begin
            @(negedge clk); rd_en=1'b1; @(posedge clk); #1;
            if (rd_data !== expected) begin errors=errors+1; $display("FAIL FIFO data expected=%h got=%h", expected, rd_data); end
            @(negedge clk); rd_en=1'b0;
        end
    endtask
    task pulse_clear;
        begin @(negedge clk); clear=1'b1; @(negedge clk); clear=1'b0; end
    endtask
    initial begin
        repeat (2) @(posedge clk); rst_n=1'b1;
        if (!empty || level !== 0) begin errors=errors+1; $display("FAIL FIFO reset state"); end
        push(16'h1111); push(16'h2222); push(16'h3333); push(16'h4444); #1;
        if (!full || level !== 4) begin errors=errors+1; $display("FAIL FIFO full level=%0d", level); end
        push(16'h5555); #1;
        if (!overflow || drop_count !== 1) begin errors=errors+1; $display("FAIL FIFO overflow drop=%0d", drop_count); end
        pop_check(16'h1111); pop_check(16'h2222);
        if (full || level !== 2) begin errors=errors+1; $display("FAIL FIFO post-read level=%0d", level); end
        pulse_clear(); #1;
        if (!empty || level !== 0 || overflow || drop_count !== 0) begin errors=errors+1; $display("FAIL FIFO clear state"); end
        push(16'hA55A); pop_check(16'hA55A);
        rst_n=1'b0; repeat (2) @(posedge clk); rst_n=1'b1; #1;
        if (!empty || overflow || drop_count !== 0) begin errors=errors+1; $display("FAIL FIFO post-reset state"); end
        if (errors == 0) $display("PASS tb_ads131m08_fifo: order, full, overflow, clear and reset");
        else $fatal(1, "FIFO boundary regression failed: %0d", errors);
        $finish;
    end
endmodule
