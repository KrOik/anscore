// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_three_field;
    parameter integer W=9,H=6,B=10,CASES=1,PROTOCOL=1,EXAMPLE=0;
    localparam integer N=W*H,F=N/2;
    reg clk=0,rst=1,ce=1,s_valid=0,m_ready=0,done_ready=0;
    always #5 clk=~clk;
    reg cfg_first_parity=0,cfg_tint_spatial=0;
    reg [B-1:0] cfg_threshold=0,s_pixel=0;
    reg s_field_sof=0,s_eol=0,s_parity=0;
    wire s_ready,m_valid,m_sof,m_eol,m_last,done_valid,busy;
    wire [B-1:0] m_pixel;
    wire [1:0] m_source,done_error;
    wire signed [2:0] m_dir;
    wire [23:0] m_rgb;
    generate if(EXAMPLE) begin: preview
        deinterlace_rgb_preview #(.WIDTH(W),.HEIGHT(H)) dut(
            .clk(clk),.rst(rst),.ce(ce),.cfg_first_parity(cfg_first_parity),.cfg_threshold(cfg_threshold),
            .cfg_tint_spatial(cfg_tint_spatial),.s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),
            .s_field_sof(s_field_sof),.s_eol(s_eol),.s_parity(s_parity),.m_valid(m_valid),.m_ready(m_ready),
            .m_rgb(m_rgb),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.done_valid(done_valid),
            .done_ready(done_ready),.done_error(done_error),.busy(busy));
        assign m_pixel=0;assign m_source=0;assign m_dir=0;
    end else begin: core
        three_field_deinterlace #(.WIDTH(W),.HEIGHT(H),.BITS(B)) dut(
            .clk(clk),.rst(rst),.ce(ce),.cfg_first_parity(cfg_first_parity),.cfg_threshold(cfg_threshold),
            .s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),.s_field_sof(s_field_sof),.s_eol(s_eol),
            .s_parity(s_parity),.m_valid(m_valid),.m_ready(m_ready),.m_pixel(m_pixel),.m_source(m_source),
            .m_dir(m_dir),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.done_valid(done_valid),
            .done_ready(done_ready),.done_error(done_error),.busy(busy));
        assign m_rgb=0;
    end endgenerate
    reg [B-1:0] inputs[0:CASES*3*F-1];
    reg [B+1:0] configs[0:CASES-1];
    reg [B+4:0] golden[0:CASES*N-1];
    integer checked=0,completions=0,resets=0,stalls=0,timing_checks=0,errors=0;
    integer seen_source[0:2],seen_dir[0:4];
    reg held=0,held_done=0;
    reg [B+31:0] snapshot;
    reg [1:0] done_snapshot;
    wire [B+31:0] bundle={m_rgb,m_dir,m_source,m_pixel,m_sof,m_eol,m_last};
    always @(posedge clk) begin
        if(rst) begin held=0;held_done=0;end
        else begin
            if(held && (!m_valid || bundle!==snapshot)) $fatal(1,"held raster changed");
            if(held_done && (!done_valid || done_error!==done_snapshot)) $fatal(1,"held DONE changed");
            held=m_valid && (!ce || !m_ready);
            held_done=done_valid && (!ce || !done_ready);
            snapshot=bundle;done_snapshot=done_error;
            if(held) stalls=stalls+1;
        end
    end
    task reset_here;
        begin
            @(negedge clk);rst=1;ce=0;s_valid=0;m_ready=0;done_ready=0;
            @(posedge clk);#1;
            if(s_ready || m_valid || done_valid || busy) $fatal(1,"CE=0 reset failed");
            @(negedge clk);rst=0;ce=1;resets=resets+1;
        end
    endtask
    task put_pixel(input integer k,input integer index,input integer stress,input integer fault);
        integer accepted,fi,fx,position;
        reg original_parity;
        begin
            fi=index/F;position=index%F;fx=position%W;original_parity=configs[k][B];
            if(stress && index%3==0) begin
                @(negedge clk);s_valid=0;ce=(index%2==0);
                @(posedge clk);#1;if(m_valid)$fatal(1,"output before complete capture");
            end
            @(negedge clk);
            // Deliberately change live controls after the first accepted P sample.
            cfg_first_parity=(index==0)?original_parity:~original_parity;
            cfg_threshold=(index==0)?configs[k][B-1:0]:~configs[k][B-1:0];
            cfg_tint_spatial=(index==0)?configs[k][B+1]:~configs[k][B+1];
            s_valid=1;s_pixel=inputs[k*3*F+index];
            s_field_sof=(position==0);s_eol=(fx==W-1);
            s_parity=(fi==1)?~original_parity:original_parity;
            if(fault==1)s_parity=~s_parity;
            if(fault==2)s_field_sof=~s_field_sof;
            if(fault==3)s_eol=~s_eol;
            ce=!(stress && index%5==0);accepted=0;
            while(!accepted) begin
                @(posedge clk);
                if(ce && s_ready)accepted=1;
                #1;if(m_valid)$fatal(1,"output before triplet validated");
                if(!accepted)begin @(negedge clk);ce=1;end
            end
        end
    endtask
    task supply(input integer k,input integer count,input integer stress);
        integer index;
        begin
            for(index=0;index<count;index=index+1)put_pixel(k,index,stress,0);
            @(negedge clk);s_valid=0;ce=1;
        end
    endtask
    task status_ack(input integer expected_error,input integer cancel);
        integer q;
        begin
            #1;if(!done_valid || done_error!==2'(expected_error) || s_ready || m_valid || !busy)
                $fatal(1,"DONE ownership/error got %0d",done_error);
            for(q=0;q<4;q=q+1)begin
                @(negedge clk);ce=(q%2==0);done_ready=0;
                @(posedge clk);#1;
                if(!done_valid || done_error!==2'(expected_error) || s_ready || m_valid)
                    $fatal(1,"held DONE failed");
            end
            if(cancel)reset_here();
            else begin
                @(negedge clk);ce=1;done_ready=1;
                @(posedge clk);#1;if(done_valid || !s_ready || busy)$fatal(1,"DONE release failed");
                completions=completions+1;
                @(negedge clk);done_ready=0;
            end
        end
    endtask
    task render(input integer k,input integer stress,input integer cancel_done);
        integer i,attempts,last_capture,last_accept,now_edge,expected_gap;
        reg [B+4:0] expected;
        reg [B-1:0] luma;
        reg [23:0] expected_rgb;
        begin
            m_ready=!stress;done_ready=0;
            // Keep the last capture edge separately: supply returns at its following negedge.
            for(i=0;i<3*F;i=i+1)put_pixel(k,i,stress,0);
            last_capture=$time/10;
            @(negedge clk);s_valid=0;ce=1;i=0;attempts=0;last_accept=0;
            while(i<N) begin
                // This first iteration already starts on a negedge.
                ce=!stress || attempts%5!=1;m_ready=!stress || attempts%7>1;
                s_valid=1;s_pixel=~s_pixel;
                @(posedge clk);
                if(s_ready || done_valid || !busy)$fatal(1,"raster ownership");
                if(ce && m_valid && m_ready)begin
                    expected=golden[k*N+i];luma=expected[B-1:0];
                    expected_rgb=(configs[k][B+1] && expected[B+1:B]==2)?{8'hff,8'(luma),8'h00}:{8'(luma),8'(luma),8'(luma)};
                    if((EXAMPLE && m_rgb!==expected_rgb) ||
                       (!EXAMPLE && {m_dir,m_source,m_pixel}!==expected) ||
                       m_sof!==(i==0) || m_eol!==(i%W==W-1) || m_last!==(i==N-1))
                        $fatal(1,"pixel k%0d i%0d got %h expected %h rgb %h/%h",k,i,{m_dir,m_source,m_pixel},expected,m_rgb,expected_rgb);
                    now_edge=$time/10;
                    if(!stress)begin
                        if(i==0 && now_edge-last_capture!=10)$fatal(1,"first accepted latency %0d",now_edge-last_capture);
                        if(i>0)begin expected_gap=(i%W==0)?7:1;
                            if(now_edge-last_accept!=expected_gap)$fatal(1,"line II/gap failed %0d",now_edge-last_accept);
                        end
                        if(i==N-1 && now_edge-last_capture!=H*(W+6)+3)
                            $fatal(1,"drain budget failed %0d",now_edge-last_capture);
                    end
                    last_accept=now_edge;checked=checked+1;
                    if(!EXAMPLE)begin
                        seen_source[m_source]=seen_source[m_source]+1;
                        if(m_source==2)seen_dir[$signed(m_dir)+2]=seen_dir[$signed(m_dir)+2]+1;
                    end
                    i=i+1;
                end
                attempts=attempts+1;
                if(attempts>H*(W+6)*12+100)$fatal(1,"finite raster budget exceeded");
                #1;
                if(i<N)@(negedge clk);
            end
            if(!stress)timing_checks=timing_checks+1;
            @(negedge clk);s_valid=0;m_ready=0;
            status_ack(0,cancel_done);
        end
    endtask
    task corrupt(input integer kind);
        integer index,target,which;
        begin
            target=(kind==0 || kind==2)?0:(kind==1)?F:3*F-1;
            which=(kind==0 || kind==4)?1:(kind==2)?3:2;
            m_ready=1;
            for(index=0;index<=target;index=index+1)put_pixel(0,index,1,(index==target)?which:0);
            @(negedge clk);s_valid=0;
            status_ack(1,0);errors=errors+1;
            render(0,1,0);
        end
    endtask
    task cancel_phase(input integer phase);
        integer q;
        begin
            m_ready=0;
            if(phase==0)supply(0,1,0);
            else if(phase==1)supply(0,F+((F>1)?F/2:1),0);
            else begin
                supply(0,3*F,0);
                if(phase==2)repeat(3)begin @(posedge clk);#1;end
                else begin
                    q=0;
                    while(!m_valid)begin @(posedge clk);#1;q=q+1;if(q>20)$fatal(1,"missing held output");end
                    repeat(3)begin @(posedge clk);#1;end
                end
            end
            reset_here();render(0,1,0);
        end
    endtask
    integer k;
    initial begin
        $readmemh("inputs.hex",inputs);$readmemh("configs.hex",configs);$readmemh("golden.hex",golden);
        for(k=0;k<3;k=k+1)seen_source[k]=0;
        for(k=0;k<5;k=k+1)seen_dir[k]=0;
        reset_here();
        for(k=0;k<CASES;k=k+1)render(k,k!=0,0);
        if(PROTOCOL)begin
            for(k=0;k<5;k=k+1)corrupt(k);
            for(k=0;k<4;k=k+1)cancel_phase(k);
            render(0,1,1);render(0,1,0);
        end
        if(checked!=N*(CASES+(PROTOCOL?11:0)) || completions!=CASES+(PROTOCOL?15:0) ||
           resets!=(PROTOCOL?6:1) || errors!=(PROTOCOL?5:0) || timing_checks!=1 || stalls==0)
            $fatal(1,"coverage accounting failed checked%0d completions%0d resets%0d errors%0d timings%0d",checked,completions,resets,errors,timing_checks);
        $display("PASS DEINTERLACE W=%0d H=%0d B=%0d EXAMPLE=%0d cases=%0d checked=%0d completions=%0d resets=%0d errors=%0d timing=%0d stalls=%0d sources=%0d,%0d,%0d dirs=%0d,%0d,%0d,%0d,%0d",
            W,H,B,EXAMPLE,CASES,checked,completions,resets,errors,timing_checks,stalls,
            seen_source[0],seen_source[1],seen_source[2],seen_dir[0],seen_dir[1],seen_dir[2],seen_dir[3],seen_dir[4]);
        $finish;
    end
    initial begin #(1000000+N*(CASES+30)*1000);$fatal(1,"finite TB deadline");end
endmodule
