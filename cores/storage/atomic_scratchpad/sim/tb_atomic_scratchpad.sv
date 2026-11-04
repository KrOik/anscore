// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_atomic_scratchpad;
    parameter DATA_W=32,DEPTH=16,TAG_W=8;
    localparam ADDR_W=(DEPTH<2)?1:$clog2(DEPTH);
    reg clk=0,rst=1,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    reg [3:0] s_op=0;
    reg [ADDR_W-1:0] s_address=0;
    reg [DATA_W-1:0] s_operand=0,s_compare=0;
    reg [TAG_W-1:0] s_tag=0;
    wire initializing,s_ready,m_valid,m_wrote;
    wire [DATA_W-1:0] m_old;
    wire [1:0] m_status;
    wire [TAG_W-1:0] m_tag;
    atomic_scratchpad #(.DATA_W(DATA_W),.DEPTH(DEPTH),.TAG_W(TAG_W)) dut(.*);
    integer fd,rc,op,address,wrote,status,lines=0,phase,delay_cycles,j;
    reg [DATA_W-1:0] operand,compare_value,expected_old;
    reg [TAG_W-1:0] tag;
    reg [1023:0] vector_path;

    task reset_core;
        begin
            @(negedge clk);rst=1;s_valid=0;m_ready=0;
            repeat(2) @(negedge clk);rst=0;
            for(integer k=0;k<DEPTH;k=k+1) begin
                if(!initializing || s_ready || m_valid) $fatal(1,"initialization admission");
                @(posedge clk);#1;
                if(k<DEPTH-1 && (!initializing || s_ready)) $fatal(1,"short clear sweep");
                if(k==DEPTH-1 && (initializing || !s_ready)) $fatal(1,"long clear sweep");
                @(negedge clk);
            end
        end
    endtask
    task request(input [3:0] opcode,input [ADDR_W-1:0] addr,
                 input [DATA_W-1:0] arg,cmp,input [TAG_W-1:0] req_tag);
        integer timeout;
        begin
            @(negedge clk);s_valid=1;s_op=opcode;s_address=addr;
            s_operand=arg;s_compare=cmp;s_tag=req_tag;m_ready=0;timeout=0;
            @(posedge clk);
            while(!s_ready) begin
                timeout=timeout+1;
                if(timeout>DEPTH+30) $fatal(1,"request timeout");
                @(posedge clk);
            end
            @(negedge clk);s_valid=0;s_op=~opcode;s_address=~addr;
            s_operand=~arg;s_compare=~cmp;s_tag=~req_tag;
        end
    endtask
    task response(input [DATA_W-1:0] old,input bit did_write,
                  input [1:0] code,input [TAG_W-1:0] response_tag,input integer stall);
        integer timeout;
        begin
            timeout=0;
            while(!m_valid) begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>10) $fatal(1,"response timeout");
            end
            repeat(stall+1) begin
                if(!m_valid || {m_old,m_wrote,m_status,m_tag}!=={old,did_write,code,response_tag})
                    $fatal(1,"line%0d got old%h wrote%b code%0d tag%h expected %h/%b/%0d/%h",
                           lines,m_old,m_wrote,m_status,m_tag,old,did_write,code,response_tag);
                if(s_ready || initializing) $fatal(1,"interleaved transaction");
                @(negedge clk);
            end
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
            if(m_valid) $fatal(1,"extra response");
        end
    endtask

    initial begin
        // Interrupt a partial zeroing sweep, then require the complete sweep.
        if(DEPTH>1) begin
            repeat(2) @(negedge clk);rst=0;
            repeat(DEPTH/2) @(negedge clk);
        end
        reset_core();
        for(delay_cycles=0;delay_cycles<5;delay_cycles=delay_cycles+1) begin
            request(1,0,{DATA_W{1'b1}},0,0);
            response(0,1,0,0,0);
            request(2,0,1,0,1);
            repeat(delay_cycles) @(negedge clk);
            reset_core();
            request(0,0,0,0,0);response(0,0,0,0,1);
        end
        // Every deterministic vector file starts from a fresh all-zero bank.
        reset_core();
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing vectors");
        fd=$fopen(vector_path,"r");if(!fd) $fatal(1,"cannot read vectors");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %h %h %h %h %d %d\n",
                       op,address,operand,compare_value,tag,expected_old,wrote,status);
            if(rc!=8) $fatal(1,"malformed vector");
            repeat(lines%3) @(negedge clk);
            request(4'(op),ADDR_W'(address),operand,compare_value,tag);
            response(expected_old,1'(wrote),2'(status),tag,lines%5);
            lines=lines+1;
        end
        $fclose(fd);
        $display("PASS commands=%0d reset_cases=5 full_clear_words=%0d",lines,DEPTH);
        $finish;
    end
    initial begin #5000000;$fatal(1,"global timeout");end
endmodule
