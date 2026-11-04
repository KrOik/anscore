// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_sparse_assembler;
    parameter integer N=64,D=8,T=8;
    localparam integer AW=N>1?$clog2(N):1,CW=$clog2(N+1),CWI=131+D+T,OW=9+T+AW+D+2*CW;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,m_ready=0;
    reg [2:0] c_op=0;reg [63:0] c_length=0,c_offset=0;reg [D-1:0] c_data=0;reg [T-1:0] c_tag=0;
    wire c_ready,m_valid,m_keep,m_first,m_last;wire [2:0] m_op,m_status;
    wire [T-1:0] m_tag;wire [AW-1:0] m_index;wire [D-1:0] m_data;wire [CW-1:0] m_total,m_filled;
    ram_sparse_assembler #(.DEPTH(N),.DATA_W(D),.TAG_W(T)) dut(.*);
    wire [CWI-1:0] command={c_op,c_length,c_offset,c_data,c_tag};
    wire [OW-1:0] payload={m_op,m_status,m_tag,m_keep,m_first,m_last,m_index,m_data,m_total,m_filled};
    reg [CWI-1:0] commands[0:30000],chold;reg [OW-1:0] mhold;
    reg cp=0,mp=0,main_phase=0,first_seen=0,gap_pending=0,cfire,mfire;
    reg [7:0] states=0;reg [N-1:0] h_owned=0;reg [D-1:0] h_data[0:N-1];
    string input_path,output_path;
    integer count,output_count,fd,ci=0,oi=0,fi=0,cycles=0,command_holds=0,output_holds=0;
    integer reads=0,writes=0,frame_reads=0,frame_writes=0,ref_cycle=0,max_latency=0;
    integer gap_ref=0,gap_reads=0,gap_checks=0,hold_age=0,guard=0,j,popcount;
    integer h_length=0,h_filled=0,probe,target,probe_words,resets=0,recovery=0;
    function [D-1:0] datum(input integer idx);datum=D'(idx*37+17);endfunction
    task tick;
        begin
            @(posedge clk);cfire=c_valid && c_ready;mfire=m_valid && m_ready;
            if(rst)begin cp=0;mp=0;end
            else begin
                cycles=cycles+1;states[dut.state]=1;
                if(cp)begin if(!c_valid || command!==chold)$fatal(1,"source hold");command_holds=command_holds+1;end
                if(mp)begin if(!m_valid || payload!==mhold)$fatal(1,"output hold");output_holds=output_holds+1;end
                cp=c_valid && !c_ready;chold=command;mp=m_valid && !m_ready;mhold=payload;
                popcount=0;for(j=0;j<N;j=j+1)if(dut.owned[j])popcount=popcount+1;
                if(dut.filled!==CW'(popcount) || dut.filled>dut.length || dut.length>N || (dut.owned>>dut.length)!=0)
                    $fatal(1,"ownership/count invariant");
                if(dut.state==2 || dut.state==5)begin
                    if(!dut.owned[dut.index] || dut.index>=dut.length)$fatal(1,"unowned RAM read");reads=reads+1;
                end
                if(dut.state==1)begin
                    if(dut.owned[dut.index] || dut.index>=dut.length)$fatal(1,"overwrite or invalid store");writes=writes+1;
                end
                if(main_phase)begin
                    if(cfire)begin ci=ci+1;ref_cycle=cycles;frame_reads=0;frame_writes=0;first_seen=0;end
                    if(dut.state==2 || dut.state==5)begin frame_reads=frame_reads+1;if(gap_pending)gap_reads=gap_reads+1;end
                    if(dut.state==1)frame_writes=frame_writes+1;
                    if(mfire)begin
                        $fwrite(fd,"O %h %0d %0d %h",payload,dut.length,dut.filled,dut.owned);
                        for(j=0;j<N;j=j+1)begin if(dut.owned[j])$fwrite(fd," %h",dut.words[j]);else $fwrite(fd," 0");end
                        $fwrite(fd,"\n");oi=oi+1;
                        if(m_keep && !m_last)begin gap_pending=1;gap_ref=cycles;gap_reads=0;end
                    end
                end
            end
            #1;@(negedge clk);
            if(main_phase && !rst && m_valid && !first_seen)begin
                first_seen=1;$fdisplay(fd,"F %0d %0d %0d %0d",fi,cycles-ref_cycle,frame_reads,frame_writes);fi=fi+1;
                if(cycles-ref_cycle>max_latency)max_latency=cycles-ref_cycle;
            end
            if(main_phase && !rst && m_valid && gap_pending)begin
                $fdisplay(fd,"G %0d %0d %0d",gap_checks,cycles-gap_ref,gap_reads);gap_checks=gap_checks+1;gap_pending=0;
            end
        end
    endtask
    task send(input [2:0] op,input [63:0] size,off,input [D-1:0] value);
        integer steps;
        begin
            c_op=op;c_length=size;c_offset=off;c_data=value;c_tag={T{1'b1}};c_valid=1;m_ready=0;
            steps=0;tick();while(!cfire)begin tick();steps=steps+1;if(steps>8)$fatal(1,"helper command bound");end
            c_valid=0;
        end
    endtask
    task wait_output;
        integer steps;
        begin steps=0;while(!m_valid)begin tick();steps=steps+1;if(steps>3)$fatal(1,"helper latency bound");end end
    endtask
    task image;
        integer idx;
        begin
            if(dut.length!==CW'(h_length) || dut.filled!==CW'(h_filled) || dut.owned!==h_owned)$fatal(1,"fresh complete metadata");
            for(idx=0;idx<N;idx=idx+1)if(h_owned[idx] && dut.words[idx]!==h_data[idx])$fatal(1,"fresh complete payload image");
        end
    endtask
    task retire;
        begin repeat(2)tick();m_ready=1;tick();if(!mfire)$fatal(1,"helper retirement");m_ready=0;end
    endtask
    task ack(input [2:0] op,input [63:0] size,off,input [D-1:0] value,input [2:0] status);
        begin
            send(op,size,off,value);wait_output();
            if(m_op!==op || m_status!==status || m_tag!=={T{1'b1}} || m_keep || !m_first || !m_last ||
                m_index!==0 || m_data!==0 || m_total!==CW'(h_length) || m_filled!==CW'(h_filled))$fatal(1,"fresh ACK fields");
            image();retire();
        end
    endtask
    task replay;
        integer idx,words;
        begin
            words=h_length;send(2,64'hffffffffffffffff,64'hffffffffffffffff,{D{1'b1}});
            for(idx=0;idx<words;idx=idx+1)begin
                wait_output();
                if(m_op!==2 || m_status!==0 || m_tag!=={T{1'b1}} || !m_keep || m_first!==(idx==0) ||
                    m_last!==(idx==words-1) || m_index!==AW'(idx) || m_data!==h_data[idx] ||
                    m_total!==CW'(words) || m_filled!==CW'(words))$fatal(1,"fresh complete ordered replay");
                image();retire();
            end
            h_length=0;h_filled=0;h_owned=0;image();
        end
    endtask
    task build(input integer words);
        integer idx;
        begin
            h_length=words;h_filled=0;h_owned=0;ack(0,words,0,0,0);
            for(idx=0;idx<words;idx=idx+1)begin
                h_data[idx]=datum(idx);h_owned[idx]=1;h_filled=h_filled+1;ack(1,0,idx,h_data[idx],0);
            end
        end
    endtask
    task fresh;
        integer words,idx;
        begin
            words=N<3?N:3;h_length=words;h_filled=0;h_owned=0;ack(0,words,0,0,0);ack(2,0,0,0,3);
            idx=words-1;h_data[idx]=datum(idx);h_owned[idx]=1;h_filled=1;ack(1,0,idx,h_data[idx],0);
            ack(1,0,idx,h_data[idx],1);ack(1,0,idx,h_data[idx]^D'(1),2);
            for(idx=words-2;idx>=0;idx=idx-1)begin
                h_data[idx]=datum(idx);h_owned[idx]=1;h_filled=h_filled+1;ack(1,0,idx,h_data[idx],0);
            end
            replay();ack(4,64'hffffffffffffffff,64'hffffffffffffffff,{D{1'b1}},0);
            h_length=1;h_filled=0;h_owned=0;ack(0,1,0,0,0);
            h_data[0]=D'(1);h_owned[0]=1;h_filled=1;ack(1,0,0,D'(1),0);replay();
            if(!c_ready || m_valid)$fatal(1,"fresh ownership end");recovery=recovery+words+9;
        end
    endtask
    task cancel_now;
        begin
            if(clk!==0)$fatal(1,"reset boundary");rst=1;c_valid=0;m_ready=0;#1;
            if(c_ready || m_valid || m_keep || m_first || m_last)$fatal(1,"reset public gates");tick();
            if(dut.state!==0 || dut.length!==0 || dut.filled!==0 || dut.owned!==0)$fatal(1,"reset ownership");
            h_length=0;h_filled=0;h_owned=0;rst=0;resets=resets+1;tick();
            if(!c_ready || m_valid)$fatal(1,"stale reset output");fresh();
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("OUTPUT=%s",output_path) ||
            !$value$plusargs("COUNT=%d",count) || !$value$plusargs("OUTS=%d",output_count))$fatal(1,"arguments");
        $readmemh(input_path,commands,0,count-1);fd=$fopen(output_path,"w");if(!fd)$fatal(1,"trace open");
        tick();rst=0;main_phase=1;
        while(oi<output_count)begin
            if(!c_valid && ci<count && cycles%7!=3){c_op,c_length,c_offset,c_data,c_tag,c_valid}={commands[ci],1'b1};
            if(m_valid)begin m_ready=hold_age>=3;hold_age=hold_age+1;end else begin m_ready=0;hold_age=0;end
            tick();if(cfire)c_valid=0;guard=guard+1;if(guard>500000)$fatal(1,"finite main bound");
        end
        if(ci!=count || cp)$fatal(1,"main acceptance total");main_phase=0;c_valid=0;m_ready=0;$fclose(fd);
        for(probe=0;probe<22;probe=probe+1)begin
            if(!c_ready)$fatal(1,"probe idle");target=0;probe_words=N<3?N:3;
            if(probe==1 || probe==7 || probe==10 || probe==12)begin
                h_length=1;h_filled=0;h_owned=0;ack(0,1,0,0,0);
            end
            if(probe>=2 && probe<=5 || probe==8 || probe==9)build(1);
            if(probe>=15)build(probe_words);
            case(probe)
                1:begin send(1,0,0,D'(1));target=1;end
                2,3,4,5:begin send(1,0,0,(probe==3 || probe==5)?h_data[0]^D'(1):h_data[0]);target=probe<4?2:3;end
                6:begin send(0,1,0,0);target=4;end
                7:begin send(1,0,0,D'(1));target=4;end
                8,9:begin send(1,0,0,probe==9?h_data[0]^D'(1):h_data[0]);target=4;end
                10:begin send(2,0,0,0);target=4;end
                11:begin send(2,0,0,0);target=4;end
                12:begin send(0,64'hffffffffffffffff,0,0);target=4;end
                13:begin send(0,0,0,0);target=4;end
                14:begin send(7,64'hffffffffffffffff,64'hffffffffffffffff,{D{1'b1}});target=4;end
                15,16,17,18,19,20,21:begin
                    send(2,0,0,0);target=probe==15 || probe==18?5:(probe==16 || probe==19?6:7);
                    if(probe>=18 && N>1)begin
                        wait_output();m_ready=1;tick();if(!mfire)$fatal(1,"probe first data retire");m_ready=0;
                    end
                    if(probe==21 && N>1)begin
                        wait_output();
                        while(m_index!=probe_words-1)begin m_ready=1;tick();m_ready=0;wait_output();end
                    end
                end
                default:target=0;
            endcase
            guard=0;while(dut.state!=target)begin tick();guard=guard+1;if(guard>3)$fatal(1,"reset target %0d",probe);end
            if(target==4 || target==7)begin
                // Actual next ABORT offered under a held ACK/data token.
                c_valid=1;c_op=3;c_length=64'hffffffffffffffff;c_offset=64'hffffffffffffffff;c_data={D{1'b1}};c_tag={T{1'b1}};
                repeat(3)tick();if(c_ready)$fatal(1,"queued reset command");
            end
            // Cancel at this observed boundary, before another active edge.
            cancel_now();
        end
        if(states!==8'hff || command_holds==0 || output_holds==0)$fatal(1,"state/hold coverage");
        $display("PASS sparse commands=%0d outputs=%0d first_checks=%0d cycles=%0d command_holds=%0d output_holds=%0d reads=%0d writes=%0d resets=%0d recovery=%0d max_latency=%0d states=%h",
            ci,oi,fi,cycles,command_holds,output_holds,reads,writes,resets,recovery,max_latency,states);
        $finish;
    end
endmodule
