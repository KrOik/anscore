`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module tb_segment_box_clip;
    parameter integer W=12,T=8;
    localparam integer NW=2*W+5,MW=W+2;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    reg signed [W-1:0] s_x0=0,s_y0=0,s_x1=0,s_y1=0;
    reg signed [W-1:0] s_xmin=0,s_ymin=0,s_xmax=0,s_ymax=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_visible,m_point,m_error;
    wire signed [NW-1:0] m_x0_num,m_y0_num,m_x1_num,m_y1_num;
    wire [W:0] m_den0,m_den1;
    wire [1:0] m_clipped;wire [T-1:0] m_tag;
    segment_box_clip #(.W(W),.TAG_W(T)) dut(.*);
    integer cycles=0,accepted_cycle=0,commands=0,held_cycles=0,reset_cases=0;
    integer visible_cases=0,point_cases=0,error_cases=0,phase;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>3000000) $fatal(1,"bounded test watchdog");
    end
    task reset_now;
    begin
        rst=1;s_valid=0;m_ready=0;
        #1;if(s_ready || m_valid) $fatal(1,"reset gating");
        repeat(2) @(negedge clk);rst=0;
        #1;if(!s_ready || m_valid) $fatal(1,"reset rearm");
    end endtask
    task put(input [W-1:0] x0,y0,x1,y1,xmin,ymin,xmax,ymax,
             input [T-1:0] tag,input integer gap);
    begin
        repeat(gap) @(negedge clk);
        @(negedge clk);s_valid=1;
        s_x0=x0;s_y0=y0;s_x1=x1;s_y1=y1;
        s_xmin=xmin;s_ymin=ymin;s_xmax=xmax;s_ymax=ymax;s_tag=tag;
        @(posedge clk);if(!s_ready) $fatal(1,"unexpected admission stall");
        #1;accepted_cycle=cycles;
        @(negedge clk);s_valid=0;
        s_x0=~x0;s_y0=~y0;s_x1=~x1;s_y1=~y1;
        s_xmin=~xmin;s_ymin=~ymin;s_xmax=~xmax;s_ymax=~ymax;s_tag=~tag;
    end endtask
    task check_ratio(input signed [NW-1:0] actual,expected,
                     input [W:0] actual_den,expected_den);
        reg signed [2*NW-1:0] left,right;
    begin
        if(actual_den==0 || actual_den>{1'b0,{W{1'b1}}}) $fatal(1,"invalid output denominator");
        left=actual*$signed({1'b0,expected_den});
        right=expected*$signed({1'b0,actual_den});
        if(left!==right) $fatal(1,"command %0d ratio got %0d/%0d expected %0d/%0d",commands,actual,actual_den,expected,expected_den);
    end endtask
    task get_result(input signed [NW-1:0] x0,y0,x1,y1,
                    input [W:0] den0,den1,input bit visible,point,error,
                    input [1:0] clipped,input [T-1:0] tag,input integer hold);
        integer waited;
        reg [4*NW+2*(W+1)+T+4:0] held_payload;
    begin
        waited=0;
        while(!m_valid) begin
            if(s_ready) $fatal(1,"admission during arithmetic");
            @(negedge clk);waited=waited+1;
            if(waited>26*MW+44) $fatal(1,"result timeout");
        end
        if(cycles-accepted_cycle>26*MW+40) $fatal(1,"latency exceeds bound");
        if(error && cycles-accepted_cycle!=1) $fatal(1,"invalid-box latency");
        held_payload={m_x0_num,m_y0_num,m_x1_num,m_y1_num,m_den0,m_den1,m_visible,m_point,m_error,m_clipped,m_tag};
        repeat(hold+1) begin
            if(!m_valid || s_ready || {m_visible,m_point,m_error,m_clipped,m_tag}!=={visible,point,error,clipped,tag})
                $fatal(1,"command %0d status mismatch visible=%b point=%b error=%b clipped=%b tag=%h",commands,m_visible,m_point,m_error,m_clipped,m_tag);
            if(held_payload!=={m_x0_num,m_y0_num,m_x1_num,m_y1_num,m_den0,m_den1,m_visible,m_point,m_error,m_clipped,m_tag})
                $fatal(1,"held output payload changed");
            check_ratio(m_x0_num,x0,m_den0,den0);check_ratio(m_y0_num,y0,m_den0,den0);
            check_ratio(m_x1_num,x1,m_den1,den1);check_ratio(m_y1_num,y1,m_den1,den1);
            if(!visible && (m_den0!=1 || m_den1!=1 || m_x0_num!=0 || m_y0_num!=0 || m_x1_num!=0 || m_y1_num!=0))
                $fatal(1,"rejection payload not canonical zero");
            held_cycles=held_cycles+1;@(negedge clk);
        end
        m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
        if(m_valid || !s_ready) $fatal(1,"result did not retire");
        commands=commands+1;visible_cases=visible_cases+visible;point_cases=point_cases+point;error_cases=error_cases+error;
    end endtask
    task await_phase(input integer target);
        integer waited;
        reg found;
    begin
        found=0;waited=0;
        while(!found) begin
            case(target)
                0:found=dut.state==dut.CHECK_BOX;
                1:found=dut.state==dut.EDGE_SETUP;
                2:found=dut.state==dut.CANDIDATE;
                3:found=dut.state==dut.MULTIPLY && dut.resume==dut.LO_PRODUCT;
                4:found=dut.state==dut.LO_COMPARE;
                5:found=dut.state==dut.HI_COMPARE;
                6:found=dut.state==dut.FINAL_DONE;
                7:found=dut.state==dut.COORD_SECOND;
                default:found=m_valid;
            endcase
            if(!found) begin
                @(negedge clk);waited=waited+1;
                if(waited>26*MW+44) $fatal(1,"phase reset timeout %0d",target);
            end
        end
    end endtask
    initial begin
        reset_now();
        for(phase=0;phase<9;phase=phase+1) begin
            put(-1,-1,1,1,0,0,1,1,0,0);
            if(phase==8) begin
                // Pending next input is blocked throughout the active command.
                s_valid=1;s_x0=0;s_y0=0;s_x1=0;s_y1=0;
            end
            await_phase(phase);
            if(s_ready) $fatal(1,"busy phase admitted a new command");
            // Immediate reset at the boundary that observed the target state.
            reset_now();reset_cases=reset_cases+1;
        end
        `include "vectors.svh"
        repeat(5) begin @(negedge clk);if(m_valid) $fatal(1,"spurious result");end
        $display("PASS clip W=%0d T=%0d commands=%0d visible=%0d points=%0d errors=%0d held=%0d phase_resets=%0d",
                 W,T,commands,visible_cases,point_cases,error_cases,held_cycles,reset_cases);
        $finish;
    end
endmodule
