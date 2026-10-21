// Canonical statistics collector with EOF-driven flush and aligned tag/EOF.
// One elastic pixel stage; statistics describe samples admitted to this stage.
module rgb_frame_statistics #(parameter SUM_WIDTH=48)(
 input wire clk,rst_n,s_valid,output wire s_ready,input wire [23:0] s_data,
 input wire s_sof,s_eol,s_eof,input wire [15:0] s_frame_id,
 output wire m_valid,input wire m_ready,output wire [23:0] m_data,
 output wire m_sof,m_eol,output reg m_eof,output reg [15:0] m_frame_id,
 output wire stats_valid,input wire stats_ready,
 output wire [SUM_WIDTH-1:0] sum_r,sum_g,sum_b,
 output wire [31:0] pixel_count,line_count,output reg [15:0] stats_frame_id,
 output wire overflow,protocol_error
);
 reg flush_pending,frame_open,local_error;
 reg [15:0] active_id,pending_id;
 wire core_ready,flush_ready,core_error;
 wire offered=s_valid&&!flush_pending;
 wire take=s_valid&&s_ready;
 wire publish=flush_pending&&flush_ready;
 assign s_ready=core_ready&&!flush_pending;
 assign protocol_error=core_error||local_error;
 img_isp_awb_stats #(.SUM_WIDTH(SUM_WIDTH)) collector(
 .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.s_data(s_data),.s_valid(offered),.s_ready(core_ready),.s_sof(s_sof),.s_eol(s_eol),
 .m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),
 .stats_flush(flush_pending),.stats_flush_ready(flush_ready),.stats_valid(stats_valid),.stats_ready(stats_ready),
 .stats_sum_r(sum_r),.stats_sum_g(sum_g),.stats_sum_b(sum_b),.stats_pixel_count(pixel_count),.stats_line_count(line_count),
 .stats_frame_id(),.stats_overflow(overflow),.protocol_error(core_error));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin flush_pending<=0;frame_open<=0;local_error<=0;
   active_id<=0;pending_id<=0;stats_frame_id<=0;m_eof<=0;m_frame_id<=0;end
  else begin
   if(publish)begin flush_pending<=0;stats_frame_id<=pending_id;end
   if(take)begin
    m_eof<=s_eof;m_frame_id<=s_frame_id;
    if(s_sof)begin
     if(frame_open)local_error<=1;
     active_id<=s_frame_id;frame_open<=1;
    end else if(!frame_open||s_frame_id!=active_id)local_error<=1;
    if(s_eof)begin
     if(!s_eol)local_error<=1;
     flush_pending<=1;frame_open<=0;pending_id<=s_sof?s_frame_id:active_id;
    end
   end
  end
 end
endmodule
