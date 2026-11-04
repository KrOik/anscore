// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_cache_scratchpad;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,c_valid=0,r_ready=0;
    wire c_ready,r_valid,r_hit;
    reg [1:0] c_op=0;
    reg [31:0] c_address=0,c_data=0;
    reg [3:0] c_strobe=0;
    reg [7:0] c_tag=0;
    wire [31:0] r_data,reads,writes,errors;
    wire [1:0] r_status;
    wire [7:0] r_tag;
    cache_scratchpad #(.RAM_DEPTH(128),.LINES(2),.LINE_WORDS(4)) dut(
        .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),
        .c_address(c_address),.c_data(c_data),.c_strobe(c_strobe),.c_tag(c_tag),
        .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_status(r_status),.r_hit(r_hit),.r_tag(r_tag),
        .backend_reads(reads),.backend_writes(writes),.backend_errors(errors)
    );
    integer cycles=0;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if (cycles>5000) $fatal(1,"integration timeout");
    end
    task automatic transact(input [1:0] op,input [31:0] address,input [31:0] value,input [3:0] mask,
                            input [31:0] expected_data,input [1:0] status,input hit);
        begin
            @(negedge clk);c_valid=1;c_op=op;c_address=address;c_data=value;c_strobe=mask;c_tag=c_tag+1;
            @(posedge clk);while (!c_ready) @(posedge clk);
            @(negedge clk);c_valid=0;
            while (!r_valid) @(negedge clk);
            if ({r_data,r_status,r_hit,r_tag}!=={expected_data,status,hit,c_tag}) $fatal(1,"integration response mismatch");
            repeat (4) @(negedge clk);
            r_ready=1;@(negedge clk);r_ready=0;
        end
    endtask
    integer i;
    initial begin
        // Testbench initialization only; the production BRAM has no reset fill.
        for (i=0;i<128;i=i+1) dut.memory.mem[i]=32'h11000000+i;
        repeat (2) @(negedge clk);rst=0;
        transact(0,0,0,0,32'h11000000,0,0);
        transact(0,4,0,0,32'h11000001,0,1);
        if (reads!=4 || writes!=0) $fatal(1,"line fill/hit count mismatch");
        transact(1,4,32'hdeadbeef,4'b0101,0,0,1);
        transact(0,4,0,0,32'h11ad00ef,0,1);
        if (dut.memory.mem[1]!==32'h11000001 || writes!=0) $fatal(1,"write was not retained dirty");
        transact(0,32,0,0,32'h11000008,0,0);
        if (reads!=8 || writes!=4 || dut.memory.mem[1]!==32'h11ad00ef) $fatal(1,"eviction mismatch");
        transact(1,20,32'h88776655,15,0,0,0);
        transact(2,3,0,0,0,0,0);
        if (writes!=8 || dut.memory.mem[5]!==32'h88776655) $fatal(1,"flush mismatch");
        transact(0,20,0,0,32'h88776655,0,0);
        transact(0,512,0,0,0,3,0);
        if (errors!=1) $fatal(1,"backend error not propagated");
        $display("PASS integrated_cache byte_merge=1 dirty_evictions=1 flushes=1 backend_errors=1");
        $finish;
    end
endmodule
