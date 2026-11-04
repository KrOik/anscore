// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_replay_window;
    parameter integer N=16,W=64,T=8;
    localparam integer CWI=99+T,OW=169+T+W;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,m_ready=0;
    reg [2:0] c_op=0;reg [31:0] c_context=0;reg [63:0] c_sequence=0;reg [T-1:0] c_tag=0;
    wire c_ready,m_valid,m_accepted,m_marked,m_active;
    wire [2:0] m_op,m_status;wire [31:0] m_context;wire [63:0] m_sequence,m_head;
    wire [T-1:0] m_tag;wire [W-1:0] m_seen;
    ram_replay_window #(.CONTEXTS(N),.WINDOW_BITS(W),.TAG_W(T)) dut(.*);
    wire [CWI-1:0] command={c_op,c_context,c_sequence,c_tag};
    wire [OW-1:0] payload={m_op,m_status,m_context,m_sequence,m_tag,m_accepted,m_marked,m_active,m_head,m_seen};
    reg [CWI-1:0] commands[0:30000],chold;reg [OW-1:0] mhold;
    reg cp=0,mp=0,main_phase=0,first_seen=0,cfire,mfire;
    reg [4:0] states=0;
    string input_path,output_path;
    integer count,fd,ci=0,oi=0,fi=0,cycles=0,command_holds=0,output_holds=0;
    integer reads=0,writes=0,frame_reads=0,frame_writes=0,ref_cycle=0,max_latency=0;
    integer hold_age=0,guard=0,j,probe,target,resets=0,recovery=0;
    task tick;
        begin
            @(posedge clk);cfire=c_valid && c_ready;mfire=m_valid && m_ready;
            if(rst)begin cp=0;mp=0;end
            else begin
                cycles=cycles+1;states[dut.state]=1;
                if(cp)begin if(!c_valid || command!==chold)$fatal(1,"source hold");command_holds=command_holds+1;end
                if(mp)begin if(!m_valid || payload!==mhold)$fatal(1,"result hold");output_holds=output_holds+1;end
                cp=c_valid && !c_ready;chold=command;mp=m_valid && !m_ready;mhold=payload;
                if(dut.state==1)reads=reads+1;
                if(dut.state==3)writes=writes+1;
                if(main_phase)begin
                    if(cfire)begin ci=ci+1;ref_cycle=cycles;frame_reads=0;frame_writes=0;first_seen=0;end
                    if(dut.state==1)frame_reads=frame_reads+1;
                    if(dut.state==3)frame_writes=frame_writes+1;
                    if(mfire)begin
                        $fwrite(fd,"O %h %h",payload,dut.live);
                        for(j=0;j<N;j=j+1)begin
                            if(dut.live[j])$fwrite(fd," %h",dut.rows[j]);else $fwrite(fd," 0");
                        end
                        $fwrite(fd,"\n");oi=oi+1;
                    end
                end
            end
            #1;@(negedge clk);
            if(main_phase && !rst && m_valid && !first_seen)begin
                first_seen=1;$fdisplay(fd,"F %0d %0d %0d %0d",fi,cycles-ref_cycle,frame_reads,frame_writes);fi=fi+1;
                if(cycles-ref_cycle>max_latency)max_latency=cycles-ref_cycle;
            end
        end
    endtask
    task send(input [2:0] op,input [31:0] ctx,input [63:0] seq);
        integer steps;
        begin
            c_op=op;c_context=ctx;c_sequence=seq;c_tag={T{1'b1}};c_valid=1;m_ready=0;
            steps=0;tick();while(!cfire)begin tick();steps=steps+1;if(steps>8)$fatal(1,"helper command bound");end
            c_valid=0;
        end
    endtask
    task wait_output;
        integer steps;
        begin steps=0;while(!m_valid)begin tick();steps=steps+1;if(steps>4)$fatal(1,"helper result bound");end end
    endtask
    task perform(input [2:0] op,input [63:0] seq,input [2:0] status,
                 input active,input [63:0] head,input [W-1:0] seen);
        begin
            send(op,0,seq);wait_output();
            if(m_op!==op || m_context!==0 || m_sequence!==seq || m_tag!=={T{1'b1}} ||
                m_status!==status || m_accepted!==((op<2)&&(status<3)) || m_marked!==((op==0)&&(status<3)) ||
                m_active!==active || m_head!==head || m_seen!==seen)$fatal(1,"fresh complete response");
            if(dut.live!==(active?N'(1):N'(0)))$fatal(1,"fresh context ownership");
            if(active && dut.rows[0]!=={head,seen})$fatal(1,"fresh row image");
            repeat(2)tick();m_ready=1;tick();if(!mfire)$fatal(1,"helper retire");m_ready=0;
        end
    endtask
    task fresh;
        reg [W-1:0] second,third;
        begin
            second=W>2?W'(5):W'(1);third=W>1?(second|W'(2)):W'(1);
            perform(0,0,0,1,0,W'(1));
            perform(0,2,1,1,2,second);
            perform(0,1,W>1?3'd2:3'd4,1,2,third);
            perform(1,2,3,1,2,third);
            perform(2,64'hffffffffffffffff,5,0,0,0);
            perform(1,0,0,0,0,0);
            if(!c_ready || m_valid)$fatal(1,"fresh ownership end");recovery=recovery+6;
        end
    endtask
    task cancel_now;
        begin
            if(clk!==0)$fatal(1,"reset boundary");rst=1;c_valid=0;m_ready=0;#1;
            if(c_ready || m_valid)$fatal(1,"reset gates");tick();
            if(dut.state!==0 || dut.live!==0)$fatal(1,"reset metadata");
            rst=0;resets=resets+1;tick();if(!c_ready || m_valid)$fatal(1,"stale reset output");fresh();
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("OUTPUT=%s",output_path) ||
            !$value$plusargs("COUNT=%d",count))$fatal(1,"arguments");
        $readmemh(input_path,commands,0,count-1);fd=$fopen(output_path,"w");if(!fd)$fatal(1,"trace open");
        tick();rst=0;main_phase=1;
        while(oi<count)begin
            if(!c_valid && ci<count && cycles%7!=3){c_op,c_context,c_sequence,c_tag,c_valid}={commands[ci],1'b1};
            if(m_valid)begin m_ready=hold_age>=3;hold_age=hold_age+1;end else begin m_ready=0;hold_age=0;end
            tick();if(cfire)c_valid=0;guard=guard+1;if(guard>500000)$fatal(1,"finite main bound");
        end
        if(ci!=count || cp)$fatal(1,"main acceptance total");main_phase=0;c_valid=0;m_ready=0;$fclose(fd);
        for(probe=0;probe<16;probe=probe+1)begin
            if(!c_ready)$fatal(1,"probe idle");target=0;
            if(probe>=4 && probe<=7 || probe>=9 && probe<=12)
                perform(0,probe==12?W+10:10,0,1,probe==12?W+10:10,W'(1));
            case(probe)
                1:begin send(0,0,10);target=1;end
                2:begin send(1,0,10);target=2;end
                3:begin send(0,0,10);target=3;end
                4:begin send(0,0,11);target=1;end
                5:begin send(1,0,10);target=2;end
                6:begin send(0,0,10+W);target=3;end
                7:begin send(0,0,W>1?9:11);target=3;end
                8:begin send(0,0,10);target=4;end
                9:begin send(0,0,11);target=4;end
                10:begin send(0,0,9);target=4;end
                11:begin send(0,0,10);target=4;end
                12:begin send(0,0,10);target=4;end
                13:begin send(3,32'hffffffff,64'hffffffffffffffff);target=4;end
                14:begin send(0,32'hffffffff,0);target=4;end
                15:begin send(7,32'hffffffff,64'hffffffffffffffff);target=4;end
                default:target=0;
            endcase
            guard=0;while(dut.state!=target)begin tick();guard=guard+1;if(guard>4)$fatal(1,"reset probe target");end
            if(probe>=8)begin
                // A real future PEEK is held; reset then cancels this obligation.
                c_valid=1;c_op=1;c_context=0;c_sequence=0;c_tag={T{1'b1}};
                repeat(3)tick();if(c_ready)$fatal(1,"queued reset source");
            end
            // Reset at the current observed boundary, before another active edge.
            cancel_now();
        end
        if(states!==5'h1f || command_holds==0 || output_holds==0)$fatal(1,"state/hold coverage");
        $display("PASS replay commands=%0d outputs=%0d first_checks=%0d cycles=%0d command_holds=%0d output_holds=%0d reads=%0d writes=%0d resets=%0d recovery=%0d max_latency=%0d states=%h",
            ci,oi,fi,cycles,command_holds,output_holds,reads,writes,resets,recovery,max_latency,states);
        $finish;
    end
endmodule
