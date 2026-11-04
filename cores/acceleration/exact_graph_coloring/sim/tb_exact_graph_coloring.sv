// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_exact_graph_coloring;
    parameter integer N=8,T=8,BEATS=1,FRAMES=1;
    localparam integer CW=$clog2(N+1),EW=N+CW+1,BW=68+T;
    reg clk=0,rst=1,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    wire s_ready,m_valid;
    reg [31:0] s_u=0,s_v=0;
    reg s_present=0,s_keep=0,s_first=0,s_last=0;
    reg [T-1:0] s_tag=0;
    wire [N*CW-1:0] m_colors;
    wire [CW-1:0] m_count;
    wire [1:0] m_error;
    wire [T-1:0] m_tag;
    exact_graph_coloring #(.NUM_NODES(N),.TAG_W(T)) dut(.*);
    reg [BW-1:0] words[0:BEATS-1];
    reg [BW-1:0] prior_source;
    reg [N*CW+CW+T+1:0] prior_result;
    reg source_wait=0,result_wait=0;
    integer cycle=0,accepted=0,retired=0,phase=0,tail_cycle=0;
    integer blocked=0,held=0,source_holds=0,queued=0;
    integer subsets=0,candidates=0,dp_reads=0,back_reads=0;
    integer out_file,trace_file,mode,seen_states=0;
    integer resets=0,fresh=0;
    string input_path,output_path,trace_path;
    wire [BW-1:0] source_bundle={s_u,s_v,s_present,s_keep,s_first,s_last,s_tag};
    wire [N*CW+CW+T+1:0] result_bundle={m_colors,m_count,m_error,m_tag};
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin source_wait=0;result_wait=0;end
        else begin
            if(source_wait)begin
                if(!s_valid || source_bundle!==prior_source)$fatal(1,"source hold");
                if(phase==1)source_holds=source_holds+1;
            end
            if(result_wait && (!m_valid || result_bundle!==prior_result))$fatal(1,"result hold");
            if(s_valid && s_ready)begin
                if(phase==1 && s_last)tail_cycle=cycle;
                if(phase==1 && source_wait)queued=queued+1;
                accepted=accepted+1;
            end
            source_wait=s_valid && !s_ready;prior_source=source_bundle;
            result_wait=m_valid && !m_ready;prior_result=result_bundle;
            if(m_valid && m_ready)retired=retired+1;
            if(phase==1)begin
                if(s_valid && !s_ready)blocked=blocked+1;
                if(m_valid && !m_ready)held=held+1;
                if(dut.state==8)subsets=subsets+1;
                if(dut.state==10)candidates=candidates+1;
                if(dut.state==12)dp_reads=dp_reads+1;
                if(dut.state==16)back_reads=back_reads+1;
            end
        end
    end
    task drive(input [BW-1:0] word);
        begin {s_u,s_v,s_present,s_keep,s_first,s_last,s_tag}=word;s_valid=1;end
    endtask
    task cancel;
        begin
            rst=1;
            #1;if(s_ready || m_valid)$fatal(1,"reset public gate");
            @(posedge clk);@(negedge clk);
            s_valid=0;m_ready=0;rst=0;
        end
    endtask
    task recovery;
        integer before_accept,before_retire,k;
        reg [EW-1:0] expected_word;
        begin
            before_accept=accepted;before_retire=retired;
            drive({32'hffffffff,32'h80000000,1'b1,1'b0,1'b1,1'b1,T'(5)});
            while(accepted==before_accept)@(negedge clk);
            s_valid=0;
            while(!m_valid)@(negedge clk);
            if(m_error!==0 || m_tag!==T'(5) || m_count!==CW'(1) || m_colors!==0)
                $fatal(1,"fresh full empty-graph recovery");
            for(k=0;k<N;k=k+1)if(dut.adjacency[k]!==0)$fatal(1,"fresh adjacency");
            expected_word={1'b1,{CW{1'b0}},{N{1'b0}}};
            if(dut.table_mem[0]!==expected_word)$fatal(1,"fresh DP zero");
            for(k=1;k<(1<<N);k=k+1)begin
                expected_word={1'b1,CW'(1),N'(k)};
                if(dut.table_mem[k]!==expected_word)$fatal(1,"fresh complete DP image");
            end
            repeat(3)@(negedge clk);
            m_ready=1;
            while(retired==before_retire)@(negedge clk);
            m_ready=0;fresh=fresh+1;
        end
    endtask
    task probe(input integer target);
        integer actual,before_accept,idx,a,b,limit;
        reg matched;
        begin
            cancel();
            actual=target;
            if(N==1 && ((target>=2 && target<=5)||(target>=10 && target<=13)))actual=6;
            before_accept=accepted;matched=0;limit=0;
            while(!matched)begin
                matched=(target==19)?(dut.state==1 && dut.started):
                        (target==20)?(dut.state==0 && dut.cursor==N/2):
                        (target==21)?(dut.state==18 && m_error!=0):(dut.state==actual);
                if(matched)begin
                    seen_states=seen_states | (1<<dut.state);
                    // Reset now, before any further active edge in this phase.
                    cancel();resets=resets+1;
                end else begin
                    idx=accepted-before_accept;
                    if(target==21)begin
                        if(idx==0)drive({32'(N),32'b0,1'b1,1'b1,1'b0,1'b1,T'(3)});
                        else s_valid=0;
                    end else if(target==19 && N==1 && idx==0)begin
                        drive({32'b0,32'b0,1'b0,1'b0,1'b1,1'b0,T'(7)});
                    end else if(target==19 && N==1 && idx==1)begin
                        drive({32'b0,32'b0,1'b0,1'b0,1'b0,1'b1,T'(7)});
                    end else if(idx<N*(N-1)/2)begin
                        a=0;b=1;
                        for(integer x=0;x<N;x=x+1)for(integer y=x+1;y<N;y=y+1)
                            if(idx==x*(2*N-x-1)/2+y-x-1)begin a=x;b=y;end
                        drive({32'(a),32'(b),1'b1,1'b1,(idx==0),1'b0,T'(7)});
                    end else if(idx==N*(N-1)/2)begin
                        drive({32'b0,32'b0,1'b0,1'b0,(idx==0),1'b1,T'(7)});
                    end else s_valid=0;
                    @(negedge clk);limit=limit+1;
                    if(limit>300000)$fatal(1,"unreachable reset target %0d",target);
                end
            end
            recovery();
        end
    endtask
    initial begin : run
        integer outputs,observed,hold_left,k,latency,step_limit;
        if(!$value$plusargs("MODE=%d",mode))mode=0;
        if(!$value$plusargs("INPUT=%s",input_path))$fatal(1,"INPUT");
        if(!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"OUTPUT");
        if(!$value$plusargs("TRACE=%s",trace_path))$fatal(1,"TRACE");
        out_file=$fopen(output_path,"w");trace_file=$fopen(trace_path,"w");
        $readmemh(input_path,words);
        repeat(3)@(negedge clk);rst=0;
        if(mode==0)begin
            phase=1;outputs=0;observed=0;hold_left=0;step_limit=0;
            while(outputs<FRAMES)begin
                if(retired>outputs)begin
                    outputs=retired;observed=0;
                    subsets=0;candidates=0;dp_reads=0;back_reads=0;
                end
                if(m_valid && !observed)begin
                    latency=cycle-tail_cycle;
                    $fdisplay(out_file,"R %0d %0d %h %0d %h %0d %0d %0d %0d %0d",outputs,m_error,m_tag,m_count,m_colors,latency,subsets,candidates,dp_reads,back_reads);
                    if(m_error==0)begin
                        for(k=0;k<N;k=k+1)$fdisplay(trace_file,"A %0d %0d %h",outputs,k,dut.adjacency[k]);
                        for(k=0;k<(1<<N);k=k+1)$fdisplay(trace_file,"D %0d %0d %h",outputs,k,dut.table_mem[k]);
                    end
                    observed=1;hold_left=3+outputs%3;
                end
                if(m_valid && observed && hold_left==0)m_ready=1;
                else begin m_ready=0;if(m_valid && hold_left>0)hold_left=hold_left-1;end
                if(accepted<BEATS)drive(words[accepted]);else s_valid=0;
                @(negedge clk);step_limit=step_limit+1;
                if(step_limit>5000000)$fatal(1,"finite main bound");
            end
            s_valid=0;m_ready=0;phase=0;
            if(accepted!=BEATS || retired!=FRAMES || blocked!=source_holds)$fatal(1,"counts/holding");
            $display("PASS exact_graph_coloring mode=main frames=%0d beats=%0d blocked=%0d source_holds=%0d queued=%0d held=%0d",FRAMES,BEATS,blocked,source_holds,queued,held);
        end else begin
            phase=2;
            for(k=0;k<22;k=k+1)probe(k);
            if(resets!=22 || fresh!=22)$fatal(1,"reset counts");
            $display("PASS exact_graph_coloring mode=reset resets=%0d fresh=%0d states=%h",resets,fresh,seen_states);
        end
        $fclose(out_file);$fclose(trace_file);$finish;
    end
    initial begin #100000000;$fatal(1,"watchdog");end
endmodule
