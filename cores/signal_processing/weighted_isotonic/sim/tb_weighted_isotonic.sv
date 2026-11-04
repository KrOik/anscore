// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_weighted_isotonic;
    parameter integer DATA_W=16,WEIGHT_W=8,MAX_LEN=16,TAG_W=8,BEATS=1,TOKENS=1,FRAMES=1;
    localparam integer L=(MAX_LEN<2)?0:$clog2(MAX_LEN),CW=(MAX_LEN<2)?1:$clog2(MAX_LEN+1);
    localparam integer SW=DATA_W+WEIGHT_W+1+L,TW=WEIGHT_W+L;
    localparam integer RW=3+TAG_W+2+5*CW+TW+SW,IW=DATA_W+WEIGHT_W+2+TAG_W;
    localparam integer BOUND=(2*TW+12)*MAX_LEN+20;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [DATA_W-1:0] s_value=0;
    reg [WEIGHT_W-1:0] s_weight=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_last;
    wire signed [SW-1:0] m_numerator;
    wire [TW-1:0] m_denominator;
    wire [CW-1:0] m_start,m_length,m_count,m_block_count,m_block_index;
    wire [TAG_W-1:0] m_tag;
    wire [2:0] m_errors;
    weighted_isotonic #(.DATA_W(DATA_W),.WEIGHT_W(WEIGHT_W),.MAX_LEN(MAX_LEN),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_last,m_keep,m_block_index,m_block_count,m_count,
        m_length,m_start,m_denominator,m_numerator};
    wire [IW-1:0] request={s_tag,s_keep,s_last,s_weight,s_value};
    reg [RW-1:0] expected[0:TOKENS-1];
    reg checking=0,held=0,source_held=0,pending_next=0;
    reg [RW-1:0] held_response;
    reg [IW-1:0] held_request;
    integer cycle=0,outputs=0,completed=0,stalls=0,source_stalls=0,resets=0;
    integer covered=0,last_transfer=0,gap_checks=0;
    always @(negedge clk) if(checking&&!rst)m_ready=(cycle%19)>=8;
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(cycle>10000000)$fatal(1,"bounded watchdog");
        if(rst)begin held<=0;source_held<=0;pending_next<=0;covered<=0;end
        else begin
            if(held&&(!m_valid||response!==held_response))$fatal(1,"held output changed");
            if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source violated hold");
            held<=m_valid&&!m_ready;held_response<=response;
            source_held<=s_valid&&!s_ready;held_request<=request;
            if(checking)begin
                if(m_valid&&s_ready)$fatal(1,"overlapped frame ownership");
                if(m_valid&&!m_ready)stalls<=stalls+1;
                if(s_valid&&!s_ready)source_stalls<=source_stalls+1;
                if(pending_next&&m_valid)begin
                    if(cycle-last_transfer!=3)$fatal(1,"synchronous output read gap");
                    pending_next<=0;gap_checks<=gap_checks+1;
                end
                if(m_valid&&m_ready)begin
                    if(outputs>=TOKENS||response!==expected[outputs])
                        $fatal(1,"token mismatch n=%0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs<=outputs+1;
                    if(m_keep)begin
                        if(m_errors!==0||m_denominator==0||m_length==0||m_start!==CW'(covered))
                            $fatal(1,"block membership");
                        covered<=covered+m_length;
                        if(m_last)begin
                            if(covered+m_length!=m_count)$fatal(1,"incomplete fitted membership");
                            covered<=0;
                        end
                    end else if(!m_last||m_errors==0||m_numerator!==0||m_denominator!==0||
                        m_length!==0||m_start!==0||m_block_count!==0||m_block_index!==0)
                        $fatal(1,"error exposed prefix solution");
                    if(m_last)completed<=completed+1;
                    else begin pending_next<=1;last_transfer<=cycle;end
                end
            end
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset gating");
            @(negedge clk);rst=0;
            #1;if(!s_ready||m_valid||dut.count!==0||dut.depth!==0)$fatal(1,"reset reachability");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic send(input signed[DATA_W-1:0] x,input[WEIGHT_W-1:0] w,
                        input keep,last,input[TAG_W-1:0] tag);
        begin
            s_valid=1;s_value=x;s_weight=w;s_keep=keep;s_last=last;s_tag=tag;
            @(posedge clk);while(!s_ready)@(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    task automatic idle_again;
        integer waited;
        begin
            waited=0;
            while(!s_ready)begin
                @(negedge clk);waited=waited+1;
                if(waited>BOUND)$fatal(1,"partial frame stuck");
            end
        end
    endtask
    task automatic fresh_singleton;
        integer waited;
        begin
            @(negedge clk);send(-1,1,1,1,{TAG_W{1'b1}});waited=0;
            while(!m_valid)begin
                @(negedge clk);waited=waited+1;
                if(waited>BOUND)$fatal(1,"fresh solution missing");
            end
            if(!m_keep||!m_last||m_errors!==0||m_numerator!=={SW{1'b1}}||m_denominator!==1||
                m_length!==1||m_start!==0||m_count!==1||m_block_count!==1||m_block_index!==0||
                m_tag!=={TAG_W{1'b1}})$fatal(1,"stale stack reachable after reset");
            repeat(3)@(negedge clk);
            m_ready=1;@(negedge clk);m_ready=0;
            if(m_valid||!s_ready)$fatal(1,"duplicate fresh result");
        end
    endtask
    string inputs_path,expected_path;
    integer fd,fields,i,probe,waited,keep,last;
    reg signed[DATA_W-1:0] value;
    reg[WEIGHT_W-1:0] weight;
    reg[TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",inputs_path)||!$value$plusargs("EXPECTED=%s",expected_path))
            $fatal(1,"missing vectors");
        $readmemh(expected_path,expected);fd=$fopen(inputs_path,"r");if(!fd)$fatal(1,"input open");
        reset_core();checking=1;@(negedge clk);
        for(i=0;i<BEATS;i=i+1)begin
            fields=$fscanf(fd,"%h %h %d %d %h\n",value,weight,keep,last,tag);
            if(fields!=5)$fatal(1,"bad vector");
            if(i%11==0)repeat(1+i%3)@(negedge clk);
            send(value,weight,keep[0],last[0],tag);
        end
        $fclose(fd);waited=0;
        while(completed<FRAMES)begin
            @(negedge clk);waited=waited+1;
            if(waited>BOUND+4*MAX_LEN+30)$fatal(1,"final frame incomplete");
        end
        if(outputs!=TOKENS||stalls<1||source_stalls<1)$fatal(1,"missing finite coverage");
        checking=0;m_ready=0;
        for(probe=0;probe<17;probe=probe+1)begin
            if(MAX_LEN>1||probe<4||probe>=12)begin
                reset_core();@(negedge clk);
                if(probe==0)send(0,0,0,0,1);
                else if(probe>=12)begin
                    if(probe==12||probe==16)send(0,0,0,1,1);
                    else send(0,1,1,1,1);
                end else if(probe>=4)begin
                    send((probe==11)?-1:0,1,1,0,1);idle_again();
                    send(0,1,1,0,1);
                end else send(0,1,1,0,1);
                waited=0;
                if(probe==15||probe==16)begin
                    s_valid=1;s_value=-1;s_weight=1;s_keep=1;s_last=1;s_tag=0;
                    while(!(dut.state==probe&&held&&source_held))begin
                        @(negedge clk);waited=waited+1;
                        if(waited>BOUND)$fatal(1,"held reset target");
                    end
                end else begin
                    while(dut.state!=probe || (probe==8 &&
                        (!dut.second_product || dut.bit_count!=TW/2)))begin
                        @(negedge clk);waited=waited+1;
                        if(waited>BOUND)$fatal(1,"missing phase=%0d",probe);
                    end
                end
                // The complete targeted condition is observed now; no further active edge.
                reset_now();resets=resets+1;fresh_singleton();
            end
        end
        // Explicitly cancel each rejected-frame drain before its tail.
        for(probe=0;probe<2;probe=probe+1)begin
            reset_core();@(negedge clk);
            if(probe==0)send(0,0,1,0,1);
            else for(i=0;i<MAX_LEN+1;i=i+1)begin send(0,1,1,0,1);idle_again();end
            if((probe==0&&!dut.zero_weight)||(probe==1&&!dut.over_capacity))$fatal(1,"missing error drain");
            reset_now();resets=resets+1;fresh_singleton();
        end
        $display("PASS frames=%0d beats=%0d tokens=%0d outputs=%0d held_cycles=%0d source_stalls=%0d output_gap_checks=%0d reset_probes=%0d",
            FRAMES,BEATS,TOKENS,outputs,stalls,source_stalls,gap_checks,resets);
        $finish;
    end
endmodule
