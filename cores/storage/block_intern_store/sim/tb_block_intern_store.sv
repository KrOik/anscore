`timescale 1ns/1ps
module tb_block_intern_store;
    parameter N=3,B=3,W=5,R=2,T=3;
    localparam WW=B>1?$clog2(B):1,CW=N>1?$clog2(N+1):1;
    localparam INW=34+T+B*W,OUTW=41+T+R+CW+WW+W,BOUND=N*(2+2*B)+2*B+8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,dv=0,rr=0;reg [INW-1:0] command=0;reg [W-1:0] dd=0;
    wire cr,dr,rv,shared,keep,first,last;wire [1:0] op;wire [2:0] status;
    wire [31:0] handle;wire [T-1:0] tag;wire [R-1:0] refs;wire [CW-1:0] count_live;
    wire [WW-1:0] index;wire [W-1:0] data;
    block_intern_store #(.SLOTS(N),.WORDS(B),.DATA_W(W),.REF_W(R),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(command[INW-1 -:2]),
        .c_handle(command[T+B*W +:32]),.c_tag(command[B*W +:T]),
        .d_valid(dv),.d_ready(dr),.d_data(dd),.r_valid(rv),.r_ready(rr),
        .r_op(op),.r_status(status),.r_handle(handle),.r_tag(tag),.r_refs(refs),.r_count(count_live),
        .r_shared(shared),.r_keep(keep),.r_first(first),.r_last(last),.r_index(index),.r_data(data));
    wire [OUTW-1:0] response={op,status,handle,tag,refs,count_live,shared,keep,first,last,index,data};
    reg [INW-1:0] inputs[0:9999],held_source;
    reg [W-1:0] held_data;reg [OUTW-1:0] held_response;
    reg source_held=0,data_held=0,response_held=0,awaiting=0,read_gap=0;
    integer tick=0,start_tick=0,max_latency=0,read_tick=0,blocked=0,data_blocked=0,held=0;
    integer completed=0,resets=0,recovery=0,comparisons=0,copies=0;
    integer count,fd=0,i,j,k,phase,target,guard,hold_age=0;
    string inpath,outpath;
    function automatic [INW-1:0] word(input [1:0] operation,input [31:0] h,input [W-1:0] value);
        reg [B*W-1:0] block;integer q;
        begin for(q=0;q<B;q=q+1)block[q*W +:W]=value;word={operation,h,{T{1'b1}},block};end
    endfunction
    task reset_now;
        begin
            rst=1;cv=0;dv=0;rr=0;source_held=0;data_held=0;response_held=0;awaiting=0;read_gap=0;hold_age=0;
            #1;if(cr || dr || rv)$fatal(1,"reset gates");
            @(posedge clk);#1;if(op!==0 || status!==0 || handle!==0 || tag!==0 || refs!==0 || count_live!==0 || shared!==0 || keep!==0 || !first || !last || index!==0 || data!==0)$fatal(1,"reset public canonical");
            @(negedge clk);rst=0;
        end
    endtask
    task command_only(input [INW-1:0] w);
        integer g;
        begin
            command=w;cv=1;
            begin:accept_cmd
                for(g=0;g<100000;g=g+1)begin
                    @(posedge clk);if(cr)begin @(negedge clk);cv=0;disable accept_cmd;end
                end
                $fatal(1,"command finite watchdog");
            end
        end
    endtask
    task send(input [INW-1:0] w);
        integer q,g;
        begin
            if(w[INW-1 -:2]==0)begin dv=1;dd=w[(B-1)*W +:W];end else dv=0;
            command_only(w);
            if(w[INW-1 -:2]==0)for(q=0;q<B;q=q+1)begin
                if(q>0)begin
                    if(q%3==1)begin dv=0;@(negedge clk);end
                    dv=1;dd=w[(B-1-q)*W +:W];
                end
                begin:accept_data
                    for(g=0;g<100000;g=g+1)begin
                        @(posedge clk);if(dr)begin @(negedge clk);dv=0;disable accept_data;end
                    end
                    $fatal(1,"data finite watchdog");
                end
            end
        end
    endtask
    task expected(input [1:0] operation,input [31:0] h,input [W-1:0] value,
        input [2:0] st,input [31:0] result_handle,input [R-1:0] result_refs,
        input [CW-1:0] occupied,input result_shared);
        integer q,g,total;reg [OUTW-1:0] want;
        begin
            send(word(operation,h,value));total=(operation==1 && st==0)?B:1;
            for(q=0;q<total;q=q+1)begin
                g=0;while(!rv)begin @(negedge clk);g=g+1;if(g>BOUND)$fatal(1,"fresh bound");end
                want={operation,st,result_handle,{T{1'b1}},result_refs,occupied,result_shared,
                    (operation==1 && st==0),(q==0),(q==total-1),WW'(q),(operation==1 && st==0)?value:W'(0)};
                if(response!==want)$fatal(1,"fresh got=%h want=%h op=%0d",response,want,operation);
                repeat(4)@(negedge clk);
                if(response!==want || !rv)$fatal(1,"fresh held output");
                rr=1;@(posedge clk);@(negedge clk);rr=0;
            end
            recovery=recovery+1;
        end
    endtask
    task fresh;
        integer q;reg [CW-1:0] occ;
        begin
            while(!cr)@(negedge clk);
            for(q=0;q<N;q=q+1)if(dut.refs[q]!==0)$fatal(1,"fresh stale reference");
            expected(1,0,0,2,0,0,0,0);
            expected(0,32'hffffffff,{W{1'b1}},0,0,1,1,0);
            if(R>1)expected(0,0,{W{1'b1}},0,0,2,1,1);
            else expected(0,0,{W{1'b1}},3,0,0,1,0);
            occ=1;
            if(N>1)begin expected(0,0,0,0,1,1,2,0);occ=2;end
            expected(1,0,{W{1'b1}},0,0,(R>1)?2:1,occ,0);
            expected(2,0,0,0,0,(R>1)?1:0,(R>1)?occ:occ-1'b1,0);
            if(R>1)expected(2,0,0,0,0,0,occ-1'b1,0);
            expected(1,0,0,2,0,0,occ-1'b1,0);
            if(N>1)expected(1,1,0,0,1,1,1,0);
            expected(0,0,{W{1'b1}},0,0,1,occ,0);
            expected(3,32'hffffffff,0,0,0,0,0,0);
            expected(1,0,0,2,0,0,0,0);
        end
    endtask
    always @(posedge clk)if(!rst)begin
        tick=tick+1;
        if(cv && cr)begin start_tick=tick;awaiting=(command[INW-1 -:2]!=0);end
        if(dv && dr && dut.word_index==B-1)begin start_tick=tick;awaiting=1;end
        if(rv && awaiting)begin
            if(tick-start_tick>BOUND)$fatal(1,"first response bound");
            if(tick-start_tick>max_latency)max_latency=tick-start_tick;awaiting=0;
        end
        if(read_gap && rv)begin if(tick-read_tick!=2)$fatal(1,"READ spacing");read_gap=0;end
        if(rv && rr && keep && !last)begin read_gap=1;read_tick=tick;end
        if(source_held && (!cv || command!==held_source))$fatal(1,"held command changed");
        if(data_held && (!dv || dd!==held_data))$fatal(1,"held input word changed");
        if(response_held && (!rv || response!==held_response))$fatal(1,"held response changed");
        source_held=cv && !cr;held_source=command;data_held=dv && !dr;held_data=dd;
        response_held=rv && !rr;held_response=response;
        if(cv && !cr)blocked=blocked+1;if(dv && !dr)data_blocked=data_blocked+1;if(rv && !rr)held=held+1;
        if(dut.state==6)comparisons=comparisons+1;if(dut.state==9)copies=copies+1;
        if(rv && rr && fd!=0)begin
            $fwrite(fd,"%h",response);
            for(j=0;j<N;j=j+1)begin
                $fwrite(fd," %h",dut.refs[j]);
                for(k=0;k<B;k=k+1)$fwrite(fd," %h",dut.refs[j]!=0?dut.payload[j*B+k]:W'(0));
            end
            $fwrite(fd,"\n");if(last)completed=completed+1;
        end
        if(tick>10000000)$fatal(1,"finite total watchdog");
    end
    initial begin
        for(phase=0;phase<20;phase=phase+1)if((phase!=7 || R>1) && (phase<18 || B>1))begin
            @(negedge clk);reset_now();
            if(phase!=0)begin
                while(!cr)@(negedge clk);
                if((phase>=3 && phase<=7) || (phase>=11 && phase<=13) || phase==15 || phase==17 || phase==19)begin
                    expected(0,0,{W{1'b1}},0,0,1,1,0);while(!cr)@(negedge clk);
                end
                if(phase==2)command_only(word(0,0,1));
                else if(phase==3 || phase==4 || phase==12 || phase==13 || phase==17 || phase==19)send(word(1,0,0));
                else if(phase==5 || phase==6 || phase==7 || phase==8 || phase==9 || phase==10 || phase==18)send(word(0,0,{W{1'b1}}));
                else if(phase==11)send(word(2,0,0));
                else if(phase==14 || phase==16)send(word(1,32'hffffffff,0));
                else if(phase==15)send(word(3,0,0));
            end
            target=phase<15?phase:phase==15?0:phase==16?14:phase==18?9:13;
            guard=0;
            while(dut.state!=target || (phase==15 && dut.init_index!=N/2) || (phase==18 && dut.word_index!=B/2))begin
                @(negedge clk);guard=guard+1;if(guard>BOUND+N+20)$fatal(1,"unreachable phase %0d state=%0d",phase,dut.state);
            end
            if(phase==19)begin
                rr=1;@(posedge clk);@(negedge clk);rr=0;
                while(!rv)@(negedge clk);
                if(index!=1)$fatal(1,"partial replay reset fixture");
            end
            if(phase==16 || phase==17)begin
                command=word(0,0,0);cv=1;dv=1;dd=0;
                repeat(4)@(negedge clk);if(!rv || cr || dr)$fatal(1,"held reset fixture");
            end
            reset_now();resets=resets+1;fresh();
        end
        if(!$value$plusargs("INPUT=%s",inpath) || !$value$plusargs("OUTPUT=%s",outpath) || !$value$plusargs("COUNT=%d",count))$fatal;
        $readmemh(inpath,inputs,0,count-1);fd=$fopen(outpath,"w");
        fork
            begin for(i=0;i<count;i=i+1)begin if(i%7==2)@(negedge clk);send(inputs[i]);end end
            begin while(completed<count)begin
                @(negedge clk);
                if(rv && hold_age<4)begin rr=0;hold_age=hold_age+1;end else rr=(tick%7!=1 && tick%7!=2);
                if(!rv || (rv && rr))hold_age=0;
            end end
        join
        @(negedge clk);$fclose(fd);
        if(blocked==0 || data_blocked==0 || held==0)$fatal(1,"finite stall coverage");
        $display("PASS intern commands=%0d cycles=%0d blocked=%0d data_blocked=%0d held=%0d resets=%0d recovery=%0d max_latency=%0d bound=%0d comparisons=%0d copies=%0d",completed,tick,blocked,data_blocked,held,resets,recovery,max_latency,BOUND,comparisons,copies);
        $finish;
    end
endmodule
