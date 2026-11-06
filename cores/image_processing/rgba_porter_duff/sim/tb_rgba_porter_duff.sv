// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_rgba_porter_duff;
    parameter integer T=8;
    localparam integer N=2048,IW=100+T,OW=70+T;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,sv=0,mr=0;
    wire sr,mv,busy;
    reg [IW-1:0] si=0;
    wire [OW-1:0] mo;
    reg [IW-1:0] inputs[0:N-1];reg [OW-1:0] golden[0:N-1];
    rgba_porter_duff #(.TAG_W(T)) dut(.clk(clk),.rst(rst),.s_valid(sv),.s_ready(sr),
        .s_src(si[31:0]),.s_dst(si[63:32]),.s_mode(si[67:64]),.s_x(si[83:68]),.s_y(si[99:84]),.s_tag(si[IW-1:100]),
        .m_valid(mv),.m_ready(mr),.m_rgba(mo[31:0]),.m_error(mo[33:32]),.m_mode(mo[37:34]),
        .m_x(mo[53:38]),.m_y(mo[69:54]),.m_tag(mo[OW-1:70]),.pipeline_busy(busy));
    integer checked=0,resets=0,holds=0,gaps=0,quant=0,cycles=0;
    reg out_hold=0,in_hold=0;reg [OW-1:0] held_out;reg [IW-1:0] held_in;
    always @(posedge clk)begin
        cycles=cycles+1;if(cycles>40000)$fatal(1,"core watchdog");
        if(rst)begin out_hold=0;in_hold=0;end
        else begin
            if(out_hold && (!mv || mo!==held_out))$fatal(1,"output changed while held");
            if(in_hold && (!sv || si!==held_in))$fatal(1,"source driver violated hold");
            out_hold=mv&&!mr;held_out=mo;in_hold=sv&&!sr;held_in=si;
            if(mv&&!mr)holds=holds+1;
        end
    end
    task reset_now;
        begin @(negedge clk);rst=1;sv=0;mr=0;@(negedge clk);rst=0;resets=resets+1;end
    endtask
    task traffic(input integer pattern);
        integer sent,received,ticks,last_output,source_pending;
        begin
            sent=0;received=0;ticks=0;last_output=-1;source_pending=0;
            while(received<N)begin
                @(negedge clk);
                mr=pattern==0 || ticks%11>=4;
                if(!source_pending)begin
                    sv=sent<N && (pattern==0 || ticks%7!=1 && ticks%7!=2);
                    if(sv)si=inputs[sent];else if(sent<N)gaps=gaps+1;
                end
                @(posedge clk);
                if(sv&&sr)begin sent=sent+1;source_pending=0;end
                else source_pending=sv;
                if(mv&&mr)begin
                    if(mo!==golden[received])$fatal(1,"core mismatch pattern=%0d index=%0d got=%h expected=%h",pattern,received,mo,golden[received]);
                    if(pattern==0 && last_output>=0 && ticks!=last_output+1)$fatal(1,"II1 output burst interrupted");
                    if(mo[33:32]==0 && (mo[31:24]>mo[7:0] || mo[23:16]>mo[7:0] || mo[15:8]>mo[7:0]))$fatal(1,"premult closure");
                    last_output=ticks;received=received+1;checked=checked+1;
                end
                ticks=ticks+1;
            end
            @(negedge clk);sv=0;mr=1;
            repeat(5)begin @(posedge clk);if(mv)$fatal(1,"extra core output");end
        end
    endtask
    task flush_stage(input integer count);
        integer i;
        begin
            @(negedge clk);sv=1;mr=0;si=inputs[0];
            for(i=0;i<count;i=i+1)begin @(posedge clk);if(!sr)$fatal(1,"unexpected reset setup stall");@(negedge clk);end
            sv=0;rst=1;@(negedge clk);rst=0;mr=1;resets=resets+1;
            repeat(5)begin @(posedge clk);if(mv||busy)$fatal(1,"reset failed to flush");end
        end
    endtask
    integer total,expect_q;
    initial begin
        $readmemh("input.hex",inputs);$readmemh("golden.hex",golden);
        for(total=0;total<=130050;total=total+1)begin
            expect_q=(total+127)/255;if(expect_q>255)expect_q=255;
            if(dut.quantize(total[16:0])!==8'(expect_q))$fatal(1,"quantizer total=%0d",total);
            quant=quant+1;
        end
        reset_now();traffic(0);traffic(1);flush_stage(1);flush_stage(2);flush_stage(3);
        if(checked!=4096 || resets!=4 || holds==0 || gaps==0)$fatal(1,"core coverage counters");
        $display("PASS RGBA_PD_CORE T=%0d checked=%0d resets=%0d quant=%0d holds=%0d gaps=%0d",T,checked,resets,quant,holds,gaps);$finish;
    end
endmodule
