// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_triangle_rgb;
    parameter integer W=16,H=12,TAG_W=8,CASES=1,TOTAL=1;
    reg clk=0,rst=1,c_valid=0,m_ready=0,d_ready=0;
    always #5 clk=~clk;
    reg signed [9:0] c_x0=0,c_y0=0,c_x1=0,c_y1=0,c_x2=0,c_y2=0;
    reg [23:0] c_rgb0=0,c_rgb1=0,c_rgb2=0;
    reg [TAG_W-1:0] c_tag=0;
    wire c_ready,m_valid,m_first,d_valid;
    wire [7:0] m_x,m_y;
    wire [23:0] m_rgb;
    wire [TAG_W-1:0] m_tag,d_tag;
    wire [1:0] d_status;
    wire [16:0] d_count;
    triangle_rgb_raster #(.WIDTH(W),.HEIGHT(H),.TAG_W(TAG_W)) dut(.*);
    reg [131:0] commands[0:CASES-1];
    reg [39:0] golden[0:TOTAL-1];
    reg [16:0] sizes[0:CASES-1];
    reg [1:0] statuses[0:CASES-1];
    integer cycles=0,checked=0,stalls=0,completed=0;
    reg held_valid=0;
    reg [TAG_W+40:0] held;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(rst) held_valid=0;
        else begin
            if(held_valid&&(!m_valid||{m_tag,m_first,m_rgb,m_y,m_x}!==held)) $fatal(1,"held fragment changed");
            held_valid=m_valid&&!m_ready;
            held={m_tag,m_first,m_rgb,m_y,m_x};
            if(held_valid) stalls=stalls+1;
        end
    end
    task reset_core;
        begin
            @(negedge clk);rst=1;c_valid=0;m_ready=0;d_ready=0;
            @(posedge clk);#1;
            if(c_ready||m_valid||d_valid||d_count!==0) $fatal(1,"reset failed");
            @(negedge clk);rst=0;
        end
    endtask
    task command(input integer k);
        begin
            @(negedge clk);
            {c_rgb2,c_rgb1,c_rgb0,c_y2,c_x2,c_y1,c_x1,c_y0,c_x0}=commands[k];
            c_tag=TAG_W'(k);c_valid=1;
            @(posedge clk);while(!c_ready) @(posedge clk);
            @(negedge clk);c_valid=0;
            // Live inputs stop belonging to the service immediately after capture.
            c_x0=-512;c_y0=511;c_x1=511;c_y1=-512;c_x2=0;c_y2=0;
            c_rgb0=0;c_rgb1=0;c_rgb2=0;c_tag=0;
        end
    endtask
    task render(input integer k,input integer offset,input integer reset_done);
        integer i,j;
        reg [TAG_W+18:0] done_snapshot;
        begin
            command(k);i=0;
            while(i<sizes[k]) begin
                @(negedge clk);m_ready=(cycles%7>=2);
                @(posedge clk);
                if(d_valid) $fatal(1,"completion before all fragments");
                if(m_valid&&m_ready) begin
                    if({m_rgb,m_y,m_x}!==golden[offset+i]||m_tag!==TAG_W'(k)||m_first!==(i==0))
                        $fatal(1,"fragment k%0d i%0d got%h expected%h",k,i,{m_rgb,m_y,m_x},golden[offset+i]);
                    i=i+1;checked=checked+1;
                end
            end
            @(negedge clk);m_ready=0;
            @(posedge clk);
            while(!d_valid) begin
                if(m_valid) $fatal(1,"extra fragment");
                @(posedge clk);
            end
            if(d_status!==statuses[k]||d_count!==sizes[k]||d_tag!==TAG_W'(k)) $fatal(1,"completion mismatch");
            done_snapshot={d_tag,d_status,d_count};
            for(j=0;j<3;j=j+1) begin
                @(posedge clk);
                if(!d_valid||{d_tag,d_status,d_count}!==done_snapshot||c_ready||m_valid) $fatal(1,"held completion changed");
            end
            completed=completed+1;
            if(reset_done) reset_core();
            else begin @(negedge clk);d_ready=1;@(posedge clk);@(negedge clk);d_ready=0;end
        end
    endtask
    integer k,offset;
    initial begin
        $readmemh("commands.hex",commands);$readmemh("golden.hex",golden);
        $readmemh("sizes.hex",sizes);$readmemh("statuses.hex",statuses);
        reset_core();
        command(0);repeat(23) @(posedge clk);
        if(m_valid||d_valid) $fatal(1,"arithmetic cancellation fixture timing");
        reset_core();render(0,0,0);
        command(0);@(posedge clk);while(!m_valid) @(posedge clk);
        repeat(3) @(posedge clk);reset_core();render(0,0,0);
        render(0,0,1);
        offset=0;
        for(k=0;k<CASES;k=k+1) begin render(k,offset,0);offset=offset+sizes[k];end
        if(stalls==0||checked!=TOTAL+3*sizes[0]||completed!=CASES+3) $fatal(1,"vacuous accounting");
        $display("PASS W=%0d H=%0d TAG_W=%0d cases=%0d checked=%0d completions=%0d stalls=%0d reset_phases=3",W,H,TAG_W,CASES,checked,completed,stalls);
        $finish;
    end
    initial begin #(100000+TOTAL*1000+W*H*50);$fatal(1,"finite TB deadline");end
endmodule
