`timescale 1ns/1ps
module tb_graph_cut_structure;
    parameter N=4,T=8;
    localparam IW=N>1?$clog2(N):1,CW=$clog2(N+1);
    localparam INW=64+3+T,OUTW=4+T+2*IW+4*CW+N;
    localparam FIRST_BOUND=3*N*N+7*N+8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,sv=0,mr=0;wire sr,mv,mk,ml,me,cut;
    reg [INW-1:0] source=0;
    wire [T-1:0] tag;wire [IW-1:0] node,component;
    wire [CW-1:0] components,after_removal,degree,bridge_count;
    wire [N-1:0] bridges;
    graph_cut_structure #(.NUM_NODES(N),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.s_valid(sv),.s_ready(sr),
        .s_u(source[INW-1 -:32]),.s_v(source[INW-33 -:32]),
        .s_present(source[T+2]),.s_keep(source[T+1]),.s_last(source[T]),.s_tag(source[T-1:0]),
        .m_valid(mv),.m_ready(mr),.m_keep(mk),.m_last(ml),.m_error(me),.m_tag(tag),
        .m_node(node),.m_component(component),.m_components(components),.m_after_removal(after_removal),
        .m_degree(degree),.m_bridge_count(bridge_count),.m_cut_vertex(cut),.m_bridge_neighbors(bridges));
    wire [OUTW-1:0] payload={mk,ml,me,tag,node,component,components,after_removal,degree,bridge_count,cut,bridges};
    reg [INW-1:0] inputs[0:100000];
    reg [OUTW-1:0] held;reg [INW-1:0] held_source;
    reg holding=0,source_held=0,awaiting_first=0;
    integer tick=0,tail_tick=0,max_latency=0,received=0,blocked=0,stalled=0,hold_age=0;
    integer count,outcount,fd=0,i,phase,guard,j,resets=0;
    string inpath,outpath;
    task reset_now;
        begin
            rst=1;sv=0;mr=0;holding=0;source_held=0;awaiting_first=0;hold_age=0;
            #1;if(sr || mv)$fatal(1,"reset transfer gate");
            @(negedge clk);rst=0;
        end
    endtask
    task send_word(input [INW-1:0] word);
        begin
            source=word;sv=1;
            begin:waiting
                for(j=0;j<200000;j=j+1) begin
                    @(posedge clk);
                    if(sr)begin @(negedge clk);sv=0;disable waiting;end
                end
                $fatal(1,"input timeout");
            end
        end
    endtask
    task fresh;
        integer k;reg [INW-1:0] word;
        begin
            word=0;word[INW-1 -:64]=64'hffffffffffffffff;word[T]=1;word[T-1:0]=3;
            send_word(word);guard=0;
            while(!mv)begin @(negedge clk);guard=guard+1;if(guard>FIRST_BOUND)$fatal(1,"fresh timeout");end
            repeat(4)begin @(negedge clk);if(!mv)$fatal(1,"fresh hold");end
            mr=1;
            for(k=0;k<N;k=k+1)begin
                while(!mv)@(negedge clk);
                if(!mk || me || node!=k || component!=k || components!=N || after_removal!=N-1 ||
                   degree!=0 || bridge_count!=0 || bridges!=0 || cut || ml!=(k==N-1) || tag!=(3 & ((64'b1<<T)-1)))
                    $fatal(1,"fresh empty graph");
                @(posedge clk);@(negedge clk);
            end
            mr=0;
        end
    endtask
    always @(posedge clk)if(!rst)begin
        tick=tick+1;
        if(sv && sr && source[T])begin tail_tick=tick;awaiting_first=1;end
        if(mv && awaiting_first)begin
            if(tick-tail_tick>FIRST_BOUND)$fatal(1,"conservative first bound");
            if(tick-tail_tick>max_latency)max_latency=tick-tail_tick;
            awaiting_first=0;
        end
        if(source_held && (!sv || source!==held_source))$fatal(1,"source hold violated");
        if(holding && (!mv || payload!==held))$fatal(1,"held result changed");
        source_held=sv && !sr;held_source=source;holding=mv && !mr;held=payload;
        if(sv && !sr)blocked=blocked+1;
        if(mv && !mr)stalled=stalled+1;
        if(mv && mr && fd!=0)begin $fdisplay(fd,"%h",payload);received=received+1;end
        if(tick>5000000)$fatal(1,"finite watchdog");
    end
    initial begin
        for(phase=0;phase<17;phase=phase+1)if(N>1 || (phase!=2 && phase!=10))begin
            @(negedge clk);reset_now();i=0;guard=0;
            begin:probe
                while(1)begin
                    if(dut.state==((phase<15)?phase:14))begin
                        if(phase>=15)begin
                            source=0;sv=1;repeat(4)@(negedge clk);
                            if(!mv || sr || me!=(phase==16))$fatal(1,"held reset phase");
                        end
                        reset_now();resets=resets+1;disable probe;
                    end
                    if(dut.state==1 && i<(N>1?N-1:1))begin
                        source=0;source[INW-1 -:32]=i;source[INW-33 -:32]=i+1;
                        source[T+2]=1;source[T+1]=(N>1);source[T]=(i==(N>1?N-2:0));sv=1;
                        if(phase==16)begin source[INW-1 -:32]=32'hffffffff;source[T+1]=1;source[T]=1;end
                    end else sv=0;
                    @(posedge clk);if(sv && sr)i=i+1;
                    @(negedge clk);guard=guard+1;if(guard>FIRST_BOUND+N*N+2*N+16)$fatal(1,"unreachable phase %0d",phase);
                end
            end
            fresh();
        end
        if(!$value$plusargs("INPUT=%s",inpath) || !$value$plusargs("OUTPUT=%s",outpath) ||
           !$value$plusargs("COUNT=%d",count) || !$value$plusargs("OUTCOUNT=%d",outcount))$fatal;
        $readmemh(inpath,inputs,0,count-1);fd=$fopen(outpath,"w");
        fork
            begin
                for(i=0;i<count;i=i+1)begin
                    if(i%7==2)begin sv=0;@(negedge clk);end
                    send_word(inputs[i]);
                end
            end
            begin
                while(received<outcount)begin
                    @(negedge clk);
                    if(mv && hold_age<4)begin mr=0;hold_age=hold_age+1;end
                    else mr=(tick%7!=1 && tick%7!=2);
                    if(!mv || (mv && mr))hold_age=0;
                end
            end
        join
        @(negedge clk);$fclose(fd);
        if(blocked==0 || stalled==0)$fatal(1,"no real stalls");
        $display("PASS cutgraph records=%0d blocked=%0d held=%0d resets=%0d max_latency=%0d bound=%0d",received,blocked,stalled,resets,max_latency,FIRST_BOUND);$finish;
    end
endmodule
