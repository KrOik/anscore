// SPDX-License-Identifier: Apache-2.0
// Directed continuation: complete maximum-size capture, only 64 checked outputs.
`timescale 1ns/1ps
module tb_max_prefix;
    localparam integer N=16384,PREFIX=64,TAG_W=32;
    reg clk=0,rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,m_ready=0,done_ready=0;
    always #5 clk=~clk;
    reg [11:0] start_key_q8=256;
    reg [TAG_W-1:0] start_tag=32'h34003400;
    reg [47:0] s_rgb=0;
    reg s_sof=0,s_eol=0,s_last=0;
    wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid;
    wire [23:0] m_rgb,m_exposure,done_exposure;
    wire [7:0] m_x,m_y;
    wire [TAG_W-1:0] m_tag,done_tag;
    wire [1:0] done_error;
    wire [14:0] done_count;
    wire [31:0] done_sum_max;
    frame_adaptive_rgb_tonemap #(.WIDTH(128),.HEIGHT(128),.TAG_W(TAG_W)) dut(.*);
    reg [47:0] pixels[0:N-1];reg [23:0] golden[0:N-1];
    reg [23:0] exposure_vector[0:0];reg [31:0] sum_vector[0:0];
    integer i,cycles=0,stalls=0;
    reg held=0;reg [98:0] snapshot;
    wire [98:0] bundle={m_tag,m_exposure,m_rgb,m_x,m_y,m_sof,m_eol,m_last};
    always @(posedge clk) begin
        cycles=cycles+1;
        if(!rst_n) held=0;
        else begin
            if(held&&(!m_valid||bundle!==snapshot)) $fatal(1,"prefix hold changed");
            held=m_valid&&(!ce||!m_ready)&&!(ce&&abort);snapshot=bundle;
            if(held) stalls=stalls+1;
            if(!ce&&(start_ready||s_ready)) $fatal(1,"prefix CE ready");
        end
    end
    initial begin
        $readmemh("pixels.hex",pixels);$readmemh("golden.hex",golden);
        $readmemh("exposures.hex",exposure_vector);$readmemh("sums.hex",sum_vector);
        @(negedge clk);ce=0;@(posedge clk);#1;
        if(m_valid||done_valid||done_count) $fatal(1,"prefix reset");
        @(negedge clk);rst_n=1;ce=1;start_valid=1;
        @(posedge clk);if(!start_ready) $fatal(1,"prefix command");
        @(negedge clk);start_valid=0;start_key_q8=0;
        for(i=0;i<N;i=i+1) begin
            @(negedge clk);ce=1;s_valid=1;s_rgb=pixels[i];s_sof=(i==0);s_eol=(i%128==127);s_last=(i==N-1);
            @(posedge clk);if(!s_ready||m_valid||done_valid) $fatal(1,"prefix capture%0d",i);
        end
        @(negedge clk);s_valid=0;i=0;
        while(i<PREFIX) begin
            @(negedge clk);ce=(cycles%11!=0);m_ready=(cycles%7>1);
            @(posedge clk);
            if(s_ready||start_ready||done_valid) $fatal(1,"prefix ownership");
            if(ce&&m_valid&&m_ready) begin
                if(m_rgb!==golden[i]||m_exposure!==exposure_vector[0]||m_tag!==32'h34003400||
                   m_x!==8'(i%128)||m_y!==8'(i/128)||m_sof!==(i==0)||m_eol!==(i%128==127)||m_last)
                    $fatal(1,"prefix pixel%0d got%h expected%h",i,m_rgb,golden[i]);
                i=i+1;
            end
        end
        @(negedge clk);ce=1;m_ready=0;abort=1;
        @(posedge clk);@(negedge clk);abort=0;
        if(!done_valid||m_valid||done_error!==3||done_count!==PREFIX||done_tag!==32'h34003400||
           done_sum_max!==sum_vector[0]||done_exposure!==exposure_vector[0]) $fatal(1,"prefix aborted DONE");
        repeat(4) begin @(posedge clk);if(!done_valid||done_count!==PREFIX||done_error!==3) $fatal(1,"prefix held DONE");end
        @(negedge clk);done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;
        if(!start_ready||done_valid||stalls==0) $fatal(1,"prefix recovery");
        $display("PASS MAX_PREFIX captured=16384 checked=64 aborted=1 stalls=%0d",stalls);$finish;
    end
    initial begin #1000000;$fatal(1,"max-prefix finite deadline");end
endmodule
