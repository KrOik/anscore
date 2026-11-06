// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_dual_venue_l2_quote;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,rr=0;wire cr,rv,busy;
    reg [2:0] op=0;reg [31:0] venue_id=0;reg [63:0] epoch=0,seq=0;reg [7:0] tag=0;
    reg remove_valid=0,remove_sell=0,add_valid=0,add_sell=0;
    reg [31:0] remove_price=0,remove_quantity=0,add_price=0,add_quantity=0;
    wire [2:0] ro;wire [31:0] rvenue,bp,ap;wire [63:0] rep,rseq;wire [7:0] rtag,bs,ass;
    wire [3:0] qs,ls,iso;wire touched,disabled,qvalid,bv,av,locked,crossed;
    wire [40:0] bq,aq;
    wire [351:0] response={ro,rvenue,rep,rseq,rtag,qs,ls,iso,touched,disabled,qvalid,bv,av,bp,ap,bq,aq,bs,ass,locked,crossed};
    reg [351:0] expected,held;
    reg [2:0] saved_op;reg [31:0] saved_venue;reg [63:0] saved_epoch,saved_sequence;reg [7:0] saved_tag;
    integer accepted=0,checked=0,futures=0,holds=0,blocked=0,resets=0,checked_l2=0,disabled_results=0,watchdog=0,latency=0;
    dual_venue_l2_quote dut(
        .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(op),.c_venue(venue_id),.c_epoch(epoch),.c_sequence(seq),
        .c_remove_valid(remove_valid),.c_remove_sell(remove_sell),.c_remove_price(remove_price),.c_remove_quantity(remove_quantity),
        .c_add_valid(add_valid),.c_add_sell(add_sell),.c_add_price(add_price),.c_add_quantity(add_quantity),.c_tag(tag),
        .r_valid(rv),.r_ready(rr),.r_op(ro),.r_venue(rvenue),.r_epoch(rep),.r_sequence(rseq),.r_tag(rtag),
        .r_quote_status(qs),.r_l2_status(ls),.r_isolation_status(iso),.r_l2_touched(touched),.r_disabled(disabled),
        .r_quote_valid(qvalid),.r_bid_valid(bv),.r_ask_valid(av),.r_bid_price(bp),.r_ask_price(ap),.r_bid_quantity(bq),.r_ask_quantity(aq),
        .r_bid_sources(bs),.r_ask_sources(ass),.r_locked(locked),.r_crossed(crossed),.busy(busy));
    task tick;begin @(posedge clk);#1;end endtask
    task reset_here;
        begin rst=1;cv=0;rr=0;tick();if(cr||rv||busy)$fatal(1,"reset gate");
            @(negedge clk);rst=0;tick();resets=resets+1;if(!cr||rv||busy)$fatal(1,"reset idle");end
    endtask
    task reset;begin @(negedge clk);reset_here();end endtask
    task launch(input [2:0] operation,input [31:0] source_id,input [63:0] ep,sequence_id,
        input rem,rem_side,input [31:0] rem_price,rem_qty,input add,add_side,input [31:0] addprice,addqty);
        begin
            @(negedge clk);op=operation;venue_id=source_id;epoch=ep;seq=sequence_id;tag=(accepted*17+1);
            remove_valid=rem;remove_sell=rem_side;remove_price=rem_price;remove_quantity=rem_qty;
            add_valid=add;add_sell=add_side;add_price=addprice;add_quantity=addqty;cv=1;rr=0;
            if(!cr)$fatal(1,"launch blocked");
            saved_op=op;saved_venue=venue_id;saved_epoch=epoch;saved_sequence=seq;saved_tag=tag;
            tick();accepted=accepted+1;@(negedge clk);cv=0;
        end
    endtask
    task finish(input [3:0] eqs,els,eiso,input etouch,edisable,eqvalid,
        input eb,ea,input [31:0] ebp,eap,input [40:0] ebq,eaq,input [7:0] ebs,eas);
        begin
            latency=0;while(!rv)begin tick();latency=latency+1;if(latency>64)$fatal(1,"example first-valid budget");end
            expected={saved_op,saved_venue,saved_epoch,saved_sequence,saved_tag,eqs,els,eiso,etouch,edisable,eqvalid,
                eqvalid&&eb,eqvalid&&ea,eqvalid?ebp:32'd0,eqvalid?eap:32'd0,eqvalid?ebq:41'd0,eqvalid?eaq:41'd0,
                eqvalid?ebs:8'd0,eqvalid?eas:8'd0,eqvalid&&eb&&ea&&ebp==eap,eqvalid&&eb&&ea&&ebp>eap};
            if(response!==expected)$fatal(1,"example response #%0d got=%h expected=%h",checked,response,expected);
            checked=checked+1;if(touched)checked_l2=checked_l2+1;if(disabled)disabled_results=disabled_results+1;
            held=response;
            @(negedge clk);op=3;venue_id=32'hffffffff;epoch=64'hffffffffffffffff;seq=64'hffffffffffffffff;tag=0;cv=1;
            repeat(4)begin tick();holds=holds+1;blocked=blocked+1;if(!rv||cr||!busy||response!==held)$fatal(1,"held result owner");end
            @(negedge clk);rr=1;tick();if(rv||!cr)$fatal(1,"result retire");
            @(negedge clk);rr=0;tick();accepted=accepted+1;futures=futures+1;
            @(negedge clk);cv=0;latency=0;
            while(!rv)begin tick();latency=latency+1;if(latency>64)$fatal(1,"future QUERY budget");end
            expected={3'd3,32'hffffffff,64'hffffffffffffffff,64'hffffffffffffffff,8'd0,12'd0,2'd0,
                1'b1,eb,ea,ebp,eap,ebq,eaq,ebs,eas,eb&&ea&&ebp==eap,eb&&ea&&ebp>eap};
            if(response!==expected)$fatal(1,"future consolidated quote #%0d got=%h expected=%h",checked,response,expected);
            checked=checked+1;held=response;
            repeat(4)begin tick();holds=holds+1;if(!rv||cr||!busy||response!==held)$fatal(1,"future QUERY hold");end
            @(negedge clk);rr=1;tick();if(rv||!cr)$fatal(1,"future QUERY retire");@(negedge clk);rr=0;
        end
    endtask
    task config_clean;
        begin launch(0,0,1,0,0,0,0,0,0,0,0,0);finish(0,0,0,1,0,0,0,0,0,0,0,0,0,0);end
    endtask
    task reset_probe(input integer which);
        integer steps;
        begin
            if(which==0)launch(0,0,12,0,0,0,0,0,0,0,0,0);
            else if(which==4)launch(3,0,0,0,0,0,0,0,0,0,0,0);
            else launch(2,0,1,1,0,0,0,0,1,0,100,1);
            steps=0;
            while(!((which==0&&dut.phase==0&&dut.state==3)||
                    (which==1&&dut.phase==2&&dut.quotes.state==2)||
                    (which==2&&dut.phase==2&&dut.venue[0].book.state==9)||
                    (which==3&&dut.phase==3&&dut.quotes.state==5)||
                    (which==4&&rv)))begin
                @(negedge clk);steps=steps+1;if(steps>100)$fatal(1,"missing reset phase %0d",which);
            end
            if(which==4)repeat(3)begin tick();holds=holds+1;end
            if(which==4)@(negedge clk);
            reset_here();config_clean();
        end
    endtask
    initial begin
        reset();
        launch(3,32'hffffffff,0,0,0,0,0,0,0,0,0,0);finish(0,0,0,0,0,1,0,0,0,0,0,0,0,0);
        launch(2,0,0,0,0,0,0,0,1,0,100,5);finish(3,0,0,0,0,0,0,0,0,0,0,0,0,0);
        launch(0,0,10,0,0,0,0,0,0,0,0,0);finish(0,0,0,1,0,0,0,0,0,0,0,0,0,0);
        launch(0,1,20,0,0,0,0,0,0,0,0,0);finish(0,0,0,1,0,0,0,0,0,0,0,0,0,0);
        launch(2,0,10,10,0,0,0,0,1,0,100,5);finish(0,0,0,1,0,1,1,0,100,0,5,0,1,0);
        launch(2,1,20,20,0,0,0,0,1,0,100,7);finish(0,0,0,1,0,1,1,0,100,0,12,0,3,0);
        launch(2,0,10,10,0,0,0,0,1,0,100,5);finish(6,0,0,0,0,0,1,0,100,0,12,0,3,0);
        launch(2,0,10,11,0,0,0,0,1,0,100,1);finish(0,0,0,1,0,1,1,0,100,0,13,0,3,0);
        launch(2,1,20,21,0,0,0,0,1,1,103,4);finish(0,0,0,1,0,1,1,1,100,103,13,4,3,2);
        launch(0,0,10,0,0,0,0,0,0,0,0,0);finish(5,0,0,0,0,0,1,1,100,103,13,4,3,2);
        launch(2,0,10,12,0,0,0,0,1,0,100,1);finish(0,0,0,1,0,1,1,1,100,103,14,4,3,2);
        launch(2,1,20,22,1,0,100,100,0,0,0,0);finish(0,3,0,1,1,0,1,0,100,0,7,0,1,0);
        launch(2,1,20,23,0,0,0,0,1,0,100,1);finish(4,0,0,0,0,0,1,0,100,0,7,0,1,0);
        launch(3,0,0,0,0,0,0,0,0,0,0,0);finish(0,0,0,0,0,1,1,0,100,0,7,0,1,0);
        launch(0,1,21,0,0,0,0,0,0,0,0,0);finish(0,0,0,1,0,0,1,0,100,0,7,0,1,0);
        launch(2,1,20,64'hffffffffffffffff,0,0,0,0,1,0,100,1);finish(5,0,0,0,0,0,1,0,100,0,7,0,1,0);
        launch(2,1,21,0,0,0,0,0,1,0,100,2);finish(0,0,0,1,0,1,1,0,100,0,9,0,3,0);
        launch(2,1,21,1,0,0,0,0,1,1,100,1);finish(0,0,0,1,0,1,1,1,100,100,9,1,3,2);
        launch(2,0,10,13,0,0,0,0,1,0,101,3);finish(0,0,0,1,0,1,1,1,101,100,3,1,1,2);
        launch(1,0,0,0,0,0,0,0,0,0,0,0);finish(0,0,0,0,1,0,1,1,100,100,2,1,2,2);
        launch(0,0,11,0,0,0,0,0,0,0,0,0);finish(0,0,0,1,0,0,1,1,100,100,2,1,2,2);
        launch(2,0,11,0,0,0,0,0,1,0,100,32'hffffffff);finish(0,0,0,1,0,1,1,1,100,100,41'd4294967297,1,3,2);
        launch(2,0,11,1,0,0,0,0,1,0,100,32'hffffffff);finish(0,0,0,1,0,1,1,1,100,100,41'd8589934592,1,3,2);
        launch(2,0,11,2,1,0,100,32'hffffffff,1,0,100,1);finish(0,0,0,1,0,1,1,1,100,100,41'd4294967298,1,3,2);
        launch(2,32'hffffffff,11,3,0,0,0,0,1,0,100,1);finish(2,0,0,0,0,0,1,1,100,100,41'd4294967298,1,3,2);
        launch(7,0,0,0,0,0,0,0,0,0,0,0);finish(9,0,0,0,0,0,1,1,100,100,41'd4294967298,1,3,2);
        launch(3,32'hffffffff,0,0,0,0,0,0,0,0,0,0);finish(0,0,0,0,0,1,1,1,100,100,41'd4294967298,1,3,2);
        reset_probe(0);reset_probe(1);reset_probe(2);reset_probe(3);reset_probe(4);
        launch(3,0,0,0,0,0,0,0,0,0,0,0);finish(0,0,0,0,0,1,0,0,0,0,0,0,0,0);
        $display("PASS dual_venue_l2_quote accepted=%0d checked=%0d futures=%0d holds=%0d blocked=%0d resets=%0d checked_l2=%0d disabled_results=%0d",accepted,checked,futures,holds,blocked,resets,checked_l2,disabled_results);$finish;
    end
    always @(posedge clk)begin watchdog=watchdog+1;if(watchdog>30000)$fatal(1,"watchdog");end
endmodule
