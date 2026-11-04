// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_kendall_tau_b;
    parameter integer DATA_W=16,MAX_LEN=32,TAG_W=8,BEATS=1,FRAMES=1,PAIR_CHECKS=0,MUL_CHECKS=0;
    localparam integer W=DATA_W,CW=$clog2(MAX_LEN+1),
        PW=($clog2(MAX_LEN*(MAX_LEN-1)/2+1)<1)?1:$clog2(MAX_LEN*(MAX_LEN-1)/2+1),
        OW=4+TAG_W+CW+9*PW;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_x=0,s_y=0;reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;wire [CW-1:0] m_count;
    wire [PW-1:0] m_pairs,m_concordant,m_discordant,m_tie_x,m_tie_y,m_tie_both;
    wire signed [PW:0] m_score;wire [2*PW-1:0] m_radicand;
    wire [TAG_W-1:0] m_tag;wire [2:0] m_errors;
    kendall_tau_b #(.DATA_W(W),.MAX_LEN(MAX_LEN),.TAG_W(TAG_W)) dut(.*);
    wire [OW-1:0] word={m_errors,m_tag,m_count,m_pairs,m_concordant,m_discordant,
        m_tie_x,m_tie_y,m_tie_both,m_score,m_radicand};
    reg [OW-1:0] expected[0:FRAMES-1];
    reg [6*PW-1:0] prefix[0:FRAMES-1];
    reg [31:0] latency[0:FRAMES-1];
    integer cycle=0,held_cycles=0,source_stalls=0,scan_checks=0,multiply_checks=0;
    integer main_pair_checks=0,main_mul_checks=0,reset_probes=0,fresh_checks=0;
    integer accepted=0,outputs=0,maximum_latency=0;
    reg main_active=1,previous_sink_stall=0,previous_source_stall=0;
    reg [OW-1:0] previous_word;
    reg [2*W+TAG_W+1:0] previous_source;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin previous_sink_stall=0;previous_source_stall=0;end
        else begin
            if(previous_sink_stall && (!m_valid || word!==previous_word))$fatal(1,"held output changed");
            if(previous_source_stall && (!s_valid || {s_tag,s_x,s_y,s_keep,s_last}!==previous_source))
                $fatal(1,"source changed before acceptance");
            if(m_valid && !m_ready)held_cycles=held_cycles+1;
            if(s_valid && !s_ready)source_stalls=source_stalls+1;
            previous_sink_stall=m_valid && !m_ready;previous_word=word;
            previous_source_stall=s_valid && !s_ready;previous_source={s_tag,s_x,s_y,s_keep,s_last};
            if(dut.state==1 && (dut.prior_count==0 || dut.scan_index>=dut.prior_count || dut.prior_count+1!=dut.count))
                $fatal(1,"sample history ownership");
            if(dut.state==2)begin
                scan_checks=scan_checks+1;if(main_active)main_pair_checks=main_pair_checks+1;
            end
            if(dut.state==5)begin
                if(dut.mul_step>=PW || dut.final_errors!=0)$fatal(1,"multiplier domain");
                multiply_checks=multiply_checks+1;if(main_active)main_mul_checks=main_mul_checks+1;
            end
            if(dut.state==4)begin
                if(dut.pairs!=dut.count*(dut.count-1)/2)$fatal(1,"finite pair population");
                if(dut.pairs!=dut.concordant+dut.discordant+dut.tie_x+dut.tie_y+dut.tie_both)
                    $fatal(1,"exclusive class partition");
                if(dut.factor_x>dut.pairs || dut.factor_y>dut.pairs)$fatal(1,"factor bound");
            end
            if(m_valid && s_ready)$fatal(1,"overlapped frame ownership");
        end
        if(cycle>4000000)$fatal(1,"finite cycle watchdog");
    end
    task push;
        input signed [W-1:0] x_value,y_value;
        input integer keep_value,last_value;input [TAG_W-1:0] tag_value;
        output integer edge_number;
        begin
            @(negedge clk);s_valid=1;s_x=x_value;s_y=y_value;s_keep=keep_value;s_last=last_value;s_tag=tag_value;
            #1;
            while(s_ready!==1'b1)begin @(negedge clk);#1;end
            @(posedge clk);#1;edge_number=cycle;
            @(negedge clk);s_valid=0;#1;
        end
    endtask
    task reset_now;
        begin
            // Caller has just observed its target on this negedge.
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready!==0 || m_valid!==0)$fatal(1,"reset interface gate");
            @(posedge clk);#1;
            if(dut.state!==0 || dut.count!==0 || dut.pairs!==0 || m_valid!==0 || m_score!==0 || m_radicand!==0)
                $fatal(1,"reset cancellation");
            @(negedge clk);rst=0;#1;
        end
    endtask
    task wait_output;
        integer guard;
        begin
            guard=0;
            while(!m_valid)begin
                @(negedge clk);#1;guard=guard+1;
                if(guard>2*MAX_LEN+PW+10)$fatal(1,"first-valid bound");
            end
        end
    endtask
    task retire;
        begin
            m_ready=1;@(posedge clk);#1;
            @(negedge clk);m_ready=0;s_valid=0;#1;
            if(m_valid)$fatal(1,"retirement left stale valid");
        end
    endtask
    task fresh;
        integer e;reg [OW-1:0] held;
        begin
            push(-1,-1,1,0,{TAG_W{1'b1}},e);push(0,0,1,1,0,e);wait_output;
            if(m_count!==2 || m_pairs!==1 || m_concordant!==1 || m_discordant!==0 ||
               m_tie_x!==0 || m_tie_y!==0 || m_tie_both!==0 || m_score!==1 || m_radicand!==1 ||
               m_errors!==0 || m_tag!=={TAG_W{1'b1}})$fatal(1,"fresh full analytic result");
            held=word;
            repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held)$fatal(1,"fresh hold");end
            retire;
            repeat(3)begin @(negedge clk);#1;if(m_valid)$fatal(1,"post-fresh stale valid");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    function target_seen;
        input integer id;
        begin
            case(id)
                0:target_seen=dut.state==0 && !dut.started;
                1:target_seen=dut.state==0 && dut.started && dut.count==0;
                2:target_seen=dut.state==0 && dut.count==1;
                3:target_seen=dut.state==1 && dut.scan_index==0;
                4:target_seen=dut.state==2 && dut.scan_index==dut.prior_count-1;
                5:target_seen=dut.state==1 && dut.scan_index==dut.prior_count/2;
                6:target_seen=dut.state==3;
                7:target_seen=dut.state==4;
                8:target_seen=dut.state==5 && dut.mul_step==0;
                9:target_seen=dut.state==5 && dut.mul_step==PW/2;
                10:target_seen=dut.state==5 && dut.mul_step==PW-1;
                11:target_seen=dut.state==6 && m_errors==0;
                12:target_seen=dut.state==2 && !dut.equal_x && !dut.equal_y && dut.concordance;
                13:target_seen=dut.state==2 && !dut.equal_x && !dut.equal_y && !dut.concordance;
                14:target_seen=dut.state==2 && dut.equal_x && !dut.equal_y;
                15:target_seen=dut.state==2 && !dut.equal_x && dut.equal_y;
                16:target_seen=dut.state==2 && dut.equal_x && dut.equal_y;
                17:target_seen=dut.state==6 && m_errors==3;
                18:target_seen=dut.state==0 && dut.overflow;
                19:target_seen=dut.state==6 && m_errors==4;
                default:target_seen=0;
            endcase
        end
    endfunction
    task probe;
        input integer id;
        integer k,e,n,guard;reg [OW-1:0] held;
        begin
            case(id)
                0:begin end
                1:push(-1,-1,0,0,1,e);
                2:push(-1,-1,1,0,1,e);
                12:begin push(-1,-1,1,0,1,e);push(0,0,1,1,1,e);end
                13:begin push(-1,0,1,0,1,e);push(0,-1,1,1,1,e);end
                14:begin push(-1,-1,1,0,1,e);push(-1,0,1,1,1,e);end
                15:begin push(-1,-1,1,0,1,e);push(0,-1,1,1,1,e);end
                16:begin push(-1,-1,1,0,1,e);push(-1,-1,1,1,1,e);end
                17:push(-1,-1,0,1,1,e);
                18,19:begin
                    for(k=0;k<=MAX_LEN;k=k+1)push(k%2-1,k%2-1,1,(id==19 && k==MAX_LEN),1,e);
                end
                default:begin
                    n=MAX_LEN<5?MAX_LEN:5;
                    for(k=0;k<n;k=k+1)push(k-1,k-1,1,k==n-1,1,e);
                end
            endcase
            guard=0;
            while(!target_seen(id))begin
                @(negedge clk);#1;guard=guard+1;
                if(guard>2*MAX_LEN+PW+10)$fatal(1,"unreached reset target %0d",id);
            end
            if(id==11 || id==17 || id==19)begin
                held=word;s_valid=1;s_x=-1;s_y=0;s_keep=1;s_last=1;s_tag=0;
                repeat(3)begin
                    @(negedge clk);#1;
                    if(!m_valid || word!==held || s_ready || !target_seen(id))$fatal(1,"held reset target");
                end
            end
            reset_probes=reset_probes+1;reset_now;fresh;
        end
    endtask
    integer input_fd,trace_fd,rc,fi,bi,keep_value,last_value,e,tail_edge,delay_observed;
    reg [W-1:0] x_value,y_value;reg [TAG_W-1:0] tag_value;reg [OW-1:0] held;
    reg [2047:0] input_path,expected_path,latency_path,prefix_path,trace_path;
    initial begin
        if(!$value$plusargs("INPUTS=%s",input_path) || !$value$plusargs("EXPECTED=%s",expected_path) ||
           !$value$plusargs("LATENCY=%s",latency_path) || !$value$plusargs("PREFIX=%s",prefix_path) ||
           !$value$plusargs("TRACE=%s",trace_path))$fatal(1,"missing local fixtures");
        input_fd=$fopen(input_path,"r");trace_fd=$fopen(trace_path,"w");
        if(!input_fd || !trace_fd)$fatal(1,"fixture open");
        $readmemh(expected_path,expected);$readmemh(latency_path,latency);$readmemh(prefix_path,prefix);
        @(negedge clk);#1;reset_now;
        for(fi=0;fi<FRAMES;fi=fi+1)begin
            last_value=0;
            while(!last_value)begin
                rc=$fscanf(input_fd,"%h %h %d %d %h\n",x_value,y_value,keep_value,last_value,tag_value);
                if(rc!=5)$fatal(1,"input fixture truncation");
                push(x_value,y_value,keep_value,last_value,tag_value,e);accepted=accepted+1;
                if(last_value)tail_edge=e;
            end
            wait_output;delay_observed=cycle-tail_edge;
            if(delay_observed!=latency[fi])$fatal(1,"tail latency %0d got %0d expected %0d",fi,delay_observed,latency[fi]);
            if(word!==expected[fi])$fatal(1,"full result frame %0d got %h expected %h",fi,word,expected[fi]);
            if({dut.pairs,dut.concordant,dut.discordant,dut.tie_x,dut.tie_y,dut.tie_both}!==prefix[fi])
                $fatal(1,"retained prefix class populations frame %0d",fi);
            $fdisplay(trace_fd,"%h %0d",word,delay_observed);
            if(delay_observed>maximum_latency)maximum_latency=delay_observed;
            held=word;
            repeat(5)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"main output hold");end
            retire;outputs=outputs+1;
        end
        main_active=0;
        if(accepted!=BEATS || outputs!=FRAMES || main_pair_checks!=PAIR_CHECKS || main_mul_checks!=MUL_CHECKS)
            $fatal(1,"finite main totals");
        for(bi=0;bi<20;bi=bi+1)probe(bi);
        $fclose(input_fd);$fclose(trace_fd);
        $display("PASS frames=%0d beats=%0d outputs=%0d latency_checks=%0d max_latency=%0d main_pairs=%0d main_mul=%0d scan_checks=%0d multiply_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",FRAMES,BEATS,outputs,FRAMES,maximum_latency,main_pair_checks,main_mul_checks,scan_checks,multiply_checks,held_cycles,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
`default_nettype wire
