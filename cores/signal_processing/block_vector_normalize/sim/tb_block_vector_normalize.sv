// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_block_vector_normalize;
    parameter integer W=16,L=16,F=16,T=8;
    localparam integer C=(L<2)?1:$clog2(L+1),I=(L<2)?1:$clog2(L);
    localparam integer E=2*W+((L<2)?0:$clog2(L)),RF=F+2;
    localparam integer RN=(E+2*RF+1)/2,DN=W+RF+F;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_data=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_keep,m_last;
    wire signed [F+1:0] m_data;
    wire [1:0] m_status;
    wire [C-1:0] m_count;
    wire [I-1:0] m_index;
    wire [E-1:0] m_energy;
    wire [T-1:0] m_tag;
    block_vector_normalize #(.DATA_W(W),.MAX_LEN(L),.FRAC(F),.TAG_W(T)) dut(.*);
    integer cycles=0,last_input_cycle=0,last_output_cycle=0,tokens=0,frames=0;
    integer held_cycles=0,source_stalls=0,reset_count=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>2000000) $fatal(1,"bounded watchdog");
        if(!rst && dut.state==7 && dut.div_valid && dut.div_user_unused!=0)
            $fatal(1,"unexpected legal-domain divide/clipping flag");
    end
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;if(s_ready || m_valid) $fatal(1,"reset transfer gating");
            repeat(2) @(negedge clk);rst=0;
            #1;if(!s_ready || m_valid) $fatal(1,"reset rearm");
            reset_count=reset_count+1;
        end
    endtask
    task put(input [W-1:0] value,input bit keep,last,input [T-1:0] tag,input integer gap);
        integer watchdog;
        begin
            repeat(gap) @(negedge clk);
            // The previous put returns at a negedge. A zero-gap successor
            // offers immediately, exercising ACCUMULATE input backpressure.
            s_valid=1;s_data=value;s_keep=keep;s_last=last;s_tag=tag;
            watchdog=0;@(posedge clk);
            while(!s_ready) begin
                source_stalls=source_stalls+1;watchdog=watchdog+1;
                if(watchdog>3) $fatal(1,"collection timeout");
                @(posedge clk);
            end
            #1;if(last)last_input_cycle=cycles;
            @(negedge clk);s_valid=0;s_data=~value;s_keep=~keep;s_last=~last;s_tag=~tag;
        end
    endtask
    task get_token(input [F+1:0] data,input bit keep,last,input [1:0] status,
                   input [C-1:0] count,input [I-1:0] index,input [E-1:0] energy,
                   input [T-1:0] tag,input integer delay,hold);
        integer watchdog;
        begin
            watchdog=0;
            while(!m_valid) begin
                if(s_ready) $fatal(1,"admitted during frame calculation/output");
                @(negedge clk);watchdog=watchdog+1;
                if(watchdog>RN+DN+12) $fatal(1,"token timeout");
            end
            if(cycles-(index==0?last_input_cycle:last_output_cycle)!=delay)
                $fatal(1,"token latency index=%0d delta=%0d expected=%0d",index,cycles-(index==0?last_input_cycle:last_output_cycle),delay);
            repeat(hold+1) begin
                if(!m_valid || {m_data,m_keep,m_last,m_status,m_count,m_index,m_energy,m_tag}
                    !== {data,keep,last,status,count,index,energy,tag})
                    $fatal(1,"token %0d got data=%0d keep/last=%b%b status=%0d count=%0d index=%0d energy=%h tag=%h expected data=%0d keep/last=%b%b status=%0d count=%0d index=%0d energy=%h tag=%h",
                        tokens,m_data,m_keep,m_last,m_status,m_count,m_index,m_energy,m_tag,
                        $signed(data),keep,last,status,count,index,energy,tag);
                if(s_ready) $fatal(1,"admitted while holding result");
                held_cycles=held_cycles+1;@(negedge clk);
            end
            m_ready=1;@(posedge clk);#1;last_output_cycle=cycles;
            @(negedge clk);m_ready=0;
            if(m_valid || (last && !s_ready) || (!last && s_ready)) $fatal(1,"result ownership/duplicate");
            tokens=tokens+1;if(last)frames=frames+1;
        end
    endtask
    task await_phase(input integer phase);
        integer watchdog;
        reg found;
        begin
            watchdog=0;found=0;
            while(!found) begin
                if(phase<10)found=(dut.state==phase);
                else if(phase==10)found=(dut.state==4 && dut.root_valid);
                else found=(dut.state==7 && dut.div_valid);
                if(!found) begin
                    @(negedge clk);watchdog=watchdog+1;
                    if(watchdog>RN+DN+12) $fatal(1,"reset phase unavailable %0d",phase);
                end
            end
        end
    endtask
    integer phase;
    initial begin
        reset_now();
        for(phase=0;phase<12;phase=phase+1) begin
            put(phase==8?0:1,1,phase!=0,0,0);
            if(phase==9) begin
                // Hold next-frame offer during processing; cancel immediately
                // once the pending-result phase is observed.
                s_valid=1;s_data=0;s_keep=1;s_last=1;s_tag=0;
            end
            await_phase(phase);
            reset_now();
        end
        `include "vectors.svh"
        repeat(5) begin @(negedge clk);if(m_valid) $fatal(1,"ghost output");end
        if(source_stalls==0) $fatal(1,"no source-stall coverage");
        $display("PASS normalize W=%0d L=%0d F=%0d T=%0d frames=%0d tokens=%0d held=%0d source_stalls=%0d resets=%0d",
                 W,L,F,T,frames,tokens,held_cycles,source_stalls,reset_count);
        $finish;
    end
endmodule
