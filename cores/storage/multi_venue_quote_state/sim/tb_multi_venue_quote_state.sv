// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_multi_venue_quote_state;
    parameter integer S=5,V=3,T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,rr=0;wire cr,rv,busy;
    reg [3:0] op=0;reg [31:0] sym=0,venue_id=0,bp=0,ap=0;
    reg [63:0] epoch=0,seq=0;reg bv=0,av=0;reg [37:0] bq=0,aq=0;reg [T-1:0] tag=0;
    wire [3:0] ro,rs;wire [31:0] rsy,rve,rbp,rap;
    wire [63:0] rep,rseq,previous;wire has_previous,qvalid,rb,ra,locked,crossed;
    wire [40:0] rbq,raq;wire [7:0] rbs,ras;wire [T-1:0] rtag;
    wire [431+T:0] response={ro,rs,rsy,rve,rep,rseq,has_previous,previous,qvalid,rb,ra,rbp,rap,rbq,raq,rbs,ras,locked,crossed,rtag};
    reg [431+T:0] expected,future_expected,held;
    reg [31:0] future_symbol;
    integer fd,ret,kind,i,latency,commands=0,holds=0,preoffers=0,futures=0,resets=0,watchdog=0;
    reg [2047:0] vector_file;
    multi_venue_quote_state #(.SYMBOLS(S),.VENUES(V),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(op),.c_symbol(sym),.c_venue(venue_id),.c_epoch(epoch),.c_sequence(seq),
        .c_bid_valid(bv),.c_ask_valid(av),.c_bid_price(bp),.c_ask_price(ap),.c_bid_quantity(bq),.c_ask_quantity(aq),.c_tag(tag),
        .r_valid(rv),.r_ready(rr),.r_op(ro),.r_status(rs),.r_symbol(rsy),.r_venue(rve),.r_epoch(rep),.r_sequence(rseq),
        .r_has_previous(has_previous),.r_previous_sequence(previous),.r_quote_valid(qvalid),.r_bid_valid(rb),.r_ask_valid(ra),
        .r_bid_price(rbp),.r_ask_price(rap),.r_bid_quantity(rbq),.r_ask_quantity(raq),.r_bid_sources(rbs),.r_ask_sources(ras),
        .r_locked(locked),.r_crossed(crossed),.r_tag(rtag),.busy(busy));
    task tick;begin @(posedge clk);#1;end endtask
    task reset_here;
        begin rst=1;cv=0;rr=0;tick();if(cr||rv||busy)$fatal(1,"reset gate");
            @(negedge clk);rst=0;tick();resets=resets+1;if(!cr||rv||busy)$fatal(1,"reset idle");end
    endtask
    task reset;begin @(negedge clk);reset_here();end endtask
    task transact;
        begin
            future_symbol=sym<S?sym:0;
            @(negedge clk);cv=1;rr=0;if(!cr)$fatal(1,"admission");tick();commands=commands+1;latency=0;
            @(negedge clk);op=4;sym=future_symbol;venue_id=32'hffffffff;epoch=64'hffffffffffffffff;seq=64'hffffffffffffffff;tag=0;
            while(!rv)begin if(cr)$fatal(1,"early future admission");tick();preoffers=preoffers+1;latency=latency+1;
                if(latency>2*V+8)$fatal(1,"first-valid budget");end
            if(response!==expected)$fatal(1,"response #%0d got=%h expected=%h",commands,response,expected);
            held=response;
            repeat(6)begin tick();holds=holds+1;preoffers=preoffers+1;
                if(!rv||cr||!busy||response!==held)$fatal(1,"held response");end
            @(negedge clk);rr=1;tick();if(rv||!cr)$fatal(1,"retirement");
            @(negedge clk);rr=0;tick();commands=commands+1;futures=futures+1;latency=0;
            @(negedge clk);cv=0;
            while(!rv)begin tick();latency=latency+1;if(latency>2*V+8)$fatal(1,"future budget");end
            if(response!==future_expected)$fatal(1,"future QUERY #%0d got=%h expected=%h",commands,response,future_expected);
            held=response;repeat(6)begin tick();holds=holds+1;if(!rv||cr||!busy||response!==held)$fatal(1,"future hold");end
            @(negedge clk);rr=1;tick();if(rv||!cr)$fatal(1,"future retire");
            @(negedge clk);rr=0;
        end
    endtask
    task empty_expected(input [3:0] eop,estatus,input [63:0] eepoch,esequence);
        begin expected={eop,estatus,32'd0,32'd0,eepoch,esequence,1'b0,64'd0,3'd0,64'd0,82'd0,16'd0,2'd0,{T{1'b0}}};
            expected[T-1:0]=1;
            future_expected={4'd4,4'd0,32'd0,32'hffffffff,64'hffffffffffffffff,64'hffffffffffffffff,1'b0,64'd0,
                1'b1,2'd0,64'd0,82'd0,16'd0,2'd0,{T{1'b0}}};end
    endtask
    task reset_phase(input integer cycles);
        begin
            @(negedge clk);op=0;sym=0;venue_id=0;epoch=1;seq=0;tag=1;bv=0;av=0;empty_expected(0,0,1,0);transact();
            @(negedge clk);op=3;sym=0;venue_id=0;epoch=1;seq=1;tag=1;bv=1;av=0;bp=100;bq=1;cv=1;tick();
            @(negedge clk);cv=0;if(cycles==0)reset_here();else begin repeat(cycles)tick();reset();end
            @(negedge clk);op=2;sym=0;venue_id=0;epoch=1;seq=0;tag=1;empty_expected(2,3,1,0);transact();
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",vector_file))$fatal(1,"vectors missing");
        fd=$fopen(vector_file,"r");if(!fd)$fatal(1,"vector open");reset();
        while(!$feof(fd))begin ret=$fscanf(fd,"%d",kind);if(ret==1)begin
            if(kind==1)reset();else begin
                ret=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %h %h\n",op,sym,venue_id,epoch,seq,bv,av,bp,ap,bq,aq,tag,expected,future_expected);
                if(ret!=14)$fatal(1,"vector parse");transact();end
        end end
        $fclose(fd);reset_phase(0);reset_phase(1);reset_phase(2*V+2);reset_phase(2*V+4);
        $display("PASS multi_venue_quote_state S=%0d V=%0d T=%0d commands=%0d holds=%0d preoffers=%0d futures=%0d resets=%0d",S,V,T,commands,holds,preoffers,futures,resets);$finish;
    end
    always @(posedge clk)begin watchdog=watchdog+1;if(watchdog>200000)$fatal(1,"watchdog");end
endmodule
