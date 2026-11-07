// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_rgb_screen_matte;
    parameter integer TAG_W=32;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid,m_error,pipeline_busy;
    reg [23:0] s_rgb,s_key;
    reg [18:0] s_inner2,s_outer2;
    reg [7:0] s_strength;reg s_blue;
    reg [15:0] s_x,s_y;reg [TAG_W-1:0] s_tag;
    reg s_sof,s_eol,s_last;reg [31:0] s_user;
    wire [31:0] m_rgba,m_user;
    wire [15:0] m_x,m_y;wire [TAG_W-1:0] m_tag;
    wire m_sof,m_eol,m_last;
    rgb_screen_matte #(.TAG_W(TAG_W)) dut(.*);
    `include "vector_reader.svh"
    localparam integer PAYLOAD_W=100+TAG_W;
    wire [PAYLOAD_W-1:0] payload={m_rgba,m_error,m_x,m_y,m_tag,m_sof,m_eol,m_last,m_user};
    reg [PAYLOAD_W-1:0] held;
    reg [23:0] prng=24'h5b50c1;
    integer in_count,out_count,cycles,holds,first_input,last_output;
    reg pending,blocked;

    task drive_token(input integer row);
        begin
            s_rgb=v_rgb[row];s_key=v_key[row];s_inner2=v_inner[row];s_outer2=v_outer[row];
            s_strength=v_strength[row];s_blue=v_blue[row];s_x=v_x[row];s_y=v_y[row];
            s_tag=v_tag[row][TAG_W-1:0];s_sof=v_sof[row];s_eol=v_eol[row];
            s_last=v_last[row];s_user=v_user[row];
        end
    endtask

    task reset_probe(input integer phase);
        integer edge_index;
        begin
            @(negedge clk);rst=1;s_valid=0;m_ready=0;
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;s_valid=1;drive_token(phase);
            @(posedge clk);
            if(!s_ready) $fatal(1,"reset probe admission");
            #1;
            for(edge_index=0;edge_index<phase;edge_index=edge_index+1) begin
                @(negedge clk);s_valid=0;
                @(posedge clk);#1;
            end
            if(dut.valid_pipe[phase]!==1'b1) $fatal(1,"reset phase %0d unobserved",phase);
            if(phase==14) begin
                held=payload;
                repeat(3) begin
                    @(negedge clk);s_valid=0;
                    @(posedge clk);#1;
                    if(!m_valid || payload!==held) $fatal(1,"held reset output changed");
                end
            end
            @(negedge clk);rst=1;s_valid=0;
            #1;
            if(s_ready || m_valid || pipeline_busy) $fatal(1,"reset masking");
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;m_ready=1;
            repeat(17) begin
                @(posedge clk);#1;
                if(m_valid || pipeline_busy) $fatal(1,"canceled core token leaked");
            end
        end
    endtask

    initial begin
        load_vectors();drive_token(0);
        reset_probe(0);reset_probe(3);reset_probe(7);reset_probe(11);reset_probe(14);
        in_count=0;out_count=0;cycles=0;holds=0;first_input=-1;last_output=-1;
        pending=0;blocked=0;
        while(out_count<vector_total) begin
            @(negedge clk);
            prng={prng[22:0],prng[23]^prng[22]^prng[21]^prng[16]};
            if(!pending && in_count<vector_total && (in_count<128 || prng[1:0]!=0)) begin
                drive_token(in_count);pending=1;
            end
            s_valid=pending;
            m_ready=out_count<128 || ((cycles%13)<9 && prng[3:2]!=0);
            @(posedge clk);
            if(blocked && (!m_valid || payload!==held)) $fatal(1,"core held payload changed");
            blocked=m_valid && !m_ready;
            if(blocked) begin held=payload;holds=holds+1;end
            if(s_valid && s_ready) begin
                if(first_input<0) first_input=cycles;
                in_count=in_count+1;pending=0;
            end
            if(m_valid && m_ready) begin
                if(out_count>=in_count) $fatal(1,"core unsolicited output");
                if(payload!=={v_rgba[out_count],v_error[out_count],v_x[out_count],v_y[out_count],
                    v_tag[out_count][TAG_W-1:0],v_sof[out_count],v_eol[out_count],
                    v_last[out_count],v_user[out_count]})
                    $fatal(1,"core row %0d got_rgba=%h expected=%h error=%b/%b",out_count,
                           m_rgba,v_rgba[out_count],m_error,v_error[out_count]);
                if(m_rgba[31:24]>m_rgba[7:0] || m_rgba[23:16]>m_rgba[7:0] ||
                   m_rgba[15:8]>m_rgba[7:0]) $fatal(1,"premultiplication invariant");
                if(out_count==0 && cycles-first_input!=15) $fatal(1,"core latency");
                if(out_count>0 && out_count<128 && cycles!=last_output+1) $fatal(1,"core dense II1");
                last_output=cycles;out_count=out_count+1;
            end
            cycles=cycles+1;
            if(cycles>20000) $fatal(1,"core bounded cycle budget");
        end
        if(in_count!=vector_total || holds==0) $fatal(1,"core incomplete coverage");
        @(negedge clk);s_valid=0;m_ready=1;
        repeat(20) begin @(posedge clk);if(m_valid) $fatal(1,"core extra output");end
        if(pipeline_busy) $fatal(1,"core did not drain");
        $display("MATTE_CORE_PASS rows=%0d holds=%0d live_reset_probes=5 TAG_W=%0d",out_count,holds,TAG_W);
        $finish;
    end
    initial begin #1000000;$fatal(1,"core watchdog");end
endmodule
