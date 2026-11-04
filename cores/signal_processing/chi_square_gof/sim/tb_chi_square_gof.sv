// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_chi_square_gof;
    parameter integer DATA_W=16,MAX_BINS=16,FRAC=16,TAG_W=8,BEATS=1,FRAMES=1;
    localparam integer GROW=(MAX_BINS<2)?0:$clog2(MAX_BINS);
    localparam integer COUNT_W=(MAX_BINS<2)?1:$clog2(MAX_BINS+1);
    localparam integer MASS_W=DATA_W+GROW,STAT_W=2*DATA_W+FRAC+GROW;
    localparam integer RW=5+TAG_W+2*MASS_W+3*COUNT_W+STAT_W;
    localparam integer DW=2*DATA_W+TAG_W+2,N=2*DATA_W+1+FRAC;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
    reg [DATA_W-1:0] s_observed=0,s_expected=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;
    wire [STAT_W-1:0] m_statistic;
    wire [COUNT_W-1:0] m_count,m_active,m_df;
    wire [MASS_W-1:0] m_sum_observed,m_sum_expected;
    wire [TAG_W-1:0] m_tag;
    wire [4:0] m_errors;
    chi_square_gof #(.DATA_W(DATA_W),.MAX_BINS(MAX_BINS),.FRAC(FRAC),.TAG_W(TAG_W)) dut(.*);
    wire [RW-1:0] response={m_errors,m_tag,m_sum_expected,m_sum_observed,
        m_df,m_active,m_count,m_statistic};
    wire [DW-1:0] request={s_tag,s_keep,s_last,s_observed,s_expected};
    reg [RW-1:0] expected [0:FRAMES-1];
    reg checking=0,held=0,source_held=0;
    reg [RW-1:0] held_response;
    reg [DW-1:0] held_request;
    integer cycle=0,outputs=0,stalls=0,source_stalls=0,reset_probes=0;
    integer accept_cycle=0,latency_checks=0;
    reg tail_arithmetic=0,tail_seen=0;
    always @(negedge clk) begin
        if (checking && !rst) m_ready=(cycle%17)>=7;
    end
    always @(posedge clk) begin
        cycle<=cycle+1;
        if (cycle>10000000) $fatal(1,"bounded cycle watchdog");
        if (rst) begin held<=0;source_held<=0;tail_seen<=0;end
        else begin
            if (held && (!m_valid || response!==held_response)) $fatal(1,"held output changed");
            if (source_held && (!s_valid || request!==held_request)) $fatal(1,"source violated hold");
            held<=m_valid&&!m_ready;held_response<=response;
            source_held<=s_valid&&!s_ready;held_request<=request;
            if (checking) begin
                if (m_valid&&!m_ready) stalls<=stalls+1;
                if (s_valid&&!s_ready) source_stalls<=source_stalls+1;
                if (m_valid && s_ready) $fatal(1,"overlapped frame ownership");
                if (s_valid && s_ready && s_last) begin
                    accept_cycle<=cycle;
                    tail_arithmetic<=s_keep && dut.count<MAX_BINS && s_expected!=0 &&
                        !dut.zero_expected && !dut.over_capacity;
                    tail_seen<=1;
                end
                if (m_valid && tail_seen) begin
                    // This monitor samples before NBA, one edge after assertion.
                    if (cycle-accept_cycle!=(tail_arithmetic?N+5:2))
                        $fatal(1,"tail-to-valid schedule mismatch got=%0d arithmetic=%0d",cycle-accept_cycle,tail_arithmetic);
                    tail_seen<=0;latency_checks<=latency_checks+1;
                end
                if (m_valid && m_ready) begin
                    if (outputs>=FRAMES || response!==expected[outputs])
                        $fatal(1,"result mismatch frame=%0d got=%h expected=%h",outputs,response,expected[outputs]);
                    outputs<=outputs+1;
                end
            end
            if (dut.state==3 && dut.div_valid && (dut.div_flags!==0 || dut.div_result[2*DATA_W+FRAC]))
                $fatal(1,"legal-domain divider flag/sign");
        end
    end
    task automatic reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;
            #1;
            if (s_ready || m_valid) $fatal(1,"reset did not suppress transfer");
            @(negedge clk);rst=0;
            #1;
            if (!s_ready || m_valid || m_count!==0 || m_active!==0 ||
                m_sum_observed!==0 || m_sum_expected!==0) $fatal(1,"reset did not cancel");
        end
    endtask
    task automatic reset_core;
        begin @(negedge clk);reset_now();end
    endtask
    task automatic send(input [DATA_W-1:0] o,e,input keep,last,input [TAG_W-1:0] tag);
        begin
            s_valid=1;s_observed=o;s_expected=e;s_keep=keep;s_last=last;s_tag=tag;
            @(posedge clk);while (!s_ready) @(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    task automatic wait_state(input integer wanted);
        integer ticks;
        begin
            ticks=0;
            while (dut.state!=wanted) begin
                @(negedge clk);ticks=ticks+1;
                if (ticks>N+12) $fatal(1,"missing reset phase %0d",wanted);
            end
        end
    endtask
    task automatic check_fresh_empty;
        integer ticks;
        begin
            @(negedge clk);send(0,0,0,1,{TAG_W{1'b1}});ticks=0;
            while (!m_valid) begin
                @(negedge clk);ticks=ticks+1;
                if (ticks>4) $fatal(1,"fresh frame missing");
            end
            if (m_errors!==5'b10001 || m_statistic!==0 || m_count!==0 || m_active!==0 ||
                m_df!==0 || m_sum_observed!==0 || m_sum_expected!==0 || m_tag!=={TAG_W{1'b1}})
                $fatal(1,"fresh frame after cancellation mismatch");
            repeat (3) @(negedge clk);
            m_ready=1;@(negedge clk);m_ready=0;
            if (m_valid) $fatal(1,"duplicate cancellation result");
        end
    endtask
    string inputs_path,expected_path;
    integer fd,fields,i,probe,waited;
    reg [DATA_W-1:0] o,e;
    reg [TAG_W-1:0] tag;
    integer keep,last;
    initial begin
        if (!$value$plusargs("INPUTS=%s",inputs_path) || !$value$plusargs("EXPECTED=%s",expected_path))
            $fatal(1,"missing vectors");
        $readmemh(expected_path,expected);
        fd=$fopen(inputs_path,"r");if (!fd) $fatal(1,"cannot open input");
        reset_core();checking=1;
        @(negedge clk);
        for (i=0;i<BEATS;i=i+1) begin
            fields=$fscanf(fd,"%h %h %d %d %h\n",o,e,keep,last,tag);
            if (fields!=5) $fatal(1,"bad input vector");
            if (i%7==0) repeat (1+i%3) @(negedge clk);
            send(o,e,keep[0],last[0],tag);
        end
        $fclose(fd);waited=0;
        while (outputs<FRAMES) begin
            @(negedge clk);waited=waited+1;
            if (waited>N+30) $fatal(1,"missing final output");
        end
        if (latency_checks!=FRAMES || stalls<1 || source_stalls<1) $fatal(1,"missing service coverage");
        checking=0;m_ready=0;
        for (probe=0;probe<8;probe=probe+1) begin
            reset_core();@(negedge clk);
            if (probe==0) send(0,0,0,0,1);
            else if (probe==4 || probe==5) send(0,0,0,1,1);
            else if (probe==6) send(1,0,1,0,1);
            else if (probe==7) begin
                for (i=0;i<MAX_BINS+1;i=i+1) send(0,0,1,0,1);
            end else send(1,1,1,0,1);
            if (probe==5) begin
                // Offer the next frame during finalization; observe a real
                // held response and stalled offer before cancelling both.
                s_valid=1;s_observed=1;s_expected=1;s_keep=1;s_last=1;s_tag=0;
                while (!(dut.state==5 && held && source_held)) @(negedge clk);
            end else if (probe<6) wait_state(probe);
            if (probe==3) begin
                while (dut.divider.state!=1 || dut.divider.cnt!=N/2) @(negedge clk);
            end
            // No intervening active edge after the targeted state is observed.
            reset_now();reset_probes=reset_probes+1;
            check_fresh_empty();
        end
        $display("PASS frames=%0d beats=%0d outputs=%0d held_cycles=%0d source_stalls=%0d latency_checks=%0d reset_probes=%0d",
            FRAMES,BEATS,outputs,stalls,source_stalls,latency_checks,reset_probes);
        $finish;
    end
endmodule
