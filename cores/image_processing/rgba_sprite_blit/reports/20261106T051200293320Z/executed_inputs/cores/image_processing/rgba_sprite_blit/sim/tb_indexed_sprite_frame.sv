// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_indexed_sprite_frame;
 reg clk=0,rst=1;always #5 clk=~clk;
 reg tex_c_valid=0,tex_r_ready=0,t_valid=0,p_valid=0;wire tex_c_ready,tex_r_valid,t_ready,p_ready,texture_resident;
 reg [1:0] tex_c_op=0;reg [7:0] tex_c_tag=0,t_index=0;reg [31:0] p_rgba=0;
 wire [1:0] tex_r_status;wire [7:0] tex_r_tag;wire [16:0] tex_r_tex_count;wire [8:0] tex_r_pal_count;
 reg begin_valid=0,c_valid=0,d_ready=0,end_valid=0,m_ready=0,done_ready=0;
 reg [23:0] begin_rgb=24'h102030;reg [7:0] begin_tag=8'he8;
 reg [7:0] c_u=0,c_v=0,c_tag=0;reg [8:0] c_width=0,c_height=0;
 reg signed [15:0] c_x=0,c_y=0;reg c_flip_x=0,c_flip_y=0;
 wire begin_ready,c_ready,d_valid,end_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_count_overflow;
 wire [1:0] d_status;wire [7:0] d_tag,m_x,m_y,m_tag,done_tag;wire [23:0] m_rgb;
 wire [16:0] d_requested,d_written,d_skipped;wire [31:0] done_seen,done_passed,done_oob;
 indexed_sprite_frame #(.WIDTH(16),.HEIGHT(12),.TEX_WIDTH(8),.TEX_HEIGHT(8),.TAG_W(8)) dut(.*);
 reg [7:0] texture[0:63];reg [31:0] palette[0:255];reg [75:0] command_data[0:16];
 reg [60:0] done_data[0:16];reg [23:0] golden[0:191];reg [31:0] counts[0:2];
 integer cycles=0,commands=0,done_checks=0,frames=0,checked=0,resets=0,holds=0;
 reg held=0;reg [50:0] snapshot;wire [50:0] frame_payload={m_rgb,m_x,m_y,m_tag,m_sof,m_eol,m_last};
 wire [60:0] blit_payload={d_tag,d_status,d_skipped,d_written,d_requested};
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>100000)$fatal(1,"finite example watchdog");
  if(rst)held=0;
  else begin
   if(held && (!m_valid || frame_payload!==snapshot))$fatal(1,"held frame changed");
   held=m_valid&&!m_ready;snapshot=frame_payload;if(held)holds=holds+1;
   if(dut.blit_busy && tex_c_ready)$fatal(1,"texture administration crossed blit owner");
   if(dut.sample_valid && (!dut.sample_visible || dut.sample_alpha==0) && dut.fragment_valid)$fatal(1,"transparent write");
   if(d_valid && (dut.sample_busy || !dut.store_ready || dut.blit.flight!=0 || dut.store.state!=2))$fatal(1,"blit completed before committed store state");
  end
 end
 task reset_here;
  begin
   @(negedge clk);rst=1;tex_c_valid=0;tex_r_ready=0;t_valid=0;p_valid=0;
   begin_valid=0;c_valid=0;d_ready=0;end_valid=0;m_ready=0;done_ready=0;
   #1;if(c_ready||d_valid||m_valid||done_valid||texture_resident)$fatal(1,"example reset masks");
   @(posedge clk);#1;@(negedge clk);rst=0;resets=resets+1;
  end
 endtask
 task texture_response(input integer status,input integer tc,input integer pc);
  reg [35:0] value;
  begin
   #1;if(!tex_r_valid || tex_r_status!==2'(status) || tex_r_tag!==tex_c_tag ||
      tex_r_tex_count!==17'(tc) || tex_r_pal_count!==9'(pc))$fatal(1,"texture response");
   value={tex_r_status,tex_r_tag,tex_r_tex_count,tex_r_pal_count};
   repeat(3)begin @(posedge clk);if(!tex_r_valid || {tex_r_status,tex_r_tag,tex_r_tex_count,tex_r_pal_count}!==value)$fatal(1,"held texture response");end
   @(negedge clk);tex_r_ready=1;@(posedge clk);@(negedge clk);tex_r_ready=0;
  end
 endtask
 task texture_command(input integer op,input integer status,input integer tc,input integer pc);
  begin
   @(negedge clk);tex_c_valid=1;tex_c_op=2'(op);tex_c_tag=8'ha8;
   @(posedge clk);while(!tex_c_ready)@(posedge clk);
   @(negedge clk);tex_c_valid=0;texture_response(status,tc,pc);
  end
 endtask
 task load_texture;
  integer ti,pi;
  begin
   texture_command(0,0,0,0);ti=0;pi=0;
   while(ti<64 || pi<256)begin
    @(negedge clk);t_valid=ti<64;p_valid=pi<256;
    if(ti<64)t_index=texture[ti];if(pi<256)p_rgba=palette[pi];
    @(posedge clk);if(t_valid&&t_ready)ti=ti+1;if(p_valid&&p_ready)pi=pi+1;
   end
   @(negedge clk);t_valid=0;p_valid=0;texture_command(1,0,64,256);
  end
 endtask
 task begin_frame;
  begin
   @(negedge clk);begin_valid=1;@(posedge clk);while(!begin_ready)@(posedge clk);
   @(negedge clk);begin_valid=0;begin_rgb=24'hbadbad;begin_tag=0;
  end
 endtask
 task offer(input integer k);
  begin
   @(negedge clk);{c_tag,c_flip_y,c_flip_x,c_y,c_x,c_height,c_width,c_v,c_u}=command_data[k];c_valid=1;
   @(posedge clk);while(!c_ready)@(posedge clk);commands=commands+1;
   @(negedge clk);c_valid=0;c_u=255;c_v=255;c_width=511;c_height=511;c_x=-32768;c_y=32767;
   c_tag=0;c_flip_x=~c_flip_x;c_flip_y=~c_flip_y;
  end
 endtask
 task finish_blit(input integer k);
  integer budget;reg [60:0] value;
  begin
   if(k==0)begin tex_c_valid=1;tex_c_op=2;tex_c_tag=8'hbc;end
   if(k==16)end_valid=1;
   budget=0;
   while(!d_valid)begin
    @(posedge clk);#1;budget=budget+1;
    if(tex_c_ready||end_ready||c_ready)$fatal(1,"blit owner not exclusive");
    if(budget>10000)$fatal(1,"example blit budget");
   end
   if(blit_payload!==done_data[k])$fatal(1,"example DONE k%0d got%h expected%h",k,blit_payload,done_data[k]);
   done_checks=done_checks+1;value=blit_payload;
   repeat(3)begin @(posedge clk);if(!d_valid || blit_payload!==value || tex_c_ready || end_ready || c_ready)$fatal(1,"held blit DONE");end
   @(negedge clk);d_ready=1;@(posedge clk);@(negedge clk);d_ready=0;
   if(k==0)begin
    @(posedge clk);while(!tex_c_ready)@(posedge clk);
    @(negedge clk);tex_c_valid=0;texture_response(3,64,256);
   end
  end
 endtask
 task end_frame;
  integer i,budget;reg [103:0] value;
  begin
   @(posedge clk);while(!end_ready)@(posedge clk);@(negedge clk);end_valid=0;i=0;budget=0;
   while(i<192)begin
    m_ready=budget%7>1;@(posedge clk);
    if(m_valid&&m_ready)begin
     if(m_rgb!==golden[i] || dut.store.m_depth!==16'hffff || m_x!==8'(i%16) || m_y!==8'(i/16) ||
        m_sof!==(i==0) || m_eol!==(i%16==15) || m_last!==(i==191) || m_tag!==8'he8)$fatal(1,"frame%0d pixel%0d got%h expected%h",frames,i,m_rgb,golden[i]);
     i=i+1;checked=checked+1;
    end
    #1;budget=budget+1;if(budget>3000)$fatal(1,"frame output budget");@(negedge clk);
   end
   m_ready=0;@(posedge clk);while(!done_valid)@(posedge clk);
   if(done_seen!==counts[1] || done_passed!==counts[1] || done_oob!=0 || done_count_overflow || done_tag!==8'he8)$fatal(1,"frame counters");
   value={done_tag,done_seen,done_passed,done_oob};
   repeat(3)begin @(posedge clk);if(!done_valid || {done_tag,done_seen,done_passed,done_oob}!==value)$fatal(1,"held frame DONE");end
   @(negedge clk);done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;frames=frames+1;
  end
 endtask
 task scene;
  integer k;
  begin
   begin_rgb=24'h102030;begin_tag=8'he8;begin_frame();
   for(k=0;k<17;k=k+1)begin offer(k);finish_blit(k);end
   end_frame();
  end
 endtask
 integer budget;
 initial begin
  $readmemh("texture.hex",texture);$readmemh("palette.hex",palette);$readmemh("commands.hex",command_data);
  $readmemh("done.hex",done_data);$readmemh("frame.hex",golden);$readmemh("counts.hex",counts);
  reset_here();load_texture();scene();
  begin_rgb=24'h102030;begin_tag=8'he8;begin_frame();offer(0);budget=0;
  while(dut.store.state!=5)begin @(posedge clk);#1;budget=budget+1;if(budget>300)$fatal(1,"missing live write reset phase");end
  reset_here();load_texture();scene();
  if(frames!=2 || commands!=35 || done_checks!=34 || checked!=384 || resets!=2 || holds==0)$fatal(1,"example coverage accounting");
  $display("PASS INDEXED_SPRITE frames=2 commands=35 done=34 checked=384 resets=2 holds=%0d",holds);$finish;
 end
endmodule
