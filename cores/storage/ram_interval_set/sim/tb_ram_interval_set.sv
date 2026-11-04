`timescale 1ns/1ps
module tb_ram_interval_set;
    parameter integer N=16,A=32,T=8;
    localparam integer I=(N<=2)?1:$clog2(N),C=$clog2(N+1),R=2*A+1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,m_ready=0;
    reg [2:0] c_op=0;
    reg [63:0] c_base=0;
    reg [64:0] c_bytes=0;
    reg [T-1:0] c_tag=0;
    wire c_ready,m_valid,m_keep,m_first,m_last,m_whole;
    wire [2:0] m_op,m_status;
    wire [I-1:0] m_index;
    wire [A-1:0] m_base;
    wire [A:0] m_bytes,m_total,m_covered;
    wire [C-1:0] m_count;
    wire [T-1:0] m_tag;
    ram_interval_set #(.MAX_INTERVALS(N),.ADDR_W(A),.TAG_W(T)) dut(.*);
    integer fd,rc,mode,units,u,setup_count,fresh_count,prefix;
    integer target=-1,armed=0,cancelled=0,next_id=0,current_id=-1;
    integer exp_op,exp_status,exp_count,exp_whole,exp_records,before_count,attempt_count,after_count;
    reg [63:0] exp_base,next_base,preaccepted_base;
    reg [64:0] exp_bytes,exp_total,exp_covered,next_bytes,preaccepted_bytes;
    reg [31:0] exp_tag,next_tag,preaccepted_tag;
    integer next_flag,next_op,preaccepted_op;
    integer record_keep[0:N-1],record_first[0:N-1],record_last[0:N-1],record_index[0:N-1];
    reg [63:0] record_base[0:N-1],before_lo[0:N],attempt_lo[0:N],after_lo[0:N];
    reg [64:0] record_bytes[0:N-1],before_end[0:N],attempt_end[0:N],after_end[0:N];
    integer owned[0:2*N-1];
    integer cycle=0,accepted_cycle=0,first_latency=-1,first_seen=0,prior_retired=0;
    integer preaccepted=0,next_is_offered=0,accepted=0,merged_rows=0;
    integer completed=0,resets=0,queued=0,accepts=0,retired=0,valid_checks=0;
    integer reads=0,writes=0,row_checks=0,source_holds=0,output_holds=0,max_latency=0;
    integer middle=(N<3)?0:N/2;
    integer j,index,bank,read_pending=0,source_held=0,output_held=0;
    reg [R-1:0] pending_read;
    reg [255:0] held_source;
    reg [511:0] held_output,previous_output;
    reg [18:0] state_mask=0;
    string input_path;

    function automatic [R-1:0] packed_row(input reg [63:0] lo,input reg [64:0] ending);
        packed_row={lo[A-1:0],ending[A:0]};
    endfunction
    function automatic [255:0] source_word;
        source_word={c_valid,c_op,c_base,c_bytes,c_tag};
    endfunction
    function automatic [511:0] output_word;
        output_word={m_valid,m_op,m_status,m_keep,m_first,m_last,m_index,m_base,
                     m_bytes,m_count,m_total,m_covered,m_whole,m_tag};
    endfunction
    task automatic check_record(input integer ordinal);
        begin
            if(ordinal<0 || ordinal>=exp_records) $fatal(1,"record range");
            if(m_op!==exp_op[2:0] || m_status!==exp_status[2:0] || m_count!==exp_count ||
               m_total!==exp_total || m_covered!==exp_covered || m_whole!==exp_whole[0] || m_tag!==exp_tag[T-1:0])
                $fatal(1,"metadata id%0d op%0d status%0d/%0d count%0d/%0d total%0h/%0h cover%0h/%0h",current_id,m_op,m_status,exp_status,m_count,exp_count,m_total,exp_total,m_covered,exp_covered);
            if(m_keep!==record_keep[ordinal][0] || m_first!==record_first[ordinal][0] ||
               m_last!==record_last[ordinal][0] || m_index!==record_index[ordinal] ||
               m_base!==record_base[ordinal] || m_bytes!==record_bytes[ordinal])
                $fatal(1,"record id%0d ordinal%0d",current_id,ordinal);
        end
    endtask
    task automatic check_snapshot;
        begin
            if(dut.active_count!==after_count) $fatal(1,"active count");
            for(j=0;j<after_count;j=j+1) begin
                index=(dut.active_bank?N:0)+j;
                if(!owned[index] || dut.ram[index]!==packed_row(after_lo[j],after_end[j]))
                    $fatal(1,"active row id%0d row%0d",current_id,j);
                row_checks=row_checks+1;
            end
        end
    endtask
    function automatic integer hit_target;
        reg overlaps,touches,left_piece,right_piece;
        integer reach;
        begin
            overlaps=({1'b0,dut.row_lo}<dut.span_end && {1'b0,dut.span_lo}<dut.row_end);
            touches=({1'b0,dut.row_lo}<=dut.pending_end && {1'b0,dut.pending_lo}<=dut.row_end);
            left_piece=dut.row_lo<dut.span_lo;
            right_piece=dut.row_end>dut.span_end;
            reach=N;if(A==1 && reach>1) reach=1;
            hit_target=0;
            if(target>=0 && target<19) hit_target=(dut.state==target);
            case(target)
            19:hit_target=dut.state==4 && dut.op_q==0 && overlaps;
            20:hit_target=dut.state==4 && dut.op_q==0 && dut.row_end=={1'b0,dut.span_lo};
            21:hit_target=dut.state==4 && dut.op_q==0 && {1'b0,dut.row_lo}==dut.span_end;
            22:hit_target=dut.state==4 && dut.op_q==0 && touches && merged_rows>=1;
            23:hit_target=dut.state==4 && dut.op_q==1 && {1'b0,dut.span_lo}<={1'b0,dut.row_lo} && dut.row_end<=dut.span_end;
            24:hit_target=dut.state==4 && dut.op_q==1 && overlaps && (left_piece!=right_piece);
            25:hit_target=dut.state==4 && dut.op_q==1 && left_piece && right_piece;
            26:hit_target=dut.state==5 && dut.op_q==0 && dut.private_count==N;
            27:hit_target=dut.state==5 && dut.op_q==1 && dut.private_count==N;
            28:hit_target=dut.state==13 && {1'b0,dut.covered_q}==(66'd1<<A);
            29:hit_target=dut.state==13 && dut.covered_q!=0 && dut.covered_q<dut.bytes_q && dut.active_count>=2;
            30:hit_target=m_valid && m_op==3 && m_keep && m_index==0;
            31:hit_target=m_valid && m_op==3 && m_index==1 && !m_last && prior_retired==1;
            32:hit_target=m_valid && m_op==3 && m_last && prior_retired==2;
            33:hit_target=dut.state==9 && dut.private_count==reach;
            34:hit_target=m_valid && m_op==0 && m_status==0;
            35:hit_target=m_valid && m_status==2;
            36:hit_target=m_valid && m_status==3;
            37:hit_target=next_is_offered && c_valid && !c_ready && dut.state!=0 &&
                c_op==next_op && c_base==next_base && c_bytes==next_bytes && c_tag==next_tag[T-1:0];
            38:hit_target=dut.state==6 && dut.private_count==0;
            39:hit_target=dut.state==6 && dut.private_count==reach/2 && reach>=3;
            40:hit_target=dut.state==6 && dut.private_count==reach-1;
            41:hit_target=m_valid && m_op==4 && m_status==0 && m_count==0;
            42:hit_target=m_valid && m_op==5 && m_status==0;
            43:hit_target=m_valid && m_op==3 && m_status==1 && !m_keep;
            44:hit_target=m_valid && m_op==2 && m_status==0 && m_covered==0 && !m_whole;
            45:hit_target=m_valid && m_status==4;
            endcase
        end
    endfunction
    // The first observed target cancels before the immediately following edge.
    always @(negedge clk) begin
        #1;
        if(!rst && m_valid && !first_seen) begin
            first_seen=1;first_latency=cycle-accepted_cycle;valid_checks=valid_checks+1;
            if(first_latency<0 || first_latency>6*N+16) $fatal(1,"first valid bound");
            if(first_latency>max_latency) max_latency=first_latency;
            check_record(prior_retired);check_snapshot();
            $display("VALID %0d %0d",current_id,first_latency);
        end
        if(armed && !cancelled && hit_target()) begin
            if(m_valid) check_record(prior_retired);
            $display("CANCEL %0d %0d %0d %0d",target,dut.state,current_id,prior_retired);
            rst=1;cancelled=1;armed=0;
        end
    end
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst) begin
            for(j=0;j<2*N;j=j+1) owned[j]=0;
            prior_retired=0;merged_rows=0;read_pending=0;source_held=0;output_held=0;
        end else begin
            if(source_held && source_word()!==held_source) $fatal(1,"unstable blocked command");
            if(output_held && output_word()!==held_output) $fatal(1,"unstable held output");
            source_held=c_valid && !c_ready;held_source=source_word();
            output_held=m_valid && !m_ready;held_output=output_word();
            if(source_held) source_holds=source_holds+1;
            if(output_held) output_holds=output_holds+1;
            if(dut.state<=18) state_mask[dut.state]=1;
            if(read_pending && dut.read_q!==pending_read) $fatal(1,"not a synchronous RAM read");
            read_pending=0;
            if(c_valid && c_ready) begin accepts=accepts+1;prior_retired=0;merged_rows=0;end
            if(dut.state==2) begin
                bank=dut.active_bank?0:N;
                for(j=0;j<N;j=j+1) owned[bank+j]=0;
            end
            if(dut.state==3 || dut.state==11 || dut.state==14) begin
                index=(dut.active_bank?N:0)+dut.scan_index;
                if(dut.scan_index>=before_count || !owned[index] ||
                   dut.ram[index]!==packed_row(before_lo[dut.scan_index],before_end[dut.scan_index]))
                    $fatal(1,"unowned/changed active read id%0d index%0d",current_id,dut.scan_index);
                pending_read=dut.ram[index];read_pending=1;reads=reads+1;
            end
            if(dut.state==4 && dut.op_q==0 && dut.pending_valid &&
               {1'b0,dut.row_lo}<=dut.pending_end && {1'b0,dut.pending_lo}<=dut.row_end)
                merged_rows=merged_rows+1;
            if(dut.state==6) begin
                index=(dut.active_bank?0:N)+dut.private_count;
                if(dut.private_count>=N || dut.private_count>=attempt_count ||
                   dut.emit_first!==packed_row(attempt_lo[dut.private_count],attempt_end[dut.private_count]))
                    $fatal(1,"private finalized row id%0d index%0d",current_id,dut.private_count);
                owned[index]=1;writes=writes+1;
            end
            if(m_valid && m_ready) begin
                check_record(prior_retired);
                $display("REC %0d %0d %0d %0d %0d %0d %0h %0h %0d %0d %0h %0h %0d %0d %0h",current_id,prior_retired,m_keep,m_first,m_last,m_index,m_base,m_bytes,m_status,m_count,m_total,m_covered,m_whole,m_op,m_tag);
                prior_retired=prior_retired+1;retired=retired+1;
            end
        end
    end
    task automatic falling;begin @(negedge clk);#2;end endtask
    task automatic active;begin @(posedge clk);#2;end endtask
    task automatic read_command;
        integer k;
        begin
            current_id=next_id;next_id=next_id+1;first_seen=0;first_latency=-1;next_is_offered=0;
            rc=$fscanf(fd,"%d %h %h %h %d %d %h %h %d %d %d %d %d\n",exp_op,exp_base,exp_bytes,exp_tag,
                       exp_status,exp_count,exp_total,exp_covered,exp_whole,exp_records,before_count,attempt_count,after_count);
            if(rc!=13 || exp_records<1 || exp_records>N || before_count>N || attempt_count>N+1 || after_count>N)
                $fatal(1,"command parse id%0d rc%0d",current_id,rc);
            rc=$fscanf(fd,"%d %d %h %h %h\n",next_flag,next_op,next_base,next_bytes,next_tag);
            if(rc!=5) $fatal(1,"next parse");
            for(k=0;k<exp_records;k=k+1) begin
                rc=$fscanf(fd,"%d %d %d %d %h %h\n",record_keep[k],record_first[k],record_last[k],record_index[k],record_base[k],record_bytes[k]);
                if(rc!=6) $fatal(1,"record parse");
            end
            for(k=0;k<before_count;k=k+1) begin rc=$fscanf(fd,"%h %h\n",before_lo[k],before_end[k]);if(rc!=2) $fatal(1,"before parse");end
            for(k=0;k<attempt_count;k=k+1) begin rc=$fscanf(fd,"%h %h\n",attempt_lo[k],attempt_end[k]);if(rc!=2) $fatal(1,"attempt parse");end
            for(k=0;k<after_count;k=k+1) begin rc=$fscanf(fd,"%h %h\n",after_lo[k],after_end[k]);if(rc!=2) $fatal(1,"after parse");end
        end
    endtask
    task automatic offer_command;
        begin
            if(preaccepted) begin
                if(exp_op!=preaccepted_op || exp_base!=preaccepted_base || exp_bytes!=preaccepted_bytes || exp_tag!=preaccepted_tag)
                    $fatal(1,"preaccepted command differs from actual next frozen command");
                preaccepted=0;
            end else begin
                falling();
                if(!cancelled) begin c_valid=1;c_op=exp_op;c_base=exp_base;c_bytes=exp_bytes;c_tag=exp_tag[T-1:0];end
                accepted=0;
                while(!accepted && !cancelled) begin
                    accepted=c_ready;active();
                    if(accepted && !cancelled) accepted_cycle=cycle;
                    if(!accepted && !cancelled) falling();
                end
                if(!cancelled) begin falling();c_valid=0;end
            end
        end
    endtask
    task automatic pending_command;
        begin
            c_valid=next_flag;c_op=next_op;c_base=next_base;c_bytes=next_bytes;c_tag=next_tag[T-1:0];
            next_is_offered=next_flag;
        end
    endtask
    task automatic complete_command;
        integer ordinal,waited,stall;
        begin
            offer_command();if(!cancelled) pending_command();
            ordinal=0;waited=0;m_ready=0;
            while(ordinal<exp_records && !cancelled) begin
                if(m_valid) begin
                    check_record(ordinal);previous_output=output_word();
                    for(stall=0;stall<2;stall=stall+1) begin
                        active();falling();
                        if(output_word()!==previous_output) $fatal(1,"two-edge output hold");
                    end
                    m_ready=1;active();falling();m_ready=0;ordinal=ordinal+1;
                end else begin active();falling();end
                waited=waited+1;
                if(waited>6*N+16+8*N+10) $fatal(1,"missing result id%0d",current_id);
            end
            if(!cancelled) begin
                if(m_valid || !c_ready || !first_seen) $fatal(1,"final ownership");
                $display("DONE %0d %0d %0d",current_id,first_latency,prior_retired);
                completed=completed+1;
                if(next_flag) begin
                    if(!c_valid || !c_ready) $fatal(1,"lost next offer");
                    preaccepted_op=next_op;preaccepted_base=next_base;preaccepted_bytes=next_bytes;preaccepted_tag=next_tag;
                    active();accepted_cycle=cycle;falling();c_valid=0;preaccepted=1;queued=queued+1;
                end else c_valid=0;
            end
        end
    endtask
    task automatic cancel_owner;
        integer waited;
        begin
            cancelled=0;armed=1;prior_retired=0;offer_command();
            if(!cancelled) pending_command();
            waited=0;m_ready=0;
            while(!cancelled) begin
                if((target==31 || target==32) && m_valid && prior_retired<prefix) m_ready=1;else m_ready=0;
                active();falling();waited=waited+1;
                if(waited>6*N+16+8*N+20) $fatal(1,"unreachable target%0d state%0d",target,dut.state);
            end
            c_valid=0;m_ready=0;next_is_offered=0;active();
            if(m_valid || c_ready || m_count!=0 || m_total!=0) $fatal(1,"reset quiescence");
            falling();rst=0;active();
            if(m_valid || !c_ready || m_count!=0 || m_total!=0) $fatal(1,"reset recovery");
            cancelled=0;armed=0;preaccepted=0;resets=resets+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path)) $fatal(1,"missing input");
        fd=$fopen(input_path,"r");if(!fd) $fatal(1,"input open");
        rc=$fscanf(fd,"%d %d\n",mode,units);if(rc!=2) $fatal(1,"mode");
        active();falling();rst=0;active();
        if(m_valid || !c_ready || m_count!=0 || m_total!=0) $fatal(1,"initial reset");
        for(u=0;u<units;u=u+1) begin
            if(mode==0) begin read_command();complete_command();end
            else begin
                rc=$fscanf(fd,"%d %d %d %d\n",target,setup_count,fresh_count,prefix);
                if(rc!=4) $fatal(1,"reset header");
                for(integer z=0;z<setup_count;z=z+1) begin read_command();complete_command();end
                read_command();cancel_owner();
                for(integer z=0;z<fresh_count;z=z+1) begin read_command();complete_command();end
            end
        end
        $fclose(fd);
        $display("PASS completed=%0d resets=%0d queued=%0d accepts=%0d retired=%0d valids=%0d reads=%0d writes=%0d rows=%0d source_holds=%0d output_holds=%0d state_mask=%0h max_latency=%0d",completed,resets,queued,accepts,retired,valid_checks,reads,writes,row_checks,source_holds,output_holds,state_mask,max_latency);
        $finish;
    end
endmodule
