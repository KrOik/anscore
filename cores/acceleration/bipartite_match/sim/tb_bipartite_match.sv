// SPDX-License-Identifier: Apache-2.0
module tb_bipartite_match;
    parameter integer LEFT_N=8,RIGHT_N=8,TAG_W=8;
    localparam integer LW=(LEFT_N<2)?1:$clog2(LEFT_N),RW=(RIGHT_N<2)?1:$clog2(RIGHT_N);
    localparam integer MM=(LEFT_N<RIGHT_N)?LEFT_N:RIGHT_N,CW=(MM<2)?1:$clog2(MM+1);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg [LW-1:0] s_left=0;reg [RW-1:0] s_right=0;reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_matched,m_last,m_bad_index;
    wire [LW-1:0] m_left;wire [RW-1:0] m_right;
    wire [CW-1:0] m_cardinality;wire [TAG_W-1:0] m_tag;
    bipartite_match #(.LEFT_N(LEFT_N),.RIGHT_N(RIGHT_N),.TAG_W(TAG_W)) dut(.*);
    localparam integer OW=LW+RW+CW+TAG_W+3;
    wire [OW-1:0] bundle={m_left,m_right,m_cardinality,m_tag,m_matched,m_last,m_bad_index};
    reg held=0;reg [OW-1:0] held_bundle;
    integer cycles=0,stalls=0;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(cycles>5000000) $fatal(1,"global watchdog");
        if(rst) held<=0;
        else begin
            if(held && (!m_valid || bundle!==held_bundle)) $fatal(1,"held output changed");
            held<=m_valid && !m_ready;
            if(m_valid && !m_ready) begin held_bundle<=bundle;stalls<=stalls+1;end
            if(m_valid && s_ready) $fatal(1,"input ownership");
        end
    end
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;
            while(!s_ready) begin @(negedge clk);if(m_valid) $fatal(1,"ghost initialization");end
            repeat(3) begin @(posedge clk);if(m_valid) $fatal(1,"ghost after reset");end
        end
    endtask
    task reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task send(input integer l,r,keep,last,input reg[31:0] tag);
        reg accepted;
        begin
            @(negedge clk);s_valid=1;s_left=LW'(l);s_right=RW'(r);
            s_keep=(keep!=0);s_last=(last!=0);s_tag=TAG_W'(tag);accepted=0;
            while(!accepted) begin @(posedge clk);accepted=s_ready;end
            @(negedge clk);s_valid=0;
        end
    endtask
    task cancel_at(input integer target);
        integer timer;
        begin
            reset_core();send(0,0,(target!=1),(target!=1),7);timer=0;
            while(dut.state!=target) begin
                @(negedge clk);timer=timer+1;
                if(timer>5000) $fatal(1,"missing reset probe state %0d",target);
            end
            // The observed target is current at this negedge. Assert reset
            // now, so no intervening active edge can advance the target.
            reset_now();
        end
    endtask
    reg [RIGHT_N-1:0] allowed[0:LEFT_N-1],used_right;
    integer known[0:LEFT_N-1],previous[0:LEFT_N-1];
    string file_name;
    integer fd,rc,nin,expected_card,bad,compare_previous,graphs=0,tokens=0;
    integer l,r,keep,last,i,k,match_count,result_right;
    reg [31:0] tag,beat_tag;
    initial begin
        reset_core();
        // Interrupt the clear sweep too, before any graph can enter.
        @(negedge clk);rst=1;@(posedge clk);@(negedge clk);rst=0;
        if(LEFT_N>1) @(posedge clk);
        #1;if(dut.state!=0) $fatal(1,"clear reset phase");
        rst=1;@(posedge clk);reset_core();
        cancel_at(1);cancel_at(2);cancel_at(3);cancel_at(4);
        cancel_at(5);cancel_at(6);cancel_at(7);cancel_at(9);
        if(!$value$plusargs("VECTORS=%s",file_name)) $fatal(1,"missing vectors");
        fd=$fopen(file_name,"r");if(!fd) $fatal(1,"open vectors");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %h %d\n",nin,expected_card,bad,tag,compare_previous);
            if(rc!=5) $fatal(1,"graph header");
            for(i=0;i<nin;i=i+1) begin
                rc=$fscanf(fd,"%d %d %d %d %h\n",l,r,keep,last,beat_tag);
                if(rc!=5) $fatal(1,"input row");
                repeat((i+graphs)%3) @(negedge clk);
                send(l,r,keep,last,beat_tag);
            end
            for(i=0;i<LEFT_N;i=i+1) begin
                rc=$fscanf(fd,"%h %d\n",allowed[i],known[i]);if(rc!=2) $fatal(1,"expected graph");
            end
            i=0;k=0;match_count=0;used_right=0;
            // Force a held valid token even in singleton profiles whose
            // computation otherwise aligns with the periodic ready pattern.
            while(!m_valid) @(negedge clk);
            repeat(3) @(posedge clk);
            while(i<LEFT_N) begin
                @(negedge clk);m_ready=(k%7>=3);k=k+1;
                @(posedge clk);
                if(m_valid && m_ready) begin
                    if(m_left!==LW'(i) || m_last!==(i==LEFT_N-1) || m_bad_index!==bad[0] ||
                        m_tag!==TAG_W'(tag) || m_cardinality!==CW'(expected_card))
                        $fatal(1,"metadata graph=%0d left=%0d",graphs,i);
                    result_right=-1;
                    if(m_matched) begin
                        if(m_right>=RIGHT_N) $fatal(1,"right out of range");
                        if(!allowed[i][m_right] || used_right[m_right]) $fatal(1,"invalid matching edge");
                        used_right[m_right]=1;match_count=match_count+1;result_right=m_right;
                    end else if(m_right!==0) $fatal(1,"unmatched payload");
                    if(known[i]!=-2 && result_right!=known[i]) $fatal(1,"fixed schedule fixture");
                    if(compare_previous && previous[i]!=result_right) $fatal(1,"input-order-dependent tie");
                    previous[i]=result_right;i=i+1;tokens=tokens+1;
                end
                if(k>200000) $fatal(1,"graph watchdog");
            end
            if(match_count!=expected_card) $fatal(1,"nonmaximum cardinality graph=%0d got=%0d want=%0d",graphs,match_count,expected_card);
            @(negedge clk);m_ready=0;graphs=graphs+1;
        end
        while(!s_ready) @(negedge clk);
        repeat(10) begin @(posedge clk);if(m_valid) $fatal(1,"extra token");end
        if(stalls<1) $fatal(1,"no stall coverage");
        $display("PASS graphs=%0d tokens=%0d reset_probes=9 stalls=%0d",graphs,tokens,stalls);
        $finish;
    end
endmodule
