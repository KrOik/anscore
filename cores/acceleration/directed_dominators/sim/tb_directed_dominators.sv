`timescale 1ns/1ps
module tb_directed_dominators;
    parameter N=3,T=8;
    localparam IW=N>1?$clog2(N):1,CW=$clog2(N+1);
    localparam INW=99+T,OUTW=6+T+3*IW+4*CW+2*N;
    localparam FIRST_BOUND=2*N*N*N+7*N*N+6*N+12;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,sv=0,mr=0;wire sr,mv,mk,ml,reach,idv;
    reg [INW-1:0] source=0;wire [1:0] errors;
    wire [T-1:0] tag;wire [IW-1:0] node,root,idom;
    wire [CW-1:0] depth,dom_count,subtree_count,reached_count;
    wire [N-1:0] dominators,dominated;
    directed_dominators #(.NUM_NODES(N),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.s_valid(sv),.s_ready(sr),
        .s_from(source[INW-1 -:32]),.s_to(source[INW-33 -:32]),.s_root(source[INW-65 -:32]),
        .s_present(source[T+2]),.s_keep(source[T+1]),.s_last(source[T]),.s_tag(source[T-1:0]),
        .m_valid(mv),.m_ready(mr),.m_keep(mk),.m_last(ml),.m_errors(errors),.m_tag(tag),
        .m_node(node),.m_root(root),.m_idom(idom),.m_reachable(reach),.m_idom_valid(idv),
        .m_depth(depth),.m_dom_count(dom_count),.m_subtree_count(subtree_count),.m_reached_count(reached_count),
        .m_dominators(dominators),.m_dominated(dominated));
    wire [OUTW-1:0] payload={mk,ml,errors,tag,node,root,idom,reach,idv,depth,dom_count,subtree_count,reached_count,dominators,dominated};
    reg [INW-1:0] inputs[0:100000];
    reg [OUTW-1:0] held;reg [INW-1:0] held_source;
    reg holding=0,source_held=0,awaiting_first=0;
    integer tick=0,tail_tick=0,max_latency=0,received=0,blocked=0,stalled=0,hold_age=0;
    integer count,outcount,fd=0,i,phase,guard,j,resets=0,max_passes=0,writes=0;
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
                for(j=0;j<FIRST_BOUND+4*N+30;j=j+1)begin
                    @(posedge clk);
                    if(sr)begin @(negedge clk);sv=0;disable waiting;end
                end
                $fatal(1,"input timeout");
            end
        end
    endtask
    task fresh;
        integer k;reg [INW-1:0] word;reg [N-1:0] prefix,suffix;
        begin
            for(k=0;k<(N>1?N-1:1);k=k+1)begin
                word=0;word[INW-1 -:32]=k;word[INW-33 -:32]=(N>1?k+1:0);
                word[T+2]=1;word[T+1]=1;word[T]=(k==(N>1?N-2:0));word[T-1:0]=3;
                send_word(word);
            end
            guard=0;
            while(!mv)begin @(negedge clk);guard=guard+1;if(guard>FIRST_BOUND)$fatal(1,"fresh timeout");end
            repeat(4)begin @(negedge clk);if(!mv)$fatal(1,"fresh hold");end
            mr=1;prefix=0;
            for(k=0;k<N;k=k+1)begin
                while(!mv)@(negedge clk);
                prefix[k]=1;suffix={N{1'b1}}<<k;
                if(!mk || errors || node!=k || root!=0 || idv!=(k!=0) || idom!=(k>0?k-1:0) || !reach ||
                   depth!=k || dom_count!=k+1 || subtree_count!=N-k || reached_count!=N ||
                   dominators!==prefix || dominated!==suffix || ml!=(k==N-1) || tag!=(3 & ((64'b1<<T)-1)))
                    $fatal(1,"fresh chain isolation");
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
        if((dut.state>=5 && dut.state<=7) || (dut.state>=9 && dut.state<=14))begin
            if(dut.pass_count<1 || dut.pass_count>N)$fatal(1,"convergence bound");
            if(dut.pass_count>max_passes)max_passes=dut.pass_count;
        end
        if(dut.state==13)begin
            writes=writes+1;
            if((dut.new_dom&~dut.old_dom)!=0 || !dut.new_dom[dut.active_node] || !dut.new_dom[dut.source_root])
                $fatal(1,"dominator descending invariant");
        end
        if(tick>10000000)$fatal(1,"finite watchdog");
    end
    initial begin
        for(phase=0;phase<28;phase=phase+1)if(N>1 || (phase!=11 && phase!=12 && phase!=13 && phase!=26))begin
            @(negedge clk);reset_now();i=0;guard=0;
            begin:probe
                while(1)begin
                    if((phase<23 && dut.state==phase) ||
                       (phase==23 && dut.state==22) || (phase==24 && dut.state==22) ||
                       (phase==25 && dut.state==6 && dut.active_node==N/2) ||
                       (phase==26 && dut.state==12 && dut.active_node==N/2 && dut.scan_node==N/2) ||
                       (phase==27 && dut.state==18 && dut.active_node==N/2 && dut.scan_node==N/2))begin
                        if(phase==23 || phase==24)begin
                            source=0;sv=1;repeat(4)@(negedge clk);
                            if(!mv || sr || (errors!=0)!=(phase==24))$fatal(1,"held reset phase");
                        end
                        reset_now();resets=resets+1;disable probe;
                    end
                    if(dut.state==1 && i<(N>1?N-1:1))begin
                        source=0;source[INW-1 -:32]=i;source[INW-33 -:32]=(N>1?i+1:0);
                        source[T+2]=1;source[T+1]=1;source[T]=(i==(N>1?N-2:0));sv=1;
                        if(phase==24)begin source[INW-1 -:32]=32'hffffffff;source[T]=1;end
                    end else sv=0;
                    @(posedge clk);if(sv && sr)i=i+1;
                    @(negedge clk);guard=guard+1;if(guard>FIRST_BOUND+4*N+30)$fatal(1,"unreachable phase %0d",phase);
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
        $display("PASS dominators records=%0d blocked=%0d held=%0d resets=%0d max_latency=%0d bound=%0d max_passes=%0d writes=%0d",received,blocked,stalled,resets,max_latency,FIRST_BOUND,max_passes,writes);$finish;
    end
endmodule
