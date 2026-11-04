// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_streaming_glrlm;
    parameter integer WIDTH=3,HEIGHT=3,PIXEL_W=1,GRAY_W=1,TAG_W=8,FRAMES=1,EXTENSIONS=0;
    localparam integer N=WIDTH*HEIGHT,L=(WIDTH>HEIGHT)?WIDTH:HEIGHT;
    localparam integer CW=(N<2)?1:$clog2(N+1),LW=(L<2)?1:$clog2(L+1);
    localparam integer OW=(L<2)?1:$clog2(L),HD=1<<(GRAY_W+OW),DENSE=4*(1<<GRAY_W)*L;
    localparam integer RW=TAG_W+6+GRAY_W+LW+2*CW,IW=TAG_W+2+PIXEL_W;
    localparam integer BOUND=5*N+4*DENSE+2*HD+100;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0;
    reg [PIXEL_W-1:0] s_pixel=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_direction_last,m_last;
    wire [1:0] m_direction,m_errors;
    wire [GRAY_W-1:0] m_gray;
    wire [LW-1:0] m_length;
    wire [CW-1:0] m_count,m_runs;
    wire [TAG_W-1:0] m_tag;
    streaming_glrlm #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PIXEL_W(PIXEL_W),.GRAY_W(GRAY_W),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_last,m_direction_last,m_direction,m_gray,m_length,m_runs,m_count};
    wire [IW-1:0] request={s_tag,s_eol,s_sof,s_pixel};
    reg [RW-1:0] expected[0:FRAMES*DENSE-1],fresh_expected[0:DENSE-1];
    reg checking=0,held=0,source_held=0,await_first=0;
    reg [RW-1:0] held_response;
    reg [IW-1:0] held_request;
    integer cycle=0,inputs=0,outputs=0,tail_cycle=0,first_checks=0;
    integer stalls=0,source_stalls=0,extension_checks=0,reset_probes=0,fresh_checks=0;
    integer last_input=-100,last_output=-100,sum_counts=0,sum_weighted=0;
    genvar b;
    generate for(b=0;b<4;b=b+1)begin:assert_bank
        always @(posedge clk)if(!rst)begin
            if(dut.state==2 && ((^dut.new_length[b])===1'bx || dut.new_length[b]<1 || dut.new_length[b]>L))
                $fatal(1,"run length bound bank=%0d",b);
            if(dut.state==3 && dut.histogram[b].read_q>=N)$fatal(1,"histogram increment bound");
            if(dut.state==5 && dut.extends_q[b] && dut.histogram[b].read_q==0)$fatal(1,"histogram underflow");
            if(dut.state==3 && dut.extends_q[b] && dut.histogram[b].increment_address==dut.histogram[b].decrement_address)
                $fatal(1,"prefix address alias");
        end
    end endgenerate
    always @(negedge clk)if(checking&&!rst)m_ready=(cycle%23)>=9;
    always @(posedge clk)begin
        cycle=cycle+1;if(cycle>10000000)$fatal(1,"bounded watchdog");
        if(rst)begin held=0;source_held=0;await_first=0;end
        else begin
            if(held&&(!m_valid||response!==held_response))$fatal(1,"held output changed");
            if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source hold violated");
            held=m_valid&&!m_ready;held_response=response;
            source_held=s_valid&&!s_ready;held_request=request;
            if(checking)begin
                if(m_valid&&s_ready)$fatal(1,"overlapped frame ownership");
                if(s_valid&&!s_ready)source_stalls=source_stalls+1;
                if(m_valid&&!m_ready)stalls=stalls+1;
                if(dut.state==2)extension_checks=extension_checks+dut.extension_now[0]+dut.extension_now[1]+dut.extension_now[2]+dut.extension_now[3];
                if(s_valid&&s_ready)begin
                    if(cycle-last_input<5)$fatal(1,"input II");last_input=cycle;inputs=inputs+1;
                    if(inputs%N==0)begin tail_cycle=cycle;await_first=1;end
                end
                if(m_valid&&m_ready)begin
                    if(cycle-last_output<2)$fatal(1,"output II");last_output=cycle;
                    if(outputs>=FRAMES*DENSE||response!==expected[outputs])
                        $fatal(1,"matrix mismatch %0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs=outputs+1;sum_counts=sum_counts+m_count;sum_weighted=sum_weighted+m_length*m_count;
                    if(m_direction_last)begin
                        if(sum_counts!=m_runs||sum_weighted!=((m_errors==0)?N:0))$fatal(1,"direction conservation");
                        sum_counts=0;sum_weighted=0;
                    end
                end
            end
        end
        #1;
        if(checking&&!rst&&await_first&&m_valid)begin
            if(cycle-tail_cycle!=5)$fatal(1,"tail latency");await_first=0;first_checks=first_checks+1;
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready||m_valid)$fatal(1,"reset gating");
            @(negedge clk);rst=0;
            #1;if(m_valid||dut.state!==0||dut.clear_index!==0||dut.x!==0||dut.y!==0||dut.errors!==0)
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
            while(!s_ready)begin
                @(negedge clk);waited=waited+1;if(waited>HD+7)$fatal(1,"clear/collection stuck");
            end
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
            while(!(dut.state==7&&held&&source_held))begin
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
                if(response!==fresh_expected[j])$fatal(1,"fresh histogram/history isolation %0d",j);
                m_ready=1;@(negedge clk);m_ready=0;
            end
            if(m_valid)$fatal(1,"duplicate fresh result");
            ready_again();fresh_checks=fresh_checks+1;
        end
    endtask
    string ipath,epath,fpath;
    integer fd,i,fields,sof,eol,phase,waited;
    reg [PIXEL_W-1:0] pixel;
    reg [TAG_W-1:0] tag;
    initial begin
        if(!$value$plusargs("INPUTS=%s",ipath)||!$value$plusargs("EXPECTED=%s",epath)||
            !$value$plusargs("FRESH=%s",fpath))$fatal(1,"missing vectors");
        $readmemh(epath,expected);$readmemh(fpath,fresh_expected);fd=$fopen(ipath,"r");if(!fd)$fatal(1,"input open");
        reset_core();ready_again();checking=1;@(negedge clk);
        for(i=0;i<FRAMES*N;i=i+1)begin
            fields=$fscanf(fd,"%h %d %d %h\n",pixel,sof,eol,tag);if(fields!=4)$fatal(1,"bad vector");
            if(i%17==0)repeat(1+i%3)@(negedge clk);
            send(pixel,sof[0],eol[0],tag);
        end
        $fclose(fd);waited=0;
        while(outputs<FRAMES*DENSE)begin @(negedge clk);waited=waited+1;if(waited>BOUND)$fatal(1,"final matrix missing");end
        if(inputs!=FRAMES*N||first_checks!=FRAMES||extension_checks!=EXTENSIONS||stalls<1||source_stalls<1)
            $fatal(1,"missing finite service checks");
        checking=0;m_ready=0;
        for(phase=0;phase<8;phase=phase+1)begin
            reset_core();
            if(phase==0)begin
                while(dut.clear_index!=HD/2)@(negedge clk);
            end else if(phase==1)begin
                ready_again();if(N>1)begin @(negedge clk);send(0,1,WIDTH==1,1);ready_again();end
            end else fill(0);
            if(phase==7)hold_next();else wait_state(phase);
            // Fully observed phase; assert reset before the next active edge.
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
        reset_core();fill(1);hold_next();reset_now();reset_probes=reset_probes+1;fresh_frame();
        if(N>1)begin
            reset_core();ready_again();@(negedge clk);send(0,0,WIDTH!=1,1);ready_again();
            if(dut.errors==0)$fatal(1,"bad-frame drain target");
            reset_now();reset_probes=reset_probes+1;fresh_frame();
        end
        $display("PASS frames=%0d pixels=%0d outputs=%0d extensions=%0d first_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",
            FRAMES,FRAMES*N,outputs,extension_checks,first_checks,stalls,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
