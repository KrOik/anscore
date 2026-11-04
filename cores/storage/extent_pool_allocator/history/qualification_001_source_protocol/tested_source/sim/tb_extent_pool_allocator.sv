// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_extent_pool_allocator;
    parameter integer N=64,T=8;
    localparam integer CW=$clog2(N+1),IW=(N>1)?$clog2(N):1;
    localparam integer INW=3+32+32+4+T,RW=3+3+32+32+4+T+2*CW;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid;
    reg [2:0] s_op=0;
    reg [31:0] s_length=0,s_base=0;
    reg [3:0] s_align_order=0;
    reg [T-1:0] s_tag=0;
    wire [2:0] m_op,m_status;
    wire [31:0] m_length,m_base;
    wire [3:0] m_align_order;
    wire [T-1:0] m_tag;
    wire [CW-1:0] m_free_units,m_largest_gap;
    wire [RW-1:0] response={m_op,m_status,m_length,m_base,m_align_order,m_tag,m_free_units,m_largest_gap};
    extent_pool_allocator #(.UNITS(N),.TAG_W(T)) dut(.*);
    reg [INW-1:0] vectors[0:12000];
    reg [INW-1:0] vector_q;
    reg [RW-1:0] held;
    string input_path,output_path;
    integer count,fd,i,j,p,guard,target,start_cycle,latency;
    integer cycles=0,blocked=0,held_cycles=0,resets=0,recovery=0,max_latency=0;
    integer writes=0,scan_checks=0,summary_checks=0,busy_checks=0,alignment_skips=0;
    reg [9:0] state_mask=0;
    reg hit;
    always @(posedge clk)begin
        if(!rst)begin
            cycles=cycles+1;
            if(s_valid && !s_ready)blocked=blocked+1;
            if(m_valid && !m_ready)held_cycles=held_cycles+1;
            state_mask[dut.state]=1;
            if(dut.state==4)writes=writes+1;
            if(dut.state==3)begin
                scan_checks=scan_checks+1;
                if(!dut.free_row)busy_checks=busy_checks+1;
                if(dut.free_row && dut.run_length==0 && !dut.aligned)alignment_skips=alignment_skips+1;
            end
            if(dut.state==8)summary_checks=summary_checks+1;
        end
    end
    task wait_idle;
        integer steps;
        begin
            steps=0;
            while(!s_ready)begin
                if(m_valid)$fatal(1,"unexpected canceled or extra response");
                if(steps>N+4)$fatal(1,"initialization bound");
                @(negedge clk);steps=steps+1;
            end
        end
    endtask
    task start(input [2:0] op,input [31:0] len,base,input [3:0] align_order,input [T-1:0] tag);
        begin
            @(negedge clk);wait_idle();
            s_op=op;s_length=len;s_base=base;s_align_order=align_order;s_tag=tag;s_valid=1;m_ready=0;
            @(posedge clk);#1;start_cycle=cycles;
            @(negedge clk);s_valid=0;
        end
    endtask
    task wait_output;
        integer steps;
        begin
            steps=0;
            while(!m_valid)begin
                if(s_ready)$fatal(1,"accepted command released early");
                if(steps>5*N+8)$fatal(1,"response bound");
                @(negedge clk);steps=steps+1;
            end
            latency=cycles-start_cycle;
            if(latency>5*N+8)$fatal(1,"latency exceeds fixed bound");
            if(latency>max_latency)max_latency=latency;
        end
    endtask
    task retire;
        begin
            s_valid=0;@(negedge clk);m_ready=1;
            @(posedge clk);#1;if(m_valid)$fatal(1,"duplicate response");
            @(negedge clk);m_ready=0;
        end
    endtask
    task simple(input [2:0] op,input [31:0] len,base,input [3:0] align_order,
        input [2:0] status,input [31:0] result_base,input [CW-1:0] free_units,gap);
        begin
            start(op,len,base,align_order,{T{1'b1}});wait_output();
            if(m_op!==op || m_length!==len || m_align_order!==align_order ||
                m_tag!=={T{1'b1}} || m_status!==status || m_base!==result_base ||
                m_free_units!==free_units || m_largest_gap!==gap)$fatal(1,"fresh recovery response");
            held=response;
            repeat(3)begin
                @(posedge clk);#1;
                if(!m_valid || response!==held || s_ready)$fatal(1,"fresh held stability");
                @(negedge clk);
            end
            retire();
        end
    endtask
    task fresh;
        integer k;
        begin
            simple(0,N,32'hffffffff,0,0,0,0,0);recovery=recovery+1;
            for(k=0;k<N;k=k+1)
                if(dut.rows[k]!=={1'b1,((k==0)?CW'(N):CW'(0))})$fatal(1,"fresh full allocation metadata");
            simple(2,32'hffffffff,32'hffffffff,15,0,0,0,0);recovery=recovery+1;
            simple(1,N,0,15,0,0,CW'(N),CW'(N));recovery=recovery+1;
            for(k=0;k<N;k=k+1)if(dut.rows[k]!==0)$fatal(1,"fresh release metadata");
            simple(2,0,0,0,0,0,CW'(N),CW'(N));recovery=recovery+1;
        end
    endtask
    // Caller has just observed the target at a negative edge. Assert now;
    // there is no extra active edge between observation and reset assertion.
    task cancel_now;
        integer k;
        begin
            rst=1;s_valid=0;m_ready=0;#1;
            if(m_valid || s_ready)$fatal(1,"reset immediate public gating");
            @(posedge clk);#1;
            if(dut.state!==1)$fatal(1,"reset controller");
            @(negedge clk);rst=0;wait_idle();
            for(k=0;k<N;k=k+1)if(dut.rows[k]!==0)$fatal(1,"reset ownership survived");
            resets=resets+1;fresh();
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("OUTPUT=%s",output_path) ||
            !$value$plusargs("COUNT=%d",count))$fatal(1,"missing paths/count");
        if(count<1 || count>12000)$fatal(1,"vector count");
        $readmemh(input_path,vectors,0,count-1);
        fd=$fopen(output_path,"w");if(!fd)$fatal(1,"output open");
        repeat(2)@(posedge clk);
        @(negedge clk);rst=0;wait_idle();
        for(p=0;p<16;p=p+1)begin
            if(p==0)target=0;
            else if(p==1 || p==14 || p==15)target=1;
            else if(p==2)target=2;
            else if(p==3)target=3;
            else if(p==4 || p==5 || p==6 || p==9)target=4;
            else if(p==7)target=5;
            else if(p==8)target=6;
            else if(p==10)target=7;
            else if(p==11)target=8;
            else target=9;
            if(p==1 || p==7 || p==8 || p==9 || p==14)
                simple(0,N,0,0,0,0,0,0);
            if(p==15)begin
                rst=1;@(posedge clk);#1;@(negedge clk);rst=0;
            end else if(p==1 || p==14)start(3,32'hffffffff,32'hffffffff,15,0);
            else if(p==7 || p==8 || p==9)start(1,N,0,15,0);
            else if(p==13)start(7,0,32'hffffffff,15,0);
            else if(p!=0)start(0,N,32'hffffffff,0,0);
            guard=0;hit=0;
            while(!hit)begin
                hit=dut.state==target;
                if(p==1 || p==5 || p==9 || p==15)hit=hit && dut.cursor==N/2;
                if(p==3 || p==6 || p==11 || p==14)hit=hit && dut.cursor==N-1;
                if(p==4)hit=hit && dut.cursor==0;
                if(!hit)begin
                    if(guard>5*N+12)$fatal(1,"reset target not reached probe=%0d",p);
                    @(negedge clk);guard=guard+1;
                end
            end
            cancel_now();
        end
        for(i=0;i<count;i=i+1)begin
            vector_q=vectors[i];
            start(vector_q[INW-1-:3],vector_q[T+4+32+:32],vector_q[T+4+:32],vector_q[T+:4],vector_q[T-1:0]);
            // Offer a real blocked next command; captured fields must not drift.
            s_valid=1;s_op=7;s_length=32'hffffffff;s_base=32'h80000000;
            s_align_order=15;s_tag=~vector_q[T-1:0];wait_output();held=response;
            for(j=0;j<(i%5)+1;j=j+1)begin
                @(posedge clk);#1;
                if(!m_valid || response!==held || s_ready)$fatal(1,"main held output or early next admission");
                @(negedge clk);
            end
            $fwrite(fd,"%h",response);
            for(j=0;j<N;j=j+1)$fwrite(fd," %h",dut.rows[j]);
            $fwrite(fd,"\n");retire();
        end
        $fclose(fd);
        if(state_mask!==10'h3ff || resets!=16 || recovery!=64 || blocked==0 || held_cycles==0)
            $fatal(1,"incomplete protocol/reset state coverage");
        if(N>1 && (busy_checks==0 || alignment_skips==0))$fatal(1,"missing occupied/alignment scans");
        $display("PASS extent commands=%0d cycles=%0d blocked=%0d held=%0d resets=%0d recovery=%0d max_latency=%0d bound=%0d writes=%0d scans=%0d summaries=%0d busy=%0d align_skips=%0d states=%h",
            count,cycles,blocked,held_cycles,resets,recovery,max_latency,5*N+8,
            writes,scan_checks,summary_checks,busy_checks,alignment_skips,state_mask);
        $finish;
    end
endmodule
