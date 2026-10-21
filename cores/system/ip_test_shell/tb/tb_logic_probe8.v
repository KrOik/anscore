`timescale 1ns/1ps
module tb_logic_probe8;
    reg clk=0, rst_n=0;
    reg [2:0] page=0;
    reg [7:0] s=0, u=0, m=0, d=0;
    wire [7:0] probe;
    reg [7:0] expected, held;
    integer i;
    logic_probe8 dut(clk,rst_n,page,s,u,m,d,probe);
    always #5 clk=~clk;
    initial begin
        #1; rst_n=1; #1; rst_n=0; #1;
        if(probe!==0) $fatal(1,"asynchronous reset");
        @(negedge clk); rst_n=1;
        for(i=0;i<1024;i=i+1) begin
            page=i%8; s=$random; u=$random; m=$random; d=$random;
            case(page)
                0: expected=s;
                1: expected=u;
                2: expected=m;
                3: expected=d;
                default: expected=0;
            endcase
            held=probe;
            #1; if(probe!==held) $fatal(1,"combinational debug output");
            @(posedge clk); #1;
            if(probe!==expected) $fatal(1,"page %d expected %h got %h",page,expected,probe);
            // Signals may change between edges; physical pins must stay registered.
            s=~s; u=~u; m=~m; d=~d;
            #1; if(probe!==expected) $fatal(1,"output isolation");
            @(negedge clk);
        end
        rst_n=0; #1;
        if(probe!==0) $fatal(1,"reset did not blank probes");
        $display("PASS logic_probe8 1024 page/isolation cases");
        $finish;
    end
endmodule
