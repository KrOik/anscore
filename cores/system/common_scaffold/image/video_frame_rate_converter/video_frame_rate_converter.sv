// Bounded whole-frame nearest/latest FRC. Three synchronous pixel RAM banks.
module video_frame_rate_converter #(
 parameter PIXEL_W=24,MAX_WIDTH=32,MAX_HEIGHT=32
)(input wire clk,rst_n,ce,start_valid,abort,cadence_tick,output wire start_ready,
 input wire[15:0]cfg_width,cfg_height,cfg_rate_num,cfg_rate_den,
 input wire[PIXEL_W-1:0]s_pixel,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output wire[PIXEL_W-1:0]m_pixel,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,output wire[31:0]m_frame_id,
 output wire running,done_valid,input wire done_ready,output reg[7:0]error_code,
 output reg[31:0]published_count,output_count,dropped_count,repeated_count,underrun_count,tick_overrun_count);
 localparam CAP=MAX_WIDTH*MAX_HEIGHT,AW=CAP<2?1:$clog2(CAP),MW=3*CAP<2?1:$clog2(3*CAP);
 localparam PARAM_OK=PIXEL_W>=1&&PIXEL_W<=32&&MAX_WIDTH>=1&&MAX_WIDTH<=256&&MAX_HEIGHT>=1&&MAX_HEIGHT<=256&&CAP<=4096&&CAP*PIXEL_W<=98304;
 reg run,stop_pending,done;reg[15:0]width,height,rate_num,rate_den,phase;
 reg[1:0]capture_bank,latest_bank,out_bank;
 reg latest_valid,latest_selected,out_active,last_selected_valid;
 reg[31:0]latest_id,out_id,last_selected_id;
 reg[15:0]in_x,in_y,read_x,read_y;
 reg[AW:0]write_index,read_index;reg[AW:0]pixels;
 reg[PIXEL_W-1:0]mem[0:3*CAP-1];reg[PIXEL_W-1:0]q;
 reg qvalid,qsof,qeol,qlast;
 wire[16:0]phase_sum={1'b0,phase}+{1'b0,rate_num};
 wire due=run&&!stop_pending&&cadence_tick&&phase_sum>={1'b0,rate_den}&&!(ce&&abort);
 wire launch=due&&!out_active&&latest_valid;
 wire consume=ce&&m_ready&&qvalid;
 wire read_en=out_active&&(!qvalid||consume)&&read_index<pixels;
 wire push=ce&&s_valid&&s_ready;
 wire markers=s_sof==(in_x==0&&in_y==0)&&s_eol==(in_x==width-1)&&s_last==(in_x==width-1&&in_y==height-1);
 wire publish=push&&markers&&s_last;
 wire protect_valid=out_active||launch;
 wire[1:0]protected_bank=out_active?out_bank:latest_bank;
 wire[1:0]free_bank=(capture_bank!=0&&(!protect_valid||protected_bank!=0))?0:(capture_bank!=1&&(!protect_valid||protected_bank!=1))?1:2;
 wire[MW-1:0]write_address=capture_bank*CAP+write_index;
 wire[MW-1:0]read_address=out_bank*CAP+read_index;
 assign s_ready=run&&!stop_pending&&!(ce&&abort);
 assign start_ready=!run&&!done;assign running=run;assign done_valid=done;
 assign m_pixel=q;assign m_valid=qvalid;assign m_sof=qsof;assign m_eol=qeol;assign m_last=qlast;assign m_frame_id=out_id;
 always @(posedge clk)begin
  if(push&&markers)mem[write_address]<=s_pixel;
  if(read_en)q<=mem[read_address];
 end
 always @(posedge clk)begin
 if(!rst_n)begin
  run<=0;stop_pending<=0;done<=0;error_code<=0;width<=0;height<=0;rate_num<=0;rate_den<=1;phase<=0;
  capture_bank<=0;latest_bank<=0;out_bank<=0;latest_valid<=0;latest_selected<=0;out_active<=0;last_selected_valid<=0;latest_id<=0;out_id<=0;last_selected_id<=0;
  in_x<=0;in_y<=0;read_x<=0;read_y<=0;write_index<=0;read_index<=0;pixels<=0;qvalid<=0;qsof<=0;qeol<=0;qlast<=0;
  published_count<=0;output_count<=0;dropped_count<=0;repeated_count<=0;underrun_count<=0;tick_overrun_count<=0;
 end else begin
  if(done&&ce&&done_ready)done<=0;
  if(start_ready&&ce&&start_valid)begin
   error_code<=0;stop_pending<=0;width<=cfg_width;height<=cfg_height;rate_num<=cfg_rate_num;rate_den<=cfg_rate_den;phase<=0;
   capture_bank<=0;latest_bank<=0;out_bank<=0;latest_valid<=0;latest_selected<=0;out_active<=0;last_selected_valid<=0;latest_id<=0;out_id<=0;last_selected_id<=0;
   in_x<=0;in_y<=0;read_x<=0;read_y<=0;write_index<=0;read_index<=0;pixels<=cfg_width*cfg_height;qvalid<=0;
   published_count<=0;output_count<=0;dropped_count<=0;repeated_count<=0;underrun_count<=0;tick_overrun_count<=0;
   if(!PARAM_OK||cfg_width==0||cfg_height==0||cfg_width>MAX_WIDTH||cfg_height>MAX_HEIGHT||cfg_rate_num==0||cfg_rate_den==0||cfg_rate_num>cfg_rate_den)begin done<=1;error_code<=1;end
   else run<=1;
  end else if(run)begin
   if(!stop_pending&&ce&&abort)begin stop_pending<=1;error_code<=9;end
   if(!stop_pending&&cadence_tick&&!(ce&&abort))begin
    if(phase_sum>={1'b0,rate_den})phase<=phase_sum-rate_den;else phase<=phase_sum;
    if(due)begin
     if(out_active)tick_overrun_count<=tick_overrun_count+1'b1;
     else if(!latest_valid)underrun_count<=underrun_count+1'b1;
    end
   end
   if(publish)begin
    latest_selected<=0;
    if(latest_valid&&!latest_selected&&!launch)dropped_count<=dropped_count+1'b1;
   end else if(launch)latest_selected<=1;
   if(push)begin
    if(!markers)begin stop_pending<=1;error_code<=2;end
    else if(s_last)begin
     latest_valid<=1;latest_bank<=capture_bank;latest_id<=published_count;published_count<=published_count+1'b1;
     capture_bank<=free_bank;write_index<=0;in_x<=0;in_y<=0;
    end else begin
     write_index<=write_index+1'b1;
     if(s_eol)begin in_x<=0;in_y<=in_y+1'b1;end else in_x<=in_x+1'b1;
    end
   end
   if(launch)begin
    out_active<=1;out_bank<=latest_bank;out_id<=latest_id;read_index<=0;read_x<=0;read_y<=0;
    if(last_selected_valid)begin
     if(latest_id==last_selected_id)repeated_count<=repeated_count+1'b1;

    end
    last_selected_valid<=1;last_selected_id<=latest_id;
   end
   if(consume)begin qvalid<=0;if(qlast)begin out_active<=0;output_count<=output_count+1'b1;end end
   if(read_en)begin
    qvalid<=1;qsof<=read_index==0;qeol<=read_x==width-1;qlast<=read_index==pixels-1;
    read_index<=read_index+1'b1;
    if(read_x==width-1)begin read_x<=0;read_y<=read_y+1'b1;end else read_x<=read_x+1'b1;
   end
   // Stop never withdraws a frame: finish all of its synchronous reads/handshakes.
   if(stop_pending&&!out_active&&!qvalid)begin run<=0;done<=1;end
  end
 end end
endmodule
