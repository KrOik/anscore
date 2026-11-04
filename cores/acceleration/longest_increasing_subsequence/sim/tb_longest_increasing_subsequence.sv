// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_longest_increasing_subsequence;
    parameter integer W=16,N=64,T=8;
    localparam integer I=(N>1)?$clog2(N):1,C=$clog2(N+1),
        INW=W+T+3+2*C, OUTW=W+2*I+2*C+T+5;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_first=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_value=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_first,m_last;
    wire signed [W-1:0] m_value;
    wire [I-1:0] m_index,m_rank;
    wire [C-1:0] m_length,m_count;
    wire [T-1:0] m_tag;
    wire [1:0] m_errors;
    longest_increasing_subsequence #(.VALUE_W(W),.MAX_SAMPLES(N),.TAG_W(T)) dut(.*);
    reg [INW-1:0] tokens[0:100000];
    reg [C-1:0] exp_pos,exp_len,committed_pos,committed_len;
    wire [OUTW-1:0] payload={m_value,m_index,m_rank,m_length,m_count,m_keep,m_first,m_last,m_tag,m_errors};
    reg [OUTW-1:0] held_payload;
    reg held=0;
    integer phase=0,cycles=0,main_cycles=0,input_count=0,output_count=0;
    integer closed=0,frames=0,compares=0,writes=0,held_cycles=0,blocked=0;
    integer fresh_rank=0,fresh_done=0,resets=0,fresh_frames=0;
    integer total_tokens,total_frames,outfile,summary_file,i,target,waitcycles;
    reg [1023:0] vector_path,actual_path,summary_path;
    always @(negedge clk) if (phase==2) m_ready=((cycles%13)>3 && (cycles%53)>7);
    always @(posedge clk) begin
        cycles=cycles+1;
        if (cycles>2500000) $fatal(1,"watchdog");
        if (rst) held=0;
        else begin
            if (held && (!m_valid || payload!==held_payload)) $fatal(1,"held output changed");
            held=m_valid && !m_ready; held_payload=payload;
            if (phase==2) begin
                main_cycles=main_cycles+1;
                if (s_valid && !s_ready) blocked=blocked+1;
                if (m_valid && !m_ready) held_cycles=held_cycles+1;
                if (s_valid && s_ready) begin
                    input_count=input_count+1;
                    if (s_last) closed=closed+1;
                    committed_pos=exp_pos; committed_len=exp_len;
                end
                if (dut.state==2) compares=compares+1;
                if (dut.state==4) begin
                    if (dut.position!==committed_pos) $fatal(1,"prefix ending DAG length");
                    if (((dut.position==dut.length)?dut.length+1:dut.length)!=committed_len)
                        $fatal(1,"prefix optimum DAG length");
                    writes=writes+1;
                end
                if (m_valid && m_ready) begin
                    if (frames>=closed) $fatal(1,"result before LAST");
                    $fdisplay(outfile,"%h",payload); output_count=output_count+1;
                    if (m_last) frames=frames+1;
                end
            end
            if (phase==1 && m_valid && m_ready) begin
                if (m_errors!==0 || !m_keep || m_index!=fresh_rank || m_rank!=fresh_rank ||
                    $signed(m_value)!=(fresh_rank-N/2) || m_length!=N || m_count!=N ||
                    m_first!=(fresh_rank==0) || m_last!=(fresh_rank==N-1) || m_tag!=1)
                    $fatal(1,"fresh recovery result rank=%0d",fresh_rank);
                fresh_rank=fresh_rank+1;
                if (m_last) fresh_done=1;
            end
        end
    end
    task reset_now;
        begin
            // Callers observe their target on a low clock boundary. Assert
            // reset there, before the target can execute another active edge.
            if (clk!==1'b0) $fatal(1,"reset probe must observe low clock");
            rst=1; s_valid=0; m_ready=0;
            #1; if (s_ready || m_valid) $fatal(1,"reset gating");
            @(posedge clk); #1;
            if (dut.state!=0 || m_value!==0 || m_index!==0 || m_rank!==0 ||
                m_length!==0 || m_count!==0 || m_keep!==0 || m_first!==0 ||
                m_last!==0 || m_tag!==0 || m_errors!==0) $fatal(1,"reset cancellation");
            @(negedge clk); rst=0; resets=resets+1;
        end
    endtask
    task offer(input integer value,keep,first,last,tagv);
        begin
            @(negedge clk); s_value=value; s_keep=keep; s_first=first;
            s_last=last; s_tag=tagv; s_valid=1;
            begin: wait_accept
                forever begin @(posedge clk); if (s_ready) disable wait_accept; end
            end
            @(negedge clk); s_valid=0;
        end
    endtask
    task ascending;
        integer j;
        begin for (j=0;j<N;j=j+1) offer(j-N/2,1,j==0,j==N-1,j==0?1:0); end
    endtask
    task recovery;
        begin
            phase=1; fresh_rank=0; fresh_done=0; m_ready=1;
            ascending(); wait(fresh_done); @(negedge clk);
            if (fresh_rank!=N) $fatal(1,"incomplete fresh frame");
            phase=0; m_ready=0; fresh_frames=fresh_frames+1;
        end
    endtask
    task probe(input integer st,mode);
        begin
            phase=0; m_ready=0;
            fork: interrupt_frame
                begin ascending(); forever @(negedge clk); end
                begin
                    begin: seek_state
                        forever begin
                            @(negedge clk);
                            if (dut.state==st &&
                                (mode==0 || (mode==1 && dut.count>=N/2) ||
                                 (mode==2 && dut.remaining<=N/2) ||
                                 (mode==3 && dut.out_pos>0))) disable seek_state;
                        end
                    end
                end
            join_any
            disable interrupt_frame;
            reset_now(); recovery();
        end
    endtask
    initial begin
        if (!$value$plusargs("VECTORS=%s",vector_path) ||
            !$value$plusargs("ACTUAL=%s",actual_path) ||
            !$value$plusargs("SUMMARY=%s",summary_path) ||
            !$value$plusargs("TOKENS=%d",total_tokens) ||
            !$value$plusargs("FRAMES=%d",total_frames)) $fatal(1,"missing args");
        $readmemh(vector_path,tokens,0,total_tokens-1);
        outfile=$fopen(actual_path,"w");
        reset_now(); recovery();
        for(target=0;target<12;target=target+1)
            if (!(N==1 && (target==2 || target==3))) probe(target,0);
        if(N>2) begin probe(2,1); probe(7,2); probe(8,2); end
        if(N>1) begin
            // Replay can advance only when ready; stop at second held record.
            m_ready=1;
            fork: mid_replay
                begin ascending(); forever @(negedge clk); end
                begin wait(dut.state==11 && dut.out_pos>0); @(negedge clk); m_ready=0; end
            join_any
            disable mid_replay;
            reset_now(); recovery();
        end
        offer(0,0,1,1,1); wait(m_valid); repeat(3) @(negedge clk);
        reset_now(); recovery();
        offer(0,0,0,1,1); wait(m_valid); repeat(3) @(negedge clk);
        reset_now(); recovery();
        // Pending next transaction is blocked while the current tail is held.
        fork: blocked_next
            begin ascending(); forever @(negedge clk); end
            begin wait(m_valid); @(negedge clk); s_valid=1; s_keep=1; s_first=1; s_last=1;
                repeat(3) begin @(negedge clk); if(s_ready) $fatal(1,"next frame escaped"); end end
        join_any
        disable blocked_next;
        reset_now(); recovery();
        phase=2;
        for(i=0;i<total_tokens;i=i+1) begin
            @(negedge clk);
            if(cycles%4==0) @(negedge clk);
            {s_value,s_keep,s_first,s_last,s_tag,exp_pos,exp_len}=tokens[i]; s_valid=1;
            begin: main_accept
                forever begin @(posedge clk); if(s_ready) disable main_accept; end
            end
            @(negedge clk); s_valid=0;
        end
        wait(frames==total_frames); repeat(8) @(negedge clk);
        if(m_valid || input_count!=total_tokens) $fatal(1,"duplicate/lost output/input");
        $fclose(outfile);
        summary_file=$fopen(summary_path,"w");
        $fdisplay(summary_file,"{\"inputs\":%0d,\"outputs\":%0d,\"frames\":%0d,\"compares\":%0d,\"writes\":%0d,\"cycles\":%0d,\"held\":%0d,\"blocked\":%0d,\"resets\":%0d,\"fresh_recoveries\":%0d}",
            input_count,output_count,frames,compares,writes,main_cycles,held_cycles,blocked,resets,fresh_frames);
        $fclose(summary_file);
        $display("PASS LIS W=%0d N=%0d T=%0d frames=%0d resets=%0d",W,N,T,frames,resets);
        $finish;
    end
endmodule
