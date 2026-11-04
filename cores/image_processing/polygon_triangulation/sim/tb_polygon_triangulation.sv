// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_polygon_triangulation;
    parameter integer COORD_W=8,MAX_VERTICES=16,TAG_W=8;
    localparam integer IW=$clog2(MAX_VERTICES),CW=$clog2(MAX_VERTICES+1);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid;
    reg signed [COORD_W-1:0] s_x=0,s_y=0;
    reg s_keep=0,s_last=0,s_error=0;
    reg [TAG_W-1:0] s_tag=0;
    wire [IW-1:0] m_id0,m_id1,m_id2,m_index;
    wire signed [COORD_W-1:0] m_x0,m_y0,m_x1,m_y1,m_x2,m_y2;
    wire [CW-1:0] m_vertices,m_count;
    wire [3:0] m_error;wire m_first,m_last;wire [TAG_W-1:0] m_tag;
    polygon_triangulation #(.COORD_W(COORD_W),.MAX_VERTICES(MAX_VERTICES),.TAG_W(TAG_W)) dut(.*);
    integer f_target[0:999],f_ostart[0:999],f_on[0:999],f_istart[0:999],f_in[0:999];
    integer f_estart[0:999],f_out[0:999],f_v[0:999],f_err[0:999],f_tag[0:999],f_bound[0:999];
    integer ix[0:19999],iy[0:19999],ik[0:19999],il[0:19999],ie[0:19999],it[0:19999];
    integer ox[0:999],oy[0:999],ok[0:999],ol[0:999],oe[0:999],ot[0:999];
    integer e0[0:19999],e1[0:19999],e2[0:19999],ex0[0:19999],ey0[0:19999];
    integer ex1[0:19999],ey1[0:19999],ex2[0:19999],ey2[0:19999];
    integer nf=0,total_input=0,total_owner=0,total_expected=0,file_id,rc,j,k;
    integer ht,ho,hi,hout,hv,he,htag,hbound;
    reg [1023:0] fixture_path;reg [63:0] mode;
    integer phase=1,cycle=0,source_pos=0,advance=0,gap=0,last_input_fire=0;
    integer active=0,eframe=0,accepted_frames=0,done_frames=0,out_local=0;
    integer tail_seen=0,tail_cycle=0,first_seen=0,out_age=0,retire_cycle=0;
    integer checked_inputs=0,checked_outputs=0,queued=0,queued_pending=0;
    integer resets=0,fresh=0,fresh_done=0,reset_frame=0,target=0,guard=0;
    integer source_holds=0,output_holds=0,max_latency=0,mem_reads=0,det_checks=0;
    integer previous_source_hold=0,previous_output_hold=0;
    reg [2*COORD_W+TAG_W+2:0] source_word;
    reg [4*IW+6*COORD_W+2*CW+TAG_W+5:0] output_word;
    wire [2*COORD_W+TAG_W+2:0] current_source={s_x,s_y,s_keep,s_last,s_error,s_tag};
    wire [4*IW+6*COORD_W+2*CW+TAG_W+5:0] current_output={m_id0,m_id1,m_id2,m_x0,m_y0,m_x1,m_y1,m_x2,m_y2,m_vertices,m_count,m_index,m_error,m_first,m_last,m_tag};
    reg [63:0] states=0,targets=0,expected_targets=0;
    integer epoch=0,sx[0:31],sy[0:31],sr[0:31],st[0:29];
    integer xy_owner[0:31],ring_owner[0:31],triangle_owner[0:29];
    integer read_xy,read_ring,read_tri,read_det,rx,ry,rr,rt,det_expected;
    integer a0,a1,a2,ar;

    always @(negedge clk)begin
        if(!rst && phase==0)begin
            if(advance)begin source_pos=source_pos+1;advance=0;s_valid=0;gap=(source_pos%5==0);end
            if(gap>0)gap=gap-1;
            else if(!s_valid && source_pos<total_input)begin
                s_x=ix[source_pos];s_y=iy[source_pos];s_keep=ik[source_pos];s_last=il[source_pos];
                s_error=ie[source_pos];s_tag=it[source_pos];s_valid=1;
            end
        end
        if(phase==0 || phase==2)m_ready=(out_age>=3 && cycle%5!=1);
        else if(target==26)m_ready=(m_index==0);
        else if(target==27)m_ready=(m_index+1<m_count);
        else m_ready=0;
    end

    always @(posedge clk)begin
        cycle=cycle+1;last_input_fire=!rst && s_valid && s_ready;
        read_xy=0;read_ring=0;read_tri=0;read_det=0;
        if(rst)begin
            active=0;tail_seen=0;first_seen=0;out_age=0;previous_source_hold=0;previous_output_hold=0;
        end else begin
            states=states|(64'b1<<dut.state);
            if(previous_source_hold)begin
                if(!s_valid || current_source!==source_word)$fatal(1,"source all-field hold");
                source_holds=source_holds+1;
            end
            if(previous_output_hold)begin
                if(!m_valid || current_output!==output_word)$fatal(1,"output all-field hold");
                output_holds=output_holds+1;
            end
            previous_source_hold=s_valid&&!s_ready;source_word=current_source;
            previous_output_hold=m_valid&&!m_ready;output_word=current_output;
            if(s_valid && s_ready && m_valid)$fatal(1,"overlapping command owners");
            if(dut.state==0 && last_input_fire)begin
                if(!dut.started)epoch=epoch+1;
                if(s_keep && dut.count<MAX_VERTICES)begin
                    sx[dut.count]=$signed(s_x);sy[dut.count]=$signed(s_y);sr[dut.count]=dut.count;
                    xy_owner[dut.count]=epoch;ring_owner[dut.count]=epoch;
                end
            end
            if(dut.state==37 && dut.load_ring)begin
                if(dut.load_index>=dut.live_n || ring_owner[dut.load_index]!==epoch)$fatal(1,"ring ownership");
                rr=sr[dut.load_index];read_ring=1;
            end
            if(dut.state==28)begin
                if(dut.vj+1>=dut.live_n || ring_owner[dut.vj+1]!==epoch)$fatal(1,"compact ownership");
                rr=sr[dut.vj+1];read_ring=1;
            end
            if(dut.state==29)begin sr[dut.vj]=dut.ring_q;ring_owner[dut.vj]=epoch;end
            if(dut.state==38)begin
                if(dut.coordinate_address>=dut.count || xy_owner[dut.coordinate_address]!==epoch)$fatal(1,"coordinate ownership");
                rx=sx[dut.coordinate_address];ry=sy[dut.coordinate_address];read_xy=1;
            end
            if(dut.state==26 || dut.state==32)begin
                a0=dut.triangle_word&((1<<IW)-1);a1=(dut.triangle_word>>IW)&((1<<IW)-1);a2=dut.triangle_word>>(2*IW);
                if(a0>=dut.count || a1>=dut.count || a2>=dut.count || a0==a1 || a0==a2 || a1==a2)$fatal(1,"triangle IDs");
                ar=(sx[a1]-sx[a0])*(sy[a2]-sy[a0])-(sy[a1]-sy[a0])*(sx[a2]-sx[a0]);
                if(ar<=0 || dut.tri_count>=MAX_VERTICES-2)$fatal(1,"triangle orientation/capacity");
                st[dut.tri_count]=dut.triangle_word;triangle_owner[dut.tri_count]=epoch;
            end
            if(dut.state==33)begin
                if(dut.out_index>=dut.tri_count || triangle_owner[dut.out_index]!==epoch)$fatal(1,"triangle ownership");
                rt=st[dut.out_index];read_tri=1;
            end
            if(dut.state==40)begin
                det_expected=($signed(dut.px[dut.det_b])-$signed(dut.px[dut.det_a]))*
                             ($signed(dut.py[dut.det_c])-$signed(dut.py[dut.det_a]))-
                             ($signed(dut.py[dut.det_b])-$signed(dut.py[dut.det_a]))*
                             ($signed(dut.px[dut.det_c])-$signed(dut.px[dut.det_a]));
            end
            if(dut.state==43)read_det=1;
            if(phase==0 || phase==2)begin
                if(phase==0 && s_valid && !s_ready)queued_pending=1;
                if(last_input_fire)begin
                    checked_inputs=checked_inputs+1;
                    if(!active)begin
                        active=1;out_local=0;first_seen=0;tail_seen=0;retire_cycle=0;
                        if(phase==0)begin
                            eframe=accepted_frames;
                            if(source_pos!=f_istart[eframe])$fatal(1,"input frame alignment");
                            if(accepted_frames>0)begin
                                if(!queued_pending)$fatal(1,"actual next frozen token never queued");queued=queued+1;
                            end
                            accepted_frames=accepted_frames+1;queued_pending=0;
                        end else eframe=reset_frame;
                    end
                    if(s_last)begin tail_seen=1;tail_cycle=cycle;end
                    if(phase==0)advance=1;
                end
                if(m_valid && m_ready)begin
                    if(!active)$fatal(1,"unowned result");
                    checked_outputs=checked_outputs+1;retire_cycle=cycle;
                    if(m_last)begin
                        active=0;
                        if(phase==0)done_frames=done_frames+1;else begin fresh=fresh+1;fresh_done=1;end
                    end else out_local=out_local+1;
                end
            end
            #1;
            if(read_xy)begin
                if($signed(dut.x_q)!==rx || $signed(dut.y_q)!==ry)$fatal(1,"synchronous coordinate read");mem_reads=mem_reads+1;
            end
            if(read_ring)begin if(dut.ring_q!==rr)$fatal(1,"synchronous ring read");mem_reads=mem_reads+1;end
            if(read_tri)begin if(dut.tri_q!==rt)$fatal(1,"synchronous triangle read");mem_reads=mem_reads+1;end
            if(read_det)begin if($signed(dut.cross_q)!==det_expected)$fatal(1,"exact shared determinant");det_checks=det_checks+1;end
            if((phase==0 || phase==2) && m_valid)begin
                if(!active || !tail_seen)$fatal(1,"output before complete owner");
                j=f_estart[eframe]+out_local;
                if(m_id0!==e0[j] || m_id1!==e1[j] || m_id2!==e2[j] ||
                   $signed(m_x0)!==ex0[j] || $signed(m_y0)!==ey0[j] ||
                   $signed(m_x1)!==ex1[j] || $signed(m_y1)!==ey1[j] ||
                   $signed(m_x2)!==ex2[j] || $signed(m_y2)!==ey2[j] ||
                   m_vertices!==f_v[eframe] || m_count!==((f_err[eframe]==0)?f_out[eframe]:0) ||
                   m_index!==out_local || m_error!==f_err[eframe] || m_tag!==f_tag[eframe] ||
                   m_first!==(out_local==0) || m_last!==(out_local+1==f_out[eframe]))
                    $fatal(1,"mesh/result mismatch frame=%0d output=%0d ids=%0d,%0d,%0d status=%0d",eframe,out_local,m_id0,m_id1,m_id2,m_error);
                if(!first_seen)begin
                    first_seen=1;
                    if(cycle-tail_cycle>f_bound[eframe])$fatal(1,"first-valid bound %0d>%0d",cycle-tail_cycle,f_bound[eframe]);
                    if(f_bound[eframe]==2 && cycle-tail_cycle!=2)$fatal(1,"short/error latency");
                    if(cycle-tail_cycle>max_latency)max_latency=cycle-tail_cycle;
                end else if(out_age==0 && cycle-retire_cycle!=11)$fatal(1,"replay schedule");
                out_age=out_age+1;
            end else out_age=0;
        end
    end

    function integer at_target(input integer t);
        begin
            case(t)
            0:at_target=dut.state==0 && !dut.started;
            1:at_target=dut.state==0 && dut.count==1 && dut.started;
            2:at_target=dut.state==0 && dut.count==0 && dut.started;
            3:at_target=dut.state==0 && dut.errors==1;
            4:at_target=dut.state==1 && dut.errors==0;
            5:at_target=dut.state==3 && (dut.px[0]!=dut.px[1] || dut.py[0]!=dut.py[1]);
            6:at_target=dut.state==6 && dut.cross_q==0 && dut.in_box(dut.px[1],dut.py[1],dut.px[0],dut.py[0],dut.px[2],dut.py[2]);
            7:at_target=dut.state==6 && dut.cross_q!=0;
            8:at_target=dut.state==9;9:at_target=dut.state==10;10:at_target=dut.state==11;
            11:at_target=dut.state==12 && !dut.intersection;
            12:at_target=dut.state==15 && dut.cross_q<0;
            13:at_target=dut.state==16 && dut.area_sum!=0;
            14:at_target=dut.state==19 && dut.strict_turn;
            15:at_target=dut.state==19 && dut.outside;
            16:at_target=dut.state==22 && dut.outside;
            17:at_target=dut.state==23 && dut.outside;
            18:at_target=dut.state==24 && !dut.outside;
            19:at_target=dut.state==26;
            20:at_target=dut.state==28 && dut.vj+1<dut.live_n-1;
            21:at_target=dut.state==29 && dut.vj+2==dut.live_n;
            22:at_target=dut.state==32;
            23:at_target=dut.state==33 && dut.out_index==0;
            24:at_target=dut.state==39 && dut.load_mode==7 && dut.load_slot==2;
            25:at_target=m_valid && m_error==0 && m_index==0 && !m_ready;
            26:at_target=m_valid && m_error==0 && m_index==1 && !m_ready;
            27:at_target=m_valid && m_error==0 && m_last && !m_ready;
            28:at_target=m_valid && m_error==1;
            29:at_target=m_valid && m_error==2;
            30:at_target=m_valid && m_error==4;
            31:at_target=dut.state==41;32:at_target=dut.state==42;33:at_target=dut.state==43;
            34:at_target=dut.state==37 && dut.load_ring;
            35:at_target=dut.state==38 && !dut.load_ring;
            36:at_target=dut.state==39 && dut.load_mode==5 && dut.load_slot==3;
            37:at_target=dut.state==12 && dut.intersection;
            38:at_target=dut.state==19 && dut.cross_q==0;
            39:at_target=m_valid && m_error==3;
            default:at_target=0;
            endcase
        end
    endfunction

    task automatic drive(input integer position,input integer is_owner);
        begin
            @(negedge clk);
            if(is_owner)begin s_x=ox[position];s_y=oy[position];s_keep=ok[position];s_last=ol[position];s_error=oe[position];s_tag=ot[position];end
            else begin s_x=ix[position];s_y=iy[position];s_keep=ik[position];s_last=il[position];s_error=ie[position];s_tag=it[position];end
            s_valid=1;guard=0;
            begin:accept_loop
                forever begin
                    @(posedge clk);#2;if(last_input_fire)disable accept_loop;
                    guard=guard+1;if(guard>100)$fatal(1,"drive acceptance watchdog");
                end
            end
        end
    endtask

    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture_path) || !$value$plusargs("MODE=%s",mode))$fatal(1,"missing fixture/mode");
        file_id=$fopen(fixture_path,"r");if(!file_id)$fatal(1,"open fixture");
        while(!$feof(file_id))begin
            rc=$fscanf(file_id,"%d %d %d %d %d %d %d %d\n",ht,ho,hi,hout,hv,he,htag,hbound);
            if(rc==8)begin
                if(nf>=1000 || total_input+hi>=20000 || total_expected+hout>=20000 || total_owner+ho>=1000)$fatal(1,"fixture capacity");
                f_target[nf]=ht;f_ostart[nf]=total_owner;f_on[nf]=ho;f_istart[nf]=total_input;f_in[nf]=hi;
                f_estart[nf]=total_expected;f_out[nf]=hout;f_v[nf]=hv;f_err[nf]=he;f_tag[nf]=htag;f_bound[nf]=hbound;
                for(k=0;k<ho;k=k+1)begin
                    rc=$fscanf(file_id,"%d %d %d %d %d %d\n",ox[total_owner],oy[total_owner],ok[total_owner],ol[total_owner],oe[total_owner],ot[total_owner]);
                    if(rc!=6)$fatal(1,"owner parse");total_owner=total_owner+1;
                end
                for(k=0;k<hi;k=k+1)begin
                    rc=$fscanf(file_id,"%d %d %d %d %d %d\n",ix[total_input],iy[total_input],ik[total_input],il[total_input],ie[total_input],it[total_input]);
                    if(rc!=6)$fatal(1,"input parse");total_input=total_input+1;
                end
                for(k=0;k<hout;k=k+1)begin
                    rc=$fscanf(file_id,"%d %d %d %d %d %d %d %d %d\n",e0[total_expected],e1[total_expected],e2[total_expected],ex0[total_expected],ey0[total_expected],ex1[total_expected],ey1[total_expected],ex2[total_expected],ey2[total_expected]);
                    if(rc!=9)$fatal(1,"output parse");total_expected=total_expected+1;
                end
                if(ht>=0)begin
                    if(expected_targets&(64'b1<<ht))$fatal(1,"duplicate target");expected_targets=expected_targets|(64'b1<<ht);
                    if(hv!=MAX_VERTICES || he!=0 || hout!=MAX_VERTICES-2)$fatal(1,"fresh must use full capacity");
                end
                nf=nf+1;
            end else if(rc!=-1)$fatal(1,"header parse");
        end
        $fclose(file_id);if(nf==0)$fatal(1,"empty fixture");
        repeat(2)@(negedge clk);rst=0;
        if(mode=="main")begin
            phase=0;guard=0;
            while(done_frames<nf)begin
                @(negedge clk);guard=guard+1;
                if(guard>nf*(230469+20*MAX_VERTICES+100))$fatal(1,"main watchdog");
            end
            phase=1;s_valid=0;m_ready=0;
            if(accepted_frames!=nf || queued!=nf-1)$fatal(1,"main ownership/queue totals");
        end else if(mode=="reset")begin
            for(reset_frame=0;reset_frame<nf;reset_frame=reset_frame+1)begin
                target=f_target[reset_frame];phase=1;m_ready=0;s_valid=0;
                for(k=0;k<f_on[reset_frame];k=k+1)drive(f_ostart[reset_frame]+k,1);
                if(f_on[reset_frame]>0)begin @(negedge clk);s_valid=0;end
                guard=0;
                while(!at_target(target))begin
                    @(negedge clk);guard=guard+1;if(guard>230469+20*MAX_VERTICES+100)$fatal(1,"reset target unreachable %0d state=%0d",target,dut.state);
                end
                states=states|(64'b1<<dut.state);targets=targets|(64'b1<<target);
                $display("OBS target=%0d state=%0d mode=%0d slot=%0d vi=%0d vj=%0d cross=%0d",target,dut.state,dut.load_mode,dut.load_slot,dut.vi,dut.vj,dut.cross_q);
                rst=1;resets=resets+1;#1;
                if(s_ready!==0 || m_valid!==0 || m_first!==0 || m_last!==0)$fatal(1,"immediate reset gating");
                @(posedge clk);#2;
                if(dut.state!==0 || dut.count!==0 || m_error!==0 || m_tag!==0)$fatal(1,"reset owner/public clear");
                @(negedge clk);rst=0;phase=2;fresh_done=0;
                for(k=0;k<f_in[reset_frame];k=k+1)drive(f_istart[reset_frame]+k,0);
                @(negedge clk);s_valid=0;guard=0;
                while(!fresh_done)begin
                    @(negedge clk);guard=guard+1;if(guard>f_bound[reset_frame]+20*MAX_VERTICES+100)$fatal(1,"fresh watchdog");
                end
                if(m_valid || dut.state!=0)$fatal(1,"fresh not completely retired");
                phase=1;m_ready=0;
            end
            if(targets!==expected_targets || fresh!=nf || resets!=nf)$fatal(1,"reset mask/totals");
        end else $fatal(1,"unknown mode");
        repeat(3)begin @(negedge clk);if(m_valid)$fatal(1,"stale output");end
        if(checked_inputs!=total_input || checked_outputs!=total_expected || output_holds==0)$fatal(1,"checked totals");
        $display("PASS mode=%0s frames=%0d inputs=%0d outputs=%0d queued=%0d resets=%0d fresh=%0d targets=%h states=%h max_latency=%0d source_holds=%0d output_holds=%0d mem_reads=%0d det_checks=%0d",
            mode,nf,checked_inputs,checked_outputs,queued,resets,fresh,targets,states,max_latency,source_holds,output_holds,mem_reads,det_checks);
        $finish;
    end
endmodule
