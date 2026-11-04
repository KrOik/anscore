// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_byte_write_coalescer;
    parameter integer N=16,A=32,B=4,T=8;
    localparam integer I=N>1?$clog2(N):1,C=$clog2(N+1),D=8*B,R=A+9*B,S=75+T;
    localparam integer CAP=(A<10 && ((1<<A)/B)<N)?((1<<A)/B):N;
    localparam integer MID=(CAP-1)/2;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg s_valid=0,q_ready=0,p_valid=0,p_error=0,m_ready=0;
    reg [S-1:0] drive_word=0;
    wire [63:0] s_addr;
    wire [7:0] s_data;
    wire s_keep,s_first,s_last;
    wire [T-1:0] s_tag;
    assign {s_addr,s_data,s_keep,s_first,s_last,s_tag}=drive_word;
    wire s_ready,q_valid,p_ready,m_valid;
    wire [A-1:0] q_addr;
    wire [D-1:0] q_data;
    wire [B-1:0] q_strb;
    wire [4:0] m_status;
    wire [T-1:0] m_tag;
    wire [C-1:0] m_beats;
    wire [N-1:0] m_error_mask;
    ram_byte_write_coalescer #(.MAX_BEATS(N),.ADDR_W(A),.DATA_BYTES(B),.TAG_W(T)) dut(.*);

    reg [S-1:0] tok[0:65535];
    integer gap[0:65535],ev_reads[0:65535],ev_write[0:65535];
    reg [R-1:0] ev_row[0:65535];
    integer ev_count[0:65535],ev_error[0:65535],ev_work[0:65535];
    integer fid[0:255],offset[0:255],length[0:255],qo[0:255],qc[0:255];
    integer es[0:255],er[0:255],ew[0:255],eh[0:255],exwait[0:255],elat[0:255];
    reg [T-1:0] etag[0:255];
    reg [N-1:0] emask[0:255];
    reg [A-1:0] qa[0:8191];
    reg [D-1:0] qd[0:8191];
    reg [B-1:0] qs[0:8191];
    integer qe[0:8191],qstall[0:8191],adelay[0:8191],target_ids[0:31];
    integer main_count,reset_count,frame_count,token_count,request_count;
    integer fd,rc,f,j,k,tp=0,qp=0;
    integer v0,v1,v2,v3,v4,v5,v6,v7,v8;
    reg [S-1:0] vt;
    reg [R-1:0] vr;
    reg [T-1:0] vtag;
    reg [N-1:0] vm;
    reg [A-1:0] va;
    reg [D-1:0] vd;
    reg [B-1:0] vs;
    reg [2047:0] vector_path,profile_name;

    integer cycle=0,active_frame=0,cursor=0,source_end=0,loaded_cursor=-1,source_gap=0;
    integer accepted=0,issued=0,acked=0,reads=0,writes=0,last_edge=-1,first_valid=-1;
    integer pending=-1,due=-1,token_reads=0,token_writes=0,owned=0;
    integer total_inputs=0,total_writes=0,total_reads=0,total_results=0;
    integer source_holds=0,output_holds=0,request_holds=0,response_waits=0,row_checks=0;
    integer q_hold_current=0,p_hold_current=0,m_hold=0,qwait=0,pwait=0;
    integer loaded_request=-1,q_remaining=0,ack_remaining=0,awaiting=0;
    integer auto_next=0,run_enabled=0,frame_done=0,frame_active=0;
    integer reset_mode=0,target_id=-1,pause_count=0,resets_done=0;
    integer queued_frames=0,offered_next=0;
    reg [R-1:0] expected_rows[0:N-1],expected_read;
    reg did_read;
    reg [10:0] states_seen=0;
    reg held_s,held_q,held_m;
    reg [S-1:0] old_s;
    reg [A+D+B-1:0] old_q;
    reg [5+T+C+N-1:0] old_m;
    integer old_state;

    // Sources advance only at real transfers. The peer can preoffer the actual
    // ACK while q is stalled; p_ready forbids acceptance before ownership.
    always @(negedge clk)begin
        if(rst)begin
            s_valid=0;q_ready=0;p_valid=0;m_ready=0;
            loaded_cursor=-1;loaded_request=-1;awaiting=0;
        end else begin
            if(run_enabled && cursor<source_end)begin
                if(reset_mode && target_id==1 && accepted>=1 && pause_count<4)s_valid=0;
                else begin
                    if(loaded_cursor!=cursor)begin loaded_cursor=cursor;source_gap=gap[cursor];s_valid=0;end
                    if(!s_valid)begin
                        if(source_gap>0)source_gap=source_gap-1;
                        else begin drive_word=tok[cursor];s_valid=1;end
                    end
                end
            end else s_valid=0;
            q_ready=0;p_valid=0;p_error=0;
            if(frame_active && !awaiting && issued<qc[active_frame])begin
                if(loaded_request!=issued)begin
                    loaded_request=issued;q_remaining=qstall[qo[active_frame]+issued];
                end
                if(q_valid)begin
                    if(q_remaining==0)q_ready=1;
                    else q_remaining=q_remaining-1;
                    if(adelay[qo[active_frame]+issued]==0)begin
                        p_valid=1;p_error=qe[qo[active_frame]+issued];
                    end
                end
            end
            if(awaiting)begin
                p_error=qe[qo[active_frame]+acked];
                if(ack_remaining==0)p_valid=1;
                else ack_remaining=ack_remaining-1;
            end
            m_ready=m_valid && m_hold>=4;
        end
    end

    always @(posedge clk)begin
        cycle=cycle+1;
        old_state=dut.state;
        held_s=s_valid && !s_ready && !rst;old_s=drive_word;
        held_q=q_valid && !q_ready && !rst;old_q={q_addr,q_data,q_strb};
        held_m=m_valid && !m_ready && !rst;old_m={m_status,m_tag,m_beats,m_error_mask};
        did_read=0;
        if(rst)begin
            frame_active=0;pending=-1;owned=0;accepted=0;issued=0;acked=0;
            awaiting=0;loaded_request=-1;q_hold_current=0;p_hold_current=0;
            m_hold=0;pause_count=0;offered_next=0;first_valid=-1;last_edge=-1;
        end else begin
            states_seen[dut.state]=1'b1;
            if(s_valid && !s_ready)source_holds=source_holds+1;
            if(s_valid && !s_ready && frame_active && accepted==length[active_frame])offered_next=1;
            if(held_q)begin request_holds=request_holds+1;q_hold_current=q_hold_current+1;qwait=qwait+1;end
            if(p_ready && !p_valid)begin response_waits=response_waits+1;p_hold_current=p_hold_current+1;pwait=pwait+1;end
            if(held_m)begin output_holds=output_holds+1;m_hold=m_hold+1;end
            if(reset_mode && target_id==1 && accepted==1 && dut.state==1 && !s_valid)pause_count=pause_count+1;

            if(s_valid && s_ready)begin
                if(cursor>=source_end || drive_word!==tok[cursor])$fatal(1,"source token mismatch");
                if(!frame_active)begin
                    if(cursor!=offset[active_frame])$fatal(1,"first token offset");
                    frame_active=1;accepted=0;issued=0;acked=0;reads=0;writes=0;
                    owned=0;first_valid=-1;last_edge=-1;qwait=0;pwait=0;
                    m_hold=0;offered_next=0;loaded_request=-1;
                end
                if(pending!=-1)$fatal(1,"new token before prior work complete");
                pending=cursor;token_reads=0;token_writes=0;due=cycle+ev_work[cursor];
                accepted=accepted+1;total_inputs=total_inputs+1;
                if(s_last)last_edge=cycle;
                cursor=cursor+1;
            end
            if(dut.state==2 || dut.state==7)begin
                if(dut.read_index>=owned)$fatal(1,"read unowned row");
                expected_read=expected_rows[dut.read_index];did_read=1;
                reads=reads+1;total_reads=total_reads+1;
                if(dut.state==2)begin
                    if(pending<0 || dut.scan_index!=token_reads)$fatal(1,"scan ownership/order");
                    token_reads=token_reads+1;
                end else if(last_edge<0 || es[active_frame]!=0 && es[active_frame]!=16)
                    $fatal(1,"flush before validated LAST");
            end
            if(dut.state==4 || dut.state==5)begin
                if(pending<0 || ev_write[pending]<0 || dut.write_index!=ev_write[pending])$fatal(1,"write schedule/index");
                if({dut.current_base,dut.merged_data,dut.merged_strobe}!==ev_row[pending])$fatal(1,"merged row value");
                expected_rows[ev_write[pending]]=ev_row[pending];
                if(dut.state==4)owned=owned+1;
                token_writes=token_writes+1;writes=writes+1;total_writes=total_writes+1;
            end
            if(q_valid)begin
                if(!frame_active || last_edge<0 || awaiting || issued>=qc[active_frame])$fatal(1,"request ownership");
                if({q_addr,q_data,q_strb}!=={qa[qo[active_frame]+issued],qd[qo[active_frame]+issued],qs[qo[active_frame]+issued]})
                    $fatal(1,"request fields frame=%0d issue=%0d",fid[active_frame],issued);
                if(q_strb==0)$fatal(1,"empty external write");
            end
            if(q_valid && q_ready)begin
                if(q_hold_current!=qstall[qo[active_frame]+issued])$fatal(1,"q wait count");
                $display("WRITE %0d %0d %h %h %h",fid[active_frame],issued,q_addr,q_data,q_strb);
                awaiting=1;ack_remaining=adelay[qo[active_frame]+issued];issued=issued+1;
                q_hold_current=0;p_hold_current=0;
            end
            if(p_valid && p_ready)begin
                if(!awaiting || acked>=issued || p_error!==qe[qo[active_frame]+acked][0])$fatal(1,"ACK ownership/value");
                if(p_hold_current!=adelay[qo[active_frame]+acked])$fatal(1,"ACK wait count");
                $display("ACK %0d %0d %0d",fid[active_frame],acked,p_error);
                acked=acked+1;awaiting=0;p_hold_current=0;loaded_request=-1;
            end
            if(m_valid)begin
                if(!frame_active || accepted!=length[active_frame] || pending!=-1)$fatal(1,"premature/stale result");
                if(m_status!==es[active_frame][4:0] || m_tag!==etag[active_frame] ||
                   m_beats!==qc[active_frame] || m_error_mask!==emask[active_frame])$fatal(1,"result fields frame=%0d",fid[active_frame]);
            end
            if(m_valid && m_ready)begin
                if(issued!=qc[active_frame] || acked!=qc[active_frame] || awaiting)$fatal(1,"incomplete ACK set");
                if(reads!=er[active_frame] || writes!=ew[active_frame] || qwait+pwait!=exwait[active_frame])$fatal(1,"frame operation/wait totals");
                if(first_valid-last_edge!=elat[active_frame])$fatal(1,"exact latency frame=%0d got=%0d expected=%0d",fid[active_frame],first_valid-last_edge,elat[active_frame]);
                if(m_hold!=4)$fatal(1,"result hold schedule");
                $display("RESULT %0d %0d %h %0d %h %0d %0d %0d %0d",fid[active_frame],m_status,m_tag,m_beats,m_error_mask,first_valid-last_edge,reads,writes,accepted);
                if(offered_next)queued_frames=queued_frames+1;
                total_results=total_results+1;frame_done=1;frame_active=0;
                if(auto_next && active_frame+1<main_count)begin active_frame=active_frame+1;frame_done=0;end
            end
        end
        #1;
        if(rst)begin
            if(s_ready || q_valid || p_ready || m_valid)$fatal(1,"reset gating");
        end else begin
            if(did_read && dut.row_q!==expected_read)$fatal(1,"synchronous read value");
            for(k=0;k<owned;k=k+1)begin
                if(dut.rows[k]!==expected_rows[k])$fatal(1,"owned row mismatch frame=%0d row=%0d",fid[active_frame],k);
                row_checks=row_checks+1;
            end
            if(pending!=-1 && cycle==due)begin
                if(token_reads!=ev_reads[pending] || token_writes!=(ev_write[pending]>=0))$fatal(1,"per-token operation certificate");
                if(dut.count!=ev_count[pending] || dut.frame_errors!=ev_error[pending])$fatal(1,"post-token count/errors");
                pending=-1;
            end
            if(m_valid && first_valid<0)begin
                first_valid=cycle;
                if(last_edge<0 || cycle-last_edge!=elat[active_frame])$fatal(1,"first-valid latency frame=%0d got=%0d expected=%0d",fid[active_frame],cycle-last_edge,elat[active_frame]);
                $display("VALID %0d %0d %h %0d %h %0d",fid[active_frame],m_status,m_tag,m_beats,m_error_mask,cycle-last_edge);
            end
            if(held_s && drive_word!==old_s)$fatal(1,"input hold fields");
            if(held_q && (!q_valid || {q_addr,q_data,q_strb}!==old_q))$fatal(1,"request hold fields");
            if(held_m && (!m_valid || {m_status,m_tag,m_beats,m_error_mask}!==old_m))$fatal(1,"result hold fields");
        end
    end

    function automatic integer target_matches;
        input integer id;
        begin
            case(id)
                0:target_matches=dut.state==0;
                1:target_matches=dut.state==1 && accepted==1 && pause_count>=4;
                2:target_matches=dut.state==4 && dut.count==0;
                3:target_matches=dut.state==4 && dut.count==CAP-1;
                4,5,6:target_matches=dut.state==2 && dut.scan_index==(id==4?0:id==5?MID:CAP-1);
                7,8,9:target_matches=dut.state==3 && dut.scan_index==(id==7?0:id==8?MID:CAP-1);
                10,11:target_matches=dut.state==5 && dut.scan_index==(id==10?0:CAP-1);
                12:target_matches=dut.state==6 && dut.count==CAP && dut.frame_errors==0;
                13,14,15:target_matches=dut.state==7 && dut.out_index==(id==13?0:id==14?MID:CAP-1);
                16,17:target_matches=dut.state==8 && dut.out_index==(id==16?0:CAP-1) && q_hold_current>=2;
                18,19:target_matches=dut.state==9 && dut.out_index==(id==18?0:CAP-1) && p_hold_current>=2;
                20:target_matches=dut.state==9 && dut.out_index==1 && dut.error_mask[0] && p_hold_current>=1;
                21:target_matches=dut.state==10 && m_status==0 && m_hold>=3;
                22:target_matches=dut.state==10 && m_status==16 && m_hold>=3;
                23:target_matches=dut.state==1 && dut.frame_errors[0];
                24:target_matches=dut.state==1 && dut.frame_errors[1];
                25:target_matches=dut.state==1 && dut.frame_errors[2];
                default:target_matches=0;
            endcase
        end
    endfunction

    task automatic start_one;
        input integer index;
        begin
            active_frame=index;cursor=offset[index];source_end=offset[index]+length[index];
            loaded_cursor=-1;loaded_request=-1;frame_done=0;frame_active=0;
            accepted=0;issued=0;acked=0;pending=-1;owned=0;pause_count=0;
            reads=0;writes=0;first_valid=-1;last_edge=-1;qwait=0;pwait=0;
            token_reads=0;token_writes=0;offered_next=0;
            awaiting=0;m_hold=0;q_hold_current=0;p_hold_current=0;run_enabled=1;
        end
    endtask
    task automatic guard_idle;
        integer z;
        begin
            run_enabled=0;
            for(z=0;z<5;z=z+1)begin @(posedge clk);#2;
                if(m_valid || q_valid || p_ready || !s_ready)$fatal(1,"stale result/idle state");
            end
        end
    endtask

    integer rindex,watchdog;
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path) || !$value$plusargs("PROFILE=%s",profile_name))$fatal(1,"missing fixture path");
        fd=$fopen(vector_path,"r");if(fd==0)$fatal(1,"fixture open");
        rc=$fscanf(fd,"%d %d %d %d %d",main_count,reset_count,frame_count,token_count,request_count);
        if(rc!=5 || frame_count>256 || token_count>65536 || request_count>8192)$fatal(1,"fixture dimensions");
        for(j=0;j<reset_count;j=j+1)begin rc=$fscanf(fd,"%d",v0);if(rc!=1)$fatal(1,"target parse");target_ids[j]=v0;end
        for(f=0;f<frame_count;f=f+1)begin
            rc=$fscanf(fd,"%d %d %d %h %d %h %d %d %d %d %d",v0,v1,v2,vtag,v3,vm,v4,v5,v6,v7,v8);
            if(rc!=11)$fatal(1,"frame parse");
            fid[f]=v0;length[f]=v1;es[f]=v2;etag[f]=vtag;qc[f]=v3;emask[f]=vm;
            er[f]=v4;ew[f]=v5;eh[f]=v6;exwait[f]=v7;elat[f]=v8;offset[f]=tp;qo[f]=qp;
            for(j=0;j<length[f];j=j+1)begin
                rc=$fscanf(fd,"%h %d %d %d %h %d %d %d",vt,v0,v1,v2,vr,v3,v4,v5);
                if(rc!=8)$fatal(1,"input/event parse");
                tok[tp]=vt;gap[tp]=v0;ev_reads[tp]=v1;ev_write[tp]=v2;ev_row[tp]=vr;
                ev_count[tp]=v3;ev_error[tp]=v4;ev_work[tp]=v5;tp=tp+1;
            end
            for(j=0;j<qc[f];j=j+1)begin
                rc=$fscanf(fd,"%h %h %h %d %d %d",va,vd,vs,v0,v1,v2);
                if(rc!=6)$fatal(1,"request parse");
                qa[qp]=va;qd[qp]=vd;qs[qp]=vs;qe[qp]=v0;qstall[qp]=v1;adelay[qp]=v2;qp=qp+1;
            end
        end
        if(tp!=token_count || qp!=request_count)$fatal(1,"parsed dimensions");
        $fclose(fd);
        repeat(2)@(posedge clk);
        @(negedge clk);#2;rst=0;auto_next=1;start_one(0);
        source_end=offset[main_count-1]+length[main_count-1];
        wait(frame_done);#2;auto_next=0;guard_idle();
        for(rindex=0;rindex<reset_count;rindex=rindex+1)begin
            @(negedge clk);#2;reset_mode=1;target_id=target_ids[rindex];
            start_one(main_count+2*rindex);
            watchdog=0;
            while(!target_matches(target_id))begin
                @(posedge clk);#2;watchdog=watchdog+1;
                if(watchdog>1000000 || frame_done)$fatal(1,"reset target not reached id=%0d",target_id);
            end
            $display("OBS %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",target_id,dut.state,dut.scan_index,dut.out_index,accepted,reads,writes,issued,acked,q_hold_current,p_hold_current);
            rst=1;run_enabled=0;
            #1;if(s_ready || q_valid || p_ready || m_valid)$fatal(1,"immediate reset gating");
            repeat(2)@(posedge clk);
            @(negedge clk);#2;reset_mode=0;target_id=-1;rst=0;
            start_one(main_count+2*rindex+1);
            wait(frame_done);#2;
            if(m_beats!=CAP)$fatal(1,"fresh reachable capacity");
            guard_idle();resets_done=resets_done+1;
        end
        if(resets_done!=reset_count || total_results!=main_count+reset_count || states_seen!=11'h7ff)$fatal(1,"final coverage totals");
        $display("PASS profile=%0s main=%0d resets=%0d results=%0d inputs=%0d reads=%0d writes=%0d rows=%0d source_holds=%0d output_holds=%0d q_holds=%0d p_waits=%0d queued=%0d state_mask=%h",
                 profile_name,main_count,resets_done,total_results,total_inputs,total_reads,total_writes,row_checks,source_holds,output_holds,request_holds,response_waits,queued_frames,states_seen);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"finite cycle watchdog");end
endmodule
