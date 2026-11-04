// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_mann_whitney_u;
    parameter integer DATA_W=16,MAX_LEN=32,FRAC=16,TAG_W=8,BEATS=1,FRAMES=1,SCANS=0;
    localparam integer CW=(MAX_LEN<2)?1:$clog2(MAX_LEN+1);
    localparam integer PW=($clog2(2*((MAX_LEN*MAX_LEN)/4)+1)<1)?1:$clog2(2*((MAX_LEN*MAX_LEN)/4)+1);
    localparam integer RW=3+TAG_W+FRAC+2+3*CW+5*PW,IW=TAG_W+3+DATA_W;
    localparam integer DN=PW+1+FRAC,BOUND=2*MAX_LEN+DN+30;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_group=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [DATA_W-1:0] s_value=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;
    wire [CW-1:0] m_count,m_count_a,m_count_b;
    wire [PW-1:0] m_pairs,m_wins,m_losses,m_ties,m_u2;
    wire signed [FRAC+1:0] m_rank_biserial;
    wire [TAG_W-1:0] m_tag;
    wire [2:0] m_errors;
    mann_whitney_u #(.DATA_W(DATA_W),.MAX_LEN(MAX_LEN),.FRAC(FRAC),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_rank_biserial,m_count_b,m_count_a,m_count,
        m_pairs,m_wins,m_losses,m_ties,m_u2};
    wire [IW-1:0] request={s_tag,s_last,s_keep,s_group,s_value};
    reg [RW-1:0] expected[0:FRAMES-1];
    reg [31:0] latency[0:FRAMES-1];
    reg checking=0,held=0,source_held=0,await_first=0;
    reg [RW-1:0] held_response;
    reg [IW-1:0] held_request;
    integer cycle=0,outputs=0,tails=0,tail_cycle=0,stalls=0,source_stalls=0;
    integer scan_checks=0,latency_checks=0,reset_probes=0;
    always @(negedge clk)if(checking&&!rst)m_ready=(cycle%17)>=7;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>10000000)$fatal(1,"bounded watchdog");
        if(rst)begin held=0;source_held=0;await_first=0;end
        else begin
            if(held&&(!m_valid||response!==held_response))$fatal(1,"held output changed");
            if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source violated hold");
            held=m_valid&&!m_ready;held_response=response;
            source_held=s_valid&&!s_ready;held_request=request;
            if(checking)begin
                if(m_valid&&s_ready)$fatal(1,"overlapped ownership");
                if(m_valid&&!m_ready)stalls=stalls+1;
                if(s_valid&&!s_ready)source_stalls=source_stalls+1;
                if(dut.state==2)scan_checks=scan_checks+1;
                if(s_valid&&s_ready&&s_last)begin
                    tail_cycle=cycle;await_first=1;tails=tails+1;
                end
                if(m_valid&&m_ready)begin
                    if(outputs>=FRAMES||response!==expected[outputs])
                        $fatal(1,"result mismatch frame=%0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs=outputs+1;
                end
            end
            if(dut.state==4)begin
                if(dut.pairs!=dut.count_a*dut.count_b || dut.pairs!=dut.wins+dut.losses+dut.ties ||
                    dut.count!=dut.count_a+dut.count_b)$fatal(1,"pair partition identity");
            end
            if(dut.state==6&&dut.div_valid&&dut.div_flags!==0)$fatal(1,"legal divider flag");
        end
        #1;
        if(checking&&!rst&&await_first&&m_valid)begin
            if(cycle-tail_cycle!=latency[tails-1])$fatal(1,"tail schedule frame=%0d got=%0d expected=%0d",tails-1,cycle-tail_cycle,latency[tails-1]);
            await_first=0;latency_checks=latency_checks+1;
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset gating");
            @(negedge clk);rst=0;
            #1;if(!s_ready||m_valid||dut.count!==0||dut.count_a!==0||dut.count_b!==0||
                dut.pairs!==0||dut.over_capacity)$fatal(1,"reset cancellation");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic send(input signed[DATA_W-1:0] x,input group_id,keep,last,input[TAG_W-1:0] tag);
        begin
            s_valid=1;s_value=x;s_group=group_id;s_keep=keep;s_last=last;s_tag=tag;
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
                if(waited>BOUND)$fatal(1,"sample scan stuck");
            end
        end
    endtask
    task automatic fresh_frame;
        integer waited;
        begin
            @(negedge clk);send(0,0,1,MAX_LEN==1,{TAG_W{1'b1}});
            if(MAX_LEN>1)begin idle_again();send(0,1,1,1,0);end
            waited=0;
            while(!m_valid)begin
                @(negedge clk);waited=waited+1;
                if(waited>BOUND)$fatal(1,"fresh frame missing");
            end
            if(m_tag!=={TAG_W{1'b1}}||m_rank_biserial!==0||m_wins!==0||m_losses!==0)
                $fatal(1,"fresh frame metadata/statistic");
            if(MAX_LEN==1)begin
                if(m_errors!==2||m_count!==1||m_count_a!==1||m_count_b!==0||
                    m_pairs!==0||m_ties!==0||m_u2!==0)$fatal(1,"fresh singleton rejection");
            end else if(m_errors!==0||m_count!==2||m_count_a!==1||m_count_b!==1||
                m_pairs!==1||m_ties!==1||m_u2!==1)$fatal(1,"stale RAM reached fresh pair");
            repeat(3)@(negedge clk);
            m_ready=1;@(negedge clk);m_ready=0;
            if(m_valid||!s_ready)$fatal(1,"duplicate fresh result");
        end
    endtask
    task automatic wait_phase(input integer phase);
        integer waited;
        begin
            waited=0;
            while(dut.state!=phase || (phase==6 &&
                (dut.divider.state!=1 || dut.divider.cnt!=DN/2)))begin
                @(negedge clk);waited=waited+1;
                if(waited>BOUND)$fatal(1,"missing reset phase %0d",phase);
            end
        end
    endtask
    string inputs_path,expected_path,latency_path;
    integer fd,fields,i,probe,waited,group_id,keep,last;
    reg signed[DATA_W-1:0] value;
    reg[TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",inputs_path)||!$value$plusargs("EXPECTED=%s",expected_path)||
            !$value$plusargs("LATENCY=%s",latency_path))$fatal(1,"missing vectors");
        $readmemh(expected_path,expected);$readmemh(latency_path,latency);
        fd=$fopen(inputs_path,"r");if(!fd)$fatal(1,"input open");
        reset_core();checking=1;@(negedge clk);
        for(i=0;i<BEATS;i=i+1)begin
            fields=$fscanf(fd,"%h %d %d %d %h\n",value,group_id,keep,last,tag);
            if(fields!=5)$fatal(1,"bad vector");
            if(i%11==0)repeat(1+i%3)@(negedge clk);
            send(value,group_id[0],keep[0],last[0],tag);
        end
        $fclose(fd);waited=0;
        while(outputs<FRAMES)begin
            @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"last result missing");
        end
        if(tails!=FRAMES||latency_checks!=FRAMES||scan_checks!=SCANS||stalls<1||source_stalls<1)
            $fatal(1,"incomplete finite service checks");
        checking=0;m_ready=0;
        for(probe=0;probe<8;probe=probe+1)begin
            if(MAX_LEN>1||probe==0||probe==3||probe==4||probe==7)begin
                reset_core();@(negedge clk);
                if(probe==0)send(0,0,0,0,1);
                else if(probe==3)send(0,0,1,0,1);
                else if(probe==4||(probe==7&&MAX_LEN==1))send(0,0,0,1,1);
                else begin
                    send(0,0,1,0,1);idle_again();send(0,1,1,probe>=5,0);
                end
                if(probe==7)begin
                    s_valid=1;s_value=-1;s_group=0;s_keep=1;s_last=1;s_tag=0;
                    waited=0;
                    while(!(dut.state==7&&held&&source_held))begin
                        @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"held reset target");
                    end
                end else wait_phase(probe);
                // Target fully observed now; no intervening active edge.
                reset_now();reset_probes=reset_probes+1;fresh_frame();
            end
        end
        if(MAX_LEN>1)begin
            reset_core();@(negedge clk);send(0,0,0,1,1);
            s_valid=1;s_value=0;s_group=1;s_keep=1;s_last=1;s_tag=0;
            while(!(dut.state==7&&held&&source_held))@(negedge clk);
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
        reset_core();@(negedge clk);
        for(i=0;i<MAX_LEN;i=i+1)begin send(0,0,1,0,1);idle_again();end
        send(0,1,1,0,1);
        if(!dut.over_capacity||!s_ready)$fatal(1,"overflow drain target missing");
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        $display("PASS frames=%0d beats=%0d outputs=%0d scan_checks=%0d held_cycles=%0d source_stalls=%0d latency_checks=%0d reset_probes=%0d",
            FRAMES,BEATS,outputs,scan_checks,stalls,source_stalls,latency_checks,reset_probes);
        $finish;
    end
endmodule
