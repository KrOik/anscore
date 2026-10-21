// Local 256-gray-level Shannon entropy, Q20 bits, replicated border.
// Serial synchronous frame/histogram/entropy ROM accesses. No sliding shortcut.
module entropy_filter_frame #(parameter WIDTH=7,HEIGHT=5,
 parameter ENTROPY_FILE="entropy.mem")(
 input clk,rst_n,ce,start_valid,output start_ready,input[3:0]cfg_size,
 input[7:0]s_pixel,input s_valid,s_sof,s_eol,s_last,output s_ready,
 output reg[22:0]m_entropy_q20,output reg m_valid,input m_ready,
 output reg m_sof,m_eol,m_last,
 output done_valid,input done_ready,output reg done_error,output reg[3:0]error_code,
 output busy
);
 localparam GOOD=WIDTH>=1&&WIDTH<=32&&HEIGHT>=1&&HEIGHT<=32;
 localparam N=GOOD?WIDTH*HEIGHT:1;
 localparam IDLE=0,CAPTURE=1,CLEAR=2,TAP_ADDR=3,TAP_WAIT=4,TAP_LOAD=5,
 HIST_WAIT=6,HIST_UPDATE=7,SCAN_ADDR=8,SCAN_READ=9,SCAN_LOAD=10,
 ROM_WAIT=11,SUM=12,OUTPUT=13,DONE=14;
 reg[3:0]state;
 reg[7:0]frame_mem[0:N-1],frame_q;
 reg[5:0]histogram[0:255],histogram_q;
 reg[19:0]entropy_rom[0:191],entropy_q;
 initial $readmemh(ENTROPY_FILE,entropy_rom);
 reg[9:0]position,frame_address;
 reg[5:0]x,y,count;
 reg[2:0]side,radius,tx,ty;
 reg[1:0]bank;
 reg[7:0]clear_index,histogram_address,scan_index,rom_address;
 reg[22:0]entropy_sum;
 reg bad_frame;
 wire signed[7:0]sx=$signed({2'b00,x})+$signed({5'b0,tx})-$signed({5'b0,radius});
 wire signed[7:0]sy=$signed({2'b00,y})+$signed({5'b0,ty})-$signed({5'b0,radius});
 wire[5:0]sample_x=sx<0?6'd0:sx>=WIDTH?WIDTH-1:sx[5:0];
 wire[5:0]sample_y=sy<0?6'd0:sy>=HEIGHT?HEIGHT-1:sy[5:0];
 wire marker_bad=(s_sof!=(position==0))||(s_eol!=(x==WIDTH-1))||(s_last!=(position==N-1));
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign done_valid=rst_n&&state==DONE;
 assign busy=state!=IDLE;
 always @(posedge clk)if(ce)begin
  frame_q<=frame_mem[frame_address];histogram_q<=histogram[histogram_address];
  entropy_q<=entropy_rom[rom_address];
  if(state==CLEAR)histogram[clear_index]<=0;
  else if(state==HIST_UPDATE)histogram[histogram_address]<=histogram_q+1'b1;
  if(state==CAPTURE&&s_valid&&s_ready)frame_mem[position]<=s_pixel;
 end
 always @(posedge clk)begin
 if(!rst_n)begin
  state<=IDLE;position<=0;frame_address<=0;histogram_address<=0;rom_address<=0;
  m_valid<=0;m_entropy_q20<=0;m_sof<=0;m_eol<=0;m_last<=0;done_error<=0;error_code<=0;
 end else if(ce)case(state)
 IDLE:if(start_valid)begin
  m_valid<=0;m_entropy_q20<=0;m_sof<=0;m_eol<=0;m_last<=0;done_error<=0;error_code<=0;
  if(!GOOD||!(cfg_size==3||cfg_size==5||cfg_size==7))begin done_error<=1;error_code<=1;state<=DONE;end
  else begin side<=cfg_size[2:0];radius<=cfg_size>>1;count<=cfg_size*cfg_size;
   bank<=cfg_size==3?0:cfg_size==5?1:2;bad_frame<=0;position<=0;x<=0;y<=0;state<=CAPTURE;end
 end
 CAPTURE:if(s_valid)begin
  if(marker_bad)bad_frame<=1;
  if(position==N-1)begin
   if(bad_frame||marker_bad)begin done_error<=1;error_code<=2;state<=DONE;end
   else begin position<=0;x<=0;y<=0;clear_index<=0;entropy_sum<=0;state<=CLEAR;end
  end else begin position<=position+1'b1;
   if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
  end
 end
 CLEAR:if(clear_index==255)begin tx<=0;ty<=0;state<=TAP_ADDR;end else clear_index<=clear_index+1'b1;
 TAP_ADDR:begin frame_address<=sample_y*WIDTH+sample_x;state<=TAP_WAIT;end
 TAP_WAIT:state<=TAP_LOAD;
 TAP_LOAD:begin histogram_address<=frame_q;state<=HIST_WAIT;end
 HIST_WAIT:state<=HIST_UPDATE;
 HIST_UPDATE:begin
  if(histogram_q>=count)begin done_error<=1;error_code<=4;state<=DONE;end
  else if(tx==side-1'b1&&ty==side-1'b1)begin scan_index<=0;state<=SCAN_ADDR;end
  else begin if(tx==side-1'b1)begin tx<=0;ty<=ty+1'b1;end else tx<=tx+1'b1;state<=TAP_ADDR;end
 end
 SCAN_ADDR:begin histogram_address<=scan_index;state<=SCAN_READ;end
 SCAN_READ:state<=SCAN_LOAD;
 SCAN_LOAD:begin rom_address<={bank,histogram_q};state<=ROM_WAIT;end
 ROM_WAIT:state<=SUM;
 SUM:begin
  entropy_sum<=entropy_sum+entropy_q;
  if(scan_index==255)begin m_entropy_q20<=entropy_sum+entropy_q;m_sof<=position==0;
   m_eol<=x==WIDTH-1;m_last<=position==N-1;m_valid<=1;state<=OUTPUT;end
  else begin scan_index<=scan_index+1'b1;state<=SCAN_ADDR;end
 end
 OUTPUT:if(m_ready)begin
  m_valid<=0;
  if(position==N-1)state<=DONE;
  else begin position<=position+1'b1;
   if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
   clear_index<=0;entropy_sum<=0;state<=CLEAR;
  end
 end
 DONE:if(done_ready)state<=IDLE;
 default:begin m_valid<=0;done_error<=1;error_code<=3;state<=DONE;end
 endcase
 end
endmodule
