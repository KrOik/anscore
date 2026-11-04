`timescale 1ns/1ps
module tb_ram_fenwick_index;
    parameter N=3,W=5,T=3;
    localparam IW=N>1?$clog2(N):1,NW=N>1?$clog2(N+1):1,SW=W+(N>1?$clog2(N):0);
    localparam INW=66+W+SW+T,OUTW=4+IW+2*SW+T,BOUND=(N+1)>6*NW+8?(N+1):6*NW+8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,rr=0;reg [INW-1:0] command=0;
    wire cr,rv;wire [1:0] op,status;wire [IW-1:0] index;
    wire [SW-1:0] result,total;wire [T-1:0] tag;
    ram_fenwick_index #(.BUCKETS(N),.COUNT_W(W),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(command[INW-1 -:2]),
        .c_lo(command[T+SW+W+32 +:32]),.c_hi(command[T+SW+W +:32]),
        .c_value(command[T+SW +:W]),.c_rank(command[T +:SW]),.c_tag(command[T-1:0]),
        .r_valid(rv),.r_ready(rr),.r_op(op),.r_status(status),.r_index(index),.r_sum(result),.r_total(total),.r_tag(tag));
    wire [OUTW-1:0] response={op,status,index,result,total,tag};
    reg [INW-1:0] inputs[0:30000],held_source;
    reg [OUTW-1:0] held_response;
    reg source_held=0,response_held=0,awaiting=0;
    integer tick=0,accepted_tick=0,max_latency=0,blocked=0,held=0,received=0,resets=0;
    integer recovery_commands=0,slot_checks=0,fd=0,count,outcount,i,j,guard,phase,target,hold_age=0;
    integer update_writes=0,prefix_reads=0,select_reads=0,select_skips=0;
    string inpath,outpath;
    function automatic [INW-1:0] word(input [1:0] operation,input [31:0] lo,hi,
        input [W-1:0] val,input [SW-1:0] rank,input [T-1:0] tok);
        word={operation,lo,hi,val,rank,tok};
    endfunction
    task reset_now;
        begin
            rst=1;cv=0;rr=0;source_held=0;response_held=0;awaiting=0;hold_age=0;
            #1;if(cr || rv)$fatal(1,"reset transfer gate");
            @(posedge clk);#1;if(response!==0)$fatal(1,"reset public zero");
            @(negedge clk);rst=0;
        end
    endtask
    task send_word(input [INW-1:0] w);
        integer g;
        begin
            command=w;cv=1;
            begin:accepting
                for(g=0;g<100000;g=g+1)begin
                    @(posedge clk);if(cr)begin @(negedge clk);cv=0;disable accepting;end
                end
                $fatal(1,"source timeout");
            end
        end
    endtask
    task expected(input [INW-1:0] w,input [1:0] st,input [IW-1:0] idx,
                  input [SW-1:0] val,tot);
        integer g;
        reg [OUTW-1:0] want;
        begin
            send_word(w);g=0;
            while(!rv)begin @(negedge clk);g=g+1;if(g>BOUND)$fatal(1,"fresh response timeout");end
            want={w[INW-1 -:2],st,idx,val,tot,w[T-1:0]};
            if(response!==want)$fatal(1,"fresh response got=%h want=%h",response,want);
            repeat(4)@(negedge clk);
            if(response!==want || !rv)$fatal(1,"fresh hold");
            rr=1;@(posedge clk);@(negedge clk);rr=0;recovery_commands=recovery_commands+1;
        end
    endtask
    task fresh;
        reg [W-1:0] maximum;reg [SW-1:0] mass;reg [T-1:0] tok;integer q;
        begin
            maximum={W{1'b1}};tok={T{1'b1}};mass=maximum;
            expected(word(1,0,N-1,0,0,tok),0,0,0,0);
            for(q=0;q<N;q=q+1)if(dut.leaves[q]!==0 || dut.tree[q]!==0)$fatal(1,"fresh stale bank row");
            expected(word(0,0,32'hffffffff,1,0,tok),0,0,0,1);
            expected(word(2,32'hffffffff,32'hffffffff,0,0,tok),0,0,0,1);
            if(N>1)begin
                mass=mass+1'b1;
                expected(word(0,N-1,0,maximum,0,tok),0,N-1,0,mass);
                expected(word(1,0,N-1,0,0,tok),0,0,mass,mass);
                expected(word(2,0,0,0,1,tok),0,N-1,1,mass);
                expected(word(0,0,0,0,0,tok),0,0,1,maximum);
                expected(word(2,0,0,0,0,tok),0,N-1,0,maximum);
            end else begin
                expected(word(0,0,0,maximum,0,tok),0,0,1,maximum);
                expected(word(1,0,0,0,0,tok),0,0,maximum,maximum);
                expected(word(0,0,0,0,0,tok),0,0,maximum,0);
            end
            expected(word(3,32'hffffffff,32'hffffffff,maximum,{SW{1'b1}},tok),0,0,0,0);
            expected(word(2,0,0,0,0,tok),2,0,0,0);
        end
    endtask
    always @(posedge clk)if(!rst)begin
        tick=tick+1;
        if(cv && cr)begin accepted_tick=tick;awaiting=1;end
        if(rv && awaiting)begin
            if(tick-accepted_tick>BOUND)$fatal(1,"first response bound");
            if(tick-accepted_tick>max_latency)max_latency=tick-accepted_tick;awaiting=0;
        end
        if(source_held && (!cv || command!==held_source))$fatal(1,"source stability");
        if(response_held && (!rv || response!==held_response))$fatal(1,"response stability");
        source_held=cv && !cr;held_source=command;response_held=rv && !rr;held_response=response;
        if(cv && !cr)blocked=blocked+1;
        if(rv && !rr)held=held+1;
        if(dut.state==6)update_writes=update_writes+1;
        if(dut.state==7)prefix_reads=prefix_reads+1;
        if(dut.state==12)select_reads=select_reads+1;
        if(dut.state==11 && dut.step!=0 && dut.select_candidate>N)select_skips=select_skips+1;
        if(rv && rr && fd!=0)begin
            $fwrite(fd,"%h",response);
            for(j=0;j<N;j=j+1)begin
                $fwrite(fd," %h %h",dut.leaves[j],dut.tree[j]);slot_checks=slot_checks+1;
            end
            $fwrite(fd,"\n");received=received+1;
        end
        if(tick>10000000)$fatal(1,"finite watchdog");
    end
    initial begin
        for(phase=0;phase<20;phase=phase+1)if(N>1 || phase!=19)begin
            @(negedge clk);reset_now();
            if(phase!=0)begin
                while(!cr)@(negedge clk);
                if((phase>=11 && phase<=14) || phase==18 || phase==19)begin
                    expected(word(0,N-1,0,1,0,1),0,N-1,0,1);
                    while(!cr)@(negedge clk);
                end
                if(phase!=1)begin
                    if(phase>=7 && phase<=10)send_word(word(1,0,N-1,0,0,1));
                    else if(phase>=11 && phase<=14)send_word(word(2,0,0,0,0,1));
                    else if(phase==17)send_word(word(0,32'hffffffff,0,1,0,1));
                    else if(phase==18)send_word(word(3,0,0,0,0,1));
                    else if(phase==19)send_word(word(1,1,N-1,0,0,1));
                    else send_word(word(0,0,0,1,0,1));
                end
            end
            target=phase<16?phase:(phase==16 || phase==17?15:(phase==18?0:8));guard=0;
            while(dut.state!=target || (phase==18 && dut.clear_index!=N/2) || (phase==19 && !dut.left_phase))begin
                @(negedge clk);guard=guard+1;if(guard>BOUND+N+20)$fatal(1,"unreachable reset phase %0d",phase);
            end
            if(phase==16 || phase==17)begin
                repeat(4)@(negedge clk);if(!rv || cr || status!=(phase==17?1:0))$fatal(1,"held reset phase");
            end
            reset_now();resets=resets+1;fresh();
        end
        if(!$value$plusargs("INPUT=%s",inpath) || !$value$plusargs("OUTPUT=%s",outpath) ||
           !$value$plusargs("COUNT=%d",count) || !$value$plusargs("OUTCOUNT=%d",outcount))$fatal;
        $readmemh(inpath,inputs,0,count-1);fd=$fopen(outpath,"w");
        fork
            begin
                for(i=0;i<count;i=i+1)begin
                    if(i%7==2)begin cv=0;@(negedge clk);end
                    send_word(inputs[i]);
                end
            end
            begin
                while(received<outcount)begin
                    @(negedge clk);
                    if(rv && hold_age<4)begin rr=0;hold_age=hold_age+1;end
                    else rr=(tick%7!=1 && tick%7!=2);
                    if(!rv || (rv && rr))hold_age=0;
                end
            end
        join
        @(negedge clk);$fclose(fd);
        if(blocked==0 || held==0 || received!=count)$fatal(1,"finite coverage");
        $display("PASS fenwick responses=%0d cycles=%0d blocked=%0d held=%0d resets=%0d recovery=%0d slots=%0d max_latency=%0d bound=%0d updates=%0d prefixes=%0d selects=%0d skips=%0d",received,tick,blocked,held,resets,recovery_commands,slot_checks,max_latency,BOUND,update_writes,prefix_reads,select_reads,select_skips);
        $finish;
    end
endmodule
