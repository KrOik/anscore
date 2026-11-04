// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_rational_polynomial_interpolate;
    parameter integer DATA_W=8,MAX_LEN=4,TAG_W=8,FRAMES=1,BEATS=1,PAIR_FACTORS=0,QUERY_FACTORS=0,MUL_STEPS=0;
    localparam integer W=DATA_W,CW=$clog2(MAX_LEN+1),DB=W*MAX_LEN*(MAX_LEN-1)/2,
        NB=W*(MAX_LEN*(MAX_LEN-1)/2+1)+$clog2(MAX_LEN)+1,OW=3+TAG_W+CW+W+NB+DB,
        BOUND=4+MAX_LEN*(MAX_LEN-1)/2*(W+4)+MAX_LEN*(3+MAX_LEN*(W+3)+MAX_LEN*(MAX_LEN-1)/2*(W+4));
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_x=0,s_y=0,s_query=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;wire [CW-1:0] m_count;
    wire signed [W-1:0] m_query;wire [TAG_W-1:0] m_tag;wire [2:0] m_errors;
    wire signed [NB-1:0] m_numerator;wire [DB-1:0] m_denominator;
    rational_polynomial_interpolate #(.DATA_W(W),.MAX_LEN(MAX_LEN),.TAG_W(TAG_W)) dut(.*);
    wire [OW-1:0] word={m_errors,m_tag,m_count,m_query,m_numerator,m_denominator};
    reg [OW-1:0] expected[0:FRAMES-1];reg [31:0] latency[0:FRAMES-1];
    integer cycle=0,held_cycles=0,source_stalls=0,read_checks=0,multiply_checks=0;
    integer pair_factors=0,query_factors=0,mul_steps=0,reset_probes=0,fresh_checks=0;
    integer accepted=0,outputs=0,maximum_latency=0,ii1_checks=0;
    reg main_active=1,previous_sink_stall=0,previous_source_stall=0;
    reg [OW-1:0] previous_word;reg [3*W+TAG_W+1:0] previous_source;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin previous_sink_stall=0;previous_source_stall=0;end
        else begin
            if(previous_sink_stall && (!m_valid || word!==previous_word))$fatal(1,"held output changed");
            if(previous_source_stall && (!s_valid || {s_tag,s_x,s_y,s_query,s_keep,s_last}!==previous_source))
                $fatal(1,"source changed before acceptance");
            if(m_valid && !m_ready)held_cycles=held_cycles+1;
            if(s_valid && !s_ready)source_stalls=source_stalls+1;
            previous_sink_stall=m_valid && !m_ready;previous_word=word;
            previous_source_stall=s_valid && !s_ready;previous_source={s_tag,s_x,s_y,s_query,s_keep,s_last};
            case(dut.state)
                2:begin if(dut.pair_a>=dut.count)$fatal(1,"pair A read ownership");read_checks=read_checks+1;end
                3:begin if(dut.pair_b>=dut.count)$fatal(1,"pair B read ownership");read_checks=read_checks+1;end
                8:begin if(dut.term_i>=dut.count)$fatal(1,"term read ownership");read_checks=read_checks+1;end
                10:begin if(dut.query_i>=dut.count)$fatal(1,"query read ownership");read_checks=read_checks+1;end
                default:begin end
            endcase
            if(dut.state==4)begin
                if(dut.pair_a>=dut.pair_b || dut.pair_b>=dut.count || dut.pair_magnitude[W])$fatal(1,"pair factor domain");
                if(main_active)pair_factors=pair_factors+1;
            end
            if(dut.state==11)begin
                if(dut.query_i>=dut.count || dut.query_magnitude[W])$fatal(1,"query factor domain");
                if(main_active)query_factors=query_factors+1;
            end
            if(dut.state==5)begin
                if(dut.mul_step>=W)$fatal(1,"serial multiplier domain");
                multiply_checks=multiply_checks+1;if(main_active)mul_steps=mul_steps+1;
            end
            if(m_valid && s_ready)$fatal(1,"overlapped frame ownership");
        end
        if(cycle>4000000)$fatal(1,"finite cycle watchdog");
    end
    task push;
        input signed [W-1:0] x_value,y_value,q_value;
        input integer keep_value,last_value;input [TAG_W-1:0] tag_value;
        output integer edge_number;
        begin
            // Successive calls drive at consecutive negedges: accepted II=1.
            @(negedge clk);s_valid=1;s_x=x_value;s_y=y_value;s_query=q_value;
            s_keep=keep_value;s_last=last_value;s_tag=tag_value;#1;
            while(s_ready!==1'b1)begin @(negedge clk);#1;end
            @(posedge clk);#1;edge_number=cycle;
        end
    endtask
    task stop_source;
        begin @(negedge clk);s_valid=0;#1;end
    endtask
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready!==0 || m_valid!==0)$fatal(1,"reset interface gate");
            @(posedge clk);#1;
            if(dut.state!==0 || dut.count!==0 || dut.started!==0 || dut.overflow!==0 || dut.duplicate!==0 ||
               m_numerator!==0 || m_denominator!==0 || m_errors!==0 || m_query!==0 || m_tag!==0)
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
                if(guard>BOUND)$fatal(1,"first-valid bound");
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
            push(-1,-1,-1,1,0,{TAG_W{1'b1}},e);push(0,0,0,1,1,0,e);stop_source;wait_output;
            if(m_count!==2 || m_query!=={W{1'b1}} || m_numerator!=={NB{1'b1}} || m_denominator!==1 ||
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
                3:target_seen=dut.state==1;
                4:target_seen=dut.state==2 && !dut.numerator_role;
                5:target_seen=dut.state==3 && !dut.numerator_role;
                6:target_seen=dut.state==4 && !dut.numerator_role;
                7:target_seen=dut.state==5 && !dut.numerator_role && dut.mul_step==0;
                8:target_seen=dut.state==5 && !dut.numerator_role && dut.mul_step==W/2;
                9:target_seen=dut.state==5 && !dut.numerator_role && dut.mul_step==W-1;
                10:target_seen=dut.state==6 && !dut.numerator_role;
                11:target_seen=dut.state==7;
                12:target_seen=dut.state==8;
                13:target_seen=dut.state==9;
                14:target_seen=dut.state==10;
                15:target_seen=dut.state==11 && dut.query_i==dut.term_i;
                16:target_seen=dut.state==5 && dut.mul_query && dut.term_i==1 && dut.query_i==0 && dut.mul_step==0 && dut.mul_factor==0;
                17:target_seen=dut.state==12;
                18:target_seen=dut.state==2 && dut.numerator_role;
                19:target_seen=dut.state==13;
                20:target_seen=dut.state==14;
                21:target_seen=dut.state==15 && m_errors==0;
                22:target_seen=dut.state==0 && dut.overflow;
                23:target_seen=dut.state==15 && m_errors==6;
                24:target_seen=dut.state==15 && m_errors==1;
                25:target_seen=dut.state==15 && m_errors==2;
                26:target_seen=dut.state==15 && m_errors==4;
                default:target_seen=0;
            endcase
        end
    endfunction
    task probe;
        input integer id;
        integer k,e,guard;reg [OW-1:0] held;
        begin
            case(id)
                0:begin end
                1:begin push(-1,-1,-1,0,0,1,e);stop_source;end
                2:begin push(-1,-1,-1,1,0,1,e);stop_source;end
                22,23:begin
                    for(k=0;k<=MAX_LEN;k=k+1)push(-1,0,-1,1,(id==23 && k==MAX_LEN),1,e);
                    stop_source;
                end
                24:begin push(-1,0,-1,0,1,1,e);stop_source;end
                25:begin push(-1,0,-1,1,0,1,e);push(-1,-1,0,1,1,0,e);stop_source;end
                26:begin
                    for(k=0;k<=MAX_LEN;k=k+1)push(-(1<<(W-1))+k,0,-1,1,k==MAX_LEN,1,e);
                    stop_source;
                end
                default:begin push(-1,-1,-1,1,0,1,e);push(0,0,0,1,1,0,e);stop_source;end
            endcase
            guard=0;
            while(!target_seen(id))begin
                @(negedge clk);#1;guard=guard+1;
                if(guard>BOUND)$fatal(1,"unreached reset target %0d",id);
            end
            if(id==21 || id>=23)begin
                held=word;s_valid=1;s_x=-1;s_y=0;s_query=0;s_keep=1;s_last=1;s_tag=0;
                repeat(3)begin
                    @(negedge clk);#1;
                    if(!m_valid || word!==held || s_ready || !target_seen(id))$fatal(1,"held reset target");
                end
            end
            reset_probes=reset_probes+1;reset_now;fresh;
        end
    endtask
    integer input_fd,trace_fd,rc,fi,bi,keep_value,last_value,e,previous_edge,tail_edge,delay_observed;
    reg [W-1:0] x_value,y_value,q_value;reg [TAG_W-1:0] tag_value;reg [OW-1:0] held;
    reg [2047:0] input_path,expected_path,latency_path,trace_path;
    initial begin
        if(!$value$plusargs("INPUTS=%s",input_path) || !$value$plusargs("EXPECTED=%s",expected_path) ||
           !$value$plusargs("LATENCY=%s",latency_path) || !$value$plusargs("TRACE=%s",trace_path))$fatal(1,"missing local fixtures");
        input_fd=$fopen(input_path,"r");trace_fd=$fopen(trace_path,"w");
        if(!input_fd || !trace_fd)$fatal(1,"fixture open");
        $readmemh(expected_path,expected);$readmemh(latency_path,latency);
        @(negedge clk);#1;reset_now;
        for(fi=0;fi<FRAMES;fi=fi+1)begin
            last_value=0;previous_edge=0;
            while(!last_value)begin
                rc=$fscanf(input_fd,"%h %h %h %d %d %h\n",x_value,y_value,q_value,keep_value,last_value,tag_value);
                if(rc!=6)$fatal(1,"input fixture truncation");
                push(x_value,y_value,q_value,keep_value,last_value,tag_value,e);accepted=accepted+1;
                if(previous_edge)begin if(e!=previous_edge+1)$fatal(1,"collection II1");ii1_checks=ii1_checks+1;end
                previous_edge=e;if(last_value)tail_edge=e;
            end
            stop_source;wait_output;delay_observed=cycle-tail_edge;
            if(delay_observed!=latency[fi])$fatal(1,"tail latency %0d got %0d expected %0d",fi,delay_observed,latency[fi]);
            if(word!==expected[fi])$fatal(1,"full result frame %0d got %h expected %h",fi,word,expected[fi]);
            $fdisplay(trace_fd,"%h %0d",word,delay_observed);
            if(delay_observed>maximum_latency)maximum_latency=delay_observed;
            held=word;
            repeat(5)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"main output hold");end
            retire;outputs=outputs+1;
        end
        main_active=0;
        if(accepted!=BEATS || outputs!=FRAMES || pair_factors!=PAIR_FACTORS || query_factors!=QUERY_FACTORS || mul_steps!=MUL_STEPS)
            $fatal(1,"finite main totals pairs=%0d query=%0d mul=%0d",pair_factors,query_factors,mul_steps);
        for(bi=0;bi<27;bi=bi+1)probe(bi);
        $fclose(input_fd);$fclose(trace_fd);
        $display("PASS frames=%0d beats=%0d outputs=%0d latency_checks=%0d max_latency=%0d pair_factors=%0d query_factors=%0d mul_steps=%0d read_checks=%0d multiply_checks=%0d held_cycles=%0d source_stalls=%0d ii1_checks=%0d reset_probes=%0d fresh_checks=%0d",FRAMES,BEATS,outputs,FRAMES,maximum_latency,pair_factors,query_factors,mul_steps,read_checks,multiply_checks,held_cycles,source_stalls,ii1_checks,reset_probes,fresh_checks);
        $finish;
    end
endmodule
`default_nettype wire
