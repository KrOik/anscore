// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_fragment_store;
    parameter integer W=7,H=5,TAG_W=8,CASES=1,FRAGS=1,PROTOCOL=1;
    localparam integer N=W*H;
    reg clk=0,rst=1,begin_valid=0,s_valid=0,end_valid=0,m_ready=0,done_ready=0;
    always #5 clk=~clk;
    reg [23:0] begin_rgb=0,s_rgb=0;
    reg [15:0] begin_depth=0,s_x=0,s_y=0,s_depth=0;
    reg [TAG_W-1:0] begin_tag=0;
    reg [7:0] s_alpha=0;
    reg [1:0] s_depth_func=0;
    reg s_depth_write=0;reg [2:0] s_color_write=0;
    wire begin_ready,s_ready,end_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_count_overflow;
    wire [23:0] m_rgb;wire [15:0] m_depth;wire [7:0] m_x,m_y;
    wire [TAG_W-1:0] m_tag,done_tag;
    wire [31:0] done_seen,done_passed,done_oob;
    fragment_rgb_depth_store #(.WIDTH(W),.HEIGHT(H),.TAG_W(TAG_W)) dut(.*);
    reg [39:0] clears[0:CASES-1],golden[0:N*CASES-1];
    reg [85:0] fragments[0:FRAGS-1];reg [15:0] sizes[0:CASES-1];
    reg [95:0] stats[0:CASES-1];
    integer cycles=0,checked=0,completions=0,stalls=0,resets=0;
    reg held=0,held_done=0;
    reg [TAG_W+58:0] snapshot;
    reg [TAG_W+96:0] done_snapshot;
    wire [TAG_W+58:0] bundle={m_tag,m_depth,m_rgb,m_x,m_y,m_sof,m_eol,m_last};
    wire [TAG_W+96:0] dbundle={done_tag,done_seen,done_passed,done_oob,done_count_overflow};
    always @(posedge clk) begin
        cycles=cycles+1;
        if(rst) begin held=0;held_done=0;end
        else begin
            if(held&&(!m_valid||bundle!==snapshot)) $fatal(1,"held raster changed");
            if(held_done&&(!done_valid||dbundle!==done_snapshot)) $fatal(1,"held DONE changed");
            held=m_valid&&!m_ready;held_done=done_valid&&!done_ready;
            snapshot=bundle;done_snapshot=dbundle;if(held)stalls=stalls+1;
        end
    end
    task reset_here;
        begin
            rst=1;begin_valid=0;s_valid=0;end_valid=0;m_ready=0;done_ready=0;
            @(posedge clk);#1;if(m_valid||done_valid||begin_ready||s_ready||end_ready||done_seen) $fatal(1,"reset failed");
            @(negedge clk);rst=0;resets=resets+1;
        end
    endtask
    task begin_frame(input integer k);
        begin
            @(negedge clk);begin_valid=1;{begin_depth,begin_rgb}=clears[k];begin_tag=TAG_W'(k+1);
            @(posedge clk);while(!begin_ready) @(posedge clk);
            @(negedge clk);begin_valid=0;begin_rgb=0;begin_depth=0;begin_tag=0;
        end
    endtask
    task one_fragment(input [85:0] value);
        begin
            @(negedge clk);{s_color_write,s_depth_write,s_depth_func,s_alpha,s_rgb,s_depth,s_y,s_x}=value;s_valid=1;
            @(posedge clk);while(!s_ready) @(posedge clk);
            @(negedge clk);s_valid=0;s_rgb=~s_rgb;s_alpha=~s_alpha;s_depth=~s_depth;
        end
    endtask
    task end_frame;
        begin
            @(negedge clk);end_valid=1;s_valid=1;
            @(posedge clk);while(!end_ready) @(posedge clk);
            if(s_ready) $fatal(1,"END failed to exclude fragment");
            @(negedge clk);end_valid=0;s_valid=0;
        end
    endtask
    task render(input integer k,input integer offset,input integer reset_done);
        integer i,j;
        begin
            begin_frame(k);
            for(i=0;i<sizes[k];i=i+1) one_fragment(fragments[offset+i]);
            end_frame();i=0;
            while(i<N) begin
                @(negedge clk);m_ready=(cycles%7>1);begin_valid=1;
                @(posedge clk);
                if(begin_ready||s_ready||end_ready||done_valid) $fatal(1,"raster ownership");
                if(m_valid&&m_ready) begin
                    if({m_depth,m_rgb}!==golden[k*N+i]||m_x!==8'(i%W)||m_y!==8'(i/W)||
                       m_sof!==(i==0)||m_eol!==(i%W==W-1)||m_last!==(i==N-1)||m_tag!==TAG_W'(k+1))
                        $fatal(1,"raster k%0d pixel%0d got%h expected%h",k,i,{m_depth,m_rgb},golden[k*N+i]);
                    i=i+1;checked=checked+1;
                end
            end
            @(negedge clk);m_ready=0;begin_valid=0;
            @(posedge clk);while(!done_valid) @(posedge clk);
            if({done_seen,done_passed,done_oob}!==stats[k]||done_count_overflow||done_tag!==TAG_W'(k+1))
                $fatal(1,"DONE stats k%0d seen%0d pass%0d oob%0d",k,done_seen,done_passed,done_oob);
            repeat(3)begin @(posedge clk);if(!done_valid||m_valid||begin_ready||s_ready||end_ready)$fatal(1,"DONE ownership");end
            if(reset_done)begin @(negedge clk);reset_here();end
            else begin @(negedge clk);done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;completions=completions+1;end
        end
    endtask
    task cancel_at(input integer target);
        integer budget;
        reg [85:0] value;
        begin
            begin_frame(0);
            if(target>=2)begin while(dut.state!=2)@(negedge clk);end
            if(target>=3&&target<=5)begin
                value=0;value[71:48]=24'habcdef;value[79:72]=255;value[82]=1;value[85:83]=7;
                one_fragment(value);
            end
            if(target>=6)end_frame();
            budget=0;
            while(dut.state!=target)begin @(negedge clk);budget=budget+1;if(budget>N+10)$fatal(1,"missed reset target%0d",target);end
            reset_here();render(0,0,0);
        end
    endtask
    integer k,offset,phase;
    initial begin
        $readmemh("clears.hex",clears);$readmemh("fragments.hex",fragments);$readmemh("sizes.hex",sizes);
        $readmemh("golden.hex",golden);$readmemh("stats.hex",stats);
        @(negedge clk);reset_here();offset=0;
        for(k=0;k<CASES;k=k+1)begin render(k,offset,0);offset=offset+sizes[k];end
        if(PROTOCOL)begin
            for(phase=1;phase<=7;phase=phase+1)cancel_at(phase);
            render(0,0,1);render(0,0,0);
        end
        if(stalls==0||checked!=N*(CASES+(PROTOCOL?9:0))||completions!=CASES+(PROTOCOL?8:0))$fatal(1,"coverage counters");
        $display("PASS STORE W=%0d H=%0d TAG=%0d cases=%0d checked=%0d completions=%0d resets=%0d stalls=%0d",W,H,TAG_W,CASES,checked,completions,resets,stalls);$finish;
    end
    initial begin #(1000000+N*(CASES+12)*100);$fatal(1,"finite TB deadline");end
endmodule
