// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_binary_linear_recurrence;
    parameter integer MAX_BITS=64,TAG_W=8,BEATS=1,FRAMES=1;
    localparam integer CW=($clog2(MAX_BITS+1)<1)?1:$clog2(MAX_BITS+1);
    localparam integer OW=2+TAG_W+2*CW+MAX_BITS+2;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_bit=0,s_keep=0,s_last=0,m_ready=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_next;
    wire [CW-1:0] m_count,m_order;
    wire [MAX_BITS:0] m_connection;
    wire [TAG_W-1:0] m_tag;wire [1:0] m_errors;
    binary_linear_recurrence #(.MAX_BITS(MAX_BITS),.TAG_W(TAG_W)) dut(.*);
    wire [OW-1:0] word={m_errors,m_tag,m_count,m_order,m_connection,m_next};
    integer cycle=0,held_cycles=0,source_stalls=0,tap_checks=0,pred_checks=0;
    integer reset_probes=0,fresh_checks=0,accepted=0,outputs=0,maximum_latency=0;
    reg previous_sink_stall=0,previous_source_stall=0;
    reg [OW-1:0] previous_word;
    reg [TAG_W+2:0] previous_source;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin previous_sink_stall=0;previous_source_stall=0;end
        else begin
            if(previous_sink_stall && (!m_valid || word!==previous_word))$fatal(1,"held output changed");
            if(previous_source_stall && (!s_valid || {s_tag,s_bit,s_keep,s_last}!==previous_source))
                $fatal(1,"source changed before acceptance");
            if(m_valid && !m_ready)held_cycles=held_cycles+1;
            if(s_valid && !s_ready)source_stalls=source_stalls+1;
            previous_sink_stall=m_valid && !m_ready;previous_word=word;
            previous_source_stall=s_valid && !s_ready;previous_source={s_tag,s_bit,s_keep,s_last};
            if(dut.state==1)begin
                if(dut.tap<1 || dut.tap>dut.order_q || dut.order_q>dut.index_q || dut.index_q>=dut.count)
                    $fatal(1,"tap history ownership");
                tap_checks=tap_checks+1;
            end
            if(dut.state==5)begin
                if(dut.tap<1 || dut.tap>dut.order_q || dut.order_q>dut.count)$fatal(1,"prediction ownership");
                pred_checks=pred_checks+1;
            end
            if(m_valid && s_ready)$fatal(1,"frame ownership overlapped");
        end
        if(cycle>3000000)$fatal(1,"finite cycle watchdog");
    end
    task push;
        input integer bit_value,keep_value,last_value;
        input [TAG_W-1:0] tag_value;
        output integer edge_number;
        begin
            @(negedge clk);s_valid=1;s_bit=bit_value;s_keep=keep_value;s_last=last_value;s_tag=tag_value;
            #1;
            while(s_ready!==1'b1)begin @(negedge clk);#1;end
            @(posedge clk);#1;edge_number=cycle;
            @(negedge clk);s_valid=0;#1;
        end
    endtask
    task reset_now;
        begin
            // Called at the observed target's negedge: no active edge intervenes.
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready!==0 || m_valid!==0)$fatal(1,"reset interface gating");
            @(posedge clk);#1;
            if(dut.state!==0 || dut.count!==0 || dut.order_q!==0 || m_valid!==0)$fatal(1,"reset cancellation");
            @(negedge clk);rst=0;#1;
        end
    endtask
    task wait_output;
        integer guard;
        begin
            guard=0;
            while(!m_valid)begin
                @(negedge clk);#1;guard=guard+1;
                if(guard>4*MAX_BITS+10)$fatal(1,"first-valid bound");
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
        integer k,e,n;reg [OW-1:0] held;
        begin
            n=(MAX_BITS==1)?1:((MAX_BITS==3)?3:4);
            for(k=0;k<n;k=k+1)push((k%2==0),1,k==n-1,{TAG_W{1'b1}},e);
            wait_output;
            if(m_errors!==0 || m_count!==n || m_tag!=={TAG_W{1'b1}})$fatal(1,"fresh metadata");
            if(MAX_BITS==1)begin
                if(m_order!==1 || m_connection!==3 || m_next!==1)$fatal(1,"fresh one");
            end else begin
                if(m_order!==2 || m_connection!==5 || m_next!==(MAX_BITS==3?1'b0:1'b1))$fatal(1,"fresh alternating");
            end
            held=word;
            repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held)$fatal(1,"fresh hold");end
            retire;
            repeat(3)begin @(negedge clk);#1;if(m_valid)$fatal(1,"post-fresh stale output");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    function target_seen;
        input integer id;
        begin
            case(id)
                0:target_seen=dut.state==0 && !dut.started;
                1:target_seen=dut.state==0 && dut.started && dut.count==0;
                2:target_seen=(MAX_BITS==1)?dut.state==3:(dut.state==1 && dut.tap==1);
                3:target_seen=(MAX_BITS==1)?dut.state==3:(dut.state==2 && dut.tap==1);
                4:target_seen=dut.state==3;
                5:target_seen=dut.state==4;
                6:target_seen=dut.state==5;
                7:target_seen=dut.state==6;
                8:target_seen=dut.state==7 && m_errors==0;
                9:target_seen=dut.state==3 && dut.discrepancy && dut.jump;
                10:target_seen=(MAX_BITS==1)?(dut.state==3 && !dut.discrepancy):
                    (dut.state==3 && !dut.jump && dut.discrepancy);
                11:target_seen=dut.state==3 && !dut.discrepancy;
                12:target_seen=(MAX_BITS==1)?dut.state==3:(dut.state==1 && dut.tap==(dut.order_q+1)/2);
                13:target_seen=(MAX_BITS==1)?dut.state==3:(dut.state==2 && dut.tap==dut.order_q);
                14:target_seen=dut.state==5 && dut.tap==(dut.order_q+1)/2;
                15:target_seen=dut.state==6 && dut.tap==dut.order_q;
                16:target_seen=dut.state==7 && m_errors==1;
                17:target_seen=dut.state==0 && dut.overflow;
                18:target_seen=dut.state==0 && dut.count==1 && dut.started;
                19:target_seen=dut.state==7 && m_errors==2;
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
                1:push(1,0,0,1,e);
                9:begin for(k=0;k<MAX_BITS;k=k+1)push(k==MAX_BITS-1,1,k==MAX_BITS-1,1,e);end
                10:begin
                    if(MAX_BITS==1)push(0,1,1,1,e);
                    else begin push(1,1,0,1,e);push(0,1,1,1,e);end
                end
                11:push(0,1,1,1,e);
                16:push(1,0,1,1,e);
                17,19:begin
                    for(k=0;k<=MAX_BITS;k=k+1)push(1,1,(id==19 && k==MAX_BITS),1,e);
                end
                18:push(1,1,0,1,e);
                default:begin
                    for(k=0;k<MAX_BITS;k=k+1)
                        push((MAX_BITS==1 || k==MAX_BITS-2),1,k==MAX_BITS-1,1,e);
                end
            endcase
            guard=0;
            while(!target_seen(id))begin
                @(negedge clk);#1;guard=guard+1;
                if(guard>4*MAX_BITS+10)$fatal(1,"unreached reset target %0d",id);
            end
            if(id==8 || id==16 || id==19)begin
                held=word;s_valid=1;s_bit=1;s_keep=1;s_last=1;s_tag=0;
                repeat(3)begin
                    @(negedge clk);#1;
                    if(!m_valid || word!==held || s_ready || !target_seen(id))$fatal(1,"held reset target");
                end
            end
            reset_probes=reset_probes+1;
            reset_now;fresh;
        end
    endtask
    integer input_fd,expected_fd,trace_fd,rc,fi,bi,bit_value,keep_value,last_value,e;
    integer count_value,order_value,error_value,delay_value,tail_edge,delay_observed;
    reg [TAG_W-1:0] tag_value,expected_tag;
    reg [OW-1:0] held;
    reg [2047:0] input_path,expected_path,trace_path;
    initial begin
        if(!$value$plusargs("INPUTS=%s",input_path) || !$value$plusargs("EXPECTED=%s",expected_path) ||
           !$value$plusargs("TRACE=%s",trace_path))$fatal(1,"missing local fixtures");
        input_fd=$fopen(input_path,"r");expected_fd=$fopen(expected_path,"r");trace_fd=$fopen(trace_path,"w");
        if(!input_fd || !expected_fd || !trace_fd)$fatal(1,"fixture open");
        @(negedge clk);#1;reset_now;
        for(fi=0;fi<FRAMES;fi=fi+1)begin
            last_value=0;
            while(!last_value)begin
                rc=$fscanf(input_fd,"%d %d %d %h\n",bit_value,keep_value,last_value,tag_value);
                if(rc!=4)$fatal(1,"input fixture truncation");
                push(bit_value,keep_value,last_value,tag_value,e);accepted=accepted+1;
                if(last_value)tail_edge=e;
            end
            rc=$fscanf(expected_fd,"%d %d %d %h %d\n",count_value,order_value,error_value,expected_tag,delay_value);
            if(rc!=5)$fatal(1,"expected fixture truncation");
            wait_output;delay_observed=cycle-tail_edge;
            if(delay_observed!=delay_value)$fatal(1,"tail latency %0d got %0d expected %0d",fi,delay_observed,delay_value);
            if(m_count!==count_value || m_order!==order_value || m_errors!==error_value || m_tag!==expected_tag)
                $fatal(1,"result metadata frame %0d",fi);
            if(error_value && (m_connection!==0 || m_next!==0))$fatal(1,"error payload");
            $fdisplay(trace_fd,"%0d %0d %0d %h %0d %0d %h %0d",fi,m_count,m_order,m_connection,m_next,m_errors,m_tag,delay_observed);
            if(delay_observed>maximum_latency)maximum_latency=delay_observed;
            held=word;
            repeat(5)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"main output hold");end
            retire;outputs=outputs+1;
        end
        if(accepted!=BEATS || outputs!=FRAMES)$fatal(1,"finite totals");
        for(bi=0;bi<20;bi=bi+1)probe(bi);
        $fclose(input_fd);$fclose(expected_fd);$fclose(trace_fd);
        $display("PASS frames=%0d beats=%0d outputs=%0d latency_checks=%0d max_latency=%0d tap_checks=%0d prediction_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",FRAMES,BEATS,outputs,FRAMES,maximum_latency,tap_checks,pred_checks,held_cycles,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
`default_nettype wire
