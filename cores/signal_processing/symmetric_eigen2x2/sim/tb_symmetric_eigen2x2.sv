// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_symmetric_eigen2x2;
    parameter integer W=16,F=12,R=32,T=8;
    localparam integer N=W+F+1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    reg signed [W-1:0] s_a=0,s_b=0,s_d=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_psd,m_repeated;
    wire signed [R-1:0] m_min,m_max;
    wire [1:0] m_saturated;
    wire signed [W:0] m_trace;
    wire [2*W:0] m_discriminant;
    wire [T-1:0] m_tag;
    symmetric_eigen2x2 #(.W(W),.FRAC(F),.RESULT_W(R),.TAG_W(T)) dut(.*);
    integer cycles=0,accepted_cycle=0,commands=0,held_cycles=0,reset_probes=0;
    integer clipped=0,psd_count=0,repeated_count=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>1000000) $fatal(1,"bounded watchdog");
    end
    // Called on the observed phase immediately: no wait before asserting rst.
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready || m_valid) $fatal(1,"reset gating");
            repeat(2) @(negedge clk);rst=0;
            #1;if(!s_ready || m_valid) $fatal(1,"reset rearm");
            reset_probes=reset_probes+1;
        end
    endtask
    task put(input [W-1:0] a,b,d,input [T-1:0] tag,input integer gap);
        begin
            repeat(gap) @(negedge clk);
            @(negedge clk);s_valid=1;s_a=a;s_b=b;s_d=d;s_tag=tag;
            @(posedge clk);if(!s_ready) $fatal(1,"idle admission");
            #1;accepted_cycle=cycles;
            @(negedge clk);s_valid=0;s_a=~a;s_b=~b;s_d=~d;s_tag=~tag;
        end
    endtask
    task get_result(input [R-1:0] minimum,maximum,input [1:0] sat,
                    input bit psd,repeated,input [W:0] trace,
                    input [2*W:0] discriminant,input [T-1:0] tag,input integer hold);
        integer watchdog;
        begin
            watchdog=0;
            while(!m_valid) begin
                if(s_ready) $fatal(1,"admitted during arithmetic");
                @(negedge clk);watchdog=watchdog+1;
                if(watchdog>4*N+9) $fatal(1,"result timeout");
            end
            if(cycles-accepted_cycle!=4*N+6)
                $fatal(1,"latency %0d != %0d",cycles-accepted_cycle,4*N+6);
            repeat(hold+1) begin
                if(!m_valid || {m_min,m_max,m_saturated,m_psd,m_repeated,m_trace,m_discriminant,m_tag}
                    !== {minimum,maximum,sat,psd,repeated,trace,discriminant,tag})
                    $fatal(1,"command %0d got min=%0d max=%0d sat=%b psd=%b repeat=%b trace=%0d D=%h tag=%h; expected %0d %0d %b %b %b %0d %h %h",
                        commands,m_min,m_max,m_saturated,m_psd,m_repeated,m_trace,m_discriminant,m_tag,
                        $signed(minimum),$signed(maximum),sat,psd,repeated,$signed(trace),discriminant,tag);
                if(s_ready || m_min>m_max) $fatal(1,"held output ordering/admission");
                held_cycles=held_cycles+1;@(negedge clk);
            end
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
            if(m_valid || !s_ready) $fatal(1,"duplicate result or blocked idle");
            commands=commands+1;
            if(|sat)clipped=clipped+1;
            if(psd)psd_count=psd_count+1;
            if(repeated)repeated_count=repeated_count+1;
        end
    endtask
    task await_phase(input integer phase);
        integer watchdog;
        reg found;
        begin
            watchdog=0;found=0;
            while(!found) begin
                case(phase)
                    0: found=(dut.state==1 && dut.operation==0);
                    1: found=(dut.state==2 && dut.operation==0);
                    2: found=(dut.state==2 && dut.operation==1);
                    3: found=(dut.state==3);
                    4: found=(dut.state==4 && dut.sqrt_engine.state==1);
                    5: found=(dut.state==4 && dut.sqrt_valid);
                    6: found=(dut.state==2 && dut.operation==2);
                    7: found=(dut.state==5);
                    default: found=m_valid;
                endcase
                if(!found) begin
                    @(negedge clk);watchdog=watchdog+1;
                    if(watchdog>4*N+10) $fatal(1,"reset phase timeout %0d",phase);
                end
            end
        end
    endtask
    integer phase;
    initial begin
        reset_now();
        for(phase=0;phase<9;phase=phase+1) begin
            put(1,1,-1,0,0);
            if(phase==8) begin
                // Offer the next command during arithmetic and hold it until
                // reset, so the observed EMIT phase is canceled immediately.
                s_valid=1;s_a=0;s_b=0;s_d=0;s_tag=0;
            end
            await_phase(phase);
            if(s_ready) $fatal(1,"busy/reset probe admission");
            reset_now();
        end
        `include "vectors.svh"
        repeat(5) begin @(negedge clk);if(m_valid) $fatal(1,"spurious result");end
        $display("PASS eigen W=%0d F=%0d R=%0d T=%0d commands=%0d held=%0d clipped=%0d psd=%0d repeated=%0d resets=%0d",
                 W,F,R,T,commands,held_cycles,clipped,psd_count,repeated_count,reset_probes);
        $finish;
    end
endmodule
