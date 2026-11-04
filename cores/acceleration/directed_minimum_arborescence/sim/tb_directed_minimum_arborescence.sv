`timescale 1ns/1ps
module tb_directed_minimum_arborescence;
    parameter integer N=8,M=16,C=8,T=8;
    localparam integer TW=C+((N<=2)?0:$clog2(N-1));
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,s_error=0,m_ready=0;
    reg [31:0] s_from=0,s_to=0,s_root=0;
    reg [C-1:0] s_cost=0;reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_summary,m_last,m_feasible;
    wire [31:0] m_vertex,m_parent,m_edge_index;
    wire [C-1:0] m_cost;wire [TW-1:0] m_total_cost;
    wire [3:0] m_errors;wire [T-1:0] m_tag;
    directed_minimum_arborescence #(.NUM_NODES(N),.MAX_EDGES(M),.COST_W(C),.TAG_W(T)) dut(.*);
    integer fd,rc,mode,units,unit_i,target=-1,prefix_limit=0,armed=0,cancelled=0;
    integer row_count,expected_errors,expected_feasible,expected_total,expected_outputs,latency_bound;
    reg [31:0] expected_tag,expected_root;
    integer rk[0:127],rl[0:127],re[0:127],cost[0:127];
    reg [31:0] ru[0:127],rv[0:127],rr[0:127],rt[0:127];
    integer ku[0:127],kv[0:127],kc[0:127],kept;
    integer next_valid,next_keep,next_last,next_error;
    reg [31:0] next_from,next_to,next_cost,next_root,next_tag;
    integer next_is_offered=0,preaccepted=0,pre_cycle=0,pre_keep,pre_last,pre_error;
    reg [31:0] pre_from,pre_to,pre_cost,pre_root,pre_tag;
    integer chosen[0:N-1],parent[0:N-1];
    integer edge_owned[0:N*M-1],node_owned[0:N*N-1];
    integer i,j,q,accepted,cycle=0,tail_cycle,first_cycle,prior_retired=0,case_id=0;
    integer completed=0,resets=0,source_holds=0,output_holds=0,queued=0;
    integer edge_reads=0,node_reads=0,edge_writes=0,node_writes=0,contractions=0,overrides=0,max_layer=0;
    integer witness_sum=0;
    reg [255:0] held;
    reg [255:0] held_source;
    integer source_held=0;
    string input_path;
    function automatic [255:0] output_word;
        output_word={m_valid,m_summary,m_last,m_feasible,m_vertex,m_parent,m_edge_index,m_cost,m_total_cost,m_errors,m_tag};
    endfunction
    function automatic [255:0] source_word;
        source_word={s_valid,s_keep,s_last,s_error,s_from,s_to,s_root,s_cost,s_tag};
    endfunction
    function automatic integer hit_target;
        begin
            hit_target=0;
            if(target>=0 && target<=46) hit_target=(dut.state==target);
            case(target)
            47:hit_target=dut.state==0 && dut.capture_active && !s_last;
            48:hit_target=dut.state==5 && dut.eq_cost==0 && (!dut.nq_min_valid || dut.nq_cost>0);
            49:hit_target=dut.state==12 && dut.cursor==dut.cycle_anchor;
            50:hit_target=dut.state==12 && dut.nq_parent==dut.cycle_anchor && dut.cursor!=dut.cycle_anchor;
            51:hit_target=dut.state==1 && dut.layer==2;
            52:hit_target=dut.state==23 && dut.nq_cost>0 && dut.from_component!=dut.nq_component;
            53:hit_target=dut.state==23 && dut.from_component==dut.nq_component;
            54:hit_target=dut.state==35;
            55:hit_target=dut.state==40 && dut.total>0;
            56:hit_target=dut.state==45 && prior_retired==0 && !m_ready;
            57:hit_target=dut.state==45 && prior_retired==1 && prior_retired<N-2 && !m_ready;
            58:hit_target=dut.state==45 && prior_retired==N-2 && !m_ready;
            59:hit_target=dut.state==46 && dut.feasible && dut.errors==0 && !m_ready;
            60:hit_target=dut.state==46 && !dut.feasible && dut.errors==0 && !m_ready;
            61:hit_target=dut.state==46 && dut.errors!=0 && !m_ready;
            62:hit_target=next_is_offered && s_valid && !s_ready && dut.state!=0 &&
                s_keep==next_keep && s_last==next_last && s_error==next_error &&
                s_from==next_from && s_to==next_to && s_root==next_root &&
                s_cost==next_cost[C-1:0] && s_tag==next_tag[T-1:0];
            63:hit_target=dut.state==0 && dut.errors[2] && dut.capture_active;
            64:hit_target=dut.state==1 && dut.layer==1 && dut.root!=0;
            endcase
        end
    endfunction
    always @(negedge clk) begin
        #1;
        if(armed && !cancelled && hit_target()) begin
            if(m_valid) check_record(prior_retired);
            rst=1;cancelled=1;armed=0;
            if(prior_retired!=prefix_limit) $fatal(1,"unexpected owner prefix");
            $display("CANCEL %0d %0d %0d",target,dut.state,prior_retired);
        end
    end
    // Independently track transaction ownership of every actual RAM address.
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst || (s_valid && s_ready && !dut.capture_active)) begin
            for(j=0;j<N*M;j=j+1) edge_owned[j]=0;
            for(j=0;j<N*N;j=j+1) node_owned[j]=0;
            prior_retired=0;
        end
        if(rst) source_held=0;
        if(!rst) begin
            if(source_held && source_word()!==held_source) $fatal(1,"unstable blocked source");
            source_held=s_valid && !s_ready;held_source=source_word();
            if(dut.e_re && dut.e_we) $fatal(1,"edge port collision");
            if(dut.n_re && dut.n_we) $fatal(1,"node port collision");
            if(dut.e_re || dut.e_we) if(dut.e_addr>=N*M) $fatal(1,"edge address");
            if(dut.n_re || dut.n_we) if(dut.n_addr>=N*N) $fatal(1,"node address");
            if(dut.e_re) begin
                if(!edge_owned[dut.e_addr]) $fatal(1,"unowned edge read");edge_reads=edge_reads+1;
            end
            if(dut.n_re) begin
                if(!node_owned[dut.n_addr]) $fatal(1,"unowned node read");node_reads=node_reads+1;
            end
            if(dut.e_we) begin edge_owned[dut.e_addr]=1;edge_writes=edge_writes+1;end
            if(dut.n_we) begin node_owned[dut.n_addr]=1;node_writes=node_writes+1;end
            if(dut.state==23 && dut.from_component!=dut.nq_component && dut.eq_cost<dut.nq_cost)
                $fatal(1,"negative adjusted cost");
            if(dut.state==25) begin
                if(dut.component_count>=dut.node_count || dut.layer>=N-1) $fatal(1,"no contraction progress");
                contractions=contractions+1;
            end
            if(dut.state==35) begin
                if(!dut.nq_active || dut.nq_root) $fatal(1,"invalid expansion destination");
                overrides=overrides+1;
            end
            if(dut.layer>max_layer) max_layer=dut.layer;
            if(s_valid && !s_ready) source_holds=source_holds+1;
            if(m_valid && !m_ready) output_holds=output_holds+1;
            if(m_valid && m_ready) prior_retired=prior_retired+1;
        end
    end
    task automatic falling;begin @(negedge clk);#2;end endtask
    task automatic active;begin @(posedge clk);#2;end endtask
    task automatic reset_dut;
        begin
            falling();rst=1;s_valid=0;m_ready=0;active();
            if(s_ready || m_valid || m_last) $fatal(1,"reset level gating");
            active();falling();rst=0;active();
            if(!s_ready || m_valid) $fatal(1,"reset recovery");
        end
    endtask
    task automatic read_case;
        begin
            rc=$fscanf(fd,"%d %d %d %d %h %h %d %d\n",row_count,expected_errors,expected_feasible,expected_total,expected_tag,expected_root,expected_outputs,latency_bound);
            if(rc!=8 || row_count<1 || row_count>128) $fatal(1,"case header");
            rc=$fscanf(fd,"%d %d %h %h %h %d %h %h %d\n",next_valid,next_keep,next_from,next_to,next_cost,next_last,next_root,next_tag,next_error);
            if(rc!=9) $fatal(1,"queued header");
            kept=0;
            for(q=0;q<row_count;q=q+1) begin
                rc=$fscanf(fd,"%d %h %h %h %d %h %h %d\n",rk[q],ru[q],rv[q],cost[q],rl[q],rr[q],rt[q],re[q]);
                if(rc!=8) $fatal(1,"input record");
                if(rk[q]) begin ku[kept]=ru[q];kv[kept]=rv[q];kc[kept]=cost[q];kept=kept+1;end
            end
            for(q=0;q<N;q=q+1) begin parent[q]=-1;chosen[q]=-1;end
            witness_sum=0;
            if(preaccepted && (pre_keep!=rk[0] || pre_from!=ru[0] || pre_to!=rv[0] ||
               pre_cost!=cost[0] || pre_last!=rl[0] || pre_root!=rr[0] ||
               pre_tag!=rt[0] || pre_error!=re[0])) $fatal(1,"preaccepted actual-next record mismatch");
        end
    endtask
    task automatic send_rows;
        integer r,start_row;
        begin
            start_row=0;next_is_offered=0;
            if(preaccepted) begin
                start_row=1;preaccepted=0;if(rl[0]) tail_cycle=pre_cycle;
            end
            falling();
            for(r=start_row;r<row_count && !cancelled;r=r+1) begin
                if(r%5==2) begin s_valid=0;active();falling();end
                if(!cancelled) begin
                    s_valid=1;s_keep=rk[r];s_from=ru[r];s_to=rv[r];s_cost=cost[r];
                    s_last=rl[r];s_root=rr[r];s_tag=rt[r];s_error=re[r];accepted=s_ready;
                    active();
                    while(!accepted && !cancelled) begin falling();accepted=s_ready;active();end
                    if(rl[r]) tail_cycle=cycle;
                    falling();
                end
            end
            s_valid=0;
        end
    endtask
    task automatic pending_record;
        begin
            s_valid=next_valid;s_keep=next_keep;s_from=next_from;s_to=next_to;s_cost=next_cost;
            s_last=next_last;s_root=next_root;s_tag=next_tag;s_error=next_error;
            next_is_offered=next_valid;
        end
    endtask
    task automatic check_record(input integer ordinal);
        integer child;
        begin
            if(m_errors!==expected_errors || m_feasible!==expected_feasible || m_total_cost!==expected_total || m_tag!==expected_tag[T-1:0])
                $fatal(1,"metadata case%0d ordinal%0d err%0d/%0d feasible%0d/%0d total%0d/%0d",case_id,ordinal,m_errors,expected_errors,m_feasible,expected_feasible,m_total_cost,expected_total);
            if(m_last!==(ordinal==expected_outputs-1) || m_summary!==m_last) $fatal(1,"summary/LAST");
            if(m_summary) begin
                if(m_vertex!==0 || m_parent!==0 || m_edge_index!==0 || m_cost!==0) $fatal(1,"summary geometry");
            end else begin
                child=(ordinal>=expected_root)?ordinal+1:ordinal;
                if(m_vertex!==child || m_edge_index>=kept || m_parent>=N) $fatal(1,"ordered witness");
                if(ku[m_edge_index]!==m_parent || kv[m_edge_index]!==m_vertex || kc[m_edge_index]!==m_cost) $fatal(1,"original edge witness");
                parent[child]=m_parent;chosen[child]=m_edge_index;
            end
        end
    endtask
    task automatic certificate;
        integer v,u,steps,sum;
        begin
            if(expected_feasible) begin
                sum=0;
                for(v=0;v<N;v=v+1) if(v!=expected_root) begin
                    if(chosen[v]<0) $fatal(1,"missing parent");sum=sum+kc[chosen[v]];
                    u=v;steps=0;
                    while(u!=expected_root && steps<N) begin
                        if(u<0 || u>=N || parent[u]<0) $fatal(1,"parent domain");
                        u=parent[u];steps=steps+1;
                    end
                    if(u!=expected_root) $fatal(1,"nonrooted parent cycle");
                end
                if(sum!=expected_total) $fatal(1,"optimal cost certificate");
            end
        end
    endtask
    task automatic complete_case;
        integer ordinal,waited,stall;
        begin
            send_rows();if(!cancelled) pending_record();
            ordinal=0;waited=0;first_cycle=-1;m_ready=0;
            while(ordinal<expected_outputs && !cancelled) begin
                if(m_valid) begin
                    if(first_cycle<0) begin
                        first_cycle=cycle;
                        if(first_cycle-tail_cycle>latency_bound) $fatal(1,"first-valid bound");
                    end
                    check_record(ordinal);held=output_word();
                    for(stall=0;stall<2 && !cancelled;stall=stall+1) begin
                        active();falling();
                        if(!cancelled && output_word()!==held) $fatal(1,"unstable output hold");
                    end
                    if(!cancelled) begin m_ready=1;active();falling();m_ready=0;ordinal=ordinal+1;end
                end else begin active();falling();end
                waited=waited+1;
                if(waited>latency_bound+16*N) $fatal(1,"result watchdog");
            end
            if(!cancelled) begin
                certificate();
                if(m_valid || !s_ready) $fatal(1,"summary retirement ownership");
                $write("RESULT %0d %0d %0d",case_id,expected_feasible,expected_total);
                if(expected_feasible) for(i=0;i<N;i=i+1) if(i!=expected_root) $write(" %0d",chosen[i]);
                $display("");$display("LATENCY %0d %0d",case_id,first_cycle-tail_cycle);
                completed=completed+1;case_id=case_id+1;
                if(next_valid) begin
                    if(!s_valid || !s_ready || !next_is_offered) $fatal(1,"lost actual next offer");
                    pre_keep=next_keep;pre_from=next_from;pre_to=next_to;pre_cost=next_cost;
                    pre_last=next_last;pre_root=next_root;pre_tag=next_tag;pre_error=next_error;
                    active();pre_cycle=cycle;falling();s_valid=0;preaccepted=1;queued=queued+1;
                end else s_valid=0;
                next_is_offered=0;
            end
        end
    endtask
    task automatic cancel_owner;
        integer waited;
        begin
            cancelled=0;armed=1;prior_retired=0;m_ready=0;
            send_rows();if(!cancelled) pending_record();waited=0;
            while(!cancelled) begin
                m_ready=(prior_retired<prefix_limit);
                if(m_valid && m_ready) check_record(prior_retired);
                active();falling();waited=waited+1;
                if(waited>latency_bound+16*N) $fatal(1,"unreachable reset target %0d",target);
            end
            s_valid=0;m_ready=0;next_is_offered=0;active();
            if(s_ready || m_valid || m_last) $fatal(1,"reset cancellation");
            active();falling();rst=0;active();
            if(!s_ready || m_valid) $fatal(1,"fresh ownership");
            cancelled=0;armed=0;preaccepted=0;resets=resets+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path)) $fatal(1,"missing input");
        fd=$fopen(input_path,"r");if(!fd) $fatal(1,"input open");
        rc=$fscanf(fd,"%d %d\n",mode,units);if(rc!=2) $fatal(1,"mode");
        reset_dut();
        for(unit_i=0;unit_i<units;unit_i=unit_i+1) begin
            if(mode==1) begin
                rc=$fscanf(fd,"%d %d\n",target,prefix_limit);if(rc!=2) $fatal(1,"target");
                read_case();cancel_owner();read_case();complete_case();
            end else begin read_case();complete_case();end
        end
        $fclose(fd);
        $display("PASS frames=%0d resets=%0d source_holds=%0d output_holds=%0d queued=%0d edge_reads=%0d node_reads=%0d edge_writes=%0d node_writes=%0d contractions=%0d overrides=%0d max_layer=%0d",completed,resets,source_holds,output_holds,queued,edge_reads,node_reads,edge_writes,node_writes,contractions,overrides,max_layer);
        $finish;
    end
endmodule
