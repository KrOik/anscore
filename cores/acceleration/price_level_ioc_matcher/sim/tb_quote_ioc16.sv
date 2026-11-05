// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_quote_ioc16;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,q_valid=0,qr_ready=0,i_valid=0,f_ready=0,d_ready=0,q_ask=1,i_buy=1,i_market=0;
    reg [31:0] q_price=100,q_quantity=7,i_limit=100,i_quantity=9;
    reg [7:0] q_tag=1,i_tag=2;
    wire q_ready,qr_valid,i_ready,f_valid,f_buy,d_valid;
    wire [2:0] qr_status,d_reason;
    wire [7:0] qr_tag,f_tag,d_tag;
    wire [31:0] f_price,f_quantity,f_remaining,f_index,d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels;
    quote_ioc16 dut(.*);
    initial begin
        repeat(3)@(negedge clk);rst_n=1;q_valid=1;
        do @(posedge clk);while(!q_ready);
        @(negedge clk);q_valid=0;
        wait(qr_valid);if(qr_status!=0||qr_tag!=1)$fatal(1,"quote");
        repeat(4)@(negedge clk);qr_ready=1;@(negedge clk);qr_ready=0;i_valid=1;
        do @(posedge clk);while(!i_ready);
        @(negedge clk);i_valid=0;
        wait(f_valid);if(!f_buy||f_price!=100||f_quantity!=7||f_remaining!=2||f_index!=0||f_tag!=2)$fatal(1,"fill");
        repeat(5)@(negedge clk);f_ready=1;@(negedge clk);f_ready=0;
        wait(d_valid);if(d_reason!=1||d_filled!=7||d_remaining!=2||d_fills!=1||d_bid_levels!=0||d_ask_levels!=0||d_tag!=2)$fatal(1,"done");
        repeat(4)@(negedge clk);d_ready=1;@(negedge clk);d_ready=0;
        $display("PASS quote_ioc16");$finish;
    end
    initial begin repeat(10000)@(posedge clk);$fatal(1,"watchdog");end
endmodule
