// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_ternary_rule_table;
    parameter integer N=16, K=32, D=16, T=8;
    localparam integer C=$clog2(N+1), R=2*K+D;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, c_valid=0, m_ready=0;
    reg [2:0] c_op=0;
    reg [31:0] c_slot=0;
    reg [K-1:0] c_value=0,c_care=0;
    reg [D-1:0] c_action=0;
    reg [T-1:0] c_tag=0;
    wire c_ready,m_valid,m_found;
    wire [2:0] m_op,m_status;
    wire [T-1:0] m_tag;
    wire [C-1:0] m_live_count,m_match_count;
    wire [N-1:0] m_match_mask;
    wire [31:0] m_slot;
    wire [K-1:0] m_pattern,m_care;
    wire [D-1:0] m_action;
    ram_ternary_rule_table #(.SLOTS(N),.KEY_W(K),.ACTION_W(D),.TAG_W(T)) dut(.*);

    integer fd,mode,units,scan,tmp_slot,j,i,u,target,setup_count,fresh_count;
    integer item_op,e_status,e_live,e_found,e_count,before_count,after_count;
    integer next_flag,next_op;
    reg [31:0] item_slot,e_slot,next_slot;
    reg [K-1:0] item_value,item_care,e_pattern,e_care,next_value,next_care;
    reg [D-1:0] item_action,e_action,next_action;
    reg [T-1:0] item_tag,next_tag;
    reg [N-1:0] e_mask,before_live,after_live;
    reg [R-1:0] before_row[0:N-1],after_row[0:N-1],reset_row[0:N-1],reset_read;
    reg [K-1:0] tmp_pattern,tmp_care;
    reg [D-1:0] tmp_action;
    reg [4095:0] input_path;
    integer completed=0,cancelled=0,accepted=0,cycles=0,held=0,blocked=0;
    integer first_checks=0,max_latency=0,physical_rows=0,reset_checks=0;
    integer latency,wanted_latency,h,owner_accepted=0;
    integer writes=0,reads=0,retired=0,unaccepted_cancels=0;
    reg [6:0] states_seen=0;
    reg [7:0] tail;

    // Edge monitor checks real transfers and the single packed bank port.
    always @(posedge clk) begin
        cycles=cycles+1;
        if (!rst) begin
            states_seen[dut.state_q]=1;
            if (c_valid && !c_ready) blocked=blocked+1;
            if (m_valid && !m_ready) held=held+1;
            if (dut.port_read && dut.port_write) $fatal(1,"RAM port collision");
            if (dut.port_read) begin
                if (dut.port_addr>=N || !dut.live_q[dut.port_addr]) $fatal(1,"invalid RAM read");
                reads=reads+1;
            end
            if (dut.port_write) begin
                if (dut.slot_q>=N || dut.op_q!=1) $fatal(1,"invalid RAM write");
                writes=writes+1;
            end
            if (c_valid && c_ready) accepted=accepted+1;
            if (m_valid && m_ready) retired=retired+1;
        end
    end

    task automatic tick;
        begin @(posedge clk); #1; end
    endtask

    task automatic load_item;
        begin
            scan=$fscanf(fd,"%d %d %h %h %h %h %d %d %d %h %d %d %h %h %h %d %d",
                item_op,item_slot,item_value,item_care,item_action,item_tag,
                e_status,e_live,e_found,e_mask,e_count,e_slot,e_pattern,e_care,e_action,
                before_count,after_count);
            if (scan!=17 || item_op<0 || item_op>7 || before_count<0 || before_count>N ||
                after_count<0 || after_count>N) $fatal(1,"fixture command");
            scan=$fscanf(fd,"%d %d %d %h %h %h %h",next_flag,next_op,next_slot,
                next_value,next_care,next_action,next_tag);
            if (scan!=7 || next_flag<0 || next_flag>1) $fatal(1,"fixture actual next");
            before_live=0; after_live=0;
            for(j=0;j<N;j=j+1) begin before_row[j]=0; after_row[j]=0; end
            for(j=0;j<before_count;j=j+1) begin
                scan=$fscanf(fd,"%d %h %h %h",tmp_slot,tmp_pattern,tmp_care,tmp_action);
                if (scan!=4 || tmp_slot<0 || tmp_slot>=N || before_live[tmp_slot]) $fatal(1,"before row");
                before_live[tmp_slot]=1;
                before_row[tmp_slot]={tmp_pattern,tmp_care,tmp_action};
            end
            for(j=0;j<after_count;j=j+1) begin
                scan=$fscanf(fd,"%d %h %h %h",tmp_slot,tmp_pattern,tmp_care,tmp_action);
                if (scan!=4 || tmp_slot<0 || tmp_slot>=N || after_live[tmp_slot]) $fatal(1,"after row");
                after_live[tmp_slot]=1;
                after_row[tmp_slot]={tmp_pattern,tmp_care,tmp_action};
            end
        end
    endtask

    task automatic check_before;
        integer b;
        begin
            if (dut.live_q!==before_live || dut.live_count_q!==before_count[C-1:0]) $fatal(1,"before metadata");
            for(b=0;b<N;b=b+1)
                if (before_live[b] && dut.payload[b]!==before_row[b]) $fatal(1,"before payload slot%0d",b);
        end
    endtask
    function automatic integer published;
        integer b;
        begin
            published=(dut.live_q===after_live && dut.live_count_q===after_count[C-1:0]);
            for(b=0;b<N;b=b+1)
                if (after_live[b] && dut.payload[b]!==after_row[b]) published=0;
        end
    endfunction
    task automatic check_after;
        begin if (!published()) $fatal(1,"after physical image"); end
    endtask

    task automatic check_response;
        begin
            if (!m_valid || (^{m_op,m_status,m_tag,m_live_count,m_found,m_match_mask,
                m_match_count,m_slot,m_pattern,m_care,m_action})===1'bx)
                $fatal(1,"missing/unknown response");
            if (m_op!==item_op[2:0] || m_tag!==item_tag || m_status!==e_status[2:0] ||
                m_live_count!==e_live[C-1:0] || m_found!==e_found[0] || m_match_mask!==e_mask ||
                m_match_count!==e_count[C-1:0] || m_slot!==e_slot || m_pattern!==e_pattern ||
                m_care!==e_care || m_action!==e_action)
                $fatal(1,"response mismatch op%0d slot%0d status%0d/%0d mask%h/%h action%h/%h",
                    item_op,item_slot,m_status,e_status,m_match_mask,e_mask,m_action,e_action);
        end
    endtask
    task automatic offer_item;
        begin
            c_valid=1; c_op=item_op; c_slot=item_slot; c_value=item_value;
            c_care=item_care; c_action=item_action; c_tag=item_tag;
        end
    endtask
    task automatic offer_next;
        begin
            c_valid=next_flag; c_op=next_op; c_slot=next_slot; c_value=next_value;
            c_care=next_care; c_action=next_action; c_tag=next_tag;
        end
    endtask
    task automatic check_next;
        begin
            if (c_valid!==next_flag[0] || (next_flag &&
                {c_op,c_slot,c_value,c_care,c_action,c_tag} !==
                {next_op[2:0],next_slot,next_value,next_care,next_action,next_tag}))
                $fatal(1,"actual next command changed");
        end
    endtask
    task automatic begin_owner;
        begin
            check_before();
            if (dut.state_q!=0 || m_valid) $fatal(1,"owner admission state");
            if (c_valid && {c_op,c_slot,c_value,c_care,c_action,c_tag} !==
                {item_op[2:0],item_slot,item_value,item_care,item_action,item_tag})
                $fatal(1,"queued command differs from next owner");
            @(negedge clk); offer_item(); m_ready=0;
            #1; if (!c_ready) $fatal(1,"owner admission ready");
            tick();
            if (c_ready || m_valid || dut.state_q!=1) $fatal(1,"owner capture");
            owner_accepted=1;
            offer_next();
        end
    endtask

    // These literal predicates match TEST_PLAN.json. held means actual valid
    // with sink blocked; published compares the complete live physical image.
    function automatic integer target_reached(input integer id);
        reg held_now;
        begin
            held_now=m_valid && !m_ready && dut.state_q==6;
            case(id)
                0: target_reached=dut.state_q==0 && !owner_accepted && c_valid && !m_valid &&
                    {c_op,c_slot,c_value,c_care,c_action,c_tag}===
                    {item_op[2:0],item_slot,item_value,item_care,item_action,item_tag};
                1: target_reached=dut.state_q==1 && dut.op_q==0;
                2: target_reached=dut.state_q==2 && dut.op_q==1;
                3: target_reached=dut.state_q==3 && dut.op_q==0;
                4: target_reached=dut.state_q==4 && dut.op_q==0;
                5: target_reached=dut.state_q==5 && dut.op_q==0;
                6: target_reached=held_now;
                7: target_reached=held_now && dut.op_q==0 && m_found && m_match_count>1;
                8: target_reached=held_now && dut.op_q==0 && m_status==1 && !m_found;
                9: target_reached=dut.state_q==4 && dut.op_q==0 && dut.row_hit && dut.read_care==0;
                10: target_reached=dut.state_q==4 && dut.op_q==0 && dut.row_hit &&
                    dut.read_care==(({K{1'b0}} | 1'b1) | ({{(K-1){1'b0}},1'b1} << (K-1)));
                11: target_reached=held_now && dut.op_q==0 && m_slot==0 && m_match_count>1;
                12: target_reached=held_now && dut.op_q==0 && m_slot==N-1 && m_match_count==1;
                13: target_reached=dut.state_q==4 && dut.op_q==0 && dut.scan_q==N-1 && dut.row_hit;
                14: target_reached=dut.state_q==4 && dut.op_q==0 && dut.scan_q==N-1 &&
                    dut.live_q[dut.scan_q] && !dut.row_hit;
                15: target_reached=dut.state_q==3 && dut.op_q==0 && !dut.live_q[dut.scan_q];
                16: target_reached=dut.state_q==3 && dut.op_q==3 && dut.live_q[dut.slot_q];
                17: target_reached=held_now && dut.op_q==3 && m_found;
                18: target_reached=dut.state_q==2 && dut.op_q==1 && !dut.live_q[dut.slot_q];
                19: target_reached=dut.state_q==2 && dut.op_q==1 && dut.live_q[dut.slot_q];
                20: target_reached=held_now && dut.op_q==1 && before_count==N && published();
                21: target_reached=dut.state_q==1 && dut.op_q==2 && dut.live_q[dut.slot_q];
                22: target_reached=held_now && dut.op_q==2 && m_status==4;
                23: target_reached=held_now && dut.op_q==4 && dut.live_count_q==0 && published();
                24: target_reached=held_now && dut.op_q==5 && dut.live_count_q==N;
                25: target_reached=held_now && m_status==2 && dut.slot_q==32'hffffffff;
                26: target_reached=held_now && m_status==3 && dut.op_q==7 && dut.slot_q==32'hffffffff;
                27: target_reached=held_now && dut.op_q==0 && m_found && m_status==0;
                28: target_reached=dut.state_q==1 && owner_accepted && c_valid && !c_ready &&
                    {c_op,c_slot,c_value,c_care,c_action,c_tag}===
                    {next_op[2:0],next_slot,next_value,next_care,next_action,next_tag};
                29: target_reached=held_now && dut.op_q==1 && dut.live_q[dut.slot_q] && published();
                30: target_reached=held_now && dut.op_q==2 && !dut.live_q[dut.slot_q] && published();
                31: target_reached=held_now && dut.op_q==3 && m_status==4;
                32: target_reached=dut.state_q==4 && dut.op_q==0 && dut.scan_q==0 && dut.row_hit;
                33: target_reached=dut.state_q==4 && dut.op_q==0 && dut.scan_q==N/2 && dut.row_hit;
                34: target_reached=dut.state_q==4 && dut.op_q==0 && dut.scan_q>0 && dut.match_q!=0;
                default: target_reached=0;
            endcase
        end
    endfunction

    task automatic emit_record;
        integer b;
        begin
            // All fields are observed DUT values. Live RAM rows follow in slot order.
            $write("R %0d %h %0d %0d %0d %h %0d %0d %h %h %h %0d",
                m_op,m_tag,m_status,m_live_count,m_found,m_match_mask,m_match_count,
                m_slot,m_pattern,m_care,m_action,after_count);
            for(b=0;b<N;b=b+1)
                if (dut.live_q[b]) $write(" %0d %h",b,dut.payload[b]);
            $write("\n");
        end
    endtask
    task automatic run_item;
        begin
            begin_owner();
            wanted_latency=1;
            if (item_op==0) wanted_latency=2*N+2;
            if (item_op==1 && item_slot<N) wanted_latency=2;
            if (item_op==3 && item_slot<N && before_live[item_slot]) wanted_latency=3;
            latency=0;
            while (!m_valid) begin
                if (c_ready) $fatal(1,"busy admission");
                check_next(); tick(); latency=latency+1;
                if (latency>2*N+2) $fatal(1,"first valid bound");
            end
            if (latency!=wanted_latency) $fatal(1,"exact latency %0d/%0d",latency,wanted_latency);
            if (latency>max_latency) max_latency=latency;
            first_checks=first_checks+1;
            check_response(); check_after();
            for(h=0;h<3+(completed%4);h=h+1) begin
                if (c_ready) $fatal(1,"held admission");
                check_next(); tick(); check_response(); check_after();
            end
            emit_record();
            @(negedge clk); m_ready=1;
            if (c_ready) $fatal(1,"retirement next acceptance");
            tick();
            if (m_valid || dut.state_q!=0 || !c_ready) $fatal(1,"response retirement");
            check_after(); m_ready=0;
            completed=completed+1; physical_rows=physical_rows+after_count;
        end
    endtask

    task automatic cancel_owner(input integer id);
        integer b,waited,prior_completed;
        begin
            owner_accepted=0; prior_completed=completed;
            if (id==0) begin
                check_before(); @(negedge clk); offer_item(); m_ready=0; #1;
                unaccepted_cancels=unaccepted_cancels+1;
            end else begin_owner();
            waited=0;
            while (!target_reached(id)) begin
                check_next();
                if (c_ready || m_ready) $fatal(1,"reset owner escaped");
                tick(); waited=waited+1;
                if (waited>2*N+4) $fatal(1,"unreached reset target%0d",id);
            end
            if (m_valid) begin check_response(); check_after(); end
            $display("Z %0d %0d %0d %0d %0d %h %h",id,dut.state_q,dut.op_q,
                dut.scan_q,owner_accepted,dut.live_q,dut.match_q);
            // No intervening active edge between true predicate and reset.
            for(b=0;b<N;b=b+1) reset_row[b]=dut.payload[b];
            reset_read=dut.read_q;
            rst=1; #1;
            if (c_ready || m_valid || dut.port_read || dut.port_write) $fatal(1,"immediate reset gates");
            tick();
            if (dut.state_q!=0 || dut.live_q!==0 || dut.live_count_q!==0 || m_valid)
                $fatal(1,"reset ownership/live metadata");
            for(b=0;b<N;b=b+1)
                if (dut.payload[b]!==reset_row[b]) $fatal(1,"payload reset/write");
            if (dut.read_q!==reset_read) $fatal(1,"read register reset/write");
            if (completed!=prior_completed) $fatal(1,"cancelled owner retired");
            @(negedge clk); c_valid=0; m_ready=0; rst=0; #1;
            if (!c_ready || m_valid) $fatal(1,"post reset admission");
            cancelled=cancelled+1; reset_checks=reset_checks+1;
        end
    endtask

    initial begin
        if (!$value$plusargs("INPUT=%s",input_path)) $fatal(1,"missing INPUT");
        fd=$fopen(input_path,"r");
        if (!fd || $fscanf(fd,"%d %d",mode,units)!=2 || units<1) $fatal(1,"fixture header");
        repeat(3) tick();
        @(negedge clk); rst=0; #1;
        if (!c_ready || m_valid || dut.live_q!==0) $fatal(1,"initial reset");
        if (mode==0) begin
            for(i=0;i<units;i=i+1) begin load_item(); run_item(); end
        end else if (mode==1) begin
            for(u=0;u<units;u=u+1) begin
                if ($fscanf(fd,"%d %d %d",target,setup_count,fresh_count)!=3 ||
                    fresh_count!=2*N+5) $fatal(1,"reset fixture unit");
                for(i=0;i<setup_count;i=i+1) begin load_item(); run_item(); end
                load_item(); cancel_owner(target);
                for(i=0;i<fresh_count;i=i+1) begin load_item(); run_item(); end
                if (dut.live_q!==0 || dut.live_count_q!==0) $fatal(1,"fresh did not end empty");
            end
        end else $fatal(1,"unknown fixture mode");
        while (!$feof(fd)) begin
            scan=$fscanf(fd,"%c",tail);
            if (scan==1 && tail!=9 && tail!=10 && tail!=13 && tail!=32) $fatal(1,"fixture trailer");
            if (scan!=1 && !$feof(fd)) $fatal(1,"fixture tail read");
        end
        $fclose(fd);
        if (accepted!=completed+cancelled-unaccepted_cancels || retired!=completed)
            $fatal(1,"exact owner/retirement counts");
        $display("PASS {\"mode\":%0d,\"completed\":%0d,\"cancelled\":%0d,\"accepted\":%0d,\"first_checks\":%0d,\"max_latency\":%0d,\"physical_rows\":%0d,\"reset_checks\":%0d,\"held\":%0d,\"blocked\":%0d,\"cycles\":%0d,\"writes\":%0d,\"reads\":%0d,\"states\":%0d}",
            mode,completed,cancelled,accepted,first_checks,max_latency,physical_rows,
            reset_checks,held,blocked,cycles,writes,reads,states_seen);
        $finish;
    end
endmodule
