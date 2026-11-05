// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_deblock_edge;
    parameter integer TAG_W=8,N=1;
    reg clk=0,rst=1,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    reg [63:0] s_pixels=0;
    reg [2:0] s_bs=0;
    reg [7:0] s_alpha=0,s_beta=0;
    reg [4:0] s_tc0=0;
    reg [TAG_W-1:0] s_tag=0;
    reg s_last=0;
    wire s_ready,m_valid,m_error,m_changed,m_last;
    wire [63:0] m_pixels;
    wire [TAG_W-1:0] m_tag;
    h264_luma_deblock_edge #(.TAG_W(TAG_W)) dut(.*);
    reg [87:0] vectors[0:N-1];
    reg [65:0] golden[0:N-1];
    reg stalled=0;
    reg [TAG_W+66:0] held;
    integer cycles=0,stalls=0,checked=0,errors=0,changed=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(rst) stalled=0;
        else begin
            if(stalled && (!m_valid||{m_pixels,m_error,m_changed,m_tag,m_last}!==held))
                $fatal(1,"held output mutated");
            stalled=m_valid&&!m_ready;
            held={m_pixels,m_error,m_changed,m_tag,m_last};
            if(stalled) stalls=stalls+1;
        end
    end
    task reset_core;
        begin
            @(negedge clk);rst=1;s_valid=0;m_ready=0;
            @(posedge clk);#1;
            if(m_valid||{m_pixels,m_error,m_changed,m_tag,m_last}!==0||s_ready)
                $fatal(1,"synchronous reset failed");
            @(negedge clk);rst=0;
        end
    endtask
    task drive(input integer i);
        begin
            {s_alpha,s_beta,s_tc0,s_bs,s_pixels}=vectors[i];
            s_tag=TAG_W'(i);s_last=(i%17==16)||(i==N-1);
        end
    endtask
    task sequence(input integer continuous);
        integer sent,received,consecutive;
        reg pending,previous;
        begin
            sent=0;received=0;pending=0;previous=0;consecutive=0;
            while(received<N) begin
                @(negedge clk);
                if(!pending && sent<N && (continuous || cycles%4!=0)) begin
                    pending=1;drive(sent);
                end
                s_valid=pending;
                m_ready=continuous||(cycles%7>=3);
                @(posedge clk);
                if(s_valid&&s_ready) begin sent=sent+1;pending=0;end
                if(m_valid&&m_ready) begin
                    if({m_changed,m_error,m_pixels}!==golden[received]||m_tag!==TAG_W'(received)||
                        m_last!==((received%17==16)||(received==N-1)))
                        $fatal(1,"index%0d got %h expected %h tag%h",received,{m_changed,m_error,m_pixels},golden[received],m_tag);
                    received=received+1;checked=checked+1;
                    if(m_error) errors=errors+1;
                    if(m_changed) changed=changed+1;
                    if(previous) consecutive=consecutive+1;
                    previous=1;
                end else previous=0;
            end
            @(negedge clk);s_valid=0;m_ready=0;
            if(sent!=N) $fatal(1,"input/output accounting");
            if(continuous && consecutive!=N-1) $fatal(1,"unexpected continuous bubbles");
        end
    endtask
    initial begin
        $readmemh("vectors.hex",vectors);
        $readmemh("golden.hex",golden);
        reset_core();sequence(0);
        // Cancel a valid held result, then prove complete fresh recovery.
        @(negedge clk);drive(0);s_valid=1;m_ready=0;
        @(posedge clk);while(!s_ready) @(posedge clk);
        @(negedge clk);s_valid=0;
        repeat(3) @(posedge clk);
        if(!m_valid) $fatal(1,"reset fixture did not fill output");
        reset_core();sequence(1);
        repeat(3) @(posedge clk);
        if(m_valid||stalls==0||errors==0||changed==0) $fatal(1,"vacuous or duplicated output");
        $display("PASS TAG_W=%0d vectors=%0d checked=%0d errors=%0d changed=%0d stalls=%0d reset_pending=1",TAG_W,N,checked,errors,changed,stalls);
        $finish;
    end
    initial begin #(10000+N*300);$fatal(1,"TB geometry-independent finite deadline");end
endmodule
