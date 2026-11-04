// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_bounded_rational_approx;
    parameter integer W=8, QW=4, TAG_W=8;
    localparam integer BOUND=W+((1<<QW)-1)+3*QW+5;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, s_valid=0, m_ready=0;
    wire s_ready, m_valid;
    reg signed [W-1:0] s_num=0;
    reg [W-1:0] s_den=0;
    reg [QW-1:0] s_limit=0;
    reg [TAG_W-1:0] s_tag=0;
    wire signed [W+QW:0] m_num;
    wire [QW-1:0] m_den;
    wire signed [W:0] m_error;
    wire [1:0] m_status;
    wire [TAG_W-1:0] m_tag;
    bounded_rational_approx #(.W(W),.QW(QW),.TAG_W(TAG_W)) dut (.*);

    integer nums[0:9999], dens[0:9999], limits[0:9999], tags[0:9999];
    integer en[0:9999], ed[0:9999], ee[0:9999], es[0:9999];
    integer nvec=0, source_index=0, done=0, accepted=0, queued=0, queued_pending=0;
    integer cycle=0, phase=0, advance=0, active=0, active_id=0, started=0;
    integer input_n, input_d, input_q, input_tag, expected_n, expected_d, expected_e, expected_s;
    integer accept_cycle=0, first_seen=0, out_age=0, fresh_done=0;
    integer div_steps=0, searches=0, products=0, mul_steps=0;
    integer total_div=0,total_search=0,total_products=0,total_mul=0;
    integer source_holds=0, output_holds=0, latency_checks=0, max_latency=0;
    integer state_mask=0, op_mask=0, resets=0, fresh=0, compare_ties=0;
    integer previous_source_hold=0, previous_output_hold=0;
    reg [2*W+QW+TAG_W-1:0] previous_source;
    reg [2*W+2*QW+TAG_W+3:0] previous_output;
    integer trace_file, fixture_file, rc, guard, k, target, found;
    integer original_a=0, original_b=0;
    integer fresh_sign;
    reg [1023:0] fixture_path, trace_path;

    // A real next token is queued while the preceding owner is busy.
    always @(negedge clk) begin
        if (!rst && phase==0) begin
            if (advance) begin
                source_index=source_index+1; advance=0; s_valid=0;
            end
            if (!s_valid && source_index<nvec &&
                ((source_index%4 != 2) || (cycle%3 == 0))) begin
                s_num=nums[source_index]; s_den=dens[source_index];
                s_limit=limits[source_index]; s_tag=tags[source_index]; s_valid=1;
            end
        end
        if (phase==0 || phase==2) m_ready=(out_age>=3 && cycle%5 != 1);
        else m_ready=0;
    end

    always @(posedge clk) begin
        cycle=cycle+1;
        if (rst) begin
            active=0; first_seen=0; out_age=0;
            previous_source_hold=0; previous_output_hold=0;
        end else if (phase==0 || phase==2) begin
            if (previous_source_hold) begin
                if (!s_valid || {s_num,s_den,s_limit,s_tag} !== previous_source)
                    $fatal(1,"source contract violation");
                source_holds=source_holds+1;
            end
            if (previous_output_hold) begin
                if (!m_valid || {m_num,m_den,m_error,m_status,m_tag} !== previous_output)
                    $fatal(1,"output hold violation");
                output_holds=output_holds+1;
            end
            previous_source_hold=s_valid&&!s_ready;
            previous_output_hold=m_valid&&!m_ready;
            previous_source={s_num,s_den,s_limit,s_tag};
            previous_output={m_num,m_den,m_error,m_status,m_tag};
            if (phase==0 && s_valid && !s_ready) queued_pending=1;
            if (s_valid && s_ready) begin
                active=1; accept_cycle=cycle; first_seen=0;
                input_n=$signed(s_num); input_d=s_den; input_q=s_limit; input_tag=s_tag;
                div_steps=0; searches=0; products=0; mul_steps=0;
                state_mask=state_mask|1;
                if (phase==0) begin
                    active_id=source_index;
                    expected_n=en[source_index]; expected_d=ed[source_index];
                    expected_e=ee[source_index]; expected_s=es[source_index];
                    if (source_index>0) begin
                        if (!queued_pending) $fatal(1,"next token was never queued");
                        queued=queued+1;
                    end
                    queued_pending=0;
                    accepted=accepted+1; advance=1;
                end else begin
                    active_id=nvec+resets-1;
                    expected_n=fresh_sign; expected_d=1; expected_e=0; expected_s=0;
                end
            end
            if (active) begin
                state_mask=state_mask|(1<<dut.state);
                if (dut.state==1) begin div_steps=div_steps+1; total_div=total_div+1; end
                if (dut.state==3) begin
                    searches=searches+1; total_search=total_search+1;
                    $fdisplay(trace_file,"S %0d %0d %0d %0d %0d %0d %0d",active_id,
                              dut.ln,dut.ld,dut.rn,dut.rd,dut.el,dut.er);
                end
                if (dut.state==4) begin
                    if (dut.mul_count==0) begin original_a=dut.mul_a; original_b=dut.mul_b; end
                    mul_steps=mul_steps+1; total_mul=total_mul+1;
                    op_mask=op_mask|(1<<dut.mul_op);
                end
                if (dut.state==5) begin
                    products=products+1; total_products=total_products+1;
                    $fdisplay(trace_file,"M %0d %0d %0d %0d %0d",active_id,
                              dut.mul_op,original_a,original_b,dut.mul_result);
                end
                if (dut.state==6 && dut.compare_left==dut.mul_result) compare_ties=compare_ties+1;
            end
            if (m_valid && m_ready) begin
                active=0;
                if (phase==0) done=done+1;
                else begin fresh=fresh+1; fresh_done=1; end
            end
            #1;
            if (active && dut.state==2)
                $fdisplay(trace_file,"D %0d %0d %0d",active_id,dut.div_quotient,dut.div_remainder);
            if (m_valid) begin
                if ($signed(m_num)!==expected_n || m_den!==expected_d ||
                    $signed(m_error)!==expected_e || m_status!==expected_s || m_tag!==input_tag)
                    $fatal(1,"result id=%0d got=%0d/%0d e=%0d status=%0d tag=%0d expected=%0d/%0d e=%0d status=%0d tag=%0d",
                        active_id,$signed(m_num),m_den,$signed(m_error),m_status,m_tag,
                        expected_n,expected_d,expected_e,expected_s,input_tag);
                if (!first_seen) begin
                    first_seen=1; latency_checks=latency_checks+1;
                    if (cycle-accept_cycle>max_latency) max_latency=cycle-accept_cycle;
                    if (cycle-accept_cycle>BOUND) $fatal(1,"latency bound");
                    $fdisplay(trace_file,"O %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                        active_id,input_n,input_d,input_q,input_tag,$signed(m_num),m_den,
                        $signed(m_error),m_status,cycle-accept_cycle,div_steps,searches,products,mul_steps);
                end
                out_age=out_age+1;
            end else out_age=0;
        end else begin
            previous_source_hold=0; previous_output_hold=0; out_age=0;
        end
    end

    function integer at_target(input integer t);
        begin
            case(t)
            0: at_target=(dut.state==0);
            1: at_target=(dut.state==1 && dut.div_count==0);
            2: at_target=(dut.state==1 && dut.div_count==W-1);
            3: at_target=(dut.state==2);
            4: at_target=(dut.state==3);
            5,6,7: at_target=(dut.state==4 && dut.mul_op==t-5 && dut.mul_count==0);
            8,9,10: at_target=(dut.state==4 && dut.mul_op==t-8 && dut.mul_count==QW-1);
            11,12,13: at_target=(dut.state==5 && dut.mul_op==t-11);
            14: at_target=(dut.state==6);
            15: at_target=(dut.state==7 && m_status==0);
            16: at_target=(dut.state==7 && m_status==1);
            17: at_target=(dut.state==7 && m_status==2);
            18: at_target=(dut.state==7 && m_status==3);
            default: at_target=0;
            endcase
        end
    endfunction

    initial begin
        if (!$value$plusargs("FIXTURE=%s",fixture_path) || !$value$plusargs("TRACE=%s",trace_path))
            $fatal(1,"missing paths");
        fixture_file=$fopen(fixture_path,"r"); trace_file=$fopen(trace_path,"w");
        if (!fixture_file || !trace_file) $fatal(1,"file open");
        while (!$feof(fixture_file)) begin
            rc=$fscanf(fixture_file,"%d %d %d %d %d %d %d %d\n",nums[nvec],dens[nvec],limits[nvec],tags[nvec],en[nvec],ed[nvec],ee[nvec],es[nvec]);
            if (rc==8) nvec=nvec+1;
            else if (rc!=-1) $fatal(1,"fixture parse");
        end
        $fclose(fixture_file);
        repeat(2) @(negedge clk);
        rst=0; started=1;
        guard=0;
        while (done<nvec) begin
            @(negedge clk); guard=guard+1;
            if (guard>nvec*(BOUND+30)) $fatal(1,"main watchdog");
        end
        phase=1; s_valid=0; m_ready=0;
        for (target=0;target<19;target=target+1) begin
            if (target!=0) begin
                s_num=1; s_den=(target==16 || target==18) ? 0 : ((1<<W)-1);
                s_limit=(target==17 || target==18) ? 0 : ((1<<QW)-1);
                s_tag=target; s_valid=1;
                @(posedge clk); #1;
                @(negedge clk); s_valid=0;
            end
            guard=0;
            while (!at_target(target)) begin
                @(negedge clk); guard=guard+1;
                if (guard>BOUND+5) $fatal(1,"unreachable reset target %0d",target);
            end
            // Target is observed on this falling edge: no intervening active edge.
            rst=1; resets=resets+1;
            @(posedge clk); #2;
            if (dut.state!==0 || m_valid!==0 || s_ready!==0) $fatal(1,"reset cancel");
            @(negedge clk);
            rst=0; phase=2; fresh_done=0;
            fresh_sign=(target%2==0) ? 1 : -1;
            s_num=fresh_sign; s_den=1; s_limit=1; s_tag=(target+73); s_valid=1;
            @(posedge clk); #2;
            @(negedge clk); s_valid=0;
            guard=0;
            while (!fresh_done) begin
                @(negedge clk); guard=guard+1;
                if (guard>BOUND+20) $fatal(1,"fresh watchdog");
            end
            phase=1; m_ready=0;
        end
        $fclose(trace_file);
        if (accepted!=nvec || done!=nvec || queued!=nvec-1 || fresh!=19 ||
            state_mask!=255 || op_mask!=7 || max_latency!=BOUND || source_holds==0 || output_holds==0)
            $fatal(1,"coverage/queue totals");
        $display("PASS W=%0d QW=%0d T=%0d frames=%0d queued=%0d resets=%0d fresh=%0d div_steps=%0d searches=%0d products=%0d mul_steps=%0d source_holds=%0d output_holds=%0d latency_checks=%0d max_latency=%0d ties=%0d states=%02x ops=%x",
            W,QW,TAG_W,nvec,queued,resets,fresh,total_div,total_search,total_products,total_mul,
            source_holds,output_holds,latency_checks,max_latency,compare_ties,state_mask,op_mask);
        $finish;
    end
endmodule
