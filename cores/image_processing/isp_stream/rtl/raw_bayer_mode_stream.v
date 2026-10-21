// Canonical synchronous window + one-stage Bayer kernel, no duplicate rows.
// Bypass broadcasts the cropped center RAW byte with identical register timing.
module raw_bayer_mode_stream #(parameter RAW_BITS=10,MAX_WIDTH=640)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_width,cmd_height,cmd_frame_id,input wire [1:0] cmd_pattern,input wire cmd_bypass,
 input wire s_valid,output wire s_ready,input wire [RAW_BITS-1:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output wire [23:0] m_data,
 output wire m_sof,m_eol,m_eof,output wire [15:0] m_frame_id,
 output wire rsp_valid,input wire rsp_ready,output wire [3:0] rsp_error,
 output wire [15:0] out_width,out_height
);
 localparam SHIFT=RAW_BITS>=8?RAW_BITS-8:0;
 reg active,reject,bypass,output_done,eof_tag;
 reg [7:0] center_tag;reg [15:0] frame_id,width,height;
 wire wc_ready,kc_ready,kc_pending,wr_valid,wv,kr,kv,ks,ke;
 wire [9*RAW_BITS-1:0] taps;wire [RAW_BITS-1:0] center;
 wire [15:0] wx,wy;wire [23:0] rgb;wire ws,we,wf;wire [3:0] window_error;
 wire legal=cmd_width>=3&&cmd_height>=3&&cmd_width<=MAX_WIDTH;
 wire launch=cmd_valid&&cmd_ready&&legal;
 assign cmd_ready=rst_n&&!active&&wc_ready&&kc_ready&&!kc_pending;
 assign m_valid=kv;assign m_sof=ks;assign m_eol=ke;assign m_eof=eof_tag;
 assign m_frame_id=frame_id;assign m_data=bypass?{3{center_tag}}:rgb;
 assign out_width=width;assign out_height=height;
 assign rsp_valid=active&&(reject||(wr_valid&&output_done));
 assign rsp_error=reject?4'd1:window_error;
 img_window3x3_valid_draft #(.PIXEL_W(RAW_BITS),.MAX_WIDTH(MAX_WIDTH)) window(
 .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.cfg_valid(launch),.cfg_ready(wc_ready),
 .cfg_width(cmd_width),.cfg_height(cmd_height),.rsp_valid(wr_valid),.rsp_ready(rsp_valid&&rsp_ready&&!reject),.rsp_error(window_error),
 .s_data(s_data),.s_valid(s_valid&&active&&!reject),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),
 .m_taps(taps),.m_center(center),.m_x(wx),.m_y(wy),.m_valid(wv),.m_ready(kr),.m_sof(ws),.m_eol(we),.m_eof(wf));
 img_isp_bayer_interpolate #(.RAW_BITS(RAW_BITS),.EXTERNAL_WINDOW(1)) bayer(
 .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.s_data(center),.s_window(taps),.s_x_odd(wx[0]),.s_y_odd(wy[0]),
 .s_valid(wv),.s_ready(kr),.s_sof(ws),.s_eol(we),.m_data(rgb),.m_valid(kv),.m_ready(m_ready),.m_sof(ks),.m_eol(ke),
 .cfg_we(launch),.cfg_commit(launch),.cfg_pattern(cmd_pattern),.cfg_ready(kc_ready),.cfg_pending(kc_pending),.unsupported(),.error(),.error_code());
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin active<=0;reject<=0;bypass<=0;output_done<=0;eof_tag<=0;center_tag<=0;frame_id<=0;width<=0;height<=0;end
  else begin
   if(cmd_valid&&cmd_ready)begin
    active<=1;reject<=!legal;bypass<=cmd_bypass;frame_id<=cmd_frame_id;output_done<=0;
    width<=legal?cmd_width-2:0;height<=legal?cmd_height-2:0;
   end
   // Same acceptance as the canonical kernel's one-entry output register.
   if(wv&&kr)begin center_tag<=center>>SHIFT;eof_tag<=wf;end
   if(m_valid&&m_ready&&m_eof)output_done<=1;
   if(rsp_valid&&rsp_ready)begin active<=0;reject<=0;end
  end
 end
`ifndef SYNTHESIS
 initial if((RAW_BITS!=8&&RAW_BITS!=10&&RAW_BITS!=12)||MAX_WIDTH<3||MAX_WIDTH>65535)
  $fatal(1,"raw_bayer_mode_stream unsupported parameters");
`endif
endmodule
