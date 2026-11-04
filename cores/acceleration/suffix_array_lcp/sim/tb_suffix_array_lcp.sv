// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_suffix_array_lcp;
    parameter integer M=32,W=8,T=8,FRAMES=1,BEATS=1;
    localparam integer I=(M>1)?$clog2(M):1;
    localparam integer BOUND=4+4*M*(M-1)+2*M*(M*M-1)/3+6*(M-1);
    reg clk=0,rst=1,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    reg [W-1:0] s_symbol=0;
    reg s_keep=0,s_last=0,s_error=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_first,m_last;
    wire [31:0] m_suffix,m_lcp,m_rank,m_count;
    wire [1:0] m_error;
    wire [T-1:0] m_tag;
    suffix_array_lcp #(.MAX_SYMBOLS(M),.SYMBOL_W(W),.TAG_W(T)) dut(.*);
    reg [W+T+2:0] words[0:BEATS-1];
    wire [W+T+2:0] source_bundle={s_symbol,s_keep,s_last,s_error,s_tag};
    wire [T+132:0] result_bundle={m_suffix,m_lcp,m_rank,m_count,m_keep,m_first,m_last,m_error,m_tag};
    reg [W+T+2:0] old_source;
    reg [T+132:0] old_result;
    reg wait_source=0,wait_result=0;
    reg [W-1:0] sx[0:M-1],expected_symbol;
    reg [I-1:0] so[0:M-1],sl[0:M-1],expected_order,expected_lcp;
    integer xo[0:M-1],oo[0:M-1],lo[0:M-1],epoch=0;
    reg check_symbol=0,check_order=0,check_lcp=0;
    integer cycle=0,accepted=0,retired=0,loadframe=0,outframe=0;
    integer tails[0:FRAMES-1],first_seen=0,latency=0;
    integer comparisons=0,sort_pairs=0,sort_ends=0,shifts=0,lcp_pairs=0,lcp_ends=0;
    integer phase=0,source_holds=0,output_holds=0,queued=0,ram_checks=0;
    integer mode,file_out,actual_frames,actual_beats,targets=0,states=0,resets=0,fresh=0;
    reg [31:0] selected_targets;
    string input_path,output_path;
    always @(posedge clk)begin
        cycle=cycle+1;check_symbol=0;check_order=0;check_lcp=0;
        if(rst)begin wait_source=0;wait_result=0;end
        else begin
            states=states | (1<<dut.state);
            if(wait_source)begin
                if(!s_valid || source_bundle!==old_source)$fatal(1,"source holding");
                source_holds=source_holds+1;
            end
            if(wait_result)begin
                if(!m_valid || result_bundle!==old_result)$fatal(1,"output holding");
                output_holds=output_holds+1;
            end
            if(s_valid && s_ready)begin
                accepted=accepted+1;
                if(!dut.started)begin
                    epoch=epoch+1;
                    if(phase==1)begin
                        if(loadframe>0)begin if(!wait_source)$fatal(1,"next actual frame never queued");queued=queued+1;end
                        comparisons=0;sort_pairs=0;sort_ends=0;shifts=0;lcp_pairs=0;lcp_ends=0;
                    end
                end
                if(s_keep && dut.count<M)begin sx[dut.count]=s_symbol;xo[dut.count]=epoch;end
                if(phase==1 && s_last)begin tails[loadframe]=cycle;loadframe=loadframe+1;end
            end
            if(m_valid && m_ready)begin
                retired=retired+1;
                if(phase==1)begin
                    $fdisplay(file_out,"R %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",outframe,m_rank,m_suffix,m_lcp,m_count,m_keep,m_error,m_tag,latency,comparisons,sort_pairs,sort_ends,shifts,lcp_pairs,lcp_ends);
                    if(m_first!==(m_rank==0) || m_last!==(m_rank+1==m_count || !m_keep))$fatal(1,"result markers");
                    if(m_last)begin outframe=outframe+1;first_seen=0;end
                end
            end
            wait_source=s_valid && !s_ready;old_source=source_bundle;
            wait_result=m_valid && !m_ready;old_result=result_bundle;
            if(dut.count>M)$fatal(1,"capacity");
            if(dut.state==2)begin so[0]=0;sl[0]=0;oo[0]=epoch;lo[0]=epoch;end
            if(dut.state==3)begin
                if(dut.hole==0 || dut.hole>dut.insert_i || oo[dut.hole-1]!==epoch)$fatal(1,"insert order ownership");
                expected_order=so[dut.hole-1];check_order=1;
                if(phase==1)comparisons=comparisons+1;
            end
            if(dut.state==9)begin so[dut.hole]=dut.order_q;oo[dut.hole]=epoch;if(phase==1)shifts=shifts+1;end
            if(dut.state==10)begin so[dut.hole]=dut.insert_i;oo[dut.hole]=epoch;end
            if(dut.state==11)begin
                if(dut.rank_i==0 || oo[dut.rank_i-1]!==epoch)$fatal(1,"LCP previous ownership");
                expected_order=so[dut.rank_i-1];check_order=1;
            end
            if(dut.state==12)begin
                if(dut.rank_i>=dut.count || oo[dut.rank_i]!==epoch)$fatal(1,"LCP current ownership");
                expected_order=so[dut.rank_i];check_order=1;
            end
            if(dut.state>=5 && dut.state<=8)begin
                if(dut.left_address>dut.count || dut.right_address>dut.count || dut.left_base==dut.right_base)$fatal(1,"comparison bounds");
            end
            if(dut.state==5 && (dut.left_address==dut.count || dut.right_address==dut.count) && phase==1)begin
                if(dut.comparing_lcp)lcp_ends=lcp_ends+1;else sort_ends=sort_ends+1;
            end
            if(dut.state==6 || dut.state==7)begin
                if(dut.state==6)begin
                    if(dut.left_address>=dut.count || xo[dut.left_address]!==epoch)$fatal(1,"left symbol ownership");
                    expected_symbol=sx[dut.left_address];
                    if(phase==1)begin if(dut.comparing_lcp)lcp_pairs=lcp_pairs+1;else sort_pairs=sort_pairs+1;end
                end else begin
                    if(dut.right_address>=dut.count || xo[dut.right_address]!==epoch)$fatal(1,"right symbol ownership");
                    expected_symbol=sx[dut.right_address];
                end
                check_symbol=1;
            end
            if(dut.state==14)begin sl[dut.rank_i]=dut.offset;lo[dut.rank_i]=epoch;end
            if(dut.state==15)begin
                if(dut.out_rank>=dut.count || oo[dut.out_rank]!==epoch || lo[dut.out_rank]!==epoch)$fatal(1,"output bank ownership");
                expected_order=so[dut.out_rank];expected_lcp=sl[dut.out_rank];check_order=1;check_lcp=1;
            end
        end
    end
    always @(negedge clk)begin
        if(check_symbol)begin if(dut.symbol_q!==expected_symbol)$fatal(1,"synchronous symbol RAM");ram_checks=ram_checks+1;end
        if(check_order)begin if(dut.order_q!==expected_order)$fatal(1,"synchronous order RAM");ram_checks=ram_checks+1;end
        if(check_lcp)begin if(dut.lcp_q!==expected_lcp)$fatal(1,"synchronous LCP RAM");ram_checks=ram_checks+1;end
        if(!rst && phase==1 && m_valid && !first_seen)begin
            first_seen=1;latency=cycle-tails[outframe];
            if(m_keep)for(integer j=0;j<dut.count;j=j+1)
                if(xo[j]!==epoch || oo[j]!==epoch || lo[j]!==epoch)$fatal(1,"complete publication ownership");
        end
    end
    task tick;begin @(negedge clk);#1;end endtask
    task row(input [W+T+2:0] word);begin {s_symbol,s_keep,s_last,s_error,s_tag}=word;s_valid=1;end endtask
    task cancel;
        begin
            rst=1;#1;if(s_ready || m_valid || m_keep || m_first || m_last)$fatal(1,"reset gates");
            @(posedge clk);tick();s_valid=0;m_ready=0;rst=0;
        end
    endtask
    task recovery;
        integer bs,br,i,guard,tail_cycle;
        begin
            bs=accepted;br=retired;guard=0;
            while(accepted-bs<M)begin row({{W{1'b1}},1'b1,(accepted-bs==M-1),1'b0,T'(5)});tick();end
            s_valid=0;tail_cycle=cycle;
            while(!m_valid)begin tick();guard=guard+1;if(guard>BOUND+100)$fatal(1,"fresh latency guard");end
            if(cycle-tail_cycle!=BOUND)$fatal(1,"all-equal exact maximum latency %0d expected%0d",cycle-tail_cycle,BOUND);
            for(i=0;i<M;i=i+1)begin
                while(!m_valid)tick();
                if(!m_keep || m_error!==0 || m_tag!==T'(5) || m_suffix!==32'(M-1-i) || m_lcp!==32'(i) || m_rank!==32'(i) || m_count!==32'(M) || m_first!==(i==0) || m_last!==(i==M-1))$fatal(1,"full fresh suffix/LCP");
                repeat(2)tick();m_ready=1;tick();m_ready=0;
            end
            if(retired-br!=M || accepted-bs!=M)$fatal(1,"full fresh retirement");
            for(i=0;i<M;i=i+1)
                if(dut.symbols[i]!=={W{1'b1}} || dut.order[i]!==I'(M-1-i) || dut.lcps[i]!==I'(i))$fatal(1,"full fresh three banks");
            fresh=fresh+1;
        end
    endtask
    task probe(input integer target);
        integer bs,guard;
        reg matched;
        begin
            cancel();bs=accepted;guard=0;matched=0;
            while(!matched)begin
                m_ready=(target==23 && m_valid && !m_last);
                if(target<18)matched=dut.state==target;
                else if(target==18)matched=dut.state==0 && dut.count==1 && dut.started;
                else if(target==19)matched=dut.state==0 && dut.errors==1;
                else if(target==20)matched=m_valid && m_error==2;
                else if(target==21)matched=dut.state==5 && !dut.comparing_lcp && dut.offset!=0;
                else if(target==22)matched=dut.state==14 && dut.rank_i>1;
                else matched=m_valid && m_keep && m_last && m_rank>0;
                if(matched)begin
                    states=states | (1<<dut.state);targets=targets | (1<<target);
                    cancel();resets=resets+1;
                end else begin
                    if(target==20 && accepted==bs)row({W'(0),1'b0,1'b1,1'b1,T'(3)});
                    else if(target==20)s_valid=0;
                    else if(target==18 && accepted==bs)row({W'(0),1'b1,1'b0,1'b0,T'(3)});
                    else if(target==18)s_valid=0;
                    else if(target==19)row({W'(0),1'b1,1'b0,1'b0,T'(3)});
                    else if(dut.state==0)row({W'(0),1'b1,(dut.count==M-1),1'b0,T'(3)});
                    else s_valid=0;
                    tick();guard=guard+1;
                    if(guard>BOUND+20*M+200)$fatal(1,"unreached reset target %0d",target);
                end
            end
            recovery();
        end
    endtask
    initial begin
        if(!$value$plusargs("MODE=%d",mode))mode=0;
        if(!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"output path");
        file_out=$fopen(output_path,"w");if(!file_out)$fatal(1,"output open");
        repeat(2)tick();rst=0;
        if(mode==0)begin:main_run
            integer pos,guard,budget,previous_retired;
            if(!$value$plusargs("ACTUAL_FRAMES=%d",actual_frames) || !$value$plusargs("ACTUAL_BEATS=%d",actual_beats) || !$value$plusargs("INPUT=%s",input_path))$fatal(1,"input metadata");
            $readmemh(input_path,words,0,actual_beats-1);phase=1;row(words[0]);guard=0;budget=0;previous_retired=0;
            while(outframe<actual_frames)begin
                tick();pos=accepted;
                if(pos<actual_beats)row(words[pos]);else s_valid=0;
                if(retired!=previous_retired)begin budget=0;previous_retired=retired;end
                if(m_valid)begin if(budget<2)begin m_ready=0;budget=budget+1;end else m_ready=1;end
                else m_ready=0;
                guard=guard+1;if(guard>actual_frames*(BOUND+20*M+200))$fatal(1,"finite main guard");
            end
            if(accepted!=actual_beats || loadframe!=actual_frames || queued!=actual_frames-1 || source_holds==0 || output_holds==0)$fatal(1,"main accounting/hold");
            $display("PASS main frames=%0d outputs=%0d queued=%0d source_holds=%0d output_holds=%0d ram_checks=%0d states=%08x",outframe,retired,queued,source_holds,output_holds,ram_checks,states);
        end else begin
            if(!$value$plusargs("TARGET_MASK=%h",selected_targets))$fatal(1,"target mask");phase=2;
            for(integer j=0;j<24;j=j+1)if(selected_targets[j])probe(j);
            if(targets!==selected_targets || resets!=fresh)$fatal(1,"reset coverage");
            $display("PASS resets=%0d fresh=%0d targets=%08x states=%08x ram_checks=%0d",resets,fresh,targets,states,ram_checks);
        end
        $fclose(file_out);$finish;
    end
endmodule
