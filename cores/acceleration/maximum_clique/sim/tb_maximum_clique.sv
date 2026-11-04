// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_maximum_clique;
    parameter integer N=8,T=8,BEATS=1,FRAMES=1;
    localparam integer CW=$clog2(N+1),INW=68+T,OUTW=N+CW+2+T;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid;
    reg [31:0] s_u=0,s_v=0;
    reg s_present=0,s_keep=0,s_first=0,s_last=0;
    reg [T-1:0] s_tag=0;
    wire [N-1:0] m_vertices;
    wire [CW-1:0] m_size;
    wire [1:0] m_error;
    wire [T-1:0] m_tag;
    maximum_clique #(.NUM_NODES(N),.TAG_W(T)) dut(.*);
    reg [INW-1:0] vectors[0:49999];
    wire [INW-1:0] offered={s_u,s_v,s_present,s_keep,s_first,s_last,s_tag};
    wire [OUTW-1:0] response={m_vertices,m_size,m_error,m_tag};
    reg [INW-1:0] source_q;
    reg [OUTW-1:0] output_q;
    reg source_pending=0,output_pending=0,main_phase=0,first_seen=0,tail_edge=0;
    integer cycles=0,accepted=0,received=0,fd,td,j,p,target,guard,tail_cycle=0,latency=0;
    integer pushes=0,pops=0,total_pushes=0,total_pops=0,latency_checks=0;
    integer held=0,blocked=0,source_holds=0,resets=0,fresh_checks=0;
    integer empty_prunes=0,bound_prunes=0,max_depth=0,max_latency=0,max_pushes=0;
    reg [12:0] state_mask=0;
    string input_path,output_path,trace_path;
    always @(posedge clk)begin
        if(rst)begin source_pending=0;output_pending=0;end
        else begin
            cycles=cycles+1;state_mask[dut.state]=1;
            if(source_pending)begin
                if(!s_valid || offered!==source_q)$fatal(1,"source changed/withdrawn before handshake/reset");
                if(main_phase)source_holds=source_holds+1;
            end
            if(output_pending && (!m_valid || response!==output_q))$fatal(1,"held response changed");
            source_pending=s_valid && !s_ready;source_q=offered;
            output_pending=m_valid && !m_ready;output_q=response;
            if(main_phase)begin
                if(s_valid && !s_ready)blocked=blocked+1;
                if(m_valid && !m_ready)held=held+1;
                if(s_valid && s_ready)begin
                    accepted=accepted+1;
                    if(s_last)begin
                        tail_cycle=cycles;pushes=0;pops=0;first_seen=0;
                        tail_edge=(dut.incoming_errors==0 && s_keep && s_u!=s_v);
                    end
                end
                if(dut.state==7)begin
                    $fwrite(td,"%0d %0d %0d %h %h %h %0d\n",received,cycles,dut.depth,
                        dut.clique,dut.candidates,m_vertices,m_size);
                    if(dut.depth>max_depth)max_depth=dut.depth;
                    if(dut.candidates!=0 && dut.cardinality_bound>{1'b0,m_size})begin
                        pushes=pushes+1;total_pushes=total_pushes+1;
                    end else begin
                        if(dut.candidates==0)empty_prunes=empty_prunes+1;
                        else bound_prunes=bound_prunes+1;
                        if(dut.depth!=0)begin pops=pops+1;total_pops=total_pops+1;end
                    end
                end
                if(m_valid && m_ready)begin
                    if(!first_seen)$fatal(1,"output transferred before first-valid check");
                    $fwrite(fd,"%h %0d %0d",response,latency,pushes);
                    for(j=0;j<N;j=j+1)$fwrite(fd," %h",dut.adjacency[j]);
                    $fwrite(fd,"\n");received=received+1;
                end
            end
        end
    end
    task idle;
        integer n;
        begin
            n=0;
            while(!s_ready)begin
                if(m_valid)$fatal(1,"unexpected extra output during initialize");
                if(n>N+3)$fatal(1,"clear exceeded bound");
                @(negedge clk);n=n+1;
            end
        end
    endtask
    task beat(input [31:0] a,b,input present,keep,first,last,input [T-1:0] tag);
        begin
            @(negedge clk);idle();
            s_u=a;s_v=b;s_present=present;s_keep=keep;s_first=first;s_last=last;s_tag=tag;s_valid=1;
            @(posedge clk);#1;@(negedge clk);s_valid=0;
        end
    endtask
    task wait_result;
        integer n;
        begin
            n=0;
            while(!m_valid)begin
                if(n>6*(1<<N)+6)$fatal(1,"response exceeded exhaustive-subset bound");
                @(negedge clk);n=n+1;
            end
        end
    endtask
    task consume;
        begin
            @(negedge clk);m_ready=1;@(posedge clk);#1;
            if(m_valid)$fatal(1,"response duplicated");
            @(negedge clk);m_ready=0;idle();
        end
    endtask
    task fresh;
        integer q;
        reg [N-1:0] expected_row;
        begin
            for(q=0;q<N;q=q+1)if(dut.adjacency[q]!==0)$fatal(1,"canceled adjacency survived clear");
            if(N>1)begin
                for(q=1;q<N;q=q+1)beat(0,q,1,1,q==1,0,{T{1'b1}});
                beat(32'hffffffff,32'h80000000,0,0,0,1,0);
            end else beat(32'hffffffff,32'h80000000,0,0,1,1,{T{1'b1}});
            wait_result();
            if(m_error!==0 || m_size!==CW'((N>1)?2:1) || m_vertices!==N'((N>1)?3:1) ||
                m_tag!=={T{1'b1}})$fatal(1,"fresh complete star optimum");
            for(q=0;q<N;q=q+1)begin
                if(N==1)expected_row=0;
                else if(q==0)expected_row={N{1'b1}} & ~N'(1);
                else expected_row=N'(1);
                if(dut.adjacency[q]!==expected_row)$fatal(1,"fresh symmetric graph storage");
            end
            repeat(3)begin @(posedge clk);#1;@(negedge clk);end
            consume();fresh_checks=fresh_checks+1;
        end
    endtask
    task cancel_now;
        begin
            // Caller has observed target at this negative edge. No extra
            // active edge occurs between that observation and reset assertion.
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready || m_valid)$fatal(1,"reset public gating");
            @(posedge clk);#1;if(dut.state!==0)$fatal(1,"reset control");
            @(negedge clk);rst=0;idle();resets=resets+1;fresh();
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("OUTPUT=%s",output_path) ||
            !$value$plusargs("TRACE=%s",trace_path))$fatal(1,"missing paths");
        if(BEATS<1 || BEATS>50000 || FRAMES<1)$fatal(1,"frozen count out of range");
        $readmemh(input_path,vectors,0,BEATS-1);
        fd=$fopen(output_path,"w");td=$fopen(trace_path,"w");
        if(!fd || !td)$fatal(1,"output open");
        repeat(2)@(posedge clk);@(negedge clk);rst=0;idle();
        for(p=0;p<16;p=p+1)begin
            target=(p<2)?0:((p<4)?1:((p<8)?p-2:((p<14)?p-2:12)));
            if(p<2)begin
                rst=1;@(posedge clk);#1;@(negedge clk);rst=0;
                while(dut.cursor!=((p==0)?0:N/2))@(negedge clk);
            end else if(p==2)begin end
            else if(p==3)beat(32'hffffffff,32'hffffffff,0,0,1,0,1);
            else if(p>=4 && p<8 && N>1)beat(0,N-1,1,1,1,1,1);
            else if(p==15)beat(N,32'hffffffff,1,1,0,1,{T{1'b1}});
            else begin
                if(p>=4 && p<8)target=6; // N1 has no distinct-endpoint update.
                beat(32'hffffffff,32'hffffffff,0,0,1,1,1);
            end
            guard=0;
            while(dut.state!=target)begin
                if(guard>6*(1<<N)+N+8)$fatal(1,"reset target absent p=%0d target=%0d",p,target);
                @(negedge clk);guard=guard+1;
            end
            if(p>=14)begin
                s_u=0;s_v=0;s_present=1;s_keep=0;s_first=1;s_last=1;s_tag=0;s_valid=1;
                repeat(3)begin @(posedge clk);#1;@(negedge clk);end
            end
            cancel_now();
        end
        main_phase=1;guard=0;
        while(received<FRAMES)begin
            @(negedge clk);
            if(m_valid && !first_seen)begin
                first_seen=1;latency=cycles-tail_cycle;latency_checks=latency_checks+1;
                if(m_error!=0)begin if(latency!=1)$fatal(1,"error latency");end
                else if(latency!=2+6*pushes+4*tail_edge || pushes!=pops || latency>6*(1<<N))
                    $fatal(1,"exact search/tail bound latency=%0d push=%0d pop=%0d",latency,pushes,pops);
                if(latency>max_latency)max_latency=latency;
                if(pushes>max_pushes)max_pushes=pushes;
            end
            m_ready=(cycles%7)<4;
            if(!source_pending)begin
                if(accepted<BEATS && cycles%5!=0)begin
                    {s_u,s_v,s_present,s_keep,s_first,s_last,s_tag}=vectors[accepted];s_valid=1;
                end else s_valid=0;
            end
            guard=guard+1;
            if(guard>(BEATS+FRAMES*(6*(1<<N)+N+16))*8)$fatal(1,"finite driver watchdog");
        end
        main_phase=0;s_valid=0;m_ready=0;
        if(accepted!=BEATS || latency_checks!=FRAMES || resets!=16 || fresh_checks!=16 ||
            total_pushes!=total_pops || held==0 || blocked==0 || source_holds==0)
            $fatal(1,"incomplete finite/protocol evidence");
        if(N>1 && state_mask!==13'h1fff)$fatal(1,"missing state");
        if(N==1 && state_mask!==13'h1fc3)$fatal(1,"missing N1 state");
        $fclose(fd);$fclose(td);
        $display("PASS maximum_clique N=%0d T=%0d frames=%0d beats=%0d pushes=%0d pops=%0d latency_checks=%0d max_latency=%0d max_pushes=%0d depth=%0d held=%0d blocked=%0d source_holds=%0d resets=%0d fresh=%0d empty_prunes=%0d bound_prunes=%0d states=%h",
            N,T,FRAMES,BEATS,total_pushes,total_pops,latency_checks,max_latency,max_pushes,max_depth,
            held,blocked,source_holds,resets,fresh_checks,empty_prunes,bound_prunes,state_mask);
        $finish;
    end
endmodule
