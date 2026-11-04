// SPDX-License-Identifier: Apache-2.0
module tb_kruskal_msf;
    parameter integer NUM_NODES=16,MAX_EDGES=32,WEIGHT_W=16,EDGE_TAG_W=8,GRAPH_TAG_W=8;
    localparam integer IW=(NUM_NODES<2)?1:$clog2(NUM_NODES);
    localparam integer CW=(NUM_NODES<2)?1:$clog2(NUM_NODES+1);
    localparam integer TW=WEIGHT_W+((NUM_NODES<3)?0:$clog2(NUM_NODES-1));
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg [IW-1:0] s_u=0,s_v=0;
    reg signed [WEIGHT_W-1:0] s_weight=0;
    reg [EDGE_TAG_W-1:0] s_edge_tag=0;
    reg [GRAPH_TAG_W-1:0] s_graph_tag=0;
    wire s_ready,m_valid,m_summary,m_bad_index,m_overflow;
    wire [IW-1:0] m_u,m_v;
    wire signed [WEIGHT_W-1:0] m_weight;
    wire [EDGE_TAG_W-1:0] m_edge_tag;
    wire [GRAPH_TAG_W-1:0] m_graph_tag;
    wire signed [TW-1:0] m_total_weight;
    wire [CW-1:0] m_selected,m_components;
    kruskal_msf #(.NUM_NODES(NUM_NODES),.MAX_EDGES(MAX_EDGES),.WEIGHT_W(WEIGHT_W),
        .EDGE_TAG_W(EDGE_TAG_W),.GRAPH_TAG_W(GRAPH_TAG_W)) dut(.*);
    localparam integer OW=1+2*IW+WEIGHT_W+EDGE_TAG_W+GRAPH_TAG_W+2+TW+2*CW;
    wire [OW-1:0] output_bundle={m_summary,m_u,m_v,m_weight,m_edge_tag,m_graph_tag,
        m_bad_index,m_overflow,m_total_weight,m_selected,m_components};
    reg held=0;reg [OW-1:0] held_bundle;
    integer cycles=0,stalls=0;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(cycles>2000000) $fatal(1,"global watchdog");
        if(rst) held<=0;
        else begin
            if(held && (!m_valid || output_bundle!==held_bundle)) $fatal(1,"unstable held output");
            held<=m_valid && !m_ready;
            if(m_valid && !m_ready) begin held_bundle<=output_bundle;stalls<=stalls+1;end
            if(m_valid && s_ready) $fatal(1,"input ownership during output");
        end
    end
    task reset_core;
        begin
            @(negedge clk);rst=1;s_valid=0;m_ready=0;
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;
            while(!s_ready) @(negedge clk);
            repeat(3) begin @(posedge clk);if(m_valid) $fatal(1,"ghost after reset");end
        end
    endtask
    task send(input integer u,v,w,tag,keep,last,input reg [31:0] gt);
        reg accepted;
        begin
            @(negedge clk);s_valid=1;s_u=IW'(u);s_v=IW'(v);s_weight=WEIGHT_W'(w);
            s_edge_tag=EDGE_TAG_W'(tag);s_keep=(keep!=0);s_last=(last!=0);s_graph_tag=GRAPH_TAG_W'(gt);
            accepted=0;
            while(!accepted) begin @(posedge clk);accepted=s_ready;end
            @(negedge clk);s_valid=0;
        end
    endtask
    task cancel_at(input integer target);
        integer timer;
        begin
            reset_core();
            if(target==1) send(0,0,0,0,0,0,7);
            else if(NUM_NODES==1) send(0,0,0,0,0,1,7);
            else send(NUM_NODES-1,0,-1,2,1,1,7);
            if(target==9) m_ready=1;
            timer=0;
            while(dut.state!=target) begin
                @(negedge clk);timer=timer+1;
                if(timer>5000) $fatal(1,"reset phase not reached %0d",target);
            end
            m_ready=0;reset_core();
        end
    endtask
    string file_name;
    integer fd,rc,nin,nout,total,sel,groups,bad,over,g,graphs=0,tokens=0;
    reg [31:0] gt,it,ig;
    integer iu,iv,iw,ik,il,i,j,k,running;
    integer eu[0:1023],ev[0:1023],ew[0:1023];reg [31:0] et[0:1023];
    initial begin
        reset_core();cancel_at(1);
        if(NUM_NODES>1) begin cancel_at(2);cancel_at(3);cancel_at(5);cancel_at(7);cancel_at(8);end
        cancel_at(9);
        if(!$value$plusargs("VECTORS=%s",file_name)) $fatal(1,"missing vectors");
        fd=$fopen(file_name,"r");if(!fd) $fatal(1,"open vectors");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d %h\n",nin,nout,total,sel,groups,bad,over,gt);
            if(rc!=8) $fatal(1,"graph header");
            for(i=0;i<nin;i=i+1) begin
                rc=$fscanf(fd,"%d %d %d %h %d %d %h\n",iu,iv,iw,it,ik,il,ig);
                if(rc!=7) $fatal(1,"input row");
                repeat((i+graphs)%3) @(negedge clk);
                send(iu,iv,iw,it,ik,il,ig);
            end
            for(i=0;i<nout;i=i+1) begin
                rc=$fscanf(fd,"%d %d %d %h\n",eu[i],ev[i],ew[i],et[i]);
                if(rc!=4) $fatal(1,"expected edge row");
            end
            i=0;k=0;running=0;
            while(i<=nout) begin
                @(negedge clk);m_ready=(k%7>=3);k=k+1;
                @(posedge clk);
                if(m_valid && m_ready) begin
                    if(m_graph_tag!==GRAPH_TAG_W'(gt) || m_bad_index!==bad[0] || m_overflow!==over[0])
                        $fatal(1,"metadata graph=%0d",graphs);
                    if(i<nout) begin
                        running=running+ew[i];
                        if(m_summary || m_u!==IW'(eu[i]) || m_v!==IW'(ev[i]) ||
                           m_weight!==WEIGHT_W'(ew[i]) || m_edge_tag!==EDGE_TAG_W'(et[i]))
                            $fatal(1,"edge graph=%0d idx=%0d got=(%0d,%0d,%0d,%0d) want=(%0d,%0d,%0d,%0d)",
                                graphs,i,m_u,m_v,m_weight,m_edge_tag,eu[i],ev[i],ew[i],et[i]);
                        if(m_total_weight!==TW'(running) || m_selected!==CW'(i+1) || m_components!==CW'(NUM_NODES-i-1))
                            $fatal(1,"running counters");
                    end else begin
                        if(!m_summary || m_u!==0 || m_v!==0 || m_weight!==0 || m_edge_tag!==0 ||
                           m_total_weight!==TW'(total) || m_selected!==CW'(sel) || m_components!==CW'(groups))
                            $fatal(1,"summary graph=%0d",graphs);
                    end
                    i=i+1;tokens=tokens+1;
                end
                if(k>100000) $fatal(1,"graph watchdog");
            end
            @(negedge clk);m_ready=0;
            graphs=graphs+1;
        end
        $fclose(fd);
        while(!s_ready) @(negedge clk);
        repeat(10) begin @(posedge clk);if(m_valid) $fatal(1,"extra token");end
        if(stalls<1) $fatal(1,"no output stalls");
        $display("PASS graphs=%0d tokens=%0d reset_cases=%0d stalls=%0d",graphs,tokens,(NUM_NODES>1)?7:2,stalls);
        $finish;
    end
endmodule
