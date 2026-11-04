// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_exact_weighted_set_cover;
    parameter integer N=8,U=16,W=8,T=8,FRAMES=1,BEATS=1;
    localparam integer CW=W+((N>1)?$clog2(N):0),RW=U+W+1;
    reg clk=0,rst=1,c_valid=0,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    wire c_ready,s_ready,m_valid,m_feasible;
    reg [U-1:0] c_target=0,s_members=0;
    reg [T-1:0] c_tag=0;
    reg [W-1:0] s_weight=0;
    reg s_last=0;
    wire [N-1:0] m_selection;
    wire [CW-1:0] m_weight;
    wire [1:0] m_error;
    wire [T-1:0] m_tag;
    exact_weighted_set_cover #(.NUM_SETS(N),.UNIVERSE_W(U),.WEIGHT_W(W),.TAG_W(T)) dut(.*);
    reg [U+T-1:0] commands[0:FRAMES-1];
    reg [RW-1:0] words[0:BEATS-1];
    reg [U+T-1:0] old_command;
    reg [RW-1:0] old_source;
    reg [N+CW+T+2:0] old_result;
    wire [U+T-1:0] command_bundle={c_target,c_tag};
    wire [RW-1:0] source_bundle={s_members,s_weight,s_last};
    wire [N+CW+T+2:0] result_bundle={m_feasible,m_selection,m_weight,m_error,m_tag};
    reg wait_command=0,wait_source=0,wait_result=0;
    integer cycle=0,accepted_c=0,accepted_s=0,retired=0,tail_cycle=0,phase=0;
    integer blocked_c=0,blocked_s=0,holds_c=0,holds_s=0,queued_c=0,queued_s=0,held=0;
    integer branches=0,evals=0,pops=0,max_sp=0,invariants=0;
    integer mode,out_file,trace_file,seen_states=0,resets=0,fresh=0;
    integer sum_check,k;
    reg [U-1:0] cover_check;
    string command_path,input_path,output_path,trace_path;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin wait_command=0;wait_source=0;wait_result=0;end
        else begin
            if(wait_command)begin
                if(!c_valid || command_bundle!==old_command)$fatal(1,"command holding");
                if(phase==1)holds_c=holds_c+1;
            end
            if(wait_source)begin
                if(!s_valid || source_bundle!==old_source)$fatal(1,"row holding");
                if(phase==1)holds_s=holds_s+1;
            end
            if(wait_result && (!m_valid || result_bundle!==old_result))$fatal(1,"result holding");
            if(c_valid && c_ready)begin
                accepted_c=accepted_c+1;
                if(phase==1 && wait_command)queued_c=queued_c+1;
            end
            if(s_valid && s_ready)begin
                accepted_s=accepted_s+1;
                if(s_last || dut.load_index==N-1)tail_cycle=cycle;
                if(phase==1 && wait_source)queued_s=queued_s+1;
            end
            if(m_valid && m_ready)retired=retired+1;
            wait_command=c_valid && !c_ready;old_command=command_bundle;
            wait_source=s_valid && !s_ready;old_source=source_bundle;
            wait_result=m_valid && !m_ready;old_result=result_bundle;
            if(phase==1)begin
                if(c_valid && !c_ready)blocked_c=blocked_c+1;
                if(s_valid && !s_ready)blocked_s=blocked_s+1;
                if(m_valid && !m_ready)held=held+1;
                if(dut.state==3)branches=branches+1;
                if(dut.state==5)pops=pops+1;
                if(dut.sp>max_sp)max_sp=dut.sp;
                if(dut.state==2)begin
                    evals=evals+1;sum_check=0;cover_check=0;
                    if(dut.depth>N || dut.sp>dut.depth || (dut.selected>>dut.depth)!=0)$fatal(1,"prefix bounds");
                    for(k=0;k<N;k=k+1)if(dut.selected[k])begin
                        cover_check=cover_check | dut.rows[k][W+:U];
                        sum_check=sum_check+dut.rows[k][W-1:0];
                    end
                    if(dut.cost!==CW'(sum_check) || dut.covered!==cover_check)$fatal(1,"node certificate");
                    invariants=invariants+1;
                end
            end
        end
    end
    task drive_command(input [U+T-1:0] word);
        begin {c_target,c_tag}=word;c_valid=1;end
    endtask
    task drive_row(input [RW-1:0] word);
        begin {s_members,s_weight,s_last}=word;s_valid=1;end
    endtask
    task cancel;
        begin
            rst=1;#1;if(c_ready || s_ready || m_valid)$fatal(1,"reset public gate");
            @(posedge clk);@(negedge clk);c_valid=0;s_valid=0;m_ready=0;rst=0;
        end
    endtask
    task recovery;
        integer bc,bs,br;
        begin
            bc=accepted_c;bs=accepted_s;br=retired;
            drive_command({{U{1'b1}},T'(5)});
            while(accepted_c==bc)@(negedge clk);
            c_valid=0;
            while(accepted_s-bs<N)begin
                drive_row({{U{1'b1}},{W{1'b0}},(accepted_s-bs==N-1)});
                @(negedge clk);
            end
            s_valid=0;
            while(!m_valid)@(negedge clk);
            if(m_error!==0 || !m_feasible || m_tag!==T'(5) || m_selection!==N'(1) || m_weight!==0)
                $fatal(1,"complete fresh cover recovery");
            for(integer j=0;j<N;j=j+1)
                if(dut.rows[j]!=={{U{1'b1}},{W{1'b0}}})$fatal(1,"fresh complete row bank");
            repeat(3)@(negedge clk);
            m_ready=1;while(retired==br)@(negedge clk);
            m_ready=0;fresh=fresh+1;
        end
    endtask
    task probe(input integer target_state);
        integer bc,bs,idx,limit;
        reg matched;
        begin
            cancel();bc=accepted_c;bs=accepted_s;limit=0;matched=0;
            while(!matched)begin
                case(target_state)
                    8:matched=dut.state==1 && dut.load_index==N/2;
                    9:matched=dut.state==2 && dut.sp==N;
                    10,11:matched=m_valid && m_error!=0;
                    default:matched=dut.state==target_state;
                endcase
                if(matched)begin
                    seen_states=seen_states | (1<<dut.state);
                    // Reset immediately after observing the state, with no intervening active edge.
                    cancel();resets=resets+1;
                end else begin
                    if(accepted_c==bc)drive_command({U'(1),T'(3)});
                    else drive_command({{U{1'b1}},T'(7)});
                    idx=accepted_s-bs;
                    if(idx<N)begin
                        if(target_state==10 && N>1)drive_row({U'(1),W'(1),1'b1});
                        else drive_row({(target_state==9?U'(0):U'(1)),W'(1),
                                        (target_state==11 || (target_state==10 && N==1))?1'b0:(idx==N-1)});
                    end else drive_row({U'(0),W'(0),1'b1});
                    @(negedge clk);limit=limit+1;
                    if(limit>500)$fatal(1,"unreachable reset target %0d",target_state);
                end
            end
            recovery();
        end
    endtask
    initial begin : run
        integer outputs,observed,hold_left,steps,j;
        if(!$value$plusargs("MODE=%d",mode))mode=0;
        if(!$value$plusargs("COMMAND=%s",command_path))$fatal(1,"COMMAND");
        if(!$value$plusargs("INPUT=%s",input_path))$fatal(1,"INPUT");
        if(!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"OUTPUT");
        if(!$value$plusargs("TRACE=%s",trace_path))$fatal(1,"TRACE");
        $readmemh(command_path,commands);$readmemh(input_path,words);
        out_file=$fopen(output_path,"w");trace_file=$fopen(trace_path,"w");
        repeat(3)@(negedge clk);rst=0;
        if(mode==0)begin
            phase=1;outputs=0;observed=0;hold_left=0;steps=0;
            while(outputs<FRAMES)begin
                if(retired>outputs)begin
                    outputs=retired;observed=0;branches=0;evals=0;pops=0;max_sp=0;
                end
                if(m_valid && !observed)begin
                    $fdisplay(out_file,"R %0d %0d %h %0d %h %h %0d %0d %0d %0d %0d",outputs,m_error,m_tag,m_feasible,m_weight,m_selection,cycle-tail_cycle,branches,evals,pops,max_sp);
                    if(m_error==0)for(j=0;j<N;j=j+1)$fdisplay(trace_file,"A %0d %0d %h",outputs,j,dut.rows[j]);
                    observed=1;hold_left=3+outputs%3;
                end
                if(m_valid && observed && hold_left==0)m_ready=1;
                else begin m_ready=0;if(m_valid && hold_left>0)hold_left=hold_left-1;end
                if(accepted_c<FRAMES)drive_command(commands[accepted_c]);else c_valid=0;
                if(accepted_s<BEATS)drive_row(words[accepted_s]);else s_valid=0;
                @(negedge clk);steps=steps+1;
                if(steps>4000000)$fatal(1,"finite main bound");
            end
            phase=0;c_valid=0;s_valid=0;m_ready=0;
            if(accepted_c!=FRAMES || accepted_s!=BEATS || retired!=FRAMES || blocked_c!=holds_c || blocked_s!=holds_s)
                $fatal(1,"main counts");
            $display("PASS exact_weighted_set_cover mode=main frames=%0d beats=%0d blocked_c=%0d holds_c=%0d blocked_s=%0d holds_s=%0d queued_c=%0d queued_s=%0d held=%0d invariants=%0d",FRAMES,BEATS,blocked_c,holds_c,blocked_s,holds_s,queued_c,queued_s,held,invariants);
        end else begin
            phase=2;for(j=0;j<12;j=j+1)probe(j);
            if(resets!=12 || fresh!=12 || seen_states!=255)$fatal(1,"reset counts/states");
            $display("PASS exact_weighted_set_cover mode=reset resets=%0d fresh=%0d states=%h",resets,fresh,seen_states);
        end
        $fclose(out_file);$fclose(trace_file);$finish;
    end
    initial begin #50000000;$fatal(1,"watchdog");end
endmodule
