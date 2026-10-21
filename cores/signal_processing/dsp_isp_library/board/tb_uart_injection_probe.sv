`timescale 1ns/1ps
module tb_uart_injection_probe;
    reg clk=0;always #5 clk=~clk;
    reg rx=1;
    wire tx,dbg;
    uart_injection_probe dut(clk,rx,tx,dbg);
    integer sent=0,received=0,j;
    reg [7:0] word;
    function [7:0] payload(input integer n);
        payload=(n*73)^8'h3c;
    endfunction
    task put(input [7:0] data,input good_stop);
        integer b;
        begin
            @(negedge clk);rx=0;repeat(234) @(negedge clk);
            for(b=0;b<8;b=b+1) begin rx=data[b];repeat(234) @(negedge clk);end
            rx=good_stop;repeat(234) @(negedge clk);rx=1;
            repeat(700) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5000) @(negedge clk);
        for(sent=0;sent<32;sent=sent+1) put(payload(sent),1);
        repeat(5000) @(negedge clk);
        if(received!=32) $fatal(1,"wrong echo count %0d",received);
        put(8'h55,0);
        repeat(5000) @(negedge clk);
        if(received!=32) $fatal(1,"bad stop accepted");
        $display("PASS external UART probe simulation 32 bytes and framing rejection");
        $finish;
    end
    initial forever begin
        @(negedge tx);
        repeat(351) @(negedge clk);
        for(j=0;j<8;j=j+1) begin word[j]=tx;repeat(234) @(negedge clk);end
        if(tx!==1 || dbg!==tx) $fatal(1,"TX stop/mirror");
        if(word!==(payload(received)^8'ha5) || received>=32)
            $fatal(1,"echo mismatch at %0d: %h",received,word);
        received=received+1;
    end
    initial begin #3000000;$fatal(1,"timeout");end
endmodule
