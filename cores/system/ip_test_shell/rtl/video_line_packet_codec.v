// RGB888 video -> one packet per line. User={frame_id[6:0],first_line}.
// Width/height/id are sampled only on an accepted SOF pixel.
module video_line_packetizer(
 input wire clk,rst_n,input wire [15:0] width,height,input wire [6:0] frame_id,
 input wire [23:0] s_data,input wire s_sof,s_eol,s_valid,output wire s_ready,
 output reg [23:0] m_data,output wire [2:0] m_keep,output reg [7:0] m_user,
 output reg m_last,m_valid,input wire m_ready,output reg error
);
 reg [15:0] run_width,run_height,x,y;
 reg [6:0] run_id;
 reg active;
 wire [15:0] cx=s_sof?16'd0:x,cy=s_sof?16'd0:y;
 wire [15:0] cw=s_sof?width:run_width,ch=s_sof?height:run_height;
 assign s_ready=rst_n&&(!m_valid||m_ready);
 assign m_keep=3'b111;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   run_width<=0;run_height<=0;run_id<=0;x<=0;y<=0;active<=0;
   m_valid<=0;m_data<=0;m_user<=0;m_last<=0;error<=0;
  end else begin
   if(m_valid&&m_ready)m_valid<=0;
   if(s_valid&&s_ready) begin
    m_valid<=1;m_data<=s_data;m_last<=s_eol;
    m_user<={s_sof?frame_id:run_id,cy==0};
    if(s_sof)begin
     run_width<=width;run_height<=height;run_id<=frame_id;active<=1;
     if(active||width==0||height==0)error<=1;
    end else if(!active)error<=1;
    if(cw==0||ch==0||cx>=cw||cy>=ch||s_eol!=(cx==cw-1'b1))error<=1;
    if(s_eol)begin
     x<=0;y<=cy+1'b1;
     if(cy==ch-1'b1)active<=0;
    end else begin x<=cx+1'b1;y<=cy;end
   end
  end
 end
endmodule

// Line packets -> RGB888. SOF is first pixel of a packet marked first_line.
module video_line_depacketizer(
 input wire clk,rst_n,input wire [23:0] s_data,input wire [2:0] s_keep,
 input wire [7:0] s_user,input wire s_last,s_valid,output wire s_ready,
 output reg [23:0] m_data,output reg [6:0] m_frame_id,
 output reg m_sof,m_eol,m_valid,input wire m_ready,output reg error
);
 reg first;
 reg [7:0] packet_user;
 assign s_ready=rst_n&&(!m_valid||m_ready);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   first<=1;packet_user<=0;error<=0;
   m_data<=0;m_frame_id<=0;m_sof<=0;m_eol<=0;m_valid<=0;
  end else begin
   if(m_valid&&m_ready)m_valid<=0;
   if(s_valid&&s_ready)begin
    m_valid<=1;m_data<=s_data;m_frame_id<=s_user[7:1];m_sof<=first&&s_user[0];m_eol<=s_last;
    if(s_keep!=3'b111||(!first&&s_user!=packet_user))error<=1;
    if(first)packet_user<=s_user;
    first<=s_last;
   end
  end
 end
endmodule
