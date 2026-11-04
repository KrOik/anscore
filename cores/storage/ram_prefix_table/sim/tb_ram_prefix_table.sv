`timescale 1ns/1ps
module tb_ram_prefix_table;
    parameter S=3,K=5,V=7,T=3;
    localparam PW=K>1?$clog2(K+1):1,CW=S>1?$clog2(S+1):1,IW=S>1?$clog2(S):1;
    localparam EW=1+K+PW+V,INW=2+K+32+V+T,OUTW=4+K+PW+V+CW+T,BOUND=2*S+4;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,rr=0;
    reg [INW-1:0] command=0;
    wire cr,rv,found,inserted;wire [1:0] status;
    wire [K-1:0] prefix;wire [PW-1:0] length;
    wire [V-1:0] value;wire [CW-1:0] occupancy;wire [T-1:0] tag;
    ram_prefix_table #(.SLOTS(S),.KEY_W(K),.VALUE_W(V),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(command[INW-1 -:2]),
        .c_key(command[T+V+32 +:K]),.c_length(command[T+V +:32]),
        .c_value(command[T +:V]),.c_tag(command[T-1:0]),
        .r_valid(rv),.r_ready(rr),.r_status(status),.r_found(found),.r_inserted(inserted),
        .r_prefix(prefix),.r_length(length),.r_value(value),.r_count(occupancy),.r_tag(tag));
    wire [OUTW-1:0] response={status,found,inserted,prefix,length,value,occupancy,tag};
    reg [INW-1:0] inputs[0:30000],held_source;
    reg [OUTW-1:0] held_response;
    reg source_held=0,response_held=0,awaiting=0;
    integer tick=0,accepted_tick=0,max_latency=0,blocked=0,held=0,received=0,resets=0;
    integer recovery_commands=0,snapshot_slots=0,fd=0,count,outcount,i,j,guard,phase,target,hold_age=0;
    string inpath,outpath;
    function automatic [INW-1:0] word(input [1:0] op,input [K-1:0] key,input [31:0] len,
                                      input [V-1:0] val,input [T-1:0] tok);
        word={op,key,len,val,tok};
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
    task expected(input [INW-1:0] w,input [1:0] st,input f,ins,
                  input [K-1:0] p,input [PW-1:0] l,input [V-1:0] v,input [CW-1:0] c);
        integer g,live_count,q;
        reg [OUTW-1:0] want;
        begin
            send_word(w);g=0;
            while(!rv)begin @(negedge clk);g=g+1;if(g>BOUND)$fatal(1,"recovery timeout");end
            want={st,f,ins,p,l,v,c,w[T-1:0]};
            if(response!==want)$fatal(1,"fresh response got=%h want=%h",response,want);
            live_count=0;
            for(q=0;q<S;q=q+1)if(dut.entries[q][EW-1])live_count=live_count+1;
            if(live_count!=c)$fatal(1,"fresh physical count");
            repeat(4)@(negedge clk);
            if(response!==want || !rv)$fatal(1,"fresh response hold");
            rr=1;@(posedge clk);@(negedge clk);rr=0;recovery_commands=recovery_commands+1;
        end
    endtask
    task fresh;
        reg [K-1:0] allkey;reg [V-1:0] av,bv;reg [T-1:0] tok;integer q;
        begin
            allkey={K{1'b1}};av={V{1'b1}};bv=0;tok={T{1'b1}};
            // Fully initialize, insert/query/replace/delete real state after every cancellation.
            expected(word(0,allkey,32'hffffffff,0,tok),1,0,0,0,0,0,0);
            for(q=0;q<S;q=q+1)if(dut.entries[q]!==0)$fatal(1,"fresh sweep stale row");
            expected(word(1,allkey,0,av,tok),0,0,1,0,0,0,1);
            expected(word(0,allkey,0,0,tok),0,1,0,0,0,av,1);
            expected(word(1,0,0,bv,tok),0,1,0,0,0,av,1);
            if(S>1)begin
                expected(word(1,allkey,K,av,tok),0,0,1,0,0,0,2);
                expected(word(0,allkey,0,0,tok),0,1,0,allkey,K,av,2);
                expected(word(2,allkey,K,0,tok),0,1,0,allkey,K,av,1);
            end
            expected(word(0,allkey,0,0,tok),0,1,0,0,0,bv,1);
            expected(word(2,allkey,0,0,tok),0,1,0,0,0,bv,0);
            expected(word(0,allkey,0,0,tok),1,0,0,0,0,0,0);
            expected(word(3,allkey,32'hffffffff,av,tok),0,0,0,0,0,0,0);
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
        if(rv && rr && fd!=0)begin
            $fwrite(fd,"%h",response);
            for(j=0;j<S;j=j+1)begin $fwrite(fd," %h",dut.entries[j]);snapshot_slots=snapshot_slots+1;end
            $fwrite(fd,"\n");received=received+1;
        end
        if(tick>10000000)$fatal(1,"finite watchdog");
    end
    initial begin
        // Fixed fourteen phase probes; observation is followed immediately by reset.
        for(phase=0;phase<14;phase=phase+1)begin
            @(negedge clk);reset_now();
            if(phase!=0 && phase!=11)begin
                while(!cr)@(negedge clk);
                if(phase==6 || phase==12 || phase==13)begin
                    expected(word(1,0,0,1,1),0,0,1,0,0,0,1);
                    while(!cr)@(negedge clk);
                end
                if(phase!=1)begin
                    if(phase==6)send_word(word(2,0,0,0,1));
                    else if(phase==9)send_word(word(1,0,32'hffffffff,1,1));
                    else if(phase==13)send_word(word(3,0,0,0,1));
                    else send_word(word(1,0,0,1,1));
                end
            end
            target=phase<8?phase:(phase==8 || phase==9?7:(phase==10?3:(phase==11 || phase==13?0:5)));
            guard=0;
            while(dut.state!=target || ((phase==10 || phase==11 || phase==13) && dut.scan_index!=S/2))begin
                @(negedge clk);guard=guard+1;if(guard>BOUND+S+8)$fatal(1,"unreachable reset phase %0d",phase);
            end
            if(phase==8 || phase==9)begin
                repeat(4)@(negedge clk);
                if(!rv || cr || status!=(phase==9?3:0))$fatal(1,"held reset phase");
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
        $display("PASS prefix responses=%0d cycles=%0d blocked=%0d held=%0d resets=%0d recovery=%0d slots=%0d max_latency=%0d bound=%0d",received,tick,blocked,held,resets,recovery_commands,snapshot_slots,max_latency,BOUND);
        $finish;
    end
endmodule
