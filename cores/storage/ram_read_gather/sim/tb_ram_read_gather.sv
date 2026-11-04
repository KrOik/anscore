// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_read_gather;
    parameter integer N=16,A=32,D=32,T=8;
    localparam integer IW=N>1?$clog2(N):1,CW=$clog2(N+1),RW=A+D+1;
    localparam integer SW=A+T+3,OW=3+4+A+D+T+IW+2*CW;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_first=0,s_last=0,m_ready=0;
    reg [A-1:0] s_addr=0;reg [T-1:0] s_tag=0;
    wire s_ready,q_valid,p_ready,m_valid,m_keep,m_error,m_first,m_last;
    wire [A-1:0] q_addr,m_addr;
    reg q_ready=0,p_valid=0,p_error=0;reg [D-1:0] p_data=0;
    wire [D-1:0] m_data;wire [T-1:0] m_tag;wire [2:0] m_status;
    wire [IW-1:0] m_index;wire [CW-1:0] m_count,m_unique;
    ram_read_gather #(.MAX_ITEMS(N),.ADDR_W(A),.DATA_W(D),.TAG_W(T)) dut(.*);
    wire [SW-1:0] source={s_addr,s_tag,s_keep,s_first,s_last};
    wire [OW-1:0] output_payload={m_status,m_keep,m_error,m_first,m_last,m_addr,m_data,m_tag,m_index,m_count,m_unique};
    reg [SW-1:0] vectors[0:30000],source_hold;
    reg [A+D:0] requests[0:30000];
    reg [A-1:0] request_hold;reg [D:0] response_hold;
    reg [OW-1:0] output_hold;
    reg sh=0,qh=0,ph=0,mh=0,main_phase=0,peer_pending=0;
    reg [D-1:0] peer_data=0;reg peer_error=0;
    reg helper_error=0;reg [D-1:0] helper_data={D{1'b1}};
    reg sfire,qfire,pfire,mfire,first_seen=0;
    reg [12:0] states=0;
    string input_path,request_path,output_path;
    integer token_total,request_total,output_total,frame_total,fd,ti=0,qi=0,oi=0,fi=0;
    integer cycles=0,source_holds=0,q_holds=0,p_holds=0,output_holds=0;
    integer accepted=0,requests_seen=0,responses_seen=0,scans=0,reads=0,writes=0;
    integer peer_delay=0,last_cycle=0,frame_waits=0,frame_scans=0,frame_requests=0;
    integer first_latency=0,max_latency=0,hold_age=0,guard=0,i,j,k,target,probe;
    integer resets=0,recovery=0,helper_requests=0,start_requests;

    // Every active edge belongs to this task. Monitors sample before NBA and
    // target/reset observations occur on the returning low boundary.
    task tick;
        begin
            @(posedge clk);
            sfire=s_valid && s_ready;qfire=q_valid && q_ready;
            pfire=p_valid && p_ready;mfire=m_valid && m_ready;
            if(rst)begin
                sh=0;qh=0;ph=0;mh=0;peer_pending=0;peer_delay=0;
            end else begin
                cycles=cycles+1;states[dut.state]=1;
                if(sh)begin
                    if(!s_valid || source!==source_hold)$fatal(1,"source hold");
                    source_holds=source_holds+1;
                end
                if(qh)begin
                    if(!q_valid || q_addr!==request_hold)$fatal(1,"request hold");
                    q_holds=q_holds+1;
                end
                if(ph)begin
                    if(!p_valid || {p_error,p_data}!==response_hold)$fatal(1,"peer response hold");
                    p_holds=p_holds+1;
                end
                if(mh)begin
                    if(!m_valid || output_payload!==output_hold)$fatal(1,"output hold");
                    output_holds=output_holds+1;
                end
                sh=s_valid && !s_ready;source_hold=source;
                qh=q_valid && !q_ready;request_hold=q_addr;
                ph=p_valid && !p_ready;response_hold={p_error,p_data};
                mh=m_valid && !m_ready;output_hold=output_payload;
                if(dut.state==3 || dut.state==5 || dut.state==10)reads=reads+1;
                if((sfire && s_keep && dut.room) || dut.state==9)writes=writes+1;
                if(dut.state==6)scans=scans+1;
                if(main_phase)begin
                    if(sfire)begin
                        ti=ti+1;accepted=accepted+1;
                        if(s_last)begin
                            last_cycle=cycles;frame_waits=0;frame_scans=0;frame_requests=0;first_seen=0;
                        end
                    end
                    if(dut.state==6)frame_scans=frame_scans+1;
                    if((q_valid && !q_ready) || (p_ready && !p_valid))frame_waits=frame_waits+1;
                    if(mfire)begin $fdisplay(fd,"O %h",output_payload);oi=oi+1;end
                end
                if(pfire)begin
                    if(!peer_pending)$fatal(1,"response without outstanding read");
                    peer_pending=0;responses_seen=responses_seen+1;
                end else if(peer_pending && peer_delay>0)peer_delay=peer_delay-1;
                if(qfire)begin
                    if(peer_pending || pfire)$fatal(1,"more than one outstanding read");
                    peer_pending=1;requests_seen=requests_seen+1;
                    if(main_phase)begin
                        if(qi>=request_total || q_addr!==requests[qi][A+D:D+1])$fatal(1,"unique request order %0d",qi);
                        peer_error=requests[qi][D];peer_data=requests[qi][D-1:0];
                        peer_delay=p_valid?0:qi%4;qi=qi+1;frame_requests=frame_requests+1;
                    end else begin
                        peer_data=helper_data;peer_error=helper_error;peer_delay=3;
                        helper_requests=helper_requests+1;
                    end
                end
            end
            #1;
            @(negedge clk);
            // Responses are held until their handshake, including while the
            // core is outside WAIT_DATA. Reset cancels the peer as well.
            p_valid=!rst && peer_pending && peer_delay==0;p_data=peer_data;p_error=peer_error;
            if(main_phase && !rst && m_valid && !first_seen)begin
                first_seen=1;first_latency=cycles-last_cycle;
                if(first_latency>max_latency)max_latency=first_latency;
                $fwrite(fd,"F %0d %0d %0d %0d %0d",fi,first_latency,frame_waits,frame_scans,frame_requests);
                for(j=0;j<N;j=j+1)begin
                    if(j<dut.count && dut.frame_errors==0)$fwrite(fd," %h",dut.rows[j]);
                end
                $fwrite(fd,"\n");fi=fi+1;
            end
        end
    endtask
    task send(input [A-1:0] address,input keep,first,last);
        begin
            s_addr=address;s_keep=keep;s_first=first;s_last=last;s_tag={T{1'b1}};s_valid=1;
            guard=0;tick();
            while(!sfire)begin guard=guard+1;if(guard>20000)$fatal(1,"send bound");tick();end
            s_valid=0;
        end
    endtask
    task wait_output;
        integer limit;
        begin
            limit=0;
            while(!m_valid)begin
                if(limit>2*N*N+40*N+50)$fatal(1,"helper output bound");
                tick();limit=limit+1;
            end
        end
    endtask
    task fresh;
        integer f,aidx,length;
        begin
            q_ready=1;m_ready=0;length=N<3?N:3;
            for(f=0;f<2;f=f+1)begin
                helper_error=f!=0;start_requests=helper_requests;
                for(aidx=0;aidx<length;aidx=aidx+1)send({A{1'b1}},1,aidx==0,aidx==length-1);
                wait_output();
                for(aidx=0;aidx<length;aidx=aidx+1)begin
                    wait_output();
                    if(!m_keep || m_status!=0 || m_error!==(f!=0) || m_addr!=={A{1'b1}} ||
                        m_data!==(f==0?{D{1'b1}}:{D{1'b0}}) || m_tag!=={T{1'b1}} ||
                        m_index!==IW'(aidx) || m_count!==CW'(length) || m_unique!==CW'(1) ||
                        m_first!==(aidx==0) || m_last!==(aidx==length-1))$fatal(1,"fresh ordered replay");
                    if(dut.rows[aidx]!=={{A{1'b1}},(f!=0),(f==0?{D{1'b1}}:{D{1'b0}})})$fatal(1,"fresh RAM image");
                    repeat(2)tick();m_ready=1;tick();if(!mfire)$fatal(1,"fresh retire");m_ready=0;
                end
                if(helper_requests-start_requests!=1 || peer_pending || !s_ready)$fatal(1,"fresh read ownership");
                recovery=recovery+1;
            end
            helper_error=0;
        end
    endtask
    task cancel_now;
        begin
            if(clk!==0)$fatal(1,"reset target boundary");
            rst=1;s_valid=0;m_ready=0;p_valid=0;#1;
            if(s_ready || q_valid || p_ready || m_valid)$fatal(1,"reset public gating");
            tick();if(dut.state!==0 || dut.count!==0 || dut.unique_count!==0)$fatal(1,"reset state");
            rst=0;resets=resets+1;tick();
            if(peer_pending || p_valid || !s_ready || m_valid || q_valid)$fatal(1,"shared peer cancellation");
            fresh();
        end
    endtask
    task probe_frame;
        integer index,length;
        begin
            length=N<3?N:3;
            for(index=0;index<length;index=index+1)
                send((index==1 && N>2)?{A{1'b1}}:{A{1'b0}},1,index==0,index==length-1);
        end
    endtask
    initial begin
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("REQUESTS=%s",request_path) ||
            !$value$plusargs("OUTPUT=%s",output_path) || !$value$plusargs("TOKENS=%d",token_total) ||
            !$value$plusargs("READS=%d",request_total) || !$value$plusargs("OUTPUTS=%d",output_total) ||
            !$value$plusargs("FRAMES=%d",frame_total))$fatal(1,"arguments");
        $readmemh(input_path,vectors,0,token_total-1);
        $readmemh(request_path,requests,0,request_total-1);
        fd=$fopen(output_path,"w");if(!fd)$fatal(1,"trace open");
        tick();rst=0;main_phase=1;
        while(oi<output_total)begin
            if(!s_valid && ti<token_total && cycles%7!=3)
                {s_addr,s_tag,s_keep,s_first,s_last,s_valid}={vectors[ti],1'b1};
            q_ready=cycles%5>=2;
            // A zero-latency peer may preoffer the current request's reply
            // on its accepting edge. It must then hold through !p_ready.
            if(!peer_pending && q_valid && q_ready && qi%3==0)begin
                p_valid=1;p_error=requests[qi][D];p_data=requests[qi][D-1:0];
            end
            if(m_valid)begin m_ready=hold_age>=3;hold_age=hold_age+1;end
            else begin m_ready=0;hold_age=0;end
            tick();if(sfire)s_valid=0;
            guard=guard+1;if(guard>5000000)$fatal(1,"main finite bound");
        end
        if(ti!=token_total || qi!=request_total || fi!=frame_total || peer_pending)$fatal(1,"main totals");
        main_phase=0;m_ready=0;s_valid=0;q_ready=1;
        $fclose(fd);
        for(probe=0;probe<16;probe=probe+1)begin
            if(!s_ready || m_valid || peer_pending)$fatal(1,"probe idle ownership");
            q_ready=1;helper_error=0;
            if(probe==0)begin end
            else if(probe==1)send(0,1,1,0);
            else if(probe==12)begin send(0,1,0,1);wait_output();end
            else begin
                if(probe==13)q_ready=0;
                probe_frame();
                target=probe;
                if(probe==2)target=2;
                if((probe==5 || probe==6) && N==1)target=7;
                if(probe>=13)target=probe==14?8:(probe==13?7:11);
                guard=0;
                while(dut.state!=target)begin tick();guard=guard+1;if(guard>50000)$fatal(1,"probe target %0d",probe);end
                if(probe==14)begin
                    while(!p_valid)tick();
                    if(!peer_pending || !p_ready)$fatal(1,"pending response target");
                end
                if(probe==15 && N>1)begin m_ready=1;tick();m_ready=0;wait_output();end
                if(probe==13 || probe==15)begin
                    s_addr={A{1'b1}};s_tag={T{1'b1}};s_keep=1;s_first=1;s_last=1;s_valid=1;
                    repeat(3)tick();if(s_ready)$fatal(1,"probe queued next source");
                end
            end
            cancel_now();
        end
        if(states!==(N==1?13'h1f9f:13'h1fff))$fatal(1,"state coverage %h",states);
        if(source_holds==0 || q_holds==0 || p_holds==0 || output_holds==0)$fatal(1,"hold coverage");
        $display("PASS gather tokens=%0d outputs=%0d reads=%0d frames=%0d cycles=%0d source_holds=%0d request_holds=%0d response_holds=%0d output_holds=%0d resets=%0d recovery=%0d scans=%0d ram_reads=%0d ram_writes=%0d requests=%0d responses=%0d max_latency=%0d states=%h",
            accepted,oi,qi,fi,cycles,source_holds,q_holds,p_holds,output_holds,resets,recovery,scans,reads,writes,requests_seen,responses_seen,max_latency,states);
        $finish;
    end
endmodule
