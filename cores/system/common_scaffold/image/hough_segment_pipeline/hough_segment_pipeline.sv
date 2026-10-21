// Automatic binary frame -> complete polar Hough peaks -> finite segments.
module hough_segment_pipeline #(parameter WIDTH=16,HEIGHT=16,THETA_STEP=1,
 parameter TRIG_FILE="trig.mem")(
 input clk,rst_n,ce,start_valid,output start_ready,
 input [10:0]cfg_threshold,input[4:0]cfg_max_candidates,
 input [6:0]cfg_theta_nms,cfg_rho_nms,
 input [1:0]cfg_rho_tolerance,input[5:0]cfg_max_gap,cfg_min_length,
 input [5:0]cfg_min_support,cfg_max_segments,
 input s_valid,s_edge,s_sof,s_eol,s_last,output s_ready,
 output m_valid,input m_ready,output[7:0]m_theta,output signed[7:0]m_rho,
 output[5:0]m_x1,m_y1,m_x2,m_y2,m_support,m_segment_index,
 output[11:0]m_length_squared,output[4:0]m_candidate_index,
 output reg[4:0]detected_candidates,output reg[9:0]emitted_segments,
 output done_valid,input done_ready,output done_error,
 output reg[7:0]error_code,output busy
);
 localparam GOOD=WIDTH>=1&&WIDTH<=32&&HEIGHT>=1&&HEIGHT<=32;
 localparam N=GOOD?WIDTH*HEIGHT:1;
 localparam IDLE=0,CAPTURE=1,PEAKS=2,CAND_ADDR=3,CAND_READ=4,CAND_LOAD=5,
 SEG_START=6,REPLAY_ADDR=7,REPLAY_READ=8,REPLAY_VALUE=9,REPLAY_SEND=10,
 SEG_RUN=11,COMPLETE=12,FAILED=13;
 reg[3:0]state;
 reg edges[0:N-1],edge_q,replay_data;
 reg[10:0]capture_pos,replay_pos;reg[5:0]replay_x;
 reg[15:0]candidate_mem[0:15],candidate_q;
 reg[4:0]candidate_index;
 reg[7:0]candidate_theta;reg signed[7:0]candidate_rho;
 reg[1:0]tolerance;reg[5:0]gap,min_length,min_support,segment_limit;
 wire full_start_ready,full_s_ready,full_valid,full_done,full_error;
 wire[7:0]full_theta;wire signed[7:0]full_rho;wire[3:0]full_code;
 wire seg_start_ready,seg_s_ready,seg_valid,seg_done,seg_error;
 wire[3:0]seg_code;wire[5:0]seg_x1,seg_y1,seg_x2,seg_y2,seg_support,seg_index;
 wire[11:0]seg_length_squared;
 wire config_good=GOOD&&THETA_STEP>=1&&THETA_STEP<=90&&180%(THETA_STEP>0?THETA_STEP:1)==0&&
 cfg_threshold>=1&&cfg_threshold<=1024&&cfg_max_candidates>=1&&cfg_max_candidates<=16&&
 cfg_theta_nms<=90&&cfg_rho_nms<=90&&cfg_max_gap<=31&&cfg_min_length>=1&&cfg_min_length<=44&&
 cfg_min_support>=2&&cfg_min_support<=32&&cfg_max_segments>=1&&cfg_max_segments<=32;
 wire active=state!=IDLE&&state!=COMPLETE&&state!=FAILED;
 wire full_failure=active&&full_done&&full_error;
 wire seg_failure=active&&seg_done&&seg_error;
 wire child_reset=!rst_n||state==FAILED;
 assign start_ready=rst_n&&ce&&state==IDLE&&full_start_ready&&seg_start_ready;
 wire accepted_start=start_valid&&start_ready;
 assign s_ready=rst_n&&state==CAPTURE&&full_s_ready;
 wire output_enable=rst_n&&state==SEG_RUN&&!full_failure&&!seg_failure;
 assign m_valid=output_enable&&seg_valid;
 assign m_theta=state==SEG_RUN?candidate_theta:8'b0;
 assign m_rho=state==SEG_RUN?candidate_rho:8'sd0;
 assign m_candidate_index=state==SEG_RUN?candidate_index:5'b0;
 assign m_x1=state==SEG_RUN?seg_x1:6'b0;
 assign m_y1=state==SEG_RUN?seg_y1:6'b0;
 assign m_x2=state==SEG_RUN?seg_x2:6'b0;
 assign m_y2=state==SEG_RUN?seg_y2:6'b0;
 assign m_support=state==SEG_RUN?seg_support:6'b0;
 assign m_segment_index=state==SEG_RUN?seg_index:6'b0;
 assign m_length_squared=state==SEG_RUN?seg_length_squared:12'b0;
 assign done_valid=rst_n&&(state==COMPLETE||state==FAILED);
 assign done_error=state==FAILED;
 assign busy=state!=IDLE;
 hough_lines_full #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.THETA_STEP(THETA_STEP),.TRIG_FILE(TRIG_FILE)) polar(
 .clk(clk),.rst_n(!child_reset),.ce(ce),.start_valid(accepted_start&&config_good),.start_ready(full_start_ready),
 .cfg_threshold(cfg_threshold),.cfg_max_lines(cfg_max_candidates),.cfg_theta_nms(cfg_theta_nms),.cfg_rho_nms(cfg_rho_nms),
 .s_valid(s_valid&&state==CAPTURE),.s_edge(s_edge),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_ready(full_s_ready),
 .m_valid(full_valid),.m_ready(state==PEAKS),.m_theta(full_theta),.m_rho(full_rho),.m_score(),.m_index(),
 .done_valid(full_done),.done_ready(state==PEAKS&&!full_error),.done_error(full_error),.error_code(full_code),.busy());
 hough_segments #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TRIG_FILE(TRIG_FILE)) segments(
 .clk(clk),.rst_n(!child_reset),.ce(ce),.start_valid(state==SEG_START),.start_ready(seg_start_ready),
 .cfg_theta(candidate_theta),.cfg_rho(candidate_rho),.cfg_rho_tolerance(tolerance),.cfg_max_gap(gap),
 .cfg_min_length(min_length),.cfg_min_support(min_support),.cfg_max_segments(segment_limit),
 .s_valid(state==REPLAY_SEND),.s_edge(replay_data),.s_sof(replay_pos==0),.s_eol(replay_x==WIDTH-1),.s_last(replay_pos==N-1),.s_ready(seg_s_ready),
 .m_valid(seg_valid),.m_ready(m_ready&&output_enable),
 .m_x1(seg_x1),.m_y1(seg_y1),.m_x2(seg_x2),.m_y2(seg_y2),.m_support(seg_support),.m_index(seg_index),.m_length_squared(seg_length_squared),
 .done_valid(seg_done),.done_ready(state==SEG_RUN&&!seg_error),.done_error(seg_error),.error_code(seg_code),.busy());
 always @(posedge clk)if(ce)begin
  edge_q<=edges[replay_pos];candidate_q<=candidate_mem[candidate_index[3:0]];
  if(state==CAPTURE&&s_valid&&full_s_ready)edges[capture_pos]<=s_edge;
  if(state==PEAKS&&full_valid&&detected_candidates<16)candidate_mem[detected_candidates[3:0]]<={full_theta,full_rho};
 end
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;capture_pos<=0;replay_pos<=0;replay_x<=0;candidate_index<=0;candidate_theta<=0;candidate_rho<=0;detected_candidates<=0;emitted_segments<=0;error_code<=0;replay_data<=0;end
 else if(ce)begin
 if(full_failure)begin state<=FAILED;error_code<={4'h1,full_code};end
 else if(seg_failure)begin state<=FAILED;error_code<={4'h2,seg_code};end
 else case(state)
 IDLE:if(accepted_start)begin
  detected_candidates<=0;emitted_segments<=0;candidate_index<=0;candidate_theta<=0;candidate_rho<=0;error_code<=0;
  if(!config_good)begin state<=FAILED;error_code<=1;end
  else begin tolerance<=cfg_rho_tolerance;gap<=cfg_max_gap;min_length<=cfg_min_length;min_support<=cfg_min_support;segment_limit<=cfg_max_segments;capture_pos<=0;state<=CAPTURE;end
 end
 CAPTURE:if(s_valid&&full_s_ready)begin if(capture_pos==N-1)state<=PEAKS;else capture_pos<=capture_pos+1;end
 PEAKS:begin
  if(full_valid&&detected_candidates==16)begin state<=FAILED;error_code<=8'h30;end
  else begin
   if(full_valid)detected_candidates<=detected_candidates+1;
   if(full_done)begin if(detected_candidates==0&&!full_valid)state<=COMPLETE;else begin candidate_index<=0;state<=CAND_ADDR;end end
  end
 end
 CAND_ADDR:state<=CAND_READ;
 CAND_READ:state<=CAND_LOAD;
 CAND_LOAD:begin candidate_theta<=candidate_q[15:8];candidate_rho<=candidate_q[7:0];state<=SEG_START;end
 SEG_START:if(seg_start_ready)begin replay_pos<=0;replay_x<=0;state<=REPLAY_ADDR;end
 REPLAY_ADDR:state<=REPLAY_READ;
 REPLAY_READ:state<=REPLAY_VALUE;
 REPLAY_VALUE:begin replay_data<=edge_q;state<=REPLAY_SEND;end
 REPLAY_SEND:if(seg_s_ready)begin if(replay_pos==N-1)state<=SEG_RUN;
  else begin replay_pos<=replay_pos+1;if(replay_x==WIDTH-1)replay_x<=0;else replay_x<=replay_x+1;state<=REPLAY_ADDR;end
 end
 SEG_RUN:begin
  if(m_valid&&m_ready)emitted_segments<=emitted_segments+1;
  if(seg_done)begin if(candidate_index==detected_candidates-1)state<=COMPLETE;
   else begin candidate_index<=candidate_index+1;state<=CAND_ADDR;end
  end
 end
 COMPLETE,FAILED:if(done_ready)state<=IDLE;
 default:begin state<=FAILED;error_code<=8'h40;end
 endcase
 end
 end
endmodule
