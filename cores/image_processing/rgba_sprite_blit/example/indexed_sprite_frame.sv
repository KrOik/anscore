// SPDX-License-Identifier: Apache-2.0
// Actual unchanged indexed texture -> rectangle blit -> RGB/depth store chain.
`default_nettype none
module indexed_sprite_frame #(
 parameter integer WIDTH=64,HEIGHT=64,TEX_WIDTH=16,TEX_HEIGHT=16,TAG_W=8
)(
 input wire clk,rst,
 input wire tex_c_valid,output wire tex_c_ready,input wire [1:0] tex_c_op,input wire [TAG_W-1:0] tex_c_tag,
 output wire tex_r_valid,input wire tex_r_ready,output wire [1:0] tex_r_status,
 output wire [TAG_W-1:0] tex_r_tag,output wire [16:0] tex_r_tex_count,output wire [8:0] tex_r_pal_count,
 input wire t_valid,output wire t_ready,input wire [7:0] t_index,
 input wire p_valid,output wire p_ready,input wire [31:0] p_rgba,output wire texture_resident,
 input wire begin_valid,output wire begin_ready,input wire [23:0] begin_rgb,input wire [TAG_W-1:0] begin_tag,
 input wire c_valid,output wire c_ready,input wire [7:0] c_u,c_v,input wire [8:0] c_width,c_height,
 input wire signed [15:0] c_x,c_y,input wire c_flip_x,c_flip_y,input wire [TAG_W-1:0] c_tag,
 output wire d_valid,input wire d_ready,output wire [1:0] d_status,output wire [TAG_W-1:0] d_tag,
 output wire [16:0] d_requested,d_written,d_skipped,
 input wire end_valid,output wire end_ready,
 output wire m_valid,input wire m_ready,output wire [23:0] m_rgb,
 output wire [7:0] m_x,m_y,output wire m_sof,m_eol,m_last,output wire [TAG_W-1:0] m_tag,
 output wire done_valid,input wire done_ready,output wire [TAG_W-1:0] done_tag,
 output wire [31:0] done_seen,done_passed,done_oob,output wire done_count_overflow
);
 reg frame_live;
 wire blit_busy,sample_busy,blit_ready,sampler_c_ready,store_ready,store_end_ready;
 wire q_valid,q_ready,sample_valid,sample_ready,sample_visible;
 wire [7:0] q_u,q_v,sample_alpha;wire [15:0] q_x,q_y,sample_x,sample_y;
 wire [TAG_W-1:0] q_tag,sample_tag;wire [23:0] sample_rgb;
 wire fragment_valid;wire [23:0] fragment_rgb;wire [7:0] fragment_alpha;wire [15:0] fragment_x,fragment_y;
 wire store_m_valid,store_done_valid;
 wire admit=frame_live && texture_resident && !end_valid && !tex_c_valid && !tex_r_valid &&
            store_ready && !sample_busy;
 assign c_ready=!rst && admit && blit_ready;
 assign tex_c_ready=sampler_c_ready && !blit_busy;
 assign end_ready=store_end_ready && !blit_busy && !sample_busy;
 assign m_valid=!rst && store_m_valid;
 assign done_valid=!rst && store_done_valid;
 always @(posedge clk)begin
  if(rst)frame_live<=0;
  else begin
   if(begin_valid && begin_ready)frame_live<=1;
   if(done_valid && done_ready)frame_live<=0;
  end
 end
 rgba_sprite_blit #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TEX_WIDTH(TEX_WIDTH),.TEX_HEIGHT(TEX_HEIGHT),.TAG_W(TAG_W)) blit(
  .clk(clk),.rst(rst),.c_valid(c_valid && admit),.c_ready(blit_ready),
  .c_u(c_u),.c_v(c_v),.c_width(c_width),.c_height(c_height),.c_x(c_x),.c_y(c_y),
  .c_flip_x(c_flip_x),.c_flip_y(c_flip_y),.c_tag(c_tag),
  .q_valid(q_valid),.q_ready(q_ready),.q_u(q_u),.q_v(q_v),.q_x(q_x),.q_y(q_y),.q_tag(q_tag),
  .s_valid(sample_valid),.s_ready(sample_ready),.s_rgb(sample_rgb),.s_alpha(sample_alpha),
  .s_visible(sample_visible),.s_x(sample_x),.s_y(sample_y),
  .m_valid(fragment_valid),.m_ready(store_ready),.m_rgb(fragment_rgb),.m_alpha(fragment_alpha),
  .m_x(fragment_x),.m_y(fragment_y),.writes_idle(store_ready),
  .d_valid(d_valid),.d_ready(d_ready),.d_status(d_status),.d_tag(d_tag),
  .d_requested(d_requested),.d_written(d_written),.d_skipped(d_skipped),.busy(blit_busy));
 indexed_texture_sampler #(.TEX_WIDTH(TEX_WIDTH),.TEX_HEIGHT(TEX_HEIGHT),.TAG_W(TAG_W)) sampler(
  .clk(clk),.rst(rst),.c_valid(tex_c_valid && !blit_busy),.c_ready(sampler_c_ready),.c_op(tex_c_op),.c_tag(tex_c_tag),
  .r_valid(tex_r_valid),.r_ready(tex_r_ready),.r_status(tex_r_status),.r_tag(tex_r_tag),
  .r_tex_count(tex_r_tex_count),.r_pal_count(tex_r_pal_count),
  .t_valid(t_valid),.t_ready(t_ready),.t_index(t_index),.p_valid(p_valid),.p_ready(p_ready),.p_rgba(p_rgba),
  .s_valid(q_valid),.s_ready(q_ready),.s_u(q_u),.s_v(q_v),.s_x(q_x),.s_y(q_y),.s_tag(q_tag),
  .m_valid(sample_valid),.m_ready(sample_ready),.m_rgb(sample_rgb),.m_alpha(sample_alpha),
  .m_visible(sample_visible),.m_reason(),.m_x(sample_x),.m_y(sample_y),.m_tag(sample_tag),
  .resident(texture_resident),.pipeline_busy(sample_busy));
 fragment_rgb_depth_store #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) store(
  .clk(clk),.rst(rst),.begin_valid(begin_valid),.begin_ready(begin_ready),.begin_rgb(begin_rgb),
  .begin_depth(16'hffff),.begin_tag(begin_tag),
  .s_valid(fragment_valid),.s_ready(store_ready),.s_x(fragment_x),.s_y(fragment_y),
  .s_depth(16'd0),.s_rgb(fragment_rgb),.s_alpha(fragment_alpha),.s_depth_func(2'd0),
  .s_depth_write(1'b0),.s_color_write(3'b111),
  .end_valid(end_valid && !blit_busy && !sample_busy),.end_ready(store_end_ready),
  .m_valid(store_m_valid),.m_ready(m_ready),.m_rgb(m_rgb),.m_depth(),.m_x(m_x),.m_y(m_y),
  .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_tag(m_tag),
  .done_valid(store_done_valid),.done_ready(done_ready),.done_tag(done_tag),
  .done_seen(done_seen),.done_passed(done_passed),.done_oob(done_oob),.done_count_overflow(done_count_overflow));
endmodule
`default_nettype wire
