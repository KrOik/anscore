// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_affine_floor_sum;
    parameter integer W=8, TAG_W=8, CYCLE_LIMIT=500000;
    localparam integer BOUND=(2*W+1)*(10*W+7);
    reg clk=0; always #5 clk=~clk;
    reg rst=1, s_valid=0, m_ready=0;
    wire s_ready, m_valid;
    reg [W-1:0] s_n=0, s_a=0, s_b=0, s_m=0;
    reg [TAG_W-1:0] s_tag=0;
    wire [3*W-1:0] m_sum;
    wire m_error;
    wire [TAG_W-1:0] m_tag;
    affine_floor_sum #(.W(W),.TAG_W(TAG_W)) dut(.*);
    integer nn[0:4999], aa[0:4999], bb[0:4999], mm[0:4999], ee[0:4999];
    reg [31:0] tt[0:4999];
    reg [63:0] xx[0:4999];
    integer pn[0:30],pa[0:30],pb[0:30],pm[0:30],pe[0:30];
    integer fn[0:30],fa[0:30],fb[0:30],fm[0:30],fe[0:30];
    reg [31:0] pt[0:30],ft[0:30];
    reg [63:0] px[0:30],fx[0:30];
    integer nvec=0, source_index=0, done=0, accepted=0, queued=0;
    integer queued_pending=0, advance=0, phase=0, active=0, active_id=0;
    integer cycle=0, accept_cycle=0, first_seen=0, out_age=0;
    integer in_n,in_a,in_b,in_m,expected_error;
    reg [TAG_W-1:0] in_tag;
    reg [63:0] expected_sum;
    integer mul_steps=0,div_steps=0,round_count=0,total_mul=0,total_div=0,total_rounds=0;
    integer source_holds=0,output_holds=0,latency_checks=0,max_latency=0;
    integer state_mask=0,mul_mask=0,div_mask=0,error_mask=0,resets=0,fresh=0;
    integer fresh_done=0,fresh_accepted=0,previous_source_hold=0,previous_output_hold=0;
    reg [4*W+TAG_W-1:0] previous_source;
    reg [3*W+TAG_W:0] previous_output;
    integer probe_round=0,probe_hold=0,probe_job,probe_count,probe_y;
    integer fixture_file,reset_file,trace_file,rc,rid,target,guard,alias_target;
    reg [1023:0] fixture_path,reset_path,trace_path;

    // Every queued request is the next actual immutable fixture token.
    always @(negedge clk) begin
        if (!rst && phase==0) begin
            if (advance) begin source_index=source_index+1;advance=0;s_valid=0;end
            if (!s_valid && source_index<nvec) begin
                s_n=nn[source_index];s_a=aa[source_index];s_b=bb[source_index];
                s_m=mm[source_index];s_tag=tt[source_index];s_valid=1;
            end
        end
        if (phase==0 || phase==2) m_ready=(out_age>=4 && cycle%5!=1);
        else m_ready=0;
    end

    always @(posedge clk) begin
        cycle=cycle+1;
        if (cycle>CYCLE_LIMIT) $fatal(1,"frozen cycle budget exceeded");
        if (rst) begin
            active=0;first_seen=0;out_age=0;
            previous_source_hold=0;previous_output_hold=0;
        end else if (phase==0 || phase==2) begin
            if (previous_source_hold) begin
                if (!s_valid || {s_n,s_a,s_b,s_m,s_tag}!==previous_source)
                    $fatal(1,"actual queued token changed before acceptance");
                source_holds=source_holds+1;
            end
            if (previous_output_hold) begin
                if (!m_valid || {m_sum,m_error,m_tag}!==previous_output)
                    $fatal(1,"all-field output hold violation");
                output_holds=output_holds+1;
            end
            previous_source_hold=s_valid&&!s_ready;
            previous_output_hold=m_valid&&!m_ready;
            previous_source={s_n,s_a,s_b,s_m,s_tag};
            previous_output={m_sum,m_error,m_tag};
            if (active && s_ready) $fatal(1,"input ready while owned");
            if (phase==0 && s_valid && !s_ready) queued_pending=1;
            if (s_valid && s_ready) begin
                if (active) $fatal(1,"acceptance while owned");
                active=1;accept_cycle=cycle;first_seen=0;
                in_n=s_n;in_a=s_a;in_b=s_b;in_m=s_m;in_tag=s_tag;
                mul_steps=0;div_steps=0;round_count=0;state_mask=state_mask|1;
                if (phase==0) begin
                    active_id=source_index;expected_sum=xx[source_index];expected_error=ee[source_index];
                    if (source_index>0) begin
                        if (!queued_pending) $fatal(1,"next actual token was never queued");
                        queued=queued+1;
                    end
                    queued_pending=0;accepted=accepted+1;advance=1;
                end else begin
                    active_id=nvec+target;expected_sum=fx[target];expected_error=fe[target];fresh_accepted=1;
                end
            end
            if (active) begin
                state_mask=state_mask|(1<<dut.state);
                if (dut.state==1) begin
                    round_count=round_count+1;total_rounds=total_rounds+1;
                    $fdisplay(trace_file,"T %0d %0d %0d %0d %0d %0d %0d",active_id,
                        round_count,dut.n,dut.a,dut.b,dut.m,m_sum);
                end
                if (dut.state==2) begin mul_steps=mul_steps+1;total_mul=total_mul+1;end
                if (dut.state==4) begin div_steps=div_steps+1;total_div=total_div+1;end
                if (dut.state==3) begin
                    mul_mask=mul_mask|(1<<dut.mul_job);
                    $fdisplay(trace_file,"M %0d %0d %0d",active_id,dut.mul_job,dut.mul_acc);
                    if (dut.mul_job==3)
                        $fdisplay(trace_file,"Y %0d %0d %0d %0d %0d %0d %0d",active_id,
                            dut.n,dut.a,dut.b,dut.m,dut.y,dut.y>=dut.m);
                end
                if (dut.state==5) begin
                    div_mask=div_mask|(1<<dut.div_job);
                    $fdisplay(trace_file,"D %0d %0d %0d %0d %0d",active_id,
                        dut.div_job,dut.div_q,dut.remainder,dut.m);
                end
            end
            if (m_valid && m_ready) begin
                if (!active) $fatal(1,"unowned response");
                active=0;
                if (phase==0) done=done+1;
                else begin fresh=fresh+1;fresh_done=1;end
            end
            #1;
            if (m_valid) begin
                if (!active) $fatal(1,"ghost response");
                if (m_sum!==expected_sum[3*W-1:0] || m_error!==expected_error[0] || m_tag!==in_tag)
                    $fatal(1,"result id=%0d got=%0d/%0d expected=%0d/%0d tag=%0d expected_tag=%0d",
                        active_id,m_sum,m_error,expected_sum,expected_error,m_tag,in_tag);
                if (!first_seen) begin
                    first_seen=1;latency_checks=latency_checks+1;error_mask=error_mask|(1<<m_error);
                    if (cycle-accept_cycle>max_latency) max_latency=cycle-accept_cycle;
                    if (cycle-accept_cycle>BOUND) $fatal(1,"latency bound");
                    if (cycle-accept_cycle != ((in_n==0 || in_m==0)?0:round_count*(10*W+8)-(2*W+1)))
                        $fatal(1,"exact round latency");
                    $fdisplay(trace_file,"O %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                        active_id,in_n,in_a,in_b,in_m,in_tag,m_sum,m_error,
                        cycle-accept_cycle,mul_steps,div_steps,round_count);
                end
                out_age=out_age+1;
            end else out_age=0;
        end else begin
            previous_source_hold=0;previous_output_hold=0;out_age=0;
            if (dut.state==1) probe_round=probe_round+1;
            if (m_valid) probe_hold=probe_hold+1;
            #1;
            if (m_valid && (m_sum!==px[target][3*W-1:0] || m_error!==pe[target][0] || m_tag!==pt[target][TAG_W-1:0]))
                $fatal(1,"reset-owner result differs from independent fixture");
        end
    end

    function integer at_target(input integer t);
        integer j,c;
        begin
            at_target=0;
            if (t==0) at_target=dut.state==0;
            else if (t==1) at_target=dut.state==1;
            else if (t<=9) begin
                j=(t-2)/2;c=((t-2)%2==0)?0:W-1;
                at_target=dut.state==2 && dut.mul_job==j && dut.mul_count==c;
            end else if (t<=13) at_target=dut.state==3 && dut.mul_job==t-10;
            else if (t<=19) begin
                j=(t-14)/2;c=((t-14)%2==0)?0:2*W-1;
                if (W==1 && j==2) at_target=dut.state==3 && dut.mul_job==3 && dut.y<dut.m;
                else at_target=dut.state==4 && dut.div_job==j && dut.div_count==c;
            end else if (t<=22) begin
                if (W==1 && t==22) at_target=dut.state==3 && dut.mul_job==3 && dut.y<dut.m;
                else at_target=dut.state==5 && dut.div_job==t-20;
            end else if (t==23) at_target=dut.state==3 && dut.mul_job==3 && dut.y<dut.m;
            else if (t==24) at_target=dut.state==3 && dut.mul_job==3 && ((W==1)?dut.y<dut.m:dut.y>=dut.m);
            else if (t==25 || t==26 || t==27 || t==30) at_target=dut.state==6 && probe_hold>=3;
            else if (t==28) at_target=dut.state==1 && ((W==1)?probe_round==0:probe_round>=2);
            else if (t==29) at_target=dut.state==6 && probe_hold==0;
        end
    endfunction

    initial begin
        if (!$value$plusargs("FIXTURE=%s",fixture_path) || !$value$plusargs("RESETS=%s",reset_path)
            || !$value$plusargs("TRACE=%s",trace_path)) $fatal(1,"fixture/reset/trace paths required");
        fixture_file=$fopen(fixture_path,"r");reset_file=$fopen(reset_path,"r");trace_file=$fopen(trace_path,"w");
        if (!fixture_file || !reset_file || !trace_file) $fatal(1,"file open failed");
        while (!$feof(fixture_file)) begin
            rc=$fscanf(fixture_file,"%d %d %d %d %d %d %d\n",
                nn[nvec],aa[nvec],bb[nvec],mm[nvec],tt[nvec],xx[nvec],ee[nvec]);
            if (rc==7) nvec=nvec+1;
            else if (rc!=-1) $fatal(1,"invalid main fixture");
        end
        if (nvec<1 || nvec>4999) $fatal(1,"invalid frame count");
        for (target=0;target<31;target=target+1) begin
            rc=$fscanf(reset_file,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                rid,pn[target],pa[target],pb[target],pm[target],pt[target],px[target],pe[target],
                fn[target],fa[target],fb[target],fm[target],ft[target],fx[target],fe[target]);
            if (rc!=15 || rid!=target) $fatal(1,"invalid reset fixture");
        end
        $fclose(fixture_file);$fclose(reset_file);
        repeat (2) @(posedge clk);
        @(negedge clk);rst=0;
        while (done<nvec) @(negedge clk);
        phase=1;s_valid=0;m_ready=0;
        for (target=0;target<31;target=target+1) begin
            @(negedge clk);
            probe_round=0;probe_hold=0;
            s_n=pn[target];s_a=pa[target];s_b=pb[target];s_m=pm[target];s_tag=pt[target];
            s_valid=(target!=0);m_ready=0;
            @(posedge clk);#2;s_valid=0;
            guard=0;
            while (!at_target(target)) begin
                @(posedge clk);#2;guard=guard+1;
                if (guard>BOUND+8) $fatal(1,"unreached frozen reset target %0d",target);
            end
            probe_job=-1;probe_count=-1;probe_y=-1;
            if (dut.state==2 || dut.state==3) probe_job=dut.mul_job;
            if (dut.state==4 || dut.state==5) probe_job=dut.div_job;
            if (dut.state==2) probe_count=dut.mul_count;
            if (dut.state==4) probe_count=dut.div_count;
            if (dut.state==3 && dut.mul_job==3) probe_y=dut.y>=dut.m;
            alias_target=(W==1 && (target==18 || target==19 || target==22 || target==24 || target==28));
            $fdisplay(trace_file,"X %0d %0d %0d %0d %0d %0d %0d %0d %0d",target,
                dut.state,probe_job,probe_count,probe_round,probe_hold,probe_y,
                (dut.state==6)?m_error:-1,alias_target);
            // Assert immediately after the actual requested boundary observation.
            rst=1;#1;
            if (s_ready!==0 || m_valid!==0) $fatal(1,"reset combinational gate");
            @(posedge clk);#2;
            if (dut.state!==0 || m_valid!==0 || m_sum!==0 || m_error!==0 || m_tag!==0)
                $fatal(1,"reset cancellation/public clear");
            resets=resets+1;
            @(negedge clk);
            phase=2;rst=0;fresh_done=0;fresh_accepted=0;
            s_n=fn[target];s_a=fa[target];s_b=fb[target];s_m=fm[target];s_tag=ft[target];s_valid=1;
            while (!fresh_accepted) @(negedge clk);
            s_valid=0;
            while (!fresh_done) @(negedge clk);
            phase=1;m_ready=0;
        end
        if (done!=nvec || accepted!=nvec || queued!=nvec-1 || resets!=31 || fresh!=31)
            $fatal(1,"incomplete frozen accounting");
        if (state_mask!=127 || mul_mask!=15 || div_mask!=((W==1)?3:7) || error_mask!=3)
            $fatal(1,"missing state/job/error coverage");
        $fclose(trace_file);
        $display("PASS W=%0d TAG=%0d frames=%0d queued=%0d resets=%0d fresh=%0d mul_steps=%0d div_steps=%0d rounds=%0d source_holds=%0d output_holds=%0d latency_checks=%0d max_latency=%0d states=%0h mul_jobs=%0h div_jobs=%0h errors=%0h cycles=%0d",
            W,TAG_W,nvec,queued,resets,fresh,total_mul,total_div,total_rounds,source_holds,output_holds,
            latency_checks,max_latency,state_mask,mul_mask,div_mask,error_mask,cycle);
        $finish;
    end
endmodule
