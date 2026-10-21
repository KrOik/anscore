`timescale 1ns/1ps
module tb_mul64x16_byte;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, ce=1, start=0;
    reg [63:0] a=0;
    reg [15:0] b=0;
    wire busy,done;
    wire [63:0] product;
    img_dh_iter_mul64x16_byte dut(clk,rst_n,ce,start,a,b,busy,done,product);
    integer cases=0, pauses=0, busy_starts=0;
    integer i,j;
    reg [63:0] av[0:7];
    reg [15:0] bv[0:7];
    reg [63:0] rng=64'h71c0ffeea591d023;
    function [63:0] next_rng;
        input [63:0] value;
        reg [63:0] x;
        begin x=value^(value<<13);x=x^(x>>7);next_rng=x^(x<<17);end
    endfunction
    task run_case;
        input [63:0] aa;
        input [15:0] bb;
        reg [79:0] full_reference;
        reg [63:0] expected,previous_product;
        reg previous_done,previous_busy;
        integer elapsed,enabled;
        begin
            full_reference={16'd0,aa}*{64'd0,bb};
            expected=full_reference[63:0];
            @(negedge clk);ce=1;start=1;a=aa;b=bb;
            @(posedge clk);#1;
            if(!busy || done) $fatal(1,"start not accepted");
            elapsed=0;enabled=0;
            while(!done && elapsed<300) begin
                previous_product=product;previous_done=done;previous_busy=busy;
                @(negedge clk);
                ce=(elapsed%7!=2 && elapsed%7!=3);
                start=(elapsed%11==3);
                a=~aa^elapsed;b=~bb^elapsed;
                if(ce && start) busy_starts=busy_starts+1;
                @(posedge clk);#1;
                if(ce) enabled=enabled+1;
                else begin
                    pauses=pauses+1;
                    if({busy,done,product} !== {previous_busy,previous_done,previous_product})
                        $fatal(1,"CE pause changed output");
                end
                if(!done && !busy) $fatal(1,"early busy clear");
                elapsed=elapsed+1;
            end
            if(!done || busy || enabled!=144 || product!==expected)
                $fatal(1,"multiply a=%h b=%h got=%h expected=%h enabled=%0d",aa,bb,product,expected,enabled);
            repeat(3) begin
                @(negedge clk);ce=0;start=1;a=~a;b=~b;
                @(posedge clk);#1;
                if(!done || busy || product!==expected) $fatal(1,"done did not hold on CE pause");
            end
            @(negedge clk);ce=1;start=0;
            @(posedge clk);#1;
            if(done || busy || product!==expected) $fatal(1,"idle result hold failed");
            cases=cases+1;
        end
    endtask
    initial begin
        av[0]=0;av[1]=1;av[2]=64'hffffffffffffffff;av[3]=64'h8000000000000000;
        av[4]=64'h7fffffffffffffff;av[5]=64'h0101010101010101;
        av[6]=64'h00ff00ff00ff00ff;av[7]=64'hfedcba9876543210;
        bv[0]=0;bv[1]=1;bv[2]=2;bv[3]=255;bv[4]=256;bv[5]=32767;bv[6]=32768;bv[7]=65535;
        repeat(3) @(negedge clk);rst_n=1;
        for(i=0;i<8;i=i+1) for(j=0;j<8;j=j+1) run_case(av[i],bv[j]);
        for(i=0;i<256;i=i+1) begin
            rng=next_rng(rng);a=rng;
            rng=next_rng(rng);run_case(a,rng[15:0]);
        end
        // Cancel a real in-flight operation, then prove a fresh operation works.
        @(negedge clk);ce=1;start=1;a=-1;b=65535;
        @(negedge clk);start=0;
        repeat(19) @(negedge clk);
        rst_n=0;#1;
        if(busy || done || product!==0) $fatal(1,"mid-operation reset failed");
        @(negedge clk);rst_n=1;
        run_case(64'h8000000000000001,16'hffff);
        $display("MUL64X16_BYTE_TEST PASS cases=%0d latency_ce=144 pauses=%0d busy_starts=%0d reset=PASS",cases,pauses,busy_starts);
        $finish;
    end
    initial begin #10000000;$fatal(1,"global timeout");end
endmodule
