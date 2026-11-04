// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_streaming_gldm;
    parameter integer WIDTH=3,HEIGHT=3,PIXEL_W=1,GRAY_W=1,TAG_W=8,FRAMES=1,MATCHES=0;
    localparam integer N=WIDTH*HEIGHT,CW=(N<2)?1:$clog2(N+1),HD=1<<(GRAY_W+4),DENSE=9*(1<<GRAY_W),
        GRID=(WIDTH+2)*(HEIGHT+2),DEGREE=2*HEIGHT*(WIDTH-1)+2*WIDTH*(HEIGHT-1)+4*(WIDTH-1)*(HEIGHT-1),
        RW=TAG_W+8+2*GRAY_W+CW,IW=TAG_W+2+GRAY_W+PIXEL_W,
        BOUND=3*GRID+2*N+2*DENSE+2*HD+100;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0;
    reg [PIXEL_W-1:0] s_pixel=0;
    reg [GRAY_W-1:0] s_alpha=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_first,m_last;
    wire [1:0] m_errors;
    wire [GRAY_W-1:0] m_gray,m_alpha;
    wire [3:0] m_dependence;
    wire [CW-1:0] m_count;
    wire [TAG_W-1:0] m_tag;
    streaming_gldm #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PIXEL_W(PIXEL_W),.GRAY_W(GRAY_W),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_last,m_first,m_alpha,m_gray,m_dependence,m_count};
    wire [IW-1:0] request={s_tag,s_eol,s_sof,s_alpha,s_pixel};
    reg [RW-1:0] expected[0:FRAMES*DENSE-1],fresh_expected[0:DENSE-1];
    reg [31:0] latency[0:FRAMES-1],frame_matches[0:FRAMES-1];
    reg checking=0,held=0,source_held=0,await_first=0;
    reg [RW-1:0] held_response;
    reg [IW-1:0] held_request;
    reg [7:0] expected_mask;
    integer cycle=0,inputs=0,outputs=0,tail_cycle=0,tail_frame=0,first_checks=0;
    integer stalls=0,source_stalls=0,grid_checks=0,line_checks=0,center_checks=0,inside_checks=0,match_checks=0,hist_checks=0;
    integer frame_grids=0,frame_centers=0,frame_inside=0,frame_matched=0,valid_neighbors=0;
    integer reset_probes=0,fresh_checks=0,sum_counts=0,sum_weighted=0,last_input=-100,last_output=-100,lane;
    always @(negedge clk)if(checking&&!rst)m_ready=(cycle%23)>=9;
    always @(posedge clk)begin
        cycle=cycle+1;if(cycle>10000000)$fatal(1,"bounded watchdog");
        if(rst)begin held=0;source_held=0;await_first=0;end
        else begin
            if(held&&(!m_valid||response!==held_response))$fatal(1,"held output changed");
            if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source hold violated");
            held=m_valid&&!m_ready;held_response=response;
            source_held=s_valid&&!s_ready;held_request=request;
            if(dut.pad_x>WIDTH+1||dut.pad_y>HEIGHT+1)$fatal(1,"line address bounds");
            if(dut.state==3 && dut.center_now)begin
                if(dut.middle1[GRAY_W]!==1'b1 || dut.dependence_now<1 || dut.dependence_now>9)$fatal(1,"center/dependence bounds");
                expected_mask[0]=(dut.pad_x>2 && dut.pad_y>2);
                expected_mask[1]=(dut.pad_y>2);
                expected_mask[2]=(dut.pad_x<WIDTH+1 && dut.pad_y>2);
                expected_mask[3]=(dut.pad_x>2);
                expected_mask[4]=(dut.pad_x<WIDTH+1);
                expected_mask[5]=(dut.pad_x>2 && dut.pad_y<HEIGHT+1);
                expected_mask[6]=(dut.pad_y<HEIGHT+1);
                expected_mask[7]=(dut.pad_x<WIDTH+1 && dut.pad_y<HEIGHT+1);
                if(dut.neighbor_valid!==expected_mask || (dut.match_bits & ~expected_mask)!=0)$fatal(1,"invalid padding counted as image");
            end
            if(dut.state==5 && dut.hist_q>=N)$fatal(1,"histogram overflow");
            if(m_valid && (m_dependence<1||m_dependence>9||m_count>N))$fatal(1,"dense result bounds");
            if(checking)begin
                if(m_valid&&s_ready)$fatal(1,"overlapped frame ownership");
                if(s_valid&&!s_ready)source_stalls=source_stalls+1;
                if(m_valid&&!m_ready)stalls=stalls+1;
                if(dut.state==2)line_checks=line_checks+1;
                if(dut.state==3)begin
                    grid_checks=grid_checks+1;frame_grids=frame_grids+1;
                    if(dut.center_now)begin
                        valid_neighbors=0;for(lane=0;lane<8;lane=lane+1)valid_neighbors=valid_neighbors+dut.neighbor_valid[lane];
                        center_checks=center_checks+1;frame_centers=frame_centers+1;
                        inside_checks=inside_checks+valid_neighbors;frame_inside=frame_inside+valid_neighbors;
                        match_checks=match_checks+dut.dependence_now-1;frame_matched=frame_matched+dut.dependence_now-1;
                    end
                end
                if(dut.state==5)hist_checks=hist_checks+1;
                if(s_valid&&s_ready)begin
                    if(cycle-last_input<3)$fatal(1,"input scheduling II");last_input=cycle;
                    inputs=inputs+1;if(inputs%N==0)begin tail_cycle=cycle;tail_frame=inputs/N-1;await_first=1;end
                end
                if(m_valid&&m_ready)begin
                    if(cycle-last_output<2)$fatal(1,"output II");last_output=cycle;
                    if(outputs>=FRAMES*DENSE||response!==expected[outputs])
                        $fatal(1,"dependence matrix mismatch %0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs=outputs+1;sum_counts=sum_counts+m_count;sum_weighted=sum_weighted+m_dependence*m_count;
                    if(m_last)begin
                        if(sum_counts!=((m_errors==0)?N:0) || sum_weighted!=((m_errors==0)?N+frame_matches[outputs/DENSE-1]:0))
                            $fatal(1,"center/dependence conservation");
                        sum_counts=0;sum_weighted=0;
                    end
                end
            end
        end
        #1;
        if(checking&&!rst&&await_first&&m_valid)begin
            if(cycle-tail_cycle!=latency[tail_frame])$fatal(1,"tail latency got=%0d expected=%0d",cycle-tail_cycle,latency[tail_frame]);
            if(frame_grids!=GRID || frame_centers!=N || frame_inside!=DEGREE || frame_matched!=frame_matches[tail_frame])$fatal(1,"per-frame line/neighbor service");
            frame_grids=0;frame_centers=0;frame_inside=0;frame_matched=0;
            await_first=0;first_checks=first_checks+1;
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset transfer gate");
            @(negedge clk);rst=0;
            #1;if(m_valid||dut.state!==0||dut.clear_index!==0||dut.pad_x!==0||dut.pad_y!==0||dut.errors!==0)
                $fatal(1,"reset cancellation");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic ready_again;
        integer waited;
        begin
            waited=0;
            while(!s_ready)begin @(negedge clk);waited=waited+1;if(waited>HD+3*(WIDTH+3)+10)$fatal(1,"clear/warmup stuck");end
        end
    endtask
    task automatic send(input[PIXEL_W-1:0] pixel,input[GRAY_W-1:0] alpha,input sof,eol,input[TAG_W-1:0] tag);
        begin
            s_valid=1;s_pixel=pixel;s_alpha=alpha;s_sof=sof;s_eol=eol;s_tag=tag;
            @(posedge clk);while(!s_ready)@(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    task automatic fill(input bad);
        integer j;
        begin
            ready_again();@(negedge clk);
            for(j=0;j<N;j=j+1)send({PIXEL_W{1'b1}},0,(j==0)&&!bad,(j%WIDTH)==WIDTH-1,{TAG_W{1'b1}});
        end
    endtask
    task automatic wait_state(input integer phase);
        integer waited;
        begin
            waited=0;
            while(dut.state!=phase)begin @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"missing phase %0d",phase);end
        end
    endtask
    task automatic hold_next;
        integer waited;
        begin
            s_valid=1;s_pixel=0;s_alpha=0;s_sof=1;s_eol=WIDTH==1;s_tag=0;waited=0;
            while(!(dut.state==7 && held && source_held))begin
                @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"held target missing");
            end
        end
    endtask
    task automatic fresh_frame;
        integer j,waited;
        begin
            ready_again();@(negedge clk);
            for(j=0;j<N;j=j+1)send((j==0)?{PIXEL_W{1'b1}}:{PIXEL_W{1'b0}},GRAY_W'((1<<GRAY_W)-2),j==0,(j%WIDTH)==WIDTH-1,TAG_W'(5));
            for(j=0;j<DENSE;j=j+1)begin
                waited=0;
                while(!m_valid)begin @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"fresh missing");end
                if(response!==fresh_expected[j])$fatal(1,"fresh line/window/histogram isolation %0d",j);
                if(j==0)repeat(3)begin @(negedge clk);if(!m_valid||response!==fresh_expected[0])$fatal(1,"fresh hold");end
                m_ready=1;@(negedge clk);m_ready=0;
            end
            if(m_valid)$fatal(1,"duplicate fresh result");
            ready_again();fresh_checks=fresh_checks+1;
        end
    endtask
    string ipath,epath,fpath,lpath,cpath;
    integer fd,i,fields,sof,eol,phase,waited,extra;
    reg [PIXEL_W-1:0] pixel;
    reg [GRAY_W-1:0] alpha;
    reg [TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",ipath)||!$value$plusargs("EXPECTED=%s",epath)||!$value$plusargs("FRESH=%s",fpath)||
            !$value$plusargs("LATENCY=%s",lpath)||!$value$plusargs("MATCHES=%s",cpath))$fatal(1,"missing vectors");
        $readmemh(epath,expected);$readmemh(fpath,fresh_expected);$readmemh(lpath,latency);$readmemh(cpath,frame_matches);
        fd=$fopen(ipath,"r");if(!fd)$fatal(1,"input open");
        reset_core();checking=1;@(negedge clk);
        for(i=0;i<FRAMES*N;i=i+1)begin
            fields=$fscanf(fd,"%h %h %d %d %h\n",pixel,alpha,sof,eol,tag);if(fields!=5)$fatal(1,"bad vector");
            if(i%17==0)repeat(1+i%3)@(negedge clk);
            send(pixel,alpha,sof[0],eol[0],tag);
        end
        $fclose(fd);waited=0;
        while(outputs<FRAMES*DENSE)begin @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"final matrix missing");end
        if(inputs!=FRAMES*N || first_checks!=FRAMES || grid_checks!=FRAMES*GRID || line_checks!=grid_checks || center_checks!=FRAMES*N ||
            inside_checks!=FRAMES*DEGREE || match_checks!=MATCHES || hist_checks!=FRAMES*N || stalls<1 || source_stalls<1)$fatal(1,"missing finite service checks");
        checking=0;m_ready=0;
        for(phase=0;phase<8;phase=phase+1)begin
            reset_core();
            if(phase==0)begin while(dut.clear_index!=HD/2)@(negedge clk);end
            else if(phase==1)begin
                ready_again();if(N>1)begin @(negedge clk);send(0,0,1,WIDTH==1,1);ready_again();end
            end else fill(0);
            if(phase==7)hold_next();else wait_state(phase);
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
        reset_core();fill(1);hold_next();reset_now();reset_probes=reset_probes+1;fresh_frame();
        if(N>1)begin
            reset_core();ready_again();@(negedge clk);send(0,0,0,WIDTH!=1,1);ready_again();
            if(dut.errors==0)$fatal(1,"bad capture drain target");
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
        for(extra=0;extra<4;extra=extra+1)begin
            reset_core();if(extra>=2)fill(0);waited=0;
            while(!(dut.state==2+(extra%2) && dut.pad_y==((extra<2)?0:HEIGHT+1) &&
                dut.pad_x==((extra<2)?(WIDTH+2)/2:WIDTH+1)))begin
                @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"warmup/bottom-drain target %0d",extra);
            end
            // Fully observed target; no active edge before reset assertion.
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
        if(N>1)begin
            reset_core();fill(0);waited=0;
            while(!(dut.state==5 && dut.hist_q>0))begin
                @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"repeated-bin RMW target");
            end
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
        $display("PASS frames=%0d pixels=%0d outputs=%0d first_checks=%0d grid_checks=%0d line_checks=%0d center_checks=%0d inside_checks=%0d match_checks=%0d hist_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",
            FRAMES,FRAMES*N,outputs,first_checks,grid_checks,line_checks,center_checks,inside_checks,match_checks,hist_checks,stalls,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
