// Shared four-mode streaming processing bank for the frame-store application.
module img_mf_processing_bank #(parameter TAG_WIDTH=16,FRAME_WIDTH=16)(
 input wire clk,rst_n,clk_en, input wire [1:0] mode, input wire cfg_pulse,
 input wire [8:0] cfg_weight, input wire cfg_key_enable, input wire [23:0] cfg_key,
 input wire [7:0] cfg_threshold, input wire [3:0] cfg_bg_shift, input wire cfg_bg_freeze,
 input wire s_valid, output wire s_ready, input wire [23:0] s_data,aux_data,
 input wire s_sof,s_eol, input wire [TAG_WIDTH-1:0] s_tag,
 input wire [FRAME_WIDTH-1:0] s_frameid,
 output wire m_valid,input wire m_ready,output wire [23:0] m_data,
 output wire m_foreground,m_sof,m_eol,output wire [TAG_WIDTH-1:0] m_tag,
 output wire [FRAME_WIDTH-1:0] m_frameid,output wire [7:0] m_error,
 output wire wb_valid,input wire wb_ready,output wire [15:0] wb_data,
 output wire wb_enable,output wire [TAG_WIDTH-1:0] wb_tag,output wire [7:0] wb_error
);
 wire [3:0] sv,av,mv,cr,cp,ce;
 wire [23:0] md [0:3]; wire [7:0] me [0:3];
 wire [3:0] ms,ml,mf;
 wire [TAG_WIDTH-1:0] mt [0:3]; wire [FRAME_WIDTH-1:0] mi [0:3];
 wire [7:0] diff_gray,bg_gray,bg_difference;
 wire [7:0] sticky [0:3];
 assign s_ready=sv[mode] && av[mode];
 assign m_valid=mv[mode]; assign m_data=md[mode]; assign m_error=me[mode];
 assign m_sof=ms[mode]; assign m_eol=ml[mode]; assign m_tag=mt[mode]; assign m_frameid=mi[mode];
 assign m_foreground=mf[mode];
 assign md[1]={3{diff_gray}}; assign md[2]={3{bg_gray}};
 assign mf[0]=1'b0; assign mf[3]=1'b0;
 img_mf_osd_overlay #(.TAG_WIDTH(TAG_WIDTH),.FRAME_WIDTH(FRAME_WIDTH)) mode_0 (
  .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
  .s_valid(s_valid && mode==2'd0),.s_ready(sv[0]),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
  .aux_valid(s_valid && mode==2'd0),.aux_ready(av[0]),.aux_data(aux_data),.aux_sof(s_sof),.aux_eol(s_eol),.aux_tag(s_tag),.aux_frameid(s_frameid),
  .cfg_we(cfg_pulse && mode==2'd0),.cfg_commit(cfg_pulse && mode==2'd0),.cfg_ready(cr[0]),.cfg_pending(cp[0]),
  .cfg_enable(1'b1),.cfg_alpha(cfg_weight),.cfg_key_enable(cfg_key_enable),.cfg_color_key(cfg_key),.cfg_error(ce[0]),
  .m_valid(mv[0]),.m_ready(m_ready && mode==2'd0),.m_data(md[0]),.m_sof(ms[0]),.m_eol(ml[0]),.m_tag(mt[0]),.m_frameid(mi[0]),.m_error(me[0]),.error_code(sticky[0])
 );
 img_mf_frame_absdiff #(.TAG_WIDTH(TAG_WIDTH),.FRAME_WIDTH(FRAME_WIDTH)) mode_1 (
  .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
  .s_valid(s_valid && mode==2'd1),.s_ready(sv[1]),.s_data(s_data[7:0]),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
  .aux_valid(s_valid && mode==2'd1),.aux_ready(av[1]),.aux_data(aux_data[7:0]),.aux_sof(s_sof),.aux_eol(s_eol),.aux_tag(s_tag),.aux_frameid(s_frameid),
  .cfg_we(cfg_pulse && mode==2'd1),.cfg_commit(cfg_pulse && mode==2'd1),.cfg_ready(cr[1]),.cfg_pending(cp[1]),
  .cfg_threshold(cfg_threshold),.m_foreground(mf[1]),
  .m_valid(mv[1]),.m_ready(m_ready && mode==2'd1),.m_data(diff_gray),.m_sof(ms[1]),.m_eol(ml[1]),.m_tag(mt[1]),.m_frameid(mi[1]),.m_error(me[1]),.error_code(sticky[1])
 );
 img_mf_background_ewma #(.TAG_WIDTH(TAG_WIDTH),.FRAME_WIDTH(FRAME_WIDTH)) mode_2 (
  .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
  .s_valid(s_valid && mode==2'd2),.s_ready(sv[2]),.s_data(s_data[7:0]),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
  .aux_valid(s_valid && mode==2'd2),.aux_ready(av[2]),.aux_data(aux_data[15:0]),.aux_sof(s_sof),.aux_eol(s_eol),.aux_tag(s_tag),.aux_frameid(s_frameid),
  .cfg_we(cfg_pulse && mode==2'd2),.cfg_commit(cfg_pulse && mode==2'd2),.cfg_ready(cr[2]),.cfg_pending(cp[2]),
  .cfg_update_shift(cfg_bg_shift),.cfg_threshold(cfg_threshold),.cfg_freeze_foreground(cfg_bg_freeze),.cfg_error(ce[2]),.aux_initialized(1'b1),.m_difference(bg_difference),.m_foreground(mf[2]),.wb_valid(wb_valid),.wb_ready(wb_ready),.wb_data(wb_data),.wb_enable(wb_enable),.wb_tag(wb_tag),.wb_error(wb_error),.wb_sof(),.wb_eol(),.wb_frameid(),
  .m_valid(mv[2]),.m_ready(m_ready && mode==2'd2),.m_data(bg_gray),.m_sof(ms[2]),.m_eol(ml[2]),.m_tag(mt[2]),.m_frameid(mi[2]),.m_error(me[2]),.error_code(sticky[2])
 );
 img_mf_weighted_fusion #(.TAG_WIDTH(TAG_WIDTH),.FRAME_WIDTH(FRAME_WIDTH)) mode_3 (
  .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
  .s_valid(s_valid && mode==2'd3),.s_ready(sv[3]),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
  .aux_valid(s_valid && mode==2'd3),.aux_ready(av[3]),.aux_data(aux_data),.aux_sof(s_sof),.aux_eol(s_eol),.aux_tag(s_tag),.aux_frameid(s_frameid),
  .cfg_we(cfg_pulse && mode==2'd3),.cfg_commit(cfg_pulse && mode==2'd3),.cfg_ready(cr[3]),.cfg_pending(cp[3]),
  .cfg_aux_weight(cfg_weight),.cfg_error(ce[3]),
  .m_valid(mv[3]),.m_ready(m_ready && mode==2'd3),.m_data(md[3]),.m_sof(ms[3]),.m_eol(ml[3]),.m_tag(mt[3]),.m_frameid(mi[3]),.m_error(me[3]),.error_code(sticky[3])
 );
endmodule
