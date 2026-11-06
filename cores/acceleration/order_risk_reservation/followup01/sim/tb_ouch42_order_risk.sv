`timescale 1ns/1ps
module tb_ouch42_order_risk;
    reg clk=0;always #5 clk=~clk;
    localparam integer WAIT_LIMIT=1024;
    reg rst_n=0,sv=0,sl=0,cv=0,rr=0;reg [7:0] sd=0;wire sr,cr,rv,faulted;
    reg [3:0] op=0;reg [31:0] ctx=0,qty=0;reg [111:0] token=0;reg buy=1;
    reg signed [63:0] pos=0,lo=-10,hi=10;reg [7:0] tag=0;
    wire venue;wire [7:0] typ;wire [2:0] dec;wire [1:0] stage,phase;
    wire [4:0] status;wire [3:0] ro;wire [111:0] rt;wire [31:0] rc,rq,rl;wire rb;
    wire signed [63:0] rpos;wire [37:0] bo,so;wire [7:0] rtag;
    localparam [111:0] TOKEN=112'h8031323334353637383930313233;
    ouch42_order_risk dut(.clk(clk),.rst_n(rst_n),.s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),.s_tag(8'h71),
        .c_valid(cv),.c_ready(cr),.c_op(op),.c_context(ctx),.c_token(token),.c_buy(buy),.c_quantity(qty),
        .c_position(pos),.c_min_position(lo),.c_max_position(hi),.c_tag(tag),.r_valid(rv),.r_ready(rr),
        .r_venue(venue),.r_type(typ),.r_decode_status(dec),.r_stage(stage),.r_status(status),.r_op(ro),
        .r_token(rt),.r_context(rc),.r_remaining(rq),.r_live(rl),.r_buy(rb),.r_phase(phase),.r_position(rpos),
        .r_buy_open(bo),.r_sell_open(so),.r_tag(rtag),.faulted(faulted));
    reg [7:0] bytes[0:79];integer i,j,checks=0,holds=0,frames=0,resets=0;
    reg [447:0] held;
    function [447:0] response;
        response={venue,typ,dec,stage,status,ro,rt,rc,rq,rl,rb,phase,rpos,bo,so,rtag,faulted};
    endfunction
    task reset_now;
        begin rst_n=0;cv=0;sv=0;sl=0;rr=0;repeat(3)@(posedge clk);@(negedge clk);rst_n=1;resets=resets+1;@(negedge clk);end
    endtask
    task local_command(input [3:0] x,input [31:0] q,input [111:0] t);
        integer waited;
        begin
            op=x;qty=q;token=t;tag=tag+1;cv=1;waited=0;
            do begin
                @(posedge clk);waited=waited+1;
                if(waited>WAIT_LIMIT)$fatal(1,"local deadline check=%0d op=%0d wrapper=%0d core=%0d",checks,x,dut.state,dut.risk.state);
            end while(!cr);
            @(negedge clk);cv=0;
        end
    endtask
    task send_byte(input [7:0] value,input last_value);
        integer waited;
        begin
            sd=value;sl=last_value;sv=1;waited=0;
            do begin
                @(posedge clk);waited=waited+1;
                if(waited>WAIT_LIMIT)$fatal(1,"byte deadline frame=%0d byte=%0d decoder=%0d wrapper=%0d",frames,i,dut.decoder.state,dut.state);
            end while(!sr);
            @(negedge clk);sv=0;sl=0;
        end
    endtask
    task await_result;
        integer waited;
        begin
            waited=0;
            while(!rv)begin
                @(negedge clk);waited=waited+1;
                if(waited>WAIT_LIMIT)$fatal(1,"example result deadline check=%0d type=%h decoder=%0d wrapper=%0d core=%0d ledger=%0d",checks,typ,dut.decoder.state,dut.state,dut.risk.state,dut.risk.ledger.state);
            end
        end
    endtask
    task packet(input [7:0] t,input integer length,input [31:0] q);
        begin
            for(i=0;i<80;i=i+1)bytes[i]=0;
            bytes[0]=t;
            for(i=0;i<14;i=i+1)bytes[9+i]=TOKEN[111-8*i -:8];
            bytes[23]="B";bytes[24]=q[31:24];bytes[25]=q[23:16];bytes[26]=q[15:8];bytes[27]=q[7:0];
            if(t=="C")bytes[27]="U";
            if(t=="C")begin bytes[23]=q[31:24];bytes[24]=q[23:16];bytes[25]=q[15:8];bytes[26]=q[7:0];end
            if(t=="E")begin bytes[23]=q[31:24];bytes[24]=q[23:16];bytes[25]=q[15:8];bytes[26]=q[7:0];end
            if(t=="J")bytes[23]="R";
            bytes[64]="L";
            for(i=0;i<length;i=i+1)begin
                send_byte(bytes[i],i==length-1);
            end
            frames=frames+1;
        end
    endtask
    task check_result(input v,input [4:0] s,input [1:0] st,p,input [31:0] q,
        input signed [63:0] position_expected,input [37:0] open_expected,input f);
        begin
            await_result();
            if(venue!==v||status!==s||stage!==st||phase!==p||rq!==q||rpos!==position_expected||bo!==open_expected||so!==0||faulted!==f)
                $fatal(1,"example mismatch check=%0d type=%h status=%0d/%0d phase=%0d/%0d rem=%0d/%0d pos=%0d/%0d open=%0d/%0d",
                    checks,typ,status,s,phase,p,rq,q,rpos,position_expected,bo,open_expected);
            if(v&&rtag!==8'h71)$fatal(1,"venue tag");
            held=response();repeat(4)begin
                if(cr)$fatal(1,"local accepted under held result");
                @(posedge clk);@(negedge clk);if(!rv||response()!==held)$fatal(1,"held response");holds=holds+1;
            end
            rr=1;@(posedge clk);@(negedge clk);rr=0;checks=checks+1;
        end
    endtask
    task clear_config;
        begin
            local_command(10,0,0);check_result(0,0,0,0,0,0,0,0);
            local_command(0,0,0);check_result(0,0,0,0,0,0,0,0);
        end
    endtask
    initial begin
        reset_now();clear_config();
        local_command(1,8,TOKEN);check_result(0,0,0,1,8,0,8,0);
        packet("A",66,8);check_result(1,0,0,2,8,0,8,0);
        local_command(4,0,TOKEN);check_result(0,0,0,3,8,0,8,0);
        local_command(1,3,TOKEN+1);check_result(0,5,0,0,0,0,0,0);
        packet("E",40,3);check_result(1,0,0,3,5,3,5,0);
        packet("C",28,2);check_result(1,0,0,2,3,3,3,0);
        local_command(4,0,TOKEN);check_result(0,0,0,3,3,3,3,0);
        local_command(6,0,TOKEN);check_result(0,0,0,2,3,3,3,0);
        packet("C",28,3);check_result(1,0,0,0,0,3,0,0);
        packet("E",40,1);check_result(1,7,2,0,0,0,0,1);
        clear_config();
        local_command(1,5,TOKEN);check_result(0,0,0,1,5,0,5,0);
        packet("J",24,0);check_result(1,0,0,0,0,0,0,0);
        packet("J",24,0);check_result(1,7,2,0,0,0,0,1);
        clear_config();
        local_command(1,2,TOKEN);check_result(0,0,0,1,2,0,2,0);
        packet("A",66,1);check_result(1,13,2,0,0,0,0,1);
        if(dut.risk.ledger.context_ram.mem[0][75:38]!==38'd2)$fatal(1,"bad ACK released hold");
        clear_config();local_command(1,1,TOKEN);check_result(0,0,0,1,1,0,1,0);
        packet("U",80,1);check_result(1,17,2,0,0,0,0,1);
        if(dut.risk.ledger.context_ram.mem[0][75:38]!==38'd1)$fatal(1,"unsupported replace released hold");
        clear_config();packet("E",3,1);check_result(1,16,2,0,0,0,0,1);
        reset_now();clear_config();
        local_command(1,2,TOKEN);check_result(0,0,0,1,2,0,2,0);
        packet("A",66,2);await_result();reset_now();
        clear_config();local_command(8,0,TOKEN);check_result(0,7,0,0,0,0,0,0);
        // Reset cancels a partially received message as well as a held result.
        send_byte("E",0);reset_now();
        clear_config();local_command(8,0,TOKEN);check_result(0,7,0,0,0,0,0,0);
        $display("B47_A_EXAMPLE_PASS checks=%0d holds=%0d frames=%0d resets=%0d",checks,holds,frames,resets);$finish;
    end
    initial begin #2000000;$fatal(1,"global example watchdog check=%0d frame=%0d wrapper=%0d core=%0d",checks,frames,dut.state,dut.risk.state);end
endmodule
