// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_minimum_cycle_mean;
    parameter integer N=8,W=8,T=8,BEATS=1,FRAMES=1;
    localparam integer CW=$clog2(N+1),DW=W+((N>1)?$clog2(N):0)+1,NW=DW+1,PW=NW+CW;
    localparam integer INW=68+W+T,OUTW=1+NW+CW+2+T,DPWORDS=(N+1)*N;
    localparam integer LIMIT=2*N*N*N+6*N*N+5*N+2*CW*(N*N-1)+1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid;
    reg [31:0] s_from=0,s_to=0;
    reg signed [W-1:0] s_weight=0;
    reg s_present=0,s_keep=0,s_first=0,s_last=0;
    reg [T-1:0] s_tag=0;
    wire m_has_cycle;
    wire signed [NW-1:0] m_numerator;
    wire [CW-1:0] m_denominator;
    wire [1:0] m_error;
    wire [T-1:0] m_tag;
    minimum_cycle_mean #(.NUM_NODES(N),.WEIGHT_W(W),.TAG_W(T)) dut(.*);
    reg [INW-1:0] vectors[0:BEATS-1];
    reg [DW:0] dp_reference[0:FRAMES*DPWORDS-1];
    reg [W:0] graph_reference[0:N*N-1];
    wire [INW-1:0] offered={s_from,s_to,s_weight,s_present,s_keep,s_first,s_last,s_tag};
    wire [OUTW-1:0] response={m_has_cycle,m_numerator,m_denominator,m_error,m_tag};
    reg [INW-1:0] source_q;
    reg [OUTW-1:0] output_q;
    reg source_pending=0,output_pending=0,main_phase=0,first_seen=0;
    reg [17:0] state_mask=0;
    integer cycles=0,accepted=0,received=0,tail_cycle=0,latency=0,fd;
    integer held=0,blocked=0,source_holds=0,resets=0,fresh_checks=0;
    integer row_checks=0,read_checks=0,edge_checks=0,ratio_products=0,multiply_steps=0;
    integer latency_checks=0,max_latency=0,p,target,guard,q,i,j,phase_target,step_target;
    integer fresh_tail,fresh_latency;
    reg signed [DW-1:0] fresh_expected;
    longint signed expected_left,expected_right,actual_num;
    string input_path,dp_path,output_path;
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
            if(dut.state==0)graph_reference[dut.cursor]=0;
            if(s_valid && s_ready && s_keep && s_from<N && s_to<N)
                graph_reference[s_from*N+s_to]={s_present,s_weight};
            if(main_phase)begin
                if(s_valid && !s_ready)blocked=blocked+1;
                if(m_valid && !m_ready)held=held+1;
                if(s_valid && s_ready)begin
                    accepted=accepted+1;
                    if(s_last)begin tail_cycle=cycles;first_seen=0;end
                end
                if(dut.state==5)begin
                    if(dut.edge_q!==graph_reference[dut.src*N+dut.dest])$fatal(1,"sync adjacency read");
                    if(dut.distance_q!==dp_reference[received*DPWORDS+(dut.level-1)*N+dut.src])
                        $fatal(1,"immutable exact-length read");
                    edge_checks=edge_checks+1;read_checks=read_checks+1;
                end
                if(dut.state==6)begin
                    if({dut.accum_valid,dut.accum_cost}!==dp_reference[received*DPWORDS+dut.level*N+dut.dest])
                        $fatal(1,"exact-length DP store frame=%0d k=%0d v=%0d",received,dut.level,dut.dest);
                    row_checks=row_checks+1;
                end
                if(dut.state==8)begin
                    if(dut.distance_q!==dp_reference[received*DPWORDS+N*N+dut.vertex])$fatal(1,"D_N ratio read");
                    read_checks=read_checks+1;
                end
                if(dut.state==10)begin
                    if(dut.distance_q!==dp_reference[received*DPWORDS+dut.k*N+dut.vertex])$fatal(1,"D_k ratio read");
                    read_checks=read_checks+1;
                end
                if(dut.state==12)begin
                    multiply_steps=multiply_steps+1;
                    if(dut.mul_step==CW-1)begin
                        expected_left=$signed(dut.candidate_num);
                        expected_left=expected_left*$signed({1'b0,dut.reference_den});
                        expected_right=$signed(dut.reference_num);
                        expected_right=expected_right*$signed({1'b0,dut.candidate_den});
                        if(!dut.mul_phase)begin
                            if(dut.mul_next!==PW'(expected_left))$fatal(1,"left cross-product");
                        end else begin
                            if(dut.left_product!==PW'(expected_left) || dut.mul_next!==PW'(expected_right))
                                $fatal(1,"right cross-product");
                        end
                        ratio_products=ratio_products+1;
                    end
                end
                if(m_valid && m_ready)begin
                    if(!first_seen)$fatal(1,"response before latency check");
                    $fwrite(fd,"%h %0d\n",response,latency);received=received+1;
                end
            end
        end
    end
    task idle;
        integer count;
        begin
            count=0;
            while(!s_ready)begin
                if(m_valid)$fatal(1,"unexpected extra response during clear");
                if(count>N*N+3)$fatal(1,"adjacency clear bound");
                @(negedge clk);count=count+1;
            end
        end
    endtask
    task beat(input [31:0] u,v,input signed [W-1:0] weight,
              input present,keep,first,last,input [T-1:0] tag);
        begin
            @(negedge clk);idle();s_from=u;s_to=v;s_weight=weight;
            s_present=present;s_keep=keep;s_first=first;s_last=last;s_tag=tag;s_valid=1;
            @(posedge clk);#1;@(negedge clk);s_valid=0;
        end
    endtask
    task ring_frame;
        integer node;
        begin
            for(node=0;node<N;node=node+1)
                beat(node,(node+1)%N,W'((node==N-1)?-1:0),1,1,node==0,node==N-1,{T{1'b1}});
        end
    endtask
    task wait_result;
        integer count;
        begin
            count=0;
            while(!m_valid)begin
                if(count>LIMIT+3)$fatal(1,"Karp response bound");
                @(negedge clk);count=count+1;
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
        integer row,node;
        reg [W:0] expected_edge;
        begin
            for(node=0;node<N*N;node=node+1)
                if(dut.adjacency[node]!==0)$fatal(1,"canceled edge survived clear");
            ring_frame();fresh_tail=cycles;wait_result();fresh_latency=cycles-fresh_tail;
            actual_num=$signed(m_numerator);
            if(m_error!==0 || !m_has_cycle || m_denominator==0 ||
               actual_num*N!=-$signed({1'b0,m_denominator}) || m_tag!=={T{1'b1}})
                $fatal(1,"complete fresh ring mean");
            if(fresh_latency!=LIMIT)$fatal(1,"fresh exact latency got=%0d expected=%0d",fresh_latency,LIMIT);
            for(row=0;row<=N;row=row+1)for(node=0;node<N;node=node+1)begin
                fresh_expected=-((row+N-1-node)/N);
                if(dut.distance[row*N+node]!=={1'b1,fresh_expected})$fatal(1,"fresh full exact-length image");
            end
            for(row=0;row<N;row=row+1)for(node=0;node<N;node=node+1)begin
                if(node==(row+1)%N)expected_edge={1'b1,W'((row==N-1)?-1:0)};
                else expected_edge=0;
                if(dut.adjacency[row*N+node]!==expected_edge)$fatal(1,"fresh directed ring image");
            end
            repeat(3)begin @(posedge clk);#1;@(negedge clk);end
            consume();fresh_checks=fresh_checks+1;
        end
    endtask
    task cancel_now;
        begin
            // Target was observed at this negative edge. Assert reset now;
            // no additional active clock may execute the observed phase.
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready || m_valid)$fatal(1,"reset public gating");
            @(posedge clk);#1;
            if(dut.state!==0 || m_numerator!==0 || m_denominator!==0 || m_has_cycle!==0 || m_error!==0 || m_tag!==0)
                $fatal(1,"reset control/public fields");
            @(negedge clk);rst=0;idle();resets=resets+1;fresh();
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("DP=%s",dp_path) ||
           !$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"missing frozen fixture path");
        if(BEATS<1 || FRAMES<1)$fatal(1,"empty finite matrix");
        $readmemh(input_path,vectors,0,BEATS-1);
        $readmemh(dp_path,dp_reference,0,FRAMES*DPWORDS-1);
        fd=$fopen(output_path,"w");if(!fd)$fatal(1,"output open");
        repeat(2)@(posedge clk);@(negedge clk);rst=0;idle();
        for(p=0;p<28;p=p+1)begin
            target=0;phase_target=-1;step_target=-1;
            if(p<2)begin
                rst=1;@(posedge clk);#1;@(negedge clk);rst=0;
                while(dut.cursor!=((p==0)?0:(N*N)/2))@(negedge clk);
            end else if(p==2)target=1;
            else if(p==3)begin beat(32'hffffffff,32'hffffffff,0,0,0,1,0,1);target=1;end
            else if(p==18 || p==20)begin beat(N,32'hffffffff,-1,1,1,0,1,1);target=(p==18)?16:17;end
            else if(p==21)begin beat(32'hffffffff,32'hffffffff,0,0,0,1,1,1);target=17;end
            else begin
                ring_frame();
                if(p<=17)target=p-2;
                else if(p==19)target=17;
                else if(p<=25)begin target=12;phase_target=(p>=24);step_target=(p%2)?CW-1:0;end
                else if(p==26)target=6;
                else target=5;
                if(N==1 && target==12)begin target=15;phase_target=-1;step_target=-1;end
            end
            guard=0;
            while(dut.state!=target ||
                  (phase_target>=0 && (dut.mul_phase!=phase_target || dut.mul_step!=step_target)) ||
                  (p==26 && (dut.level!=(N+1)/2 || dut.dest!=N/2)) ||
                  (p==27 && (dut.level!=N || dut.src!=N-1 || dut.dest!=N-1)))begin
                if(guard>LIMIT+N*N+8)$fatal(1,"reset target absent p=%0d state=%0d",p,target);
                @(negedge clk);guard=guard+1;
            end
            if(p>=19 && p<=21)begin
                s_from=0;s_to=0;s_weight=-1;s_present=1;s_keep=1;s_first=1;s_last=1;s_tag=0;s_valid=1;
                repeat(3)begin @(posedge clk);#1;@(negedge clk);end
            end
            cancel_now();
        end
        main_phase=1;guard=0;
        while(received<FRAMES)begin
            @(negedge clk);
            if(m_valid && !first_seen)begin
                first_seen=1;latency=cycles-tail_cycle;latency_checks=latency_checks+1;
                if((m_error!=0 && latency!=1) || (m_error==0 && latency>LIMIT))$fatal(1,"first-valid bound");
                if(latency>max_latency)max_latency=latency;
            end
            m_ready=(cycles%7)<4;
            if(!source_pending)begin
                if(accepted<BEATS && cycles%5!=0)begin
                    {s_from,s_to,s_weight,s_present,s_keep,s_first,s_last,s_tag}=vectors[accepted];s_valid=1;
                end else s_valid=0;
            end
            guard=guard+1;
            if(guard>(BEATS+FRAMES*(LIMIT+N*N+16))*8)$fatal(1,"finite driver watchdog");
        end
        main_phase=0;s_valid=0;m_ready=0;
        if(accepted!=BEATS || latency_checks!=FRAMES || resets!=28 || fresh_checks!=28 ||
           held==0 || blocked==0 || source_holds==0)$fatal(1,"incomplete finite/protocol evidence");
        if(N>1 && state_mask!==18'h3ffff)$fatal(1,"missing state");
        if(N==1 && state_mask!==(18'h3ffff ^ (18'b1<<12)))$fatal(1,"missing N1 state");
        if(multiply_steps!=ratio_products*CW)$fatal(1,"multiplier step count");
        $fclose(fd);
        $display("PASS minimum_cycle_mean N=%0d W=%0d T=%0d frames=%0d beats=%0d latency_checks=%0d max_latency=%0d held=%0d blocked=%0d source_holds=%0d resets=%0d fresh=%0d row_checks=%0d read_checks=%0d edge_checks=%0d ratio_products=%0d multiply_steps=%0d states=%h",
            N,W,T,FRAMES,BEATS,latency_checks,max_latency,held,blocked,source_holds,resets,fresh_checks,
            row_checks,read_checks,edge_checks,ratio_products,multiply_steps,state_mask);
        $finish;
    end
endmodule
