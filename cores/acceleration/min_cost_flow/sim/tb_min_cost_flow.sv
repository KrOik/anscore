`timescale 1ns/1ps
module tb_min_cost_flow;
    parameter integer N=8,M=16,C=8,W=8,T=8;
    localparam integer V=(N<=2)?1:$clog2(N),EI=(M<=2)?1:$clog2(M),FW=C+$clog2(M),TW=C+W+$clog2(M);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,s_valid=0,s_keep=0,s_last=0,s_error=0,m_ready=0;
    reg [31:0] c_source=0,c_sink=0,c_limit=0,s_from=0,s_to=0;
    reg [T-1:0] c_tag=0;
    reg [C-1:0] s_capacity=0;reg [W-1:0] s_cost=0;
    wire c_ready,s_ready,m_valid,m_keep,m_last,m_target_met;
    wire [EI-1:0] m_index;wire [C-1:0] m_edge_flow;
    wire [FW-1:0] m_total_flow;wire [TW-1:0] m_total_cost;
    wire [5:0] m_error;wire [T-1:0] m_tag;
    min_cost_flow #(.NUM_NODES(N),.MAX_EDGES(M),.CAP_W(C),.COST_W(W),.TAG_W(T)) dut(.*);
    integer fd,rc,mode,units,unit_i,target=-1,armed=0,cancelled=0;
    integer row_count,expected_error,expected_outputs,case_id=0;
    reg [31:0] cmd_source,cmd_sink,cmd_limit,cmd_tag;
    reg [31:0] next_source,next_sink,next_limit,next_tag;
    integer next_valid,command_preaccepted=0;
    integer row_u[0:127],row_v[0:127],row_cap[0:127],row_cost[0:127];
    integer row_keep[0:127],row_last[0:127],row_error[0:127];
    longint unsigned expected_flow,expected_cost,latency_bound;
    integer flow_result[0:M-1];
    integer i,j,q,accepted,cycle=0,tail_cycle,first_cycle,prior_retired;
    integer reset_count=0,completed=0,source_holds=0,output_holds=0,queued=0;
    integer edge_reads=0,node_reads=0,path_reads=0,products=0,reverse_reads=0,reverse_writes=0;
    integer edge_owned[0:M-1],node_owned[0:N-1],path_owned[0:N-2];
    integer capture_count=0,returned=0;
    reg [255:0] previous_output;
    string input_path;
    function automatic [255:0] output_word;
        output_word={m_valid,m_keep,m_last,m_index,m_edge_flow,m_total_flow,m_total_cost,m_target_met,m_error,m_tag};
    endfunction
    function automatic integer hit_target;
        begin
            hit_target=0;
            if(target>=0 && target<37) hit_target=(dut.state==target);
            case(target)
            37:hit_target=(dut.state==1 && capture_count==0);
            38:hit_target=(dut.state==1 && capture_count==1);
            39:hit_target=(dut.state==1 && dut.error_q[3]);
            40:hit_target=m_valid && m_error==1;
            41:hit_target=m_valid && m_error==2;
            42:hit_target=m_valid && m_error==4;
            43:hit_target=m_valid && m_error==16;
            44:hit_target=m_valid && m_error==31;
            45:hit_target=dut.state==7 && dut.reverse_arc && dut.residual_capacity!=0 && dut.nq_reach && dut.arc_cost<0;
            46:hit_target=dut.state==27 && dut.update_reverse;
            47:hit_target=m_valid && m_error==0 && !m_target_met;
            48:hit_target=m_valid && m_error==0 && m_target_met && m_total_flow==0;
            49:hit_target=m_valid && m_last && prior_retired>0;
            50:hit_target=dut.state==33 && dut.edge_index!=0;
            51:hit_target=dut.state==4 && dut.pass_index!=0;
            52:hit_target=dut.state==22 && dut.path_count==N-1;
            53:hit_target=c_valid && !c_ready && dut.state!=0 && dut.state!=1;
            endcase
        end
    endfunction
    // Observe the first falling-edge occurrence; assert reset before active edge.
    always @(negedge clk) begin
        #1;
        if(armed && !cancelled && hit_target()) begin
            rst=1;cancelled=1;armed=0;
            $display("CANCEL %0d %0d",target,dut.state);
        end
    end
    // Ownership follows actual writes, and never relies on stale RAM reset values.
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst) begin
            capture_count=0;prior_retired=0;
            for(j=0;j<M;j=j+1) edge_owned[j]=0;
            for(j=0;j<N;j=j+1) node_owned[j]=0;
            for(j=0;j<N-1;j=j+1) path_owned[j]=0;
        end else begin
            if(c_valid && c_ready) begin
                capture_count=0;prior_retired=0;
                for(j=0;j<M;j=j+1) edge_owned[j]=0;
            end
            if(s_valid && s_ready && s_keep && capture_count<M) begin
                edge_owned[capture_count]=1;capture_count=capture_count+1;
            end
            if(dut.state==3) begin
                if(dut.init_node==0) for(j=0;j<N;j=j+1) node_owned[j]=0;
                node_owned[dut.init_node]=1;
            end
            if(dut.state==15) for(j=0;j<N-1;j=j+1) path_owned[j]=0;
            if(dut.state==20) begin
                if(dut.path_count>=N-1) $fatal(1,"path write range");
                path_owned[dut.path_count]=1;
            end
            if(dut.state==4 || dut.state==25 || dut.state==31 || dut.state==34) begin
                if(dut.edge_index>=capture_count || !edge_owned[dut.edge_index]) $fatal(1,"unowned edge read");
                edge_reads=edge_reads+1;
            end
            if(dut.state==18) begin
                if(dut.trace_edge>=capture_count || !edge_owned[dut.trace_edge]) $fatal(1,"unowned trace edge");
                edge_reads=edge_reads+1;
            end
            if(dut.state==6) begin
                if(dut.arc_u>=N || !node_owned[dut.arc_u]) $fatal(1,"unowned source node");node_reads=node_reads+1;
            end
            if(dut.state==8) begin
                if(dut.arc_v>=N || !node_owned[dut.arc_v]) $fatal(1,"unowned destination node");node_reads=node_reads+1;
            end
            if(dut.state==13) begin
                if(dut.sink>=N || !node_owned[dut.sink]) $fatal(1,"unowned sink");node_reads=node_reads+1;
            end
            if(dut.state==16) begin
                if(dut.trace_node>=N || !node_owned[dut.trace_node]) $fatal(1,"unowned trace node");node_reads=node_reads+1;
            end
            if(dut.state==23) begin
                if(dut.path_index>=dut.path_count || !path_owned[dut.path_index]) $fatal(1,"unowned path read");path_reads=path_reads+1;
            end
            if(dut.state==32) products=products+1;
            if(dut.state==7 && dut.reverse_arc && dut.residual_capacity!=0 && dut.nq_reach && dut.arc_cost<0) reverse_reads=reverse_reads+1;
            if(dut.state==27 && dut.update_reverse) reverse_writes=reverse_writes+1;
            if(c_valid && !c_ready) source_holds=source_holds+1;
            if(m_valid && !m_ready) output_holds=output_holds+1;
            if(m_valid && m_ready) prior_retired=prior_retired+1;
        end
    end
    task automatic falling;
        begin @(negedge clk);#2;end
    endtask
    task automatic active;
        begin @(posedge clk);#2;end
    endtask
    task automatic reset_dut;
        begin
            falling();rst=1;c_valid=0;s_valid=0;m_ready=0;active();
            falling();rst=0;active();
            if(m_valid || !c_ready || s_ready) $fatal(1,"reset ownership");
        end
    endtask
    task automatic read_case;
        longint unsigned a,b,c,d,e,f,g,h,k,l;
        begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d\n",a,b,c,d,e,f,g,h,k,l);
            if(rc!=10) $fatal(1,"case header %0d",rc);
            cmd_source=a;cmd_sink=b;cmd_limit=c;cmd_tag=d;row_count=e;expected_error=f;
            expected_flow=g;expected_cost=h;expected_outputs=k;latency_bound=l;
            rc=$fscanf(fd,"%d %d %d %d %d\n",next_valid,a,b,c,d);
            if(rc!=5) $fatal(1,"next command parse");
            next_source=a;next_sink=b;next_limit=c;next_tag=d;
            if(row_count<1 || row_count>128) $fatal(1,"row storage");
            for(q=0;q<row_count;q=q+1) begin
                rc=$fscanf(fd,"%d %d %d %d %d %d %d\n",a,b,c,d,e,f,g);
                if(rc!=7) $fatal(1,"row parse");
                row_u[q]=a;row_v[q]=b;row_cap[q]=c;row_cost[q]=d;row_keep[q]=e;row_last[q]=f;row_error[q]=g;
            end
        end
    endtask
    task automatic offer_command;
        begin
            if(command_preaccepted) begin command_preaccepted=0;falling();end
            else begin
            falling();
            if(!cancelled) begin c_valid=1;c_source=cmd_source;c_sink=cmd_sink;c_limit=cmd_limit;c_tag=cmd_tag[T-1:0];end
            accepted=0;
            while(!accepted && !cancelled) begin
                accepted=c_ready;
                active();
                if(!accepted && !cancelled) falling();
            end
            if(!cancelled) begin falling();c_valid=0;end
            end
        end
    endtask
    task automatic send_rows;
        integer r;
        begin
            for(r=0;r<row_count && !cancelled;r=r+1) begin
                // Deterministic input bubbles; valid row payload remains fixed until transfer.
                if((r%5)==2) begin s_valid=0;active();falling();end
                if(!cancelled) begin
                    s_valid=1;s_from=row_u[r];s_to=row_v[r];s_capacity=row_cap[r];s_cost=row_cost[r];
                    s_keep=row_keep[r];s_last=row_last[r];s_error=row_error[r];accepted=s_ready;
                    active();
                    while(!accepted && !cancelled) begin falling();accepted=s_ready;active();end
                    if(row_last[r]) tail_cycle=cycle;
                    falling();
                end
            end
            s_valid=0;
        end
    endtask
    task automatic pending_command;
        begin
            // The next command is held throughout solve/output. It is never
            // accepted by the owner; reset cancels it, or caller supplies next frame.
            c_valid=next_valid;c_source=next_source;c_sink=next_sink;c_limit=next_limit;c_tag=next_tag[T-1:0];
        end
    endtask
    task automatic check_record(input integer ordinal);
        begin
            if(m_error!==expected_error || m_tag!==cmd_tag[T-1:0] || m_total_flow!==expected_flow || m_total_cost!==expected_cost)
                $fatal(1,"metadata case%0d out%0d err%0d/%0d flow%0d/%0d cost%0d/%0d",case_id,ordinal,m_error,expected_error,m_total_flow,expected_flow,m_total_cost,expected_cost);
            if(m_target_met!==(expected_error==0 && expected_flow==cmd_limit)) $fatal(1,"met flag");
            if(m_last!==(ordinal==expected_outputs-1)) $fatal(1,"last");
            if(expected_error!=0 || capture_count==0) begin
                if(m_keep!==0 || m_index!==0 || m_edge_flow!==0) $fatal(1,"canonical summary");
            end else begin
                if(m_keep!==1 || m_index!==ordinal || m_edge_flow>row_cap[ordinal]) $fatal(1,"edge output");
                flow_result[ordinal]=m_edge_flow;
            end
        end
    endtask
    task automatic complete_case;
        integer ordinal,waited,stall;
        begin
            offer_command();send_rows();
            // A blocked offer is exercised only inside this command's lifetime.
            if(!cancelled) pending_command();
            ordinal=0;waited=0;first_cycle=-1;m_ready=0;
            while(ordinal<expected_outputs && !cancelled) begin
                if(m_valid) begin
                    if(first_cycle<0) begin
                        first_cycle=cycle;
                        if(first_cycle-tail_cycle>latency_bound) $fatal(1,"latency bound");
                    end
                    check_record(ordinal);previous_output=output_word();
                    for(stall=0;stall<2 && !cancelled;stall=stall+1) begin
                        active();falling();
                        if(!cancelled && output_word()!==previous_output) $fatal(1,"unstable held result");
                    end
                    if(!cancelled) begin m_ready=1;active();falling();m_ready=0;ordinal=ordinal+1;end
                end else begin active();falling();end
                waited=waited+1;
                if(waited>latency_bound+10+8*M) $fatal(1,"no result");
            end
            if(!cancelled) begin
                if(m_valid || !c_ready) $fatal(1,"final retirement ownership");
                $write("RESULT %0d",case_id);
                if(expected_error==0 && capture_count!=0) for(i=0;i<capture_count;i=i+1) $write(" %0d",flow_result[i]);
                $display("");
                $display("LATENCY %0d %0d",case_id,first_cycle-tail_cycle);
                completed=completed+1;case_id=case_id+1;
                if(next_valid) begin
                    if(!c_valid) $fatal(1,"lost queued command");
                    active();falling();c_valid=0;command_preaccepted=1;queued=queued+1;
                end else c_valid=0;
            end
        end
    endtask
    task automatic cancel_owner;
        integer waited;
        begin
            cancelled=0;armed=1;prior_retired=0;
            offer_command();
            if(!cancelled) send_rows();
            if(!cancelled) pending_command();
            waited=0;m_ready=0;
            while(!cancelled) begin
                // Only target49 retires earlier records; all others are held.
                if(target==49 && m_valid && !m_last) m_ready=1;else m_ready=0;
                active();falling();waited=waited+1;
                if(waited>1000000) $fatal(1,"unreachable reset target %0d",target);
            end
            c_valid=0;s_valid=0;m_ready=0;active();
            if(m_valid || s_ready || c_ready) $fatal(1,"reset quiescence");
            falling();rst=0;active();
            if(!c_ready || m_valid) $fatal(1,"reset recovery");
            cancelled=0;armed=0;reset_count=reset_count+1;
            command_preaccepted=0;
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path)) $fatal(1,"missing input");
        fd=$fopen(input_path,"r");if(!fd) $fatal(1,"input open");
        rc=$fscanf(fd,"%d %d\n",mode,units);if(rc!=2) $fatal(1,"mode");
        reset_dut();
        for(unit_i=0;unit_i<units;unit_i=unit_i+1) begin
            if(mode==1) begin
                rc=$fscanf(fd,"%d\n",target);if(rc!=1) $fatal(1,"target parse");
                read_case();cancel_owner();read_case();complete_case();
            end else begin read_case();complete_case();end
        end
        $fclose(fd);
        $display("PASS frames=%0d resets=%0d source_holds=%0d output_holds=%0d queued=%0d edge_reads=%0d node_reads=%0d path_reads=%0d products=%0d reverse_reads=%0d reverse_writes=%0d",completed,reset_count,source_holds,output_holds,queued,edge_reads,node_reads,path_reads,products,reverse_reads,reverse_writes);
        $finish;
    end
endmodule
