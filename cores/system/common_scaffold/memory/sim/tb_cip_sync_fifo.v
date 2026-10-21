`timescale 1ns/1ps
module fifo_case #(parameter DEPTH=3,parameter DW=17)(output reg done=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=1,iv=0,orr=0;
    reg [DW-1:0] id=0;
    wire ir,ov,full,empty;wire [DW-1:0] od;
    localparam LW=DEPTH<2?1:$clog2(DEPTH+1);
    wire [LW-1:0] level;
    reg [DW-1:0] oracle[0:8191];
    integer head=0,tail=0,count=0,i=0,accepted=0,removed=0,full_seen=0,simultaneous=0;
    reg last_accept=0;
    cip_sync_fifo #(.DATA_WIDTH(DW),.DEPTH(DEPTH)) dut(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(iv),.in_ready(ir),.in_data(id),
        .out_valid(ov),.out_ready(orr),.out_data(od),.level(level),.full(full),.empty(empty));
    always @(posedge clk)begin
        last_accept=0;
        if(!rst_n)begin head=0;tail=0;count=0;end
        else begin
            if(level!==count || full!==(count==DEPTH) || empty!==(count==0))
                $fatal(1,"FIFO D=%d accounting count=%d level=%d",DEPTH,count,level);
            if(ov!==(count!=0))$fatal(1,"FIFO validity D=%d",DEPTH);
            if(ov&&od!==oracle[head])$fatal(1,"FIFO ordering D=%d got=%h exp=%h",DEPTH,od,oracle[head]);
            if(full)full_seen=full_seen+1;
            if(ce)begin
                if(ov&&orr)begin head=head+1;count=count-1;removed=removed+1;end
                if(iv&&ir)begin oracle[tail]=id;tail=tail+1;count=count+1;accepted=accepted+1;last_accept=1;end
                if(iv&&ir&&ov&&orr)simultaneous=simultaneous+1;
            end
        end
    end
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        // Fill, full-stall, then replace entries at full occupancy.
        for(i=0;i<DEPTH+8;i=i+1)begin
            @(negedge clk);if(!iv||last_accept)begin iv=1;id=id+1;end
            ce=1;orr=0;
        end
        for(i=0;i<50;i=i+1)begin
            @(negedge clk);if(!iv||last_accept)begin iv=1;id=id+1;end
            ce=1;orr=1;
        end
        for(i=0;i<2000;i=i+1)begin
            @(negedge clk);
            if(!iv||last_accept)begin iv=$urandom_range(0,3)!=0;id=$urandom;end
            ce=$urandom_range(0,3)!=0;orr=$urandom_range(0,2)!=0;
        end
        // Drain any producer request, then drain FIFO itself.
        @(negedge clk);ce=1;orr=1;
        while(iv&&!last_accept)@(negedge clk);
        iv=0;
        repeat(DEPTH+3)@(negedge clk);
        if(count!=0||accepted!=removed||full_seen==0||simultaneous==0)
            $fatal(1,"FIFO insufficient coverage D=%d",DEPTH);
        // Buffered reset must discard queued entries even with clk_en=0.
        iv=1;orr=0;id='h55;
        repeat(DEPTH+2)@(negedge clk);
        rst_n=0;ce=0;iv=0;
        repeat(2)@(negedge clk);
        if(ov!==0||level!==0)$fatal(1,"FIFO reset D=%d",DEPTH);
        rst_n=1;ce=1;orr=1;
        repeat(3)@(negedge clk);
        $display("PASS FIFO depth=%0d width=%0d accepted=%0d full=%0d simultaneous=%0d",DEPTH,DW,accepted,full_seen,simultaneous);
        done=1;
    end
endmodule
module tb_cip_sync_fifo;
    wire a,b,c;
    fifo_case #(.DEPTH(1),.DW(8))one(a);
    fifo_case #(.DEPTH(3),.DW(17))odd(c);
    fifo_case #(.DEPTH(16),.DW(32))normal(b);
    initial begin wait(a&&b&&c);$display("PASS FIFO all configurations");$finish;end
    initial begin #1000000;$fatal(1,"FIFO timeout");end
endmodule
