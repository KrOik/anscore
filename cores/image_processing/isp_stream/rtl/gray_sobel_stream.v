// Synchronous two-row window plus unchanged canonical three-stage Sobel.
// Both modes crop one pixel per border; bypass returns each window center.
module gray_sobel_stream #(parameter MAX_WIDTH=640,MAG_SHIFT=2)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_width,cmd_height,cmd_frame_id,input wire cmd_bypass,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output wire [7:0] m_data,
 output wire m_sof,m_eol,m_eof,output wire [15:0] m_frame_id,
 output wire rsp_valid,input wire rsp_ready,output wire [3:0] rsp_error,
 output wire [15:0] out_width,out_height,output wire drained
);
 reg active,bypass,output_done;
 reg [15:0] frame_id,width,height;
 wire wc_ready,wr_valid,w_valid,w_ready,k_ready,k_valid,k_sof,k_eol;
 wire [71:0] taps;wire [7:0] center,k_data;
 wire w_sof,w_eol,w_eof;wire [3:0] w_error;
 reg [8:0] tags[0:7];reg [2:0] rd,wr;reg [3:0] count;
 wire push=w_valid&&w_ready;
 wire pop=m_valid&&m_ready;
 assign cmd_ready=wc_ready&&!active;
 assign w_ready=k_ready&&count<8;
 assign m_valid=k_valid&&count!=0;
 assign m_data=bypass?tags[rd][7:0]:k_data;
 assign m_sof=k_sof;assign m_eol=k_eol;assign m_eof=tags[rd][8];
 assign m_frame_id=frame_id;
 assign out_width=width>=3?width-2:0;
 assign out_height=height>=3?height-2:0;
 assign rsp_error=w_error;
 // Safe to abort a partial frame after the upstream response: no pending
 // window processing beat and no accepted kernel/output tokens remain.
 assign drained=count==0&&!w_valid&&(!active||s_ready||wr_valid);
 assign rsp_valid=active&&wr_valid&&(w_error==1||(output_done&&count==0));
 img_window3x3_valid_draft #(.PIXEL_W(8),.MAX_WIDTH(MAX_WIDTH)) window(
 .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.cfg_valid(cmd_valid&&!active),.cfg_ready(wc_ready),
 .cfg_width(cmd_width),.cfg_height(cmd_height),.rsp_valid(wr_valid),.rsp_ready(rsp_valid&&rsp_ready),.rsp_error(w_error),
 .s_data(s_data),.s_valid(s_valid&&active),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),
 .m_taps(taps),.m_center(center),.m_x(),.m_y(),.m_valid(w_valid),.m_ready(w_ready),.m_sof(w_sof),.m_eol(w_eol),.m_eof(w_eof));
 img_edge_sobel3x3 #(.PIXEL_W(8),.MAG_SHIFT(MAG_SHIFT)) sobel(
 .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.s_taps(taps),.s_valid(w_valid&&count<8),.s_ready(k_ready),
 .s_sof(w_sof),.s_eol(w_eol),.m_data(k_data),.m_gx(),.m_gy(),.m_magnitude(),
 .m_valid(k_valid),.m_ready(m_ready&&count!=0),.m_sof(k_sof),.m_eol(k_eol));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin active<=0;bypass<=0;output_done<=0;frame_id<=0;width<=0;height<=0;rd<=0;wr<=0;count<=0;end
  else begin
   if(cmd_valid&&cmd_ready)begin active<=1;bypass<=cmd_bypass;frame_id<=cmd_frame_id;width<=cmd_width;height<=cmd_height;output_done<=0;end
   if(push)begin tags[wr]<={w_eof,center};wr<=wr+1'b1;end
   if(pop)begin rd<=rd+1'b1;if(m_eof)output_done<=1;end
   case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
   if(rsp_valid&&rsp_ready)active<=0;
  end
 end
endmodule
