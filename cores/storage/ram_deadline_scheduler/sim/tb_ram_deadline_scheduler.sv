// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_deadline_scheduler;
    parameter integer N=16,K=16,TW=32,D=32,T=8;
    localparam integer CW=$clog2(N+1),R=K+TW+D;
    localparam integer INW=3+K+2*TW+D+T,OW=3+3+3+K+TW+D+T+2*CW;
    localparam [K-1:0] IDMAX={K{1'b1}};
    localparam [TW-1:0] TMAX={TW{1'b1}};
    localparam [D-1:0] DMAX={D{1'b1}};
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    reg [2:0] s_op=0;
    reg [K-1:0] s_id=0;
    reg [TW-1:0] s_deadline=0,s_cutoff=0;
    reg [D-1:0] s_data=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_found,m_replaced,m_due;
    wire [2:0] m_op,m_status;
    wire [K-1:0] m_id;
    wire [TW-1:0] m_deadline;
    wire [D-1:0] m_data;
    wire [T-1:0] m_tag;
    wire [CW-1:0] m_live,m_free;
    ram_deadline_scheduler #(.SLOTS(N),.ID_W(K),.TIME_W(TW),.DATA_W(D),.TAG_W(T)) dut(.*);
    wire [OW-1:0] payload={m_op,m_status,m_found,m_replaced,m_due,m_id,m_deadline,m_data,m_tag,m_live,m_free};
    wire [INW-1:0] source_payload={s_op,s_id,s_deadline,s_data,s_cutoff,s_tag};
    reg [INW-1:0] vectors[0:12000],vector_q,pending_source=0;
    reg [OW-1:0] held;
    reg input_pending=0,main_phase=0;
    reg [6:0] state_mask=0;
    string input_path,output_path;
    integer count,fd,i,j,p,target,guard,start_cycle,latency,expected_latency;
    integer cycles=0,blocked=0,holds=0,resets=0,recovery=0,max_latency=0;
    integer source_holds=0,main_accepts=0,latency_checks=0,reads=0,writes=0,clears=0;
    reg hit;
    always @(posedge clk)begin
        if(rst)input_pending=0;
        else begin
            cycles=cycles+1;state_mask[dut.state]=1;
            if(input_pending)begin
                if(!s_valid || source_payload!==pending_source)$fatal(1,"source hold violated");
                if(main_phase)source_holds=source_holds+1;
            end
            input_pending=s_valid && !s_ready;pending_source=source_payload;
            if(s_valid && !s_ready)blocked=blocked+1;
            if(m_valid && !m_ready)holds=holds+1;
            if(main_phase && s_valid && s_ready)main_accepts=main_accepts+1;
            if(dut.state==2)reads=reads+1;
            if(dut.state==5)writes=writes+1;
            if(dut.state==1)clears=clears+1;
        end
    end
    task wait_idle;
        integer steps;
        begin
            steps=0;
            while(!s_ready)begin
                if(m_valid)$fatal(1,"unexpected canceled completion");
                if(steps>N+3)$fatal(1,"init bound");
                @(negedge clk);steps=steps+1;
            end
        end
    endtask
    task start(input [2:0] op,input [K-1:0] id,input [TW-1:0] deadline,
        input [D-1:0] data,input [TW-1:0] cutoff,input [T-1:0] tag);
        begin
            @(negedge clk);wait_idle();s_op=op;s_id=id;s_deadline=deadline;
            s_data=data;s_cutoff=cutoff;s_tag=tag;s_valid=1;m_ready=0;
            @(posedge clk);#1;start_cycle=cycles;
            @(negedge clk);s_valid=0;
        end
    endtask
    task wait_output;
        integer steps;
        begin
            steps=0;
            while(!m_valid)begin
                if(s_ready)$fatal(1,"early admission");
                if(steps>2*N+4)$fatal(1,"response bound");
                @(negedge clk);steps=steps+1;
            end
            latency=cycles-start_cycle;
            if(m_op>4)expected_latency=0;
            else if(m_op==4)expected_latency=N;
            else expected_latency=2*N+1+((m_status==0 && (m_op==0 || m_op==1 || m_op==3))?1:0);
            if(latency!==expected_latency || latency>2*N+2)$fatal(1,"exact response latency %0d expected %0d",latency,expected_latency);
            if(main_phase)latency_checks=latency_checks+1;
            if(latency>max_latency)max_latency=latency;
        end
    endtask
    task retire;
        begin
            @(negedge clk);m_ready=1;
            @(posedge clk);#1;if(m_valid)$fatal(1,"duplicate completion");
            @(negedge clk);m_ready=0;
        end
    endtask
    task simple(input [2:0] op,input [K-1:0] id,input [TW-1:0] deadline,
        input [D-1:0] data,input [TW-1:0] cutoff,input [2:0] status,
        input found,replaced,due,input [K-1:0] rid,input [TW-1:0] rdeadline,
        input [D-1:0] rdata,input [CW-1:0] live);
        begin
            start(op,id,deadline,data,cutoff,{T{1'b1}});wait_output();
            if(m_op!==op || m_status!==status || m_found!==found || m_replaced!==replaced ||
                m_due!==due || m_id!==rid || m_deadline!==rdeadline || m_data!==rdata ||
                m_tag!=={T{1'b1}} || m_live!==live || m_free!==CW'(N-live))$fatal(1,"fresh/setup response");
            held=payload;
            repeat(2)begin
                @(posedge clk);#1;if(!m_valid || payload!==held || s_ready)$fatal(1,"helper held response");
                @(negedge clk);
            end
            retire();
        end
    endtask
    task fresh_rows(input integer expected_live);
        integer k,seen;
        begin
            seen=0;
            for(k=0;k<N;k=k+1)begin
                if(dut.rows[k][R])begin
                    seen=seen+1;
                    if(dut.rows[k][R-1:0]!=={IDMAX,TMAX,DMAX})$fatal(1,"fresh logical event image");
                end else if(dut.rows[k]!==0)$fatal(1,"fresh invalid row not clear");
            end
            if(seen!=expected_live)$fatal(1,"fresh logical map count");
        end
    endtask
    task fresh;
        begin
            simple(0,IDMAX,TMAX,DMAX,0,0,1,0,0,IDMAX,TMAX,DMAX,1);fresh_rows(1);recovery=recovery+1;
            simple(2,0,0,0,TMAX-1'b1,0,1,0,0,IDMAX,TMAX,DMAX,1);fresh_rows(1);recovery=recovery+1;
            simple(3,0,0,0,TMAX,0,1,0,1,IDMAX,TMAX,DMAX,0);fresh_rows(0);recovery=recovery+1;
            simple(2,IDMAX,TMAX,DMAX,TMAX,1,0,0,0,0,0,0,0);fresh_rows(0);recovery=recovery+1;
        end
    endtask
    task setup_one(input [TW-1:0] deadline);
        begin simple(0,0,deadline,DMAX,TMAX,0,1,0,0,0,deadline,DMAX,1);end
    endtask
    task setup_full;
        integer k;
        begin
            for(k=0;k<N;k=k+1)simple(0,K'(k),0,D'(k),TMAX,0,1,0,0,K'(k),0,D'(k),CW'(k+1));
        end
    endtask
    // Called at the low boundary that observed the target. Do not wait for
    // another edge before asserting reset, including after held-source probes.
    task cancel_now;
        integer k;
        begin
            if(clk!==0)$fatal(1,"reset observation boundary");
            rst=1;s_valid=0;m_ready=0;#1;if(s_ready || m_valid)$fatal(1,"reset gates");
            @(posedge clk);#1;
            if(dut.state!==1 || m_op!==0 || m_status!==0 || m_found!==0 || m_replaced!==0 ||
                m_due!==0 || m_id!==0 || m_deadline!==0 || m_data!==0 || m_tag!==0 || m_live!==0)
                $fatal(1,"reset cancellation fields");
            @(negedge clk);rst=0;wait_idle();
            for(k=0;k<N;k=k+1)if(dut.rows[k]!==0)$fatal(1,"reset event survived sweep");
            resets=resets+1;fresh();
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("OUTPUT=%s",output_path) ||
            !$value$plusargs("COUNT=%d",count))$fatal(1,"missing arguments");
        if(count<1 || count>12000)$fatal(1,"vector count");
        $readmemh(input_path,vectors,0,count-1);fd=$fopen(output_path,"w");if(!fd)$fatal(1,"output open");
        repeat(2)@(posedge clk);@(negedge clk);rst=0;wait_idle();
        for(p=0;p<20;p=p+1)begin
            if(p==0)target=0;
            else if(p==1 || p==2 || p==18)target=1;
            else if(p==3 || p==19)target=2;
            else if(p==4 || p==5)target=3;
            else if(p==6 || p==8 || p==10 || p==12 || p==17)target=4;
            else if(p==7 || p==9 || p==11 || p==13)target=5;
            else target=6;
            if(p==2 || p==5 || p==8 || p==9 || p==10 || p==11 || p==16)setup_one(1);
            if(p==12 || p==13)setup_one(0);
            if(p==17 || p==18)setup_full();
            if(p==1)begin rst=1;@(posedge clk);#1;@(negedge clk);rst=0;end
            else if(p==2 || p==18)start(4,IDMAX,TMAX,DMAX,TMAX,0);
            else if(p==5)start(2,IDMAX,TMAX,DMAX,TMAX,0);
            else if(p==10 || p==11)start(1,0,TMAX,0,TMAX,0);
            else if(p==12 || p==13 || p==16)start(3,IDMAX,TMAX,0,0,0);
            else if(p==8 || p==9)start(0,0,0,0,TMAX,0);
            else if(p==15)start(6,IDMAX,TMAX,DMAX,TMAX,0);
            else if(p!=0)start(0,IDMAX,TMAX,DMAX,0,0);
            guard=0;hit=0;
            while(!hit)begin
                hit=dut.state==target;
                if(p==1 || p==4 || p==18)hit=hit && dut.cursor==N/2;
                if(p==2 || p==5 || p==19)hit=hit && dut.cursor==N-1;
                if(p==3)hit=hit && dut.cursor==0;
                if(!hit)begin
                    if(guard>2*N+6)$fatal(1,"reset target %0d unreachable",p);
                    @(negedge clk);guard=guard+1;
                end
            end
            if(p==14 || p==15)begin
                s_op=2;s_id=0;s_deadline=0;s_data=0;s_cutoff=0;s_tag=0;s_valid=1;held=payload;
                repeat(3)begin
                    @(posedge clk);#1;if(s_ready || !m_valid || payload!==held)$fatal(1,"reset-canceled source ownership");
                    @(negedge clk);
                end
            end
            cancel_now();
        end
        main_phase=1;vector_q=vectors[0];
        start(vector_q[INW-1-:3],vector_q[T+TW+D+TW+:K],vector_q[T+TW+D+:TW],
            vector_q[T+TW+:D],vector_q[T+:TW],vector_q[T-1:0]);
        for(i=0;i<count;i=i+1)begin
            if(i+1<count)begin
                vector_q=vectors[i+1];{s_op,s_id,s_deadline,s_data,s_cutoff,s_tag}=vector_q;s_valid=1;
            end else begin s_valid=0;s_op=7;s_id=0;s_deadline=0;s_data=0;s_cutoff=0;s_tag=0;end
            wait_output();held=payload;
            for(j=0;j<(i%5)+1;j=j+1)begin
                @(posedge clk);#1;if(!m_valid || payload!==held || s_ready)$fatal(1,"main response hold");
                @(negedge clk);
            end
            $fwrite(fd,"%h",payload);
            for(j=0;j<N;j=j+1)$fwrite(fd," %h",dut.rows[j]);
            $fwrite(fd,"\n");retire();
            if(i+1<count)begin
                if(!s_ready || !s_valid)$fatal(1,"queued next source disappeared");
                @(posedge clk);#1;start_cycle=cycles;@(negedge clk);s_valid=0;
            end
        end
        $fclose(fd);
        if(main_accepts!=count || latency_checks!=count || source_holds==0 ||
            resets!=20 || recovery!=80 || state_mask!==7'h7f)$fatal(1,"incomplete fixed coverage");
        $display("PASS deadline commands=%0d accepted=%0d cycles=%0d blocked=%0d held=%0d source_holds=%0d resets=%0d recovery=%0d latency_checks=%0d max_latency=%0d bound=%0d reads=%0d writes=%0d clears=%0d states=%h",
            count,main_accepts,cycles,blocked,holds,source_holds,resets,recovery,latency_checks,max_latency,2*N+2,reads,writes,clears,state_mask);
        $finish;
    end
endmodule
