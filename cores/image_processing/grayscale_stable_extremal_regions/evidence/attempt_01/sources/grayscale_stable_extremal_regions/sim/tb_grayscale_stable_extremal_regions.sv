// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_grayscale_stable_extremal_regions;
    parameter WIDTH=8,HEIGHT=8,CONNECTIVITY=4,TAG_W=8;
    localparam N=WIDTH*HEIGHT,IW=(N<2)?1:$clog2(N),CW=(N<2)?1:$clog2(N+1);
    localparam R=2*HEIGHT*(WIDTH-1)+2*WIDTH*(HEIGHT-1)+((CONNECTIVITY==8)?4*(WIDTH-1)*(HEIGHT-1):0);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,cfg_bright=0,m_ready=0;
    reg [7:0] s_pixel=0,cfg_delta=0,cfg_variation_p=0,cfg_variation_q=0;
    reg [CW-1:0] cfg_min_area=0,cfg_max_area=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_canonical,m_selected,m_sof,m_eol,m_last;
    wire [IW-1:0] m_index,m_parent;wire [7:0] m_level;
    wire [CW-1:0] m_area,m_variation_num,m_variation_den;
    wire [2:0] m_errors;wire [TAG_W-1:0] m_tag;
    grayscale_stable_extremal_regions #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.CONNECTIVITY(CONNECTIVITY),.TAG_W(TAG_W)) dut(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),
        .cfg_bright(cfg_bright),.cfg_delta(cfg_delta),.cfg_variation_p(cfg_variation_p),.cfg_variation_q(cfg_variation_q),
        .cfg_min_area(cfg_min_area),.cfg_max_area(cfg_max_area),.m_valid(m_valid),.m_ready(m_ready),
        .m_index(m_index),.m_parent(m_parent),.m_level(m_level),.m_area(m_area),.m_variation_num(m_variation_num),
        .m_variation_den(m_variation_den),.m_canonical(m_canonical),.m_selected(m_selected),
        .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_errors(m_errors),.m_tag(m_tag));
    integer input_fd,expected_fd,probe_fd,input_cases,expected_cases,probe_cases;
    integer mode,first_reset,reset_count,rid,driver_seq,driver_bright,driver_delta,driver_min,driver_max,driver_p,driver_q,driver_tag,driver_error;
    integer expected_seq,expected_error,expected_tag,completed=0,cycle=0,last_input_cycle=0;
    integer H=0,A=0,B=0,E=0,F=0,first_latency=0,frame_outputs=0,blocked=0,holds=0,hold_phase=0;
    integer accepted=0,watch=0,rc,i,j,tmp,number;
    integer e0,e1,e2,e3,e4,e5,e6,e7,e8,e9,e10,e11,e12;
    reg [7:0] input_pixels[0:N-1];reg input_sof[0:N-1],input_eol[0:N-1];
    reg started=0,score_enabled=0,probe_phase=0,cancel_probe=0,first_seen=0,all_outputs_done=0;
    reg prior_input_stall=0,prior_output_stall=0;
    reg [TAG_W+2*CW+34:0] prior_input;
    reg [2*IW+3*CW+TAG_W+15:0] prior_output;
    wire [TAG_W+2*CW+34:0] input_packet={s_pixel,s_sof,s_eol,s_tag,cfg_bright,cfg_delta,cfg_variation_p,cfg_variation_q,cfg_min_area,cfg_max_area};
    wire [2*IW+3*CW+TAG_W+15:0] output_packet={m_index,m_parent,m_level,m_area,m_variation_num,m_variation_den,m_canonical,m_selected,m_sof,m_eol,m_last,m_errors,m_tag};
    string group_name,input_name,expected_name,probe_name,token;

    task load_input(input integer fd);
        integer z,index_value,pixel_value,sof_value,eol_value;
        begin
            z=$fscanf(fd,"%s %d %d %d %d %d %d %d %d %d\n",token,driver_seq,driver_bright,driver_delta,driver_min,driver_max,driver_p,driver_q,driver_tag,driver_error);
            if(z!=10 || token!="C")$fatal(1,"input header");
            for(integer t=0;t<N;t=t+1)begin
                z=$fscanf(fd,"%s %d %d %d %d\n",token,index_value,pixel_value,sof_value,eol_value);
                if(z!=5 || token!="I" || index_value!=t || pixel_value<0 || pixel_value>255 || sof_value<0 || sof_value>1 || eol_value<0 || eol_value>1)$fatal(1,"input scalar tuple");
                input_pixels[t]=pixel_value;input_sof[t]=sof_value;input_eol[t]=eol_value;
            end
        end
    endtask
    task load_expected_header;
        integer z;
        begin
            z=$fscanf(expected_fd,"%s %d %d %d\n",token,expected_seq,expected_error,expected_tag);
            if(z!=4 || token!="C")$fatal(1,"expected header");
        end
    endtask
    task finish_file(input integer fd);
        integer z;
        begin z=$fscanf(fd,"%s",token);if(z!=1 || token!="END")$fatal(1,"END required");
            z=$fscanf(fd,"%s",token);if(z!=-1)$fatal(1,"trailing token");end
    endtask
    task offer_terminal;
        begin
            @(negedge clk);s_valid=1;s_pixel=8'ha5;s_sof=1;s_eol=(WIDTH==1);s_tag='1;
            cfg_bright=0;cfg_delta=1;cfg_min_area=1;cfg_max_area=N;cfg_variation_p=1;cfg_variation_q=1;
        end
    endtask
    task drive_pixels(input integer is_probe);
        integer t,waits;
        begin:drive_body
            for(t=0;t<N;t=t+1)begin
                if(t>0 && t%5==2)begin
                    @(negedge clk);s_valid=0;@(posedge clk);
                    if(is_probe && cancel_probe)disable drive_body;
                end
                @(negedge clk);
                if(is_probe && cancel_probe)begin s_valid=0;disable drive_body;end
                s_valid=1;s_pixel=input_pixels[t];s_sof=input_sof[t];s_eol=input_eol[t];
                s_tag=driver_tag^(t!=0);
                cfg_bright=(t==0)?driver_bright:!driver_bright;cfg_delta=(t==0)?driver_delta:0;
                cfg_min_area=(t==0)?driver_min:0;cfg_max_area=(t==0)?driver_max:0;
                cfg_variation_p=(t==0)?driver_p:0;cfg_variation_q=(t==0)?driver_q:0;
                waits=0;
                begin:wait_accepted
                    forever begin
                        @(posedge clk);
                        if(is_probe && cancel_probe)disable drive_body;
                        if(s_ready)disable wait_accepted;
                        waits=waits+1;if(waits>900000)$fatal(1,"input ownership watchdog");
                    end
                end
            end
        end
    endtask
    function target(input integer id);
        begin
            case(id)
                0:target=dut.state==0 && dut.capture_index==3;
                1:target=dut.state==1 && dut.dependency.tree.state==3;
                2:target=dut.state==1 && dut.dependency.tree.state==22;
                3:target=dut.state==1 && dut.tree_valid && dut.tree_index==3;
                4:target=dut.state==4 && dut.walk!=dut.own_parent;
                5:target=dut.state==11 && dut.mul_purpose==2 && dut.mul_step==4;
                6:target=dut.state==17 && dut.selected_choice;
                7:target=m_valid && m_index==0 && !m_ready;
                8:target=m_valid && m_index==N-1 && !m_ready;
                9:target=m_valid && m_errors==4 && !m_ready;
                default:target=0;
            endcase
        end
    endfunction
    // Deterministic two-cycle hold on EVERY scored output, including error and
    // final output. Probe8 drains only the prefix and holds the true final record.
    always @(negedge clk)begin
        if(rst || !started)m_ready=0;
        else if(probe_phase)begin
            if((rid==7 && m_index==0) || (rid==8 && m_index==N-1) || rid==9)m_ready=0;
            else m_ready=1;
        end else if(m_valid && hold_phase>=2)m_ready=1;
        else m_ready=0;
        if(!rst && score_enabled && m_valid)begin
            if(!first_seen)begin
                first_seen=1;first_latency=cycle-last_input_cycle;
                if(m_errors!=0)tmp=N+1;
                else tmp=3*256+(20+2*CONNECTIVITY)*N+WIDTH*HEIGHT*(HEIGHT-1)/2+2*R+2*H+3+12*N+2*A+2*B+22*E+20*F-1;
                if(first_latency!=tmp)$fatal(1,"exact first latency got=%0d expected=%0d",first_latency,tmp);
            end
            if(hold_phase<2)hold_phase=hold_phase+1;
        end
    end
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin
            if(s_ready!==0 || m_valid!==0 || m_sof!==0 || m_eol!==0 || m_last!==0)$fatal(1,"reset gating");
            prior_input_stall=0;prior_output_stall=0;H=0;A=0;B=0;E=0;F=0;accepted=0;
            first_seen=0;frame_outputs=0;blocked=0;holds=0;hold_phase=0;watch=0;
        end else if(started)begin
            watch=watch+1;if(watch>900000)$fatal(1,"frame watchdog");
            if(prior_input_stall && (!s_valid || input_packet!==prior_input))$fatal(1,"source changed held beat");
            if(prior_output_stall && (!m_valid || output_packet!==prior_output))$fatal(1,"output changed held record");
            prior_input_stall=s_valid&&!s_ready;prior_output_stall=m_valid&&!m_ready;
            prior_input=input_packet;prior_output=output_packet;
            if(s_valid && s_ready)begin
                if(dut.capture_index==0)begin
                    H=0;A=0;B=0;E=0;F=0;accepted=0;first_seen=0;frame_outputs=0;blocked=0;holds=0;hold_phase=0;watch=0;
                end
                if(dut.capture_index!==accepted)$fatal(1,"input index");
                if(probe_phase)$display("PIN %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",driver_seq,accepted,s_pixel,s_sof,s_eol,s_tag,cfg_bright,cfg_delta,cfg_min_area,cfg_max_area,cfg_variation_p,cfg_variation_q);
                else $display("IN %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",driver_seq,accepted,s_pixel,s_sof,s_eol,s_tag,cfg_bright,cfg_delta,cfg_min_area,cfg_max_area,cfg_variation_p,cfg_variation_q);
                accepted=accepted+1;if(accepted==N)last_input_cycle=cycle;
            end
            if(dut.dependency.tree.state==18 || dut.dependency.tree.state==20)H=H+1;
            if(dut.state==4)A=A+1;if(dut.state==9)B=B+1;if(dut.state==13)E=E+1;
            if(dut.state==11 && dut.mul_purpose==2 && dut.mul_step==0)F=F+1;
            if(s_valid && !s_ready)blocked=blocked+1;
            if(m_valid && (^output_packet===1'bx))$fatal(1,"unknown output field");
            if(m_valid && score_enabled)begin
                if(!s_valid || s_ready)$fatal(1,"next real offer absent or admitted before retirement");
                if(!m_ready)holds=holds+1;
            end
            if(m_valid && m_ready && probe_phase)
                $display("POUT %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",200+rid,m_index,m_parent,m_level,m_area,m_variation_num,m_variation_den,m_canonical,m_selected,m_errors,m_tag,m_sof,m_eol,m_last);
            if(m_valid && m_ready && score_enabled)begin
                rc=$fscanf(expected_fd,"%s %d %d %d %d %d %d %d %d %d %d %d %d %d\n",token,e0,e1,e2,e3,e4,e5,e6,e7,e8,e9,e10,e11,e12);
                if(rc!=14 || token!="O")$fatal(1,"expected scalar output");
                if(m_index!==e0 || m_parent!==e1 || m_level!==e2 || m_area!==e3 || m_variation_num!==e4 || m_variation_den!==e5 ||
                    m_canonical!==e6 || m_selected!==e7 || m_errors!==e8 || m_tag!==e9 || m_sof!==e10 || m_eol!==e11 || m_last!==e12)$fatal(1,"complete output tuple seq=%0d index=%0d",expected_seq,m_index);
                $display("OUT %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",expected_seq,m_index,m_parent,m_level,m_area,m_variation_num,m_variation_den,m_canonical,m_selected,m_errors,m_tag,m_sof,m_eol,m_last);
                frame_outputs=frame_outputs+1;hold_phase=0;
                if(m_last)begin
                    if(frame_outputs!=N || holds<2*N || blocked<1)$fatal(1,"frame/hold/offer coverage");
                    $display("REC %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",expected_seq,H,A,B,E,F,first_latency,frame_outputs,blocked,holds);
                    completed=completed+1;
                    if(completed==expected_cases)all_outputs_done=1;else load_expected_header();
                end
            end
        end
    end
    initial begin
        if(!$value$plusargs("GROUP=%s",group_name) || !$value$plusargs("INPUT=%s",input_name) || !$value$plusargs("EXPECTED=%s",expected_name) || !$value$plusargs("MODE=%d",mode))$fatal(1,"fixed plusargs");
        input_fd=$fopen(input_name,"r");expected_fd=$fopen(expected_name,"r");
        if(!input_fd || !expected_fd)$fatal(1,"fixture open");
        rc=$fscanf(input_fd,"%d\n",input_cases);if(rc!=1)$fatal(1,"input count");
        rc=$fscanf(expected_fd,"%d\n",expected_cases);if(rc!=1 || expected_cases!=input_cases || expected_cases<1)$fatal(1,"expected count");
        load_expected_header();repeat(2)@(posedge clk);@(negedge clk);rst=0;started=1;
        if(mode==0)begin
            score_enabled=1;
            for(j=0;j<input_cases;j=j+1)begin load_input(input_fd);drive_pixels(0);end
            finish_file(input_fd);offer_terminal();wait(all_outputs_done);@(negedge clk);s_valid=0;
        end else if(mode==1)begin
            if(!$value$plusargs("PROBE=%s",probe_name) || !$value$plusargs("FIRST=%d",first_reset) || !$value$plusargs("COUNT=%d",reset_count))$fatal(1,"reset plusargs");
            probe_fd=$fopen(probe_name,"r");if(!probe_fd)$fatal(1,"probe open");
            rc=$fscanf(probe_fd,"%d\n",probe_cases);if(rc!=1 || probe_cases!=reset_count || reset_count!=input_cases)$fatal(1,"probe count");
            load_input(probe_fd);
            for(j=0;j<reset_count;j=j+1)begin
                rid=first_reset+j;cancel_probe=0;
                if(driver_seq!=200+rid)$fatal(1,"probe id");
                fork
                    begin drive_pixels(1);if(!cancel_probe)offer_terminal();end
                    begin:reset_observer
                        // A following probe is the REAL next frame offer while
                        // the previous fresh frame drains. Only change sink
                        // ownership after that fresh frame has retired.
                        wait(completed==j);@(negedge clk);probe_phase=1;score_enabled=0;
                        for(integer timeout=0;timeout<900000;timeout=timeout+1)begin
                            @(negedge clk);#1;
                            if(target(rid))begin
                                $display("RESET %0d %0d %0d %0d %0d %0d",rid,dut.state,dut.dependency.tree.state,dut.mul_purpose,dut.mul_step,m_index);
                                rst=1;cancel_probe=1;s_valid=0;
                                if(s_ready!==0 || m_valid!==0)begin #0;if(s_ready!==0 || m_valid!==0)$fatal(1,"immediate cancel gating");end
                                repeat(2)@(posedge clk);@(negedge clk);rst=0;disable reset_observer;
                            end
                        end
                        $fatal(1,"fixed reset target unreachable");
                    end
                join
                @(negedge clk);s_valid=0;probe_phase=0;score_enabled=1;
                load_input(input_fd);if(driver_seq!=100+rid)$fatal(1,"fresh id");
                drive_pixels(0);
                if(j+1<reset_count)load_input(probe_fd);
                else begin
                    offer_terminal();wait(completed==j+1);@(negedge clk);s_valid=0;score_enabled=0;
                end
            end
            finish_file(input_fd);finish_file(probe_fd);$fclose(probe_fd);
        end else $fatal(1,"mode");
        finish_file(expected_fd);$fclose(input_fd);$fclose(expected_fd);
        $display("PASS group=%s cases=%0d resets=%0d",group_name,expected_cases,(mode==1)?reset_count:0);$finish;
    end
endmodule
