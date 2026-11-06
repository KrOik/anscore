// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_indexed_frame;
    reg clk=0,rst=1;always #5 clk=~clk;
    reg tex_c_valid=0,tex_r_ready=0,t_valid=0,p_valid=0;
    reg [1:0] tex_c_op=0;reg [7:0] tex_c_tag=0,t_index=0;reg [31:0] p_rgba=0;
    wire tex_c_ready,tex_r_valid,t_ready,p_ready,texture_resident;
    wire [1:0] tex_r_status;wire [7:0] tex_r_tag;wire [16:0] tex_r_tex_count;wire [8:0] tex_r_pal_count;
    reg begin_valid=0,c_valid=0,tri_done_ready=0,end_valid=0,m_ready=0,done_ready=0;
    reg [23:0] begin_rgb=24'h102030;reg [15:0] begin_depth=65535;reg [7:0] begin_tag=8'he1;
    reg signed [9:0] c_x0=0,c_y0=0,c_x1=0,c_y1=0,c_x2=0,c_y2=0;
    reg [7:0] c_u0=0,c_v0=0,c_u1=0,c_v1=0,c_u2=0,c_v2=0,c_tag=0;
    reg [15:0] c_depth=0;reg [1:0] c_depth_func=0;reg c_depth_write=0;reg [2:0] c_color_write=0;
    wire begin_ready,c_ready,tri_done_valid,end_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_count_overflow;
    wire [1:0] tri_done_status;wire [16:0] tri_done_covered,tri_done_visible;wire [7:0] tri_done_tag;
    wire [23:0] m_rgb;wire [15:0] m_depth;wire [7:0] m_x,m_y,m_tag,done_tag;
    wire [31:0] done_seen,done_passed,done_oob;
    indexed_triangle_frame #(.WIDTH(16),.HEIGHT(12),.TEX_WIDTH(4),.TEX_HEIGHT(4),.TAG_W(8)) dut(.*);
    reg [7:0] texture[0:15];reg [31:0] palette[0:255];
    reg [137:0] triangles[0:8];reg [35:0] triangle_stats[0:8];
    reg [39:0] golden[0:191];reg [95:0] stats[0:0];
    integer frames=0,commands=0,checked=0,stalls=0,resets=0,cycles=0;
    reg held=0;reg [66:0] snapshot;
    wire [66:0] bundle={m_depth,m_rgb,m_x,m_y,m_tag,m_sof,m_eol,m_last};
    always @(posedge clk)begin
        cycles=cycles+1;if(cycles>500000)$fatal(1,"finite frame watchdog");
        if(rst)held=0;
        else begin
            if(held && (!m_valid || bundle!==snapshot))$fatal(1,"held frame changed");
            held=m_valid&&!m_ready;snapshot=bundle;if(held)stalls=stalls+1;
            if(dut.tri_owned && tex_c_ready)$fatal(1,"texture epoch changed inside primitive");
            if(dut.sample_valid && !dut.sample_visible && dut.store.s_valid)
                $fatal(1,"transparent fragment reached RGB/Z store");
        end
    end
    task reset_here;
        begin
            @(negedge clk);rst=1;tex_c_valid=0;tex_r_ready=0;t_valid=0;p_valid=0;
            begin_valid=0;c_valid=0;tri_done_ready=0;end_valid=0;m_ready=0;done_ready=0;
            @(posedge clk);#1;if(m_valid||tri_done_valid||done_valid||texture_resident)$fatal(1,"frame reset");
            @(negedge clk);rst=0;resets=resets+1;
        end
    endtask
    task texture_response(input integer status,input integer tc,input integer pc);
        reg [35:0] value;
        begin
            #1;
            if(!tex_r_valid || tex_r_status!==2'(status) || tex_r_tag!==tex_c_tag ||
               tex_r_tex_count!==17'(tc) || tex_r_pal_count!==9'(pc))$fatal(1,"texture response");
            value={tex_r_status,tex_r_tag,tex_r_tex_count,tex_r_pal_count};
            repeat(3)begin @(posedge clk);if(!tex_r_valid||{tex_r_status,tex_r_tag,tex_r_tex_count,tex_r_pal_count}!==value)$fatal(1,"held texture response");end
            @(negedge clk);tex_r_ready=1;@(posedge clk);@(negedge clk);tex_r_ready=0;
        end
    endtask
    task texture_command(input integer op,input integer status,input integer tc,input integer pc);
        begin
            @(negedge clk);tex_c_valid=1;tex_c_op=2'(op);tex_c_tag=8'h91;
            @(posedge clk);while(!tex_c_ready)@(posedge clk);
            @(negedge clk);tex_c_valid=0;texture_response(status,tc,pc);
        end
    endtask
    task load_texture;
        integer ti,pi;
        begin
            texture_command(0,0,0,0);ti=0;pi=0;
            while(ti<16 || pi<256)begin
                @(negedge clk);t_valid=ti<16;p_valid=pi<256;
                if(ti<16)t_index=texture[ti];if(pi<256)p_rgba=palette[pi];
                @(posedge clk);if(t_valid&&t_ready)ti=ti+1;if(p_valid&&p_ready)pi=pi+1;
            end
            @(negedge clk);t_valid=0;p_valid=0;texture_command(1,0,16,256);
        end
    endtask
    task begin_frame;
        begin
            @(negedge clk);begin_valid=1;
            @(posedge clk);while(!begin_ready)@(posedge clk);
            @(negedge clk);begin_valid=0;
        end
    endtask
    task issue_triangle(input integer k);
        begin
            @(negedge clk);
            {c_tag,c_color_write,c_depth_write,c_depth_func,c_depth,c_v2,c_u2,c_v1,c_u1,c_v0,c_u0,
             c_y2,c_x2,c_y1,c_x1,c_y0,c_x0}=triangles[k];c_valid=1;
            @(posedge clk);while(!c_ready)@(posedge clk);commands=commands+1;
            @(negedge clk);c_valid=0;
            c_depth=~c_depth;c_depth_func=~c_depth_func;c_depth_write=~c_depth_write;c_color_write=~c_color_write;
            c_u0=255;c_v0=255;c_x0=-512;c_y0=511;c_tag=0;
        end
    endtask
    task finish_triangle(input integer k);
        integer budget;
        reg [51:0] held_done;
        begin
            if(k==2)begin tex_c_valid=1;tex_c_op=2;tex_c_tag=8'haf;end
            if(k==8)end_valid=1;
            budget=0;
            while(!tri_done_valid)begin
                @(posedge clk);#1;budget=budget+1;
                if(tex_c_ready||end_ready||c_ready)$fatal(1,"primitive ownership");
                if(budget>16000)$fatal(1,"triangle budget");
            end
            if({tri_done_status,tri_done_visible,tri_done_covered}!==triangle_stats[k] || tri_done_tag!==8'(k+1))
                $fatal(1,"triangle stats k%0d got %h expected%h",k,{tri_done_status,tri_done_visible,tri_done_covered},triangle_stats[k]);
            held_done={tri_done_status,tri_done_visible,tri_done_covered,tri_done_tag,8'd0};
            repeat(3)begin @(posedge clk);
                if(!tri_done_valid || {tri_done_status,tri_done_visible,tri_done_covered,tri_done_tag,8'd0}!==held_done ||
                   tex_c_ready || end_ready || c_ready || dut.in_flight!=0)$fatal(1,"held primitive DONE");
            end
            @(negedge clk);tri_done_ready=1;@(posedge clk);@(negedge clk);tri_done_ready=0;
            if(k==2)begin
                @(posedge clk);while(!tex_c_ready)@(posedge clk);
                @(negedge clk);tex_c_valid=0;texture_response(3,16,256);
            end
        end
    endtask
    task end_frame;
        integer i,budget;
        reg [103:0] done_snapshot;
        begin
            // A real END offer has already been held throughout primitive8.
            @(posedge clk);while(!end_ready)@(posedge clk);
            @(negedge clk);end_valid=0;i=0;budget=0;
            while(i<192)begin
                m_ready=budget%7>1;@(posedge clk);
                if(m_valid&&m_ready)begin
                    if({m_depth,m_rgb}!==golden[i] || m_x!==8'(i%16) || m_y!==8'(i/16) ||
                       m_sof!==(i==0) || m_eol!==(i%16==15) || m_last!==(i==191) || m_tag!==8'he1)
                        $fatal(1,"frame %0d pixel%0d got%h expected%h",frames,i,{m_depth,m_rgb},golden[i]);
                    i=i+1;checked=checked+1;
                end
                #1;budget=budget+1;if(budget>3000)$fatal(1,"frame output budget");
                @(negedge clk);
            end
            m_ready=0;@(posedge clk);while(!done_valid)@(posedge clk);
            if({done_seen,done_passed,done_oob}!==stats[0] || done_count_overflow || done_tag!==8'he1)$fatal(1,"frame DONE stats");
            done_snapshot={done_tag,done_seen,done_passed,done_oob};
            repeat(3)begin @(posedge clk);if(!done_valid||{done_tag,done_seen,done_passed,done_oob}!==done_snapshot)$fatal(1,"held frame DONE");end
            @(negedge clk);done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;frames=frames+1;
        end
    endtask
    task scene;
        integer k;
        begin begin_frame();for(k=0;k<9;k=k+1)begin issue_triangle(k);finish_triangle(k);end end_frame();end
    endtask
    integer budget;
    initial begin
        $readmemh("texture.hex",texture);$readmemh("palette.hex",palette);$readmemh("triangles.hex",triangles);
        $readmemh("triangle_stats.hex",triangle_stats);$readmemh("frame.hex",golden);$readmemh("frame_stats.hex",stats);
        reset_here();load_texture();scene();
        begin_frame();issue_triangle(0);budget=0;
        while(dut.in_flight==0)begin @(posedge clk);#1;budget=budget+1;if(budget>300)$fatal(1,"missing sample reset target");end
        reset_here();load_texture();scene();
        if(frames!=2||commands!=19||checked!=384||resets!=2||stalls==0)$fatal(1,"frame coverage accounting");
        $display("PASS INDEXED_FRAME frames=2 triangles=19 checked=384 resets=2 stalls=%0d",stalls);$finish;
    end
endmodule
