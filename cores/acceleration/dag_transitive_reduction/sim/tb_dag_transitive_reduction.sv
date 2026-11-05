`timescale 1ns/1ps
module tb_dag_transitive_reduction;
    parameter integer NUM_NODES=16,TAG_W=8;
    localparam integer N=NUM_NODES,IW=(N>1?$clog2(N):1),CW=$clog2(N+1),EW=$clog2(N*N+1);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_present=0,s_keep=0,s_last=0,m_ready=0;
    reg [31:0] s_from=0,s_to=0;reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_last;wire [1:0] m_errors;
    wire [TAG_W-1:0] m_tag;wire [IW-1:0] m_node;
    wire [N-1:0] m_successors;wire [CW-1:0] m_out_degree;
    wire [EW-1:0] m_edge_count,m_removed_count;
    dag_transitive_reduction #(.NUM_NODES(N),.TAG_W(TAG_W)) dut(.*);
    reg [98:0] tokens[0:32767];
    reg [N-1:0] expected_adj[0:4095],expected_reach[0:4095],expected_red[0:4095];
    integer starts[0:63],lengths[0:63],outputs[0:63],errors[0:63],edges[0:63],removed[0:63];
    reg [31:0] tags[0:63];
    integer target_state[0:31],target_backend[0:31],target_prefix[0:31],target_held[0:31],target_owner[0:31],target_fresh[0:31];
    integer frames,total_tokens,target_count,fd,scan,f,j,offset,mode,cycle_limit;
    integer cycles=0,accepted=0,retired=0,completed=0,first_checks=0,resets=0,reset_offers=0,next_offers=0;
    integer source_holds=0,output_holds=0,backend_rows=0,adj_reads=0,reach_reads=0,result_reads=0,commits=0;
    integer owner=-1,source_case=-1,out_cursor=0,owner_accepts=0,tail_cycle=0,seen_first=0;
    integer budget=9999,cancel_source=0,probe=-1,blocked_output=0;
    integer base_done,target_hit,actual_next,actual_prefix,guard;
    integer u_tmp,v_tmp,p_tmp,k_tmp,l_tmp,t_tmp,degree_tmp;
    reg [31:0] u_word,v_word,tag_word;
    reg [N-1:0] a_word,r_word,z_word,adj_model[0:N-1],next_row;
    reg [N-1:0] adj_owned=0,reach_owned=0,result_owned=0;
    reg [31:0] pending_u,pending_v;reg pending_p;
    reg adj_wr=0,reach_wr=0,result_wr=0;
    integer adj_address,reach_address,result_address;
    reg [N-1:0] adj_written,reach_written;reg [N+CW-1:0] result_written;
    reg source_blocked=0,output_blocked=0;
    wire [66+TAG_W:0] source_bundle={s_from,s_to,s_present,s_keep,s_last,s_tag};
    wire [3+TAG_W+IW+N+CW+2*EW:0] output_bundle={m_keep,m_last,m_errors,m_tag,m_node,m_successors,m_out_degree,m_edge_count,m_removed_count};
    reg [66+TAG_W:0] source_saved;
    reg [3+TAG_W+IW+N+CW+2*EW:0] output_saved;
    reg [15:0] states=0;reg [16:0] backend_states=0;
    string fixture;
    function automatic integer pop(input reg [N-1:0] word);
        integer q;begin pop=0;for(q=0;q<N;q=q+1)pop=pop+word[q];end
    endfunction
    task automatic set_token(input integer position);
        begin
            s_tag=tokens[position][98:67];s_from=tokens[position][66:35];s_to=tokens[position][34:3];
            s_present=tokens[position][2];s_keep=tokens[position][1];s_last=tokens[position][0];s_valid=1;
        end
    endtask
    task automatic send_case(input integer which);
        integer q,g;begin:send_body
            source_case=which;
            for(q=0;q<lengths[which];q=q+1)begin
                if(cancel_source)disable send_body;
                @(negedge clk);if(cancel_source)disable send_body;
                if(mode==1 && q%5==2)begin
                    s_valid=0;for(g=0;g<2;g=g+1)begin @(negedge clk);if(cancel_source)disable send_body;end
                end
                set_token(starts[which]+q);
                begin:wait_accept
                    forever begin
                        @(posedge clk);
                        if(cancel_source)disable send_body;
                        if(s_ready && !rst)disable wait_accept;
                    end
                end
            end
            @(negedge clk);if(!cancel_source)s_valid=0;
        end
    endtask
    always @(negedge clk)begin
        if(rst)m_ready=0;
        else if(mode==0)m_ready=1;
        else if(mode==1)m_ready=cycles%9>=4;
        else m_ready=out_cursor<budget && cycles%5>=2;
    end
    always @(posedge clk)begin
        cycles=cycles+1;if(cycles>cycle_limit)$fatal(1,"fixed cycle limit; never extend or split");
        if(rst)begin
            if(s_ready || m_valid)$fatal(1,"reset public gating");
            if(s_valid)reset_offers=reset_offers+1;
            owner=-1;out_cursor=0;owner_accepts=0;seen_first=0;
            source_blocked=0;output_blocked=0;blocked_output=0;
            adj_owned=0;reach_owned=0;result_owned=0;adj_wr=0;reach_wr=0;result_wr=0;
        end else begin
            states[dut.state]=1;backend_states[dut.closure_backend.state]=1;
            if(source_blocked && (!s_valid || source_bundle!==source_saved))$fatal(1,"source hold");
            if(output_blocked && (!m_valid || output_bundle!==output_saved))$fatal(1,"response hold");
            source_blocked=s_valid && !s_ready;source_saved=source_bundle;
            output_blocked=m_valid && !m_ready;output_saved=output_bundle;
            if(source_blocked)source_holds=source_holds+1;
            if(output_blocked)begin output_holds=output_holds+1;blocked_output=blocked_output+1;end
            else blocked_output=0;
            if(adj_wr && dut.adjacency[adj_address]!==adj_written)$fatal(1,"physical adjacency write");
            if(reach_wr && dut.reachability[reach_address]!==reach_written)$fatal(1,"physical reach write");
            if(result_wr && dut.reduced_rows[result_address]!==result_written)$fatal(1,"physical result write");
            adj_wr=0;reach_wr=0;result_wr=0;
            if(dut.state==0)begin
                adj_model[dut.init_row]=0;adj_owned[dut.init_row]=1;
                adj_address=dut.init_row;adj_written=0;adj_wr=1;
            end
            if(s_valid && s_ready)begin
                if(owner<0)begin
                    owner=source_case;out_cursor=0;owner_accepts=0;seen_first=0;
                    reach_owned=0;result_owned=0;
                    if(s_tag!==tags[owner][TAG_W-1:0])$fatal(1,"first tag owner");
                    if(adj_owned!=={N{1'b1}})$fatal(1,"capture before complete initialization");
                end
                owner_accepts=owner_accepts+1;accepted=accepted+1;
                if(s_keep && s_from<N && s_to<N)begin pending_u=s_from;pending_v=s_to;pending_p=s_present;end
                if(s_last)begin
                    if(owner_accepts!=lengths[owner])$fatal(1,"input frame length");tail_cycle=cycles;
                end
            end
            if(dut.state==2)begin
                if(dut.pending_from!==pending_u || dut.pending_to!==pending_v || dut.pending_present!==pending_p)$fatal(1,"full32 validated pending owner");
                if(!adj_owned[dut.pending_from])$fatal(1,"unowned adjacency read");adj_reads=adj_reads+1;
            end
            if(dut.state==3)begin
                if(dut.adjacency_q!==adj_model[dut.pending_from])$fatal(1,"sync adjacency read result");
                next_row=adj_model[dut.pending_from];next_row[dut.pending_to]=dut.pending_present;
                if(dut.update_row!==next_row)$fatal(1,"last assignment RMW");
                adj_model[dut.pending_from]=next_row;adj_address=dut.pending_from;adj_written=next_row;adj_wr=1;
            end
            if(dut.backend_valid && dut.state==4)begin
                if(owner<0 || owner_accepts!=lengths[owner])$fatal(1,"backend owner/tail");
                if(dut.backend_error !== (errors[owner]==1))$fatal(1,"backend invalid classification");
                if(dut.backend_keep)begin
                    if(dut.backend_reachable!==expected_reach[owner*N+dut.backend_node])$fatal(1,"independent BFS closure reused backend");
                    if(dut.backend_acyclic !== (errors[owner]==0))$fatal(1,"independent Kahn DAG");
                    reach_owned[dut.backend_node]=1;backend_rows=backend_rows+1;
                    reach_address=dut.backend_node;reach_written=expected_reach[owner*N+dut.backend_node];reach_wr=1;
                end
            end
            if(dut.state==5)begin
                if(reach_owned!=={N{1'b1}} || errors[owner])$fatal(1,"compute before complete valid closure");
                if(adj_model[dut.compute_row]!==expected_adj[owner*N+dut.compute_row])$fatal(1,"final edge assignments");
                adj_reads=adj_reads+1;
            end
            if(dut.state==6 && dut.adjacency_q!==expected_adj[owner*N+dut.compute_row])$fatal(1,"sync direct row");
            if(dut.state==8)begin if(!reach_owned[dut.successor])$fatal(1,"unowned closure read");reach_reads=reach_reads+1;end
            if(dut.state==9 && dut.reach_q!==expected_reach[owner*N+dut.successor])$fatal(1,"sync successor closure");
            if(dut.state==12)begin
                degree_tmp=pop(expected_red[owner*N+dut.compute_row]);
                if(dut.reduced_mask!==expected_red[owner*N+dut.compute_row] || dut.degree!==degree_tmp)$fatal(1,"edge deletion/minimality certificate");
                result_owned[dut.compute_row]=1;commits=commits+1;
                result_address=dut.compute_row;result_written={degree_tmp[CW-1:0],expected_red[owner*N+dut.compute_row]};result_wr=1;
            end
            if(dut.state==13)begin
                if(result_owned!=={N{1'b1}})$fatal(1,"replay before complete result bank");result_reads=result_reads+1;
            end
            if(dut.state==14 && !dut.frame_error)begin
                degree_tmp=pop(expected_red[owner*N+dut.output_node]);
                if(dut.reduced_q!=={degree_tmp[CW-1:0],expected_red[owner*N+dut.output_node]})$fatal(1,"sync result row");
            end
            if(m_valid)begin
                if(owner<0)$fatal(1,"stale output after reset/retirement");
                if(!seen_first)begin
                    if(cycles-tail_cycle>7*N*N+12*N+8 || owner_accepts!=lengths[owner])$fatal(1,"first-valid bound");
                    seen_first=1;first_checks=first_checks+1;
                end
                if(m_tag!==tags[owner][TAG_W-1:0] || m_errors!==errors[owner])$fatal(1,"held metadata");
                if(errors[owner])begin
                    if(m_keep || !m_last || m_node || m_successors || m_out_degree || m_edge_count || m_removed_count)$fatal(1,"atomic error row");
                end else begin
                    if(!m_keep || m_node!==out_cursor || m_last!==(out_cursor==N-1) ||
                       m_successors!==expected_red[owner*N+out_cursor] || m_out_degree!==pop(expected_red[owner*N+out_cursor]) ||
                       m_edge_count!==edges[owner] || m_removed_count!==removed[owner])$fatal(1,"complete reduced row/summary");
                end
                if(m_ready)begin
                    retired=retired+1;out_cursor=out_cursor+1;
                    if(m_last)begin
                        if(out_cursor!=outputs[owner])$fatal(1,"output count");completed=completed+1;owner=-1;
                    end
                end
            end
        end
    end
    function automatic integer predicate(input integer q);
        begin
            predicate=dut.state==target_state[q] && owner_accepts>0 && out_cursor==target_prefix[q];
            if(target_backend[q]>=0)predicate=predicate && dut.closure_backend.state==target_backend[q];
            if(target_state[q]==11)predicate=predicate && dut.count_bit==N/2;
            if(target_state[q]==12)predicate=predicate && dut.compute_row==N/2;
            if(target_held[q])predicate=predicate && blocked_output>=target_held[q] && s_valid && !s_last;
        end
    endfunction
    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture) || !$value$plusargs("MODE=%d",mode) || !$value$plusargs("LIMIT=%d",cycle_limit))$fatal(1,"arguments");
        fd=$fopen(fixture,"r");if(!fd)$fatal(1,"fixture open");
        scan=$fscanf(fd,"%d %d %d",frames,total_tokens,target_count);if(scan!=3 || frames>=64 || total_tokens>=32768 || target_count>32)$fatal(1,"header");
        offset=0;
        for(f=0;f<frames;f=f+1)begin
            scan=$fscanf(fd,"%d %d %d %h %d %d",u_tmp,v_tmp,p_tmp,tag_word,k_tmp,l_tmp);if(scan!=6)$fatal(1,"frame header");
            lengths[f]=u_tmp;outputs[f]=v_tmp;errors[f]=p_tmp;tags[f]=tag_word;edges[f]=k_tmp;removed[f]=l_tmp;starts[f]=offset;
            for(j=0;j<N;j=j+1)begin
                scan=$fscanf(fd,"%h %h %h",a_word,r_word,z_word);if(scan!=3)$fatal(1,"row cert");
                expected_adj[f*N+j]=a_word;expected_reach[f*N+j]=r_word;expected_red[f*N+j]=z_word;
            end
            for(j=0;j<lengths[f];j=j+1)begin
                scan=$fscanf(fd,"%h %h %d %d %d %h",u_word,v_word,p_tmp,k_tmp,l_tmp,tag_word);if(scan!=6)$fatal(1,"token");
                tokens[offset]={tag_word,u_word,v_word,p_tmp[0],k_tmp[0],l_tmp[0]};offset=offset+1;
            end
        end
        if(offset!=total_tokens)$fatal(1,"total tokens");
        for(j=0;j<target_count;j=j+1)begin
            scan=$fscanf(fd,"%d %d %d %d %d %d",u_tmp,v_tmp,p_tmp,k_tmp,l_tmp,t_tmp);if(scan!=6)$fatal(1,"reset predicate");
            target_state[j]=u_tmp;target_backend[j]=v_tmp;target_prefix[j]=p_tmp;target_held[j]=k_tmp;target_owner[j]=l_tmp;target_fresh[j]=t_tmp;
        end
        // Consume ASCII whitespace, then require physical EOF; no fscanf EOF-code assumption.
        scan=$fgetc(fd);while(scan==9 || scan==10 || scan==13 || scan==32)scan=$fgetc(fd);
        if(scan!=-1)$fatal(1,"fixture trailing bytes");$fclose(fd);
        repeat(3)@(posedge clk);@(negedge clk);rst=0;
        if(mode<2)begin
            for(f=0;f<frames;f=f+1)send_case(f);
            while(completed<frames)@(negedge clk);
            if(completed!=frames || accepted!=total_tokens || !first_checks || !source_holds)$fatal(1,"main totals");
        end else begin
            for(probe=0;probe<target_count;probe=probe+1)begin
                budget=target_prefix[probe];cancel_source=0;base_done=completed;
                fork
                    begin
                        send_case(target_owner[probe]);
                        if(target_held[probe] && !cancel_source)begin
                            @(negedge clk);if(!cancel_source)begin source_case=target_fresh[probe];set_token(starts[source_case]);end
                            while(!cancel_source)@(posedge clk);
                        end
                    end
                    begin
                        target_hit=0;
                        while(!target_hit)begin @(negedge clk);if(predicate(probe))target_hit=1;end
                        actual_next=target_held[probe]!=0;actual_prefix=out_cursor;
                        if(actual_next)next_offers=next_offers+1;
                        $display("OBS probe=%0d state=%0d backend=%0d row=%0d successor=%0d bit=%0d prefix=%0d next=%0d accepted=%0d",probe,dut.state,dut.closure_backend.state,(dut.state>=5 && dut.state<=12)?dut.compute_row:0,(dut.state>=7 && dut.state<=9)?dut.successor:0,(dut.state==11)?dut.count_bit:0,actual_prefix,actual_next,owner_accepts);
                        cancel_source=1;rst=1;source_case=target_fresh[probe];set_token(starts[source_case]);
                        repeat(3)@(posedge clk);@(negedge clk);s_valid=0;
                    end
                join
                if(completed!=base_done)$fatal(1,"canceled owner completed");
                resets=resets+1;budget=N+1;cancel_source=0;rst=0;
                send_case(target_fresh[probe]);while(completed<base_done+1)@(negedge clk);
                while(!s_ready)@(negedge clk);
            end
            if(resets!=target_count || completed!=target_count || reset_offers!=3*target_count)$fatal(1,"reset/fresh totals");
        end
        if(mode==1 && !output_holds)$fatal(1,"stalled sink not exercised");
        $display("PASS mode=%0d N=%0d T=%0d frames=%0d accepted=%0d retired=%0d first=%0d resets=%0d reset_offers=%0d next=%0d backend_rows=%0d adj_reads=%0d reach_reads=%0d commits=%0d result_reads=%0d source_holds=%0d output_holds=%0d states=%h backend_states=%h cycles=%0d",mode,N,TAG_W,completed,accepted,retired,first_checks,resets,reset_offers,next_offers,backend_rows,adj_reads,reach_reads,commits,result_reads,source_holds,output_holds,states,backend_states,cycles);
        $finish;
    end
endmodule
