// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_streaming_ngtdm;
    parameter integer WIDTH=32,HEIGHT=24,PIXEL_W=8,GRAY_W=3,TAG_W=8,FRAMES=20;
    localparam integer N=WIDTH*HEIGHT,LEVELS=1<<GRAY_W,
        CW=($clog2(N+1)<1)?1:$clog2(N+1),
        DW=$clog2(N*120*(LEVELS-1)+1),OW=GRAY_W+CW+DW+TAG_W+4;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0;
    reg [PIXEL_W-1:0] s_pixel=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_first,m_last;
    wire [GRAY_W-1:0] m_gray;
    wire [CW-1:0] m_count;
    wire [DW-1:0] m_difference_120;
    wire [TAG_W-1:0] m_tag;
    wire [1:0] m_errors;
    streaming_ngtdm #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PIXEL_W(PIXEL_W),.GRAY_W(GRAY_W),.TAG_W(TAG_W)) dut(.*);
    wire [OW-1:0] word={m_gray,m_count,m_difference_120,m_first,m_last,m_tag,m_errors};
    integer pixels[0:N-1],shadow_count[0:LEVELS-1],shadow_sum[0:LEVELS-1];
    integer seen=0,grid_work=0,center_work=0,update_work=0,frame_neighbors=0,frame_fractional=0,frame_nonzero=0;
    integer cycle=0,grid_checks=0,center_checks=0,update_checks=0,held_cycles=0,source_stalls=0;
    integer ref_gray,ref_count,ref_sum,ref_delta,ref_scaled,rx,ry,nx,ny,dx,dy,j,g;
    integer old_state,old_gray,old_count,old_sum;
    reg sink_stall=0,source_stall=0;
    reg [OW-1:0] held_word;
    reg [PIXEL_W+TAG_W+1:0] held_source;
    always @(posedge clk)begin
        cycle=cycle+1;
        old_state=dut.state;old_gray=dut.center_gray;
        if(rst)begin
            sink_stall=0;source_stall=0;seen=0;grid_work=0;center_work=0;update_work=0;
            frame_neighbors=0;frame_fractional=0;frame_nonzero=0;
            for(j=0;j<LEVELS;j=j+1)begin shadow_count[j]=0;shadow_sum[j]=0;end
        end else begin
            if(sink_stall && (!m_valid || word!==held_word))$fatal(1,"held result changed");
            if(source_stall && (!s_valid || {s_pixel,s_sof,s_eol,s_tag}!==held_source))$fatal(1,"pending source changed");
            sink_stall=m_valid && !m_ready;held_word=word;
            source_stall=s_valid && !s_ready;held_source={s_pixel,s_sof,s_eol,s_tag};
            if(sink_stall)held_cycles=held_cycles+1;
            if(source_stall)source_stalls=source_stalls+1;
            if(s_valid && s_ready)begin
                if(seen>=N)$fatal(1,"too many frame inputs");
                pixels[seen]=s_pixel>>(PIXEL_W-GRAY_W);seen=seen+1;
            end
            if(dut.state==3)begin
                grid_work=grid_work+1;grid_checks=grid_checks+1;
                if(dut.center_now)begin
                    rx=dut.pad_x-2;ry=dut.pad_y-2;
                    if(ry*WIDTH+rx>=seen || !dut.middle1[GRAY_W])$fatal(1,"unwritten center");
                    ref_gray=pixels[ry*WIDTH+rx];ref_count=0;ref_sum=0;
                    for(dy=-1;dy<=1;dy=dy+1)for(dx=-1;dx<=1;dx=dx+1)begin
                        nx=rx+dx;ny=ry+dy;
                        if((dx!=0 || dy!=0) && nx>=0 && nx<WIDTH && ny>=0 && ny<HEIGHT)begin
                            if(ny*WIDTH+nx>=seen)$fatal(1,"unwritten neighbor");
                            ref_count=ref_count+1;ref_sum=ref_sum+pixels[ny*WIDTH+nx];
                        end
                    end
                    if(dut.middle1[GRAY_W-1:0]!==ref_gray || dut.neighbor_count_now!==ref_count ||
                        dut.neighbor_sum_now!==ref_sum)$fatal(1,"coordinate window mismatch");
                    if(!(ref_count==0 || ref_count==1 || ref_count==2 || ref_count==3 || ref_count==5 || ref_count==8))
                        $fatal(1,"illegal rectangular neighbor count");
                    ref_delta=ref_count*ref_gray-ref_sum;if(ref_delta<0)ref_delta=-ref_delta;
                    ref_scaled=(ref_count==0)?0:(120*ref_delta/ref_count);
                    center_work=center_work+1;center_checks=center_checks+1;
                    frame_neighbors=frame_neighbors+ref_count;
                    if(ref_count>0)begin
                        if(ref_delta%ref_count!=0)frame_fractional=frame_fractional+1;
                        if(ref_scaled>0)frame_nonzero=frame_nonzero+1;
                    end
                end
            end
            if(dut.state==4)begin
                if(dut.center_gray!==ref_gray || dut.neighbor_count_q!==ref_count || dut.neighbor_sum_q!==ref_sum ||
                    dut.center_product_q!==ref_count*ref_gray)$fatal(1,"absolute stage metadata");
            end
            if(dut.state==5 && dut.delta_q!==ref_delta)$fatal(1,"absolute difference");
            if(dut.state==6 && dut.scaled_q!==ref_scaled)$fatal(1,"exact scaling");
            if(dut.state==7)begin
                if(dut.hist_q[CW-1:0]!==shadow_count[old_gray] || dut.hist_q[CW+DW-1:CW]!==shadow_sum[old_gray])
                    $fatal(1,"histogram old value");
                shadow_count[old_gray]=shadow_count[old_gray]+1;
                shadow_sum[old_gray]=shadow_sum[old_gray]+ref_scaled;
                old_count=shadow_count[old_gray];old_sum=shadow_sum[old_gray];
                update_work=update_work+1;update_checks=update_checks+1;
            end
            if(m_valid && m_first)begin
                if(seen!=N || grid_work!=(WIDTH+2)*(HEIGHT+2) || center_work!=N || update_work!=(N==1?0:N))
                    $fatal(1,"complete frame work");
            end
            if(m_valid && s_ready)$fatal(1,"frame overlap");
            if(m_valid && m_ready && m_last)begin
                seen=0;grid_work=0;center_work=0;update_work=0;frame_neighbors=0;frame_fractional=0;frame_nonzero=0;
                for(j=0;j<LEVELS;j=j+1)begin shadow_count[j]=0;shadow_sum[j]=0;end
            end
        end
        #1;
        if(!rst && old_state==7 && (dut.hist_mem[old_gray][CW-1:0]!==old_count ||
            dut.hist_mem[old_gray][CW+DW-1:CW]!==old_sum))$fatal(1,"histogram committed value");
        if(cycle>3000000)$fatal(1,"finite cycle watchdog");
    end
    task push;
        input integer value,sof,eol;
        input [TAG_W-1:0] tag;
        output integer edge_number;
        begin
            @(negedge clk);s_pixel=value;s_sof=sof;s_eol=eol;s_tag=tag;s_valid=1;#1;
            while(s_ready!==1'b1)begin @(negedge clk);#1;end
            @(posedge clk);#1;edge_number=cycle;
            @(negedge clk);s_valid=0;#1;
        end
    endtask
    task wait_output;
        integer guard;
        begin
            guard=0;
            while(!m_valid)begin @(negedge clk);#1;guard=guard+1;
                if(guard>8*WIDTH+40)$fatal(1,"first-valid bound");end
        end
    endtask
    task take;
        output integer edge_number;
        begin
            m_ready=1;@(posedge clk);#1;edge_number=cycle;
            @(negedge clk);m_ready=0;#1;
        end
    endtask
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready!==0 || m_valid!==0)$fatal(1,"reset gating");
            @(posedge clk);#1;
            if(dut.state!==0 || dut.clear_index!==0)$fatal(1,"reset cancellation");
            @(negedge clk);rst=0;#1;
        end
    endtask
    task analytic_frame;
        input integer bad;
        integer p,e;
        begin
            for(p=0;p<N;p=p+1)push((p==0)?((LEVELS-1)<<(PIXEL_W-GRAY_W)):0,
                (p==0)^(bad && p==0),p%WIDTH==WIDTH-1,{TAG_W{1'b1}},e);
        end
    endtask
    integer fresh_checks=0,reset_probes=0;
    task fresh;
        integer q,e,nn,sum0,kx,ky,kcount;
        begin
            analytic_frame(0);sum0=0;
            for(ky=0;ky<HEIGHT && ky<2;ky=ky+1)for(kx=0;kx<WIDTH && kx<2;kx=kx+1)
                if(kx!=0 || ky!=0)begin
                    nn=((kx>0?1:0)+1+(kx+1<WIDTH?1:0))*((ky>0?1:0)+1+(ky+1<HEIGHT?1:0))-1;
                    sum0=sum0+120*(LEVELS-1)/nn;
                end
            for(q=0;q<LEVELS;q=q+1)begin
                wait_output;
                kcount=(N==1)?0:((q==0)?N-1:((q==LEVELS-1)?1:0));
                nn=(N==1)?0:((q==0)?sum0:((q==LEVELS-1)?120*(LEVELS-1):0));
                if(m_gray!==q || m_count!==kcount || m_difference_120!==nn || m_errors!==0 ||
                    m_tag!=={TAG_W{1'b1}} || m_first!==(q==0) || m_last!==(q==LEVELS-1))$fatal(1,"analytic fresh output");
                repeat(2)begin @(negedge clk);#1;end
                take(e);
            end
            repeat(2)begin @(negedge clk);#1;if(m_valid)$fatal(1,"stale post-fresh output");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    function target_seen;
        input integer id;
        begin case(id)
            0:target_seen=dut.state==0;
            1:target_seen=dut.state==0 && dut.clear_index==LEVELS/2;
            2:target_seen=dut.state==1 && dut.real_pixel && seen==1;
            3:target_seen=dut.state==2;
            4:target_seen=dut.state==3;
            5:target_seen=dut.state==4;
            6:target_seen=dut.state==5;
            7:target_seen=dut.state==6;
            8:target_seen=dut.state==7;
            9:target_seen=dut.state==8;
            10:target_seen=dut.state==9 && m_errors==0;
            11:target_seen=dut.state==9 && m_errors!=0;
            12:target_seen=dut.state==2 && dut.pad_y==0;
            13:target_seen=dut.state==3 && dut.pad_x==WIDTH+1 && dut.pad_y==HEIGHT+1;
            14:target_seen=dut.state==7 && dut.hist_q[CW-1:0]>=1;
            15:target_seen=dut.state==9 && m_gray==1;
            16:target_seen=dut.state==1 && dut.real_pixel && seen==1 && dut.errors!=0;
            17:target_seen=dut.state==2 && dut.pad_y>=2;
            default:target_seen=0;
        endcase end
    endfunction
    task probe;
        input integer id;
        integer guard,e,p;
        reg [OW-1:0] held;
        begin
            // Start every setup from a known immediate reset, before target work.
            reset_now;
            case(id)
                0,1,12:begin end
                2,3,4,16:push(0,id!=16,WIDTH==1,1,e);
                14:for(p=0;p<N;p=p+1)push(0,p==0,p%WIDTH==WIDTH-1,1,e);
                default:analytic_frame(id==11);
            endcase
            if(id==15)begin wait_output;take(e);end
            guard=0;
            while(!target_seen(id))begin
                @(negedge clk);#1;guard=guard+1;
                if(guard>8*WIDTH+40)$fatal(1,"unreached reset target %0d",id);
            end
            if(id==10 || id==11 || id==15)begin
                held=word;s_valid=1;s_pixel=1;s_sof=1;s_eol=1;s_tag=0;
                repeat(3)begin @(negedge clk);#1;
                    if(!m_valid || word!==held || s_ready || !target_seen(id))$fatal(1,"held blocked target");end
            end
            reset_probes=reset_probes+1;reset_now;fresh;
        end
    endtask
    integer inputs_fd,expected_fd,rc,fi,p,q,value,sof,eol,e,tail_edge,delay,got_delay,last_take;
    integer count_value,sum_value,error_value,gray_value,main_centers=0,main_updates=0,main_neighbors=0;
    integer main_fractional=0,main_nonzero=0,maximum_latency=0,outputs=0,id;
    reg [TAG_W-1:0] tag,expected_tag;
    reg [2047:0] inputs_path,expected_path;
    initial begin
        if(!$value$plusargs("INPUTS=%s",inputs_path) || !$value$plusargs("EXPECTED=%s",expected_path))$fatal(1,"missing fixtures");
        inputs_fd=$fopen(inputs_path,"r");expected_fd=$fopen(expected_path,"r");
        if(!inputs_fd || !expected_fd)$fatal(1,"fixture open");
        @(negedge clk);#1;reset_now;
        for(fi=0;fi<FRAMES;fi=fi+1)begin
            for(p=0;p<N;p=p+1)begin
                rc=$fscanf(inputs_fd,"%h %d %d %h\n",value,sof,eol,tag);if(rc!=4)$fatal(1,"input truncation");
                push(value,sof,eol,tag,e);if(p==N-1)tail_edge=e;
            end
            for(q=0;q<LEVELS;q=q+1)begin
                rc=$fscanf(expected_fd,"%d %d %d %d %h %d\n",gray_value,count_value,sum_value,error_value,expected_tag,delay);
                if(rc!=6)$fatal(1,"expected truncation");
                wait_output;
                if(q==0)begin
                    got_delay=cycle-tail_edge;if(got_delay!=delay)$fatal(1,"tail got %0d expected %0d",got_delay,delay);
                    if(got_delay>maximum_latency)maximum_latency=got_delay;
                    main_centers=main_centers+center_work;main_updates=main_updates+update_work;
                    main_neighbors=main_neighbors+frame_neighbors;main_fractional=main_fractional+frame_fractional;
                    main_nonzero=main_nonzero+frame_nonzero;
                end else if(cycle-last_take!=1)$fatal(1,"output read latency");
                if(m_gray!==gray_value || m_count!==count_value || m_difference_120!==sum_value || m_errors!==error_value ||
                    m_tag!==expected_tag || m_first!==(q==0) || m_last!==(q==LEVELS-1))$fatal(1,"dense result frame %0d bin %0d",fi,q);
                repeat(2+q%3)begin @(negedge clk);#1;if(!m_valid)$fatal(1,"hold lost valid");end
                take(last_take);outputs=outputs+1;
            end
        end
        for(id=0;id<18;id=id+1)
            if(!((id==1 && LEVELS<4) || (N==1 && (id==2 || id==7 || id==8 || id==14 || id==16))))probe(id);
        if(fresh_checks!=reset_probes)$fatal(1,"reset recovery totals");
        $fclose(inputs_fd);$fclose(expected_fd);
        $display("PASS frames=%0d pixels=%0d outputs=%0d latency_checks=%0d max_latency=%0d centers=%0d updates=%0d neighbors=%0d fractional=%0d nonzero=%0d grid_checks=%0d center_checks=%0d update_checks=%0d held_cycles=%0d source_stalls=%0d reset_probes=%0d fresh_checks=%0d",FRAMES,FRAMES*N,outputs,FRAMES,maximum_latency,main_centers,main_updates,main_neighbors,main_fractional,main_nonzero,grid_checks,center_checks,update_checks,held_cycles,source_stalls,reset_probes,fresh_checks);
        $finish;
    end
endmodule
`default_nettype wire
