// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_tonemap;
    parameter integer W=7,H=5,TAG_W=8,CASES=1,PROTOCOL=1;
    localparam integer N=W*H,TOTAL=N*CASES;
    reg clk=0,rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,m_ready=0,done_ready=0;
    always #5 clk=~clk;
    reg [11:0] start_key_q8=256;
    reg [TAG_W-1:0] start_tag=0;
    reg [47:0] s_rgb=0;
    reg s_sof=0,s_eol=0,s_last=0;
    wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid;
    wire [23:0] m_rgb,m_exposure,done_exposure;
    wire [7:0] m_x,m_y;
    wire [TAG_W-1:0] m_tag,done_tag;
    wire [1:0] done_error;
    wire [14:0] done_count;
    wire [31:0] done_sum_max;
    frame_adaptive_rgb_tonemap #(.WIDTH(W),.HEIGHT(H),.TAG_W(TAG_W)) dut(.*);
    reg [47:0] pixels[0:TOTAL-1];
    reg [23:0] golden[0:TOTAL-1],exposures[0:CASES-1];
    reg [31:0] sums[0:CASES-1];
    reg [11:0] keys[0:CASES-1];
    integer cycles=0,checked=0,completed=0,stalls=0,ce_pauses=0,resets=0,aborts=0,errors=0;
    reg held=0,held_done=0;
    reg [TAG_W+66:0] held_pixel;
    reg [TAG_W+72:0] held_completion;
    wire [TAG_W+66:0] pixel_bundle={m_tag,m_exposure,m_rgb,m_x,m_y,m_sof,m_eol,m_last};
    wire [TAG_W+72:0] done_bundle={done_tag,done_error,done_count,done_sum_max,done_exposure};
    always @(posedge clk) begin
        cycles=cycles+1;
        if(!rst_n) begin held=0;held_done=0;end
        else begin
            if(held && (!m_valid || pixel_bundle!==held_pixel)) $fatal(1,"stalled output changed");
            if(held_done && (!done_valid || done_bundle!==held_completion)) $fatal(1,"stalled DONE changed");
            if(!ce && (start_ready||s_ready)) $fatal(1,"ready during CE pause");
            held=m_valid&&(!ce||!m_ready)&&!(ce&&abort);
            held_done=done_valid&&(!ce||!done_ready);
            held_pixel=pixel_bundle;held_completion=done_bundle;
            if(held) stalls=stalls+1;
            if(!ce) ce_pauses=ce_pauses+1;
        end
    end
    task reset_here;
        begin
            rst_n=0;ce=0;start_valid=0;s_valid=0;abort=0;m_ready=0;done_ready=0;
            @(posedge clk);#1;
            if(m_valid||done_valid||start_ready||s_ready||done_count!==0) $fatal(1,"CE-low reset failed");
            @(negedge clk);rst_n=1;ce=1;resets=resets+1;
        end
    endtask
    task reset_core;
        begin @(negedge clk);reset_here();end
    endtask
    task command(input integer k,input integer override_key);
        begin
            @(negedge clk);ce=1;start_valid=1;start_key_q8=override_key<0?keys[k]:12'(override_key);start_tag=TAG_W'(k+1);
            @(posedge clk);while(!start_ready) @(posedge clk);
            @(negedge clk);start_valid=0;start_key_q8=0;start_tag=0;
        end
    endtask
    task send_frame(input integer k,input integer bad_kind);
        integer i;
        begin
            for(i=0;i<N;i=i+1) begin
                @(negedge clk);ce=(cycles%5!=0);s_valid=1;s_rgb=pixels[k*N+i];
                s_sof=(i==0);s_eol=(i%W==W-1);s_last=(i==N-1);
                if(i==N-1) begin
                    if(bad_kind==1) s_sof=~s_sof;
                    if(bad_kind==2) s_eol=~s_eol;
                    if(bad_kind==3) s_last=~s_last;
                end
                @(posedge clk);
                while(!(ce&&s_ready)) begin @(negedge clk);ce=1;@(posedge clk);end
            end
            @(negedge clk);s_valid=0;ce=1;s_rgb=48'h123456789abc;s_sof=0;s_eol=0;s_last=0;
        end
    endtask
    task acknowledge(input integer error_code,input integer count,input integer k,input integer check_stats);
        integer j;
        begin
            @(posedge clk);while(!done_valid) begin
                if(m_valid) $fatal(1,"unexpected pixel before DONE");
                @(posedge clk);
            end
            if(done_error!==2'(error_code)||done_count!==15'(count)||done_tag!==TAG_W'(k+1))
                $fatal(1,"DONE mismatch error%0d count%0d tag%0d",done_error,done_count,done_tag);
            if(check_stats && (done_exposure!==exposures[k]||done_sum_max!==sums[k])) $fatal(1,"DONE stats mismatch");
            for(j=0;j<4;j=j+1) begin
                @(negedge clk);ce=(j%2==0);done_ready=0;
                @(posedge clk);if(!done_valid||m_valid||start_ready||s_ready) $fatal(1,"DONE ownership");
            end
            @(negedge clk);ce=0;done_ready=1;
            @(posedge clk);@(negedge clk);if(!done_valid) $fatal(1,"DONE consumed while CE low");
            ce=1;@(posedge clk);@(negedge clk);done_ready=0;
            completed=completed+1;
        end
    endtask
    task render(input integer k);
        integer i;
        begin
            command(k,-1);send_frame(k,0);i=0;
            while(i<N) begin
                @(negedge clk);ce=(cycles%11!=0);m_ready=(cycles%7>1);
                // A second command remains forbidden until DONE acknowledgement.
                start_valid=1;start_key_q8=1;start_tag=~TAG_W'(k+1);
                @(posedge clk);
                if(start_ready||s_ready||done_valid) $fatal(1,"processing ownership");
                if(ce&&m_valid&&m_ready) begin
                    if(m_rgb!==golden[k*N+i]||m_x!==8'(i%W)||m_y!==8'(i/W)||
                       m_sof!==(i==0)||m_eol!==(i%W==W-1)||m_last!==(i==N-1)||
                       m_tag!==TAG_W'(k+1)||m_exposure!==exposures[k])
                        $fatal(1,"pixel k%0d i%0d got%h expected%h A%0d expected%0d",k,i,m_rgb,golden[k*N+i],m_exposure,exposures[k]);
                    checked=checked+1;i=i+1;
                end
            end
            @(negedge clk);ce=1;m_ready=0;start_valid=0;
            acknowledge(0,N,k,1);
        end
    endtask
    task cancel_at(input integer target,input integer use_reset,input integer accept_output);
        integer watchdog;
        begin
            command(0,-1);
            if(target!=1) send_frame(0,0);
            watchdog=0;
            while(dut.state!=target) begin
                @(negedge clk);ce=1;watchdog=watchdog+1;
                if(watchdog>1000) $fatal(1,"unreached cancellation phase%0d",target);
            end
            if(use_reset) begin reset_here();render(0);end
            else begin
                // Pause once in the target phase; abort has no effect until CE.
                ce=0;abort=1;m_ready=accept_output;
                @(posedge clk);@(negedge clk);
                if(dut.state!=target) $fatal(1,"abort ignored CE");
                ce=1;@(posedge clk);@(negedge clk);abort=0;m_ready=0;
                acknowledge(3,(target==9&&accept_output)?1:0,0,0);aborts=aborts+1;render(0);
            end
        end
    endtask
    integer k,phase,drained;
    initial begin
        $readmemh("pixels.hex",pixels);$readmemh("golden.hex",golden);
        $readmemh("keys.hex",keys);$readmemh("exposures.hex",exposures);$readmemh("sums.hex",sums);
        reset_core();
        for(k=0;k<CASES;k=k+1) render(k);
        if(PROTOCOL) begin
            command(0,0);acknowledge(1,0,0,0);errors=errors+1;
            for(k=1;k<=3;k=k+1) begin
                command(0,-1);send_frame(0,k);acknowledge(2,0,0,0);errors=errors+1;render(0);
            end
            // Exact internal phases only select cancellation timing, never arithmetic.
            for(phase=1;phase<=9;phase=phase+1) begin
                cancel_at(phase,1,0);cancel_at(phase,0,0);
            end
            cancel_at(9,0,1);
            command(0,-1);send_frame(0,0);
            while(!m_valid) @(negedge clk);
            m_ready=1;drained=0;
            while(!done_valid) begin
                @(posedge clk);
                if(ce&&m_valid&&m_ready) begin
                    if(m_rgb!==golden[drained]||m_x!==8'(drained%W)||m_y!==8'(drained/W)) $fatal(1,"DONE-reset drain mismatch");
                    drained=drained+1;checked=checked+1;
                end
                @(negedge clk);
            end
            if(drained!=N||done_count!=N||done_error!=0) $fatal(1,"DONE-reset completion");
            m_ready=0;reset_core();render(0);
        end
        if(stalls==0||ce_pauses==0||checked!=N*(CASES+(PROTOCOL?24:0))||completed!=CASES+(PROTOCOL?37:0))
            $fatal(1,"coverage accounting checked%0d completed%0d",checked,completed);
        $display("PASS W=%0d H=%0d TAG_W=%0d cases=%0d checked=%0d completions=%0d stalls=%0d ce_pauses=%0d resets=%0d aborts=%0d errors=%0d",W,H,TAG_W,CASES,checked,completed,stalls,ce_pauses,resets,aborts,errors);
        $finish;
    end
    initial begin #(200000+N*(CASES+30)*2500);$fatal(1,"finite TB deadline");end
endmodule
