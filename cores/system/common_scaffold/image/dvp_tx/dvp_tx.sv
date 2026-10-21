// Fixed tick parallel-camera transmitter; host CE cannot pause sensor timing.
module dvp_tx #(parameter MAX_WIDTH=640,MAX_HEIGHT=480,FIFO_DEPTH=1024)(
 input wire clk,rst_n,ce,start_valid,abort,output wire start_ready,
 input wire[15:0]cfg_width,cfg_height,input wire cfg_mode,cfg_big_endian,cfg_vsync_active_high,cfg_href_active_high,
 input wire[15:0]cfg_hblank,cfg_vblank_lines,cfg_byte_period,
 input wire[23:0]s_pixel,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output reg[7:0]data,output reg vsync,href,sample_valid,
 output wire done_valid,input wire done_ready,output reg frame_error,output reg[7:0]error_code,
 output reg[15:0]image_width,image_height,output reg image_mode);
 localparam IDLE=0,PREFILL=1,RUN=2,DONE=3;
 localparam AW=FIFO_DEPTH<=1?1:$clog2(FIFO_DEPTH);
 reg[1:0]state;reg be,vpol,hpol;reg[15:0]hblank,vblank,period,phase;
 reg[31:0]total,received,target;reg[15:0]input_x;
 reg[17:0]line_no;reg[16:0]byte_no;
 reg[AW-1:0]wp,rp;reg[AW:0]count;reg[23:0]mem[0:FIFO_DEPTH-1];reg[23:0]pixel;reg pixel_valid;
 wire tick=state==RUN&&phase==0;
 wire[16:0]line_bytes=image_mode?{image_width,1'b0}:{1'b0,image_width};
 wire[17:0]line_ticks={1'b0,line_bytes}+hblank;
 wire[17:0]frame_lines={2'b0,image_height}+({2'b0,vblank}<<1);
 wire active_line=line_no>=vblank&&line_no<({2'b0,vblank}+image_height);
 wire active_byte=active_line&&byte_no>=hblank;
 wire[16:0]active_index=byte_no-hblank;
 wire consume=tick&&!frame_error&&active_byte&&pixel_valid&&(!image_mode||active_index[0]);
 wire read_en=(state==PREFILL||state==RUN)&&!frame_error&&(!pixel_valid||consume)&&count!=0;
 wire marker_good=(s_sof==(received==0))&&(s_eol==(input_x==image_width-1))&&(s_last==(received==total-1));
 // A full ring has wp==rp. Never write on its read cycle: avoid cross-port same-address hardware ambiguity.
 assign s_ready=(state==PREFILL||state==RUN)&&!frame_error&&received<total&&count<FIFO_DEPTH;
 wire accept=ce&&s_valid&&s_ready;
 wire push=accept&&marker_good;
 wire marker_error=accept&&!marker_good;
 wire abort_event=ce&&abort&&(state==PREFILL||state==RUN)&&!frame_error;
 wire[15:0]packed565={pixel[23:19],pixel[15:10],pixel[7:3]};
 wire[7:0]pixelbyte=image_mode?(active_index[0]!=be?packed565[15:8]:packed565[7:0]):pixel[7:0];
 assign start_ready=state==IDLE;assign done_valid=state==DONE;
 always @(posedge clk)begin if(push)mem[wp]<=s_pixel;if(read_en)pixel<=mem[rp];end
 task fail;input[7:0]code;begin
  if(!frame_error)begin frame_error<=1;error_code<=code;end
  count<=0;wp<=0;rp<=0;pixel_valid<=0;
  if(state==PREFILL)state<=DONE;
 end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;be<=0;vpol<=1;hpol<=1;hblank<=1;vblank<=1;period<=1;phase<=0;total<=0;received<=0;target<=0;input_x<=0;line_no<=0;byte_no<=0;wp<=0;rp<=0;count<=0;pixel_valid<=0;data<=0;vsync<=1;href<=0;sample_valid<=0;frame_error<=0;error_code<=0;image_width<=0;image_height<=0;image_mode<=0;end
 else begin
  sample_valid<=0;
  if(push)begin wp<=wp==FIFO_DEPTH-1?0:wp+1'b1;received<=received+1'b1;input_x<=input_x==image_width-1?0:input_x+1'b1;end
  if(read_en)begin rp<=rp==FIFO_DEPTH-1?0:rp+1'b1;pixel_valid<=1;end else if(consume)pixel_valid<=0;
  case({push,read_en})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
  case(state)
  IDLE:if(ce&&start_valid)begin
   be<=cfg_big_endian;vpol<=cfg_vsync_active_high;hpol<=cfg_href_active_high;hblank<=cfg_hblank;vblank<=cfg_vblank_lines;period<=cfg_byte_period;
   image_width<=cfg_width;image_height<=cfg_height;image_mode<=cfg_mode;
   total<=cfg_width*cfg_height;target<=cfg_width*cfg_height<FIFO_DEPTH?cfg_width*cfg_height:FIFO_DEPTH;
   phase<=0;received<=0;input_x<=0;line_no<=0;byte_no<=0;wp<=0;rp<=0;count<=0;pixel_valid<=0;frame_error<=0;error_code<=0;data<=0;vsync<=cfg_vsync_active_high;href<=!cfg_href_active_high;
   if(MAX_WIDTH<1||MAX_WIDTH>4096||MAX_HEIGHT<1||MAX_HEIGHT>4096||FIFO_DEPTH<2||FIFO_DEPTH>4096||cfg_width==0||cfg_width>MAX_WIDTH||cfg_height==0||cfg_height>MAX_HEIGHT||cfg_hblank==0||cfg_hblank>4096||cfg_vblank_lines==0||cfg_vblank_lines>4096||cfg_byte_period==0||cfg_byte_period>4096)begin state<=DONE;frame_error<=1;error_code<=1;end
   else state<=PREFILL;
  end
  PREFILL:if(received>=target&&pixel_valid)begin state<=RUN;phase<=0;end
  RUN:begin
   if(phase!=0)phase<=phase-1'b1;
   else begin
    phase<=period-1'b1;sample_valid<=1;
    if(frame_error||marker_error||abort_event)begin data<=0;vsync<=vpol;href<=!hpol;end
    else begin
     vsync<=active_line?!vpol:vpol;
     href<=active_byte?hpol:!hpol;
     data<=active_byte?pixelbyte:0;
     if(active_byte&&!pixel_valid)begin data<=0;href<=!hpol;vsync<=vpol;fail(2);end
    end
    if(byte_no+1==line_ticks)begin byte_no<=0;if(line_no+1==frame_lines)state<=DONE;else line_no<=line_no+1'b1;end
    else byte_no<=byte_no+1'b1;
   end
  end
  DONE:if(ce&&done_ready)state<=IDLE;
  default:begin state<=DONE;frame_error<=1;error_code<=8;end
  endcase
  if(marker_error)fail(4);
  if(abort_event)fail(9);
 end end
endmodule

