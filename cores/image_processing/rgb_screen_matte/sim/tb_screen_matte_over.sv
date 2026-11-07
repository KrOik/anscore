// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_screen_matte_over;
    parameter integer TAG_W=28;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,d_valid=0,m_ready=0;
    wire s_ready,d_ready,m_valid,pipeline_busy;
    reg [23:0] s_rgb,s_key;
    reg [18:0] s_inner2,s_outer2;
    reg [7:0] s_strength;reg s_blue;
    reg [15:0] s_x,s_y;reg [TAG_W-1:0] s_tag;
    reg s_sof,s_eol,s_last;reg [31:0] d_rgba;
    wire [31:0] m_rgba;wire [2:0] m_error;
    wire [15:0] m_x,m_y;wire [TAG_W-1:0] m_tag;
    wire m_sof,m_eol,m_last;
    screen_matte_over #(.TAG_W(TAG_W)) dut(.*);
    `include "vector_reader.svh"
    localparam integer PAYLOAD_W=70+TAG_W;
    wire [PAYLOAD_W-1:0] payload={m_rgba,m_error,m_x,m_y,m_tag,m_sof,m_eol,m_last};
    reg [PAYLOAD_W-1:0] held;
    reg [23:0] prng=24'h50cafe;
    integer in_count,background_count,out_count,cycles,holds,first_input,last_output;
    reg source_pending,background_pending,blocked,source_fire,background_fire;

    task drive_source(input integer row);
        begin
            s_rgb=v_rgb[row];s_key=v_key[row];s_inner2=v_inner[row];s_outer2=v_outer[row];
            s_strength=v_strength[row];s_blue=v_blue[row];s_x=v_x[row];s_y=v_y[row];
            s_tag=v_tag[row][TAG_W-1:0];s_sof=v_sof[row];s_eol=v_eol[row];s_last=v_last[row];
        end
    endtask

    task reset_probe(input integer phase);
        integer edge_index;
        reg observed;
        begin
            @(negedge clk);rst=1;s_valid=0;d_valid=0;m_ready=0;
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;s_valid=1;d_valid=1;drive_source(phase);d_rgba=v_background[phase];
            @(posedge clk);
            if(!s_ready || !d_ready) $fatal(1,"wrapper reset probe admission");
            #1;
            for(edge_index=0;edge_index<phase;edge_index=edge_index+1) begin
                @(negedge clk);s_valid=0;d_valid=0;
                @(posedge clk);#1;
            end
            if(phase<15) observed=dut.matte.valid_pipe[phase];
            else if(phase==15) observed=dut.blend.v1;
            else if(phase==16) observed=dut.blend.v2;
            else observed=dut.blend.v3;
            if(observed!==1'b1) $fatal(1,"wrapper reset phase %0d unobserved",phase);
            if(phase==17) begin
                held=payload;
                repeat(3) begin
                    @(negedge clk);s_valid=0;d_valid=0;
                    @(posedge clk);#1;
                    if(!m_valid || payload!==held) $fatal(1,"held wrapper output changed");
                end
            end
            @(negedge clk);rst=1;s_valid=0;d_valid=0;
            #1;
            if(s_ready || d_ready || m_valid || pipeline_busy) $fatal(1,"wrapper reset masking");
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;m_ready=1;
            repeat(20) begin
                @(posedge clk);#1;
                if(m_valid || pipeline_busy) $fatal(1,"canceled wrapper token leaked");
            end
        end
    endtask

    task unmatched_reset(input reg foreground_only);
        begin
            @(negedge clk);rst=0;s_valid=foreground_only;d_valid=!foreground_only;
            drive_source(0);d_rgba=v_background[0];m_ready=1;
            repeat(4) begin
                @(posedge clk);
                if((s_valid && s_ready) || (d_valid && d_ready) || m_valid || pipeline_busy)
                    $fatal(1,"unmatched input consumed");
            end
            @(negedge clk);rst=1;s_valid=0;d_valid=0;
            #1;if(s_ready || d_ready || m_valid || pipeline_busy) $fatal(1,"unmatched reset masking");
            repeat(2) @(posedge clk);
            @(negedge clk);rst=0;
        end
    endtask

    initial begin
        load_vectors();drive_source(0);d_rgba=v_background[0];
        reset_probe(0);reset_probe(7);reset_probe(14);reset_probe(15);reset_probe(17);
        unmatched_reset(1);unmatched_reset(0);
        in_count=0;background_count=0;out_count=0;cycles=0;holds=0;first_input=-1;last_output=-1;
        source_pending=0;background_pending=0;blocked=0;
        while(out_count<vector_total) begin
            @(negedge clk);
            prng={prng[22:0],prng[23]^prng[22]^prng[21]^prng[16]};
            if(!source_pending && in_count<vector_total && (in_count<128 || prng[1:0]!=0)) begin
                drive_source(in_count);source_pending=1;
            end
            if(!background_pending && background_count<vector_total &&
               (background_count<128 || prng[3:2]!=0)) begin
                d_rgba=v_background[background_count];background_pending=1;
            end
            s_valid=source_pending;d_valid=background_pending;
            m_ready=out_count<128 || ((cycles%17)<11 && prng[5:4]!=0);
            @(posedge clk);
            if(blocked && (!m_valid || payload!==held)) $fatal(1,"wrapper held payload changed");
            blocked=m_valid && !m_ready;
            if(blocked) begin held=payload;holds=holds+1;end
            source_fire=s_valid && s_ready;background_fire=d_valid && d_ready;
            if(source_fire!=background_fire) $fatal(1,"non-atomic source/background acceptance");
            if(source_fire) begin
                if(first_input<0) first_input=cycles;
                in_count=in_count+1;background_count=background_count+1;
                source_pending=0;background_pending=0;
            end
            if(m_valid && m_ready) begin
                if(out_count>=in_count) $fatal(1,"wrapper unsolicited output");
                if(payload!=={v_over[out_count],v_over_error[out_count],v_x[out_count],v_y[out_count],
                    v_tag[out_count][TAG_W-1:0],v_sof[out_count],v_eol[out_count],v_last[out_count]})
                    $fatal(1,"wrapper row %0d got_rgba=%h expected=%h error=%h/%h",out_count,
                           m_rgba,v_over[out_count],m_error,v_over_error[out_count]);
                if(out_count==0 && cycles-first_input!=18) $fatal(1,"wrapper latency");
                if(out_count>0 && out_count<128 && cycles!=last_output+1) $fatal(1,"wrapper dense II1");
                last_output=cycles;out_count=out_count+1;
            end
            cycles=cycles+1;
            if(cycles>20000) $fatal(1,"wrapper bounded cycle budget");
        end
        if(in_count!=vector_total || background_count!=vector_total || holds==0)
            $fatal(1,"wrapper incomplete coverage");
        @(negedge clk);s_valid=0;d_valid=0;m_ready=1;
        repeat(23) begin @(posedge clk);if(m_valid) $fatal(1,"wrapper extra output");end
        if(pipeline_busy) $fatal(1,"wrapper did not drain");
        $display("MATTE_OVER_PASS rows=%0d holds=%0d live_reset_probes=5 unmatched_reset_probes=2 TAG_W=%0d",
                 out_count,holds,TAG_W);
        $finish;
    end
    initial begin #1000000;$fatal(1,"wrapper watchdog");end
endmodule
