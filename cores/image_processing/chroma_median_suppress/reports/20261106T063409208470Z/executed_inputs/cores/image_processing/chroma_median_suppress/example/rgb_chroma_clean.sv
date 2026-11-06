// SPDX-License-Identifier: Apache-2.0
// Real RGB -> unchanged BT.601 full-range CSC -> chroma core -> inverse CSC.
`timescale 1ns/1ps
module rgb_chroma_clean #(parameter WIDTH=16,HEIGHT=12,BITS=8,TAG_W=8)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire c_enable,
 input wire [BITS-1:0] c_luma_threshold,input wire [TAG_W-1:0] c_tag,
 input wire [3*BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_last,
 output wire [3*BITS-1:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,
 output wire d_valid,input wire d_ready,output reg [2:0] d_error,
 output reg [TAG_W-1:0] d_tag,output reg [16:0] d_applied,d_changed,output wire busy
);
 localparam N=WIDTH*HEIGHT,IDLE=0,ACTIVE=1,DONE=2;
 localparam XW=(WIDTH<2)?1:$clog2(WIDTH);
 reg [1:0] state;
 reg [16:0] in_count,rgb_count;
 reg [XW-1:0] ix;
 reg core_done,rgb_done,bad_input;
 wire front_ready,front_valid,front_sof,front_eol,front_cfg_ready,front_cfg_error;
 wire back_valid,back_sof,back_eol,back_cfg_ready,back_cfg_error;
 wire [3*BITS-1:0] yuv,filtered,rgb;
 wire filter_ready,filter_valid,filter_sof,filter_eol,filter_last,back_ready;
 wire core_c_ready,core_d_valid,core_d_ready;
 wire [1:0] core_error;
 wire [TAG_W-1:0] core_tag;
 wire [16:0] core_applied,core_changed;
 assign c_ready=!rst&&state==IDLE&&core_c_ready&&front_cfg_ready&&back_cfg_ready;
 wire start=c_valid&&c_ready;
 assign s_ready=!rst&&state==ACTIVE&&in_count<N&&front_ready;
 assign m_data=rgb;assign m_valid=!rst&&state==ACTIVE&&back_valid;
 assign m_sof=back_sof;assign m_eol=back_eol;assign m_last=rgb_count==N-1;
 assign busy=!rst&&state!=IDLE;assign d_valid=!rst&&state==DONE;
 assign core_d_ready=!rst&&state==ACTIVE&&!core_done;
 wire finish_core=core_d_valid&&core_d_ready;
 wire finish_rgb=m_valid&&m_ready&&m_last;
 csc_stream #(.BITS(BITS)) front(
  .clk(clk),.rst_n(!rst),.s_tdata(s_data),.s_tvalid(s_valid&&state==ACTIVE&&in_count<N&&!rst),
  .s_tready(front_ready),.s_tuser(in_count==0),.s_tlast(ix==WIDTH-1),
  .m_tdata(yuv),.m_tvalid(front_valid),.m_tready(filter_ready&&state==ACTIVE&&!rst),
  .m_tuser(front_sof),.m_tlast(front_eol),.cfg_valid(start),.cfg_ready(front_cfg_ready),
  .cfg_mode(2'd0),.cfg_standard(1'b0),.cfg_limited(1'b0),.cfg_error(front_cfg_error));
 reg [16:0] filter_inputs;
 chroma_median_suppress #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS),.TAG_W(TAG_W)) suppressor(
  .clk(clk),.rst(rst),.c_valid(start),.c_ready(core_c_ready),.c_enable(c_enable),
  .c_luma_threshold(c_luma_threshold),.c_tag(c_tag),
  .s_data(yuv),.s_valid(front_valid&&state==ACTIVE&&!rst),.s_ready(filter_ready),
  .s_sof(front_sof),.s_eol(front_eol),.s_last(filter_inputs==N-1),
  .m_data(filtered),.m_valid(filter_valid),.m_ready(back_ready&&state==ACTIVE&&!rst),
  .m_sof(filter_sof),.m_eol(filter_eol),.m_last(filter_last),.m_applied(),.m_changed(),
  .d_valid(core_d_valid),.d_ready(core_d_ready),.d_error(core_error),.d_tag(core_tag),
  .d_applied(core_applied),.d_changed(core_changed),.busy());
 csc_stream #(.BITS(BITS)) back(
  .clk(clk),.rst_n(!rst),.s_tdata(filtered),.s_tvalid(filter_valid&&state==ACTIVE&&!rst),
  .s_tready(back_ready),.s_tuser(filter_sof),.s_tlast(filter_eol),
  .m_tdata(rgb),.m_tvalid(back_valid),.m_tready(m_ready&&state==ACTIVE&&!rst),
  .m_tuser(back_sof),.m_tlast(back_eol),.cfg_valid(start),.cfg_ready(back_cfg_ready),
  .cfg_mode(2'd1),.cfg_standard(1'b0),.cfg_limited(1'b0),.cfg_error(back_cfg_error));
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;in_count<=0;rgb_count<=0;filter_inputs<=0;ix<=0;
   core_done<=0;rgb_done<=0;bad_input<=0;d_error<=0;d_tag<=0;d_applied<=0;d_changed<=0;
  end else case(state)
   IDLE:if(start)begin
    state<=ACTIVE;in_count<=0;rgb_count<=0;filter_inputs<=0;ix<=0;
    core_done<=0;rgb_done<=0;bad_input<=0;d_error<=0;d_tag<=c_tag;d_applied<=0;d_changed<=0;
   end
   ACTIVE:begin
    if(s_valid&&s_ready)begin
     in_count<=in_count+1'b1;ix<=(ix==WIDTH-1)?{XW{1'b0}}:ix+1'b1;
     if(s_sof!=(in_count==0)||s_eol!=(ix==WIDTH-1)||s_last!=(in_count==N-1))bad_input<=1;
    end
    if(front_valid&&filter_ready)filter_inputs<=filter_inputs+1'b1;
    if(front_cfg_error||back_cfg_error)d_error[2]<=1;
    if(finish_core)begin
     core_done<=1;d_error[1:0]<=core_error|{1'b0,bad_input};
     d_applied<=core_applied;d_changed<=core_changed;
    end
    if(m_valid&&m_ready)begin rgb_count<=rgb_count+1'b1;if(m_last)rgb_done<=1;end
    if((core_done||finish_core)&&(rgb_done||finish_rgb))state<=DONE;
   end
   DONE:if(d_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
 initial if((BITS!=8&&BITS!=10)||WIDTH<1||WIDTH>512||HEIGHT<1||HEIGHT>512||N>65536||TAG_W<1||TAG_W>32)
  $fatal(1,"rgb_chroma_clean parameters");
endmodule
