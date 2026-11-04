// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_exact_binary_permanent;
    parameter integer N=8,T=8,MAX_FRAMES=1,MAX_INPUTS=32,CYCLE_LIMIT=1000000;
    function automatic integer fact(input integer x);
        integer k;begin fact=1;for(k=2;k<=x;k=k+1)fact=fact*k;end
    endfunction
    localparam integer V=$clog2(fact(N)+1),C=$clog2(N+1),D=1<<N,IB=N+3+T,OB=V+3+C+T;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,s_error=0,m_ready=0;
    reg [N-1:0] s_row=0;reg [T-1:0] s_tag=0;
    wire s_ready,m_valid;wire [V-1:0] m_value;wire [2:0] m_error;wire [C-1:0] m_rows;wire [T-1:0] m_tag;
    exact_binary_permanent #(.N(N),.TAG_W(T)) dut(.*);
    wire [IB-1:0] command={s_row,s_keep,s_last,s_error,s_tag};
    wire [OB-1:0] payload={m_value,m_error,m_rows,m_tag};
    reg [IB-1:0] tokens[0:MAX_INPUTS-1],old_tokens[0:4*N+15],fresh_tokens[0:4*N+15];
    reg [OB-1:0] expected[0:MAX_FRAMES-1],fresh_expected;
    integer frame_start[0:MAX_FRAMES-1],frame_latency[0:MAX_FRAMES-1],frame_reads[0:MAX_FRAMES-1];
    reg [V-1:0] gold[0:MAX_FRAMES*D-1],fresh_gold[0:D-1];
    reg [N-1:0] owned_rows=0,shadow_rows[0:N-1];
    reg [D-1:0] owned_dp=0;reg [V-1:0] shadow_dp[0:D-1];
    reg cp=0,mp=0,cfire,mfire,read_row_pending,read_dp_pending,write_row_pending,write_dp_pending;
    reg [IB-1:0] chold;reg [OB-1:0] mhold;
    reg [N-1:0] expected_row;reg [V-1:0] expected_dp,write_dp_value;
    integer row_address,dp_address,write_row_address,write_dp_address;
    integer mode,phase=3,fd,rd,fr,r,nframes,ntokens=0,fresh_inputs,fresh_latency,fresh_reads;
    integer cycles=0,frames=0,outputs=0,queued=0,resets=0,fresh=0,latency_checks=0;
    integer source_holds=0,output_holds=0,ram_reads=0,row_writes=0,dp_writes=0,dp_certificates=0,bank_checks=0;
    integer si=0,oi=0,ai=0,active=0,offer_frame=0,output_age=0,tail_cycle=0,first_seen=0;
    integer current_reads=0,current_row_reads=0,current_writes=0,current_inits=0,write_cursor=1;
    integer target,old_count,old_cursor,number,q,j,k,hold_target,ref_latency;
    reg [10:0] states=0;
    reg [31:0] reset_mask=0;
    string fixture_path,fresh_path;
    longint signed a,b,c,d,e,f,g,h;
    task parse_token(input integer fileid,output reg [IB-1:0] value);
        begin
            r=$fscanf(fileid,"%d %d %d %d %d",a,b,c,d,e);if(r!=5)$fatal(1,"token parse");
            value={N'(a),1'(b),1'(c),1'(d),T'(e)};
        end
    endtask
    task check_image(input integer which);
        integer x;reg [V-1:0] wanted;
        begin
            if(owned_rows!=={N{1'b1}} || owned_dp!=={D{1'b1}})$fatal(1,"complete ownership");
            for(x=0;x<N;x=x+1)if(dut.rows[x]!==shadow_rows[x])$fatal(1,"whole captured row");
            for(x=0;x<D;x=x+1)begin
                wanted=which==2?fresh_gold[x]:gold[active*D+x];
                if(dut.dp[x]!==wanted)$fatal(1,"whole Ryser minor image mask=%0d",x);bank_checks=bank_checks+1;
            end
        end
    endtask
    task tick;
        reg [V-1:0] wanted;
        begin
            @(posedge clk);cfire=s_valid && s_ready;mfire=m_valid && m_ready;
            read_row_pending=0;read_dp_pending=0;write_row_pending=0;write_dp_pending=0;
            if(rst)begin cp=0;mp=0;owned_rows=0;owned_dp=0;end
            else begin
                cycles=cycles+1;if(cycles>CYCLE_LIMIT)$fatal(1,"frozen cycle limit");states[dut.state]=1;
                if(cp)begin if(!s_valid || command!==chold)$fatal(1,"source all-field hold");source_holds=source_holds+1;end
                if(mp)begin if(!m_valid || payload!==mhold)$fatal(1,"output all-field hold");output_holds=output_holds+1;end
                cp=s_valid && !s_ready;chold=command;mp=m_valid && !m_ready;mhold=payload;
                if(cfire && !dut.started)begin owned_rows=0;owned_dp=0;end
                if(cfire && s_keep && dut.count<N)begin
                    owned_rows[dut.count]=1;shadow_rows[dut.count]=s_row;
                    write_row_pending=1;write_row_address=dut.count;expected_row=s_row;row_writes=row_writes+1;
                end
                if(cfire && s_last && (phase==0 || phase==2))begin
                    active=phase==0?ai:0;if(phase==0)begin ai=ai+1;frames=frames+1;end
                    tail_cycle=cycles;first_seen=0;current_reads=0;current_row_reads=0;current_writes=0;current_inits=0;
                end
                if(dut.count>N)$fatal(1,"saturated captured rows");
                if(dut.state==3)begin
                    row_address=dut.row_number;
                    if(row_address<0 || row_address>=N || !owned_rows[row_address])$fatal(1,"owned row read");
                    expected_row=shadow_rows[row_address];read_row_pending=1;ram_reads=ram_reads+1;current_row_reads=current_row_reads+1;
                end
                if(dut.state==1)begin
                    owned_dp[0]=1;shadow_dp[0]=V'(1);write_cursor=1;current_inits=current_inits+1;
                    write_dp_pending=1;write_dp_address=0;write_dp_value=V'(1);dp_writes=dp_writes+1;
                    if(phase==0 || phase==2)begin
                        wanted=phase==2?fresh_gold[0]:gold[active*D];if(wanted!==V'(1))$fatal(1,"Ryser empty minor");dp_certificates=dp_certificates+1;
                    end
                end
                if(dut.state==5 || dut.state==8)begin
                    dp_address=dut.state==8?D-1:dut.predecessor;
                    if(dp_address<0 || dp_address>=D || !owned_dp[dp_address])$fatal(1,"owned DP read");
                    if(dut.state==5 && dp_address>=dut.mask)$fatal(1,"strict previous-mask dependency");
                    expected_dp=shadow_dp[dp_address];read_dp_pending=1;ram_reads=ram_reads+1;current_reads=current_reads+1;
                end
                if(dut.state==6 && dut.widened_sum[V]!==0)$fatal(1,"proven factorial carry bound");
                if(dut.state==7)begin
                    if(dut.mask!=write_cursor)$fatal(1,"complete ascending DP write schedule");write_cursor=write_cursor+1;
                    owned_dp[dut.mask]=1;shadow_dp[dut.mask]=dut.acc;
                    write_dp_pending=1;write_dp_address=dut.mask;write_dp_value=dut.acc;dp_writes=dp_writes+1;current_writes=current_writes+1;
                    if(phase==0 || phase==2)begin
                        wanted=phase==2?fresh_gold[dut.mask]:gold[active*D+dut.mask];
                        if(dut.acc!==wanted)$fatal(1,"independent Ryser prefix-minor mask=%0d actual=%0d expected=%0d",dut.mask,dut.acc,wanted);
                        dp_certificates=dp_certificates+1;
                    end
                end
                if(mfire && phase==0)begin if(oi>=nframes || payload!==expected[oi])$fatal(1,"all result fields");oi=oi+1;outputs=outputs+1;end
            end
            #2;
            if(read_row_pending && dut.row_q!==expected_row)$fatal(1,"registered row read");
            if(read_dp_pending && dut.dp_q!==expected_dp)$fatal(1,"registered DP read");
            if(write_row_pending && dut.rows[write_row_address]!==expected_row)$fatal(1,"captured row write");
            if(write_dp_pending && dut.dp[write_dp_address]!==write_dp_value)$fatal(1,"single-port DP write");
            if(!rst && (phase==0 || phase==2) && m_valid && !first_seen)begin
                first_seen=1;ref_latency=phase==2?fresh_latency:frame_latency[active];
                if(cycles-tail_cycle!=ref_latency)$fatal(1,"exact first-valid latency actual=%0d expected=%0d",cycles-tail_cycle,ref_latency);
                if(payload!==(phase==2?fresh_expected:expected[active]))$fatal(1,"first-valid payload");latency_checks=latency_checks+1;
                if(m_error==0)begin
                    if(current_inits!=1 || current_row_reads!=D-1 || current_writes!=D-1 || current_reads!=(phase==2?fresh_reads:frame_reads[active])+1)$fatal(1,"exact RAM schedule");
                    check_image(phase);
                end else if(current_inits || current_reads || current_row_reads || current_writes)$fatal(1,"error performed computation");
            end
        end
    endtask
    function automatic integer effective(input integer id);
        begin
            effective=id;
            if(N==1)case(id)
                3:effective=2;12:effective=6;13:effective=7;14:effective=8;15:effective=9;16:effective=10;
                17:effective=11;27:effective=8;28:effective=11;29:effective=9;
                default:effective=id;
            endcase
            else if(N==2 && id==28)effective=17;
        end
    endfunction
    function automatic bit hit(input integer original);
        integer id;
        begin
            id=effective(original);hit=0;
            case(id)
                0:hit=dut.state==0 && !dut.started;
                1:hit=dut.state==0 && dut.started && dut.count==0;
                2:hit=dut.state==0 && dut.count==1;
                3:hit=dut.state==0 && dut.count==N;
                4:hit=dut.state==0 && dut.errors[1];
                5:hit=dut.state==1;
                6:hit=dut.state==2 && dut.mask==1;
                7:hit=dut.state==3 && dut.mask==1;
                8:hit=dut.state==4 && dut.mask==1 && dut.column==0;
                9:hit=dut.state==5 && dut.mask==1 && dut.column==0;
                10:hit=dut.state==6 && dut.mask==1 && dut.column==0;
                11:hit=dut.state==7 && dut.mask==1;
                12:hit=dut.state==2 && dut.mask==D-1;
                13:hit=dut.state==3 && dut.mask==D-1;
                14:hit=dut.state==4 && dut.mask==D-1 && dut.column==N-1;
                15:hit=dut.state==5 && dut.mask==D-1 && dut.column==N-1;
                16:hit=dut.state==6 && dut.mask==D-1 && dut.column==N-1;
                17:hit=dut.state==7 && dut.mask==D-1;
                18:hit=dut.state==8;
                19:hit=dut.state==9;
                20,21:hit=dut.state==10 && m_error==0 && m_value==fact(N);
                22:hit=dut.state==10 && m_error==1;
                23:hit=dut.state==10 && m_error==2;
                24:hit=dut.state==10 && m_error==4;
                25:hit=dut.state==10 && m_error==5;
                26:hit=dut.state==10 && m_error==6;
                27:hit=dut.state==4 && dut.mask==3 && dut.column==1;
                28:hit=dut.state==7 && dut.mask==3;
                29:hit=dut.state==5 && dut.mask==3 && dut.column==0;
                30,31:hit=dut.state==10 && m_error==0 && m_value==0;
                default:hit=0;
            endcase
        end
    endfunction
    task recover;
        integer cursor,age;
        begin
            phase=2;cursor=0;age=0;
            while(!m_valid)begin
                if(!s_valid && cursor<fresh_inputs){s_row,s_keep,s_last,s_error,s_tag,s_valid}={fresh_tokens[cursor],1'b1};
                tick();if(cfire)begin cursor=cursor+1;s_valid=0;end
            end
            if(cursor!=fresh_inputs || payload!==fresh_expected)$fatal(1,"full-capacity fresh input/result");
            repeat(3)tick();m_ready=1;tick();if(!mfire)$fatal(1,"fresh actual retirement");m_ready=0;
            if(m_valid || !s_ready)$fatal(1,"fresh complete idle");fresh=fresh+1;phase=3;
        end
    endtask
    initial begin
        if(!$value$plusargs("MODE=%d",mode) || !$value$plusargs("FIXTURE=%s",fixture_path))$fatal(1,"arguments");
        fd=$fopen(fixture_path,"r");if(!fd)$fatal(1,"fixture open");
        if(mode==0)begin
            r=$fscanf(fd,"%d",nframes);if(r!=1 || nframes>MAX_FRAMES)$fatal(1,"main allocation");
            for(q=0;q<nframes;q=q+1)begin
                r=$fscanf(fd,"%d %d %d %d %d %d %d %d",a,b,c,d,e,f,g,h);if(r!=8)$fatal(1,"header parse");
                number=a;frame_start[q]=ntokens;expected[q]={V'(b),3'(c),C'(d),T'(e)};frame_latency[q]=f;frame_reads[q]=g;
                if(h!=0 && h!=D)$fatal(1,"certificate allocation");
                for(k=0;k<number;k=k+1)begin if(ntokens>=MAX_INPUTS)$fatal(1,"input allocation");parse_token(fd,tokens[ntokens]);ntokens=ntokens+1;end
                for(k=0;k<h;k=k+1)begin r=$fscanf(fd,"%d",a);if(r!=1)$fatal(1,"minor parse");gold[q*D+k]=V'(a);end
            end
            $fclose(fd);tick();rst=0;phase=0;
            while(oi<nframes)begin
                if(!s_valid && si<ntokens && cycles%7!=3)begin
                    if(offer_frame<nframes && si==frame_start[offer_frame])begin
                        if(offer_frame>0 && !s_ready)queued=queued+1;offer_frame=offer_frame+1;
                    end
                    {s_row,s_keep,s_last,s_error,s_tag,s_valid}={tokens[si],1'b1};
                end
                if(m_valid)begin m_ready=output_age>=3;output_age=output_age+1;end else begin m_ready=0;output_age=0;end
                tick();if(cfire)begin si=si+1;s_valid=0;end
            end
            if(si!=ntokens || ai!=nframes || queued!=nframes-1 || cp)$fatal(1,"main complete/actual queued packet");
            m_ready=0;phase=3;
        end else begin
            if(!$value$plusargs("FRESH=%s",fresh_path))$fatal(1,"fresh argument");fr=$fopen(fresh_path,"r");if(!fr)$fatal(1,"fresh open");
            r=$fscanf(fr,"%d",number);if(r!=1 || number!=1)$fatal(1,"fresh count");
            r=$fscanf(fr,"%d %d %d %d %d %d %d %d",a,b,c,d,e,f,g,h);if(r!=8 || h!=D)$fatal(1,"fresh header");
            fresh_inputs=a;fresh_expected={V'(b),3'(c),C'(d),T'(e)};fresh_latency=f;fresh_reads=g;
            for(k=0;k<fresh_inputs;k=k+1)parse_token(fr,fresh_tokens[k]);
            for(k=0;k<D;k=k+1)begin r=$fscanf(fr,"%d",a);if(r!=1)$fatal(1,"fresh minor");fresh_gold[k]=V'(a);end
            $fclose(fr);r=$fscanf(fd,"%d",number);if(r!=1)$fatal(1,"reset count");tick();rst=0;
            for(q=0;q<number;q=q+1)begin
                r=$fscanf(fd,"%d %d",target,old_count);if(r!=2)$fatal(1,"reset header");
                for(k=0;k<old_count;k=k+1)parse_token(fd,old_tokens[k]);
                phase=1;old_cursor=0;
                while(!hit(target))begin
                    if(!s_valid && old_cursor<old_count){s_row,s_keep,s_last,s_error,s_tag,s_valid}={old_tokens[old_cursor],1'b1};
                    tick();if(cfire)begin old_cursor=old_cursor+1;s_valid=0;end
                end
                hold_target=(target>=21 && target<=26) || target==31;
                if(hold_target)begin
                    // The held target includes three blocked edges and a real next packet.
                    {s_row,s_keep,s_last,s_error,s_tag,s_valid}={fresh_tokens[0],1'b1};
                    repeat(3)tick();if(cfire || s_ready || !hit(target))$fatal(1,"held cancellation boundary");
                end
                $display("OBS target=%0d effective=%0d state=%0d mask=%0d column=%0d",target,effective(target),dut.state,dut.mask,dut.column);
                reset_mask[target]=1;rst=1;s_valid=0;m_ready=0;#1;if(s_ready || m_valid)$fatal(1,"immediate reset gates");
                tick();if(dut.state!=0 || m_value!==0 || m_error!==0 || m_rows!==0 || m_tag!==0)$fatal(1,"canceled ownership/public clear");
                rst=0;resets=resets+1;recover();
            end
            $fclose(fd);if(fresh!=number || resets!=number)$fatal(1,"all reset recovery");
        end
        $display("PASS mode=%0d N=%0d T=%0d frames=%0d outputs=%0d queued=%0d resets=%0d fresh=%0d latency_checks=%0d dp_certificates=%0d bank_checks=%0d ram_reads=%0d row_writes=%0d dp_writes=%0d source_holds=%0d output_holds=%0d states=%h resetmask=%h cycles=%0d",
          mode,N,T,frames,outputs,queued,resets,fresh,latency_checks,dp_certificates,bank_checks,ram_reads,row_writes,dp_writes,source_holds,output_holds,states,reset_mask,cycles);
        $finish;
    end
endmodule
