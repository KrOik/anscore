// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ks_histogram_distance;
    parameter integer KEY_W=16,FREQ_W=12,MAX_BINS=32,TAG_W=8,BEATS=1,FRAMES=1,ROWS=1,PRODUCTS=3;
    localparam integer K=KEY_W,F=FREQ_W,CW=($clog2(MAX_BINS+1)<1)?1:$clog2(MAX_BINS+1);
    localparam integer TW=($clog2(MAX_BINS*((1<<F)-1)+1)<1)?1:$clog2(MAX_BINS*((1<<F)-1)+1);
    localparam integer DW=2*TW,RW=6+TAG_W+2*CW+10*TW+K,IW=TAG_W+2+K+2*F;
    localparam integer BOUND=TW+2+MAX_BINS*(2*TW+4)+10;
    localparam signed [K-1:0] LO={1'b1,{(K-1){1'b0}}},HI={1'b0,{(K-1){1'b1}}};
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [K-1:0] s_key=0;
    reg [F-1:0] s_a=0,s_b=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;
    wire [CW-1:0] m_bins,m_witness_bin;
    wire [TW-1:0] m_total_a,m_total_b;
    wire [DW-1:0] m_num,m_den,m_plus,m_minus;
    wire signed [K-1:0] m_witness_key;
    wire signed [1:0] m_direction;
    wire [TAG_W-1:0] m_tag;
    wire [3:0] m_errors;
    ks_histogram_distance #(.KEY_W(K),.FREQ_W(F),.MAX_BINS(MAX_BINS),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_bins,m_total_a,m_total_b,
        m_num,m_den,m_plus,m_minus,m_witness_key,m_witness_bin,m_direction};
    wire [IW-1:0] request={s_tag,s_last,s_keep,s_key,s_a,s_b};
    reg [RW-1:0] expected[0:FRAMES-1];
    reg [31:0] latency[0:FRAMES-1];
    reg checking=0,held=0,source_held=0,await_first=0;
    reg [RW-1:0] held_response;
    reg [IW-1:0] held_request;
    integer cycle=0,outputs=0,tails=0,tail_cycle=0,held_cycles=0,source_stalls=0;
    integer latency_checks=0,row_checks=0,multiply_checks=0,reset_probes=0,fresh_checks=0,max_latency=0;
    always @(negedge clk)if(checking&&!rst)m_ready=(cycle%23)>=9;
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
                if(held)held_cycles=held_cycles+1;
                if(source_held)source_stalls=source_stalls+1;
                if(dut.state==5)row_checks=row_checks+1;
                if(dut.state==3)multiply_checks=multiply_checks+1;
                if(s_valid&&s_ready&&s_last)begin tail_cycle=cycle;tails=tails+1;await_first=1;end
                if(m_valid&&m_ready)begin
                    if(outputs>=FRAMES||response!==expected[outputs])
                        $fatal(1,"KS mismatch frame=%0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs=outputs+1;
                end
            end
            if(dut.state==3&&dut.mul_role==2)begin
                if(dut.prefix_a>dut.total_a||dut.prefix_b>dut.total_b||dut.magnitude>{1'b0,m_den})
                    $fatal(1,"CDF/product range");
                if(dut.row_index==dut.bin_count-1 && (dut.prefix_a!==dut.total_a||
                    dut.prefix_b!==dut.total_b||dut.difference!==0))$fatal(1,"CDF endpoint");
            end
            if(m_valid&&m_errors==0)begin
                if(m_den==0||m_num>m_den||m_plus>m_num||m_minus>m_num||
                    m_num!=((m_plus>m_minus)?m_plus:m_minus)||
                    (m_num==0&&m_direction!=0)||(m_num!=0&&m_direction!=1&&m_direction!=-1))
                    $fatal(1,"KS result range/direction");
            end
        end
        #1;
        if(checking&&!rst&&await_first&&m_valid)begin
            if(cycle-tail_cycle!=latency[tails-1])
                $fatal(1,"tail schedule frame=%0d got=%0d expected=%0d",tails-1,cycle-tail_cycle,latency[tails-1]);
            if(cycle-tail_cycle>max_latency)max_latency=cycle-tail_cycle;
            latency_checks=latency_checks+1;await_first=0;
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset gating");
            @(negedge clk);rst=0;
            #1;if(!s_ready||m_valid||dut.bin_count!==0||dut.total_a!==0||dut.total_b!==0||
                dut.order_error||dut.overflow)$fatal(1,"reset cancellation");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic send(input signed [K-1:0] key,input [F-1:0] a,b,
        input keep,last,input [TAG_W-1:0] tag);
        begin
            s_valid=1;s_key=key;s_a=a;s_b=b;s_keep=keep;s_last=last;s_tag=tag;
            @(posedge clk);while(!s_ready)@(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    task automatic fresh_frame;
        integer waited;
        begin
            @(negedge clk);
            if(MAX_BINS==1)send(HI,1,1,1,1,{TAG_W{1'b1}});
            else begin send(LO,1,0,1,0,{TAG_W{1'b1}});send(HI,0,1,1,1,0);end
            waited=0;
            while(!m_valid)begin
                @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"fresh result missing");
            end
            if(m_errors!==0||m_total_a!==1||m_total_b!==1||m_den!==1||m_minus!==0||
                m_witness_bin!==0||m_tag!=={TAG_W{1'b1}})$fatal(1,"fresh metadata/normalization");
            if(MAX_BINS==1)begin
                if(m_bins!==1||m_num!==0||m_plus!==0||m_direction!==0||m_witness_key!==HI)
                    $fatal(1,"fresh singleton CDF");
            end else if(m_bins!==2||m_num!==1||m_plus!==1||m_direction!==1||m_witness_key!==LO)
                $fatal(1,"fresh nonzero CDF/stale RAM");
            repeat(3)@(negedge clk);
            m_ready=1;@(negedge clk);m_ready=0;
            repeat(3)begin @(negedge clk);if(m_valid||!s_ready)$fatal(1,"stale fresh output");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    task automatic launch_probe;
        begin
            @(negedge clk);
            for(integer j=0;j<MAX_BINS;j=j+1)send(LO+j,1,1,1,j==MAX_BINS-1,1);
        end
    endtask
    task automatic phase_probe(input integer phase,role,index);
        integer waited;
        begin
            reset_core();
            if(phase==0)begin @(negedge clk);send(HI,0,0,0,0,1);end
            else launch_probe();
            if(phase==6)begin
                s_valid=1;s_key=HI;s_a=0;s_b=1;s_keep=1;s_last=1;s_tag=0;
            end
            waited=0;
            while(dut.state!=phase||((phase==2||phase==3)&&dut.mul_role!=role)||
                (phase==2&&dut.mul_step!=TW/2)||
                ((phase==4||phase==5)&&dut.row_index!=index)||
                (phase==6&&!(held&&source_held)))begin
                @(negedge clk);waited=waited+1;
                if(waited>BOUND)$fatal(1,"missing reset phase=%0d role=%0d index=%0d",phase,role,index);
            end
            // Complete target observed; assert reset before the next active edge.
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
    endtask
    string inputs_path,expected_path,latency_path;
    integer fd,fields,i,phase,role,waited,keep,last;
    reg signed [K-1:0] key;reg [F-1:0] a,b;reg [TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",inputs_path)||!$value$plusargs("EXPECTED=%s",expected_path)||
            !$value$plusargs("LATENCY=%s",latency_path))$fatal(1,"missing vectors");
        $readmemh(expected_path,expected);$readmemh(latency_path,latency);
        fd=$fopen(inputs_path,"r");if(!fd)$fatal(1,"input open");
        reset_core();checking=1;@(negedge clk);
        for(i=0;i<BEATS;i=i+1)begin
            fields=$fscanf(fd,"%h %h %h %d %d %h\n",key,a,b,keep,last,tag);
            if(fields!=6)$fatal(1,"bad vector");
            if(i%17==0)repeat(1+i%3)@(negedge clk);
            send(key,a,b,keep[0],last[0],tag);
        end
        $fclose(fd);waited=0;
        while(outputs<FRAMES)begin
            @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"last result missing");
        end
        if(tails!=FRAMES||latency_checks!=FRAMES||row_checks!=ROWS||multiply_checks!=PRODUCTS||
            held_cycles<1||source_stalls<1)$fatal(1,"incomplete finite checks");
        checking=0;m_ready=0;
        for(phase=0;phase<7;phase=phase+1)phase_probe(phase,0,0);
        for(role=1;role<3;role=role+1)begin phase_probe(2,role,0);phase_probe(3,role,0);end
        phase_probe(4,0,MAX_BINS/2);phase_probe(4,0,MAX_BINS-1);
        phase_probe(5,0,MAX_BINS/2);phase_probe(5,0,MAX_BINS-1);
        reset_core();@(negedge clk);send(HI,0,0,0,1,1);
        s_valid=1;s_key=LO;s_a=1;s_b=1;s_keep=1;s_last=1;s_tag=0;waited=0;
        while(!(dut.state==6&&held&&source_held))begin
            @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"held error target");
        end
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        reset_core();@(negedge clk);
        for(i=0;i<MAX_BINS;i=i+1)send(LO+i,1,1,1,0,1);
        send(HI,{F{1'b1}},{F{1'b1}},1,0,0);
        if(!dut.overflow||dut.order_error||dut.total_a!==MAX_BINS||dut.total_b!==MAX_BINS||!s_ready)
            $fatal(1,"overflow bounded prefix target");
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        reset_core();@(negedge clk);send(HI,1,1,1,0,1);send(LO,0,0,1,0,0);
        if(!dut.order_error||!s_ready)$fatal(1,"zero-frequency ordering target");
        reset_now();reset_probes=reset_probes+1;fresh_frame();
        if(reset_probes!=18||fresh_checks!=reset_probes)$fatal(1,"missing phase/fresh checks");
        $display("PASS frames=%0d beats=%0d outputs=%0d latency_checks=%0d max_latency=%0d row_checks=%0d multiply_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",
            FRAMES,BEATS,outputs,latency_checks,max_latency,row_checks,multiply_checks,held_cycles,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
