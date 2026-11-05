// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_triangle_depth;
    reg clk=0,rst=1,begin_valid=0,c_valid=0,tri_done_ready=0,end_valid=0,m_ready=0,done_ready=0;
    always #5 clk=~clk;
    reg [23:0] begin_rgb=24'h102030,c_rgb0=0,c_rgb1=0,c_rgb2=0;
    reg [15:0] begin_depth=65535,c_depth=0;
    reg [7:0] begin_tag=35,c_tag=0,c_alpha=255;
    reg signed [9:0] c_x0=0,c_y0=0,c_x1=4,c_y1=0,c_x2=0,c_y2=4;
    reg [1:0] c_depth_func=1;reg c_depth_write=1;reg [2:0] c_color_write=7;
    wire begin_ready,c_ready,tri_done_valid,end_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_count_overflow;
    wire [1:0] tri_done_status;wire [16:0] tri_done_count;wire [7:0] tri_done_tag;
    wire [23:0] m_rgb;wire [15:0] m_depth;wire [7:0] m_x,m_y,m_tag,done_tag;
    wire [31:0] done_seen,done_passed,done_oob;
    triangle_depth64 dut(.*);
    reg [39:0] golden[0:4095];integer cycles=0,k,i,stalls=0;
    reg held=0;reg [66:0] snapshot;
    always @(posedge clk)begin
        cycles=cycles+1;
        if(rst)held=0;
        else begin
            if(held&&(!m_valid||{m_tag,m_depth,m_rgb,m_x,m_y,m_sof,m_eol,m_last}!==snapshot))$fatal(1,"integration hold");
            held=m_valid&&!m_ready;snapshot={m_tag,m_depth,m_rgb,m_x,m_y,m_sof,m_eol,m_last};if(held)stalls=stalls+1;
        end
    end
    initial begin
        $readmemh("golden.hex",golden);
        @(negedge clk);@(posedge clk);@(negedge clk);rst=0;begin_valid=1;
        @(posedge clk);if(!begin_ready)$fatal(1,"integration begin");
        @(negedge clk);begin_valid=0;
        for(k=0;k<5;k=k+1)begin
            c_tag=8'(k+1);c_depth_func=1;c_depth_write=1;c_color_write=7;c_alpha=255;
            case(k)
                0:begin c_rgb0=24'hff0000;c_depth=100;end
                1:begin c_rgb0=24'h0000ff;c_depth=200;end
                2:begin c_rgb0=24'h00ff00;c_depth=50;c_alpha=128;c_depth_write=0;end
                3:begin c_rgb0=24'hffffff;c_depth=100;c_depth_func=2;c_depth_write=0;c_color_write=4;end
                4:begin c_y2=0;c_rgb0=0;c_depth=0;end
            endcase
            c_rgb1=c_rgb0;c_rgb2=c_rgb0;c_valid=1;
            @(posedge clk);while(!c_ready)@(posedge clk);
            @(negedge clk);c_valid=0;c_depth=65535;c_alpha=0;c_color_write=0;c_depth_func=3;
            while(!tri_done_valid)@(negedge clk);
            if(tri_done_status!==(k==4?1:0)||tri_done_count!==(k==4?0:6)||tri_done_tag!==8'(k+1))$fatal(1,"triangle completion%0d",k);
            end_valid=1;
            repeat(3)begin @(posedge clk);if(end_ready||c_ready||m_valid)$fatal(1,"END escaped triangle ownership");end
            @(negedge clk);end_valid=0;tri_done_ready=1;
            @(posedge clk);@(negedge clk);tri_done_ready=0;
        end
        end_valid=1;@(posedge clk);while(!end_ready)@(posedge clk);
        @(negedge clk);end_valid=0;i=0;
        while(i<4096)begin
            @(negedge clk);m_ready=(cycles%7>1);
            @(posedge clk);if(m_valid&&m_ready)begin
                if({m_depth,m_rgb}!==golden[i]||m_x!==8'(i%64)||m_y!==8'(i/64)||m_tag!==35||
                   m_sof!==(i==0)||m_eol!==(i%64==63)||m_last!==(i==4095))$fatal(1,"integrated raster%0d",i);
                i=i+1;
            end
        end
        @(negedge clk);m_ready=0;@(posedge clk);while(!done_valid)@(posedge clk);
        if(done_seen!==24||done_passed!==18||done_oob||done_count_overflow||done_tag!==35||stalls==0)$fatal(1,"integration stats");
        repeat(3)@(posedge clk);
        @(negedge clk);done_ready=1;@(posedge clk);@(negedge clk);
        if(!begin_ready)$fatal(1,"integration completion recovery");
        $display("PASS TRIANGLE_STORE triangles=5 seen=24 passed=18 checked=4096 stalls=%0d",stalls);$finish;
    end
    initial begin #1000000;$fatal(1,"integration finite deadline");end
endmodule
