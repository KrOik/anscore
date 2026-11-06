// SPDX-License-Identifier: Apache-2.0
// Actual local RAW equalizer -> unchanged resident row-window demosaic.
`timescale 1ns/1ps
module green_bayer_rgb #(parameter WIDTH=16,HEIGHT=12,BITS=10,TAG_W=8)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire c_enable,
 input wire [1:0] c_pattern,input wire [BITS-1:0] c_imbalance_threshold,c_edge_threshold,
 input wire [TAG_W-1:0] c_tag,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_last,
 output wire [3*BITS-1:0] m_rgb,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,
 output wire d_valid,input wire d_ready,output reg [2:0] d_error,
 output reg [TAG_W-1:0] d_tag,output reg [16:0] d_applied,d_changed,
 output wire busy
);
 localparam N=WIDTH*HEIGHT;
 localparam IDLE=0,ACTIVE=1,DONE=2;
 reg [1:0] state;
 reg green_done,rgb_done;
 reg [16:0] rgb_count;
 wire gc_ready,gd_valid,gd_ready,gm_valid,gm_ready,gm_sof,gm_eol,gm_last;
 wire [BITS-1:0] gm_data;
 wire [1:0] gd_error;
 wire [TAG_W-1:0] gd_tag;
 wire [16:0] gd_applied,gd_changed;
 wire br_cfg_ready,br_cfg_done,br_cfg_error,br_error,br_busy,br_valid,br_sof,br_eol;
 wire [3*BITS-1:0] br_data;
 // Canonical pattern0 RGGB/1 GRBG/2 GBRG/3 BGGR -> older Bayer ABI.
 wire [1:0] bayer_pattern=(c_pattern==0)?2'd0:(c_pattern==1)?2'd2:
  (c_pattern==2)?2'd3:2'd1;
 assign c_ready=!rst&&(state==IDLE)&&gc_ready&&br_cfg_ready;
 wire start=c_valid&&c_ready;
 assign busy=!rst&&(state!=IDLE);
 assign d_valid=!rst&&(state==DONE);
 assign gd_ready=!rst&&(state==ACTIVE)&&!green_done;
 assign m_rgb=br_data;assign m_valid=!rst&&(state==ACTIVE)&&br_valid;
 assign m_sof=br_sof;assign m_eol=br_eol;assign m_last=rgb_count==N-1;
 wire last_rgb=m_valid&&m_ready&&m_last;
 wire green_finish=gd_valid&&gd_ready;
 raw_green_equalize #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS),.TAG_W(TAG_W)) equalizer(
  .clk(clk),.rst(rst),.c_valid(start),.c_ready(gc_ready),.c_enable(c_enable),.c_pattern(c_pattern),
  .c_imbalance_threshold(c_imbalance_threshold),.c_edge_threshold(c_edge_threshold),.c_tag(c_tag),
  .s_data(s_data),.s_valid(s_valid&&(state==ACTIVE)),.s_ready(s_ready),
  .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
  .m_data(gm_data),.m_valid(gm_valid),.m_ready(gm_ready),
  .m_sof(gm_sof),.m_eol(gm_eol),.m_last(gm_last),.m_applied(),.m_changed(),
  .d_valid(gd_valid),.d_ready(gd_ready),.d_error(gd_error),.d_tag(gd_tag),
  .d_applied(gd_applied),.d_changed(gd_changed),.busy());
 bayer_demosaic #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) demosaic(
  .clk(clk),.rst_n(!rst),.s_tdata(gm_data),.s_tvalid(gm_valid),.s_tready(gm_ready),
  .s_tuser(gm_sof),.s_tlast(gm_eol),.m_tdata(br_data),.m_tvalid(br_valid),
  .m_tready(m_ready&&(state==ACTIVE)&&!rst),.m_tuser(br_sof),.m_tlast(br_eol),
  .cfg_valid(start),.cfg_ready(br_cfg_ready),.cfg_cfa(bayer_pattern),
  .cfg_ox(1'b0),.cfg_oy(1'b0),.cfg_reserved(4'd0),
  .cfg_done(br_cfg_done),.cfg_error(br_cfg_error),.marker_error(br_error),.busy(br_busy));
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;green_done<=0;rgb_done<=0;rgb_count<=0;
   d_error<=0;d_tag<=0;d_applied<=0;d_changed<=0;
  end else case(state)
   IDLE:if(start)begin
    state<=ACTIVE;green_done<=0;rgb_done<=0;rgb_count<=0;
    d_error<=0;d_tag<=c_tag;d_applied<=0;d_changed<=0;
   end
   ACTIVE:begin
    if(br_error||br_cfg_error)d_error[2]<=1;
    if(green_finish)begin
     green_done<=1;d_error[1:0]<=gd_error;d_applied<=gd_applied;d_changed<=gd_changed;
    end
    if(m_valid&&m_ready)begin
     rgb_count<=rgb_count+1'b1;
     if(m_last)rgb_done<=1;
    end
    // Equalizer DONE alone only proves all RAW was admitted by demosaic.
    // Public completion additionally owns its last held RGB output.
    if((green_done||green_finish)&&(rgb_done||last_rgb))state<=DONE;
   end
   DONE:if(d_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
 initial if(BITS!=8&&BITS!=10)$fatal(1,"green_bayer_rgb supports RAW8/10 only");
endmodule
