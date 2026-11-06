// SPDX-License-Identifier: Apache-2.0
// Original rectangle clip/flip controller; no pixel RAM or duplicate blender.
`default_nettype none
module rgba_sprite_blit #(
 parameter integer WIDTH=64,HEIGHT=64,TEX_WIDTH=16,TEX_HEIGHT=16,TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [7:0] c_u,c_v,
 input wire [8:0] c_width,c_height,input wire signed [15:0] c_x,c_y,
 input wire c_flip_x,c_flip_y,input wire [TAG_W-1:0] c_tag,
 output wire q_valid,input wire q_ready,output wire [7:0] q_u,q_v,
 output wire [15:0] q_x,q_y,output wire [TAG_W-1:0] q_tag,
 input wire s_valid,output wire s_ready,input wire [23:0] s_rgb,
 input wire [7:0] s_alpha,input wire s_visible,input wire [15:0] s_x,s_y,
 output wire m_valid,input wire m_ready,output wire [23:0] m_rgb,
 output wire [7:0] m_alpha,output wire [15:0] m_x,m_y,
 input wire writes_idle,
 output wire d_valid,input wire d_ready,output reg [1:0] d_status,
 output reg [TAG_W-1:0] d_tag,
 output reg [16:0] d_requested,d_written,d_skipped,output wire busy
);
 localparam [2:0] IDLE=0,SETUP=1,SCAN=2,DRAIN=3,DONE=4;
 reg [2:0] state;
 reg [7:0] src_u,src_v,u_first,u_now,v_now,x_first,x_last,y_last,x_now,y_now;
 reg [8:0] width,height;
 reg signed [15:0] dst_x,dst_y;
 reg flip_x,flip_y;
 reg [1:0] flight;
 wire signed [17:0] dx={{2{dst_x[15]}},dst_x},dy={{2{dst_y[15]}},dst_y};
 wire signed [17:0] right=dx+$signed({9'd0,width}),bottom=dy+$signed({9'd0,height});
 wire signed [17:0] left_clip=dx>0?dx:18'sd0,top_clip=dy>0?dy:18'sd0;
 wire signed [17:0] right_clip=right<WIDTH?right:18'(WIDTH);
 wire signed [17:0] bottom_clip=bottom<HEIGHT?bottom:18'(HEIGHT);
 wire [9:0] source_right={2'd0,src_u}+{1'd0,width};
 wire [9:0] source_bottom={2'd0,src_v}+{1'd0,height};
 wire [8:0] column_offset=9'(left_clip-dx),row_offset=9'(top_clip-dy);
 wire [9:0] first_u={2'd0,src_u}+(flip_x?({1'd0,width}-10'd1-{1'd0,column_offset}):{1'd0,column_offset});
 wire [9:0] first_v={2'd0,src_v}+(flip_y?({1'd0,height}-10'd1-{1'd0,row_offset}):{1'd0,row_offset});
 wire response_owned=(state==SCAN || state==DRAIN) && flight!=0;
 wire visible=s_visible && s_alpha!=0;
 assign s_ready=!rst && response_owned && (!visible || m_ready);
 wire retired=s_valid && s_ready;
 assign q_valid=!rst && state==SCAN && (flight<3 || retired);
 wire issued=q_valid && q_ready;
 assign q_u=u_now;assign q_v=v_now;assign q_x={8'd0,x_now};assign q_y={8'd0,y_now};assign q_tag=d_tag;
 assign m_valid=!rst && response_owned && s_valid && visible;
 assign m_rgb=s_rgb;assign m_alpha=s_alpha;assign m_x=s_x;assign m_y=s_y;
 assign c_ready=!rst && state==IDLE;
 assign d_valid=!rst && state==DONE;
 assign busy=!rst && state!=IDLE;
 generate if(WIDTH<1 || WIDTH>128 || HEIGHT<1 || HEIGHT>128 || TEX_WIDTH<1 || TEX_WIDTH>256 ||
             TEX_HEIGHT<1 || TEX_HEIGHT>256 || TAG_W<1 || TAG_W>32)begin:invalid
  rgba_sprite_blit_invalid_parameters__see_README invalid_parameters();
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;src_u<=0;src_v<=0;width<=0;height<=0;dst_x<=0;dst_y<=0;flip_x<=0;flip_y<=0;
   u_first<=0;u_now<=0;v_now<=0;x_first<=0;x_last<=0;y_last<=0;x_now<=0;y_now<=0;flight<=0;
   d_status<=0;d_tag<=0;d_requested<=0;d_written<=0;d_skipped<=0;
  end else begin
   case({issued,retired})
    2'b10:flight<=flight+1'b1;
    2'b01:flight<=flight-1'b1;
    default:begin end
   endcase
   if(issued)d_requested<=d_requested+1'b1;
   if(retired)begin
    if(visible)d_written<=d_written+1'b1;else d_skipped<=d_skipped+1'b1;
   end
   case(state)
    IDLE:if(c_valid)begin
     src_u<=c_u;src_v<=c_v;width<=c_width;height<=c_height;dst_x<=c_x;dst_y<=c_y;
     flip_x<=c_flip_x;flip_y<=c_flip_y;d_tag<=c_tag;
     d_status<=0;d_requested<=0;d_written<=0;d_skipped<=0;state<=SETUP;
    end
    SETUP:begin
     // Zero extent is a successful no-op, even when the unused origin is outside.
     if(width==0 || height==0)state<=DONE;
     else if(width>256 || height>256 || source_right>TEX_WIDTH || source_bottom>TEX_HEIGHT)begin
      d_status<=1;state<=DONE;
     end else if(left_clip>=right_clip || top_clip>=bottom_clip)begin d_status<=2;state<=DONE;end
     else begin
      u_first<=first_u[7:0];u_now<=first_u[7:0];v_now<=first_v[7:0];
      x_first<=left_clip[7:0];x_now<=left_clip[7:0];y_now<=top_clip[7:0];
      x_last<=8'(right_clip-1);y_last<=8'(bottom_clip-1);state<=SCAN;
     end
    end
    SCAN:if(issued)begin
     if(x_now==x_last)begin
      if(y_now==y_last)state<=DRAIN;
      else begin x_now<=x_first;y_now<=y_now+1'b1;u_now<=u_first;v_now<=flip_y?v_now-1'b1:v_now+1'b1;end
     end else begin x_now<=x_now+1'b1;u_now<=flip_x?u_now-1'b1:u_now+1'b1;end
    end
    DRAIN:if(flight==0 && writes_idle)state<=DONE;
    DONE:if(d_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
