// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_congruence_merge;
    parameter integer W=8,TAG_W=8;
    localparam integer BOUND=4*W+5+((1<<W)-1);
    reg clk=0; always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid;
    reg signed [W-1:0] s_a=0,s_b=0;
    reg [W-1:0] s_m=0,s_n=0;
    reg [TAG_W-1:0] s_tag=0;
    wire [2*W-1:0] m_solution,m_period;
    wire [2:0] m_status;
    wire [TAG_W-1:0] m_tag;
    congruence_merge #(.W(W),.TAG_W(TAG_W)) dut(.*);
    integer aa[0:4999],bb[0:4999],mm[0:4999],nn[0:4999],tt[0:4999];
    integer xx[0:4999],pp[0:4999],ss[0:4999];
    integer nvec=0,source_index=0,done=0,accepted=0,queued=0,queued_pending=0;
    integer cycle=0,phase=0,advance=0,active=0,active_id=0;
    integer ia,ib,im,in_,itag,ex,ep,es,accept_cycle=0,first_seen=0,out_age=0;
    integer div_steps=0,orbit_steps=0,matches=0,total_div=0,total_orbit=0,total_matches=0;
    integer source_holds=0,output_holds=0,latency_checks=0,max_latency=0;
    integer state_mask=0,job_mask=0,status_mask=0,resets=0,fresh=0,fresh_done=0;
    integer previous_source_hold=0,previous_output_hold=0;
    reg [4*W+TAG_W-1:0] previous_source;
    reg [4*W+TAG_W+2:0] previous_output;
    integer fixture_file,trace_file,rc,guard,target,alias_target;
    reg [1023:0] fixture_path,trace_path;

    // The next actual fixture token remains asserted and unchanged until accepted.
    always @(negedge clk) begin
        if (!rst && phase==0) begin
            if (advance) begin source_index=source_index+1;advance=0;s_valid=0;end
            if (!s_valid && source_index<nvec) begin
                s_a=aa[source_index];s_b=bb[source_index];s_m=mm[source_index];
                s_n=nn[source_index];s_tag=tt[source_index];s_valid=1;
            end
        end
        if (phase==0 || phase==2) m_ready=(out_age>=3 && cycle%5!=1);
        else m_ready=0;
    end

    always @(posedge clk) begin
        cycle=cycle+1;
        if (rst) begin
            active=0;first_seen=0;out_age=0;previous_source_hold=0;previous_output_hold=0;
        end else if (phase==0 || phase==2) begin
            if (previous_source_hold) begin
                if (!s_valid || {s_a,s_b,s_m,s_n,s_tag}!==previous_source)
                    $fatal(1,"source contract violation");
                source_holds=source_holds+1;
            end
            if (previous_output_hold) begin
                if (!m_valid || {m_solution,m_period,m_status,m_tag}!==previous_output)
                    $fatal(1,"all-field output hold violation");
                output_holds=output_holds+1;
            end
            previous_source_hold=s_valid&&!s_ready;previous_output_hold=m_valid&&!m_ready;
            previous_source={s_a,s_b,s_m,s_n,s_tag};
            previous_output={m_solution,m_period,m_status,m_tag};
            if (phase==0 && s_valid && !s_ready) queued_pending=1;
            if (s_valid && s_ready) begin
                if (active) $fatal(1,"accepted while owned");
                active=1;accept_cycle=cycle;first_seen=0;
                ia=$signed(s_a);ib=$signed(s_b);im=s_m;in_=s_n;itag=s_tag;
                div_steps=0;orbit_steps=0;matches=0;state_mask=state_mask|1;
                if (phase==0) begin
                    active_id=source_index;ex=xx[source_index];ep=pp[source_index];es=ss[source_index];
                    if (source_index>0) begin
                        if (!queued_pending) $fatal(1,"next actual token never queued");
                        queued=queued+1;
                    end
                    queued_pending=0;accepted=accepted+1;advance=1;
                end else begin
                    active_id=nvec+resets-1;es=0;
                    ex=(W==1)?0:((target%2==0)?5:1);ep=(W==1)?1:6;
                end
            end
            if (active) begin
                state_mask=state_mask|(1<<dut.state);
                if (dut.state==1) begin div_steps=div_steps+1;total_div=total_div+1;end
                if (dut.state==2) begin
                    job_mask=job_mask|(1<<dut.job);
                    $fdisplay(trace_file,"D %0d %0d %0d %0d",active_id,dut.job,dut.remainder,dut.divisor);
                end
                if (dut.state==3) begin
                    orbit_steps=orbit_steps+1;total_orbit=total_orbit+1;
                    if (dut.orbit_residue==dut.r2) begin matches=matches+1;total_matches=total_matches+1;end
                    $fdisplay(trace_file,"R %0d %0d %0d %0d %0d %0d",active_id,
                        dut.candidate,dut.orbit_residue,dut.next_candidate,dut.residue_reduced,dut.found);
                end
            end
            if (m_valid && m_ready) begin
                if (!active) $fatal(1,"unowned output");
                active=0;
                if (phase==0) done=done+1;
                else begin fresh=fresh+1;fresh_done=1;end
            end
            #1;
            if (m_valid) begin
                if (m_solution!==ex || m_period!==ep || m_status!==es || m_tag!==itag)
                    $fatal(1,"result id=%0d a=%0d b=%0d m=%0d n=%0d got=%0d/%0d status=%0d expected=%0d/%0d status=%0d",
                        active_id,ia,ib,im,in_,m_solution,m_period,m_status,ex,ep,es);
                if (!first_seen) begin
                    first_seen=1;latency_checks=latency_checks+1;status_mask=status_mask|(1<<m_status);
                    if (cycle-accept_cycle>max_latency) max_latency=cycle-accept_cycle;
                    if (cycle-accept_cycle>BOUND) $fatal(1,"latency bound");
                    $fdisplay(trace_file,"O %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                        active_id,ia,ib,im,in_,itag,m_solution,m_period,m_status,
                        cycle-accept_cycle,div_steps,orbit_steps,matches);
                end
                out_age=out_age+1;
            end else out_age=0;
        end else begin previous_source_hold=0;previous_output_hold=0;out_age=0;end
    end

    function integer at_target(input integer t);
        begin
            if (t==0) at_target=dut.state==0;
            else if (t<=8) at_target=(dut.state==1 && dut.job==(t-1)/2 &&
                                                     dut.div_count==((t%2==1)?0:W-1));
            else if (t<=12) at_target=(dut.state==2 && dut.job==t-9);
            else case(t)
                13:at_target=(dut.state==3 && !dut.found);
                14:at_target=(W==1)?(dut.state==4):(dut.state==3 && dut.found);
                15:at_target=(dut.state==4);
                16:at_target=(dut.state==5 && m_status==0);
                17:at_target=(dut.state==5 && m_status==1);
                18:at_target=(dut.state==5 && m_status==2);
                19:at_target=(dut.state==5 && m_status==3);
                20:at_target=(dut.state==5 && m_status==((W==1)?0:4));
                default:at_target=0;
            endcase
        end
    endfunction

    initial begin
        if (!$value$plusargs("FIXTURE=%s",fixture_path) || !$value$plusargs("TRACE=%s",trace_path))
            $fatal(1,"missing paths");
        fixture_file=$fopen(fixture_path,"r");trace_file=$fopen(trace_path,"w");
        if (!fixture_file || !trace_file) $fatal(1,"file open");
        while (!$feof(fixture_file)) begin
            rc=$fscanf(fixture_file,"%d %d %d %d %d %d %d %d\n",aa[nvec],bb[nvec],mm[nvec],nn[nvec],tt[nvec],xx[nvec],pp[nvec],ss[nvec]);
            if (rc==8) nvec=nvec+1;else if (rc!=-1) $fatal(1,"fixture parse");
        end
        $fclose(fixture_file);
        repeat(2) @(negedge clk);
        rst=0;guard=0;
        while (done<nvec) begin
            @(negedge clk);guard=guard+1;
            if (guard>nvec*(BOUND+30)) $fatal(1,"main watchdog");
        end
        phase=1;s_valid=0;m_ready=0;
        for (target=0;target<21;target=target+1) begin
            if (target!=0) begin
                s_a=0;s_b=0;s_m=1;s_n=(1<<W)-1;s_tag=target;
                if (target==17 || target==19) s_m=0;
                if (target==18 || target==19) s_n=0;
                if (target==20 && W>1) begin s_m=2;s_n=2;s_b=1;end
                s_valid=1;@(posedge clk);#2;@(negedge clk);s_valid=0;
            end
            guard=0;
            while (!at_target(target)) begin
                @(negedge clk);guard=guard+1;
                if (guard>BOUND+5) $fatal(1,"unreachable reset target %0d",target);
            end
            alias_target=(W==1 && (target==14 || target==20));
            $fdisplay(trace_file,"X %0d %0d %0d %0d %0d %0d %0d",target,dut.state,
                (dut.state==1 || dut.state==2)?dut.job:0,(dut.state==1)?dut.div_count:0,
                (dut.state==3)?dut.found:0,(dut.state==5)?m_status:0,alias_target);
            // Observe the target at this falling edge and assert reset immediately.
            rst=1;resets=resets+1;#1;
            if (s_ready!==0 || m_valid!==0) $fatal(1,"immediate reset gating");
            @(posedge clk);#2;
            if (dut.state!==0 || m_valid!==0 || s_ready!==0 ||
                m_solution!==0 || m_period!==0 || m_status!==0 || m_tag!==0) $fatal(1,"reset cancel");
            @(negedge clk);rst=0;phase=2;fresh_done=0;
            if (W==1) begin s_a=-1;s_b=0;s_m=1;s_n=1;end
            else if (target%2==0) begin s_a=-1;s_b=1;s_m=2;s_n=3;end
            else begin s_a=1;s_b=-1;s_m=3;s_n=2;end
            s_tag=target+73;s_valid=1;@(posedge clk);#2;@(negedge clk);s_valid=0;
            guard=0;
            while (!fresh_done) begin
                @(negedge clk);guard=guard+1;
                if (guard>BOUND+20) $fatal(1,"fresh watchdog");
            end
            if (m_valid || dut.state!=0) $fatal(1,"fresh retirement");
            phase=1;m_ready=0;
        end
        repeat(3) begin @(negedge clk);if(m_valid) $fatal(1,"stale output");end
        $fclose(trace_file);
        if (accepted!=nvec || done!=nvec || queued!=nvec-1 || fresh!=21 || resets!=21 ||
            state_mask!=63 || job_mask!=15 || status_mask!=((W==1)?15:31) ||
            max_latency!=BOUND || source_holds==0 || output_holds==0) $fatal(1,"coverage/queue totals");
        $display("PASS W=%0d T=%0d frames=%0d queued=%0d resets=%0d fresh=%0d div_steps=%0d orbit_steps=%0d matches=%0d source_holds=%0d output_holds=%0d latency_checks=%0d max_latency=%0d states=%x jobs=%x statuses=%x",
            W,TAG_W,nvec,queued,resets,fresh,total_div,total_orbit,total_matches,source_holds,output_holds,
            latency_checks,max_latency,state_mask,job_mask,status_mask);
        $finish;
    end
endmodule
