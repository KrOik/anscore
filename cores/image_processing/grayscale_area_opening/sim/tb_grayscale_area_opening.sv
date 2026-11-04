// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_grayscale_area_opening;
    parameter integer WIDTH=3,HEIGHT=3,PIXEL_W=2,TAG_W=8,FRAMES=1,SCANS=0,POPS=0,WRITES=0;
    localparam integer N=WIDTH*HEIGHT,CW=(N<2)?1:$clog2(N+1);
    localparam integer RW=PIXEL_W+6+TAG_W,IW=PIXEL_W+CW+2+TAG_W;
    localparam integer BOUND=17*N*(1<<PIXEL_W)+(1<<PIXEL_W)+4*N+100;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0;
    reg [PIXEL_W-1:0] s_pixel=0;
    reg [CW-1:0] s_area=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_sof,m_eol,m_last;
    wire [PIXEL_W-1:0] m_pixel;
    wire [TAG_W-1:0] m_tag;
    wire [2:0] m_errors;
    grayscale_area_opening #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PIXEL_W(PIXEL_W),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_last,m_eol,m_sof,m_pixel};
    wire [IW-1:0] request={s_tag,s_eol,s_sof,s_area,s_pixel};
    reg [RW-1:0] expected[0:FRAMES*N-1];
    reg [31:0] latency[0:FRAMES-1];
    reg checking=0,held=0,source_held=0,await_first=0;
    reg [RW-1:0] held_response;
    reg [IW-1:0] held_request;
    integer cycle=0,inputs=0,outputs=0,tail_cycle=0,latency_checks=0;
    integer stalls=0,source_stalls=0,scan_checks=0,pops=0,writes=0,clears=0,reset_probes=0;
    always @(negedge clk)if(checking&&!rst)m_ready=(cycle%19)>=8;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>100000000)$fatal(1,"bounded watchdog");
        if(rst)begin held=0;source_held=0;await_first=0;end
        else begin
            if(held&&(!m_valid||response!==held_response))$fatal(1,"held output changed");
            if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source hold violation");
            held=m_valid&&!m_ready;held_response=response;
            source_held=s_valid&&!s_ready;held_request=request;
            if(dut.tail>N || dut.head>dut.tail)$fatal(1,"queue bounds");
            if(dut.state==10 && !dut.visited_q && dut.source_q>=dut.level && dut.tail>=N)
                $fatal(1,"queue enqueue capacity");
            if(checking)begin
                if(m_valid&&s_ready)$fatal(1,"frame ownership overlap");
                if(s_valid&&!s_ready)source_stalls=source_stalls+1;
                if(m_valid&&!m_ready)stalls=stalls+1;
                if(dut.state==5)scan_checks=scan_checks+1;
                if(dut.state==3)clears=clears+1;
                if(dut.state==8)pops=pops+1;
                if(dut.state==13)writes=writes+1;
                if(s_valid&&s_ready)begin
                    inputs=inputs+1;
                    if(inputs%N==0)begin tail_cycle=cycle;await_first=1;end
                end
                if(m_valid&&m_ready)begin
                    if(outputs>=FRAMES*N||response!==expected[outputs])
                        $fatal(1,"pixel mismatch %0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs=outputs+1;
                end
            end
        end
        #1;
        if(checking&&!rst&&await_first&&m_valid)begin
            if(cycle-tail_cycle!=latency[inputs/N-1])
                $fatal(1,"tail schedule frame=%0d got=%0d expected=%0d",inputs/N-1,cycle-tail_cycle,latency[inputs/N-1]);
            await_first=0;latency_checks=latency_checks+1;
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset gating");
            @(negedge clk);rst=0;
            #1;if(!s_ready||m_valid||dut.capture_index!==0||dut.errors!==0||dut.occupied!==0)
                $fatal(1,"reset cancellation");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic send(input[PIXEL_W-1:0] pixel,input[CW-1:0] area,
        input sof,eol,input[TAG_W-1:0] tag);
        begin
            s_valid=1;s_pixel=pixel;s_area=area;s_sof=sof;s_eol=eol;s_tag=tag;
            @(posedge clk);while(!s_ready)@(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    task automatic fill(input bad);
        integer j;
        begin
            for(j=0;j<N;j=j+1)send({PIXEL_W{1'b1}},bad?0:CW'(1),j==0,(j%WIDTH)==WIDTH-1,{TAG_W{1'b1}});
        end
    endtask
    task automatic wait_state(input integer phase);
        integer waited;
        begin
            waited=0;
            while(dut.state!=phase)begin
                @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"missing phase %0d",phase);
            end
        end
    endtask
    task automatic hold_next;
        integer waited;
        begin
            s_valid=1;s_pixel=0;s_area=CW'(N);s_sof=1;s_eol=WIDTH==1;s_tag=0;
            waited=0;
            while(!(dut.state==15&&held&&source_held))begin
                @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"held target");
            end
        end
    endtask
    task automatic fresh_frame;
        integer j,waited;
        begin
            @(negedge clk);
            for(j=0;j<N;j=j+1)send(PIXEL_W'(j==0),CW'(1),j==0,(j%WIDTH)==WIDTH-1,TAG_W'(5));
            for(j=0;j<N;j=j+1)begin
                waited=0;
                while(!m_valid)begin
                    @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"fresh missing");
                end
                if(m_pixel!==PIXEL_W'(j==0)||m_errors!==0||m_tag!==TAG_W'(5)||m_sof!==(j==0)||
                    m_eol!==((j%WIDTH)==WIDTH-1)||m_last!==(j==N-1))$fatal(1,"fresh isolation");
                m_ready=1;@(negedge clk);m_ready=0;
            end
            if(m_valid||!s_ready)$fatal(1,"duplicate fresh output");
        end
    endtask
    string ipath,epath,lpath;
    integer fd,i,fields,sof,eol,probe,waited;
    reg [PIXEL_W-1:0] pixel;
    reg [CW-1:0] area;
    reg [TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",ipath)||!$value$plusargs("EXPECTED=%s",epath)||
            !$value$plusargs("LATENCY=%s",lpath))$fatal(1,"missing vectors");
        $readmemh(epath,expected);$readmemh(lpath,latency);fd=$fopen(ipath,"r");if(!fd)$fatal(1,"input open");
        reset_core();checking=1;@(negedge clk);
        for(i=0;i<FRAMES*N;i=i+1)begin
            fields=$fscanf(fd,"%h %h %d %d %h\n",pixel,area,sof,eol,tag);
            if(fields!=5)$fatal(1,"bad vector");
            if(i%13==0)repeat(1+i%3)@(negedge clk);
            send(pixel,area,sof[0],eol[0],tag);
        end
        $fclose(fd);waited=0;
        while(outputs<FRAMES*N)begin
            @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"last frame missing");
        end
        if(inputs!=FRAMES*N||latency_checks!=FRAMES||scan_checks!=SCANS||clears!=SCANS||pops!=POPS||
            writes!=WRITES||stalls<1||source_stalls<1)$fatal(1,"incomplete service checks");
        checking=0;m_ready=0;
        for(probe=0;probe<16;probe=probe+1)begin
            if(N>1||probe!=10)begin
                reset_core();@(negedge clk);
                if(probe==0)begin if(N>1)send(0,CW'(1),1,WIDTH==1,1);end
                else fill(0);
                if(probe==15)hold_next();else wait_state(probe);
                // Observe the complete phase, then assert reset without an active edge.
                reset_now();reset_probes=reset_probes+1;fresh_frame();
            end
        end
        reset_core();@(negedge clk);fill(1);hold_next();reset_now();reset_probes=reset_probes+1;fresh_frame();
        if(N>1)begin
            reset_core();@(negedge clk);send(0,0,0,WIDTH!=1,1);
            if(!s_ready||dut.errors==0)$fatal(1,"error drain target");
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
        $display("PASS frames=%0d pixels=%0d outputs=%0d scans=%0d pops=%0d writes=%0d held_cycles=%0d source_stalls=%0d latency_checks=%0d reset_probes=%0d",
            FRAMES,FRAMES*N,outputs,scan_checks,pops,writes,stalls,source_stalls,latency_checks,reset_probes);
        $finish;
    end
endmodule
