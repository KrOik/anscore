`timescale 1ns/1ps
module tb_uartrx;
    reg clk = 0, rst_n = 0;
    reg [7:0] din = 0; reg dv = 0;
    wire tx, rdy, busy;
    always #18.5 clk = ~clk;
    uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) u (
        .clk(clk), .rst_n(rst_n), .tx_data(din), .tx_data_valid(dv),
        .tx_data_ready(rdy), .tx_pin(tx), .tx_busy(busy));

    // decoder
    localparam integer BIT = 234;
    integer bitcnt = 0; integer nrx = 0;
    reg [9:0] sh = 10'h3FF;
    reg bsy = 0;
    reg [7:0] got [0:15];
    always @(posedge clk) begin
        if (!bsy && tx === 1'b0) begin bsy <= 1; bitcnt <= 0; end
        else if (bsy) begin
            bitcnt <= bitcnt + 1;
            if ((bitcnt % BIT) == BIT/2) sh <= {tx, sh[9:1]};
            if (bitcnt == 10*BIT - BIT/2 + 1) begin
                bsy <= 0; got[nrx] <= sh[8:1]; nrx <= nrx + 1;
            end
        end
    end
    initial begin
        rst_n = 0; repeat(100) @(posedge clk); rst_n = 1; repeat(10) @(posedge clk);
        din = 8'hA5; dv = 1; @(posedge clk); dv = 0;
        wait(busy); wait(!busy);
        din = 8'h3C; dv = 1; @(posedge clk); dv = 0;
        repeat (20000) @(posedge clk);
        $display("nrx=%0d got0=%02x got1=%02x", nrx, got[0], got[1]);
        $finish;
    end
endmodule
