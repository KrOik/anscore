// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_grayscale_size_zone;
    parameter integer WIDTH=3,HEIGHT=3,PIXEL_W=1,GRAY_W=1,CONNECTIVITY=4,TAG_W=8,
        FRAMES=1,VALID_FRAMES=1,ZONES=1;
    localparam integer N=WIDTH*HEIGHT,CW=(N<2)?1:$clog2(N+1),AW=(N<2)?1:$clog2(N),
        HD=1<<(GRAY_W+AW),DENSE=(1<<GRAY_W)*N,
        DEGREE=2*HEIGHT*(WIDTH-1)+2*WIDTH*(HEIGHT-1)+((CONNECTIVITY==8)?4*(WIDTH-1)*(HEIGHT-1):0),
        RW=TAG_W+4+GRAY_W+3*CW,IW=TAG_W+2+PIXEL_W,
        BOUND=(3*CONNECTIVITY+7)*N+2*DENSE+HD+100;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0;
    reg [PIXEL_W-1:0] s_pixel=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_first,m_last;
    wire [1:0] m_errors;
    wire [GRAY_W-1:0] m_gray;
    wire [CW-1:0] m_size,m_count,m_zones;
    wire [TAG_W-1:0] m_tag;
    grayscale_size_zone #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PIXEL_W(PIXEL_W),.GRAY_W(GRAY_W),
        .CONNECTIVITY(CONNECTIVITY),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_last,m_first,m_gray,m_size,m_zones,m_count};
    wire [IW-1:0] request={s_tag,s_eol,s_sof,s_pixel};
    reg [RW-1:0] expected[0:FRAMES*DENSE-1],fresh_expected[0:DENSE-1];
    reg [31:0] latency[0:FRAMES-1];
    reg checking=0,held=0,source_held=0,await_first=0;
    reg [RW-1:0] held_response;
    reg [IW-1:0] held_request;
    integer cycle=0,inputs=0,outputs=0,tail_cycle=0,tail_frame=0,first_checks=0;
    integer stalls=0,source_stalls=0,scan_checks=0,pop_checks=0,neighbor_checks=0,inside_checks=0,zone_checks=0;
    integer reset_probes=0,fresh_checks=0,sum_counts=0,sum_weighted=0,last_output=-100;
    always @(negedge clk)if(checking&&!rst)m_ready=(cycle%23)>=9;
    always @(posedge clk)begin
        cycle=cycle+1;if(cycle>10000000)$fatal(1,"bounded watchdog");
        if(rst)begin held=0;source_held=0;await_first=0;end
        else begin
            if(held&&(!m_valid||response!==held_response))$fatal(1,"held output changed");
            if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source hold violated");
            held=m_valid&&!m_ready;held_response=response;
            source_held=s_valid&&!s_ready;held_request=request;
            if(dut.state>=4 && dut.state<=10 && (dut.head>dut.tail || dut.tail>N || dut.zone_size<1 || dut.zone_size>N))
                $fatal(1,"FIFO/zone bounds");
            if(dut.state==8 && dut.new_neighbor && (dut.tail>=N || dut.zone_size>=N))$fatal(1,"duplicate enqueue/capacity");
            if((dut.state==2 && dut.scan_index>=N)||(dut.state==7 && dut.neighbor_index>=N))$fatal(1,"frame read bounds");
            if(dut.state==6 && dut.neighbor_inside && (dut.candidate_index>=N || dut.candidate_x>=WIDTH))$fatal(1,"neighbor coordinate bounds");
            if(dut.state==10 && dut.hist_q>=N)$fatal(1,"histogram overflow");
            if(m_valid && (m_size<1 || m_size>N || m_count>N || m_zones>N))$fatal(1,"dense output bounds");
            if(checking)begin
                if(m_valid&&s_ready)$fatal(1,"overlapped frame ownership");
                if(s_valid&&!s_ready)source_stalls=source_stalls+1;
                if(m_valid&&!m_ready)stalls=stalls+1;
                if(dut.state==3)scan_checks=scan_checks+1;
                if(dut.state==5)pop_checks=pop_checks+1;
                if(dut.state==6)begin neighbor_checks=neighbor_checks+1;inside_checks=inside_checks+dut.neighbor_inside;end
                if(dut.state==10)zone_checks=zone_checks+1;
                if(s_valid&&s_ready)begin
                    inputs=inputs+1;
                    if(inputs%N==0)begin tail_cycle=cycle;tail_frame=inputs/N-1;await_first=1;end
                end
                if(m_valid&&m_ready)begin
                    if(cycle-last_output<2)$fatal(1,"output II");last_output=cycle;
                    if(outputs>=FRAMES*DENSE||response!==expected[outputs])
                        $fatal(1,"zone matrix mismatch %0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs=outputs+1;sum_counts=sum_counts+m_count;sum_weighted=sum_weighted+m_size*m_count;
                    if(m_last)begin
                        if(sum_counts!=m_zones || sum_weighted!=((m_errors==0)?N:0))$fatal(1,"zone conservation");
                        sum_counts=0;sum_weighted=0;
                    end
                end
            end
        end
        #1;
        if(checking&&!rst&&await_first&&m_valid)begin
            if(cycle-tail_cycle!=latency[tail_frame])$fatal(1,"tail latency got=%0d expected=%0d",cycle-tail_cycle,latency[tail_frame]);
            await_first=0;first_checks=first_checks+1;
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset transfer gate");
            @(negedge clk);rst=0;
            #1;if(m_valid||dut.state!==0||dut.clear_index!==0||dut.capture_index!==0||dut.errors!==0)
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
            while(!s_ready)begin @(negedge clk);waited=waited+1;if(waited>HD+7)$fatal(1,"clear/collection stuck");end
        end
    endtask
    task automatic send(input[PIXEL_W-1:0] pixel,input sof,eol,input[TAG_W-1:0] tag);
        begin
            s_valid=1;s_pixel=pixel;s_sof=sof;s_eol=eol;s_tag=tag;
            @(posedge clk);while(!s_ready)@(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    task automatic fill(input bad);
        integer j;
        begin
            ready_again();@(negedge clk);
            for(j=0;j<N;j=j+1)send({PIXEL_W{1'b1}},(j==0)&&!bad,(j%WIDTH)==WIDTH-1,{TAG_W{1'b1}});
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
            s_valid=1;s_pixel=0;s_sof=1;s_eol=WIDTH==1;s_tag=0;waited=0;
            while(!(dut.state==12 && held && source_held))begin
                @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"held target missing");
            end
        end
    endtask
    task automatic fresh_frame;
        integer j,waited;
        begin
            ready_again();@(negedge clk);
            for(j=0;j<N;j=j+1)send((j==0)?{PIXEL_W{1'b1}}:{PIXEL_W{1'b0}},j==0,(j%WIDTH)==WIDTH-1,TAG_W'(5));
            for(j=0;j<DENSE;j=j+1)begin
                waited=0;
                while(!m_valid)begin @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"fresh missing");end
                if(response!==fresh_expected[j])$fatal(1,"fresh gray/visited/FIFO/histogram isolation %0d",j);
                if(j==0)repeat(3)begin @(negedge clk);if(!m_valid||response!==fresh_expected[0])$fatal(1,"fresh hold");end
                m_ready=1;@(negedge clk);m_ready=0;
            end
            if(m_valid)$fatal(1,"duplicate fresh result");
            ready_again();fresh_checks=fresh_checks+1;
        end
    endtask
    string ipath,epath,fpath,lpath;
    integer fd,i,fields,sof,eol,phase,waited,extra;
    reg [PIXEL_W-1:0] pixel;
    reg [TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",ipath)||!$value$plusargs("EXPECTED=%s",epath)||
            !$value$plusargs("FRESH=%s",fpath)||!$value$plusargs("LATENCY=%s",lpath))$fatal(1,"missing vectors");
        $readmemh(epath,expected);$readmemh(fpath,fresh_expected);$readmemh(lpath,latency);
        fd=$fopen(ipath,"r");if(!fd)$fatal(1,"input open");
        reset_core();ready_again();checking=1;@(negedge clk);
        for(i=0;i<FRAMES*N;i=i+1)begin
            fields=$fscanf(fd,"%h %d %d %h\n",pixel,sof,eol,tag);if(fields!=4)$fatal(1,"bad vector");
            if(i%17==0)repeat(1+i%3)@(negedge clk);
            send(pixel,sof[0],eol[0],tag);
        end
        $fclose(fd);waited=0;
        while(outputs<FRAMES*DENSE)begin @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"final matrix missing");end
        if(inputs!=FRAMES*N || first_checks!=FRAMES || scan_checks!=VALID_FRAMES*N || pop_checks!=VALID_FRAMES*N ||
            neighbor_checks!=VALID_FRAMES*CONNECTIVITY*N || inside_checks!=VALID_FRAMES*DEGREE || zone_checks!=ZONES || stalls<1 || source_stalls<1)
            $fatal(1,"missing finite service checks");
        checking=0;m_ready=0;
        for(phase=0;phase<=12;phase=phase+1)begin
            if(!(N==1 && (phase==7||phase==8)))begin
                reset_core();
                if(phase==0)begin while(dut.clear_index!=HD/2)@(negedge clk);end
                else if(phase==1)begin
                    ready_again();if(N>1)begin @(negedge clk);send(0,1,WIDTH==1,1);ready_again();end
                end else fill(0);
                if(phase==12)hold_next();else wait_state(phase);
                // Assert immediately after observing the complete target, before another active edge.
                reset_now();reset_probes=reset_probes+1;fresh_frame();
            end
        end
        reset_core();fill(1);hold_next();reset_now();reset_probes=reset_probes+1;fresh_frame();
        if(N>1)begin
            reset_core();ready_again();@(negedge clk);send(0,0,WIDTH!=1,1);ready_again();
            if(dut.errors==0)$fatal(1,"bad capture drain target");
            reset_now();reset_probes=reset_probes+1;fresh_frame();
            for(extra=0;extra<5;extra=extra+1)begin
                reset_core();fill(0);waited=0;
                begin:find_extra
                    while(1)begin
                        if((extra==0 && dut.state==8 && dut.new_neighbor) ||
                           (extra==1 && dut.state==8 && !dut.new_neighbor) ||
                           (extra==2 && dut.state==4 && dut.head==N && dut.tail==N) ||
                           (extra==3 && dut.state==2 && dut.scan_index==N-1) ||
                           (extra==4 && dut.state==3 && dut.scan_index==N-1))disable find_extra;
                        @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"extra reset target %0d",extra);
                    end
                end
                reset_now();reset_probes=reset_probes+1;fresh_frame();
            end
        end
        $display("PASS frames=%0d pixels=%0d outputs=%0d first_checks=%0d scan_checks=%0d pop_checks=%0d neighbor_checks=%0d inside_checks=%0d zone_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",
            FRAMES,FRAMES*N,outputs,first_checks,scan_checks,pop_checks,neighbor_checks,inside_checks,zone_checks,stalls,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
