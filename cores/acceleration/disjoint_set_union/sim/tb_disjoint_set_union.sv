// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_disjoint_set_union;
    parameter integer NUM_NODES=64,TAG_W=8;
    localparam integer INDEX_W=(NUM_NODES<2)?1:$clog2(NUM_NODES);
    localparam integer COUNT_W=(NUM_NODES<2)?1:$clog2(NUM_NODES+1);
    reg clk=0,rst=1,s_valid=0,m_ready=0;
    reg [1:0] s_op=0;
    reg [INDEX_W-1:0] s_a=0,s_b=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_same,m_merged,m_error;
    wire [1:0] m_op;
    wire [INDEX_W-1:0] m_root;
    wire [COUNT_W-1:0] m_groups;
    wire [TAG_W-1:0] m_tag;
    disjoint_set_union #(.NUM_NODES(NUM_NODES),.TAG_W(TAG_W)) dut(.*);
    always #5 clk=~clk;
    integer fd,rc,op,a,b,root,same,merged,error,groups,commands=0,offset;
    reg [TAG_W-1:0] tag;
    reg [1023:0] vectors_path;
    task reset_core;
        integer cycles;
        begin
            @(negedge clk);rst=1;s_valid=0;m_ready=0;
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;cycles=0;
            while(!s_ready) begin
                if(m_valid) $fatal(1,"stale response after reset");
                cycles=cycles+1;
                if(cycles>NUM_NODES+5) $fatal(1,"singleton initialization timeout");
                @(negedge clk);
            end
        end
    endtask
    task send(input [1:0] command,input [INDEX_W-1:0] aa,bb,input [TAG_W-1:0] t);
        integer cycles;
        begin
            @(negedge clk);s_valid=1;s_op=command;s_a=aa;s_b=bb;s_tag=t;cycles=0;
            @(posedge clk);
            while(!s_ready) begin
                cycles=cycles+1;
                if(cycles>NUM_NODES+100) $fatal(1,"command timeout");
                @(posedge clk);
            end
            @(negedge clk);s_valid=0;s_op=~command;s_a=~aa;s_b=~bb;s_tag=~t;
        end
    endtask
    task response(input [1:0] command,input [INDEX_W-1:0] representative,
                  input bit eq,joined,bad,input integer count,input [TAG_W-1:0] t);
        integer cycles,j;
        begin
            cycles=0;
            while(!m_valid) begin
                cycles=cycles+1;
                if(cycles>NUM_NODES+100) $fatal(1,"result timeout");
                @(negedge clk);
            end
            for(j=0;j<5;j=j+1) begin
                if(!m_valid || {m_op,m_root,m_same,m_merged,m_error,m_groups,m_tag} !==
                   {command,representative,eq,joined,bad,COUNT_W'(count),t})
                    $fatal(1,"command %0d mismatch op%0d root%0d same%b merged%b err%b groups%0d tag%h expected %0d/%0d/%b/%b/%b/%0d/%h",
                        commands,m_op,m_root,m_same,m_merged,m_error,m_groups,m_tag,command,representative,eq,joined,bad,count,t);
                if(s_ready) $fatal(1,"new command accepted while holding response");
                @(negedge clk);
            end
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
            if(m_valid) $fatal(1,"duplicate response");
        end
    endtask
    initial begin
        if(!$value$plusargs("VECTORS=%s",vectors_path)) $fatal(1,"missing vectors");
        fd=$fopen(vectors_path,"r");if(!fd) $fatal(1,"cannot read vectors");
        reset_core();
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %h %d %d %d %d %d\n",op,a,b,tag,root,same,merged,error,groups);
            if(rc!=9) $fatal(1,"malformed vector");
            repeat(commands%3) @(negedge clk);
            send(2'(op),INDEX_W'(a),INDEX_W'(b),tag);
            response(2'(op),INDEX_W'(root),1'(same),1'(merged),1'(error),groups,tag);
            commands=commands+1;
        end
        $fclose(fd);
        // Elapsed-time cancellation probes can hit lookup/link/promotion or
        // a held response. They deliberately do not inspect the DUT's FSM.
        for(offset=0;offset<12;offset=offset+1) begin
            reset_core();
            send(1,0,INDEX_W'(NUM_NODES-1),0);
            repeat(offset) @(negedge clk);
            reset_core();
            send(0,INDEX_W'(NUM_NODES-1),{INDEX_W{1'b1}},1);
            response(0,INDEX_W'(NUM_NODES-1),1,0,0,NUM_NODES,1);
        end
        reset_core();send(3,0,0,0);
        repeat(NUM_NODES/2) @(negedge clk);
        reset_core();send(0,0,0,0);response(0,0,1,0,0,NUM_NODES,0);
        reset_core();send(0,0,0,0);wait(m_valid);
        repeat(3) @(negedge clk);
        reset_core();send(0,0,0,0);response(0,0,1,0,0,NUM_NODES,0);
        $display("PASS commands=%0d reset_cancellation_cases=14",commands);
        $finish;
    end
    initial begin #20000000;$fatal(1,"global timeout");end
endmodule
