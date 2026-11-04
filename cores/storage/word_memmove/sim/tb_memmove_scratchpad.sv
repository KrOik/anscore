// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_memmove_scratchpad;
    reg clk=0,rst=1,s_valid=0,done_ready=0;
    always #5 clk=~clk;
    reg [31:0] s_source=0,s_destination=4;
    reg [15:0] s_words=15;
    reg [7:0] s_tag=17;
    wire s_ready,done_valid,done_backward;
    wire [1:0] done_status;
    wire [15:0] done_words;
    wire [7:0] done_tag;
    reg host_valid=0,host_write=0,host_resp_ready=0;
    reg [31:0] host_address=0,host_data=0;
    reg [3:0] host_strobe=4'hf;
    wire host_ready,host_resp_valid,host_resp_error;
    wire [31:0] host_resp_data;
    memmove_scratchpad #(.RAM_DEPTH(32)) dut(.*);
    function [31:0] original(input integer index);
        original=32'h91730005+index*113;
    endfunction
    task host(input bit write,input integer index,input [31:0] value);
        begin
            @(negedge clk);host_valid=1;host_write=write;host_address=index*4;host_data=value;
            do @(posedge clk);while(!host_ready);
            @(negedge clk);host_valid=0;
            while(!host_resp_valid) @(negedge clk);
            repeat(3) begin
                if(!host_resp_valid || host_resp_error || host_resp_data!==(write?32'd0:value))
                    $fatal(1,"host access mismatch index%0d",index);
                @(negedge clk);
            end
            host_resp_ready=1;@(posedge clk);@(negedge clk);host_resp_ready=0;
        end
    endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(i=0;i<32;i=i+1) host(1,i,original(i));
        @(negedge clk);s_valid=1;
        do @(posedge clk);while(!s_ready);
        @(negedge clk);s_valid=0;
        fork
            begin
                for(integer j=0;j<4;j=j+1) host(0,31,original(31));
            end
            begin
                wait(done_valid);
                repeat(6) begin
                    @(negedge clk);
                    if(!done_valid || {done_status,done_words,done_backward,done_tag}!=={2'd0,16'd15,1'b1,8'd17})
                        $fatal(1,"integrated completion mismatch");
                end
            end
        join
        done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;
        for(i=0;i<32;i=i+1) host(0,i,original((i>=1&&i<=15)?i-1:i));
        $display("PASS integrated_memmove overlap_words=15 host_readback_words=32 concurrent_host_reads=4");
        $finish;
    end
    initial begin #1000000;$fatal(1,"integration timeout");end
endmodule
