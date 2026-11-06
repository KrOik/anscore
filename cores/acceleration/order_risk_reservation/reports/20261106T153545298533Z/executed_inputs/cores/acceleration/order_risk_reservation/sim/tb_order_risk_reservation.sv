`timescale 1ns/1ps
module tb_order_risk_reservation;
    parameter integer A=3,K=5,T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,cv=0,rr=0;wire cr,rv,busy,faulted;
    reg [3:0] op;reg [31:0] ctx,qty;reg [111:0] token;reg buy;
    reg signed [63:0] pos,lo,hi;reg [T-1:0] tag;
    wire [3:0] ro;wire [4:0] rs;wire [111:0] rt;wire [31:0] rc,rq,rl;
    wire rb;wire [1:0] rp;wire signed [63:0] rpos,rlo,rhi;wire [37:0] bo,so;wire [T-1:0] rtag;
    order_risk_reservation #(.CONTEXTS(A),.ORDERS(K),.TAG_W(T)) dut(
        .clk(clk),.rst_n(rst_n),.c_valid(cv),.c_ready(cr),.c_op(op),.c_context(ctx),.c_token(token),
        .c_buy(buy),.c_quantity(qty),.c_position(pos),.c_min_position(lo),.c_max_position(hi),.c_tag(tag),
        .r_valid(rv),.r_ready(rr),.r_op(ro),.r_status(rs),.r_token(rt),.r_context(rc),.r_buy(rb),
        .r_remaining(rq),.r_phase(rp),.r_position(rpos),.r_min_position(rlo),.r_max_position(rhi),
        .r_buy_open(bo),.r_sell_open(so),.r_live(rl),.r_tag(rtag),.busy(busy),.faulted(faulted));
    integer fd,n,rcount,i,j,checks=0,holds=0,blocked=0,resets=0,canceled=0;
    integer es,ep,ec,eb,eq,el,ef;reg signed [63:0] epos,elo,ehi;reg [37:0] ebo,eso;
    reg [3:0] oldop;reg [111:0] oldtoken;reg [T-1:0] oldtag;
    reg [543:0] held;reg [1023:0] filename;
    function [543:0] response;
        response={faulted,ro,rs,rt,rc,rb,rq,rp,rpos,rlo,rhi,bo,so,rl,rtag};
    endfunction
    task read_record;
        begin
            rcount=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                op,ctx,token,buy,qty,pos,lo,hi,tag,es,ep,ec,eb,eq,epos,elo,ehi,ebo,eso,el,ef);
            if(rcount!=21)$fatal(1,"record format rc=%0d",rcount);
        end
    endtask
    task accept;
        begin
            cv=1;
            while(!cr)begin @(posedge clk);@(negedge clk);end
            @(posedge clk);@(negedge clk);cv=0;
        end
    endtask
    task await_result;
        begin while(!rv)begin @(posedge clk);@(negedge clk);end end
    endtask
    task retire;
        begin rr=1;@(posedge clk);@(negedge clk);rr=0;end
    endtask
    task simple(input [3:0] x,input [31:0] q,input [4:0] status);
        begin
            op=x;qty=q;ctx=0;token=112'h8000000000000000000000000011;buy=1;pos=0;lo=-100;hi=100;tag=0;
            accept();await_result();if(rs!==status)$fatal(1,"reset setup op=%0d status=%0d expected=%0d",x,rs,status);retire();
        end
    endtask
    task reset_now;
        begin
            rst_n=0;cv=0;rr=0;#1;if(cr||rv||busy||faulted)$fatal(1,"reset mask");
            repeat(3)@(posedge clk);@(negedge clk);rst_n=1;resets=resets+1;
        end
    endtask
    initial begin
        op=0;ctx=0;qty=0;token=0;buy=0;pos=0;lo=0;hi=0;tag=0;
        reset_now();
        if(!$value$plusargs("vectors=%s",filename))$fatal(1,"vectors missing");
        fd=$fopen(filename,"r");if(!fd)$fatal(1,"open vectors");
        rcount=$fscanf(fd,"%d",n);if(rcount!=1||n<1)$fatal(1,"header");
        read_record();accept();
        for(i=0;i<n;i=i+1)begin
            await_result();oldop=op;oldtoken=token;oldtag=tag;
            if(ro!==oldop||rt!==oldtoken||rtag!==oldtag||rs!==es[4:0]||rp!==ep[1:0]||rc!==ec||rb!==eb[0]||
                rq!==eq||rpos!==epos||rlo!==elo||rhi!==ehi||bo!==ebo||so!==eso||rl!==el||faulted!==ef[0])
                $fatal(1,"oracle mismatch case=%0d op=%0d status=%0d/%0d phase=%0d/%0d qty=%0d/%0d",i,op,rs,es,rp,ep,rq,eq);
            checks=checks+1;held=response();
            if(i+1<n)begin read_record();cv=1;end
            repeat(4)begin
                if(cr)$fatal(1,"admitted while held");
                @(posedge clk);@(negedge clk);
                if(!rv||response()!==held)$fatal(1,"held changed");holds=holds+1;
                if(cv)blocked=blocked+1;
            end
            retire();
            if(i+1<n)begin
                while(!cr)begin @(posedge clk);@(negedge clk);end
                @(posedge clk);@(negedge clk);cv=0;
            end
        end
        rcount=$fscanf(fd,"%d",j);if(!((rcount==0||rcount==-1)&&$feof(fd)))$fatal(1,"suffix rc=%0d",rcount);
        $fclose(fd);
        for(j=0;j<4;j=j+1)begin
            reset_now();simple(0,0,0);simple(1,8,0);simple(2,8,0);
            op=(j==3)?5:4;qty=2;cv=1;
            while(!cr)begin @(posedge clk);@(negedge clk);end
            @(posedge clk);@(negedge clk);cv=0;
            if(j==0)begin while(dut.state!=3)@(negedge clk);end
            if(j==1)begin while(dut.state!=4)@(negedge clk);end
            if(j==2)await_result();
            if(j==3)begin while(!(dut.second&&dut.state==3))@(negedge clk);end
            reset_now();canceled=canceled+1;
            simple(8,0,7);simple(9,0,2);
        end
        $display("B47_A_CORE_PASS records=%0d checks=%0d holds=%0d blocked=%0d resets=%0d canceled=%0d",n,checks,holds,blocked,resets,canceled);
        $finish;
    end
    initial begin #200000000;$fatal(1,"watchdog");end
endmodule
