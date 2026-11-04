// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_exact_integer_charpoly;
    parameter integer N=4,W=8,T=8,CYCLE_LIMIT=100000;
    localparam integer L=$clog2(N),WW=N*(W-1)+(N+1)*L+3;
    localparam integer F=(N==1)?1:(N==2)?2:(N==3)?6:(N==4)?24:(N==5)?120:(N==6)?720:(N==7)?5040:40320;
    localparam integer QW=N*(W-1)+$clog2(F+1)+1,K=$clog2(N+1);
    reg clk=0,rst=1,s_valid=0,s_keep=0,s_last=0,s_bad=0,m_ready=0;
    reg signed [W-1:0] s_data=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_last;
    wire signed [QW-1:0] m_coeff;
    wire [K-1:0] m_index;
    wire [2:0] m_errors;
    wire [T-1:0] m_tag;
    exact_integer_charpoly #(.N(N),.DATA_W(W),.TAG_W(T)) dut(.*);
    always #5 clk=~clk;

    integer nt[0:3],no[0:3],err[0:3],cnt[0:3],complete_case[0:3],compute[0:3],ns[0:3];
    reg [T-1:0] tags[0:3];
    reg signed [W-1:0] td[0:3][0:159],amat[0:3][0:63];
    integer tk[0:3][0:159],tl[0:3][0:159],tb[0:3][0:159];
    reg [T-1:0] tt[0:3][0:159];
    reg signed [QW-1:0] od[0:3][0:8];
    integer oi[0:3][0:8],ok[0:3][0:8],ol[0:3][0:8],oe[0:3][0:8];
    reg [T-1:0] ot[0:3][0:8];
    reg signed [WW-1:0] gc[0:3][1:8][0:8],gg[0:3][1:8][0:8];
    reg signed [WW-1:0] gv[0:3][1:8][0:7][0:7];
    integer accepted[0:3],retired[0:3],completed[0:3],last_cycle[0:3],valid_seen[0:3],queued_blocked[0:3];
    integer mode,entries,target,drive_slot=0,active_slot=-1,cycles=0,total_frames=0,total_outputs=0;
    integer queued=0,reset_count=0,hold_age=0,source_holds=0,output_holds=0,latency_checks=0;
    integer bank_checks=0,dot_checks=0,mul_checks=0,reset_high_offers=0,actual_next_seen=0;
    integer state_mask=0,reset_search=0,fd,scan_result,fidx,tidx,k,z,goal,tail_char;
    reg [4095:0] fixture;
    reg source_held=0,output_held=0;
    reg [W+T+2:0] held_source;
    reg [QW+K+T+4:0] held_output;
    wire [W+T+2:0] source_bundle={s_data,s_keep,s_last,s_bad,s_tag};
    wire [QW+K+T+4:0] output_bundle={m_coeff,m_index,m_keep,m_last,m_errors,m_tag};
    integer a_owned[0:63],v0_owned[0:7],v1_owned[0:7],g_owned[0:8],q0_owned[0:8],q1_owned[0:8];
    reg signed [127:0] mul_a,mul_b,full_product,partial_product,term_a,term_b,prefix,limit;
    integer old_state,old_m,old_r,old_i,old_j,old_vbank,old_qbank,old_power,old_count,old_slot,old_addr;
    integer old_accept,old_keep;
    reg signed [W-1:0] old_data;
    reg signed [WW-1:0] old_total;

    task clear_ownership;
        integer u;
        begin
            for(u=0;u<64;u=u+1)a_owned[u]=0;
            for(u=0;u<8;u=u+1)begin v0_owned[u]=0;v1_owned[u]=0;end
            for(u=0;u<9;u=u+1)begin g_owned[u]=0;q0_owned[u]=0;q1_owned[u]=0;end
        end
    endtask

    task load_case;
        input integer slot;
        integer u,v,mm,nv,kept;
        integer read_nt,read_no,read_errors,read_compute,read_count,read_complete,read_ns;
        integer read_keep,read_last,read_bad,read_index;
        reg [31:0] read_tag;
        reg signed [127:0] value;
        begin
            scan_result=$fscanf(fd,"%d %d %d %d %d %d %d %d",read_nt,read_no,read_errors,read_tag,read_compute,read_count,read_complete,read_ns);
            if(scan_result!=8 || read_nt>160 || read_no>9)$fatal(1,"bad case header");
            nt[slot]=read_nt;no[slot]=read_no;err[slot]=read_errors;tags[slot]=read_tag;
            compute[slot]=read_compute;cnt[slot]=read_count;complete_case[slot]=read_complete;ns[slot]=read_ns;
            kept=0;
            for(u=0;u<nt[slot];u=u+1)begin
                scan_result=$fscanf(fd,"%d %d %d %d %d",value,read_keep,read_last,read_bad,read_tag);
                if(scan_result!=5)$fatal(1,"bad input token");
                td[slot][u]=value;tk[slot][u]=read_keep;tl[slot][u]=read_last;tb[slot][u]=read_bad;tt[slot][u]=read_tag;
                if(tk[slot][u] && kept<N*N)amat[slot][kept]=td[slot][u];
                if(tk[slot][u])kept=kept+1;
            end
            for(u=0;u<no[slot];u=u+1)begin
                scan_result=$fscanf(fd,"%d %d %d %d %d %d",value,read_index,read_keep,read_last,read_errors,read_tag);
                if(scan_result!=6)$fatal(1,"bad expected output");
                od[slot][u]=value;oi[slot][u]=read_index;ok[slot][u]=read_keep;ol[slot][u]=read_last;oe[slot][u]=read_errors;ot[slot][u]=read_tag;
            end
            for(u=0;u<ns[slot];u=u+1)begin
                scan_result=$fscanf(fd,"%d",mm);
                if(scan_result!=1 || mm!=u+1)$fatal(1,"bad stage index");
                for(v=0;v<=mm;v=v+1)begin scan_result=$fscanf(fd,"%d",value);if(scan_result!=1)$fatal(1,"stage coeff");gc[slot][mm][v]=value;end
                for(v=0;v<=mm;v=v+1)begin scan_result=$fscanf(fd,"%d",value);if(scan_result!=1)$fatal(1,"stage G");gg[slot][mm][v]=value;end
                scan_result=$fscanf(fd,"%d",nv);
                if(scan_result!=1 || nv!=mm-1)$fatal(1,"vector count");
                for(v=0;v<nv;v=v+1)begin
                    for(kept=0;kept<mm-1;kept=kept+1)begin
                        scan_result=$fscanf(fd,"%d",value);
                        if(scan_result!=1)$fatal(1,"vector certificate");
                        gv[slot][mm][v][kept]=value;
                    end
                end
            end
        end
    endtask

    function actual_next;
        begin actual_next=(drive_slot==1 && active_slot==0 && s_valid && !s_ready &&
            s_data===td[1][0] && s_keep===tk[1][0][0] && s_last===tl[1][0][0] &&
            s_bad===tb[1][0][0] && s_tag===tt[1][0]);end
    endfunction

    function reset_hit;
        input integer id;
        begin
            reset_hit=0;
            if(id<=18)reset_hit=(dut.state==id);
            else case(id)
                19:reset_hit=(dut.state==1 && dut.count==0 && accepted[0]>0);
                20:reset_hit=(dut.state==1 && dut.count==1 && !s_last);
                21:reset_hit=(dut.state==1 && dut.count==N*N && !s_last);
                22:reset_hit=(dut.state==1 && dut.count==N*N+1 && dut.errors[1]);
                23:reset_hit=(dut.state==11 && dut.mul_step==0);
                24:reset_hit=(dut.state==11 && dut.mul_step==W/2);
                25:reset_hit=(dut.state==11 && dut.mul_step==W-1);
                26:reset_hit=(dut.state==15 && dut.mul_step==0);
                27:reset_hit=(dut.state==15 && dut.mul_step==QW/2);
                28:reset_hit=(dut.state==15 && dut.mul_step==QW-1);
                29:reset_hit=(dut.state==12 && dut.m==3 && dut.power_mode && dut.i==0 && dut.j==1);
                30:reset_hit=(dut.state==12 && dut.m==3 && !dut.power_mode && dut.r==2 && dut.j==1);
                31:reset_hit=(dut.state==12 && dut.m==3 && dut.power_mode && dut.r==2 && dut.i==1 && dut.j==1 && dut.vec_bank==0);
                32:reset_hit=(dut.state==9 && dut.m==3 && !dut.power_mode && dut.r==3 && dut.j==0 && dut.vec_bank==1);
                33:reset_hit=(dut.state==16 && dut.m==2 && dut.i==2 && dut.j==1 && dut.coeff_bank==0);
                34:reset_hit=(dut.state==5 && dut.m==3 && dut.coeff_bank==1);
                35:reset_hit=(dut.state==16 && dut.m==2 && dut.i==1 && dut.j==1);
                36:reset_hit=(dut.state==16 && dut.m==2 && dut.i==1 && dut.j==1 && dut.dot_acc!=0);
                37:reset_hit=(dut.state==18 && dut.i==0 && !m_ready);
                38:reset_hit=(dut.state==18 && dut.i==N/2 && !m_ready);
                39:reset_hit=(dut.state==18 && dut.i==N && !m_ready);
                40:reset_hit=(dut.state==2 && dut.errors==1 && !m_ready);
                41:reset_hit=(dut.state==2 && dut.errors==2 && !m_ready);
                42:reset_hit=(dut.state==2 && dut.errors==4 && !m_ready);
                43:reset_hit=(dut.state==2 && dut.errors==5 && !m_ready);
                44:reset_hit=(dut.state==2 && dut.errors==6 && !m_ready);
                45:reset_hit=(dut.state==3 && actual_next());
                46:reset_hit=(dut.state==18 && actual_next());
                47:reset_hit=(dut.state==18 && dut.i==1 && retired[0]==1 && !m_ready);
                48:reset_hit=(dut.state==16 && dut.m==N && dut.i==N && dut.j==N-1);
                49:reset_hit=(dut.state==4 && q0_owned[0]);
                50:reset_hit=(dut.state==11 && dut.m==3 && dut.power_mode && dut.mul_step==W/2);
                51:reset_hit=(dut.state==9 && dut.m==N && !dut.power_mode && dut.r==N && dut.j==0);
                52:reset_hit=(dut.state==15 && dut.m==N && dut.i==N && dut.j==N-1 && dut.mul_step==QW-1);
                53:reset_hit=(dut.state==16 && dut.m==2 && dut.i==0 && dut.j==0);
                54:reset_hit=(dut.state==16 && dut.m==N && dut.i==N && dut.j==N-1);
                default:reset_hit=0;
            endcase
        end
    endfunction

    task prepare_ready;
        reg freeze_output;
        begin
            freeze_output=reset_search && m_valid &&
                ((target==38 && m_index==N/2) || (target==39 && m_index==N) ||
                 (target==47 && m_index==1) || target==18 || target==37 || target==46 ||
                 target==2 || (target>=40 && target<=44));
            m_ready=(!rst && m_valid && hold_age>=2 && !freeze_output);
        end
    endtask

    task tick;
        begin prepare_ready;@(posedge clk);#2;@(negedge clk);end
    endtask

    task drive_token;
        input integer slot,index;
        begin drive_slot=slot;s_data=td[slot][index];s_keep=tk[slot][index];s_last=tl[slot][index];s_bad=tb[slot][index];s_tag=tt[slot][index];s_valid=1;end
    endtask

    task send_case;
        input integer slot;
        integer u,want;
        begin
            for(u=0;u<nt[slot];u=u+1)begin
                if(u%5==2)begin s_valid=0;tick;end
                drive_token(slot,u);want=accepted[slot]+1;
                while(accepted[slot]<want)tick;
            end
        end
    endtask

    always @(posedge clk)begin
        cycles=cycles+1;
        if(cycles>CYCLE_LIMIT)$fatal(1,"frozen cycle watchdog target=%0d state=%0d",target,dut.state);
        old_state=dut.state;old_m=dut.m;old_r=dut.r;old_i=dut.i;old_j=dut.j;
        old_vbank=dut.vec_bank;old_qbank=dut.coeff_bank;old_power=dut.power_mode;
        old_count=dut.count;old_data=s_data;old_accept=s_valid&&s_ready;old_keep=s_keep;
        old_total=dut.dot_total;old_addr=0;
        if(rst)begin
            if(s_ready || m_valid)$fatal(1,"reset gating");
            active_slot=-1;source_held=0;output_held=0;hold_age=0;clear_ownership;
            if(s_valid)reset_high_offers=reset_high_offers+1;
        end else begin
            state_mask=state_mask|(1<<dut.state);
            if(source_held && (!s_valid || source_bundle!==held_source))$fatal(1,"source changed while blocked");
            if(output_held && (!m_valid || output_bundle!==held_output))$fatal(1,"output changed while held");
            source_held=s_valid&&!s_ready;held_source=source_bundle;
            output_held=m_valid&&!m_ready;held_output=output_bundle;
            if(source_held)begin
                source_holds=source_holds+1;
                if(mode==0 && drive_slot>active_slot)queued_blocked[drive_slot]=1;
            end
            if(output_held)begin output_holds=output_holds+1;hold_age=hold_age+1;end else hold_age=0;
            if(old_accept)begin
                if(dut.state!=0 && dut.state!=1)$fatal(1,"accept while owner busy");
                if(dut.state==0)begin
                    active_slot=drive_slot;clear_ownership;
                    if(mode==0 && drive_slot>0)begin
                        if(!completed[drive_slot-1] || !queued_blocked[drive_slot])$fatal(1,"next frame ownership");
                        queued=queued+1;
                    end
                end
                if(accepted[drive_slot]>=nt[drive_slot])$fatal(1,"extra input accepted");
                if(source_bundle!=={td[drive_slot][accepted[drive_slot]],tk[drive_slot][accepted[drive_slot]][0],tl[drive_slot][accepted[drive_slot]][0],tb[drive_slot][accepted[drive_slot]][0],tt[drive_slot][accepted[drive_slot]]})$fatal(1,"input token changed");
                accepted[drive_slot]=accepted[drive_slot]+1;
                if(s_keep && old_count<N*N)begin a_owned[old_count]=1;bank_checks=bank_checks+1;end
                if(s_last)last_cycle[drive_slot]=cycles;
            end
            old_slot=active_slot;
            if(m_valid)begin
                if(active_slot<0 || retired[active_slot]>=no[active_slot])$fatal(1,"unexpected/stale response");
                z=retired[active_slot];
                if(m_coeff!==od[active_slot][z] || m_index!==oi[active_slot][z] || m_keep!==ok[active_slot][z][0] || m_last!==ol[active_slot][z][0] || m_errors!==oe[active_slot][z] || m_tag!==ot[active_slot][z])$fatal(1,"coefficient/metadata mismatch slot=%0d index=%0d actual=%0d expected=%0d",active_slot,z,m_coeff,od[active_slot][z]);
                if(s_ready)$fatal(1,"input ready before final retirement");
                if(m_ready)begin
                    retired[active_slot]=retired[active_slot]+1;total_outputs=total_outputs+1;
                    if(m_last)begin completed[active_slot]=1;total_frames=total_frames+1;end
                end
            end
            if(active_slot>=0)begin
                case(dut.state)
                    3:begin
                        if(!a_owned[N*N-1])$fatal(1,"base A ownership");
                        for(k=0;k<9;k=k+1)begin q0_owned[k]=0;q1_owned[k]=0;end
                        q0_owned[0]=1;bank_checks=bank_checks+2;
                    end
                    4:begin q0_owned[1]=1;bank_checks=bank_checks+1;end
                    5:begin
                        for(k=0;k<8;k=k+1)begin v0_owned[k]=0;v1_owned[k]=0;end
                        for(k=0;k<9;k=k+1)g_owned[k]=0;
                        old_addr=(N-dut.m)*N+(N-dut.m);
                        if(!a_owned[old_addr])$fatal(1,"diagonal A ownership");
                        g_owned[0]=1;bank_checks=bank_checks+2;
                    end
                    6:begin g_owned[1]=1;bank_checks=bank_checks+1;end
                    7:begin
                        old_addr=(N-dut.m+1+dut.i)*N+(N-dut.m);
                        if(!a_owned[old_addr])$fatal(1,"C ownership");
                        bank_checks=bank_checks+1;
                    end
                    8:begin
                        if(dut.a_work!==gv[active_slot][dut.m][0][dut.i])$fatal(1,"initial vector certificate");
                        v0_owned[dut.i]=1;bank_checks=bank_checks+1;
                    end
                    9:begin
                        old_addr=dut.power_mode?((N-dut.m+1+dut.i)*N+(N-dut.m+1+dut.j)):((N-dut.m)*N+(N-dut.m+1+dut.j));
                        if(!a_owned[old_addr] || !(dut.vec_bank?v1_owned[dut.j]:v0_owned[dut.j]))$fatal(1,"DOT bank ownership");
                        bank_checks=bank_checks+2;
                    end
                    10:begin
                        old_addr=dut.power_mode?((N-dut.m+1+dut.i)*N+(N-dut.m+1+dut.j)):((N-dut.m)*N+(N-dut.m+1+dut.j));
                        if(dut.a_q!==amat[active_slot][old_addr] || dut.v_q!==gv[active_slot][dut.m][dut.r-2][dut.j])$fatal(1,"DOT synchronous read certificate");
                        term_a=dut.v_q;term_b=dut.a_q;
                        mul_a=term_a<0?-term_a:term_a;mul_b=term_b<0?-term_b:term_b;full_product=mul_a*mul_b;
                    end
                    11,15:begin
                        limit=128'sd1<<(WW-3);
                        partial_product=mul_a*(mul_b&((128'sd1<<dut.mul_step)-1));
                        if(full_product>limit || $unsigned(dut.mul_acc)!==partial_product || $unsigned(dut.mul_factor)!==(mul_b>>dut.mul_step))$fatal(1,"full product/partial invariant");
                        if(dut.mul_factor!=0 && $unsigned(dut.mul_shift)!==(mul_a<<dut.mul_step))$fatal(1,"shift before significant truncation");
                        if($unsigned(dut.mul_shift)>limit || $unsigned(dut.add_total)>full_product)$fatal(1,"working magnitude bound");
                        mul_checks=mul_checks+1;
                    end
                    12:begin
                        prefix=0;
                        for(k=0;k<=dut.j;k=k+1)begin
                            old_addr=dut.power_mode?((N-dut.m+1+dut.i)*N+(N-dut.m+1+k)):((N-dut.m)*N+(N-dut.m+1+k));
                            term_a=amat[active_slot][old_addr];term_b=gv[active_slot][dut.m][dut.r-2][k];
                            prefix=prefix+(dut.power_mode?term_a*term_b:-term_a*term_b);
                        end
                        if(dut.dot_total!==prefix)$fatal(1,"signed DOT prefix certificate");
                        dot_checks=dot_checks+1;
                        if(dut.j==dut.m-2)begin
                            if(dut.power_mode)begin
                                if(dut.dot_total!==gv[active_slot][dut.m][dut.r-1][dut.i])$fatal(1,"power vector certificate");
                                if(dut.vec_bank)v0_owned[dut.i]=1;else v1_owned[dut.i]=1;
                            end else begin
                                if(dut.dot_total!==gg[active_slot][dut.m][dut.r])$fatal(1,"G dot certificate");
                                g_owned[dut.r]=1;
                                if(dut.r<dut.m)begin
                                    for(k=0;k<8;k=k+1)begin
                                        if(dut.vec_bank)v0_owned[k]=0;else v1_owned[k]=0;
                                    end
                                end
                            end
                            bank_checks=bank_checks+1;
                        end
                    end
                    13:begin
                        if(!g_owned[dut.i-dut.j] || !(dut.coeff_bank?q1_owned[dut.j]:q0_owned[dut.j]))$fatal(1,"convolution source ownership");
                        if(dut.i==0 && dut.j==0)begin
                            for(k=0;k<9;k=k+1)begin if(dut.coeff_bank)q0_owned[k]=0;else q1_owned[k]=0;end
                        end
                        bank_checks=bank_checks+2;
                    end
                    14:begin
                        if(dut.g_q!==gg[active_slot][dut.m][dut.i-dut.j] || dut.q_q!==gc[active_slot][dut.m-1][dut.j])$fatal(1,"convolution synchronous read certificate");
                        term_a=dut.g_q;term_b=dut.q_q;
                        mul_a=term_a<0?-term_a:term_a;mul_b=term_b<0?-term_b:term_b;full_product=mul_a*mul_b;
                    end
                    16:begin
                        prefix=0;
                        for(k=0;k<=dut.j;k=k+1)begin
                            term_a=gg[active_slot][dut.m][dut.i-k];term_b=gc[active_slot][dut.m-1][k];prefix=prefix+term_a*term_b;
                        end
                        if(dut.dot_total!==prefix)$fatal(1,"signed convolution prefix certificate");
                        dot_checks=dot_checks+1;
                        if(dut.j==dut.conv_limit)begin
                            if(dut.dot_total!==gc[active_slot][dut.m][dut.i])$fatal(1,"trailing full coefficient certificate");
                            if(dut.coeff_bank)q0_owned[dut.i]=1;else q1_owned[dut.i]=1;
                            bank_checks=bank_checks+1;
                        end
                    end
                    17:begin
                        if(!(dut.coeff_bank?q1_owned[dut.i]:q0_owned[dut.i]))$fatal(1,"output bank ownership");
                        bank_checks=bank_checks+1;
                    end
                    default:begin end
                endcase
            end
        end
        #1;
        if(rst)begin if(s_ready || m_valid || dut.state!==0 || dut.count!==0)$fatal(1,"synchronous reset clear");end
        else begin
            if(old_accept && old_keep && old_count<N*N && dut.a_mem[old_count]!==old_data)$fatal(1,"A write payload");
            if(old_slot>=0)case(old_state)
                3:if(dut.q0_mem[0]!==1)$fatal(1,"base c0 write");
                4:if(dut.q0_mem[1]!==gc[old_slot][1][1])$fatal(1,"base c1 write");
                5:if(dut.g_mem[0]!==gg[old_slot][old_m][0])$fatal(1,"G0 write");
                6:if(dut.g_mem[1]!==gg[old_slot][old_m][1])$fatal(1,"G1 write");
                8:if(dut.v0_mem[old_i]!==gv[old_slot][old_m][0][old_i])$fatal(1,"C write");
                12:if(old_j==old_m-2)begin
                    if(old_power)begin
                        if(old_vbank)begin if(dut.v0_mem[old_i]!==old_total)$fatal(1,"V0 destination write");end
                        else if(dut.v1_mem[old_i]!==old_total)$fatal(1,"V1 destination write");
                    end else if(dut.g_mem[old_r]!==old_total)$fatal(1,"G destination write");
                end
                16:if(old_j==((old_i<old_m)?old_i:old_m-1))begin
                    if(old_qbank)begin if(dut.q0_mem[old_i]!==old_total[QW-1:0])$fatal(1,"Q0 destination write");end
                    else if(dut.q1_mem[old_i]!==old_total[QW-1:0])$fatal(1,"Q1 destination write");
                end
                default:begin end
            endcase
            if(m_valid && active_slot>=0 && !valid_seen[active_slot])begin
                if(cycles-last_cycle[active_slot]!=(err[active_slot]?0:compute[active_slot]+1))$fatal(1,"fixed first-valid latency actual=%0d expected=%0d",cycles-last_cycle[active_slot],compute[active_slot]+1);
                valid_seen[active_slot]=1;latency_checks=latency_checks+1;
            end
        end
    end

    initial begin
        for(k=0;k<4;k=k+1)begin accepted[k]=0;retired[k]=0;completed[k]=0;last_cycle[k]=-1;valid_seen[k]=0;queued_blocked[k]=0;end
        clear_ownership;
        if(!$value$plusargs("INPUT=%s",fixture))$fatal(1,"missing frozen INPUT");
        fd=$fopen(fixture,"r");if(fd==0)$fatal(1,"cannot open frozen INPUT");
        scan_result=$fscanf(fd,"%d %d",mode,entries);if(scan_result!=2)$fatal(1,"fixture header");
        if(mode==0)begin
            if(entries<1 || entries>4)$fatal(1,"frame grouping");
            for(fidx=0;fidx<entries;fidx=fidx+1)load_case(fidx);
        end else begin target=entries;load_case(0);load_case(1);end
        tail_char=$fgetc(fd);
        while(tail_char!=-1)begin
            if(tail_char!=32 && tail_char!=9 && tail_char!=13 && tail_char!=10)$fatal(1,"trailing non-whitespace fixture byte");
            tail_char=$fgetc(fd);
        end
        $fclose(fd);
        @(negedge clk);repeat(3)tick;rst=0;
        if(mode==0)begin
            for(fidx=0;fidx<entries;fidx=fidx+1)send_case(fidx);
            s_valid=0;
            while(!completed[entries-1])tick;
            for(fidx=0;fidx<entries;fidx=fidx+1)
                if(accepted[fidx]!=nt[fidx] || retired[fidx]!=no[fidx])$fatal(1,"incomplete main frame");
        end else begin
            reset_search=1;
            send_case(0);s_valid=0;
            if(target==45 || target==46)drive_token(1,0);
            prepare_ready;
            while(!reset_hit(target))tick;
            if((target==38 && retired[0]!=N/2) || (target==39 && retired[0]!=N) || (target==47 && retired[0]!=1))$fatal(1,"owner output prefix incomplete");
            if(target!=38 && target!=39 && target!=47 && retired[0]!=0)$fatal(1,"unexpected owner retired prefix");
            if(target==45 || target==46)begin if(!actual_next())$fatal(1,"actual next offer missing");actual_next_seen=1;end
            $display("OBS target=%0d state=%0d m=%0d r=%0d i=%0d j=%0d step=%0d vb=%0d qb=%0d power=%0d count=%0d errors=%0d prefix=%0d next=%0d acc=%0d owned0=%0d accepted=%0d",target,dut.state,dut.m,dut.r,dut.i,dut.j,dut.mul_step,dut.vec_bank,dut.coeff_bank,dut.power_mode,dut.count,dut.errors,retired[0],actual_next_seen,dut.dot_acc,q0_owned[0],accepted[0]);
            goal=accepted[0]+accepted[1];z=total_outputs;
            rst=1;
            if(target!=45 && target!=46)begin s_data=-(1<<(W-1));s_keep=1;s_last=1;s_bad=1;s_tag=0;s_valid=1;end
            #1;if(s_ready || m_valid)$fatal(1,"immediate reset gating");
            repeat(3)tick;
            if(accepted[0]+accepted[1]!=goal || total_outputs!=z)$fatal(1,"reset-high acceptance");
            reset_count=1;rst=0;reset_search=0;
            send_case(1);s_valid=0;
            while(!completed[1])tick;
            if(accepted[1]!=nt[1] || retired[1]!=N+1)$fatal(1,"fresh frame incomplete");
        end
        repeat(5)begin tick;if(m_valid)$fatal(1,"late duplicate response");end
        $display("PASS mode=%0d N=%0d W=%0d T=%0d frames=%0d outputs=%0d queued=%0d resets=%0d fresh=%0d prefix=%0d next=%0d reset_offers=%0d latency=%0d bank=%0d dot=%0d mul=%0d source_holds=%0d output_holds=%0d states=%0h cycles=%0d",mode,N,W,T,(mode==0)?total_frames:completed[1],(mode==0)?total_outputs:retired[1],queued,reset_count,(mode==0)?0:completed[1],(mode==0)?0:retired[0],actual_next_seen,(mode==0)?0:reset_high_offers,latency_checks,bank_checks,dot_checks,mul_checks,source_holds,output_holds,state_mask,cycles);
        $finish;
    end
endmodule
`default_nettype wire
