`timescale 1ns/1ps
module tb_min_cost_assignment;
    parameter N=3, COST_W=4, TAG_W=5;
    localparam IW=N>1?$clog2(N):1, TW=COST_W+$clog2(N), DW=COST_W+2*$clog2(N)+3;
    localparam INW=64+COST_W+3+TAG_W, OUTW=2+2+TAG_W+2*IW+COST_W+TW+2*DW+2*N;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, sv=0, mr=0;
    wire sr,mv,mk,ml; wire [1:0] ms; wire [TAG_W-1:0] mt;
    reg [INW-1:0] source=0;
    wire [IW-1:0] row,col; wire signed [COST_W-1:0] cost;
    wire signed [TW-1:0] total; wire signed [DW-1:0] ud,vd;
    wire [N-1:0] hr,hc;
    min_cost_assignment #(.N(N),.COST_W(COST_W),.TAG_W(TAG_W)) dut(
        .clk(clk),.rst(rst),.s_valid(sv),.s_ready(sr),
        .s_row(source[INW-1 -:32]),.s_column(source[INW-33 -:32]),
        .s_cost(source[TAG_W+3 +:COST_W]),.s_allowed(source[TAG_W+2]),
        .s_keep(source[TAG_W+1]),.s_last(source[TAG_W]),.s_tag(source[TAG_W-1:0]),
        .m_valid(mv),.m_ready(mr),.m_keep(mk),.m_last(ml),.m_status(ms),.m_tag(mt),
        .m_row(row),.m_column(col),.m_cost(cost),.m_total(total),.m_row_dual(ud),
        .m_column_dual(vd),.m_hall_rows(hr),.m_hall_columns(hc));
    wire [OUTW-1:0] payload={mk,ml,ms,mt,row,col,cost,total,ud,vd,hr,hc};
    reg [INW-1:0] inputs[0:100000];
    reg [OUTW-1:0] held;
    reg holding=0; integer tick=0, received=0, blocked=0, stalled=0, hold_age=0;
    reg source_held=0;reg [INW-1:0] held_source;
    localparam integer FIRST_BOUND=(N+1)+N*(N+2)+(3*N+5)*N*(N+1)/2+N+3;
    integer tail_tick=0,max_latency=0;reg awaiting_first=0;
    integer count,outcount,fd,rc,i,phase,guard,j; string inpath,outpath;
    reg [INW-1:0] pending_word;
    task reset_now;
        begin
            rst=1;sv=0;mr=0;holding=0;source_held=0;hold_age=0;awaiting_first=0;
            @(negedge clk);rst=0;
        end
    endtask
    task send_word(input [INW-1:0] word);
        begin
            source=word;sv=1;
            begin: waiting
                for(j=0;j<2000000;j=j+1) begin
                    @(posedge clk);
                    if(sr) begin @(negedge clk);sv=0;disable waiting;end
                end
                $fatal(1,"input timeout");
            end
        end
    endtask
    task fresh;
        integer r,k;
        begin
            for(r=0;r<N;r=r+1) begin
                pending_word=0;
                pending_word[INW-1 -:32]=r;pending_word[INW-33 -:32]=r;
                pending_word[TAG_W+2]=1;pending_word[TAG_W+1]=1;
                pending_word[TAG_W]=(r==N-1);pending_word[TAG_W-1:0]=3;
                send_word(pending_word);
            end
            guard=0;
            while(!mv) begin @(negedge clk);guard=guard+1;if(guard>2000000)$fatal(1,"fresh timeout");end
            // Deliberately hold the first, including singleton, result.
            repeat(4) begin @(negedge clk);if(!mv || total!=0)$fatal(1,"fresh held");end
            mr=1;
            for(k=0;k<N;k=k+1) begin
                while(!mv) @(negedge clk);
                if(!mk || ms!=0 || row!=k || col!=k || cost!=0 || total!=0 || mt!=(3 & ((64'b1<<TAG_W)-1)) || ml!=(k==N-1))
                    $fatal(1,"fresh certificate");
                @(posedge clk);@(negedge clk);
            end
            mr=0;
        end
    endtask
    always @(posedge clk) if(!rst) begin
        tick=tick+1;
        if(sv && sr && source[TAG_W]) begin tail_tick=tick;awaiting_first=1;end
        if(mv && awaiting_first) begin
            if(tick-tail_tick>FIRST_BOUND)$fatal(1,"first-result bound exceeded");
            if(tick-tail_tick>max_latency)max_latency=tick-tail_tick;
            awaiting_first=0;
        end
        if(sv && !sr) blocked=blocked+1;
        if(source_held && (!sv || source!==held_source))$fatal(1,"unstable blocked source");
        source_held=sv && !sr;held_source=source;
        if(holding && (!mv || payload!==held)) $fatal(1,"unstable held result");
        holding=mv && !mr;held=payload;
        if(mv && !mr) stalled=stalled+1;
        if(mv && mr && fd!=0) begin $fdisplay(fd,"%h",payload);received=received+1;end
        if(tick>10000000)$fatal(1,"finite watchdog");
    end
    initial begin
        fd=0;
        // Cancel immediately at every implementation state, with no intervening active edge.
        for(phase=0;phase<18;phase=phase+1) begin
            @(negedge clk);reset_now();i=0;guard=0;
            begin: probe
                while(1) begin
                    if(dut.state==((phase<16)?phase:15)) begin
                        if(phase>=16) begin
                            source=0;sv=1;
                            repeat(4) @(negedge clk);
                            if(!mv || sr || ms!=((phase==17)?1:0))$fatal(1,"held reset boundary");
                        end
                        reset_now();disable probe;
                    end
                    if(dut.state==1 && i<N*N) begin
                        source=0;source[INW-1 -:32]=i/N;source[INW-33 -:32]=i%N;
                        source[TAG_W+2]=1;source[TAG_W+1]=1;source[TAG_W]=(i==N*N-1);sv=1;
                        if(phase==17) begin source[INW-1 -:32]=N;source[TAG_W]=1;end
                    end else sv=0;
                    @(posedge clk);if(sv && sr)i=i+1;
                    @(negedge clk);guard=guard+1;if(guard>2000000)$fatal(1,"phase unreachable %0d",phase);
                end
            end
            fresh();
        end
        if(!$value$plusargs("INPUT=%s",inpath) || !$value$plusargs("OUTPUT=%s",outpath) ||
           !$value$plusargs("COUNT=%d",count) || !$value$plusargs("OUTCOUNT=%d",outcount))$fatal;
        $readmemh(inpath,inputs,0,count-1);fd=$fopen(outpath,"w");
        fork
            begin
                for(i=0;i<count;i=i+1) begin
                    if(i%7==2) begin sv=0;@(negedge clk);end
                    send_word(inputs[i]);
                end
            end
            begin
                while(received<outcount) begin
                    @(negedge clk);
                    if(mv && hold_age<4) begin mr=0;hold_age=hold_age+1;end
                    else mr=(tick%7!=1 && tick%7!=2);
                    if(!mv || (mv && mr)) hold_age=0;
                end
            end
        join
        @(negedge clk);$fclose(fd);
        if(blocked==0 || stalled==0)$fatal(1,"no real stalls");
        $display("PASS records=%0d blocked=%0d stalled=%0d reset_phases=18 max_latency=%0d bound=%0d",received,blocked,stalled,max_latency,FIRST_BOUND);$finish;
    end
endmodule
