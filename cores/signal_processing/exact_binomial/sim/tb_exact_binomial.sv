// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_exact_binomial;
    parameter integer MAX_N=32,TAG_W=8,CYCLE_LIMIT=500000;
    localparam integer KMAX=MAX_N/2;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid;
    reg [63:0] s_n=0,s_k=0;
    reg [TAG_W-1:0] s_tag=0;
    wire [MAX_N-1:0] m_value;wire m_error;wire [TAG_W-1:0] m_tag;
    exact_binomial #(.MAX_N(MAX_N),.TAG_W(TAG_W)) dut(.*);
    reg [63:0] nn[0:255],kk[0:255],xx[0:255];reg [31:0] tt[0:255];integer ee[0:255];
    reg [63:0] pn[0:24],pk[0:24],px[0:24],fn[0:24],fk[0:24],fx[0:24];
    reg [31:0] pt[0:24],ft[0:24];integer pe[0:24],fe[0:24];
    reg [MAX_N-1:0] shadow[0:KMAX];integer owner[0:KMAX],epoch=0;
    reg [MAX_N-1:0] expected_read;
    integer read_pending=0,read_address=0,ram_checks=0,shadow_checks=0;
    integer nvec=0,source_index=0,done=0,accepted=0,queued=0,queued_pending=0,advance=0;
    integer phase=1,cycle=0,active=0,active_id=0,accept_cycle=0,first_seen=0,out_age=0;
    reg [63:0] in_n,in_k,expected_value;
    reg [TAG_W-1:0] in_tag;integer expected_error,work_k,compute;
    integer cells=0,inits=0,reads=0,rowsets=0,total_cells=0,total_inits=0,total_reads=0;
    integer source_holds=0,output_holds=0,latency_checks=0,max_latency=0;
    integer state_mask=0,error_mask=0,resets=0,fresh=0,fresh_done=0,fresh_accepted=0;
    integer previous_source_hold=0,previous_output_hold=0;
    reg [127+TAG_W:0] old_source;reg [MAX_N+TAG_W:0] old_output;
    integer probe_hold=0,target=0,guard,alias_target,probe_row,probe_j,probe_k;
    integer file_id,trace_file,rc,rid,j,expected_latency,update_count;
    reg [1023:0] fixture_path,trace_path;reg [63:0] mode;

    always @(negedge clk)begin
        if(!rst && phase==0)begin
            if(advance)begin source_index=source_index+1;advance=0;s_valid=0;end
            if(!s_valid && source_index<nvec)begin s_n=nn[source_index];s_k=kk[source_index];s_tag=tt[source_index];s_valid=1;end
        end
        if(phase==0 || phase==2)m_ready=(out_age>=4 && cycle%5!=1);else m_ready=0;
    end

    always @(posedge clk)begin
        cycle=cycle+1;read_pending=0;
        if(cycle>CYCLE_LIMIT)$fatal(1,"frozen cycle budget exceeded");
        if(rst)begin active=0;first_seen=0;out_age=0;previous_source_hold=0;previous_output_hold=0;end
        else begin
            state_mask=state_mask|(1<<dut.state);
            if(s_valid && s_ready)epoch=epoch+1;
            if(dut.state==1)begin shadow[dut.j]=(dut.j==0)?1:0;owner[dut.j]=epoch;end
            if(dut.state==5)begin
                if(dut.sum_extended[MAX_N]!==0)$fatal(1,"unexpected arithmetic carry");
                shadow[dut.j]=dut.sum_extended[MAX_N-1:0];owner[dut.j]=epoch;
            end
            if(dut.state==3 || dut.state==4 || dut.state==6)begin
                read_address=(dut.state==3)?dut.j:((dut.state==4)?dut.j-1:dut.k);
                if(read_address<0 || read_address>KMAX || owner[read_address]!==epoch)$fatal(1,"unowned Pascal RAM read");
                expected_read=shadow[read_address];read_pending=1;
            end
            if(phase==0 || phase==2)begin
                if(previous_source_hold)begin
                    if(!s_valid || {s_n,s_k,s_tag}!==old_source)$fatal(1,"real next token changed before acceptance");
                    source_holds=source_holds+1;
                end
                if(previous_output_hold)begin
                    if(!m_valid || {m_value,m_error,m_tag}!==old_output)$fatal(1,"all-field output hold");
                    output_holds=output_holds+1;
                end
                previous_source_hold=s_valid&&!s_ready;old_source={s_n,s_k,s_tag};
                previous_output_hold=m_valid&&!m_ready;old_output={m_value,m_error,m_tag};
                if(active && s_ready)$fatal(1,"input ready while owned");
                if(phase==0 && s_valid && !s_ready)queued_pending=1;
                if(s_valid && s_ready)begin
                    if(active)$fatal(1,"overlapping owners");
                    active=1;accept_cycle=cycle;first_seen=0;in_n=s_n;in_k=s_k;in_tag=s_tag;
                    compute=(s_n<=MAX_N && s_k<=s_n && s_k!=0 && s_k!=s_n);
                    work_k=compute?((s_k<s_n-s_k)?s_k:s_n-s_k):0;
                    cells=0;inits=0;reads=0;rowsets=0;
                    if(phase==0)begin
                        active_id=source_index;expected_value=xx[source_index];expected_error=ee[source_index];
                        if(source_index>0)begin if(!queued_pending)$fatal(1,"next actual token never queued");queued=queued+1;end
                        queued_pending=0;accepted=accepted+1;advance=1;
                    end else begin active_id=target;expected_value=fx[target];expected_error=fe[target];fresh_accepted=1;end
                end
                if(active)begin
                    if(dut.state==1)begin
                        inits=inits+1;total_inits=total_inits+1;
                        $fdisplay(trace_file,"I %0d %0d %0h",active_id,dut.j,(dut.j==0)?1:0);
                    end
                    if(dut.state==2)rowsets=rowsets+1;
                    if(read_pending)begin reads=reads+1;total_reads=total_reads+1;end
                    if(dut.state==5)begin
                        cells=cells+1;total_cells=total_cells+1;
                        $fdisplay(trace_file,"U %0d %0d %0d %0h %0h %0h",active_id,dut.row,dut.j,dut.current,dut.row_q,dut.sum_extended);
                    end
                end
                if(m_valid && m_ready)begin
                    if(!active)$fatal(1,"unowned retirement");active=0;
                    if(phase==0)done=done+1;else begin fresh=fresh+1;fresh_done=1;end
                end
            end else begin
                previous_source_hold=0;previous_output_hold=0;out_age=0;
                if(m_valid)probe_hold=probe_hold+1;
            end
            #1;
            if(read_pending)begin if(dut.row_q!==expected_read)$fatal(1,"synchronous RAM read");ram_checks=ram_checks+1;end
            if((phase==0 || phase==2) && m_valid)begin
                if(!active)$fatal(1,"ghost output");
                if(m_value!==expected_value[MAX_N-1:0] || m_error!==expected_error[0] || m_tag!==in_tag)
                    $fatal(1,"binomial result id=%0d N=%0h K=%0h got=%0h/%0d expected=%0h/%0d",active_id,in_n,in_k,m_value,m_error,expected_value,expected_error);
                if(!first_seen)begin
                    first_seen=1;latency_checks=latency_checks+1;error_mask=error_mask|(1<<m_error);
                    update_count=work_k*in_n-work_k*(work_k-1)/2;
                    expected_latency=compute?in_n+work_k+3+3*update_count:0;
                    if(cycle-accept_cycle!=expected_latency || cells!=(compute?update_count:0) ||
                       inits!=(compute?work_k+1:0) || reads!=(compute?2*cells+1:0) || rowsets!=(compute?in_n:0))$fatal(1,"exact schedule");
                    if(cycle-accept_cycle>max_latency)max_latency=cycle-accept_cycle;
                    $fwrite(trace_file,"O %0d %0h %0h %0h %0h %0d %0d %0d %0d %0d %0d %0d",active_id,in_n,in_k,in_tag,m_value,m_error,
                        cycle-accept_cycle,cells,inits,reads,rowsets,work_k);
                    if(compute)for(j=0;j<=work_k;j=j+1)begin
                        if(owner[j]!==epoch || dut.coef[j]!==shadow[j])$fatal(1,"final owned row image");
                        shadow_checks=shadow_checks+1;$fwrite(trace_file," %0h",dut.coef[j]);
                    end
                    $fwrite(trace_file,"\n");
                end
                out_age=out_age+1;
            end else if(phase==0 || phase==2)out_age=0;
            if(phase==1 && m_valid && (m_value!==px[target][MAX_N-1:0] || m_error!==pe[target][0] || m_tag!==pt[target][TAG_W-1:0]))
                $fatal(1,"reset owner output fixture mismatch");
        end
    end

    function integer is_alias(input integer t);
        begin is_alias=(MAX_N==1 && ((t>=1 && t<=15)||(t>=21 && t<=24))) || (MAX_N==2 && (t==22 || t==23));end
    endfunction
    function integer at_target(input integer t);
        begin
            at_target=0;
            if(MAX_N==1 && is_alias(t))at_target=m_valid && !m_error && probe_hold>=3;
            else case(t)
                0:at_target=dut.state==0;
                1:at_target=dut.state==1 && dut.j==0;
                2:at_target=dut.state==1 && dut.j==dut.k;
                3:at_target=dut.state==2 && dut.row==1;
                4,5,6:at_target=dut.state==t-1 && dut.row==1 && dut.j==1;
                7,8,9:at_target=dut.state==t-4 && dut.row==dut.n && dut.j==dut.k;
                10,11,12:at_target=dut.state==t-7 && dut.row==dut.n && dut.j==1;
                13:at_target=dut.state==6;
                14:at_target=dut.state==7;
                15,16,17,18,19,20:at_target=m_valid && probe_hold>=3;
                21:at_target=dut.state==2 && dut.row==dut.k+1;
                22:at_target=dut.state==1 && dut.j==((MAX_N==2)?dut.k:(dut.k>>1));
                23:at_target=dut.state==5 && ((MAX_N==2)?(dut.row==dut.n && dut.j==1):(dut.row>=3 && dut.j>=2));
                24:at_target=m_valid && probe_hold==0;
            endcase
        end
    endfunction

    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture_path) || !$value$plusargs("TRACE=%s",trace_path) || !$value$plusargs("MODE=%s",mode))$fatal(1,"paths/mode required");
        file_id=$fopen(fixture_path,"r");trace_file=$fopen(trace_path,"w");if(!file_id || !trace_file)$fatal(1,"file open");
        if(mode=="main")begin
            while(!$feof(file_id))begin
                rc=$fscanf(file_id,"%h %h %h %h %d\n",nn[nvec],kk[nvec],tt[nvec],xx[nvec],ee[nvec]);
                if(rc==5)nvec=nvec+1;else if(rc!=-1)$fatal(1,"main parse");
            end
            if(nvec<1 || nvec>128)$fatal(1,"fixed group size");
        end else if(mode=="reset")begin
            for(target=0;target<25;target=target+1)begin
                rc=$fscanf(file_id,"%d %h %h %h %h %d %h %h %h %h %d\n",rid,pn[target],pk[target],pt[target],px[target],pe[target],fn[target],fk[target],ft[target],fx[target],fe[target]);
                if(rc!=11 || rid!=target)$fatal(1,"reset parse");
            end
        end else $fatal(1,"unknown mode");
        $fclose(file_id);repeat(2)@(negedge clk);rst=0;
        if(mode=="main")begin
            phase=0;while(done<nvec)@(negedge clk);phase=1;s_valid=0;m_ready=0;
            if(accepted!=nvec || queued!=nvec-1)$fatal(1,"main accounting");
        end else begin
            for(target=0;target<25;target=target+1)begin
                @(negedge clk);probe_hold=0;
                s_n=pn[target];s_k=pk[target];s_tag=pt[target];s_valid=(target!=0);m_ready=0;
                @(posedge clk);#2;s_valid=0;guard=0;
                while(!at_target(target))begin
                    @(posedge clk);#2;guard=guard+1;if(guard>4755+8)$fatal(1,"unreached reset target %0d",target);
                end
                probe_row=-1;probe_j=-1;probe_k=-1;
                if(dut.state>=1 && dut.state<=7)begin probe_row=(dut.state==1)?0:dut.row;probe_j=dut.j;probe_k=dut.k;end
                alias_target=is_alias(target);
                $fdisplay(trace_file,"X %0d %0d %0d %0d %0d %0d %0d",target,dut.state,probe_row,probe_j,probe_k,probe_hold,alias_target);
                rst=1;#1;if(s_ready!==0 || m_valid!==0)$fatal(1,"immediate reset gate");
                @(posedge clk);#2;if(dut.state!==0 || m_value!==0 || m_error!==0 || m_tag!==0 || m_valid!==0)$fatal(1,"reset cancellation/public clear");
                resets=resets+1;@(negedge clk);rst=0;phase=2;fresh_done=0;fresh_accepted=0;
                s_n=fn[target];s_k=fk[target];s_tag=ft[target];s_valid=1;
                while(!fresh_accepted)@(negedge clk);s_valid=0;
                while(!fresh_done)@(negedge clk);phase=1;m_ready=0;
            end
            if(resets!=25 || fresh!=25)$fatal(1,"reset/fresh accounting");
        end
        $fclose(trace_file);
        $display("PASS mode=%0s N=%0d TAG=%0d frames=%0d queued=%0d resets=%0d fresh=%0d cells=%0d inits=%0d reads=%0d ram_checks=%0d shadow_checks=%0d source_holds=%0d output_holds=%0d latency_checks=%0d max_latency=%0d states=%0h errors=%0h cycles=%0d",
            mode,MAX_N,TAG_W,(mode=="main")?nvec:25,queued,resets,fresh,total_cells,total_inits,total_reads,ram_checks,shadow_checks,
            source_holds,output_holds,latency_checks,max_latency,state_mask,error_mask,cycle);
        $finish;
    end
endmodule
