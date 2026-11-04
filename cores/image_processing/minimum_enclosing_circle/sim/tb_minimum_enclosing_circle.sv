// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_minimum_enclosing_circle;
    parameter integer COORD_W=8,MAX_POINTS=8,TAG_W=8,FRAMES=1;
    localparam integer W=COORD_W,M=MAX_POINTS,IW=($clog2(M)<1)?1:$clog2(M),
        CW=($clog2(M+1)<1)?1:$clog2(M+1),MW=3*W+5,RW=2*MW,
        OW=4+CW+TAG_W+3*IW+5*MW,MB=3*M+12,
        CMAX=1+M*(M-1)/2+M*(M-1)*(M-2)/6,
        BOUND=2+CMAX*(8+(16+4*M)*(MW+2)+3*M);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_x=0,s_y=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;
    wire signed [MW-1:0] m_center_x_num,m_center_y_num;
    wire [MW-1:0] m_den;wire [RW-1:0] m_radius_sq_num;
    wire [1:0] m_support,m_status;wire [IW-1:0] m_i,m_j,m_k;
    wire [CW-1:0] m_count;wire [TAG_W-1:0] m_tag;
    minimum_enclosing_circle #(.COORD_W(W),.MAX_POINTS(M),.TAG_W(TAG_W)) dut(.*);
    wire [OW-1:0] word={m_status,m_support,m_count,m_tag,m_i,m_j,m_k,m_center_x_num,m_center_y_num,m_den,m_radius_sq_num};
    reg [OW-1:0] expected,held,previous_word;
    reg [2*W+TAG_W+1:0] previous_source;
    reg previous_sink_stall=0,previous_source_stall=0,main_active=0;
    reg signed [RW-1:0] expected_product;
    integer cycle=0,frames=0,beats=0,outputs=0,candidates=0,point_checks=0,multiply_steps=0,read_checks=0;
    integer product_checks=0,ii1_checks=0,latency_checks=0,reset_probes=0,fresh_checks=0,queued_checks=0;
    integer held_cycles=0,source_stalls=0,state_mask=0;
    integer px[0:M-1],py[0:M-1],keep[0:MB-1],xx[0:MB-1],yy[0:MB-1],lasts[0:MB-1];
    reg [TAG_W-1:0] tags[0:MB-1];
    integer fd,trace_fd,rc,fi,k,nbeats,latency,want_cand,want_points,want_steps;
    integer parsed_keep,parsed_x,parsed_y,parsed_last;
    reg [TAG_W-1:0] parsed_tag;
    integer start_cand,start_points,start_steps,tail_edge,e,previous_edge,delay_observed,target,guard,found,idx;
    reg [2047:0] cases_path,trace_path;
    reg [W-1:0] want_x,want_y;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin previous_sink_stall=0;previous_source_stall=0;end
        else begin
            state_mask=state_mask|(1<<dut.state);
            if(previous_sink_stall && (!m_valid || word!==previous_word))$fatal(1,"complete output changed under stall");
            if(previous_source_stall && (!s_valid || {s_tag,s_x,s_y,s_keep,s_last}!==previous_source))$fatal(1,"source withdrawn/changed");
            if(m_valid && !m_ready)held_cycles=held_cycles+1;
            if(s_valid && !s_ready)source_stalls=source_stalls+1;
            previous_sink_stall=m_valid && !m_ready;previous_word=word;
            previous_source_stall=s_valid && !s_ready;previous_source={s_tag,s_x,s_y,s_keep,s_last};
            if(dut.state==7)expected_product=$signed(dut.operand_a)*$signed(dut.operand_b);
            if(dut.state==9 && dut.product!==expected_product)$fatal(1,"independent full signed product");
            if(main_active)begin
                if(dut.state==2)candidates=candidates+1;
                if(dut.state==13)point_checks=point_checks+1;
                if(dut.state==8)multiply_steps=multiply_steps+1;
                if(dut.state==9)product_checks=product_checks+1;
                idx=-1;
                case(dut.state)
                    4:idx=dut.ia;
                    5:idx=dut.ib;
                    6:idx=dut.ic;
                    12:idx=dut.scan;
                endcase
                if(idx>=0)begin
                    if(idx>=m_count)$fatal(1,"read outside current prefix");want_x=px[idx];want_y=py[idx];
                    if(dut.point_q!=={want_x,want_y})$fatal(1,"synchronous point read ownership");read_checks=read_checks+1;
                end
            end
            if(m_valid && s_ready)$fatal(1,"overlapping frame ownership");
        end
        if(cycle>2000000)$fatal(1,"finite watchdog");
    end
    task push(input integer keep_value,x,y,last_value,input reg [TAG_W-1:0] tag_value,output integer edge_number);
        begin
            @(negedge clk);s_valid=1;s_keep=keep_value;s_x=x;s_y=y;s_last=last_value;s_tag=tag_value;#1;
            if(!s_ready)$fatal(1,"unexpected input stall");@(posedge clk);#1;edge_number=cycle;
        end
    endtask
    task stop_source;begin @(negedge clk);s_valid=0;#1;end endtask
    task wait_output;
        integer g;
        begin g=0;while(!m_valid)begin @(negedge clk);#1;g=g+1;if(g>BOUND)$fatal(1,"bounded result missing");end end
    endtask
    task retire;
        begin m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;#1;if(m_valid || !s_ready)$fatal(1,"retirement");end
    endtask
    task analytic_input;
        integer edge_number;
        begin
            push(1,-1,-1,M==1,7,edge_number);
            if(M>1)begin push(1,1,-1,0,0,edge_number);push(1,0,1,1,0,edge_number);end
            tail_edge=edge_number;stop_source;
        end
    endtask
    task check_analytic;
        integer exact_latency;
        begin
            if(M==1)begin
                exact_latency=9+4*(MW+2);
                if(m_center_x_num!==-1 || m_center_y_num!==-1 || m_den!==1 || m_radius_sq_num!==0 ||
                    m_support!==1 || m_count!==1 || m_i!==0 || m_j!==0 || m_k!==0)$fatal(1,"analytic singleton");
            end else begin
                exact_latency=64+66*(MW+2);
                if(m_center_x_num!==0 || m_center_y_num!==-2 || m_den!==8 || m_radius_sq_num!==100 ||
                    m_support!==3 || m_count!==3 || m_i!==0 || m_j!==1 || m_k!==2)$fatal(1,"analytic acute rational circle");
            end
            if(m_status!==0 || m_tag!==(TAG_W'(7)) || cycle-tail_edge!=exact_latency)$fatal(1,"analytic tag/status/exact latency");
        end
    endtask
    task fresh;
        begin
            analytic_input;wait_output;check_analytic;held=word;
            repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held)$fatal(1,"fresh hold");end
            retire;repeat(2)begin @(negedge clk);#1;if(m_valid)$fatal(1,"stale fresh response");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    function target_seen(input integer id);
        begin
            case(id)
                0:target_seen=dut.state==0 && !dut.started;
                1:target_seen=dut.state==0 && dut.started;
                2:target_seen=dut.state==0 && dut.overflow && m_count==M;
                3:target_seen=dut.state==1;
                4:target_seen=dut.state==3;
                5:target_seen=dut.state==4;
                6:target_seen=dut.state==5;
                7:target_seen=dut.state==6;
                8:target_seen=dut.state==7;
                9:target_seen=dut.state==8 && dut.bit_index==0;
                10:target_seen=dut.state==8 && dut.bit_index==MW/2;
                11:target_seen=dut.state==8 && dut.bit_index==MW-1;
                12:target_seen=dut.state==9;
                13:target_seen=M==1 ? dut.state==13:dut.state==10;
                14:target_seen=dut.state==11;
                15:target_seen=dut.state==12;
                16:target_seen=dut.state==13 && dut.test_distance<=dut.radius_num;
                17:target_seen=dut.state==13 && dut.test_distance>dut.radius_num;
                18:target_seen=dut.state==14;
                19:target_seen=m_valid && m_status==0;
                20:target_seen=m_valid && m_status==1;
                21:target_seen=m_valid && m_status==2;
                default:target_seen=0;
            endcase
        end
    endfunction
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;#1;if(s_ready || m_valid)$fatal(1,"immediate reset gates");
            @(posedge clk);#1;
            if(dut.state!==0 || dut.started || dut.overflow || m_count!==0 || m_status!==0 || m_support!==0 ||
                m_center_x_num!==0 || m_center_y_num!==0 || m_den!==0 || m_radius_sq_num!==0 ||
                m_i!==0 || m_j!==0 || m_k!==0 || m_tag!==0)$fatal(1,"reset ownership/output cancellation");
            @(negedge clk);rst=0;#1;
        end
    endtask
    task probe(input integer id);
        integer q,edge_number;
        begin
            case(id)
                0:begin end
                1:begin push(0,1,-1,0,5,edge_number);stop_source;end
                2:begin for(q=0;q<=M;q=q+1)push(1,0,0,0,5,edge_number);stop_source;end
                20:begin push(0,-1,1,1,5,edge_number);stop_source;end
                21:begin for(q=0;q<=M;q=q+1)push(1,0,0,q==M,5,edge_number);stop_source;end
                default:analytic_input;
            endcase
            guard=0;while(!target_seen(id))begin @(negedge clk);#1;guard=guard+1;if(guard>BOUND)$fatal(1,"unreachable reset target%0d",id);end
            if(id>=19)begin
                held=word;s_valid=1;s_keep=1;s_x=-1;s_y=-1;s_last=1;s_tag=0;
                repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"blocked source before cancellation");end
            end
            reset_probes=reset_probes+1;reset_now;fresh;
        end
    endtask
    task queued;
        begin
            analytic_input;wait_output;check_analytic;held=word;
            s_valid=1;s_keep=1;s_x=-1;s_y=-1;s_last=1;s_tag=0;
            repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"queued blocked source");end
            m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;#1;if(!s_ready)$fatal(1,"queued admission");
            @(posedge clk);#1;tail_edge=cycle;stop_source;wait_output;
            if(m_status!==0 || m_support!==1 || m_count!==1 || m_tag!==0 || m_i!==0 || m_j!==0 || m_k!==0 ||
                m_center_x_num!==-1 || m_center_y_num!==-1 || m_den!==1 || m_radius_sq_num!==0 ||
                cycle-tail_edge!=9+4*(MW+2))$fatal(1,"queued complete singleton");
            held=word;repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held)$fatal(1,"queued hold");end
            retire;queued_checks=queued_checks+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("CASES=%s",cases_path) || !$value$plusargs("TRACE=%s",trace_path))$fatal(1,"paths");
        fd=$fopen(cases_path,"r");trace_fd=$fopen(trace_path,"w");if(!fd || !trace_fd)$fatal(1,"fixture files");
        @(negedge clk);#1;reset_now;
        for(fi=0;fi<FRAMES;fi=fi+1)begin
            rc=$fscanf(fd,"%d %h %d %d %d %d\n",nbeats,expected,latency,want_cand,want_points,want_steps);if(rc!=6 || nbeats>MB)$fatal(1,"fixture header");
            idx=0;
            for(k=0;k<nbeats;k=k+1)begin
                rc=$fscanf(fd,"%d %d %d %d %h\n",parsed_keep,parsed_x,parsed_y,parsed_last,parsed_tag);if(rc!=5)$fatal(1,"fixture beat");
                keep[k]=parsed_keep;xx[k]=parsed_x;yy[k]=parsed_y;lasts[k]=parsed_last;tags[k]=parsed_tag;
                if(keep[k] && idx<M)begin px[idx]=xx[k];py[idx]=yy[k];idx=idx+1;end
            end
            start_cand=candidates;start_points=point_checks;start_steps=multiply_steps;main_active=1;previous_edge=0;
            for(k=0;k<nbeats;k=k+1)begin
                if(fi%3==0 && k%2==1)begin @(negedge clk);s_valid=0;@(posedge clk);#1;end
                push(keep[k],xx[k],yy[k],lasts[k],tags[k],e);beats=beats+1;
                if(previous_edge && e==previous_edge+1)ii1_checks=ii1_checks+1;previous_edge=e;
            end
            tail_edge=e;stop_source;wait_output;delay_observed=cycle-tail_edge;
            if(word!==expected || delay_observed!=latency)$fatal(1,"frame%0d complete result/latency got%h want%h delay%0d want%0d",fi,word,expected,delay_observed,latency);
            if(candidates-start_cand!=want_cand || point_checks-start_points!=want_points || multiply_steps-start_steps!=want_steps)$fatal(1,"exact frame work");
            $fdisplay(trace_fd,"%h %0d",word,delay_observed);latency_checks=latency_checks+1;held=word;
            repeat(4)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"main held output");end
            retire;main_active=0;frames=frames+1;outputs=outputs+1;
        end
        rc=$fscanf(fd,"%d",idx);if(rc==1)$fatal(1,"extra fixtures");$fclose(fd);$fclose(trace_fd);
        for(target=0;target<22;target=target+1)if(!(M==1 && (target==17 || target==18)))probe(target);
        queued;
        $display("PASS frames=%0d beats=%0d outputs=%0d candidates=%0d point_checks=%0d multiply_steps=%0d read_checks=%0d product_checks=%0d ii1_checks=%0d latency_checks=%0d reset_probes=%0d fresh_checks=%0d queued_checks=%0d held_cycles=%0d source_stalls=%0d state_mask=%0d",
            frames,beats,outputs,candidates,point_checks,multiply_steps,read_checks,product_checks,ii1_checks,latency_checks,reset_probes,fresh_checks,queued_checks,held_cycles,source_stalls,state_mask);
        $finish;
    end
endmodule
`default_nettype wire
