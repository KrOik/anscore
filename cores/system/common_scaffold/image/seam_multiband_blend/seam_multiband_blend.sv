// Full aligned image pair -> DP seam mask -> actual Laplacian pyramid blend.
module seam_multiband_blend(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire[5:0]cfg_width,cfg_height,
 input wire[1:0]cfg_levels,input wire cfg_horizontal,input wire[7:0]cfg_gradient_weight,
 input wire[5:0]cfg_feather,output reg cfg_done,cfg_error,
 input wire start_valid,output wire start_ready,input wire abort,
 input wire[7:0]s_a,s_b,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output wire[7:0]m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output wire[191:0]seam_coordinates,output wire[5:0]seam_length,output wire[31:0]total_cost,
 output wire done_valid,input wire done_ready,output wire done_error,
 output reg[7:0]error_code,output wire busy
);
 localparam IDLE=0,CONFIG=1,RUN=2,COMPLETE=3,FAILED=4,RESTORE=5,RESTORE_WAIT=6;
 reg[2:0]state;
 reg configured,s_seen,b_seen,config_fault;
 reg[5:0]width_q,height_q,feather_q;
 reg[1:0]levels_q;
 reg horizontal_q;
 reg[7:0]gradient_q;
 wire child_rst_n=rst_n&&state!=FAILED;
 wire s_cfg_ready,s_cfg_done,s_cfg_error,b_cfg_ready,b_cfg_done,b_cfg_error;
 wire s_start_ready,b_start_ready;
 wire good_config=cfg_width!=0&&cfg_width<=32&&cfg_height!=0&&cfg_height<=32&&
                  cfg_feather<=32&&(cfg_levels==2||cfg_levels==3);
 assign cfg_ready=rst_n&&ce&&state==IDLE&&s_cfg_ready&&b_cfg_ready;
 wire external_config=cfg_valid&&cfg_ready&&good_config;
 wire restore_config=state==RESTORE&&s_cfg_ready&&b_cfg_ready;
 wire child_config=external_config||restore_config;
 wire[5:0]cw=external_config?cfg_width:width_q,ch=external_config?cfg_height:height_q,
           cf=external_config?cfg_feather:feather_q;
 wire[1:0]cl=external_config?cfg_levels:levels_q;
 wire cd=external_config?cfg_horizontal:horizontal_q;
 wire[7:0]cg=external_config?cfg_gradient_weight:gradient_q;
 assign start_ready=rst_n&&ce&&state==IDLE&&configured&&!cfg_valid&&!abort&&s_start_ready&&b_start_ready;
 wire begin_frame=start_valid&&start_ready;
 wire sm_valid,sm_ready,sm_sof,sm_eol,sm_last,sm_seam,s_done,b_done;
 wire[7:0]sm_mask,bm_data;
 wire[3:0]s_error,b_error;
 wire bs_ready,bm_valid,bm_sof,bm_eol,bm_last;
 reg[15:0]pairs[0:1023],pair_q;
 reg[9:0]pair_addr;
 reg[10:0]input_index,replay_index;
 reg[1:0]replay_state;
 wire bad_child=(s_done&&s_error!=0)||(b_done&&b_error!=0);
 wire finish=state==RUN&&s_done&&b_done&&!bad_child&&!abort;
 wire replay_valid=state==RUN&&replay_state==2&&sm_valid&&!abort&&!bad_child;
 assign sm_ready=state==RUN&&replay_state==2&&bs_ready&&!abort&&!bad_child;
 wire seam_input_ready;
 assign s_ready=rst_n&&state==RUN&&seam_input_ready&&!abort;
 seam_find seam(
  .clk(clk),.rst_n(child_rst_n),.ce(ce),
  .cfg_valid(child_config),.cfg_ready(s_cfg_ready),.cfg_width(cw),.cfg_height(ch),
  .cfg_horizontal(cd),.cfg_gradient_weight(cg),.cfg_feather(cf),.cfg_done(s_cfg_done),.cfg_error(s_cfg_error),
  .start_valid(begin_frame),.start_ready(s_start_ready),.abort(abort&&state==RUN),
  .s_a(s_a),.s_b(s_b),.s_valid(s_valid&&state==RUN),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_ready(seam_input_ready),
  .m_mask(sm_mask),.m_valid(sm_valid),.m_ready(sm_ready),.m_sof(sm_sof),.m_eol(sm_eol),.m_last(sm_last),.m_is_seam(sm_seam),
  .seam_coordinates(seam_coordinates),.seam_length(seam_length),.total_cost(total_cost),
  .done_valid(s_done),.done_ready(finish),.error_code(s_error),.busy());
 multiband_blend blend(
  .clk(clk),.rst_n(child_rst_n),.ce(ce),
  .cfg_valid(child_config),.cfg_ready(b_cfg_ready),.cfg_width(cw),.cfg_height(ch),.cfg_levels(cl),.cfg_done(b_cfg_done),.cfg_error(b_cfg_error),
  .start_valid(begin_frame),.start_ready(b_start_ready),
  .s_a(pair_q[15:8]),.s_b(pair_q[7:0]),.s_mask(sm_mask),.s_valid(replay_valid),
  .s_sof(sm_sof),.s_eol(sm_eol),.s_last(sm_last),.s_ready(bs_ready),
  .m_data(bm_data),.m_valid(bm_valid),.m_ready(m_ready&&state==RUN&&!abort&&!bad_child),.m_sof(bm_sof),.m_eol(bm_eol),.m_last(bm_last),
  .done_valid(b_done),.done_ready(finish),.error_code(b_error),.busy());
 assign m_data=bm_data;
 assign m_valid=rst_n&&state==RUN&&bm_valid&&!abort&&!bad_child;
 assign m_sof=m_valid&&bm_sof;assign m_eol=m_valid&&bm_eol;assign m_last=m_valid&&bm_last;
 assign done_valid=rst_n&&(state==COMPLETE||state==FAILED);
 assign done_error=state==FAILED;
 assign busy=state!=IDLE;
 always @(posedge clk)if(ce)begin
  pair_q<=pairs[pair_addr];
  if(state==RUN&&s_valid&&s_ready)pairs[input_index[9:0]]<={s_a,s_b};
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;configured<=0;s_seen<=0;b_seen<=0;config_fault<=0;
   width_q<=1;height_q<=1;feather_q<=0;levels_q<=2;horizontal_q<=0;gradient_q<=0;
   cfg_done<=0;cfg_error<=0;error_code<=0;input_index<=0;replay_index<=0;replay_state<=0;pair_addr<=0;
  end else if(ce)begin
   cfg_done<=0;cfg_error<=0;
   if(state==RUN&&(abort||bad_child))begin
    error_code<=abort?8'h93:(s_done&&s_error!=0?{4'h1,s_error}:{4'h2,b_error});state<=FAILED;
   end else case(state)
    IDLE:if(cfg_valid&&cfg_ready)begin
     if(!good_config)cfg_error<=1;
     else begin
      width_q<=cfg_width;height_q<=cfg_height;feather_q<=cfg_feather;levels_q<=cfg_levels;
      horizontal_q<=cfg_horizontal;gradient_q<=cfg_gradient_weight;s_seen<=0;b_seen<=0;config_fault<=0;state<=CONFIG;
     end
    end else if(begin_frame)begin input_index<=0;replay_index<=0;replay_state<=0;error_code<=0;state<=RUN;end
    CONFIG,RESTORE_WAIT:begin
     if(s_cfg_done||s_cfg_error)s_seen<=1;
     if(b_cfg_done||b_cfg_error)b_seen<=1;
     if(s_cfg_error||b_cfg_error)config_fault<=1;
     if((s_seen||s_cfg_done||s_cfg_error)&&(b_seen||b_cfg_done||b_cfg_error))begin
      if(config_fault||s_cfg_error||b_cfg_error)begin
       configured<=0;cfg_error<=1;error_code<=8'h94;state<=FAILED;
      end else begin configured<=1;if(state==CONFIG)cfg_done<=1;state<=IDLE;end
     end
    end
    RUN:begin
     if(s_valid&&s_ready)input_index<=input_index+1'b1;
     case(replay_state)
      0:begin pair_addr<=replay_index[9:0];replay_state<=1;end
      1:replay_state<=2;
      2:if(sm_valid&&sm_ready)begin replay_index<=replay_index+1'b1;replay_state<=0;end
     endcase
     if(finish)state<=COMPLETE;
    end
    COMPLETE:if(done_ready)state<=IDLE;
    FAILED:if(done_ready)state<=RESTORE;
    RESTORE:if(restore_config)begin s_seen<=0;b_seen<=0;config_fault<=0;state<=RESTORE_WAIT;end
    default:begin error_code<=8'h95;state<=FAILED;end
   endcase
  end
 end
endmodule
