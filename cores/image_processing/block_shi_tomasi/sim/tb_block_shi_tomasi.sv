`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module tb_block_shi_tomasi;
    parameter integer G=9,M=64,F=8,R=32,T=8;
    localparam integer C=(M>0)?$clog2(M+1):1;
    localparam integer S=2*G+((M<2)?0:$clog2(M));
    localparam integer LAT=4*(S+F+1)+6;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [G-1:0] s_gx=0,s_gy=0;
    reg [R-2:0] s_threshold=0;reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_corner,m_isotropic;
    wire signed [R-1:0] m_score,m_max_score;
    wire [1:0] m_saturated,m_status;
    wire [C-1:0] m_count;wire [S:0] m_energy;wire [T-1:0] m_tag;
    block_shi_tomasi #(.GRAD_W(G),.MAX_SAMPLES(M),.FRAC(F),.SCORE_W(R),.TAG_W(T)) dut(.*);
    integer cycles=0,last_input_cycle=0,frames=0,held_cycles=0,source_stalls=0,phase_resets=0;
    integer corner_frames=0,isotropic_frames=0,overflow_frames=0,min_clipped_frames=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>3000000) $fatal(1,"bounded watchdog");
        if(!rst && dut.state==dut.EIGEN_WAIT && dut.eigen_valid &&
           (!dut.eigen_psd || dut.eigen_min<0 || dut.eigen_max<0))
            $fatal(1,"structure tensor violated PSD result domain");
    end
    task reset_now;
    begin
        rst=1;s_valid=0;m_ready=0;
        #1;if(s_ready || m_valid) $fatal(1,"reset transfer gating");
        repeat(2) @(negedge clk);rst=0;
        #1;if(!s_ready || m_valid) $fatal(1,"reset rearm");
    end endtask
    task put(input [G-1:0] gx,gy,input bit keep,last,input [R-2:0] threshold,
             input [T-1:0] tag,input integer gap);
        integer waited;
    begin
        repeat(gap) @(negedge clk);
        // Zero-gap successor offers at the previous task's return boundary.
        s_valid=1;s_gx=gx;s_gy=gy;s_keep=keep;s_last=last;s_threshold=threshold;s_tag=tag;
        waited=0;@(posedge clk);
        while(!s_ready) begin
            source_stalls=source_stalls+1;waited=waited+1;
            if(waited>4) $fatal(1,"collection stall too long");
            @(posedge clk);
        end
        #1;if(last) last_input_cycle=cycles;
        @(negedge clk);s_valid=0;s_gx=~gx;s_gy=~gy;s_keep=~keep;s_last=~last;
        s_threshold=~threshold;s_tag=~tag;
    end endtask
    task get_result(input [R-1:0] score,maximum,input [1:0] saturated,status,
                    input bit corner,isotropic,input [C-1:0] count,
                    input [S:0] energy,input [T-1:0] tag,input integer delay,hold);
        integer waited;
    begin
        waited=0;
        while(!m_valid) begin
            if(s_ready) $fatal(1,"admitted while solving");
            @(negedge clk);waited=waited+1;
            if(waited>LAT+10) $fatal(1,"result timeout");
        end
        if(cycles-last_input_cycle!=delay) $fatal(1,"latency %0d expected %0d",cycles-last_input_cycle,delay);
        repeat(hold+1) begin
            if(!m_valid || s_ready || {m_score,m_max_score,m_saturated,m_status,m_corner,m_isotropic,m_count,m_energy,m_tag}
                !== {score,maximum,saturated,status,corner,isotropic,count,energy,tag})
                $fatal(1,"frame %0d got score=%0d max=%0d sat=%b status=%0d corner=%b iso=%b count=%0d energy=%h tag=%h expected %0d %0d %b %0d %b %b %0d %h %h",
                       frames,m_score,m_max_score,m_saturated,m_status,m_corner,m_isotropic,m_count,m_energy,m_tag,
                       $signed(score),$signed(maximum),saturated,status,corner,isotropic,count,energy,tag);
            held_cycles=held_cycles+1;@(negedge clk);
        end
        m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
        if(m_valid || !s_ready) $fatal(1,"result duplicate or no rearm");
        frames=frames+1;corner_frames=corner_frames+corner;isotropic_frames=isotropic_frames+isotropic;
        overflow_frames=overflow_frames+(status==2);min_clipped_frames=min_clipped_frames+saturated[0];
    end endtask
    task await_phase(input integer phase);
        integer waited;
        reg found;
    begin
        waited=0;found=0;
        while(!found) begin
            if(phase<8) found=dut.state==phase;
            else case(phase)
                8:found=dut.state==dut.EIGEN_WAIT && dut.eigensolver.state==2;
                9:found=dut.state==dut.EIGEN_WAIT && dut.eigensolver.sqrt_engine.state==1;
                10:found=dut.state==dut.EIGEN_WAIT && dut.eigensolver.sqrt_valid;
                default:found=dut.state==dut.EIGEN_WAIT && dut.eigen_valid;
            endcase
            if(!found) begin
                @(negedge clk);waited=waited+1;
                if(waited>LAT+10) $fatal(1,"reset phase unavailable %0d",phase);
            end
        end
    end endtask
    integer phase;
    initial begin
        reset_now();
        for(phase=0;phase<12;phase=phase+1) begin
            put(1,1,1,phase!=0,0,0,0);
            if(phase==7) begin
                // The pending next block is already offered during arithmetic.
                s_valid=1;s_gx=0;s_gy=0;s_keep=1;s_last=1;s_threshold=0;s_tag=0;
            end
            await_phase(phase);
            reset_now();phase_resets=phase_resets+1;
        end
        `include "vectors.svh"
        repeat(5) begin @(negedge clk);if(m_valid) $fatal(1,"spurious score");end
        if(source_stalls==0) $fatal(1,"missing source stall coverage");
        $display("PASS ShiTomasi G=%0d M=%0d F=%0d R=%0d T=%0d frames=%0d corners=%0d isotropic=%0d overflow=%0d minclip=%0d held=%0d source_stalls=%0d resets=%0d",
                 G,M,F,R,T,frames,corner_frames,isotropic_frames,overflow_frames,min_clipped_frames,held_cycles,source_stalls,phase_resets);
        $finish;
    end
endmodule
