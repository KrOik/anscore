// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_binary_heap_queue;
    parameter integer KEY_W=16, DATA_W=32, CAPACITY=32, SIGNED_KEY=1;
    localparam integer COUNT_W=(CAPACITY<2)?1:$clog2(CAPACITY+1);
    reg clk=0, rst=1, s_valid=0, m_ready=0;
    reg [1:0] s_op=0;
    reg [KEY_W-1:0] s_key=0;
    reg [DATA_W-1:0] s_data=0;
    wire s_ready, m_valid;
    wire [1:0] m_op,m_status;
    wire [KEY_W-1:0] m_key;
    wire [DATA_W-1:0] m_data;
    wire [COUNT_W-1:0] m_count;
    binary_heap_queue #(.KEY_W(KEY_W),.DATA_W(DATA_W),.CAPACITY(CAPACITY),.SIGNED_KEY(SIGNED_KEY)) dut(.*);
    always #5 clk=~clk;
    integer fd, rc, op, status, expected_count, lines=0, i,j,delay_cycles;
    reg [KEY_W-1:0] key,expected_key;
    reg [DATA_W-1:0] data,expected_data;
    reg [1023:0] vector_path;

    task reset_queue;
        begin
            @(negedge clk); rst=1; s_valid=0; m_ready=0;
            repeat(2) @(posedge clk);
            @(negedge clk); rst=0;
            repeat(3) begin
                @(posedge clk); #1;
                if(m_valid || m_count!==0) $fatal(1,"reset did not cancel transaction");
            end
        end
    endtask

    task send_command(input [1:0] command, input [KEY_W-1:0] k, input [DATA_W-1:0] d);
        integer cycles;
        begin
            @(negedge clk); s_valid=1; s_op=command; s_key=k; s_data=d; m_ready=0;
            cycles=0;
            @(posedge clk);
            while(!s_ready) begin
                cycles=cycles+1;
                if(cycles>1000) $fatal(1,"command acceptance timeout");
                @(posedge clk);
            end
            @(negedge clk); s_valid=0; s_op=~command; s_key=~k; s_data=~d;
        end
    endtask

    task response(input [1:0] command, input [1:0] st,
                  input [KEY_W-1:0] k, input [DATA_W-1:0] d,
                  input integer occupancy, input integer stall);
        integer cycles;
        begin
            cycles=0;
            while(!m_valid) begin
                @(negedge clk);
                cycles=cycles+1;
                if(cycles>1000) $fatal(1,"response timeout");
            end
            repeat(stall+1) begin
                if({m_op,m_status,m_key,m_data,m_count} !==
                   {command,st,k,d,COUNT_W'(occupancy)})
                    $fatal(1,"line %0d response mismatch: op%0d status%0d key%h data%h count%0d expected op%0d status%0d key%h data%h count%0d",
                        lines,m_op,m_status,m_key,m_data,m_count,command,st,k,d,occupancy);
                if(s_ready) $fatal(1,"accepted another command with pending response");
                @(negedge clk);
                if(!m_valid) $fatal(1,"response disappeared while stalled");
            end
            m_ready=1;
            @(posedge clk);
            @(negedge clk); m_ready=0;
            if(m_valid) $fatal(1,"extra response");
        end
    endtask

    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing vectors");
        fd=$fopen(vector_path,"r");
        if(!fd) $fatal(1,"cannot read vectors");
        reset_queue();
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %h %h %d %h %h %d\n",op,key,data,status,expected_key,expected_data,expected_count);
            if(rc!=7) $fatal(1,"malformed test vector");
            repeat(lines%3) @(negedge clk);
            send_command(2'(op),key,data);
            response(2'(op),2'(status),expected_key,expected_data,expected_count,lines%5);
            lines=lines+1;
        end
        $fclose(fd);
        // Reset at different elapsed times during a push, a pop and a held
        // response. These tests use the public protocol, not FSM internals.
        for(i=0;i<2;i=i+1) begin
            for(delay_cycles=0;delay_cycles<13;delay_cycles=delay_cycles+1) begin
                reset_queue();
                for(j=0;j<CAPACITY-(i==0);j=j+1) begin
                    send_command(0,KEY_W'(j),DATA_W'(j));
                    response(0,0,KEY_W'(j),DATA_W'(j),j+1,0);
                end
                if(i==0) send_command(0,{KEY_W{1'b1}},{DATA_W{1'b1}});
                else send_command(1,0,0);
                repeat(delay_cycles) @(negedge clk);
                reset_queue();
                send_command(0,KEY_W'(1),DATA_W'(1));
                response(0,0,KEY_W'(1),DATA_W'(1),1,1);
                send_command(1,0,0);
                response(1,0,KEY_W'(1),DATA_W'(1),0,1);
                send_command(1,0,0);
                response(1,2,0,0,0,1);
            end
        end
        $display("PASS commands=%0d reset_cancellation_cases=26",lines);
        $finish;
    end
    initial begin #20000000; $fatal(1,"global timeout"); end
endmodule
