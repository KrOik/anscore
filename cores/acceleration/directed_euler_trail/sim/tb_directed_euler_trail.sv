// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_directed_euler_trail;
    parameter integer N=8,M=32,T=8,FRAMES=1,BEATS=1;
    localparam integer V=(N>1)?$clog2(N):1,E=(M>1)?$clog2(M):1;
    reg clk=0,rst=1,c_valid=0,s_valid=0,m_ready=0;
    always #5 clk=~clk;
    reg [31:0] c_start=0,s_from=0,s_to=0;
    reg [T-1:0] c_tag=0;
    reg s_keep=0,s_last=0;
    wire c_ready,s_ready,m_valid,m_has_edge,m_keep,m_last;
    wire [31:0] m_node,m_in_edge,m_step,m_edges;
    wire [3:0] m_error;
    wire [T-1:0] m_tag;
    directed_euler_trail #(.NUM_NODES(N),.MAX_EDGES(M),.TAG_W(T)) dut(.*);
    reg [31+T:0] commands[0:FRAMES-1];
    reg [65:0] words[0:BEATS-1];
    wire [31+T:0] command_bundle={c_start,c_tag};
    wire [65:0] source_bundle={s_from,s_to,s_keep,s_last};
    wire [T+134:0] result_bundle={m_node,m_in_edge,m_step,m_edges,m_has_edge,m_keep,m_last,m_error,m_tag};
    reg [31+T:0] old_c;
    reg [65:0] old_s;
    reg [T+134:0] old_m;
    reg wait_c=0,wait_s=0,wait_m=0,check_edge=0,check_stack=0,check_route=0;
    reg [2*V-1:0] want_edge;
    reg [V+E-1:0] want_stack,want_route;
    integer cycle=0,accepted_c=0,accepted_s=0,retired=0,loadframes=0,outframe=0;
    integer tail[0:FRAMES-1];
    integer phase=0,reads=0,first_latency=0,first_reads=0,first_seen=0;
    integer holds_c=0,holds_s=0,holds_m=0,queued_c=0,queued_s=0,ram_checks=0;
    integer mode,file_out,states=0,targets=0,resets=0,fresh=0;
    string command_path,input_path,output_path;
    always @(posedge clk)begin
        cycle=cycle+1;
        check_edge=0;check_stack=0;check_route=0;
        if(rst)begin wait_c=0;wait_s=0;wait_m=0;end
        else begin
            states=states | (1<<dut.state);
            if(wait_c)begin
                if(!c_valid || command_bundle!==old_c)$fatal(1,"command hold");
                holds_c=holds_c+1;
            end
            if(wait_s)begin
                if(!s_valid || source_bundle!==old_s)$fatal(1,"source hold");
                holds_s=holds_s+1;
            end
            if(wait_m)begin
                if(!m_valid || result_bundle!==old_m)$fatal(1,"output hold");
                holds_m=holds_m+1;
            end
            if(c_valid && c_ready)begin
                accepted_c=accepted_c+1;reads=0;
                if(wait_c)queued_c=queued_c+1;
            end
            if(s_valid && s_ready)begin
                accepted_s=accepted_s+1;
                if(wait_s)queued_s=queued_s+1;
                if(phase==1 && s_last)begin tail[loadframes]=cycle;loadframes=loadframes+1;end
            end
            if(m_valid && m_ready)begin
                retired=retired+1;
                if(phase==1)begin
                    $fdisplay(file_out,"R %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",outframe,m_step,m_node,m_in_edge,m_has_edge,m_last,m_keep,m_error,m_tag,m_edges,first_latency,first_reads);
                    if(m_last)begin outframe=outframe+1;first_seen=0;end
                end
            end
            wait_c=c_valid && !c_ready;old_c=command_bundle;
            wait_s=s_valid && !s_ready;old_s=source_bundle;
            wait_m=m_valid && !m_ready;old_m=result_bundle;
            if(dut.state==3)begin check_edge=1;want_edge=dut.edges[dut.scan];reads=reads+1;end
            if(dut.state==12)begin check_edge=1;want_edge=dut.edges[dut.verify_edge];end
            if(dut.state==7)begin check_stack=1;want_stack=dut.stack[dut.sp];end
            if(dut.state==10)begin check_route=1;want_route=dut.route[dut.verify_index];end
            if(dut.state==14)begin check_route=1;want_route=dut.route[dut.out_index];end
            if(dut.sp>M || dut.edge_count>M || dut.route_count>M+1)$fatal(1,"bounds");
            // Used-count belongs to this graph only after INIT, not while LOAD drains.
            if(dut.state>=3 && dut.state<=15 && dut.used_count>dut.edge_count)$fatal(1,"used-count bounds");
        end
    end
    always @(negedge clk)begin
        if(check_edge)begin if(dut.edge_q!==want_edge)$fatal(1,"sync edge RAM");ram_checks=ram_checks+1;end
        if(check_stack)begin if(dut.stack_q!==want_stack)$fatal(1,"sync stack RAM");ram_checks=ram_checks+1;end
        if(check_route)begin if(dut.route_q!==want_route)$fatal(1,"sync route RAM");ram_checks=ram_checks+1;end
        if(!rst && phase==1 && m_valid && !first_seen)begin
            first_seen=1;first_latency=cycle-tail[outframe];first_reads=reads;
        end
    end
    task tick;begin @(negedge clk);#1;end endtask
    task command(input [31+T:0] word);begin {c_start,c_tag}=word;c_valid=1;end endtask
    task row(input [65:0] word);begin {s_from,s_to,s_keep,s_last}=word;s_valid=1;end endtask
    task cancel;
        begin
            rst=1;#1;if(c_ready || s_ready || m_valid)$fatal(1,"reset gates");
            @(posedge clk);tick();c_valid=0;s_valid=0;m_ready=0;rst=0;
        end
    endtask
    task recovery;
        integer bc,bs,br,i,guard;
        begin
            bc=accepted_c;bs=accepted_s;br=retired;guard=0;
            command({32'd0,T'(5)});
            while(accepted_c==bc)tick();c_valid=0;
            while(accepted_s-bs<M)begin
                row({32'd0,32'd0,1'b1,(accepted_s-bs==M-1)});tick();
            end
            s_valid=0;
            for(i=0;i<=M;i=i+1)begin
                while(!m_valid)begin tick();guard=guard+1;if(guard>4*M*M+16*M+200)$fatal(1,"fresh timeout");end
                if(m_error!==0 || !m_keep || m_node!==0 || m_step!==32'(i) || m_edges!==32'(M) ||
                    m_has_edge!==(i!=0) || m_in_edge!==32'((i==0)?0:i-1) || m_last!==(i==M) || m_tag!==T'(5))$fatal(1,"full fresh trail");
                repeat(2)tick();m_ready=1;tick();m_ready=0;
            end
            if(retired-br!=M+1 || accepted_s-bs!=M)$fatal(1,"fresh complete retirement");
            for(i=0;i<M;i=i+1)begin
                if(dut.edges[i]!==0 || dut.stack[i]!==((i==0)?(V+E)'(0):(V+E)'(i-1)))$fatal(1,"fresh complete edge/stack banks");
            end
            for(i=0;i<=M;i=i+1)
                if(dut.route[i]!==((i==M)?(V+E)'(0):(V+E)'(M-1-i)))$fatal(1,"fresh complete route bank");
            fresh=fresh+1;
        end
    endtask
    task probe(input integer target);
        integer bc,bs,guard;
        reg matched;
        begin
            cancel();bc=accepted_c;bs=accepted_s;guard=0;matched=0;
            while(!matched)begin
                if(target<17)matched=dut.state==target && (target!=16 || m_last);
                else if(target==17)matched=dut.state==1 && accepted_s>bs && dut.edge_count==M/2;
                else if(target==18)matched=dut.sp==M;
                else if(target==19)matched=m_valid && m_error==1;
                else matched=dut.state==1 && dut.input_error==4;
                if(matched)begin
                    states=states | (1<<dut.state);targets=targets | (1<<target);
                    cancel();resets=resets+1;
                end else begin
                    if(accepted_c==bc)command({32'((target==19)?N:0),T'(3)});else c_valid=0;
                    if(accepted_c>bc)begin
                        if(target==19)begin
                            if(accepted_s==bs)row({32'd0,32'd0,1'b0,1'b1});else s_valid=0;
                        end else if(target==20)row({32'd0,32'd0,1'b1,1'b0});
                        else if(target==17 && accepted_s==bs)row({32'd0,32'd0,1'b0,1'b0});
                        else if(dut.state==1)row({32'd0,32'd0,1'b1,(dut.edge_count==M-1)});
                        else s_valid=0;
                    end
                    m_ready=(target==16 && m_valid && !m_last);
                    tick();guard=guard+1;
                    if(guard>4*M*M+16*M+200)$fatal(1,"unreached reset target %0d",target);
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
            integer ci,si,guard,stall_phase,stall_budget,previous_retired;
            if(!$value$plusargs("COMMANDS=%s",command_path) || !$value$plusargs("INPUT=%s",input_path))$fatal(1,"fixture paths");
            $readmemh(command_path,commands);$readmemh(input_path,words);
            phase=1;ci=0;si=0;guard=0;stall_phase=0;stall_budget=0;previous_retired=0;
            command(commands[0]);row(words[0]);
            while(outframe<FRAMES)begin
                tick();ci=accepted_c;si=accepted_s;
                if(ci<FRAMES)command(commands[ci]);else c_valid=0;
                if(si<BEATS)row(words[si]);else s_valid=0;
                // Every output is held for two complete edges; acceptance then allows prefetch.
                if(retired!=previous_retired)begin stall_budget=0;previous_retired=retired;end
                if(m_valid)begin
                    if(stall_budget<2)begin m_ready=0;stall_budget=stall_budget+1;end
                    else m_ready=1;
                end else m_ready=0;
                guard=guard+1;if(guard>15000000)$fatal(1,"finite main guard");
            end
            if(accepted_c!=FRAMES || accepted_s!=BEATS || loadframes!=FRAMES)$fatal(1,"full input accounting");
            if(holds_s==0 || holds_m==0 || (FRAMES>1 && queued_c!=FRAMES-1))$fatal(1,"real queued/held coverage");
            $display("PASS main frames=%0d records=%0d holds_c=%0d holds_s=%0d holds_m=%0d queued_c=%0d queued_s=%0d ram_checks=%0d states=%08x",outframe,retired,holds_c,holds_s,holds_m,queued_c,queued_s,ram_checks,states);
        end else begin
            phase=2;
            for(integer j=0;j<21;j=j+1)probe(j);
            if(resets!=21 || fresh!=21 || targets!=21'h1fffff || (states & 17'h1ffff)!=17'h1ffff)$fatal(1,"reset coverage");
            $display("PASS resets=%0d fresh=%0d targets=%08x states=%08x ram_checks=%0d",resets,fresh,targets,states,ram_checks);
        end
        $fclose(file_out);$finish;
    end
endmodule
