`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module tb;
parameter NUM_NODES=16,WEIGHT_W=16,TAG_W=8;
localparam NODE_W=(NUM_NODES>1)?$clog2(NUM_NODES):1;
localparam DIST_W=WEIGHT_W+NODE_W;
localparam SEM_W=32+2+2+NODE_W+2+NODE_W+DIST_W;
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
reg [31:0] s_from=0,s_to=0,s_source=0;
reg [WEIGHT_W-1:0] s_weight=0;
reg [TAG_W-1:0] s_tag=0;
wire s_ready,m_valid,m_reachable,m_parent_valid,m_first,m_last;
wire [NODE_W-1:0] m_vertex,m_parent;
wire [DIST_W-1:0] m_distance;
wire [31:0] m_source;wire [1:0] m_error;wire [TAG_W-1:0] m_tag;
dijkstra_sssp #(.NUM_NODES(NUM_NODES),.WEIGHT_W(WEIGHT_W),.TAG_W(TAG_W)) dut(.*);
wire [SEM_W-1:0] semantic_payload={m_source,m_error,m_last,m_first,m_vertex,
    m_reachable,m_parent_valid,m_parent,m_distance};
wire [SEM_W+TAG_W-1:0] payload={m_tag,semantic_payload};
reg [SEM_W+TAG_W-1:0] held;
reg [SEM_W-1:0] previous[0:NUM_NODES-1];
reg [DIST_W-1:0] expected_distance[0:NUM_NODES-1],distances[0:NUM_NODES-1];
reg expected_reach[0:NUM_NODES-1],reached[0:NUM_NODES-1],has_parent[0:NUM_NODES-1];
reg [NODE_W-1:0] parents[0:NUM_NODES-1];
reg [31:0] expected_parent[0:NUM_NODES-1];
reg present[0:NUM_NODES*NUM_NODES-1];
reg [WEIGHT_W-1:0] weights[0:NUM_NODES*NUM_NODES-1];
reg [NUM_NODES-1:0] walked;
integer fd,rc,frames,beats,frame,i,j,k,waited,reset_probes=0,stalls=0;
integer cycles=0,last_tail_cycle,reachable_count,expected_latency;
reg legal_tail;
always @(posedge clk) cycles=cycles+1;
integer keep_value,last_value,error_value,replay_value,present_value,reach_value,current_vertex,steps;
reg [31:0] from_value,to_value,source_value,expected_source;
reg [WEIGHT_W-1:0] weight_value;
reg [TAG_W-1:0] tag_value,expected_tag;

task wait_ready;
begin
    waited=0;
    while(!s_ready && waited<NUM_NODES*NUM_NODES+10) begin @(negedge clk);waited=waited+1;end
    if(!s_ready || m_valid) $fatal(1,"reset/clear did not rearm");
end endtask

task reset_now;
begin
    rst=1;s_valid=0;m_ready=0;
    repeat(2) @(posedge clk);
    @(negedge clk);rst=0;wait_ready();
end endtask

task reset_core;
begin @(negedge clk);reset_now();end endtask

task put(input [31:0] u,input [31:0] v,input [WEIGHT_W-1:0] w,
         input keep,input tail,input [31:0] source,input [TAG_W-1:0] tag);
begin
    @(negedge clk);s_valid=1;s_from=u;s_to=v;s_weight=w;s_keep=keep;
    s_last=tail;s_source=source;s_tag=tag;
    do @(posedge clk);while(!s_ready);
    @(negedge clk);s_valid=0;
    if(tail) begin
        last_tail_cycle=cycles;legal_tail=keep && u<NUM_NODES && v<NUM_NODES;
    end
end endtask

task abort_at(input integer target);
begin
    reset_core();
    put(0,0,1,1,target!=dut.CAPTURE,0,0);
    waited=0;
    while(dut.state!=target && waited<8*NUM_NODES*NUM_NODES+100) begin
        @(negedge clk);waited=waited+1;
    end
    if(dut.state!=target) $fatal(1,"reset target unreachable %0d",target);
    // Do not wait another edge after observing this target boundary.
    reset_now();reset_probes=reset_probes+1;
end endtask

initial begin
    // Interrupt the clear sweep, including the single-word one-cycle case.
    @(negedge clk);rst=0;
    repeat((NUM_NODES*NUM_NODES)/2) @(negedge clk);
    if(dut.state!=dut.CLEAR_EDGES) $fatal(1,"clear reset phase missed");
    reset_now();reset_probes=reset_probes+1;
    abort_at(dut.CAPTURE);abort_at(dut.EDGE_STORE);abort_at(dut.INIT_NODES);
    abort_at(dut.SELECT_READ);abort_at(dut.SELECT_COMPARE);abort_at(dut.SELECT_COMMIT);
    abort_at(dut.RELAX_READ);abort_at(dut.RELAX_COMPARE);
    abort_at(dut.OUTPUT_READ);abort_at(dut.OUTPUT_HOLD);
    fd=$fopen("vectors.txt","r");if(!fd) $fatal(1,"missing vectors");
    rc=$fscanf(fd,"%d",frames);if(rc!=1) $fatal(1,"missing frame count");
    for(frame=0;frame<frames;frame=frame+1) begin
        rc=$fscanf(fd,"%d %h %h %d %d",beats,expected_source,expected_tag,error_value,replay_value);
        if(rc!=5) $fatal(1,"bad frame header");
        for(i=0;i<beats;i=i+1) begin
            rc=$fscanf(fd,"%h %h %h %d %d %h %h",from_value,to_value,weight_value,
                keep_value,last_value,source_value,tag_value);
            if(rc!=7) $fatal(1,"bad input");
            if((frame+i)%5==0) repeat(2) @(negedge clk);
            put(from_value,to_value,weight_value,keep_value!=0,last_value!=0,source_value,tag_value);
        end
        for(i=0;i<NUM_NODES*NUM_NODES;i=i+1) begin
            rc=$fscanf(fd,"%d %h",present_value,weight_value);if(rc!=2) $fatal(1,"bad matrix");
            present[i]=present_value!=0;weights[i]=weight_value;
        end
        reachable_count=0;
        for(i=0;i<NUM_NODES;i=i+1) begin
            rc=$fscanf(fd,"%d %h %h",reach_value,expected_distance[i],expected_parent[i]);
            if(rc!=3) $fatal(1,"bad golden");expected_reach[i]=reach_value!=0;
            reachable_count=reachable_count+(reach_value!=0);
        end
        expected_latency=legal_tail+NUM_NODES+1;
        if(!(error_value&2)) expected_latency=legal_tail+reachable_count*(4*NUM_NODES+1)+3*NUM_NODES+2;
        for(i=0;i<NUM_NODES;i=i+1) begin
            waited=0;
            while(!m_valid && waited<8*NUM_NODES*NUM_NODES+100) begin
                @(negedge clk);waited=waited+1;
            end
            if(!m_valid) $fatal(1,"result timeout frame %0d",frame);
            if(i==0 && cycles-last_tail_cycle!=expected_latency)
                $fatal(1,"latency got=%0d expected=%0d",cycles-last_tail_cycle,expected_latency);
            held=payload;
            repeat(3) begin
                @(posedge clk);#1;
                if(!m_valid || payload!==held) $fatal(1,"held fields changed");
                stalls=stalls+1;
            end
            if(m_vertex!==i[NODE_W-1:0] || m_first!==(i==0) || m_last!==(i==NUM_NODES-1) ||
               m_source!==expected_source || m_tag!==expected_tag || m_error!==error_value[1:0] ||
               m_reachable!==expected_reach[i] || m_distance!==expected_distance[i])
                $fatal(1,"frame %0d node %0d reach/distance/status mismatch got=%h",frame,i,payload);
            if(!m_reachable || i==expected_source) begin
                if(m_parent_valid || m_parent!=0) $fatal(1,"invalid root/unreachable parent");
            end else if(!m_parent_valid || m_parent>=NUM_NODES) $fatal(1,"missing parent");
            if(expected_parent[i]!=32'hffffffff && m_parent!==expected_parent[i][NODE_W-1:0])
                $fatal(1,"hand-derived parent tie mismatch");
            if(replay_value && semantic_payload!==previous[i]) $fatal(1,"edge order changed tree");
            previous[i]=semantic_payload;distances[i]=m_distance;reached[i]=m_reachable;
            parents[i]=m_parent;has_parent[i]=m_parent_valid;
            @(negedge clk);m_ready=1;
            @(posedge clk);
            @(negedge clk);m_ready=0;
        end
        // Exact edge-distance and root-reaching certificates, independent of settlement order.
        for(i=0;i<NUM_NODES;i=i+1) if(reached[i] && i!=expected_source) begin
            if(!reached[parents[i]] || !present[parents[i]*NUM_NODES+i] ||
               {1'b0,distances[parents[i]]}+weights[parents[i]*NUM_NODES+i]!={1'b0,distances[i]})
                $fatal(1,"invalid shortest tree edge");
            walked=0;current_vertex=i;steps=0;
            while(current_vertex!=expected_source && steps<NUM_NODES) begin
                if(walked[current_vertex] || !has_parent[current_vertex]) $fatal(1,"parent cycle");
                walked[current_vertex]=1;current_vertex=parents[current_vertex];steps=steps+1;
            end
            if(current_vertex!=expected_source) $fatal(1,"parent chain did not reach source");
        end
    end
    $fclose(fd);
    repeat(NUM_NODES*NUM_NODES+5) @(negedge clk);
    if(m_valid || !s_ready) $fatal(1,"extra output or no rearm");
    $display("PASS dijkstra N=%0d W=%0d T=%0d graphs=%0d tokens=%0d reset_probes=%0d held=%0d",
        NUM_NODES,WEIGHT_W,TAG_W,frames,frames*NUM_NODES,reset_probes,stalls);
    $finish;
end
initial begin #50000000;$fatal(1,"watchdog");end
endmodule
