// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_stream_linear_fit;
    parameter integer W=8,C=6,F=16,R=32,T=8;
    localparam integer A=2*W+C+1,D=2*A+1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_x=0,s_y=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_degenerate,m_overflow;
    wire signed [R-1:0] m_slope,m_intercept;
    wire [C-1:0] m_count;
    wire [1:0] m_saturated;
    wire [D-1:0] m_spread;
    wire [T-1:0] m_tag;
    stream_linear_fit #(.DATA_W(W),.COUNT_W(C),.FRAC(F),.RESULT_W(R),.TAG_W(T)) dut(.*);
    integer cycles=0,last_cycle=0,frames=0,held_cycles=0,input_stalls=0;
    integer degenerate_frames=0,overflow_frames=0,saturated_frames=0,reset_probes=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>1000000) $fatal(1,"bounded watchdog");
    end
    task reset_core;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready || m_valid) $fatal(1,"reset not gating transfers");
            repeat(2) @(negedge clk);rst=0;
            #1;if(m_valid || !s_ready) $fatal(1,"reset failed to rearm");
            reset_probes=reset_probes+1;
        end
    endtask
    task put(input [W-1:0] x,y,input bit keep,last,input [T-1:0] tag,input integer gap);
        integer watchdog;
        begin
            repeat(gap) @(negedge clk);
            @(negedge clk);s_valid=1;s_x=x;s_y=y;s_keep=keep;s_last=last;s_tag=tag;
            watchdog=0;
            @(posedge clk);
            while(!s_ready) begin
                input_stalls=input_stalls+1;watchdog=watchdog+1;
                if(watchdog>6) $fatal(1,"unexpected input stall");
                @(posedge clk);
            end
            // Sample after the clock counter's active-region update.
            if(last) begin #1;last_cycle=cycles;end
            @(negedge clk);s_valid=0;
            // Arithmetic must consume its captured pair rather than these changes.
            s_x=~x;s_y=~y;s_keep=~keep;s_last=~last;s_tag=~tag;
        end
    endtask
    task get_result(input [R-1:0] slope,intercept,input [C-1:0] n,
                    input bit degenerate,overflow,input [1:0] saturated,
                    input [D-1:0] spread,input [T-1:0] tag,
                    input integer expected_delay,hold);
        integer watchdog;
        begin
            watchdog=0;
            while(!m_valid) begin
                if(s_ready) $fatal(1,"admission while completing a frame");
                @(negedge clk);watchdog=watchdog+1;
                if(watchdog>6*(A+1)+2*(2*A+F+2)+8) $fatal(1,"result timeout");
            end
            if(cycles-last_cycle!=expected_delay)
                $fatal(1,"tail latency %0d != %0d",cycles-last_cycle,expected_delay);
            repeat(hold+1) begin
                if(!m_valid || {m_slope,m_intercept,m_count,m_degenerate,m_overflow,m_saturated,m_spread,m_tag}
                    !== {slope,intercept,n,degenerate,overflow,saturated,spread,tag})
                    $fatal(1,"frame %0d got slope=%0d intercept=%0d n=%0d deg=%b overflow=%b sat=%b spread=%0d tag=%h; expected %0d %0d %0d %b %b %b %0d %h",
                           frames,m_slope,m_intercept,m_count,m_degenerate,m_overflow,m_saturated,m_spread,m_tag,
                           $signed(slope),$signed(intercept),n,degenerate,overflow,saturated,spread,tag);
                if(s_ready) $fatal(1,"admitted a frame while output blocked");
                held_cycles=held_cycles+1;@(negedge clk);
            end
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
            if(m_valid || !s_ready) $fatal(1,"result duplicated or collector not released");
            frames=frames+1;
            if(degenerate) degenerate_frames=degenerate_frames+1;
            if(overflow) overflow_frames=overflow_frames+1;
            if(|saturated) saturated_frames=saturated_frames+1;
        end
    endtask
    initial begin
        reset_core();
        // Partial collection, both product phases, solver offer, multiplication,
        // division (when the prefix can contain two pairs), and held result.
        put(1,1,1,0,0,0);repeat(3) @(negedge clk);reset_core();
        put(1,1,1,0,0,0);if(dut.state!=1) $fatal(1,"square probe");reset_core();
        put(1,1,1,0,0,0);@(negedge clk);if(dut.state!=2) $fatal(1,"cross probe");reset_core();
        put(0,0,0,1,0,0);if(dut.state!=3) $fatal(1,"offer probe");reset_core();
        put(0,0,0,1,0,0);wait(dut.fit.state==2);@(negedge clk);reset_core();
        if(C>1) begin
            put(0,0,1,0,0,0);put(1,1,1,1,0,0);
            wait(dut.fit.state==4);@(negedge clk);reset_core();
        end
        put(0,0,0,1,0,0);wait(m_valid);@(negedge clk);
        // A blocked next command may be canceled by reset.
        s_valid=1;s_keep=1;s_last=1;s_x=1;s_y=1;
        repeat(3) begin @(negedge clk);if(s_ready) $fatal(1,"held result admission");end
        reset_core();
        `include "vectors.svh"
        repeat(5) begin @(negedge clk);if(m_valid) $fatal(1,"spurious result");end
        $display("PASS linear_fit W=%0d C=%0d F=%0d R=%0d T=%0d frames=%0d held=%0d source_stalls=%0d degenerate=%0d overflow=%0d saturated=%0d resets=%0d",
                 W,C,F,R,T,frames,held_cycles,input_stalls,degenerate_frames,overflow_frames,saturated_frames,reset_probes);
        $finish;
    end
endmodule
