// Finite, seedable RAW raster source with command/payload/response sequencing.
// Period is command-to-command in clocks when the consumer finishes on time.
module virtual_raw_source #(parameter RAW_BITS=10)(
 input wire clk,rst_n,start,output wire start_ready,
 input wire [15:0] width,height,input wire [31:0] frame_count,period_cycles,
 input wire [RAW_BITS-1:0] seed,
 output wire cmd_valid,input wire cmd_ready,output wire [15:0] cmd_width,cmd_height,cmd_frame_id,
 output wire m_valid,input wire m_ready,output wire [RAW_BITS-1:0] m_data,
 output wire m_sof,m_eol,m_eof,
 input wire rsp_valid,output wire rsp_ready,input wire [3:0] rsp_error,
 output wire done,output reg error,
 output reg [31:0] completed_frames,deadline_misses,command_stalls,pixel_stalls,run_cycles
);
 localparam IDLE=0,COMMAND=1,PIXELS=2,RESPONSE=3,GAP=4,FINISHED=5;
 reg [2:0] state;
 reg [15:0] w,h,x,y,frame_id;
 reg [31:0] frames,period,age;
 reg [RAW_BITS-1:0] frame_base,row_base,pixel;
 assign start_ready=state==IDLE||state==FINISHED;
 assign cmd_valid=state==COMMAND;
 assign cmd_width=w;assign cmd_height=h;assign cmd_frame_id=frame_id;
 assign m_valid=state==PIXELS;assign m_data=pixel;
 assign m_sof=x==0&&y==0;assign m_eol=x==w-1;assign m_eof=m_eol&&y==h-1;
 // Configuration rejection may arrive before the consumer accepts any RAW
 // samples. An explicit error response aborts the offered source frame.
 assign rsp_ready=state==RESPONSE||(state==PIXELS&&rsp_error!=0);
 assign done=state==FINISHED;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;w<=0;h<=0;x<=0;y<=0;frame_id<=0;frames<=0;period<=0;age<=0;
   frame_base<=0;row_base<=0;pixel<=0;error<=0;completed_frames<=0;deadline_misses<=0;command_stalls<=0;pixel_stalls<=0;run_cycles<=0;end
  else if(start&&start_ready)begin
   w<=width;h<=height;frames<=frame_count;period<=period_cycles;frame_id<=0;
   frame_base<=seed;row_base<=seed;pixel<=seed;x<=0;y<=0;age<=0;
   completed_frames<=0;deadline_misses<=0;command_stalls<=0;pixel_stalls<=0;run_cycles<=0;
   error<=width==0||height==0||frame_count==0||period_cycles<2;
   state<=width==0||height==0||frame_count==0||period_cycles<2?FINISHED:COMMAND;
  end else if(!start_ready)begin
   run_cycles<=run_cycles+1'b1;
   if(age!=32'hffffffff)age<=age+1'b1;
   case(state)
    COMMAND:begin
     if(cmd_ready)begin state<=PIXELS;age<=0;end
     else command_stalls<=command_stalls+1'b1;
    end
    PIXELS:begin
     if(rsp_valid&&rsp_error!=0)begin
      completed_frames<=completed_frames+1'b1;
      if(age>=period)deadline_misses<=deadline_misses+1'b1;
      error<=1;state<=FINISHED;
     end else if(!m_ready)pixel_stalls<=pixel_stalls+1'b1;
     else if(m_eof)state<=RESPONSE;
     else if(m_eol)begin x<=0;y<=y+1'b1;row_base<=row_base+37;pixel<=row_base+37;end
     else begin x<=x+1'b1;pixel<=pixel+23;end
    end
    RESPONSE:if(rsp_valid)begin
     completed_frames<=completed_frames+1'b1;
     if(age>=period)deadline_misses<=deadline_misses+1'b1;
     if(rsp_error!=0)begin error<=1;state<=FINISHED;end
     else if(completed_frames==frames-1)state<=FINISHED;
     else begin
      frame_id<=frame_id+1'b1;frame_base<=frame_base+57;
      row_base<=frame_base+57;pixel<=frame_base+57;x<=0;y<=0;
      state<=age>=period-2?COMMAND:GAP;
     end
    end
    GAP:if(age>=period-2)state<=COMMAND;
    default:state<=FINISHED;
   endcase
  end
 end
endmodule
