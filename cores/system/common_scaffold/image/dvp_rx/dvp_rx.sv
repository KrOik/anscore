// Single pixel-clock DVP receiver. Sensor input is deliberately NOT CE gated.
module dvp_rx #(parameter MAX_WIDTH=640,MAX_HEIGHT=480,FIFO_DEPTH=1024)(
 input wire clk,rst_n,ce,start_valid,abort,output wire start_ready,
 input wire[15:0]cfg_width,cfg_height,input wire cfg_mode,cfg_big_endian,
 input wire cfg_vsync_active_high,cfg_href_active_high,
 input wire sample_valid,vsync,href,input wire[7:0]data,
 output wire[23:0]m_pixel,output reg m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,output wire done_valid,input wire done_ready,
 output reg frame_error,output reg[7:0]error_code,
 output reg[15:0]image_width,image_height,output reg image_mode);
 localparam IDLE=0,LOCK=1,FRAME=2,DRAIN=3,DONE=4,ERROR_DRAIN=5;
 localparam AW=FIFO_DEPTH<=1?1:$clog2(FIFO_DEPTH+1);
 reg[2:0]state;reg be,vpol,hpol,locked,prev_h,half;
 reg[7:0]first;reg[16:0]linebytes;reg[15:0]lines;
 reg[AW-1:0]wp,rp;reg[AW:0]count;
 reg[26:0]mem[0:FIFO_DEPTH];reg[26:0]q;
 wire v=vsync==vpol,h=href==hpol;
 wire pop=ce&&m_valid&&m_ready;
 wire read_en=ce&&(!m_valid||m_ready)&&count!=0&&(state==FRAME||state==DRAIN);
 wire[16:0]expected_bytes=image_mode?{image_width,1'b0}:{1'b0,image_width};
 wire pixel_event=state==FRAME&&sample_valid&&!v&&h&&linebytes<expected_bytes&&lines<image_height&&(!image_mode||half);
 wire full=count==FIFO_DEPTH;
 wire push=pixel_event&&(!full||read_en);
 wire[15:0]rgb565=be?{first,data}:{data,first};
 wire[23:0]rgb888={rgb565[15:11],rgb565[15:13],rgb565[10:5],rgb565[10:9],rgb565[4:0],rgb565[4:2]};
 wire[16:0]pixel_x=image_mode?(linebytes>>1):linebytes;
 wire[26:0]token={lines==0&&pixel_x==0,pixel_x==image_width-1,pixel_x==image_width-1&&lines==image_height-1,image_mode?rgb888:{16'b0,data}};
 assign m_pixel=q[23:0];assign m_sof=q[26];assign m_eol=q[25];assign m_last=q[24];
 assign start_ready=state==IDLE;assign done_valid=state==DONE;
 always @(posedge clk)begin
  if(push)mem[wp]<=token;
  if(read_en)q<=mem[rp];
 end
 task fail;input[7:0]code;begin frame_error<=1;error_code<=code;state<=m_valid&&!pop?ERROR_DRAIN:DONE;count<=0;wp<=0;rp<=0;m_valid<=m_valid&&!pop;half<=0;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;be<=0;vpol<=1;hpol<=1;locked<=0;prev_h<=0;half<=0;first<=0;linebytes<=0;lines<=0;wp<=0;rp<=0;count<=0;m_valid<=0;frame_error<=0;error_code<=0;image_width<=0;image_height<=0;image_mode<=0;end
 else begin
  if(push)wp<=wp==FIFO_DEPTH?0:wp+1'b1;
  if(read_en)begin rp<=rp==FIFO_DEPTH?0:rp+1'b1;m_valid<=1;end else if(pop)m_valid<=0;
  case({push,read_en})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
  if(ce&&abort&&state!=IDLE&&state!=DONE&&state!=ERROR_DRAIN)fail(9);
  else case(state)
  IDLE:if(ce&&start_valid)begin
   image_width<=cfg_width;image_height<=cfg_height;image_mode<=cfg_mode;be<=cfg_big_endian;vpol<=cfg_vsync_active_high;hpol<=cfg_href_active_high;
   locked<=0;prev_h<=0;half<=0;linebytes<=0;lines<=0;count<=0;wp<=0;rp<=0;m_valid<=0;frame_error<=0;error_code<=0;
   if(MAX_WIDTH<1||MAX_WIDTH>4096||MAX_HEIGHT<1||MAX_HEIGHT>4096||FIFO_DEPTH<2||FIFO_DEPTH>4096||cfg_width==0||cfg_width>MAX_WIDTH||cfg_height==0||cfg_height>MAX_HEIGHT)fail(1);
   else state<=LOCK;
  end
  LOCK:if(sample_valid)begin
   if(v)locked<=1;
   else if(locked)begin if(h)fail(8);else begin state<=FRAME;prev_h<=0;linebytes<=0;lines<=0;half<=0;end end
  end
  FRAME:if(sample_valid)begin
   prev_h<=h;
   if(v)begin
    if(h)fail(8);
    else if(prev_h)begin
     if(half)fail(5);else if(linebytes!=expected_bytes)fail(4);
     else if(lines+1!=image_height)fail(6);else state<=DRAIN;
    end else if(lines!=image_height)fail(6);else state<=DRAIN;
   end else if(h)begin
    if(lines>=image_height)fail(7);
    else if(linebytes>=expected_bytes)fail(3);
    else begin
     linebytes<=linebytes+1'b1;
     if(image_mode)begin if(!half)first<=data;half<=!half;end
     if(pixel_event&&full&&!read_en)fail(2);
    end
   end else if(prev_h)begin
    if(half)fail(5);else if(linebytes!=expected_bytes)fail(4);
    else begin lines<=lines+1'b1;linebytes<=0;half<=0;end
   end
  end
  DRAIN:if(count==0&&!m_valid)state<=DONE;
  ERROR_DRAIN:if(!m_valid||pop)state<=DONE;
  DONE:if(ce&&done_ready)state<=IDLE;
  default:fail(8);
  endcase
 end end
endmodule
