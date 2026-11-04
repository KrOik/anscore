// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_theil_sen_slope;
    parameter integer DATA_W=12,MAX_LEN=8,TAG_W=8,BEATS=1,FRAMES=1;
    localparam integer W=DATA_W,CW=$clog2(MAX_LEN+1),D=W+1;
    localparam integer PW=($clog2(MAX_LEN*(MAX_LEN-1)/2+1)<1)?1:$clog2(MAX_LEN*(MAX_LEN-1)/2+1);
    localparam integer NW=2*W+2,DW=2*W+1;
    localparam integer RW=2+TAG_W+CW+2*PW+1+NW+DW+2*(D+W),IW=TAG_W+2+2*W;
    localparam integer Q=MAX_LEN*(MAX_LEN-1)/2,BOUND=6*Q+(2*W+5)*Q*(Q-1)/2+3*W+8;
    localparam signed [W-1:0] LO={1'b1,{(W-1){1'b0}}},HI={1'b0,{(W-1){1'b1}}};
    localparam signed [NW-1:0] PRODUCT_LIMIT=({{(NW-1){1'b0}},1'b1} << (2*W));
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_x=0,s_y=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_even;
    wire [CW-1:0] m_count;
    wire [PW-1:0] m_pairs,m_skipped;
    wire signed [NW-1:0] m_num;
    wire [DW-1:0] m_den;
    wire signed [D-1:0] m_low_num,m_high_num;
    wire [W-1:0] m_low_den,m_high_den;
    wire [TAG_W-1:0] m_tag;
    wire [1:0] m_errors;
    theil_sen_slope #(.DATA_W(W),.MAX_LEN(MAX_LEN),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_count,m_pairs,m_skipped,m_even,
        m_num,m_den,m_low_num,m_low_den,m_high_num,m_high_den};
    wire [IW-1:0] request={s_tag,s_last,s_keep,s_x,s_y};
    reg [RW-1:0] expected[0:FRAMES-1];
    reg [31:0] bounds[0:FRAMES-1];
    integer outputs=0;
    wire [1:0] e_errors;wire [TAG_W-1:0] e_tag;wire [CW-1:0] e_count;
    wire [PW-1:0] e_pairs,e_skipped;wire e_even;
    wire signed [NW-1:0] e_num;wire [DW-1:0] e_den;
    wire signed [D-1:0] e_low_num,e_high_num;wire [W-1:0] e_low_den,e_high_den;
    assign {e_errors,e_tag,e_count,e_pairs,e_skipped,e_even,e_num,e_den,
        e_low_num,e_low_den,e_high_num,e_high_den}=expected[outputs];
    function automatic same_fraction(input signed [NW-1:0] an,input [DW-1:0] ad,
        input signed [NW-1:0] bn,input [DW-1:0] bd);
        reg signed [NW+DW:0] lhs,rhs;
        begin
            lhs=an*$signed({1'b0,bd});rhs=bn*$signed({1'b0,ad});
            same_fraction=(ad==0||bd==0)?(ad==0&&bd==0&&an==0&&bn==0):(lhs==rhs);
        end
    endfunction
    reg checking=0,held=0,source_held=0,await_first=0;
    reg [RW-1:0] held_response;
    reg [IW-1:0] held_request;
    integer cycle=0,tails=0,tail_cycle=0,held_cycles=0,source_stalls=0;
    integer first_checks=0,max_latency=0,reset_probes=0,fresh_checks=0,pair_checks=0;
    integer wide_even_sum=0,wide_even_den=0;
    always @(negedge clk)if(checking&&!rst)m_ready=(cycle%19)>=8;
    always @(posedge clk)begin
        cycle=cycle+1;if(cycle>20000000)$fatal(1,"bounded watchdog");
        if(rst)begin held=0;source_held=0;await_first=0;end
        else begin
            if(held&&(!m_valid||response!==held_response))$fatal(1,"held output changed");
            if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source hold violated");
            held=m_valid&&!m_ready;held_response=response;
            source_held=s_valid&&!s_ready;held_request=request;
            if(checking)begin
                if(m_valid&&s_ready)$fatal(1,"overlapping frame ownership");
                if(held)held_cycles=held_cycles+1;
                if(source_held)source_stalls=source_stalls+1;
                if(s_valid&&s_ready&&s_last)begin tail_cycle=cycle;tails=tails+1;await_first=1;end
                if(m_valid&&m_ready)begin
                    if(outputs>=FRAMES||{m_errors,m_tag,m_count,m_pairs,m_skipped,m_even}!==
                        {e_errors,e_tag,e_count,e_pairs,e_skipped,e_even}||
                        !same_fraction(m_num,m_den,e_num,e_den)||
                        !same_fraction(m_low_num,m_low_den,e_low_num,e_low_den)||
                        !same_fraction(m_high_num,m_high_den,e_high_num,e_high_den))
                        $fatal(1,"median mismatch frame=%0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs=outputs+1;
                    if(m_errors==0&&m_even)begin
                        if(m_num>=PRODUCT_LIMIT||m_num<=-PRODUCT_LIMIT)wide_even_sum=wide_even_sum+1;
                        if(m_den[2*W])wide_even_den=wide_even_den+1;
                    end
                end
            end
            if(dut.state==13)begin
                if(dut.pairs==0||dut.pairs+dut.skipped!=dut.count*(dut.count-1)/2)
                    $fatal(1,"pair population partition");
                pair_checks=pair_checks+1;
            end
            if(m_valid&&m_errors==0&&(m_den==0||m_low_den==0||m_high_den==0))
                $fatal(1,"valid slope denominator");
        end
        #1;
        if(checking&&!rst&&await_first&&m_valid)begin
            if(cycle-tail_cycle>bounds[tails-1]||cycle-tail_cycle<1||
                (m_errors!=0&&cycle-tail_cycle!=1))$fatal(1,"first valid bound");
            if(cycle-tail_cycle>max_latency)max_latency=cycle-tail_cycle;
            first_checks=first_checks+1;await_first=0;
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset gating");
            @(negedge clk);rst=0;
            #1;if(!s_ready||m_valid||dut.count!==0||dut.pairs!==0||dut.skipped!==0||dut.overflow)
                $fatal(1,"reset cancellation");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic send(input signed [W-1:0] x,y,input keep,last,input [TAG_W-1:0] tag);
        begin
            s_valid=1;s_x=x;s_y=y;s_keep=keep;s_last=last;s_tag=tag;
            @(posedge clk);while(!s_ready)@(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    task automatic fresh_frame;
        integer waited;
        begin
            @(negedge clk);send(LO,0,1,0,{TAG_W{1'b1}});send(HI,0,1,1,0);
            waited=0;
            while(!m_valid)begin
                @(negedge clk);waited=waited+1;
                if(waited>BOUND)$fatal(1,"fresh result missing");
            end
            if(m_errors!==0||m_count!==2||m_pairs!==1||m_skipped!==0||m_even||
                m_num!==0||m_den!=={W{1'b1}}||m_low_num!==0||m_high_num!==0||
                m_low_den!=={W{1'b1}}||m_high_den!=={W{1'b1}}||m_tag!=={TAG_W{1'b1}})
                $fatal(1,"fresh frame stale RAM/statistic");
            repeat(3)@(negedge clk);
            m_ready=1;@(negedge clk);m_ready=0;
            repeat(2)begin @(negedge clk);if(m_valid||!s_ready)$fatal(1,"duplicate fresh output");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    task automatic launch_probe;
        begin
            @(negedge clk);send(LO,LO,1,0,1);send(HI,HI,1,MAX_LEN==2,0);
            if(MAX_LEN>2)send(HI,LO,1,1,0);
        end
    endtask
    task automatic phase_probe(input integer phase,role);
        integer waited;
        begin
            reset_core();
            if(phase==0)begin @(negedge clk);send(LO,HI,0,0,1);end
            else launch_probe();
            if(phase==17)begin
                s_valid=1;s_x=HI;s_y=LO;s_keep=1;s_last=1;s_tag=0;
            end
            waited=0;
            while(dut.state!=phase||((phase==8||phase==9)&&dut.mul_role!=role)||
                (phase==8&&dut.mul_step!=W/2)||
                (phase==17&&!(held&&source_held)))begin
                @(negedge clk);waited=waited+1;
                if(waited>BOUND)$fatal(1,"missing reset phase=%0d role=%0d",phase,role);
            end
            // Complete target observed; reset is asserted before any active edge.
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
    endtask
    string inputs_path,expected_path,bounds_path;
    integer fd,fields,i,phase,role,waited,keep,last;
    reg signed [W-1:0] x,y;reg [TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",inputs_path)||!$value$plusargs("EXPECTED=%s",expected_path)||
            !$value$plusargs("BOUNDS=%s",bounds_path))$fatal(1,"missing vectors");
        $readmemh(expected_path,expected);$readmemh(bounds_path,bounds);
        fd=$fopen(inputs_path,"r");if(!fd)$fatal(1,"input open");
        reset_core();checking=1;@(negedge clk);
        for(i=0;i<BEATS;i=i+1)begin
            fields=$fscanf(fd,"%h %h %d %d %h\n",x,y,keep,last,tag);
            if(fields!=5)$fatal(1,"bad vector");
            if(i%13==0)repeat(1+i%3)@(negedge clk);
            send(x,y,keep[0],last[0],tag);
        end
        $fclose(fd);waited=0;
        while(outputs<FRAMES)begin
            @(negedge clk);waited=waited+1;if(waited>BOUND+20)$fatal(1,"last result missing");
        end
        if(tails!=FRAMES||first_checks!=FRAMES||held_cycles<1||source_stalls<1)$fatal(1,"missing service checks");
        if(W>=3&&(wide_even_sum<2||wide_even_den<2))$fatal(1,"missing even guard-bit cases");
        checking=0;m_ready=0;
        for(phase=0;phase<18;phase=phase+1)begin
            if(MAX_LEN>2||(phase!=6&&phase!=7&&phase!=8&&phase!=9&&phase!=10))phase_probe(phase,0);
        end
        if(MAX_LEN>2)for(role=1;role<5;role=role+1)begin phase_probe(8,role);phase_probe(9,role);end
        reset_core();@(negedge clk);send(LO,HI,0,1,1);
        s_valid=1;s_x=HI;s_y=LO;s_keep=1;s_last=1;s_tag=0;waited=0;
        while(!(dut.state==17&&held&&source_held))begin
            @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"held error reset target");
        end
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        reset_core();@(negedge clk);
        for(i=0;i<MAX_LEN;i=i+1)send(LO,HI,1,0,1);
        send(HI,LO,1,0,0);
        if(!dut.overflow||!s_ready||dut.x_varies)$fatal(1,"overflow prefix target");
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        if(fresh_checks!=reset_probes)$fatal(1,"missing fresh recovery");
        $display("PASS frames=%0d beats=%0d outputs=%0d first_checks=%0d max_latency=%0d held_cycles=%0d source_stalls=%0d pair_checks=%0d reset_probes=%0d fresh_checks=%0d",
            FRAMES,BEATS,outputs,first_checks,max_latency,held_cycles,source_stalls,pair_checks,reset_probes,fresh_checks);
        $finish;
    end
endmodule
