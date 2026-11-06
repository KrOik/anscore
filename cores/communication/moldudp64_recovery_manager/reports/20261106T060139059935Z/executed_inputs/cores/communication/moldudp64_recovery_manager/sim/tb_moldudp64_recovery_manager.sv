// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_moldudp64_recovery_manager;
    parameter integer N=5,K=7,T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,rr=0;wire cr,rv,busy;
    reg [3:0] op=0;reg [31:0] context_id=0;reg [79:0] session_id=0;
    reg [63:0] seq=0,nxt=0;reg [15:0] count=0;reg [T-1:0] tag=0;
    wire [3:0] ro,rs;wire [31:0] rc;wire configured,outs,closed,emit;
    wire [79:0] sess;wire [63:0] rn,rt,ru,rseq;wire [15:0] amount;wire [T-1:0] rtag;
    wire [395+T:0] response={ro,rs,rc,configured,sess,rn,rt,outs,ru,closed,emit,rseq,amount,rtag};
    reg [395+T:0] expected,future_expected,held;
    integer fd,ret,kind,i,latency,commands=0,holds=0,preoffers=0,futures=0,resets=0,emits=0,watchdog=0;
    reg [2047:0] vector_file;
    moldudp64_recovery_manager #(.CONTEXTS(N),.REQUEST_MAX(K),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(op),.c_context(context_id),
        .c_session(session_id),.c_sequence(seq),.c_next(nxt),.c_messages(count),.c_tag(tag),
        .r_valid(rv),.r_ready(rr),.r_op(ro),.r_status(rs),.r_context(rc),.r_configured(configured),
        .r_session(sess),.r_next(rn),.r_target(rt),.r_outstanding(outs),.r_until(ru),.r_closed(closed),
        .r_emit(emit),.r_request_sequence(rseq),.r_request_count(amount),.r_tag(rtag),.busy(busy));
    task tick;begin @(posedge clk);#1;end endtask
    task reset_here;
        begin rst=1;cv=0;rr=0;tick();
            if(rv||cr||busy)$fatal(1,"reset gating");
            @(negedge clk);rst=0;tick();resets=resets+1;
            if(!cr||rv||busy)$fatal(1,"reset idle");end
    endtask
    task reset;begin @(negedge clk);reset_here();end endtask
    task transact;
        begin
            @(negedge clk);cv=1;rr=0;
            if(!cr)$fatal(1,"admission blocked");tick();commands=commands+1;latency=0;
            @(negedge clk);cv=1;op=5;context_id=0;tag=0;
            while(!rv)begin
                if(cr)$fatal(1,"early future admission");preoffers=preoffers+1;
                tick();latency=latency+1;
                if(latency>5)$fatal(1,"first result budget");
            end
            if(response!==expected)$fatal(1,"response command=%0d got=%h expected=%h",commands,response,expected);
            if(emit)emits=emits+1;held=response;
            for(i=0;i<6;i=i+1)begin
                if(cr||!busy)$fatal(1,"owner during held result");
                tick();holds=holds+1;preoffers=preoffers+1;
                if(!rv||response!==held)$fatal(1,"unstable held response");
            end
            @(negedge clk);rr=1;tick();
            if(rv||!cr)$fatal(1,"retire did not release");
            // The held future GET persists through actual admission, then its
            // independently specified snapshot is checked and retired too.
            @(negedge clk);rr=0;tick();commands=commands+1;futures=futures+1;latency=0;
            @(negedge clk);cv=0;
            while(!rv)begin tick();latency=latency+1;if(latency>5)$fatal(1,"future result budget");end
            if(response!==future_expected)$fatal(1,"future GET snapshot command=%0d got=%h expected=%h",commands,response,future_expected);
            held=response;
            repeat(6)begin tick();holds=holds+1;if(!rv||cr||!busy||response!==held)$fatal(1,"future GET stability");end
            @(negedge clk);rr=1;tick();
            if(rv||!cr)$fatal(1,"future GET retirement");
            @(negedge clk);rr=0;
        end
    endtask
    // Reset aborts configuration before/during RAM access and at its held result.
    task reset_phase(input integer cycles);
        begin
            @(negedge clk);op=0;context_id=0;session_id=80'h1234;nxt=10;count=0;cv=1;tick();
            @(negedge clk);cv=0;
            if(cycles==0)reset_here();
            else begin repeat(cycles)tick();reset();end
            @(negedge clk);op=5;context_id=0;seq=0;nxt=0;count=0;tag=1;
            expected={4'd5,4'd1,32'd0,1'b0,80'd0,64'd0,64'd0,1'b0,64'd0,1'b0,1'b0,64'd0,16'd0,{T{1'b0}}};
            expected[T-1:0]=1;future_expected=expected;future_expected[T-1:0]=0;transact();
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",vector_file))$fatal(1,"vectors missing");
        fd=$fopen(vector_file,"r");if(!fd)$fatal(1,"vector open");reset();
        while(!$feof(fd))begin
            ret=$fscanf(fd,"%d",kind);
            if(ret==1)begin
                if(kind==1)reset();
                else begin
                    ret=$fscanf(fd,"%d %d %d %d %d %d %d %h %h\n",op,context_id,session_id,seq,nxt,count,tag,expected,future_expected);
                    if(ret!=9)$fatal(1,"vector parse");transact();
                end
            end
        end
        $fclose(fd);reset_phase(0);reset_phase(1);reset_phase(4);
        $display("PASS moldudp64_recovery_manager N=%0d K=%0d T=%0d commands=%0d holds=%0d preoffers=%0d futures=%0d resets=%0d emits=%0d",N,K,T,commands,holds,preoffers,futures,resets,emits);$finish;
    end
    always @(posedge clk)begin watchdog=watchdog+1;if(watchdog>100000)$fatal(1,"watchdog");end
endmodule
