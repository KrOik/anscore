// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_nonnegative_least_squares2;
    parameter integer DATA_W=8,MAX_SAMPLES=16,TAG_W=8,BEATS=1,FRAMES=1,RESETS=1;
    localparam integer W=DATA_W,N=MAX_SAMPLES,IW=$clog2(N),CW=$clog2(N+1),EW=4*W+2*IW+4,
        CMDW=3*W+TAG_W+2,OW=4*EW+CW+TAG_W+4,FW=OW+32+CMDW,BOUND=14+N*(5*W+11)+6*EW;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_a0=0,s_a1=0,s_b=0;reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;wire [EW-1:0] m_num_x,m_num_y,m_denominator;
    wire signed [EW-1:0] m_determinant;wire [CW-1:0] m_count;wire [1:0] m_positive,m_status;wire [TAG_W-1:0] m_tag;
    nonnegative_least_squares2 #(.DATA_W(W),.MAX_SAMPLES(N),.TAG_W(TAG_W)) dut(.*);
    wire [CMDW-1:0] source_word={s_tag,s_last,s_keep,s_a0,s_a1,s_b};
    wire [OW-1:0] output_word={m_status,m_positive,m_count,m_tag,m_determinant,m_num_x,m_num_y,m_denominator};
    reg [FW-1:0] fixture[0:BEATS-1];reg [1023:0] fixture_path;
    reg [3*W-1:0] captured_rows[0:N-1];integer captured_count=0;
    reg previous_source_stall=0,previous_sink_stall=0,main_active=0,check_product=0;
    reg [CMDW-1:0] previous_source;reg [OW-1:0] previous_output;
    reg [2*EW-1:0] product_reference;reg signed [EW-1:0] signed_reference;
    reg product_negative=0;reg [9:0] states_seen=0;reg [4:0] sample_seen=0;reg [5:0] wide_seen=0;
    integer cycle=0,accepted=0,outputs=0,source_holds=0,output_holds=0,sample_products=0,wide_products=0,multiply_steps=0;
    integer reset_probes=0,fresh_checks=0,queued_checks=0,kkt_checks=0,row_checks=0,maximum_latency=0,first_edge=0;
    integer i,j,id,guard,main_frames=0;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin previous_source_stall=0;previous_sink_stall=0;check_product=0;captured_count=0;end
        else begin
            if(previous_source_stall && (!s_valid || source_word!==previous_source))$fatal(1,"source changed/withdrew before acceptance");
            if(previous_sink_stall && (!m_valid || output_word!==previous_output))$fatal(1,"held result changed");
            previous_source_stall=s_valid && !s_ready;previous_source=source_word;
            previous_sink_stall=m_valid && !m_ready;previous_output=output_word;
            if(s_valid && s_ready && s_keep && captured_count<N)begin
                captured_rows[captured_count]={s_a0,s_a1,s_b};captured_count=captured_count+1;
            end
            if(m_valid && m_ready)captured_count=0;
            if(main_active)begin
                states_seen[dut.state]=1;
                if(s_valid && s_ready)accepted=accepted+1;
                if(m_valid && m_ready)outputs=outputs+1;
                if(s_valid && !s_ready)source_holds=source_holds+1;
                if(m_valid && !m_ready)output_holds=output_holds+1;
                if(dut.state==3)sample_seen[dut.operation]=1;
                if(dut.state==6)wide_seen[dut.operation]=1;
            end
            if(dut.state==2 && (dut.row_index>=dut.count || dut.count>N || dut.count==0))$fatal(1,"RAM read prefix ownership");
            if(m_valid && s_ready)$fatal(1,"overlapped ownership");
            if(check_product)begin if(dut.mul_result!==signed_reference)$fatal(1,"signed product reference");check_product=0;end
            if(dut.state==4)begin
                if(dut.mul_limit!=W && dut.mul_limit!=EW)$fatal(1,"multiplier mode");
                if(dut.mul_step>=dut.mul_limit)$fatal(1,"multiplier iteration ownership");
                if(dut.mul_step==0)begin
                    product_reference=dut.mul_term*dut.mul_factor;product_negative=dut.mul_negative;
                    if(product_reference[2*EW-1:EW-1]!=0)$fatal(1,"signed EW product overflow");
                    if(main_active)begin
                        if(dut.return_state==5)sample_products=sample_products+1;else wide_products=wide_products+1;
                    end
                end
                if(dut.mul_step==dut.mul_limit-1)begin
                    if(dut.mul_added!==product_reference[EW-1:0])$fatal(1,"full magnitude product reference");
                    signed_reference=product_negative?-$signed(product_reference[EW-1:0]):$signed(product_reference[EW-1:0]);check_product=1;
                end
                if(main_active)multiply_steps=multiply_steps+1;
            end
            if(dut.state==8 && (dut.g00<0 || dut.g11<0 || m_determinant<0))$fatal(1,"Gram nonnegativity");
        end
        if(cycle>9000000)$fatal(1,"finite total watchdog");
    end
    task drive;
        input [CMDW-1:0] word;
        begin {s_tag,s_last,s_keep,s_a0,s_a1,s_b}=word;s_valid=1;end
    endtask
    task push;
        input signed [W-1:0] a0,a1,b;input integer keep,last;
        input [TAG_W-1:0] tag;output integer e;
        begin
            @(negedge clk);s_a0=a0;s_a1=a1;s_b=b;s_keep=keep;s_last=last;s_tag=tag;s_valid=1;#1;
            while(!s_ready)begin @(negedge clk);#1;end
            @(posedge clk);#1;e=cycle;
        end
    endtask
    task wait_output;
        integer n;
        begin n=0;while(!m_valid)begin @(negedge clk);#1;n=n+1;if(n>BOUND)$fatal(1,"tail first-valid bound");end end
    endtask
    task retire;
        begin m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;#1;if(m_valid)$fatal(1,"stale valid after retirement");end
    endtask
    task original_row_certificate;
        integer k;
        reg signed [2*EW-1:0] x,y,den,a0,a1,b,residual,gx,gy;
        begin
            if(m_count!==captured_count)$fatal(1,"captured row count");
            for(k=0;k<captured_count;k=k+1)begin
                if(dut.rows[k]!==captured_rows[k])$fatal(1,"raw sample RAM image");
                if(main_active)row_checks=row_checks+1;
            end
            if(m_status==0)begin
                if(m_denominator==0 || m_determinant<=0 || m_positive!=={m_num_y!=0,m_num_x!=0})$fatal(1,"rational success metadata");
                x=$signed({1'b0,m_num_x});y=$signed({1'b0,m_num_y});den=$signed({1'b0,m_denominator});gx=0;gy=0;
                for(k=0;k<captured_count;k=k+1)begin
                    a0=$signed(captured_rows[k][3*W-1:2*W]);a1=$signed(captured_rows[k][2*W-1:W]);b=$signed(captured_rows[k][W-1:0]);
                    residual=a0*x+a1*y-b*den;gx=gx+a0*residual;gy=gy+a1*residual;
                end
                if(gx<0 || gy<0 || (x!=0 && gx!=0) || (y!=0 && gy!=0))$fatal(1,"original-row KKT/complimentary slackness");
                if(main_active)kkt_checks=kkt_checks+1;
            end else if(m_num_x!=0 || m_num_y!=0 || m_denominator!=0 || m_determinant!=0 || m_positive!=0)
                $fatal(1,"canonical error record");
        end
    endtask
    task check_fixture;
        input [FW-1:0] word;input integer e;
        reg [1:0] status,positive;reg [CW-1:0] count;reg [TAG_W-1:0] tag;
        reg [EW-1:0] determinant,nx,ny,den;reg [2*EW-1:0] l0,r0,l1,r1;integer latency;
        begin
            {status,positive,count,tag,determinant,nx,ny,den}=word[FW-1:CMDW+32];latency=word[CMDW+:32];
            if(m_status!==status || m_positive!==positive || m_count!==count || m_tag!==tag || m_determinant!==determinant)
                $fatal(1,"frozen independent metadata mismatch beat %0d",i);
            if(status==0)begin
                l0=m_num_x*den;r0=nx*m_denominator;l1=m_num_y*den;r1=ny*m_denominator;
                if(l0!==r0 || l1!==r1)$fatal(1,"independent Gaussian rational solution beat %0d",i);
            end
            original_row_certificate;
            if(cycle-e!=latency || cycle-e>BOUND)$fatal(1,"exact tail latency %0d expected %0d",cycle-e,latency);
            if(cycle-e>maximum_latency)maximum_latency=cycle-e;
        end
    endtask
    task reset_now;
        begin
            if(clk!==0)$fatal(1,"reset observation boundary");rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready!==0 || m_valid!==0)$fatal(1,"reset gates");
            @(posedge clk);#1;
            if(dut.state!==0 || dut.started!==0 || m_count!==0 || m_num_x!==0 || m_num_y!==0 || m_denominator!==0 ||
               m_determinant!==0 || m_status!==0 || m_positive!==0 || m_tag!==0 || dut.g00!==0 || dut.mul_acc!==0)
                $fatal(1,"synchronous reset image");
            @(negedge clk);rst=0;#1;
        end
    endtask
    task fresh;
        integer e;reg [OW-1:0] held;
        begin
            push(-1,0,-1,1,0,{TAG_W{1'b1}},e);push(0,-1,-1,1,1,0,e);
            @(negedge clk);s_valid=0;#1;wait_output;
            if(m_status!==0 || m_positive!==3 || m_count!==2 || m_tag!=={TAG_W{1'b1}} || m_determinant!==1 ||
               m_num_x!==1 || m_num_y!==1 || m_denominator!==1 || cycle-e!=14+2*(5*W+11)+6*EW)$fatal(1,"full fresh analytic basis solve");
            original_row_certificate;held=output_word;
            repeat(3)begin @(negedge clk);#1;if(!m_valid || output_word!==held)$fatal(1,"fresh hold");end
            retire;repeat(3)begin @(negedge clk);#1;if(m_valid)$fatal(1,"stale output after fresh");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    task probe_frame;
        input integer target;integer e,k;
        begin
            if(target==29)push(0,0,0,0,1,1,e);
            else if(target==30)begin for(k=0;k<N+1;k=k+1)push(-1,0,-1,1,k==N,1,e);end
            else if(target==19 || target==25)begin push(-1,-1,0,1,0,1,e);push(-1,0,-1,1,1,0,e);end
            else if(target==20 || target==26)begin push(-1,-1,0,1,0,1,e);push(0,-1,-1,1,1,0,e);end
            else if(target==21 || target==27)begin push(-1,0,0,1,0,1,e);push(0,-1,0,1,1,0,e);end
            else if(target==22 || target==42)begin push(-1,0,1,1,0,1,e);push(0,-1,1,1,1,0,e);end
            else if(target==23 || target==28 || target==32)begin push(-1,-1,-1,1,0,1,e);push(-1,-1,0,1,1,0,e);end
            else begin push(-1,0,-1,1,0,1,e);push(0,-1,-1,1,1,0,e);end
            @(negedge clk);s_valid=1;s_a0=-1;s_a1=0;s_b=-1;s_keep=1;s_last=0;s_tag=0;#1;
        end
    endtask
    function target_seen;
        input integer target;
        begin
            case(target)
                0:target_seen=dut.state==0 && !dut.started;
                1:target_seen=dut.state==0 && dut.count==1;
                2:target_seen=dut.state==0 && dut.count==N;
                3:target_seen=dut.state==0 && dut.overflow;
                4:target_seen=dut.state==0 && dut.started && dut.count==0;
                5:target_seen=dut.state==1;
                6:target_seen=dut.state==2 && dut.row_index==0;
                7:target_seen=dut.state==2 && dut.row_index==dut.count-1;
                8:target_seen=dut.state==3 && dut.operation==0;
                9:target_seen=dut.state==5 && dut.operation==4;
                10:target_seen=dut.state==4 && dut.return_state==5 && dut.mul_step==0;
                11:target_seen=dut.state==4 && dut.return_state==5 && dut.mul_step==W/2;
                12:target_seen=dut.state==4 && dut.return_state==5 && dut.mul_step==W-1;
                13:target_seen=dut.state==6 && dut.operation==0;
                14:target_seen=dut.state==7 && dut.operation==5;
                15:target_seen=dut.state==4 && dut.return_state==7 && dut.mul_step==0;
                16:target_seen=dut.state==4 && dut.return_state==7 && dut.mul_step==EW/2;
                17:target_seen=dut.state==4 && dut.return_state==7 && dut.mul_step==EW-1;
                18:target_seen=dut.state==8 && dut.numerator_x>0 && dut.numerator_y>0;
                19:target_seen=dut.state==8 && dut.numerator_y<0;
                20:target_seen=dut.state==8 && dut.numerator_x<0;
                21:target_seen=dut.state==8 && dut.h0==0 && dut.h1==0;
                22:target_seen=dut.state==8 && dut.h0<0 && dut.h1<0;
                23:target_seen=dut.state==8 && m_determinant==0;
                24:target_seen=m_valid && m_positive==3;
                25:target_seen=m_valid && m_positive==1;
                26:target_seen=m_valid && m_positive==2;
                27:target_seen=m_valid && m_status==0 && m_positive==0;
                28:target_seen=m_valid && m_status==3;
                29:target_seen=m_valid && m_status==1;
                30:target_seen=m_valid && m_status==2;
                31:target_seen=m_valid && m_status==0 && s_valid && !s_ready;
                32:target_seen=m_valid && m_status==3 && s_valid && !s_ready;
                33,34,35,36:target_seen=dut.state==3 && dut.operation==target-32;
                37,38,39,40,41:target_seen=dut.state==6 && dut.operation==target-36;
                42:target_seen=dut.state==4 && dut.return_state==5 && dut.mul_step==0 && dut.mul_negative;
                43:target_seen=dut.state==4 && dut.return_state==5 && dut.mul_step==0 && dut.mul_factor==0;
                44:target_seen=dut.state==3 && dut.row_index==dut.count-1;
                default:target_seen=0;
            endcase
        end
    endfunction
    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture_path))$fatal(1,"fixture missing");$readmemh(fixture_path,fixture);
        @(negedge clk);reset_now;main_active=1;
        @(negedge clk);drive(fixture[0][CMDW-1:0]);#1;@(posedge clk);#1;first_edge=cycle;
        for(i=0;i<BEATS;i=i+1)begin
            if(fixture[i][3*W+1])begin
                @(negedge clk);if(i+1<BEATS)drive(fixture[i+1][CMDW-1:0]);else s_valid=0;
                #1;wait_output;check_fixture(fixture[i],first_edge);main_frames=main_frames+1;
                repeat(2+i%3)begin @(negedge clk);#1;end
                retire;
                if(i+1<BEATS)begin
                    if(!s_valid || !s_ready)$fatal(1,"actual next token lost after result retirement");
                    @(posedge clk);#1;first_edge=cycle;queued_checks=queued_checks+1;
                end
            end else begin
                @(negedge clk);s_valid=0;
                if(i%4==1)begin @(negedge clk);#1;end
                drive(fixture[i+1][CMDW-1:0]);#1;
                if(!s_ready)$fatal(1,"unexpected collection stall");@(posedge clk);#1;first_edge=cycle;
            end
        end
        main_active=0;
        if(accepted!=BEATS || outputs!=FRAMES || main_frames!=FRAMES || queued_checks!=FRAMES-1)$fatal(1,"exact main population");
        if(multiply_steps!=sample_products*W+wide_products*EW)$fatal(1,"two-mode exact product step population");
        if(states_seen!==10'h3ff || sample_seen!==5'h1f || wide_seen!==6'h3f)$fatal(1,"state/product operation coverage");
        for(id=0;id<45;id=id+1)if(W>1 || (id!=22 && id!=42))begin
            if(id==0)begin @(negedge clk);#1;end
            else if(id==1)begin push(-1,0,-1,1,0,1,first_edge);@(negedge clk);s_valid=0;#1;end
            else if(id==2 || id==3)begin
                for(j=0;j<N+(id==3);j=j+1)push(-1,0,-1,1,0,1,first_edge);
                @(negedge clk);s_valid=0;#1;
            end else if(id==4)begin push(0,0,0,0,0,{TAG_W{1'b1}},first_edge);@(negedge clk);s_valid=0;#1;end
            else begin
                probe_frame(id);guard=0;
                while(!target_seen(id))begin @(negedge clk);#1;guard=guard+1;if(guard>BOUND)$fatal(1,"reset target unreachable %0d",id);end
            end
            if(!target_seen(id))$fatal(1,"target not current %0d",id);reset_now;reset_probes=reset_probes+1;fresh;
        end
        if(reset_probes!=RESETS || fresh_checks!=RESETS)$fatal(1,"reset/fresh frozen population");
        $display("PASS W=%0d N=%0d T=%0d frames=%0d beats=%0d queued=%0d resets=%0d fresh=%0d sample_products=%0d wide_products=%0d steps=%0d KKT=%0d rows=%0d source_hold=%0d output_hold=%0d max_latency=%0d states=%h sample_ops=%h wide_ops=%h",
            W,N,TAG_W,FRAMES,BEATS,queued_checks,reset_probes,fresh_checks,sample_products,wide_products,multiply_steps,kkt_checks,row_checks,source_holds,output_holds,maximum_latency,states_seen,sample_seen,wide_seen);
        $finish;
    end
endmodule
`default_nettype wire
