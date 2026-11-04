// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_label_region_adjacency;
    parameter integer W=64,H=64,L=4,K=15,T=8;
    localparam integer N=W*H,A=$clog2(N+1),S=$clog2(2*N+1),V=$clog2(K+1);
    localparam integer E=(K<2)?1:$clog2(K*(K-1)/2+1),TABLE=K*K;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;
    reg [L-1:0] s_label=0;reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,done_valid;
    wire [L-1:0] m_a,m_b;wire [S-1:0] m_contact_sides;
    wire [1:0] done_errors;wire [V-1:0] done_nodes;
    wire [A-1:0] done_foreground;wire [E-1:0] done_edges;
    wire [S-1:0] done_contact_sides;wire [T-1:0] done_tag;
    label_region_adjacency #(.WIDTH(W),.HEIGHT(H),.LABEL_W(L),.MAX_LABEL(K),.TAG_W(T)) dut(.*);
    integer cycles=0,event_cycle=0,source_stalls=0,edge_holds=0,done_holds=0;
    integer frames=0,edges=0,phase_resets=0,phase,i,j;
    bit main_checks=0,held_edge=0,held_done=0,held_source=0;
    reg [L+T+1:0] held_source_data;
    wire [L+T+1:0] source_data={s_label,s_sof,s_eol,s_tag};
    reg [2*L+S-1:0] held_edge_data;
    reg [2+V+A+E+S+T-1:0] held_done_data;
    wire [2*L+S-1:0] edge_data={m_a,m_b,m_contact_sides};
    wire [2+V+A+E+S+T-1:0] done_data={done_errors,done_nodes,done_foreground,done_edges,done_contact_sides,done_tag};
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>5000000) $fatal(1,"bounded watchdog");
        if(rst) begin held_edge<=0;held_done<=0;held_source<=0;end
        else begin
            if(held_source && (!s_valid || source_data!==held_source_data)) $fatal(1,"source violated hold");
            held_source<=s_valid&&!s_ready;held_source_data<=source_data;
            if(held_edge && (!m_valid || edge_data!==held_edge_data)) $fatal(1,"held edge changed");
            if(held_done && (!done_valid || done_data!==held_done_data)) $fatal(1,"held DONE changed");
            held_edge<=m_valid&&!m_ready;held_edge_data<=edge_data;
            held_done<=done_valid&&!done_ready;held_done_data<=done_data;
            if(m_valid && (s_ready || done_valid)) $fatal(1,"edge ownership overlap");
            if(done_valid && s_ready) $fatal(1,"DONE admitted input");
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;done_ready=0;
            #1;if(s_ready || m_valid || done_valid) $fatal(1,"reset transfer gating");
            repeat(2) @(negedge clk);rst=0;
            #1;if(m_valid || done_valid || dut.state!=dut.CLEAR) $fatal(1,"reset state");
        end
    endtask
    task automatic put(input [L-1:0] label_value,input bit sof,eol,
                       input [T-1:0] tag,input integer gap,input bit tail);
        integer ticks;
        begin
            repeat(gap) @(negedge clk);
            s_valid=1;s_label=label_value;s_sof=sof;s_eol=eol;s_tag=tag;
            ticks=0;@(posedge clk);
            while(!s_ready) begin
                source_stalls=source_stalls+1;ticks=ticks+1;
                if(ticks>TABLE+12) $fatal(1,"source stall bound");
                @(posedge clk);
            end
            #1;if(tail) event_cycle=cycles;
            @(negedge clk);s_valid=0;s_label=~label_value;s_sof=~sof;s_eol=~eol;s_tag=~tag;
        end
    endtask
    task automatic get_edge(input [L-1:0] a,b,input [S-1:0] sides,input integer delay,hold);
        integer ticks;
        begin
            ticks=0;
            while(!m_valid) begin
                if(done_valid || s_ready) $fatal(1,"edge missing");
                @(negedge clk);ticks=ticks+1;
                if(ticks>2*TABLE+16) $fatal(1,"edge timeout");
            end
            if(cycles-event_cycle!=delay) $fatal(1,"edge schedule got=%0d expected=%0d",cycles-event_cycle,delay);
            repeat(hold+1) begin
                if(!m_valid || edge_data!=={a,b,sides} || a>=b || sides==0)
                    $fatal(1,"edge mismatch frame=%0d got=%0d,%0d,%0d expected=%0d,%0d,%0d",frames,m_a,m_b,m_contact_sides,a,b,sides);
                edge_holds=edge_holds+1;@(negedge clk);
            end
            m_ready=1;@(posedge clk);#1;event_cycle=cycles;
            @(negedge clk);m_ready=0;
            if(main_checks) edges=edges+1;
        end
    endtask
    task automatic get_done(input [1:0] errors,input [V-1:0] nodes,
                            input [A-1:0] foreground,input [E-1:0] edge_count,
                            input [S-1:0] sides,input [T-1:0] tag,
                            input integer delay,hold);
        integer ticks;
        begin
            ticks=0;
            while(!done_valid) begin
                if(m_valid || s_ready) $fatal(1,"unexpected extra edge or capture");
                @(negedge clk);ticks=ticks+1;
                if(ticks>2*TABLE+16) $fatal(1,"DONE timeout");
            end
            if(delay>=0 && cycles-event_cycle!=delay) $fatal(1,"DONE schedule got=%0d expected=%0d",cycles-event_cycle,delay);
            repeat(hold+1) begin
                if(!done_valid || done_data!=={errors,nodes,foreground,edge_count,sides,tag})
                    $fatal(1,"DONE mismatch frame=%0d got=%h expected=%h",frames,done_data,{errors,nodes,foreground,edge_count,sides,tag});
                done_holds=done_holds+1;@(negedge clk);
            end
            done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;
            if(done_valid || m_valid) $fatal(1,"duplicate completion");
            if(main_checks) frames=frames+1;
        end
    endtask
    task automatic wait_state(input integer wanted);
        integer ticks;
        begin
            ticks=0;
            while(dut.state!=wanted) begin
                @(negedge clk);ticks=ticks+1;
                if(ticks>2*TABLE+16) $fatal(1,"missing reset phase %0d",wanted);
            end
        end
    endtask
    task automatic fresh_empty;
        integer n;
        begin
            for(n=0;n<N;n=n+1) put(0,n==0,n%W==W-1,{T{1'b1}},0,n==N-1);
            get_done(0,0,0,0,0,{T{1'b1}},2*TABLE+4,3);
        end
    endtask
    initial begin
        reset_now();
        for(phase=0;phase<14;phase=phase+1) begin
            if(!((phase==3 || phase==4) && (W<2 || K<2)) &&
               !((phase==6 || phase==7) && (H<2 || K<2)) &&
               !(phase==12 && (N<2 || K<2))) begin
                if(phase==0) begin
                    s_valid=1;s_label=1;s_sof=1;s_eol=W==1;
                    while(dut.clear_address!=TABLE/2) @(negedge clk);
                end
                else if(phase==1) begin
                    wait_state(1);
                    if(N>1) begin put(1,1,W==1,0,0,0);wait_state(1);end
                end else if(phase==3 || phase==4) begin
                    put(1,1,0,0,0,0);put(2,0,W==2,0,0,0);wait_state(phase);
                end else if(phase==6 || phase==7) begin
                    for(i=0;i<W;i=i+1) put(1,i==0,i==W-1,0,0,0);
                    put(2,0,W==1,0,0,0);wait_state(phase);
                end else if(phase>=9) begin
                    for(i=0;i<N;i=i+1) put((phase==12)?1+(i%2):0,i==0,i%W==W-1,0,0,i==N-1);
                    wait_state(phase);
                    if(phase==12) while(!held_edge) @(negedge clk);
                    if(phase==13) begin
                        s_valid=1;s_label=1;s_sof=1;s_eol=W==1;s_tag=0;
                        while(!held_done) @(negedge clk);
                        if(s_ready) $fatal(1,"pending next frame accepted");
                    end
                end else begin put(1,1,W==1,0,0,0);wait_state(phase);end
                reset_now();phase_resets=phase_resets+1;fresh_empty();reset_now();
            end
        end
        main_checks=1;
        `include "vectors.svh"
        main_checks=0;
        repeat(4) begin @(negedge clk);if(m_valid || done_valid) $fatal(1,"spurious output");end
        if(source_stalls==0 || done_holds==0) $fatal(1,"missing service coverage");
        $display("PASS RAG W=%0d H=%0d L=%0d K=%0d T=%0d frames=%0d edges=%0d source_stalls=%0d edge_holds=%0d done_holds=%0d resets=%0d",
                 W,H,L,K,T,frames,edges,source_stalls,edge_holds,done_holds,phase_resets);
        $finish;
    end
endmodule
