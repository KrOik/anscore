// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_steiner;
    parameter N=8,K=4,W=16,T=8;
    localparam IW=$clog2(N),SW=W+IW,CW=$clog2(N+1),E=N*(N-1)/2;
    localparam M=(1<<K)-1;
    localparam D=N*(4*M+M*(M+1)/2)+2*N*((3**K)-(1<<(K+1))+1)
        +M*(2*(N+1)*(N+1)+7*N*N+1);
    localparam BOUND=D+6*E+6*N+1080;
    reg clk=0,rst=0,s_valid=0,s_present=0,s_last=0,m_ready=0;
    reg [W-1:0] s_weight=0;
    reg [N-1:0] s_terminals=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_summary,m_feasible;
    wire [IW-1:0] m_u,m_v;
    wire [W-1:0] m_weight;
    wire [SW-1:0] m_total_cost;
    wire [CW-1:0] m_selected_count;
    wire [N-1:0] m_vertices,m_terminals;
    wire [3:0] m_error;
    wire [T-1:0] m_tag;
    exact_undirected_steiner_tree #(.NUM_NODES(N),.MAX_TERMINALS(K),
        .WEIGHT_W(W),.TAG_W(T)) dut(.*);
    always #5 clk=~clk;
    integer cycle=0,active=-1,pin_frame=-1,pin_index=0,reset_id=-1;
    integer fd,rc,frames,f,case_id,header_tag,header_terms,idx,watch,got_sum,hold;
    integer offered=0,cut_seen=0,edge_held=0,summary_held=0,future=0;
    integer pres[0:E-1],weight[0:E-1],last[0:E-1];
    reg [4095:0] fixture,job_name;
    reg input_held=0,output_held=0;
    reg [W+N+T+1:0] previous_input;
    localparam OW=1+2*IW+W+SW+CW+2*N+1+4+T;
    reg [OW-1:0] previous_output;
    wire [W+N+T+1:0] input_fields={s_present,s_weight,s_last,s_terminals,s_tag};
    wire [OW-1:0] output_fields={m_summary,m_u,m_v,m_weight,m_total_cost,
        m_selected_count,m_vertices,m_terminals,m_feasible,m_error,m_tag};

    // Observe pre-edge values, the same values consumed by DUT nonblocking logic.
    always @(posedge clk) begin
        cycle=cycle+1;
        if(cycle>6*(BOUND+4000))$fatal(1,"job cycle bound");
        if(rst)begin
            if(s_ready!==0 || m_valid!==0)$fatal(1,"reset masking");
            $display("RST %0d %0d",cycle,cut_seen);
            input_held=0;output_held=0;
        end else begin
            if(input_held && (!s_valid || input_fields!==previous_input))$fatal(1,"input hold");
            if(output_held && (!m_valid || output_fields!==previous_output))$fatal(1,"output hold");
            if(s_ready && m_valid)$fatal(1,"frame overlap");
            if(s_valid)$display("PIN %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                cycle,pin_frame,pin_index,s_present,s_weight,s_last,s_terminals,s_tag,s_ready);
            if(m_valid)begin
                $display("POUT %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    cycle,active,m_ready,m_summary,m_u,m_v,m_weight,m_total_cost,
                    m_selected_count,m_vertices,m_terminals,m_feasible,m_error,m_tag);
                if(!m_ready && !m_summary)edge_held=edge_held+1;
                if(!m_ready && m_summary)summary_held=summary_held+1;
            end
            input_held=s_valid&&!s_ready;previous_input=input_fields;
            output_held=m_valid&&!m_ready;previous_output=output_fields;
        end
    end

    task read_frame;
        begin
            rc=$fscanf(fd,"%d %d %d\n",case_id,header_tag,header_terms);
            if(rc!=3)$fatal(1,"frame header");
            for(idx=0;idx<E;idx=idx+1)begin
                rc=$fscanf(fd,"%d %d %d\n",pres[idx],weight[idx],last[idx]);
                if(rc!=3)$fatal(1,"edge input");
            end
        end
    endtask
    task begin_frame;
        begin
            active=case_id;pin_frame=case_id;pin_index=0;
            $display("FRAME %0d %0d %0d %0d",cycle,case_id,header_tag,header_terms);
        end
    endtask
    task drive_edge(input integer j);
        begin
            s_valid=1;s_present=pres[j];s_weight=weight[j];s_last=last[j];pin_index=j;
            // Only the first accepted edge captures frame metadata.
            s_terminals=(j==0)?header_terms:~header_terms;
            s_tag=(j==0)?header_tag:~header_tag;
        end
    endtask
    task reset_three;
        begin
            rst=1;s_valid=1;m_ready=1;
            repeat(3)@(posedge clk);
            @(negedge clk);rst=0;s_valid=0;m_ready=0;
        end
    endtask
    task send_frame;
        integer j;
        begin
            begin_frame();
            for(j=0;j<E;j=j+1)begin
                @(negedge clk);drive_edge(j);
                @(posedge clk);
                while(!s_ready)@(posedge clk);
            end
            @(negedge clk);s_valid=0;
        end
    endtask
    task drain_frame;
        begin
            got_sum=0;hold=0;watch=0;
            while(!got_sum)begin
                @(negedge clk);
                if(m_valid && hold<3)begin m_ready=0;hold=hold+1;end
                else m_ready=1;
                @(posedge clk);watch=watch+1;
                if(watch>BOUND+200)$fatal(1,"frame result deadline");
                if(m_valid && m_ready)begin got_sum=m_summary;hold=0;end
            end
            @(negedge clk);m_ready=0;
        end
    endtask
    function automatic cut_predicate;
        begin
            case(reset_id)
                0:cut_predicate=dut.state==dut.CAPTURE && dut.input_count==3;
                1:cut_predicate=dut.state==dut.LEFT_TAKE && dut.mask==3;
                2:cut_predicate=dut.state==dut.DST_TAKE && dut.mask==1 &&
                    dut.source_vertex==1 && dut.target_vertex==3;
                3:cut_predicate=dut.state==dut.TRACE_TAKE && dut.pending_count!=0;
                4:cut_predicate=dut.state==dut.OUT_EDGE && m_valid && !m_ready && edge_held!=0;
                5:cut_predicate=dut.state==dut.OUT_SUM && m_valid && !m_ready && summary_held!=0;
                default:cut_predicate=0;
            endcase
        end
    endfunction
    task interrupted_owner;
        integer j,ticks;
        begin:owner
            begin_frame();j=0;ticks=0;
            forever begin
                @(negedge clk);ticks=ticks+1;
                if(ticks>BOUND+E*4)$fatal(1,"reset predicate unreachable");
                if(cut_predicate())begin
                    $display("CUT %0d %0d %0d %0d %0d %0d %0d %0d",cycle,reset_id,
                        dut.state,dut.input_count,(reset_id>=1 && reset_id<=3)?dut.mask:0,
                        (reset_id==2)?dut.source_vertex:0,(reset_id==2)?dut.target_vertex:0,
                        (reset_id==3)?dut.pending_count:0);
                    cut_seen=1;reset_three();disable owner;
                end
                if(j<E)drive_edge(j);else s_valid=0;
                m_ready=(reset_id==4)?0:((reset_id==5 && m_summary)?0:1);
                @(posedge clk);
                if(s_valid && s_ready)j=j+1;
            end
        end
    endtask
    initial begin
        if(!$value$plusargs("fixture=%s",fixture) || !$value$plusargs("job=%s",job_name))
            $fatal(1,"required plusargs");
        rc=$value$plusargs("reset=%d",reset_id);rc=$value$plusargs("future=%d",future);
        fd=$fopen(fixture,"r");if(fd==0)$fatal(1,"fixture open");
        rc=$fscanf(fd,"%d\n",frames);if(rc!=1 || frames<1)$fatal(1,"frame count");
        $display("BEGIN %0s %0d %0d %0d %0d %0d %0d",job_name,N,K,W,T,reset_id,frames);
        @(negedge clk);reset_three();
        for(f=0;f<frames;f=f+1)begin
            read_frame();
            if(reset_id>=0 && f==0)interrupted_owner();
            else begin
                send_frame();
                if(future && f==frames-1)begin
                    // This valid offer remains until the next frame ACTUALLY accepts it.
                    pin_frame=-2;pin_index=0;drive_edge(0);s_tag='h5a;s_terminals=header_terms;
                    $display("OFFER %0d",cycle);
                end
                drain_frame();
            end
        end
        if(future)begin
            @(posedge clk);
            while(!s_ready)@(posedge clk);
            // Sampled handshake is logged by the monitor before this negedge.
            @(negedge clk);
            $display("NEXTIN %0d",cycle);
            s_valid=0;cut_seen=2;reset_three();
        end
        rc=$fscanf(fd,"%d",idx);if(rc!=1 || idx!=-99)$fatal(1,"fixture sentinel");
        while(!$feof(fd))begin
            rc=$fgetc(fd);
            if(rc!=-1 && rc!=9 && rc!=10 && rc!=13 && rc!=32)$fatal(1,"trailing fixture");
        end
        $fclose(fd);
        repeat(4)begin @(posedge clk);if(m_valid)$fatal(1,"stale output");end
        @(negedge clk);$display("END %0d %0d %0d %0d",cycle,cut_seen,edge_held,summary_held);$finish;
    end
endmodule
