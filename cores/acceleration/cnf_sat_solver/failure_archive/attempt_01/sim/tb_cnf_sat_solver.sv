// SPDX-License-Identifier: Apache-2.0
module tb_cnf_sat_solver;
    parameter integer V=8, C=16, T=8;
    localparam integer MAX_CASES=256;
    localparam longint TAIL_BOUND=((64'd1 << (V+1))-1)*((V+1)*(2*C+3)+6)+8;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, c_valid=0, c_error=0, s_valid=0, s_last=0, s_error=0, m_ready=0;
    reg [31:0] c_num_vars=0, c_num_clauses=0;
    reg [T-1:0] c_tag=0;
    reg [V-1:0] s_positive=0, s_negative=0;
    wire c_ready,s_ready,m_valid,m_sat;
    wire [V-1:0] m_assignment;
    wire [5:0] m_error;
    wire [T-1:0] m_tag;
    cnf_sat_solver #(.MAX_VARS(V),.MAX_CLAUSES(C),.TAG_W(T)) dut(.*);

    integer num_cases, nr[0:MAX_CASES-1], upstream[0:MAX_CASES-1];
    reg [31:0] nv[0:MAX_CASES-1], nc[0:MAX_CASES-1];
    reg [T-1:0] tags[0:MAX_CASES-1];
    integer expected_sat[0:MAX_CASES-1];
    reg [5:0] expected_error[0:MAX_CASES-1];
    reg [V-1:0] pos[0:MAX_CASES-1][0:C-1], neg[0:MAX_CASES-1][0:C-1];
    integer lasts[0:MAX_CASES-1][0:C-1], errors[0:MAX_CASES-1][0:C-1];
    integer reset_count, fresh_case;
    integer reset_state[0:31], reset_owner[0:31], reset_condition[0:31];
    reg [2047:0] fixture_path, reset_path;
    integer mode, fd, scan, i,j,k,tmp_id,tmp_up,tmp_sat,tmp_nr,tmp_last,tmp_error;
    reg [31:0] tmp_nv,tmp_nc;
    reg [T-1:0] tmp_tag;
    reg [5:0] tmp_expected_error;
    reg [V-1:0] tmp_pos,tmp_neg;
    reg [7:0] tail_char;
    longint cycles=0, writes=0, reads=0, pushes=0, pops=0;
    longint c_transfers=0, s_transfers=0, m_transfers=0;
    longint c_hold_cycles=0, s_hold_cycles=0, m_hold_cycles=0, literal_checks=0;
    longint max_latency=0;
    integer max_depth=0,owner_writes=0;
    reg [9:0] states_seen=0;
    reg previous_c_blocked=0, previous_s_blocked=0, previous_m_blocked=0;
    reg [64+T:0] previous_c;
    reg [2*V+1:0] previous_s;
    reg [V+T+6:0] previous_m;
    reg [V-1:0] pending_written=0;

    always @(posedge clk) begin
        cycles=cycles+1;
        if (rst) begin
            previous_c_blocked=0;
            previous_s_blocked=0;
            previous_m_blocked=0;
            pending_written=0;
            owner_writes=0;
        end else begin
            if (previous_c_blocked && (!c_valid ||
                {c_num_vars,c_num_clauses,c_error,c_tag} !== previous_c))
                $fatal(1,"command hold violation");
            if (previous_s_blocked && (!s_valid ||
                {s_positive,s_negative,s_last,s_error} !== previous_s))
                $fatal(1,"row hold violation");
            if (previous_m_blocked && (!m_valid ||
                {m_sat,m_assignment,m_error,m_tag} !== previous_m))
                $fatal(1,"result hold violation");
            previous_c_blocked=c_valid&&!c_ready;
            previous_s_blocked=s_valid&&!s_ready;
            previous_m_blocked=m_valid&&!m_ready;
            previous_c={c_num_vars,c_num_clauses,c_error,c_tag};
            previous_s={s_positive,s_negative,s_last,s_error};
            previous_m={m_sat,m_assignment,m_error,m_tag};
            if (previous_c_blocked) c_hold_cycles=c_hold_cycles+1;
            if (previous_s_blocked) s_hold_cycles=s_hold_cycles+1;
            if (previous_m_blocked) m_hold_cycles=m_hold_cycles+1;
            if (c_valid&&c_ready) begin
                c_transfers=c_transfers+1;
                pending_written=0;
                owner_writes=0;
            end
            if (s_valid&&s_ready) s_transfers=s_transfers+1;
            if (m_valid&&m_ready) m_transfers=m_transfers+1;
            states_seen[dut.state]=1;
            if (dut.clause_we && dut.clause_re) $fatal(1,"clause port collision");
            if (dut.pending_we && dut.pending_re) $fatal(1,"pending port collision");
            if (dut.clause_we) begin
                if (dut.load_count >= C || dut.load_count >= dut.clause_count)
                    $fatal(1,"clause write ownership");
                writes=writes+1;
                owner_writes=owner_writes+1;
            end
            if (dut.clause_re) begin
                if (dut.clause_index >= dut.clause_count || dut.clause_count > C ||
                    owner_writes != dut.clause_count || dut.input_errors != 0)
                    $fatal(1,"clause read ownership");
                reads=reads+1;
            end
            if (dut.state>=2 && dut.state<=8) begin
                if ((dut.assigned_mask & ~dut.variable_mask) != 0 ||
                    (dut.value_mask & ~dut.assigned_mask) != 0)
                    $fatal(1,"assignment domain invariant");
            end
            if (dut.pending_depth > max_depth) max_depth=dut.pending_depth;
            if (dut.pending_depth > V) $fatal(1,"pending depth exceeds variables");
            if (dut.pending_we) begin
                if (dut.pending_depth >= V || dut.branch_bit == 0 ||
                    (dut.branch_bit & (dut.branch_bit-1'b1)) != 0 ||
                    (dut.branch_bit & dut.assigned_mask) != 0 ||
                    (dut.branch_bit & ~dut.unresolved_mask) != 0)
                    $fatal(1,"decision invariant");
                pending_written[dut.pending_depth]=1;
                pushes=pushes+1;
            end
            if (dut.pending_re) begin
                if (dut.pending_depth == 0 ||
                    !pending_written[dut.pending_depth-1])
                    $fatal(1,"pending read before current owner write");
                pending_written[dut.pending_depth-1]=0;
                pops=pops+1;
            end
        end
    end

    task automatic whitespace_eof(input integer handle);
        integer r;
        reg [7:0] ch;
        begin
            while (!$feof(handle)) begin
                r=$fscanf(handle,"%c",ch);
                if (r==1 && ch!=9 && ch!=10 && ch!=11 && ch!=12 && ch!=13 && ch!=32)
                    $fatal(1,"unexpected fixture trailer");
                if (r!=1 && !$feof(handle)) $fatal(1,"fixture tail read error");
            end
        end
    endtask

    task automatic drive_command(input integer cid);
        begin
            c_valid=1;
            c_num_vars=nv[cid]; c_num_clauses=nc[cid];
            c_error=upstream[cid]; c_tag=tags[cid];
        end
    endtask
    task automatic drive_row(input integer cid,input integer rid);
        begin
            s_valid=1; s_positive=pos[cid][rid]; s_negative=neg[cid][rid];
            s_last=lasts[cid][rid]; s_error=errors[cid][rid];
        end
    endtask
    task automatic check_rows(input integer cid);
        integer r;
        begin
            for (r=0;r<nr[cid];r=r+1)
                if (dut.clause_mem[r] !== {pos[cid][r],neg[cid][r]})
                    $fatal(1,"row image mismatch case%0d row%0d",cid,r);
        end
    endtask
    task automatic check_result(input integer cid);
        integer r;
        reg [V-1:0] legal_mask;
        begin
            if ((^{m_sat,m_assignment,m_error,m_tag}) === 1'bx)
                $fatal(1,"unknown result field");
            if (!m_valid || m_tag !== tags[cid] ||
                m_error !== expected_error[cid] || m_sat !== expected_sat[cid][0])
                $fatal(1,"result metadata case%0d got sat%0d err%0h tag%0h expected %0d/%0h/%0h",
                    cid,m_sat,m_error,m_tag,expected_sat[cid],expected_error[cid],tags[cid]);
            if (!m_sat && m_assignment !== 0) $fatal(1,"non-SAT assignment not zero");
            if (m_sat) begin
                legal_mask={V{1'b1}} >> (V-nv[cid]);
                if ((m_assignment & ~legal_mask) != 0) $fatal(1,"unused assignment bits");
                for (r=0;r<nr[cid];r=r+1) begin
                    if (((pos[cid][r]&m_assignment)|(neg[cid][r]&~m_assignment)) == 0)
                        $fatal(1,"returned assignment falsifies case%0d clause%0d",cid,r);
                    literal_checks=literal_checks+1;
                end
            end
            check_rows(cid);
        end
    endtask

    function automatic integer predicate(input integer condition);
        begin
            case(condition)
                0: predicate=1;
                1: predicate=dut.pending_depth==0;
                2: predicate=!dut.clause_satisfied && dut.clause_unit;
                3: predicate=(dut.positive&dut.negative)!=0;
                4: predicate=dut.pending_depth>0;
                5: predicate=dut.pending_depth>=2;
                default: predicate=0;
            endcase
        end
    endfunction

    task automatic cancel_now;
        begin
            // Called immediately after the target is observed, before another edge.
            rst=1;
            #1;
            if (c_ready || s_ready || m_valid) $fatal(1,"reset level gate");
            repeat(2) @(posedge clk);
            @(negedge clk);
            c_valid=0; s_valid=0; m_ready=0; rst=0;
            #1;
            if (dut.state!=0 || m_valid) $fatal(1,"reset ownership survived");
        end
    endtask

    task automatic reach_and_cancel(input integer cid,input integer target,
                                     input integer condition,input integer group);
        integer sent, row, hit;
        reg ct,st;
        longint start;
        begin
            sent=0; row=0; hit=0; start=cycles;
            while (!hit) begin
                @(negedge clk);
                if (!sent) drive_command(cid); else drive_command(fresh_case);
                if (row<nr[cid]) drive_row(cid,row); else drive_row(fresh_case,0);
                m_ready=0;
                if (target==0) begin
                    #1;
                    if (dut.state!=0) $fatal(1,"idle reset target");
                    hit=1;
                end else begin
                    @(posedge clk);
                    ct=c_valid&&c_ready; st=s_valid&&s_ready;
                    if (ct) begin
                        if (sent) $fatal(1,"next command admitted before owner retires");
                        sent=1;
                    end
                    if (st) begin
                        if (row>=nr[cid]) $fatal(1,"future row admitted before owner retires");
                        row=row+1;
                    end
                    #1;
                    if (dut.state==target && predicate(condition)) hit=1;
                    if (cycles-start>TAIL_BOUND+nr[cid]+16)
                        $fatal(1,"unreached reset predicate group%0d",group);
                end
            end
            $display("OBS group=%0d owner=%0d state=%0d condition=%0d rows=%0d pending=%0d",
                group,cid,dut.state,condition,row,dut.pending_depth);
            cancel_now();
        end
    endtask

    task automatic fresh_then_actual_next;
        integer row,h;
        reg ct,st;
        longint start;
        begin
            @(negedge clk); drive_command(fresh_case); drive_row(fresh_case,0); m_ready=0;
            @(posedge clk);
            if (!c_ready || s_ready) $fatal(1,"fresh command ownership");
            #1;
            row=0;
            while (row<nr[fresh_case]) begin
                @(negedge clk);
                c_valid=0; drive_row(fresh_case,row);
                @(posedge clk);
                st=s_valid&&s_ready;
                if (!st) $fatal(1,"fresh capture unexpected stall");
                row=row+1;
                #1;
            end
            start=cycles;
            @(negedge clk);
            s_valid=0;
            drive_command(0); // A real next empty-CNF command held to acceptance.
            while (!m_valid) begin
                @(posedge clk); #1;
                if (c_ready || s_ready) $fatal(1,"fresh solve admission");
                if (cycles-start>TAIL_BOUND) $fatal(1,"fresh first-valid bound");
            end
            check_result(fresh_case);
            for (h=0;h<5;h=h+1) begin
                @(posedge clk); #1;
                check_result(fresh_case);
                if (c_ready) $fatal(1,"fresh held next command admitted");
            end
            @(negedge clk); m_ready=1;
            @(posedge clk);
            if (!m_valid || c_ready) $fatal(1,"fresh retirement ownership");
            #1;
            @(negedge clk); m_ready=0;
            @(posedge clk);
            if (!c_ready || !c_valid) $fatal(1,"held real next command did not transfer");
            #1;
            check_result(0);
            @(negedge clk); c_valid=0;
            repeat(2) begin @(posedge clk); #1; check_result(0); end
            @(negedge clk); m_ready=1;
            @(posedge clk);
            if (!m_valid) $fatal(1,"next empty CNF did not retire");
            #1;
            @(negedge clk); m_ready=0;
        end
    endtask

    integer ci,sc,sr,oi,hold_left,result_seen,first_checks,total_rows;
    integer sat_results,error_results,unsat_results;
    reg ct,st,mt;
    longint start_cycle[0:MAX_CASES-1];
    reg start_known[0:MAX_CASES-1];
    initial begin
        if (!$value$plusargs("FIXTURE=%s",fixture_path) ||
            !$value$plusargs("MODE=%d",mode)) $fatal(1,"missing plusargs");
        fd=$fopen(fixture_path,"r");
        if (!fd || $fscanf(fd,"%d",num_cases)!=1 || num_cases<1 || num_cases>MAX_CASES)
            $fatal(1,"fixture header");
        total_rows=0;
        for(i=0;i<num_cases;i=i+1) begin
            scan=$fscanf(fd,"%d %h %h %d %h %h %d %d",tmp_id,tmp_nv,tmp_nc,
                tmp_up,tmp_tag,tmp_expected_error,tmp_sat,tmp_nr);
            if (scan!=8 || tmp_id!=i || tmp_nr<0 || tmp_nr>C) $fatal(1,"fixture case header");
            nv[i]=tmp_nv; nc[i]=tmp_nc; upstream[i]=tmp_up; tags[i]=tmp_tag;
            expected_error[i]=tmp_expected_error; expected_sat[i]=tmp_sat; nr[i]=tmp_nr;
            start_known[i]=0;
            total_rows=total_rows+tmp_nr;
            for(j=0;j<tmp_nr;j=j+1) begin
                scan=$fscanf(fd,"%h %h %d %d",tmp_pos,tmp_neg,tmp_last,tmp_error);
                if (scan!=4) $fatal(1,"fixture row");
                pos[i][j]=tmp_pos; neg[i][j]=tmp_neg;
                lasts[i][j]=tmp_last; errors[i][j]=tmp_error;
            end
        end
        whitespace_eof(fd); $fclose(fd);
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        if(mode==0) begin
            ci=0; sc=0; sr=0; oi=0; hold_left=0; result_seen=0; first_checks=0;
            sat_results=0; error_results=0; unsat_results=0;
            while(sc<num_cases && nr[sc]==0) sc=sc+1;
            while(oi<num_cases) begin
                @(negedge clk);
                if(ci<num_cases) drive_command(ci); else c_valid=0;
                if(sc<num_cases) drive_row(sc,sr); else s_valid=0;
                m_ready=result_seen && hold_left==0;
                @(posedge clk);
                ct=c_valid&&c_ready; st=s_valid&&s_ready; mt=m_valid&&m_ready;
                if(ct) begin
                    if(nr[ci]==0) begin start_cycle[ci]=cycles; start_known[ci]=1; end
                    ci=ci+1;
                end
                if(st) begin
                    if(sc>=ci) $fatal(1,"row precedes owning command");
                    sr=sr+1;
                    if(sr==nr[sc]) begin
                        start_cycle[sc]=cycles; start_known[sc]=1;
                        sc=sc+1; sr=0;
                        while(sc<num_cases && nr[sc]==0) sc=sc+1;
                    end
                end
                if(mt) begin
                    oi=oi+1; result_seen=0; hold_left=0;
                end
                #1;
                if(m_valid && !result_seen) begin
                    if(oi>=num_cases || !start_known[oi]) $fatal(1,"unowned response");
                    check_result(oi);
                    if(cycles-start_cycle[oi]>TAIL_BOUND) $fatal(1,"first valid latency bound");
                    if(cycles-start_cycle[oi]>max_latency) max_latency=cycles-start_cycle[oi];
                    first_checks=first_checks+1; result_seen=1; hold_left=5;
                    if(m_error!=0) error_results=error_results+1;
                    else if(m_sat) sat_results=sat_results+1;
                    else unsat_results=unsat_results+1;
                end else if(result_seen && hold_left>0) hold_left=hold_left-1;
                if(oi<num_cases && start_known[oi] && !result_seen &&
                    cycles-start_cycle[oi]>TAIL_BOUND) $fatal(1,"missing result latency bound");
            end
            @(negedge clk); c_valid=0; s_valid=0; m_ready=0;
            if(ci!=num_cases || sc!=num_cases || c_transfers!=num_cases ||
                s_transfers!=total_rows || m_transfers!=num_cases || first_checks!=num_cases)
                $fatal(1,"main exact transfer counts");
            $display("PASS {\"mode\":\"main\",\"cases\":%0d,\"rows\":%0d,\"sat\":%0d,\"unsat\":%0d,\"errors\":%0d,\"first_valid_checks\":%0d,\"max_latency\":%0d,\"clause_writes\":%0d,\"clause_reads\":%0d,\"pushes\":%0d,\"pops\":%0d,\"max_depth\":%0d,\"literal_checks\":%0d,\"command_hold_cycles\":%0d,\"row_hold_cycles\":%0d,\"output_hold_cycles\":%0d,\"states\":%0d}",
                num_cases,total_rows,sat_results,unsat_results,error_results,first_checks,
                max_latency,writes,reads,pushes,pops,max_depth,literal_checks,
                c_hold_cycles,s_hold_cycles,m_hold_cycles,states_seen);
        end else if(mode==1) begin
            if(!$value$plusargs("RESET=%s",reset_path)) $fatal(1,"missing reset fixture");
            fd=$fopen(reset_path,"r");
            if(!fd || $fscanf(fd,"%d %d",reset_count,fresh_case)!=2 || reset_count>32)
                $fatal(1,"reset header");
            for(i=0;i<reset_count;i=i+1) begin
                scan=$fscanf(fd,"%d %d %d",tmp_id,tmp_nr,tmp_up);
                if(scan!=3) $fatal(1,"reset entry");
                reset_state[i]=tmp_id; reset_owner[i]=tmp_nr; reset_condition[i]=tmp_up;
            end
            whitespace_eof(fd); $fclose(fd);
            if(nr[fresh_case]!=C || expected_error[fresh_case]!=0 ||
                !expected_sat[fresh_case]) $fatal(1,"fresh must overwrite full capacity");
            for(k=0;k<reset_count;k=k+1) begin
                reach_and_cancel(reset_owner[k],reset_state[k],reset_condition[k],k);
                fresh_then_actual_next();
            end
            $display("PASS {\"mode\":\"reset\",\"groups\":%0d,\"complete_fresh\":%0d,\"accepted_next\":%0d,\"clause_writes\":%0d,\"clause_reads\":%0d,\"pushes\":%0d,\"pops\":%0d,\"max_depth\":%0d,\"literal_checks\":%0d,\"states\":%0d}",
                reset_count,reset_count,reset_count,writes,reads,pushes,pops,max_depth,
                literal_checks,states_seen);
        end else $fatal(1,"unknown mode");
        $finish;
    end
endmodule
