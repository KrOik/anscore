// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_sg_range_map;
    parameter integer N=16,A=32,L=16,T=8;
    localparam integer IW=N>1?$clog2(N):1,CW=$clog2(N+1),TW=L+(N>1?$clog2(N):0);
    localparam integer CWI=130+T,EWI=A+L+3,OW=11+T+A+L+2*TW+IW+CW;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,e_valid=0,m_ready=0;
    reg [1:0] c_op=0;reg [63:0] c_offset=0,c_bytes=0;reg [T-1:0] c_tag=0;
    reg e_keep=0,e_first=0,e_last=0;reg [A-1:0] e_base=0;reg [L-1:0] e_bytes=0;
    wire c_ready,e_ready,m_valid,m_keep,m_first,m_last;
    wire [1:0] m_op;wire [2:0] m_status,m_load_errors;wire [T-1:0] m_tag;
    wire [A-1:0] m_addr;wire [L-1:0] m_bytes;wire [TW-1:0] m_offset,m_total;
    wire [IW-1:0] m_segment;wire [CW-1:0] m_segments;
    ram_sg_range_map #(.MAX_SEGS(N),.ADDR_W(A),.LEN_W(L),.TAG_W(T)) dut(.*);
    wire [CWI-1:0] command={c_op,c_offset,c_bytes,c_tag};
    wire [EWI-1:0] entry={e_base,e_bytes,e_keep,e_first,e_last};
    wire [OW-1:0] payload={m_op,m_status,m_load_errors,m_keep,m_first,m_last,m_tag,m_addr,m_bytes,m_offset,m_total,m_segment,m_segments};
    reg [CWI-1:0] commands[0:30000],chold;reg [EWI-1:0] entries[0:30000],ehold;
    reg [OW-1:0] mhold;reg cp=0,ep=0,mp=0,main_phase=0,first_seen=0,gap_pending=0;
    reg cfire,efire,mfire;reg [6:0] states=0;
    string command_path,entry_path,output_path;
    integer command_total,entry_total,output_total,fd,ci=0,ei=0,oi=0,fi=0;
    integer cycles=0,command_holds=0,entry_holds=0,output_holds=0,reads=0,writes=0;
    integer ref_cycle=0,frame_reads=0,max_latency=0,hold_age=0,guard=0,j,probe,target,target_index;
    integer gap_ref=0,gap_checks=0;
    integer resets=0,recovery=0,length,total,k;
    task tick;
        begin
            @(posedge clk);cfire=c_valid && c_ready;efire=e_valid && e_ready;mfire=m_valid && m_ready;
            if(rst)begin cp=0;ep=0;mp=0;end
            else begin
                cycles=cycles+1;states[dut.state]=1;
                if(cp)begin if(!c_valid || command!==chold)$fatal(1,"command source hold");command_holds=command_holds+1;end
                if(ep)begin if(!e_valid || entry!==ehold)$fatal(1,"entry source hold");entry_holds=entry_holds+1;end
                if(mp)begin if(!m_valid || payload!==mhold)$fatal(1,"output hold");output_holds=output_holds+1;end
                cp=c_valid && !c_ready;chold=command;ep=e_valid && !e_ready;ehold=entry;
                mp=m_valid && !m_ready;mhold=payload;
                if(dut.state==3)reads=reads+1;
                if(efire && e_keep && dut.shadow_count<N)begin
                    writes=writes+1;
                    if((dut.write_address/N)==dut.bank)$fatal(1,"write to active bank");
                end
                if(main_phase)begin
                    if(cfire)begin ci=ci+1;ref_cycle=cycles;frame_reads=0;first_seen=0;end
                    if(efire)begin ei=ei+1;if(e_last)ref_cycle=cycles;end
                    if(dut.state==3)frame_reads=frame_reads+1;
                    if(mfire)begin
                        $fwrite(fd,"O %h",payload);
                        for(j=0;j<N;j=j+1)if(j<dut.active_count)$fwrite(fd," %h",dut.rows[dut.bank*N+j]);
                        $fwrite(fd,"\n");oi=oi+1;
                        if(m_keep && !m_last)begin gap_ref=cycles;gap_pending=1;end
                    end
                end
            end
            #1;@(negedge clk);
            if(main_phase && !rst && m_valid && !first_seen)begin
                first_seen=1;$fdisplay(fd,"F %0d %0d %0d",fi,cycles-ref_cycle,frame_reads);fi=fi+1;
                if(cycles-ref_cycle>max_latency)max_latency=cycles-ref_cycle;
            end
            if(main_phase && !rst && m_valid && gap_pending)begin
                $fdisplay(fd,"G %0d %0d",gap_checks,cycles-gap_ref);gap_checks=gap_checks+1;gap_pending=0;
            end
        end
    endtask
    task cmd(input [1:0] op,input [63:0] offset,bytes);
        integer steps;
        begin
            c_op=op;c_offset=offset;c_bytes=bytes;c_tag={T{1'b1}};c_valid=1;m_ready=0;
            steps=0;tick();while(!cfire)begin tick();steps=steps+1;if(steps>2*N+5)$fatal(1,"helper command bound");end
            c_valid=0;
        end
    endtask
    task ent(input [A-1:0] base,input [L-1:0] bytes,input keep,first,last);
        integer steps;
        begin
            e_base=base;e_bytes=bytes;e_keep=keep;e_first=first;e_last=last;e_valid=1;
            steps=0;tick();while(!efire)begin tick();steps=steps+1;if(steps>2*N+5)$fatal(1,"helper entry bound");end
            e_valid=0;
        end
    endtask
    task wait_output;
        integer steps;
        begin
            steps=0;while(!m_valid)begin tick();steps=steps+1;if(steps>2*N+5)$fatal(1,"helper latency bound");end
        end
    endtask
    task retire;
        begin repeat(2)tick();m_ready=1;tick();if(!mfire)$fatal(1,"helper retire");m_ready=0;end
    endtask
    task map_image;
        integer idx;
        reg [A-1:0] base;reg [L-1:0] bytes;
        begin
            if(dut.active_count!==CW'(length) || dut.active_total!==TW'(total))$fatal(1,"fresh map metadata");
            for(idx=0;idx<length;idx=idx+1)begin
                base=idx==length-1 && idx!=0?{A{1'b0}}:{A{1'b1}};
                bytes=(length==3 && idx==1)?L'(0):L'(1);
                if(dut.rows[dut.bank*N+idx]!=={base,bytes})$fatal(1,"fresh active map image");
            end
        end
    endtask
    task ack(input [1:0] op,input [2:0] status,errors);
        begin
            wait_output();
            if(m_op!==op || m_status!==status || m_load_errors!==errors || m_keep || !m_first || !m_last ||
                m_tag!=={T{1'b1}} || m_addr!==0 || m_bytes!==0 || m_offset!==0 || m_segment!==0 ||
                m_total!==TW'(total) || m_segments!==CW'(length))$fatal(1,"helper ACK fields");
            map_image();retire();
        end
    endtask
    task full_query;
        integer index,chunks,segment;
        reg [A-1:0] address;
        begin
            cmd(1,0,total);chunks=N==1?1:2;
            for(index=0;index<chunks;index=index+1)begin
                wait_output();segment=index==0?0:length-1;address=index==0?{A{1'b1}}:{A{1'b0}};
                if(m_op!==1 || m_status!==0 || m_load_errors!==0 || !m_keep || m_first!==(index==0) ||
                    m_last!==(index==chunks-1) || m_tag!=={T{1'b1}} || m_addr!==address || m_bytes!==L'(1) ||
                    m_offset!==TW'(index) || m_segment!==IW'(segment) || m_total!==TW'(total) ||
                    m_segments!==CW'(length))$fatal(1,"fresh spanning query");
                map_image();retire();
            end
        end
    endtask
    task fresh;
        integer index;
        begin
            length=N<3?N:3;total=N==1?1:2;
            cmd(0,64'hffffffffffffffff,64'hffffffffffffffff);
            for(index=0;index<length;index=index+1)
                ent(index==length-1 && index!=0?{A{1'b0}}:{A{1'b1}},
                    length==3 && index==1?L'(0):L'(1),1,index==0,index==length-1);
            ack(0,0,0);full_query();
            cmd(0,0,0);ent(0,1,1,0,1);ack(0,4,2);full_query();
            if(!c_ready || e_ready || m_valid)$fatal(1,"fresh ownership end");
            recovery=recovery+4;
        end
    endtask
    task cancel_now;
        begin
            if(clk!==0)$fatal(1,"reset observation boundary");
            rst=1;c_valid=0;e_valid=0;m_ready=0;#1;
            if(c_ready || e_ready || m_valid)$fatal(1,"reset gates");
            tick();
            if(dut.state!==0 || dut.active_count!==0 || dut.active_total!==0 || dut.bank!==0)$fatal(1,"reset map ownership");
            rst=0;resets=resets+1;tick();
            if(!c_ready || e_ready || m_valid)$fatal(1,"stale output after reset");
            fresh();
        end
    endtask
    initial begin
        if(!$value$plusargs("COMMANDS=%s",command_path) || !$value$plusargs("ENTRIES=%s",entry_path) ||
            !$value$plusargs("OUTPUT=%s",output_path) || !$value$plusargs("CMDS=%d",command_total) ||
            !$value$plusargs("ENTS=%d",entry_total) || !$value$plusargs("OUTS=%d",output_total))$fatal(1,"arguments");
        $readmemh(command_path,commands,0,command_total-1);$readmemh(entry_path,entries,0,entry_total-1);
        fd=$fopen(output_path,"w");if(!fd)$fatal(1,"trace open");tick();rst=0;main_phase=1;
        while(oi<output_total)begin
            if(!c_valid && ci<command_total && cycles%7!=3){c_op,c_offset,c_bytes,c_tag,c_valid}={commands[ci],1'b1};
            if(!e_valid && ei<entry_total && cycles%5!=2){e_base,e_bytes,e_keep,e_first,e_last,e_valid}={entries[ei],1'b1};
            if(m_valid)begin m_ready=hold_age>=3;hold_age=hold_age+1;end
            else begin m_ready=0;hold_age=0;end
            tick();if(cfire)c_valid=0;if(efire)e_valid=0;
            guard=guard+1;if(guard>3000000)$fatal(1,"finite main bound");
        end
        if(ci!=command_total || ei!=entry_total || cp || ep)$fatal(1,"main acceptance totals");
        main_phase=0;c_valid=0;e_valid=0;m_ready=0;$fclose(fd);
        for(probe=0;probe<16;probe=probe+1)begin
            if(!c_ready)$fatal(1,"probe idle");
            target=0;target_index=-1;
            if(probe==1)begin cmd(0,0,0);target=1;end
            else if(probe==2)begin cmd(0,0,0);ent(0,1,1,1,0);target=1;end
            else if(probe==3 || probe==4)begin cmd(0,0,0);ent(0,1,1,probe==3,1);target=2;end
            else if(probe>=5 && probe<=10)begin
                cmd(1,(probe==7 || probe==8)?total-1:0,(probe==9 || probe==10)?total:1);
                target=(probe==5 || probe==7)?3:((probe==6 || probe==8)?4:5);
                if(probe==7 || probe==8)target_index=length-1;
            end else if(probe==11 || probe==12)begin
                cmd(0,0,0);ent(0,1,1,probe==11,1);target=6;
            end else if(probe==13)begin cmd(1,64'hffffffffffffffff,0);target=6;end
            else if(probe==14)begin cmd(1,64'hffffffffffffffff,1);target=6;end
            else if(probe==15)begin cmd(3,64'hffffffffffffffff,64'hffffffffffffffff);target=6;end
            guard=0;
            while(dut.state!=target || (target_index>=0 && dut.scan_index!=target_index))begin
                tick();guard=guard+1;if(guard>2*N+5)$fatal(1,"probe target %0d",probe);
            end
            if(probe==10 && N>1)begin m_ready=1;tick();m_ready=0;wait_output();end
            if(probe>=9)begin
                c_op=0;c_offset=0;c_bytes=0;c_tag={T{1'b1}};c_valid=1;
                e_base=0;e_bytes=1;e_keep=1;e_first=1;e_last=1;e_valid=1;
                repeat(3)tick();if(c_ready || e_ready)$fatal(1,"queued probe sources");
            end
            cancel_now();
        end
        if(states!==7'h7f || command_holds==0 || entry_holds==0 || output_holds==0)$fatal(1,"state/hold coverage");
        $display("PASS sgmap commands=%0d entries=%0d outputs=%0d first_checks=%0d cycles=%0d command_holds=%0d entry_holds=%0d output_holds=%0d reads=%0d writes=%0d resets=%0d recovery=%0d max_latency=%0d states=%h",
            ci,ei,oi,fi,cycles,command_holds,entry_holds,output_holds,reads,writes,resets,recovery,max_latency,states);
        $finish;
    end
endmodule
