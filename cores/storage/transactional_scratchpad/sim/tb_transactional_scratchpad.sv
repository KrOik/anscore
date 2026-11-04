// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_transactional_scratchpad;
    parameter C=2,N=3,W=5,T=3;
    localparam CW=N>1?$clog2(N+1):1,INW=43+W+T,OUTW=48+T+W+CW;
    localparam BOUND=(C*N+1)>N*(3+2*C)+3?(C*N+1):N*(3+2*C)+3;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,rr=0;reg [INW-1:0] command=0;
    wire cr,rv,active,conflict;wire [2:0] op,status;wire [7:0] context_id;
    wire [31:0] address;wire [T-1:0] tag;wire [W-1:0] data;wire [CW-1:0] written;
    transactional_scratchpad #(.CONTEXTS(C),.DEPTH(N),.DATA_W(W),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(command[INW-1 -:3]),
        .c_context(command[T+W+32 +:8]),.c_address(command[T+W +:32]),.c_data(command[T +:W]),.c_tag(command[T-1:0]),
        .r_valid(rv),.r_ready(rr),.r_op(op),.r_status(status),.r_context(context_id),.r_address(address),.r_tag(tag),
        .r_data(data),.r_written(written),.r_active(active),.r_conflict(conflict));
    wire [OUTW-1:0] response={op,status,context_id,address,tag,data,written,active,conflict};
    reg [INW-1:0] inputs[0:9999],held_source;reg [OUTW-1:0] held_response;
    reg source_held=0,response_held=0,awaiting=0;
    integer tick=0,start_tick=0,max_latency=0,blocked=0,held=0,received=0,resets=0,recovery=0;
    integer applications=0,invalidations=0,count,fd=0,i,j,k,guard,phase,target,hold_age=0;
    string inpath,outpath;
    function automatic [INW-1:0] word(input [2:0] operation,input [7:0] tx,input [31:0] addr,input [W-1:0] value);
        word={operation,tx,addr,value,{T{1'b1}}};
    endfunction
    task reset_now;
        begin
            rst=1;cv=0;rr=0;source_held=0;response_held=0;awaiting=0;hold_age=0;
            #1;if(cr || rv)$fatal(1,"reset transfer gates");
            @(posedge clk);#1;if(response!==0)$fatal(1,"reset outputs");
            @(negedge clk);rst=0;
        end
    endtask
    task send(input [INW-1:0] w);
        integer g;
        begin
            command=w;cv=1;
            begin:accepting
                for(g=0;g<100000;g=g+1)begin @(posedge clk);if(cr)begin @(negedge clk);cv=0;disable accepting;end end
                $fatal(1,"source finite watchdog");
            end
        end
    endtask
    task expected(input [2:0] operation,input [7:0] tx,input [31:0] addr,input [W-1:0] value,
        input [2:0] st,input [W-1:0] result,input [CW-1:0] writes,input act,conf);
        integer g;reg [OUTW-1:0] want;
        begin
            send(word(operation,tx,addr,value));g=0;
            while(!rv)begin @(negedge clk);g=g+1;if(g>BOUND)$fatal(1,"fresh response bound");end
            want={operation,st,tx,addr,{T{1'b1}},result,writes,act,conf};
            if(response!==want)$fatal(1,"fresh op=%0d got=%h want=%h",operation,response,want);
            repeat(4)@(negedge clk);
            if(!rv || response!==want)$fatal(1,"fresh held result");
            rr=1;@(posedge clk);@(negedge clk);rr=0;recovery=recovery+1;
        end
    endtask
    task fresh;
        integer q;
        begin
            while(!cr)@(negedge clk);
            if(dut.active!==0 || dut.conflicted!==0)$fatal(1,"fresh stale flags");
            for(q=0;q<N;q=q+1)if(dut.committed[q]!==0)$fatal(1,"fresh stale committed word");
            for(q=0;q<C*N;q=q+1)if(dut.read_mask[q]!==0 || dut.write_mask[q]!==0)$fatal(1,"fresh stale metadata");
            for(q=0;q<C;q=q+1)if(dut.write_count[q]!==0)$fatal(1,"fresh stale write count");
            expected(5,255,0,0,0,0,0,0,0);
            expected(0,0,32'hffffffff,0,0,0,0,1,0);
            expected(2,0,0,{W{1'b1}},0,0,0,1,0);
            expected(1,0,0,0,0,{W{1'b1}},0,1,0);
            expected(5,255,0,0,0,0,0,0,0);
            if(N>1)expected(2,0,N-1,1,0,0,0,1,0);
            if(C>1)begin
                expected(0,C-1,0,0,0,0,0,1,0);
                expected(1,C-1,0,0,0,0,0,1,0);
                expected(2,C-1,N-1,0,0,0,0,1,0);
            end
            expected(3,0,32'hffffffff,0,0,0,(N>1)?2:1,0,0);
            expected(5,255,0,0,0,{W{1'b1}},0,0,0);
            if(N>1)expected(5,255,N-1,0,0,1,0,0,0);
            if(C>1)begin
                expected(1,C-1,0,0,6,0,0,1,1);
                expected(3,C-1,0,0,6,0,0,0,0);
            end
            expected(0,0,0,0,0,0,0,1,0);
            expected(2,0,0,0,0,0,0,1,0);
            expected(4,0,32'hffffffff,0,0,0,0,0,0);
            expected(5,255,0,0,0,{W{1'b1}},0,0,0);
            expected(6,255,32'hffffffff,{W{1'b1}},0,0,0,0,0);
            expected(5,255,0,0,0,0,0,0,0);
        end
    endtask
    always @(posedge clk)if(!rst)begin
        tick=tick+1;
        if(cv && cr)begin start_tick=tick;awaiting=1;end
        if(rv && awaiting)begin
            if(tick-start_tick>BOUND)$fatal(1,"first-valid bound");
            if(tick-start_tick>max_latency)max_latency=tick-start_tick;awaiting=0;
        end
        if(source_held && (!cv || command!==held_source))$fatal(1,"command changed while blocked");
        if(response_held && (!rv || response!==held_response))$fatal(1,"response changed while held");
        source_held=cv && !cr;held_source=command;response_held=rv && !rr;held_response=response;
        if(cv && !cr)blocked=blocked+1;if(rv && !rr)held=held+1;
        if(dut.state==9)applications=applications+1;
        if(dut.state==11 && dut.invalidate_context!=dut.context_q && dut.active[dut.invalidate_context] && dut.invalidate_bit_q)invalidations=invalidations+1;
        if(rv && rr && fd!=0)begin
            $fwrite(fd,"%h",response);
            for(j=0;j<N;j=j+1)$fwrite(fd," %h",dut.committed[j]);
            for(j=0;j<C;j=j+1)begin
                $fwrite(fd," %h %h %h",dut.active[j],dut.conflicted[j],dut.write_count[j]);
                for(k=0;k<N;k=k+1)$fwrite(fd," %h %h %h %h",dut.active[j]?dut.read_mask[j*N+k]:1'b0,
                    dut.active[j]?dut.write_mask[j*N+k]:1'b0,(dut.active[j] && dut.read_mask[j*N+k])?dut.read_log[j*N+k]:W'(0),
                    (dut.active[j] && dut.write_mask[j*N+k])?dut.write_log[j*N+k]:W'(0));
            end
            $fwrite(fd,"\n");received=received+1;
        end
        if(tick>10000000)$fatal(1,"finite total watchdog");
    end
    initial begin
        for(phase=0;phase<22;phase=phase+1)if((phase!=16 || N>1) && ((phase!=17 && phase!=19) || C>1))begin
            @(negedge clk);reset_now();
            if(phase!=0 && phase!=14)begin
                while(!cr)@(negedge clk);
                if(phase==17 || phase==19)begin
                    expected(0,C-1,0,0,0,0,0,1,0);expected(1,C-1,0,0,0,0,0,1,0);
                end
                if((phase>=3 && phase<=12) || phase==16 || phase==17 || phase==19 || phase==20 || phase==21)
                    expected(0,0,0,0,0,0,0,1,0);
                if((phase>=7 && phase<=12) || phase==16 || phase==17 || phase==19 || phase==20)begin
                    expected(2,0,0,{W{1'b1}},0,0,0,1,0);
                    if(N>1)expected(2,0,N-1,1,0,0,0,1,0);
                end
                if(phase==19)expected(3,0,0,0,0,0,(N>1)?2:1,0,0);
                if(phase==21)expected(1,0,0,0,0,0,0,1,0);
                if(phase==2 || phase==15)send(word(0,0,0,0));
                else if(phase==3 || phase==4 || phase==5 || phase==20 || phase==21)send(word(1,0,0,0));
                else if(phase==6)send(word(2,0,0,1));
                else if((phase>=7 && phase<=12) || phase==16 || phase==17)send(word(3,0,0,0));
                else if(phase==13 || phase==18)send(word(7,255,32'hffffffff,0));
                else if(phase==19)send(word(1,C-1,0,0));
            end
            target=phase<14?phase:phase==14?0:phase==15?2:phase==16?9:phase==17?11:13;guard=0;
            while(dut.state!=target || (phase==14 && dut.init_index!=C*N/2) || (phase==15 && dut.sweep!=N/2) ||
                (phase==16 && dut.address_q!=N-1) || (phase==17 && dut.invalidate_context!=C-1))begin
                @(negedge clk);guard=guard+1;if(guard>BOUND+C*N+20)$fatal(1,"unreachable reset phase=%0d state=%0d",phase,dut.state);
            end
            if(phase>=18)begin
                command=word(0,0,0,0);cv=1;repeat(4)@(negedge clk);if(!rv || cr)$fatal(1,"held reset fixture");
            end
            reset_now();resets=resets+1;fresh();
        end
        if(!$value$plusargs("INPUT=%s",inpath) || !$value$plusargs("OUTPUT=%s",outpath) || !$value$plusargs("COUNT=%d",count))$fatal;
        $readmemh(inpath,inputs,0,count-1);fd=$fopen(outpath,"w");
        fork
            begin for(i=0;i<count;i=i+1)begin if(i%7==2)@(negedge clk);send(inputs[i]);end end
            begin while(received<count)begin
                @(negedge clk);if(rv && hold_age<4)begin rr=0;hold_age=hold_age+1;end else rr=(tick%7!=1 && tick%7!=2);
                if(!rv || (rv && rr))hold_age=0;
            end end
        join
        @(negedge clk);$fclose(fd);
        if(blocked==0 || held==0 || received!=count)$fatal(1,"finite coverage");
        $display("PASS txn commands=%0d cycles=%0d blocked=%0d held=%0d resets=%0d recovery=%0d max_latency=%0d bound=%0d applications=%0d invalidations=%0d",received,tick,blocked,held,resets,recovery,max_latency,BOUND,applications,invalidations);
        $finish;
    end
endmodule
