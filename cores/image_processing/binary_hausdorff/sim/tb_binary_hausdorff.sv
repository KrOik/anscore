// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_binary_hausdorff;
    parameter integer WIDTH=16,HEIGHT=12,TAG_W=8,FRAMES=28;
    localparam integer N=WIDTH*HEIGHT,XW=($clog2(WIDTH)<1)?1:$clog2(WIDTH),
        YW=($clog2(HEIGHT)<1)?1:$clog2(HEIGHT),CW=($clog2(N+1)<1)?1:$clog2(N+1),
        DW=($clog2((WIDTH-1)*(WIDTH-1)+(HEIGHT-1)*(HEIGHT-1)+1)<1)?1:
        $clog2((WIDTH-1)*(WIDTH-1)+(HEIGHT-1)*(HEIGHT-1)+1),
        OW=5+TAG_W+2*CW+3*DW+4*XW+4*YW;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_a=0,s_b=0,s_sof=0,s_eol=0,m_ready=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_direction;
    wire [CW-1:0] m_count_a,m_count_b;
    wire [DW-1:0] m_ab_distance_sq,m_ba_distance_sq,m_distance_sq;
    wire [XW-1:0] m_ab_source_x,m_ab_target_x,m_ba_source_x,m_ba_target_x;
    wire [YW-1:0] m_ab_source_y,m_ab_target_y,m_ba_source_y,m_ba_target_y;
    wire [TAG_W-1:0] m_tag;wire [3:0] m_errors;
    binary_hausdorff #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) dut(.*);
    wire [OW-1:0] word={m_errors,m_tag,m_count_a,m_count_b,m_ab_distance_sq,m_ba_distance_sq,m_distance_sq,
        m_direction,m_ab_source_x,m_ab_source_y,m_ab_target_x,m_ab_target_y,
        m_ba_source_x,m_ba_source_y,m_ba_target_x,m_ba_target_y};
    reg [OW-1:0] expected[0:FRAMES-1];
    reg [31:0] latency[0:FRAMES-1];
    reg a[0:N-1],b[0:N-1];
    integer cycle=0,seen=0,map0=0,map1=0,replayed=0,counta=0,countb=0;
    integer map_checks=0,replay_checks=0,selected_checks=0,held_cycles=0,source_stalls=0;
    integer j,xx,yy,tx,ty,distance,best,best_index,guard;
    reg pending_sink=0,pending_source=0;
    reg [OW-1:0] held_word;
    reg [TAG_W+3:0] held_source;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin pending_sink=0;pending_source=0;end
        if(rst || dut.state==0)begin seen=0;map0=0;map1=0;replayed=0;counta=0;countb=0;end
        if(!rst)begin
            if(pending_sink && (!m_valid || word!==held_word))$fatal(1,"held result changed");
            if(pending_source && (!s_valid || {s_a,s_b,s_sof,s_eol,s_tag}!==held_source))$fatal(1,"pending source changed");
            pending_sink=m_valid && !m_ready;held_word=word;
            pending_source=s_valid && !s_ready;held_source={s_a,s_b,s_sof,s_eol,s_tag};
            if(pending_sink)held_cycles=held_cycles+1;
            if(pending_source)source_stalls=source_stalls+1;
            if(s_valid && s_ready)begin
                if(seen>=N || !dut.child_source_valid || !dut.child_ready)$fatal(1,"capture ownership");
                a[seen]=s_a;b[seen]=s_b;seen=seen+1;counta=counta+s_a;countb=countb+s_b;
            end
            if(dut.state==7 && dut.child_ready)begin
                if(seen!=N || dut.child_source_pixel!==!a[dut.feed_index] ||
                    dut.child_source_sof!==(dut.feed_index==0) || dut.child_source_eol!==(dut.feed_index%WIDTH==WIDTH-1))
                    $fatal(1,"replayed raw mask/markers");
                replayed=replayed+1;replay_checks=replay_checks+1;
            end
            if(dut.child_done && dut.child_error)$fatal(1,"regenerated child failed");
            if(dut.state==4 && dut.child_valid)begin
                if(seen!=N || dut.child_invalid || dut.child_x!==dut.map_index%WIDTH ||
                    dut.child_y!==dut.map_index/WIDTH || dut.child_sof!==(dut.map_index==0) ||
                    dut.child_eol!==(dut.map_index%WIDTH==WIDTH-1) || dut.child_last!==(dut.map_index==N-1))
                    $fatal(1,"complete child map ownership");
                if(dut.mask_q!=={a[dut.map_index],b[dut.map_index]})$fatal(1,"mask read ownership");
                xx=dut.map_index%WIDTH;yy=dut.map_index/WIDTH;best=2147483647;best_index=-1;
                for(j=0;j<N;j=j+1)if(dut.phase?a[j]:b[j])begin
                    tx=j%WIDTH;ty=j/WIDTH;distance=(xx-tx)*(xx-tx)+(yy-ty)*(yy-ty);
                    if(distance<best)begin best=distance;best_index=j;end
                end
                if(best_index<0 || dut.child_distance!==best || dut.child_nearest_x!==best_index%WIDTH ||
                    dut.child_nearest_y!==best_index/WIDTH)$fatal(1,"independent2D child map/nearest tie");
                if(!dut.phase)map0=map0+1;else begin
                    if(replayed!=N)$fatal(1,"incomplete replay");map1=map1+1;end
                map_checks=map_checks+1;
                if(dut.phase?b[dut.map_index]:a[dut.map_index])selected_checks=selected_checks+1;
            end
            if(m_valid)begin
                if(s_ready || seen!=N || m_count_a!==counta || m_count_b!==countb)$fatal(1,"response ownership/counts");
                if(m_errors==0)begin
                    if(map0!=N || map1!=N || replayed!=N || !dut.ab_seen || !dut.ba_seen)$fatal(1,"complete map work");
                end else begin
                    if(map0!=0 || map1!=0 || replayed!=0 || m_ab_distance_sq!==0 || m_ba_distance_sq!==0 ||
                        m_distance_sq!==0 || m_direction!==0 || m_ab_source_x!==0 || m_ab_source_y!==0 ||
                        m_ab_target_x!==0 || m_ab_target_y!==0 || m_ba_source_x!==0 || m_ba_source_y!==0 ||
                        m_ba_target_x!==0 || m_ba_target_y!==0)$fatal(1,"canonical error payload");
                end
            end
        end
        if(cycle>4000000)$fatal(1,"finite cycle watchdog");
    end
    task push;
        input integer av,bv,sof,eol;input [TAG_W-1:0] tag;
        output integer edge_number;
        begin
            @(negedge clk);s_valid=1;s_a=av;s_b=bv;s_sof=sof;s_eol=eol;s_tag=tag;#1;
            while(s_ready!==1'b1)begin @(negedge clk);#1;end
            @(posedge clk);#1;edge_number=cycle;
            @(negedge clk);s_valid=0;#1;
        end
    endtask
    task wait_output;
        integer k;
        begin k=0;while(!m_valid)begin @(negedge clk);#1;k=k+1;
            if(k>4*N*(WIDTH+HEIGHT+3)+20)$fatal(1,"result bound");end end
    endtask
    task retire;
        begin m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;s_valid=0;#1;
            if(m_valid)$fatal(1,"stale retired response");end
    endtask
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;#1;
            if(m_valid!==0 || s_ready!==0)$fatal(1,"reset gates");
            @(posedge clk);#1;
            if(dut.state!==0 || m_count_a!==0 || m_count_b!==0 || m_valid!==0)$fatal(1,"reset cancellation");
            @(negedge clk);rst=0;#1;
        end
    endtask
    task analytic_frame;
        input integer bad;
        integer p,e;
        begin for(p=0;p<N;p=p+1)push(p==0,p==N-1,(p==0)^(bad && p==0),
            p%WIDTH==WIDTH-1,{TAG_W{1'b1}},e);end
    endtask
    integer reset_probes=0,fresh_checks=0;
    task fresh;
        reg [OW-1:0] held;
        begin
            analytic_frame(0);wait_output;
            if(m_count_a!==1 || m_count_b!==1 || m_errors!==0 || m_tag!=={TAG_W{1'b1}} ||
                m_ab_distance_sq!==(WIDTH-1)*(WIDTH-1)+(HEIGHT-1)*(HEIGHT-1) || m_ba_distance_sq!==m_ab_distance_sq ||
                m_distance_sq!==m_ab_distance_sq || m_direction!==0 || m_ab_source_x!==0 || m_ab_source_y!==0 ||
                m_ab_target_x!==WIDTH-1 || m_ab_target_y!==HEIGHT-1 || m_ba_source_x!==WIDTH-1 ||
                m_ba_source_y!==HEIGHT-1 || m_ba_target_x!==0 || m_ba_target_y!==0)$fatal(1,"complete analytic fresh");
            held=word;repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held)$fatal(1,"fresh hold");end
            retire;repeat(3)begin @(negedge clk);#1;if(m_valid)$fatal(1,"postfresh stale valid");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    function target_seen;
        input integer id;
        begin case(id)
            0:target_seen=dut.state==0;
            1:target_seen=dut.state==1 && seen==1;
            2:target_seen=dut.state==2;
            3:target_seen=dut.state==3 && !dut.phase && dut.child_valid;
            4:target_seen=dut.state==4 && !dut.phase;
            5:target_seen=dut.state==5 && !dut.phase;
            6:target_seen=dut.state==6;
            7:target_seen=dut.state==7;
            8:target_seen=dut.state==3 && dut.phase && dut.child_valid;
            9:target_seen=dut.state==4 && dut.phase;
            10:target_seen=dut.state==5 && dut.phase;
            11:target_seen=dut.state==8 && m_errors==0;
            12:target_seen=dut.state==8 && m_errors!=0;
            13:target_seen=!dut.phase && dut.edt.state==1;
            14:target_seen=!dut.phase && dut.edt.state==2;
            15:target_seen=!dut.phase && dut.edt.state==3;
            16:target_seen=!dut.phase && dut.edt.state==4;
            17:target_seen=!dut.phase && dut.edt.state==5;
            18:target_seen=!dut.phase && dut.edt.state==6;
            19:target_seen=!dut.phase && dut.edt.state==7;
            default:target_seen=0;
        endcase end
    endfunction
    task probe;
        input integer id;
        integer e,k;reg [OW-1:0] held;
        begin
            reset_now;
            if(id==1)push(1,1,1,WIDTH==1,1,e);
            else if(id!=0)analytic_frame(id==12);
            k=0;
            while(!target_seen(id))begin @(negedge clk);#1;k=k+1;
                if(k>4*N*(WIDTH+HEIGHT+3)+20)$fatal(1,"unreached reset target %0d",id);end
            if(id==11 || id==12)begin
                held=word;s_valid=1;s_a=1;s_b=0;s_sof=1;s_eol=1;s_tag=0;
                repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"blocked held target");end
            end
            reset_probes=reset_probes+1;reset_now;fresh;
        end
    endtask
    integer input_fd,trace_fd,fi,p,rc,av,bv,sof,eol,e,tail_edge,delay_observed,outputs=0;
    integer main_map_checks=0,main_replay_checks=0,maximum_latency=0,id;
    reg [TAG_W-1:0] tag;
    reg [2047:0] input_path,expected_path,latency_path,trace_path;
    initial begin
        if(!$value$plusargs("INPUTS=%s",input_path) || !$value$plusargs("EXPECTED=%s",expected_path) ||
            !$value$plusargs("LATENCY=%s",latency_path) || !$value$plusargs("TRACE=%s",trace_path))$fatal(1,"missing fixtures");
        input_fd=$fopen(input_path,"r");trace_fd=$fopen(trace_path,"w");
        if(!input_fd || !trace_fd)$fatal(1,"fixture open");
        $readmemh(expected_path,expected);$readmemh(latency_path,latency);
        @(negedge clk);#1;reset_now;
        for(fi=0;fi<FRAMES;fi=fi+1)begin
            for(p=0;p<N;p=p+1)begin
                rc=$fscanf(input_fd,"%d %d %d %d %h\n",av,bv,sof,eol,tag);if(rc!=5)$fatal(1,"input truncation");
                push(av,bv,sof,eol,tag,e);if(p==N-1)tail_edge=e;
            end
            wait_output;delay_observed=cycle-tail_edge;
            if(delay_observed!=latency[fi])$fatal(1,"tail got %0d expected %0d",delay_observed,latency[fi]);
            if(word!==expected[fi])$fatal(1,"full Hausdorff frame %0d got %h expected %h",fi,word,expected[fi]);
            if(delay_observed>maximum_latency)maximum_latency=delay_observed;
            main_map_checks=main_map_checks+map0+map1;main_replay_checks=main_replay_checks+replayed;
            $fdisplay(trace_fd,"%h %0d",word,delay_observed);
            repeat(5)begin @(negedge clk);#1;if(!m_valid || s_ready)$fatal(1,"main hold");end
            retire;outputs=outputs+1;
        end
        for(id=0;id<20;id=id+1)if(!(N==1 && id==1))probe(id);
        $fclose(input_fd);$fclose(trace_fd);
        $display("PASS frames=%0d paired_pixels=%0d responses=%0d latency_checks=%0d max_latency=%0d main_maps=%0d main_replays=%0d map_checks=%0d replay_checks=%0d selected_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",FRAMES,FRAMES*N,outputs,FRAMES,maximum_latency,main_map_checks,main_replay_checks,map_checks,replay_checks,selected_checks,held_cycles,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
`default_nettype wire
