// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_wilcoxon_signed_rank;
    parameter integer DATA_W=16,MAX_LEN=16,TAG_W=8,BEATS=1,FRAMES=1,ROWS=1,COMPARES=1;
    localparam integer W=DATA_W,CW=($clog2(MAX_LEN+1)<1)?1:$clog2(MAX_LEN+1);
    localparam integer SW=($clog2(MAX_LEN*(MAX_LEN+1)+1)<1)?1:$clog2(MAX_LEN*(MAX_LEN+1)+1);
    localparam integer RW=2+TAG_W+6*CW+3*SW,IW=TAG_W+2+2*W;
    localparam integer BOUND=2+MAX_LEN*(2*MAX_LEN+3)+20;
    localparam signed [W-1:0] LO={1'b1,{(W-1){1'b0}}},HI={1'b0,{(W-1){1'b1}}};
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_x=0,s_y=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;
    wire [CW-1:0] m_count,m_nonzero,m_zeros,m_positive,m_negative,m_tied;
    wire [SW-1:0] m_plus2,m_minus2,m_stat2;
    wire [TAG_W-1:0] m_tag;wire [1:0] m_errors;
    wilcoxon_signed_rank #(.DATA_W(W),.MAX_LEN(MAX_LEN),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_count,m_nonzero,m_zeros,m_positive,m_negative,m_tied,m_plus2,m_minus2,m_stat2};
    wire [IW-1:0] request={s_tag,s_last,s_keep,s_x,s_y};
    reg [RW-1:0] expected[0:FRAMES-1];reg [31:0] latency[0:FRAMES-1];
    reg checking=0,held=0,source_held=0,await_first=0;
    reg [RW-1:0] held_response;reg [IW-1:0] held_request;
    integer cycle=0,outputs=0,tails=0,tail_cycle=0,held_cycles=0,source_stalls=0;
    integer latency_checks=0,rank_checks=0,compare_checks=0,reset_probes=0,fresh_checks=0,max_latency=0;
    always @(negedge clk)if(checking&&!rst)m_ready=(cycle%29)>=11;
    always @(posedge clk)begin
        cycle=cycle+1;if(cycle>10000000)$fatal(1,"bounded watchdog");
        if(rst)begin held=0;source_held=0;await_first=0;end
        else begin
            if(held&&(!m_valid||response!==held_response))$fatal(1,"held result changed");
            if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source hold violated");
            held=m_valid&&!m_ready;held_response=response;
            source_held=s_valid&&!s_ready;held_request=request;
            if(checking)begin
                if(m_valid&&s_ready)$fatal(1,"overlapping frame ownership");
                if(held)held_cycles=held_cycles+1;if(source_held)source_stalls=source_stalls+1;
                if(dut.state==5)compare_checks=compare_checks+1;
                if(dut.state==6)rank_checks=rank_checks+1;
                if(s_valid&&s_ready&&s_last)begin tail_cycle=cycle;tails=tails+1;await_first=1;end
                if(m_valid&&m_ready)begin
                    if(outputs>=FRAMES||response!==expected[outputs])
                        $fatal(1,"signed-rank mismatch frame=%0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs=outputs+1;
                end
            end
            if(dut.state==5 && (dut.sample_magnitude==0||dut.target_magnitude==0))$fatal(1,"zero entered compact RAM");
            if(dut.state==6 && (dut.equal_count==0||dut.less_count+dut.equal_count>m_nonzero||
                dut.rank2<2||dut.rank2>2*m_nonzero))$fatal(1,"average rank range");
            if(m_valid)begin
                if(m_count>MAX_LEN||m_count!=m_nonzero+m_zeros||m_nonzero!=m_positive+m_negative)$fatal(1,"pair diagnostics");
                if(m_errors==0)begin
                    if(m_nonzero==0||m_plus2+m_minus2!=m_nonzero*(m_nonzero+1)||
                        m_stat2!=((m_plus2<m_minus2)?m_plus2:m_minus2)||m_tied>m_nonzero||m_tied==1)
                        $fatal(1,"rank/tie conservation");
                end else if(m_plus2!==0||m_minus2!==0||m_stat2!==0||m_tied!==0)$fatal(1,"rejected rank publication");
            end
        end
        #1;
        if(checking&&!rst&&await_first&&m_valid)begin
            if(cycle-tail_cycle!=latency[tails-1])$fatal(1,"tail schedule frame=%0d got=%0d expected=%0d",tails-1,cycle-tail_cycle,latency[tails-1]);
            if(cycle-tail_cycle>max_latency)max_latency=cycle-tail_cycle;
            latency_checks=latency_checks+1;await_first=0;
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset gating");
            @(negedge clk);rst=0;
            #1;if(!s_ready||m_valid||dut.count!==0||dut.nonzero!==0||dut.positive!==0||dut.negative!==0||dut.overflow)
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
            @(negedge clk);
            if(MAX_LEN==1)send(LO,HI,1,1,{TAG_W{1'b1}});
            else begin send(HI,LO,1,0,{TAG_W{1'b1}});send(LO,HI,1,1,0);end
            waited=0;
            while(!m_valid)begin @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"fresh result missing");end
            if(m_errors!==0||m_zeros!==0||m_tag!=={TAG_W{1'b1}})$fatal(1,"fresh metadata");
            if(MAX_LEN==1)begin
                if(m_count!==1||m_nonzero!==1||m_positive!==0||m_negative!==1||m_tied!==0||
                    m_plus2!==0||m_minus2!==2||m_stat2!==0)$fatal(1,"fresh full-range negative rank");
            end else if(m_count!==2||m_nonzero!==2||m_positive!==1||m_negative!==1||m_tied!==2||
                m_plus2!==3||m_minus2!==3||m_stat2!==3)$fatal(1,"fresh opposite-sign half-rank/stale RAM");
            repeat(3)@(negedge clk);
            m_ready=1;@(negedge clk);m_ready=0;
            repeat(3)begin @(negedge clk);if(m_valid||!s_ready)$fatal(1,"stale fresh output");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    task automatic launch_probe;
        begin
            @(negedge clk);
            for(integer j=0;j<MAX_LEN;j=j+1)begin
                if(j%2==0)send(HI,LO,1,j==MAX_LEN-1,1);
                else send(LO,HI,1,j==MAX_LEN-1,0);
            end
        end
    endtask
    task automatic phase_probe(input integer phase,target,scan);
        integer waited;
        begin
            reset_core();
            if(phase==0)begin @(negedge clk);send(HI,LO,0,0,1);end
            else launch_probe();
            if(phase==8)begin s_valid=1;s_x=HI;s_y=LO;s_keep=1;s_last=1;s_tag=0;end
            waited=0;
            while(dut.state!=phase||((phase>=2&&phase<=6)&&dut.target_index!=target)||
                ((phase==4||phase==5)&&dut.scan_index!=scan)||(phase==8&&!(held&&source_held)))begin
                @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"missing reset phase=%0d target=%0d scan=%0d",phase,target,scan);
            end
            // Complete target observed; reset before another active edge.
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
    endtask
    string inputs_path,expected_path,latency_path;
    integer fd,fields,i,phase,waited,keep,last;
    reg signed [W-1:0] x,y;reg [TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",inputs_path)||!$value$plusargs("EXPECTED=%s",expected_path)||
            !$value$plusargs("LATENCY=%s",latency_path))$fatal(1,"missing vectors");
        $readmemh(expected_path,expected);$readmemh(latency_path,latency);
        fd=$fopen(inputs_path,"r");if(!fd)$fatal(1,"input open");
        reset_core();checking=1;@(negedge clk);
        for(i=0;i<BEATS;i=i+1)begin
            fields=$fscanf(fd,"%h %h %d %d %h\n",x,y,keep,last,tag);if(fields!=5)$fatal(1,"bad vector");
            if(i%17==0)repeat(1+i%3)@(negedge clk);
            send(x,y,keep[0],last[0],tag);
        end
        $fclose(fd);waited=0;
        while(outputs<FRAMES)begin @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"last result missing");end
        if(tails!=FRAMES||latency_checks!=FRAMES||rank_checks!=ROWS||compare_checks!=COMPARES||held_cycles<1||source_stalls<1)
            $fatal(1,"incomplete finite checks");
        checking=0;m_ready=0;
        for(phase=0;phase<9;phase=phase+1)phase_probe(phase,0,0);
        phase_probe(2,MAX_LEN/2,0);phase_probe(2,MAX_LEN-1,0);
        phase_probe(3,MAX_LEN/2,0);phase_probe(3,MAX_LEN-1,0);
        phase_probe(4,MAX_LEN-1,MAX_LEN/2);phase_probe(4,MAX_LEN-1,MAX_LEN-1);
        phase_probe(5,MAX_LEN-1,MAX_LEN/2);phase_probe(5,MAX_LEN-1,MAX_LEN-1);
        reset_core();@(negedge clk);send(HI,LO,0,1,1);
        s_valid=1;s_x=LO;s_y=HI;s_keep=1;s_last=1;s_tag=0;waited=0;
        while(!(dut.state==8&&held&&source_held))begin
            @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"held error target");
        end
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        reset_core();@(negedge clk);
        for(i=0;i<MAX_LEN;i=i+1)send(HI,HI,1,0,1);
        send(HI,LO,1,0,0);
        if(!dut.overflow||dut.count!==MAX_LEN||dut.nonzero!==0||dut.positive!==0||dut.negative!==0||!s_ready)
            $fatal(1,"overflow cannot repair retained zero prefix");
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        reset_core();@(negedge clk);send(LO,LO,1,0,1);
        if(dut.count!==1||dut.nonzero!==0||!s_ready)$fatal(1,"retained zero pair target");
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        if(reset_probes!=20||fresh_checks!=reset_probes)$fatal(1,"missing phase/fresh checks");
        $display("PASS frames=%0d beats=%0d outputs=%0d latency_checks=%0d max_latency=%0d rank_checks=%0d compare_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",
            FRAMES,BEATS,outputs,latency_checks,max_latency,rank_checks,compare_checks,held_cycles,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
