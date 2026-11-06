// SPDX-License-Identifier: Apache-2.0
// Actual adaptive RAW repair -> unchanged resident bilinear Bayer engine.
`timescale 1ns/1ps
module directional_bayer_rgb #(parameter WIDTH=16,HEIGHT=12,BITS=10,TAG_W=8)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire c_enable,
 input wire [BITS-1:0] c_base_threshold,input wire [1:0] c_gradient_shift,c_pattern,
 input wire [TAG_W-1:0] c_tag,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_last,
 output wire [3*BITS-1:0] m_rgb,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,
 output wire d_valid,input wire d_ready,output reg [2:0] d_error,
 output reg [TAG_W-1:0] d_tag,output reg [16:0] d_repaired,output wire busy
);
 localparam N=WIDTH*HEIGHT;
 localparam IDLE=0,ACTIVE=1,DONE=2;
 reg [1:0] state;
 reg raw_done,rgb_done;
 reg [16:0] rgb_count;
 wire rc_ready,rd_valid,rd_ready,rm_valid,rm_ready,rm_sof,rm_eol,rm_last;
 wire [BITS-1:0] rm_data;
 wire [1:0] rd_error;
 wire [TAG_W-1:0] rd_tag;
 wire [16:0] rd_repaired;
 wire br_cfg_ready,br_cfg_done,br_cfg_error,br_error,br_busy,br_valid,br_sof,br_eol;
 wire [3*BITS-1:0] br_data;
 // Public 0 RGGB / 1 GRBG / 2 GBRG / 3 BGGR -> unchanged legacy ABI.
 wire [1:0] bayer_pattern=(c_pattern==0)?2'd0:(c_pattern==1)?2'd2:
  (c_pattern==2)?2'd3:2'd1;
 assign c_ready=!rst&&(state==IDLE)&&rc_ready&&br_cfg_ready;
 wire start=c_valid&&c_ready;
 assign busy=!rst&&(state!=IDLE);
 assign d_valid=!rst&&(state==DONE);
 assign rd_ready=!rst&&(state==ACTIVE)&&!raw_done;
 assign m_rgb=br_data;assign m_valid=!rst&&(state==ACTIVE)&&br_valid;
 assign m_sof=br_sof;assign m_eol=br_eol;assign m_last=rgb_count==N-1;
 wire last_rgb=m_valid&&m_ready&&m_last;
 wire raw_finish=rd_valid&&rd_ready;
 raw_directional_defect_repair #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS),.TAG_W(TAG_W)) repair_i(
  .clk(clk),.rst(rst),.c_valid(start),.c_ready(rc_ready),.c_enable(c_enable),
  .c_base_threshold(c_base_threshold),.c_gradient_shift(c_gradient_shift),.c_tag(c_tag),
  .s_data(s_data),.s_valid(s_valid&&(state==ACTIVE)),.s_ready(s_ready),
  .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
  .m_data(rm_data),.m_valid(rm_valid),.m_ready(rm_ready),
  .m_sof(rm_sof),.m_eol(rm_eol),.m_last(rm_last),.m_repaired(),.m_direction(),
  .d_valid(rd_valid),.d_ready(rd_ready),.d_error(rd_error),.d_tag(rd_tag),
  .d_repaired(rd_repaired),.busy());
 bayer_demosaic #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) demosaic_i(
  .clk(clk),.rst_n(!rst),.s_tdata(rm_data),.s_tvalid(rm_valid),.s_tready(rm_ready),
  .s_tuser(rm_sof),.s_tlast(rm_eol),.m_tdata(br_data),.m_tvalid(br_valid),
  .m_tready(m_ready&&(state==ACTIVE)&&!rst),.m_tuser(br_sof),.m_tlast(br_eol),
  .cfg_valid(start),.cfg_ready(br_cfg_ready),.cfg_cfa(bayer_pattern),
  .cfg_ox(1'b0),.cfg_oy(1'b0),.cfg_reserved(4'd0),
  .cfg_done(br_cfg_done),.cfg_error(br_cfg_error),.marker_error(br_error),.busy(br_busy));
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;raw_done<=0;rgb_done<=0;rgb_count<=0;
   d_error<=0;d_tag<=0;d_repaired<=0;
  end else case(state)
   IDLE:if(start)begin
    state<=ACTIVE;raw_done<=0;rgb_done<=0;rgb_count<=0;
    d_error<=0;d_tag<=c_tag;d_repaired<=0;
   end
   ACTIVE:begin
    if(br_error||br_cfg_error)d_error[2]<=1;
    if(raw_finish)begin raw_done<=1;d_error[1:0]<=rd_error;d_repaired<=rd_repaired;end
    if(m_valid&&m_ready)begin rgb_count<=rgb_count+1'b1;if(m_last)rgb_done<=1;end
    // RAW retirement does not retire the demosaic's buffered RGB pixels.
    if((raw_done||raw_finish)&&(rgb_done||last_rgb))state<=DONE;
   end
   DONE:if(d_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
 initial if(BITS!=8&&BITS!=10)$fatal(1,"directional_bayer_rgb supports RAW8/10 only");
endmodule
