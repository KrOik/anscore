// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_region_guard;
    parameter integer A=32,S=16,T=8;
    localparam integer IW=S>1?$clog2(S):1,CW=$clog2(S+1),RW=2*A+3,CWI=170+T,OW=45+T+2*A+CW;
    localparam [64:0] SPACE=65'd1<<A;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,m_ready=0;
    reg [2:0] c_op=0,c_perm=0,c_access=0;
    reg [31:0] c_slot=0;reg [63:0] c_base=0;reg [64:0] c_bytes=0;reg [T-1:0] c_tag=0;
    wire c_ready,m_valid,m_allow,m_found;wire [2:0] m_op,m_perm;wire [3:0] m_status;
    wire [T-1:0] m_tag;wire [31:0] m_slot;wire [A-1:0] m_base;wire [A:0] m_bytes;wire [CW-1:0] m_count;
    ram_region_guard #(.ADDR_W(A),.SLOTS(S),.TAG_W(T)) dut(.*);
    wire [CWI-1:0] command={c_op,c_slot,c_base,c_bytes,c_perm,c_access,c_tag};
    wire [OW-1:0] payload={m_op,m_status,m_tag,m_allow,m_found,m_slot,m_base,m_bytes,m_perm,m_count};
    reg [CWI-1:0] commands[0:30000],chold;
    reg [OW-1:0] mhold;
    reg cp=0,mp=0,cfire,mfire,main_phase=0,first_seen=0,read_check=0,recovery_phase=0;
    reg [RW-1:0] expected_q;
    reg [4:0] states=0;
    reg [S-1:0] h_live=0;
    reg [63:0] h_base[0:S-1];reg [64:0] h_bytes[0:S-1];reg [2:0] h_perm[0:S-1];
    string input_path,output_path;
    integer count,fd,ci=0,oi=0,fi=0,cycles=0,command_holds=0,output_holds=0;
    integer reads=0,writes=0,frame_reads=0,frame_writes=0,ref_cycle=0,max_latency=0;
    integer hold_age=0,guard=0,j,popcount,h_count=0,probe,target,want_index,resets=0,recovery=0;
    task tick;
        begin
            @(posedge clk);cfire=c_valid && c_ready;mfire=m_valid && m_ready;read_check=0;
            if(rst)begin cp=0;mp=0;end
            else begin
                cycles=cycles+1;states[dut.state]=1;
                if(cp)begin if(!c_valid || command!==chold)$fatal(1,"source hold");command_holds=command_holds+1;end
                if(mp)begin if(!m_valid || payload!==mhold)$fatal(1,"output hold");output_holds=output_holds+1;end
                cp=c_valid && !c_ready;chold=command;mp=m_valid && !m_ready;mhold=payload;
                popcount=0;for(j=0;j<S;j=j+1)if(dut.live[j])popcount=popcount+1;
                if(dut.count!==CW'(popcount) || dut.count>S)$fatal(1,"live count invariant");
                if((dut.state==1 || dut.state==2 || dut.state==3) && dut.index>=S)$fatal(1,"RAM index bounds");
                if(dut.state==1 && dut.live[dut.index])begin
                    reads=reads+1;read_check=1;expected_q=dut.rules[dut.index];
                end
                if(dut.state==1 && dut.m_op==3 && !dut.live[dut.index])$fatal(1,"GET unowned read");
                if(dut.state==3)begin
                    if(dut.out_base>dut.out_last)$fatal(1,"malformed rule write");writes=writes+1;
                end
                if(main_phase)begin
                    if(cfire)begin ci=ci+1;ref_cycle=cycles;frame_reads=0;frame_writes=0;first_seen=0;end
                    if(dut.state==1 && dut.live[dut.index])frame_reads=frame_reads+1;
                    if(dut.state==3)frame_writes=frame_writes+1;
                    if(mfire)begin
                        $fwrite(fd,"O %h %0d %h",payload,dut.count,dut.live);
                        for(j=0;j<S;j=j+1)begin if(dut.live[j])$fwrite(fd," %h",dut.rules[j]);else $fwrite(fd," 0");end
                        $fwrite(fd,"\n");oi=oi+1;
                    end
                end
            end
            #1;if(read_check && dut.row_q!==expected_q)$fatal(1,"synchronous owned RAM read");@(negedge clk);
            if(main_phase && !rst && m_valid && !first_seen)begin
                first_seen=1;$fdisplay(fd,"F %0d %0d %0d %0d",fi,cycles-ref_cycle,frame_reads,frame_writes);fi=fi+1;
                if(cycles-ref_cycle>max_latency)max_latency=cycles-ref_cycle;
            end
        end
    endtask
    task send(input [2:0] op,input [31:0] slot,input [63:0] base,input [64:0] bytes,input [2:0] perm,access);
        integer steps;
        begin
            c_op=op;c_slot=slot;c_base=base;c_bytes=bytes;c_perm=perm;c_access=access;c_tag={T{1'b1}};c_valid=1;m_ready=0;
            steps=0;tick();while(!cfire)begin tick();steps=steps+1;if(steps>4)$fatal(1,"helper command bound");end
            c_valid=0;
        end
    endtask
    task wait_output;
        integer steps;
        begin steps=0;while(!m_valid)begin tick();steps=steps+1;if(steps>2*S+1)$fatal(1,"helper latency bound");end end
    endtask
    task image;
        integer idx;
        reg [RW-1:0] expected_row;
        begin
            if(dut.count!==CW'(h_count) || dut.live!==h_live)$fatal(1,"fresh complete metadata");
            for(idx=0;idx<S;idx=idx+1)if(h_live[idx])begin
                expected_row={A'(h_base[idx]),A'(h_base[idx]+h_bytes[idx]-1'b1),h_perm[idx]};
                if(dut.rules[idx]!==expected_row)$fatal(1,"fresh complete owned rule image");
            end
        end
    endtask
    task ack(input [2:0] op,input [31:0] slot,input [63:0] base,input [64:0] bytes,input [2:0] perm,access,
             input [3:0] status,input bit expected_found,input integer selected);
        begin
            send(op,slot,base,bytes,perm,access);wait_output();
            if(m_op!==op || m_status!==status || m_tag!=={T{1'b1}} || m_allow!==(op==0 && status==0) ||
                m_found!==expected_found || m_count!==CW'(h_count))$fatal(1,"fresh response fields");
            if(expected_found)begin
                if(m_slot!==32'(selected) || m_base!==A'(h_base[selected]) || m_bytes!==(A+1)'(h_bytes[selected]) ||
                    m_perm!==h_perm[selected])$fatal(1,"fresh descriptor fields");
            end else if(m_slot!==0 || m_base!==0 || m_bytes!==0 || m_perm!==0)$fatal(1,"fresh canonical descriptor");
            image();repeat(2)tick();m_ready=1;tick();if(!mfire)$fatal(1,"fresh retirement");m_ready=0;
            if(recovery_phase)recovery=recovery+1;
        end
    endtask
    task set_rule(input integer slot,input [63:0] base,input [64:0] bytes,input [2:0] perm);
        begin
            if(!h_live[slot])h_count=h_count+1;h_live[slot]=1;h_base[slot]=base;h_bytes[slot]=bytes;h_perm[slot]=perm;
            ack(1,slot,base,bytes,perm,7,0,1,slot);
        end
    endtask
    task get_rule(input integer slot);
        begin ack(3,slot,64'hffffffffffffffff,65'h1ffffffffffffffff,7,7,h_live[slot]?0:8,h_live[slot],slot);end
    endtask
    task check_rule(input [63:0] base,input [64:0] bytes,input [2:0] access,input [3:0] status,input bit present,input integer slot);
        begin ack(0,32'hffffffff,base,bytes,7,access,status,present,slot);end
    endtask
    task delete_rule(input integer slot);
        begin h_live[slot]=0;h_count=h_count-1;ack(2,slot,64'hffffffffffffffff,65'h1ffffffffffffffff,7,7,0,0,0);end
    endtask
    task clear_rules;
        begin h_live=0;h_count=0;ack(4,32'hffffffff,64'hffffffffffffffff,65'h1ffffffffffffffff,7,7,0,0,0);end
    endtask
    task fresh;
        integer before_count;
        begin
            recovery_phase=1;before_count=recovery;
            ack(5,32'hffffffff,64'hffffffffffffffff,65'h1ffffffffffffffff,7,7,0,0,0);
            check_rule(0,1,1,1,0,0);
            set_rule(S-1,0,SPACE,7);get_rule(S-1);check_rule(0,SPACE,7,0,1,S-1);
            set_rule(0,0,1,1);get_rule(0);check_rule(0,2,1,2,1,0);
            check_rule(0,1,2,3,1,0);check_rule(0,1,1,0,1,0);
            set_rule(0,0,1,0);check_rule(0,1,1,3,1,0);delete_rule(0);
            check_rule(0,1,1,S>1?0:1,S>1,S-1);
            set_rule(0,0,SPACE,7);check_rule(SPACE-1'b1,1,7,0,1,0);
            clear_rules();get_rule(0);check_rule(0,1,1,1,0,0);
            ack(5,32'hffffffff,64'hffffffffffffffff,65'h1ffffffffffffffff,7,7,0,0,0);
            recovery_phase=0;
            if(recovery-before_count!=20 || !c_ready || m_valid)$fatal(1,"full fresh command sequence");image();
        end
    endtask
    task cancel_now;
        begin
            if(clk!==0)$fatal(1,"reset boundary");rst=1;c_valid=0;m_ready=0;#1;
            if(c_ready || m_valid || m_allow || m_found)$fatal(1,"reset interface gates");tick();
            if(dut.state!==0 || dut.count!==0 || dut.live!==0)$fatal(1,"reset ownership");
            h_count=0;h_live=0;rst=0;resets=resets+1;tick();
            if(!c_ready || m_valid)$fatal(1,"stale reset output");fresh();
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("OUTPUT=%s",output_path) ||
            !$value$plusargs("COUNT=%d",count))$fatal(1,"arguments");
        $readmemh(input_path,commands,0,count-1);fd=$fopen(output_path,"w");if(!fd)$fatal(1,"trace open");
        tick();rst=0;main_phase=1;
        while(oi<count)begin
            if(!c_valid && ci<count && cycles%7!=3){c_op,c_slot,c_base,c_bytes,c_perm,c_access,c_tag,c_valid}={commands[ci],1'b1};
            if(m_valid)begin m_ready=hold_age>=3;hold_age=hold_age+1;end else begin m_ready=0;hold_age=0;end
            tick();if(cfire)c_valid=0;guard=guard+1;if(guard>2000000)$fatal(1,"finite main bound");
        end
        if(ci!=count || cp)$fatal(1,"main acceptance total");main_phase=0;c_valid=0;m_ready=0;$fclose(fd);
        for(probe=0;probe<22;probe=probe+1)begin
            if(!c_ready || dut.live!==0)$fatal(1,"probe empty idle");target=0;want_index=-1;
            case(probe)
                1:begin send(1,0,0,1,7,0);target=3;end
                2,3:begin set_rule(0,0,1,7);send(3,0,0,0,0,0);target=probe==2?1:2;end
                4,5:begin set_rule(0,0,SPACE,7);send(0,0,0,1,0,1);target=probe==4?1:2;end
                6,7:begin set_rule(S-1,0,SPACE,7);send(0,0,0,1,0,1);target=probe==6?1:2;want_index=S-1;end
                8:begin send(1,0,0,1,7,0);target=4;end
                9:begin set_rule(0,0,1,1);send(1,0,0,SPACE,7,0);target=4;end
                10:begin set_rule(0,0,SPACE,5);send(3,0,0,0,0,0);target=4;end
                11:begin set_rule(0,0,SPACE,7);send(0,0,0,1,0,7);target=4;end
                12:begin set_rule(0,0,1,7);send(0,0,0,2,0,1);target=4;end
                13:begin set_rule(0,0,1,0);send(0,0,0,1,0,1);target=4;end
                14:begin send(0,0,0,1,0,1);target=4;end
                15:begin set_rule(0,0,1,7);send(2,0,0,0,0,0);target=4;end
                16:begin set_rule(0,0,1,7);send(4,0,0,0,0,0);target=4;end
                17:begin send(0,0,0,1,0,0);target=4;end
                18:begin set_rule(0,0,SPACE,7);send(1,0,0,0,0,0);target=4;end
                19:begin send(3,S,64'hffffffffffffffff,65'h1ffffffffffffffff,7,7);target=4;end
                20:begin send(7,32'hffffffff,64'hffffffffffffffff,65'h1ffffffffffffffff,7,7);target=4;end
                21:begin set_rule(0,0,1,5);send(5,0,0,0,0,0);target=4;end
                default:target=0;
            endcase
            guard=0;
            while(dut.state!=target || (want_index>=0 && dut.index!=want_index))begin
                tick();guard=guard+1;if(guard>2*S+2)$fatal(1,"unreached immediate reset target %0d",probe);
            end
            if(target==4)begin
                // A real next CLEAR is held under the selected current response.
                c_valid=1;c_op=4;c_slot=32'hffffffff;c_base=64'hffffffffffffffff;c_bytes=65'h1ffffffffffffffff;
                c_perm=7;c_access=7;c_tag={T{1'b1}};repeat(3)tick();if(c_ready)$fatal(1,"queued reset command");
            end
            cancel_now();
        end
        if(states!==5'h1f || command_holds==0 || output_holds==0)$fatal(1,"state and hold coverage");
        $display("PASS region commands=%0d outputs=%0d first_checks=%0d cycles=%0d command_holds=%0d output_holds=%0d reads=%0d writes=%0d resets=%0d recovery=%0d max_latency=%0d states=%h",
            ci,oi,fi,cycles,command_holds,output_holds,reads,writes,resets,recovery,max_latency,states);
        $finish;
    end
endmodule
