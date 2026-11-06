// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_spectral_group_delay_fit;
    parameter integer ADAPTER=0,P=16,MAX_BINS=64,TAG_W=8,MAX_FFT=16,ITER=0,IN_W=16;
    localparam integer L=$clog2(MAX_BINS),CW=$clog2(MAX_BINS+1),BW=P+3*L+CW+2,
        CCW=2*P+3*L+CW+1,DW=3*L+CW+1,RW=((CCW+DW>2*BW)?CCW+DW:2*BW)+1,
        QW=MAX_FFT+17,MW=((BW>CCW)?((BW>DW)?BW:DW):((CCW>DW)?CCW:DW))+1,
        H=MW+(2*MW+7)/8,TAIL=10*H+BW+MAX_FFT+16+23+(ADAPTER!=0?ITER+2:0);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,c_valid=0,s_valid=0,m_ready=0;
    reg [31:0] count=0,first=0,fft=0;reg [TAG_W-1:0] tag=0;
    reg [P-1:0] phase=0;reg signed [IN_W-1:0] iv=0,qv=0;reg last=0,invalid=0;
    wire c_ready,s_ready,m_valid,busy;wire [2:0] status;
    wire signed [QW-1:0] delay;wire signed [BW-1:0] b;
    wire [CCW-1:0] c;wire [DW-1:0] d;wire [RW-1:0] residual;
    wire [31:0] mc,mf,ml,mr;wire [TAG_W-1:0] mt;
    wire [3:0] debug_state;wire [2:0] debug_operation;wire debug_pending;
    generate if(ADAPTER==0)begin:core
        spectral_group_delay_fit #(.PHASE_W(P),.MAX_BINS(MAX_BINS),.TAG_W(TAG_W),.MAX_FFT_LOG2(MAX_FFT)) dut(
            .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_count(count),.c_first_bin(first),.c_fft_log2(fft),.c_tag(tag),
            .s_valid(s_valid),.s_ready(s_ready),.s_phase(phase),.s_last(last),.s_invalid(invalid),
            .m_valid(m_valid),.m_ready(m_ready),.m_status(status),.m_delay_q16(delay),.m_b(b),.m_c(c),.m_d(d),.m_residual_numerator(residual),
            .m_count(mc),.m_first_bin(mf),.m_fft_log2(ml),.m_received(mr),.m_tag(mt),.busy(busy));
        assign debug_state=dut.state;assign debug_operation=dut.operation;assign debug_pending=0;
    end else begin:iq
        iq_group_delay_fit #(.IN_W(IN_W),.PHASE_W(P),.ITER(ITER),.MAX_BINS(MAX_BINS),.TAG_W(TAG_W),.MAX_FFT_LOG2(MAX_FFT)) dut(
            .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_count(count),.c_first_bin(first),.c_fft_log2(fft),.c_tag(tag),
            .s_valid(s_valid),.s_ready(s_ready),.s_i(iv),.s_q(qv),.s_last(last),
            .m_valid(m_valid),.m_ready(m_ready),.m_status(status),.m_delay_q16(delay),.m_b(b),.m_c(c),.m_d(d),.m_residual_numerator(residual),
            .m_count(mc),.m_first_bin(mf),.m_fft_log2(ml),.m_received(mr),.m_tag(mt),.busy(busy));
        assign debug_state=dut.fit.state;assign debug_operation=dut.fit.operation;assign debug_pending=dut.angle_pending;
    end endgenerate
    integer cases=0,holds=0,reset_fixtures=0,recovery_outputs=0,recovery_holds=0,future_outputs=0,future_holds=0;
    task automatic reset_now;
        begin
            @(negedge clk);rst=1;c_valid=0;s_valid=0;m_ready=0;
            #1;if(c_ready || s_ready || m_valid || busy)$fatal(1,"reset masks");
            repeat(2)@(posedge clk);@(negedge clk);rst=0;
            if(m_valid || !c_ready || s_ready || busy)$fatal(1,"reset stale ownership");
        end
    endtask
    task automatic command(input [31:0] nn,ff,ll,tt);
        begin
            @(negedge clk);count=nn;first=ff;fft=ll;tag=TAG_W'(tt);c_valid=1;
            @(posedge clk);if(!c_ready)$fatal(1,"command admission");
            @(negedge clk);c_valid=0;count=~nn;first=~ff;fft=~ll;tag=~TAG_W'(tt);
        end
    endtask
    task automatic sample(input [31:0] aa,bb,input integer ll,bad);
        integer watchdog;
        begin
            @(negedge clk);s_valid=1;phase=P'(aa);iv=IN_W'(aa);qv=IN_W'(bb);last=1'(ll);invalid=1'(bad);
            watchdog=0;
            do begin
                @(posedge clk);watchdog=watchdog+1;
                if(c_ready || m_valid || !busy || watchdog>2*H+ITER+20)$fatal(1,"sample ownership/deadline");
            end while(!s_ready);
            @(negedge clk);s_valid=0;phase=~P'(aa);iv=~IN_W'(aa);qv=~IN_W'(bb);last=~1'(ll);invalid=~1'(bad);
        end
    endtask
    task automatic response(input [31:0] nn,ff,ll,tt,input integer ss,rr,
        input [QW-1:0] qq,input [BW-1:0] eb,input [CCW-1:0] ec,input [DW-1:0] ed,input [RW-1:0] ee,
        input integer latency_expected,kind);
        integer latency,j;
        begin
            latency=0;
            while(!m_valid)begin
                if(c_ready || !busy)$fatal(1,"calculation ownership");
                @(negedge clk);latency=latency+1;
                if(latency>TAIL+2)$fatal(1,"response watchdog");
            end
            if(latency!=latency_expected)$fatal(1,"tail latency got%0d expected%0d",latency,latency_expected);
            for(j=0;j<4;j=j+1)begin
                if(!m_valid || c_ready || s_ready || !busy || status!==3'(ss) || mr!==32'(rr) ||
                    mc!==nn || mf!==ff || ml!==ll || mt!==TAG_W'(tt) || delay!==qq || b!==eb || c!==ec || d!==ed || residual!==ee)
                    $fatal(1,"result case%0d status%0d delay%h/%h B%h/%h C%h/%h D%h/%h E%h/%h",cases,status,delay,qq,b,eb,c,ec,d,ed,residual,ee);
                if(ss==0 && nn==2 && residual!==0)$fatal(1,"N2 residual");
                @(negedge clk);
                if(kind==0)holds=holds+1;else if(kind==1)recovery_holds=recovery_holds+1;else future_holds=future_holds+1;
            end
            m_ready=1;@(posedge clk);if(c_ready || s_ready || !m_valid)$fatal(1,"retirement fallthrough");
            @(negedge clk);m_ready=0;
            if(m_valid || !c_ready || s_ready || busy)$fatal(1,"retirement state");
            if(kind==0)cases=cases+1;else if(kind==1)recovery_outputs=recovery_outputs+1;else future_outputs=future_outputs+1;
        end
    endtask
    task automatic zero_sample(input integer ll);
        begin sample(ADAPTER!=0?1:0,0,ll,0);end
    endtask
    task automatic recovery;
        begin
            command(2,0,MAX_FFT,32'hffffffff);zero_sample(0);zero_sample(1);
            response(2,0,MAX_FFT,32'hffffffff,0,2,0,0,0,1,0,TAIL,1);
        end
    endtask
    task automatic cancellation(input integer fixture);
        integer watchdog;reg reached;
        begin
            command(2,0,MAX_FFT,1);zero_sample(0);
            if(fixture>=3 && fixture<=6)zero_sample(1);
            watchdog=0;reached=0;
            while(!reached)begin
                case(fixture)
                    0:reached=debug_state==1 && mr==1 && !debug_pending;
                    1:reached=debug_state==4;
                    2:reached=debug_state==6;
                    3:reached=debug_state==8 && debug_operation==0;
                    4:reached=debug_state==8 && debug_operation==6;
                    5:reached=debug_state==10;
                    6:reached=m_valid;
                    7:reached=debug_pending && debug_state==1;
                endcase
                if(!reached)begin @(negedge clk);watchdog=watchdog+1;end
                if(watchdog>TAIL+2)$fatal(1,"reset target not reached %0d",fixture);
            end
            reset_now();reset_fixtures=reset_fixtures+1;
            repeat(TAIL+2)begin @(negedge clk);if(m_valid || !c_ready || s_ready || busy)$fatal(1,"canceled helper leaked");end
            recovery();
        end
    endtask
    task automatic future_command;
        begin
            command(2,0,MAX_FFT,1);zero_sample(0);zero_sample(1);
            c_valid=1;count=2;first=0;fft=MAX_FFT;tag=TAG_W'(2);
            response(2,0,MAX_FFT,1,0,2,0,0,0,1,0,TAIL,2);
            if(!c_valid || !c_ready)$fatal(1,"future command cannot resume");
            @(posedge clk);if(!c_ready)$fatal(1,"future command handshake");
            @(negedge clk);c_valid=0;zero_sample(0);zero_sample(1);
            response(2,0,MAX_FFT,2,0,2,0,0,0,1,0,TAIL,2);
        end
    endtask
    integer f,n,rc,i,j,ns,ss,rr,sl,si,latency_expected;
    reg [31:0] nn,ff,ll,tt,aa,bb;
    reg [QW-1:0] qq;reg [BW-1:0] eb;reg [CCW-1:0] ec;reg [DW-1:0] ed;reg [RW-1:0] ee;
    reg [2047:0] folder,filename;
    initial begin repeat(2000000)@(posedge clk);$fatal(1,"global watchdog");end
    initial begin
        if(!$value$plusargs("vectors=%s",folder))$fatal(1,"vectors argument");
        reset_now();
        for(i=0;i<7+ADAPTER;i=i+1)cancellation(i);
        future_command();
        filename={folder,"/vectors.txt"};f=$fopen(filename,"r");if(f==0)$fatal(1,"vectors open");
        rc=$fscanf(f,"%d\n",n);if(rc!=1 || n!=(ADAPTER!=0?25:39))$fatal(1,"vector case count");
        for(i=0;i<n;i=i+1)begin
            rc=$fscanf(f,"%h %h %h %h %d %d %h %h %h %h %h %d\n",nn,ff,ll,tt,ss,rr,qq,eb,ec,ed,ee,ns);
            if(rc!=12)$fatal(1,"vector header");command(nn,ff,ll,tt);
            for(j=0;j<ns;j=j+1)begin
                rc=$fscanf(f,"%h %h %d %d\n",aa,bb,sl,si);if(rc!=4)$fatal(1,"vector sample");sample(aa,bb,sl,si);
            end
            latency_expected=ss==0?TAIL:ss==1?1:(ADAPTER!=0?ITER+3:1);
            response(nn,ff,ll,tt,ss,rr,qq,eb,ec,ed,ee,latency_expected,0);
        end
        if($fgetc(f)!=-1)$fatal(1,"vector trailing data");$fclose(f);
        if(cases!=n || holds!=4*n || reset_fixtures!=7+ADAPTER || recovery_outputs!=7+ADAPTER ||
            recovery_holds!=4*(7+ADAPTER) || future_outputs!=2 || future_holds!=8)$fatal(1,"finite counters");
        $display("B46_B_SIM_PASS cases=%0d holds=%0d reset_fixtures=%0d recovery_outputs=%0d recovery_holds=%0d future_outputs=%0d future_holds=%0d PHASE=%0d MAX=%0d TAG=%0d ADAPTER=%0d ITER=%0d tail=%0d",cases,holds,reset_fixtures,recovery_outputs,recovery_holds,future_outputs,future_holds,P,MAX_BINS,TAG_W,ADAPTER,ITER,TAIL);
        $finish;
    end
endmodule
