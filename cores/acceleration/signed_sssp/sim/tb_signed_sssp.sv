// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_signed_sssp;
    parameter integer N=8,W=8,T=8;
    localparam integer I=(N>1)?$clog2(N):1,C=$clog2(N+1),D=W+((N>1)?$clog2(N):0)+1,
        INW=100+W+T,OW=2*I+D+9+T;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_present=0,s_keep=0,s_first=0,s_last=0,m_ready=0;
    reg [31:0] s_from=0,s_to=0,s_source=0;
    reg signed [W-1:0] s_weight=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_reachable,m_negative_infinite,m_has_negative_cycle,m_keep,m_first,m_last;
    wire [I-1:0] m_vertex,m_source;
    wire signed [D-1:0] m_distance;
    wire [T-1:0] m_tag;wire [2:0] m_errors;
    signed_sssp #(.NUM_NODES(N),.WEIGHT_W(W),.TAG_W(T)) dut(.*);
    wire [OW-1:0] payload={m_vertex,m_source,m_distance,m_reachable,m_negative_infinite,
        m_has_negative_cycle,m_keep,m_first,m_last,m_tag,m_errors};
    reg [INW-1:0] tokens[0:100000];
    reg [OW-1:0] held_payload;
    reg held=0;
    integer phase=0,cycles=0,inputs=0,outputs=0,frames=0,closed=0;
    integer relaxations=0,propagations=0,main_cycles=0,held_cycles=0,blocked=0;
    integer pass_count=0,prop_count=0,tail_edge=0,latency,max_latency=0,latency_checks=0;
    integer resets=0,fresh_checks=0,fresh_rank=0,fresh_done=0;
    integer total_tokens,total_frames,outfile,summary_file,meta_file,i,st,recorded_first=0;
    reg [1023:0] input_path,output_path,summary_path,meta_path;
    always @(negedge clk)if(phase==2)m_ready=((cycles%17)>4 && (cycles%61)>8);
    always @(posedge clk)begin
        cycles=cycles+1;
        if(cycles>8000000)$fatal(1,"finite watchdog");
        if(rst)held=0;
        else begin
            if(held && (!m_valid || payload!==held_payload))$fatal(1,"held payload changed");
            held=m_valid && !m_ready;held_payload=payload;
            if(m_valid && m_errors==0 && m_negative_infinite && !m_reachable)$fatal(1,"unreachable negative infinity");
            if(dut.state==6 && dut.edge_q[W] && dut.distance_q[D])begin
                if(dut.candidate[D]!==dut.candidate[D-1])$fatal(1,"signed candidate narrowing overflow");
            end
            if(phase==2)begin
                main_cycles=main_cycles+1;
                if(s_valid && !s_ready)blocked=blocked+1;
                if(m_valid && !m_ready)held_cycles=held_cycles+1;
                if(s_valid && s_ready)begin
                    inputs=inputs+1;
                    if(s_last)begin
                        closed=closed+1;tail_edge=cycles;pass_count=0;prop_count=0;recorded_first=0;
                    end
                end
                if(dut.state==6)relaxations=relaxations+1;
                if(dut.state==10)propagations=propagations+1;
                if(dut.state==8)pass_count=pass_count+1;
                if(dut.state==11)prop_count=prop_count+1;
                if(m_valid && !recorded_first)begin
                    if(frames>=closed)$fatal(1,"result before tail");
                    latency=cycles-tail_edge-1;
                    if(m_errors!=0)begin
                        if(latency!=1 || pass_count!=0 || prop_count!=0)$fatal(1,"error tail");
                    end else begin
                        if(pass_count<1 || pass_count>N || prop_count>N-1)$fatal(1,"pass limits");
                        if(latency!=N+pass_count*(N*(2*N+3)+1)+prop_count*(2*N*N+1)+2)
                            $fatal(1,"exact first-valid tail %0d K%0d P%0d",latency,pass_count,prop_count);
                    end
                    $fdisplay(meta_file,"%0d %0d %0d",pass_count,prop_count,latency);
                    recorded_first=1;latency_checks=latency_checks+1;
                    if(latency>max_latency)max_latency=latency;
                end
                if(m_valid && m_ready)begin
                    $fdisplay(outfile,"%h",payload);outputs=outputs+1;
                    if(m_last)frames=frames+1;
                end
            end
            if(phase==1 && m_valid && m_ready)begin
                if(m_errors!==0 || !m_keep || m_vertex!=fresh_rank || m_source!=N-1 ||
                    m_distance!==0 || m_reachable!=(fresh_rank==N-1) || m_negative_infinite!==0 ||
                    m_has_negative_cycle!==0 || m_first!=(fresh_rank==0) || m_last!=(fresh_rank==N-1) || m_tag!=1)
                    $fatal(1,"complete fresh recovery vertex%0d",fresh_rank);
                fresh_rank=fresh_rank+1;if(m_last)fresh_done=1;
            end
        end
    end
    task reset_now;
        begin
            if(clk!==1'b0)$fatal(1,"reset target must be observed on low boundary");
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready || m_valid)$fatal(1,"reset gates");
            @(posedge clk);#1;
            if(dut.state!=0 || m_vertex!==0 || m_source!==0 || m_distance!==0 ||
               m_reachable!==0 || m_negative_infinite!==0 || m_has_negative_cycle!==0 ||
               m_keep!==0 || m_first!==0 || m_last!==0 || m_tag!==0 || m_errors!==0)
                $fatal(1,"reset public cancellation");
            @(negedge clk);rst=0;resets=resets+1;
        end
    endtask
    task offer(input integer fromv,tov,src,weight,present,keep,first,last,tagv);
        begin
            @(negedge clk);s_from=fromv;s_to=tov;s_source=src;s_weight=weight;
            s_present=present;s_keep=keep;s_first=first;s_last=last;s_tag=tagv;s_valid=1;
            begin: accepted
                forever begin @(posedge clk);if(s_ready)disable accepted;end
            end
            @(negedge clk);s_valid=0;
        end
    endtask
    task recovery;
        begin
            phase=1;fresh_rank=0;fresh_done=0;m_ready=1;
            offer(-1,-1,N-1,-1,1,0,1,1,1);
            wait(fresh_done);@(negedge clk);
            if(fresh_rank!=N)$fatal(1,"missing fresh vertices");
            phase=0;m_ready=0;fresh_checks=fresh_checks+1;
        end
    endtask
    task seed_graph;
        integer j;
        begin
            if(N==1)offer(0,0,0,-1,1,1,1,1,1);
            else begin
                for(j=0;j<N-1;j=j+1)offer(j,j+1,0,0,1,1,j==0,0,1);
                offer(N-1,N-1,0,-1,1,1,0,0,1);
                offer(N-1,0,0,0,1,1,0,1,1);
            end
        end
    endtask
    task probe(input integer target,mode);
        begin
            phase=0;m_ready=0;
            if(target==0)begin
                if(dut.state!=0)$fatal(1,"clear target boundary");
            end else begin
                fork: stop_seed
                    begin
                        if(target==15)offer(-1,-1,N,0,0,0,1,1,1);else seed_graph();
                        forever @(negedge clk);
                    end
                    begin
                        begin: seek
                            forever begin
                                @(negedge clk);
                                if(dut.state==target && (mode==0 ||
                                    (mode==1 && dut.pass==N && dut.node_v>=N/2) ||
                                    (mode==2 && dut.edge_q[W] && dut.negative[dut.node_u] && !dut.negative[dut.node_v])))disable seek;
                            end
                        end
                    end
                join_any
                disable stop_seed;
            end
            reset_now();recovery();
        end
    endtask
    task held_probe(input integer bad);
        begin
            phase=0;m_ready=0;
            fork: held_seed
                begin
                    if(bad)offer(-1,-1,N,0,0,0,1,1,1);else seed_graph();
                    forever @(negedge clk);
                end
                begin
                    wait(m_valid);@(negedge clk);s_valid=1;s_from=0;s_to=0;s_source=0;
                    s_weight=0;s_present=0;s_keep=0;s_first=1;s_last=1;s_tag=0;
                    repeat(3)begin @(negedge clk);if(s_ready || !m_valid)$fatal(1,"blocked held owner");end
                end
            join_any
            disable held_seed;
            reset_now();recovery();
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("OUTPUT=%s",output_path) ||
           !$value$plusargs("SUMMARY=%s",summary_path) || !$value$plusargs("META=%s",meta_path) ||
           !$value$plusargs("TOKENS=%d",total_tokens) || !$value$plusargs("FRAMES=%d",total_frames))$fatal(1,"missing arguments");
        $readmemh(input_path,tokens,0,total_tokens-1);outfile=$fopen(output_path,"w");meta_file=$fopen(meta_path,"w");
        reset_now();recovery();
        for(st=0;st<16;st=st+1)if(!(N==1 && st>=9 && st<=11))probe(st,0);
        if(N>1)begin
            probe(6,1);probe(7,1);probe(10,2);
            m_ready=1;
            fork: middle_replay
                begin seed_graph();forever @(negedge clk);end
                begin wait(dut.state==14 && dut.out_node>0);@(negedge clk);m_ready=0;end
            join_any
            disable middle_replay;
            reset_now();recovery();
        end
        held_probe(0);held_probe(1);
        phase=2;
        for(i=0;i<total_tokens;i=i+1)begin
            @(negedge clk);if(cycles%5==0)@(negedge clk);
            {s_from,s_to,s_source,s_weight,s_present,s_keep,s_first,s_last,s_tag}=tokens[i];s_valid=1;
            begin: main_accept
                forever begin @(posedge clk);if(s_ready)disable main_accept;end
            end
            @(negedge clk);s_valid=0;
        end
        wait(frames==total_frames);repeat(8)@(negedge clk);
        if(m_valid || inputs!=total_tokens)$fatal(1,"duplicate or missing transfer");
        $fclose(outfile);$fclose(meta_file);summary_file=$fopen(summary_path,"w");
        $fdisplay(summary_file,"{\"frames\":%0d,\"inputs\":%0d,\"outputs\":%0d,\"relaxations\":%0d,\"propagations\":%0d,\"cycles\":%0d,\"held\":%0d,\"blocked\":%0d,\"resets\":%0d,\"fresh_checks\":%0d,\"latency_checks\":%0d,\"max_first_latency\":%0d}",frames,inputs,outputs,relaxations,propagations,main_cycles,held_cycles,blocked,resets,fresh_checks,latency_checks,max_latency);
        $fclose(summary_file);
        $display("PASS signed_sssp N=%0d W=%0d T=%0d frames=%0d resets=%0d",N,W,T,frames,resets);
        $finish;
    end
endmodule
