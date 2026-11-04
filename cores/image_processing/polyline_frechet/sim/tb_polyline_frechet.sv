// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_polyline_frechet;
    parameter integer COORD_W=12,MAX_POINTS=16,TAG_W=8,FRAMES=1;
    localparam integer IW=($clog2(MAX_POINTS)<1)?1:$clog2(MAX_POINTS),
        CW=($clog2(MAX_POINTS+1)<1)?1:$clog2(MAX_POINTS+1),DW=2*COORD_W+1,
        OW=4+TAG_W+2*CW+DW+3+2*IW+4*COORD_W,MB=4*MAX_POINTS+10;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_a_keep=0,s_b_keep=0,s_last=0,m_ready=0;
    wire s_ready,m_valid,m_first,m_last,m_empty;
    reg signed [COORD_W-1:0] s_a_x=0,s_a_y=0,s_b_x=0,s_b_y=0;
    reg [TAG_W-1:0] s_tag=0;
    wire signed [COORD_W-1:0] m_a_x,m_a_y,m_b_x,m_b_y;
    wire [IW-1:0] m_index_a,m_index_b;
    wire [CW-1:0] m_count_a,m_count_b;
    wire [DW-1:0] m_distance_sq;
    wire [3:0] m_errors;wire [TAG_W-1:0] m_tag;
    polyline_frechet #(.COORD_W(COORD_W),.MAX_POINTS(MAX_POINTS),.TAG_W(TAG_W)) dut(.*);
    wire [OW-1:0] packed_output={m_errors,m_tag,m_count_a,m_count_b,m_distance_sq,
        m_first,m_last,m_empty,m_index_a,m_index_b,m_a_x,m_a_y,m_b_x,m_b_y};
    reg [OW-1:0] expected[0:2*MAX_POINTS],held;
    reg [DW-1:0] scores[0:MAX_POINTS*MAX_POINTS-1],header_score,fixture_score;
    integer fixture_direction;
    integer directions[0:MAX_POINTS*MAX_POINTS-1];
    integer ka[0:MB-1],kb[0:MB-1],xa[0:MB-1],ya[0:MB-1],xb[0:MB-1],yb[0:MB-1],lasts[0:MB-1];
    reg [TAG_W-1:0] tags[0:MB-1];
    integer ax[0:MAX_POINTS-1],ay[0:MAX_POINTS-1],bx[0:MAX_POINTS-1],by[0:MAX_POINTS-1];
    integer ticks=0,frames=0,beats=0,outputs=0,cells=0,multiply_steps=0,ii1_checks=0;
    integer read_checks=0,predecessor_checks=0,trace_checks=0,latency_checks=0;
    integer reset_probes=0,fresh_checks=0,held_cycles=0,source_stalls=0,state_mask=0;
    integer fd,trace_fd,rc,fi,k,h,oi,na,nb,nbeats,npath,ncells,error_code,expected_latency;
    integer final_tick,last_accept=-100,observed_delay,target,rn,guard,code,ci,cj,old_state;
    integer track=0;reg [TAG_W-1:0] header_tag,fresh_tag;
    string cases_path,trace_path;
    longint signed ddx,ddy;reg [DW-1:0] expected_minimum;
    reg [COORD_W-1:0] e_ax,e_ay,e_bx,e_by;

    task automatic tick;
        integer previous_state,idx;
        begin
            previous_state=dut.state;
            @(posedge clk);#1;ticks=ticks+1;state_mask=state_mask|(1<<dut.state);
            if(track)begin
                if(previous_state==4 || previous_state==6)multiply_steps=multiply_steps+1;
                idx=dut.i*MAX_POINTS+dut.j;
                if(dut.state==3)begin
                    e_ax=ax[dut.i];e_ay=ay[dut.i];e_bx=bx[dut.j];e_by=by[dut.j];
                    if(dut.a_q!=={e_ax,e_ay} || dut.b_q!=={e_bx,e_by})$fatal(1,"point read ownership frame%0d i%0d j%0d",fi,dut.i,dut.j);
                    if(dut.i!=0 && dut.row_q!==scores[(dut.i-1)*MAX_POINTS+dut.j])$fatal(1,"previous row read");
                    read_checks=read_checks+1;
                end
                if(dut.state==4 && dut.bit_index==0)begin
                    case(directions[idx])
                        0:expected_minimum=0;
                        1:expected_minimum=scores[(dut.i-1)*MAX_POINTS+dut.j-1];
                        2:expected_minimum=scores[(dut.i-1)*MAX_POINTS+dut.j];
                        3:expected_minimum=scores[dut.i*MAX_POINTS+dut.j-1];
                    endcase
                    if(dut.predecessor!==directions[idx] || dut.minimum!==expected_minimum)$fatal(1,"predecessor/tie frame%0d i%0d j%0d",fi,dut.i,dut.j);
                    predecessor_checks=predecessor_checks+1;
                end
                if(dut.state==7)begin
                    ddx=ax[dut.i];ddx=ddx-bx[dut.j];ddy=ay[dut.i];ddy=ddy-by[dut.j];
                    if(dut.distance_sq!==ddx*ddx+ddy*ddy || dut.cell_value!==scores[idx])$fatal(1,"distance/score frame%0d i%0d j%0d got%h expected%h",fi,dut.i,dut.j,dut.cell_value,scores[idx]);
                    cells=cells+1;
                end
                if(dut.state==9)begin
                    e_ax=ax[dut.i];e_ay=ay[dut.i];e_bx=bx[dut.j];e_by=by[dut.j];
                    if(dut.a_q!=={e_ax,e_ay} || dut.b_q!=={e_bx,e_by} || dut.trace_q!==directions[idx])$fatal(1,"trace read/point ownership");
                    trace_checks=trace_checks+1;
                end
            end
        end
    endtask
    task automatic drive_token(input integer a_keep,a_x,a_y,b_keep,b_x,b_y,last_word,input reg [TAG_W-1:0] tag_word);
        begin
            @(negedge clk);s_valid=1;s_a_keep=a_keep;s_a_x=a_x;s_a_y=a_y;
            s_b_keep=b_keep;s_b_x=b_x;s_b_y=b_y;s_last=last_word;s_tag=tag_word;
            if(!s_ready)$fatal(1,"unexpected capture stall");tick();
        end
    endtask
    task automatic stop_source;
        begin @(negedge clk);s_valid=0;end
    endtask
    task automatic wait_valid(input integer limit);
        integer waited;
        begin waited=0;while(!m_valid)begin tick();waited=waited+1;if(waited>limit)$fatal(1,"bounded missing response");end end
    endtask
    task automatic retire_pair;
        begin @(negedge clk);m_ready=1;tick();@(negedge clk);m_ready=0;end
    endtask
    task automatic hold_pair(input integer clocks);
        integer n;
        begin
            held=packed_output;
            for(n=0;n<clocks;n=n+1)begin
                tick();held_cycles=held_cycles+1;
                if(!m_valid || packed_output!==held || s_ready)$fatal(1,"held complete output/input exclusion");
            end
        end
    endtask
    task automatic fresh_recovery;
        integer n,p,begin_tick;
        reg [OW-1:0] want;
        reg [CW-1:0] count_value;
        reg [IW-1:0] index_value;
        reg [DW-1:0] distance_value;
        reg [COORD_W-1:0] negative_one,zero_value;
        begin
            n=(MAX_POINTS>1)?2:1;count_value=n;distance_value=2;negative_one=-1;zero_value=0;
            fresh_tag=(reset_probes*13+7);
            for(p=0;p<n;p=p+1)drive_token(1,-1,-1,1,0,0,p==n-1,fresh_tag);
            begin_tick=ticks;stop_source();wait_valid(3+n*n*(2*COORD_W+4)+2);
            if(ticks-begin_tick!=3+n*n*(2*COORD_W+4))$fatal(1,"fresh exact latency");
            for(p=n-1;p>=0;p=p-1)begin
                wait_valid(4);index_value=p;
                want={4'b0000,fresh_tag,count_value,count_value,distance_value,
                    (p==n-1),(p==0),1'b0,index_value,index_value,negative_one,negative_one,zero_value,zero_value};
                if(packed_output!==want)$fatal(1,"fresh complete analytic mismatch target%0d",target);
                hold_pair(2);retire_pair();
            end
            repeat(2)begin tick();if(m_valid || !s_ready)$fatal(1,"stale result after fresh retirement");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    task automatic cancel_now;
        begin
            // No active edge occurs between observing the phase and asserting reset.
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready || m_valid)$fatal(1,"reset immediate public gates");
            tick();
            if(dut.state!=0 || dut.started || m_count_a!=0 || m_count_b!=0 || m_errors!=0 || m_valid)$fatal(1,"reset ownership");
            @(negedge clk);rst=0;reset_probes=reset_probes+1;fresh_recovery();
        end
    endtask

    initial begin
        if(!$value$plusargs("CASES=%s",cases_path) || !$value$plusargs("TRACE=%s",trace_path))$fatal(1,"paths");
        fd=$fopen(cases_path,"r");trace_fd=$fopen(trace_path,"w");if(!fd || !trace_fd)$fatal(1,"files");
        tick();@(negedge clk);rst=0;
        for(fi=0;fi<FRAMES;fi=fi+1)begin
            rc=$fscanf(fd,"%d %d %d %d %h %h %d %d %d\n",nbeats,na,nb,error_code,header_tag,header_score,expected_latency,npath,ncells);
            if(rc!=9 || nbeats>MB || npath>2*MAX_POINTS)$fatal(1,"fixture header");
            ci=0;cj=0;
            for(k=0;k<nbeats;k=k+1)begin
                rc=$fscanf(fd,"%d %d %d %d %d %d %d %h\n",ka[k],xa[k],ya[k],kb[k],xb[k],yb[k],lasts[k],tags[k]);
                if(rc!=8)$fatal(1,"fixture token");
                if(ka[k] && ci<MAX_POINTS)begin ax[ci]=xa[k];ay[ci]=ya[k];ci=ci+1;end
                if(kb[k] && cj<MAX_POINTS)begin bx[cj]=xb[k];by[cj]=yb[k];cj=cj+1;end
            end
            if(error_code==0)for(ci=0;ci<na;ci=ci+1)for(cj=0;cj<nb;cj=cj+1)begin
                rc=$fscanf(fd,"%h %d\n",fixture_score,fixture_direction);if(rc!=2)$fatal(1,"fixture score");
                scores[ci*MAX_POINTS+cj]=fixture_score;directions[ci*MAX_POINTS+cj]=fixture_direction;
            end
            for(k=0;k<npath;k=k+1)begin rc=$fscanf(fd,"%h\n",expected[k]);if(rc!=1)$fatal(1,"fixture output");end
            track=1;
            for(k=0;k<nbeats;k=k+1)begin
                if(fi%3==0 && k%2==1)begin @(negedge clk);s_valid=0;tick();end
                drive_token(ka[k],xa[k],ya[k],kb[k],xb[k],yb[k],lasts[k],tags[k]);
                if(ticks==last_accept+1)ii1_checks=ii1_checks+1;
                last_accept=ticks;beats=beats+1;
            end
            final_tick=ticks;stop_source();wait_valid(expected_latency+2);observed_delay=ticks-final_tick;
            if(observed_delay!=expected_latency)$fatal(1,"first latency frame%0d got%0d want%0d",fi,observed_delay,expected_latency);
            latency_checks=latency_checks+1;
            for(oi=0;oi<npath;oi=oi+1)begin
                wait_valid(4);
                if(packed_output!==expected[oi])$fatal(1,"output frame%0d pair%0d got%h want%h",fi,oi,packed_output,expected[oi]);
                $fdisplay(trace_fd,"%h %0d",packed_output,(oi==0)?observed_delay:-1);
                hold_pair(1+(outputs%3));retire_pair();outputs=outputs+1;
            end
            track=0;frames=frames+1;
            repeat(2)begin tick();if(m_valid || !s_ready)$fatal(1,"retirement/next-frame ownership");end
        end
        rc=$fscanf(fd,"%d",code);if(rc==1)$fatal(1,"unconsumed fixture");$fclose(fd);$fclose(trace_fd);
        rn=(MAX_POINTS>=3)?3:1;
        for(target=0;target<20;target=target+1)begin
            if(!(target==16 && MAX_POINTS==1))begin
                if(target==1)begin drive_token(0,1,-1,0,-1,1,0,1);stop_source();end
                else if(target>=2)begin
                    if(target==18 || target==19)begin
                        for(k=0;k<=MAX_POINTS;k=k+1)drive_token(1,0,0,0,0,0,k==MAX_POINTS,3);
                    end else for(k=0;k<rn;k=k+1)drive_token(1,k-1,k-1,1,k-1,k-1,k==rn-1,5);
                    stop_source();
                    guard=0;code=0;
                    while(!code)begin
                        case(target)
                            2:code=dut.state==1;
                            3:code=dut.state==2;
                            4:code=dut.state==3;
                            5:code=dut.state==4 && dut.bit_index==0;
                            6:code=dut.state==4 && dut.bit_index==COORD_W-1;
                            7:code=dut.state==5;
                            8:code=dut.state==6 && dut.bit_index==0;
                            9:code=dut.state==6 && dut.bit_index==COORD_W-1;
                            10:code=dut.state==7 && dut.i==0 && dut.j==0;
                            11:code=dut.state==7 && dut.i==0 && dut.j==rn-1;
                            12:code=dut.state==7 && dut.i==rn-1 && dut.j==rn-1;
                            13:code=dut.state==8;
                            14:code=dut.state==9;
                            15:code=m_valid && m_first;
                            16:code=m_valid && !m_first && !m_last;
                            17:code=m_valid && m_last;
                            18:code=m_valid && m_errors==6;
                            19:code=dut.state==1;
                        endcase
                        if(!code)begin
                            if(m_valid && (target==16 || target==17))retire_pair();else tick();
                            guard=guard+1;if(guard>rn*rn*(2*COORD_W+4)+100)$fatal(1,"reset target unreachable%0d",target);
                        end
                    end
                    if(target>=15 && target<=18)begin
                        @(negedge clk);s_valid=1;s_a_keep=0;s_b_keep=0;s_last=1;s_tag=0;
                        held=packed_output;
                        repeat(3)begin tick();source_stalls=source_stalls+1;
                            if(s_ready || !m_valid || packed_output!==held)$fatal(1,"blocked source before reset");end
                    end
                end
                cancel_now();
            end
        end
        $display("PASS frames=%0d beats=%0d outputs=%0d cells=%0d multiply_steps=%0d ii1_checks=%0d read_checks=%0d predecessor_checks=%0d trace_checks=%0d latency_checks=%0d reset_probes=%0d fresh_checks=%0d held_cycles=%0d source_stalls=%0d state_mask=%0d",
            frames,beats,outputs,cells,multiply_steps,ii1_checks,read_checks,predecessor_checks,trace_checks,latency_checks,reset_probes,fresh_checks,held_cycles,source_stalls,state_mask);
        $finish;
    end
endmodule
`default_nettype wire
