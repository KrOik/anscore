// Fixed-tick RGB scanout; synchronous RAM FIFO, no timing backpressure.
module video_rgb_scanout #(parameter MAX_ACTIVE=4096,MAX_TOTAL=8192,FIFO_DEPTH=64,PREBUFFER=16)(
input wire clk,rst_n,ce,pixel_tick,start_valid,stop,abort,output wire start_ready,
input wire[15:0]cfg_h_active,cfg_h_front,cfg_h_sync,cfg_h_back,
input wire[15:0]cfg_v_active,cfg_v_front,cfg_v_sync,cfg_v_back,
input wire cfg_hsync_positive,cfg_vsync_positive,
input wire[23:0]s_pixel,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
output wire[23:0]rgb,output wire running,output wire hsync,vsync,de,sof,eol,eof,frame_end,
output wire[15:0]h_count,v_count,output wire done_valid,input wire done_ready,
output reg frame_error,output reg[7:0]error_code);
localparam IDLE=0,PREFILL=1,RUN=2,FINISH=3,DONE=4;
localparam AW=FIFO_DEPTH<=1?1:$clog2(FIFO_DEPTH);
reg[2:0]state;reg[15:0]ha,hf,hs,hb,va,vf,vs,vb,ix,iy;reg hp,vp,fatal;
reg[26:0]mem[0:FIFO_DEPTH-1];reg[26:0]q;reg qvalid;
reg[AW-1:0]wp,rp;reg[AW:0]count;
wire tr,td,te;wire[7:0]tc;
wire want=pixel_tick&&de;
wire consume=want&&qvalid&&!fatal;
wire fetch=(state==PREFILL||state==RUN||state==FINISH)&&!fatal&&(!qvalid||consume)&&count!=0;
// Do not write a full ring on its read cycle: avoids undefined same-address
// cross-port BRAM collision semantics while keeping physical timing unthrottled.
assign s_ready=(state==PREFILL||state==RUN||state==FINISH)&&!fatal&&count<FIFO_DEPTH;
wire push=ce&&s_valid&&s_ready;
wire markers=s_sof==(ix==0&&iy==0)&&s_eol==(ix==ha-1)&&s_last==(ix==ha-1&&iy==va-1);
wire marker_fault=push&&!markers;
wire underflow=want&&!qvalid&&!fatal;
wire launch=state==PREFILL&&!fatal&&!(ce&&(stop||abort))&&!(push&&!markers)&&(count+qvalid>=PREBUFFER);
assign rgb=de&&qvalid&&!fatal?q[23:0]:24'b0;
assign start_ready=state==IDLE;assign done_valid=state==DONE;
video_timing_generator #(.MAX_ACTIVE(MAX_ACTIVE),.MAX_TOTAL(MAX_TOTAL))timing(
.clk(clk),.rst_n(rst_n),.ce(1'b1),.pixel_tick(pixel_tick),.start_valid(launch),.start_ready(tr),
.stop(state==FINISH||(ce&&(stop||abort))||marker_fault||underflow),.abort(1'b0),.cfg_h_active(ha),.cfg_h_front(hf),.cfg_h_sync(hs),.cfg_h_back(hb),
.cfg_v_active(va),.cfg_v_front(vf),.cfg_v_sync(vs),.cfg_v_back(vb),.cfg_hsync_positive(hp),.cfg_vsync_positive(vp),
.running(running),.done_valid(td),.done_ready(state==DONE&&ce&&done_ready),.frame_error(te),.error_code(tc),
.h_count(h_count),.v_count(v_count),.hsync(hsync),.vsync(vsync),.de(de),.sof(sof),.eol(eol),.eof(eof),.frame_end(frame_end));
always @(posedge clk)begin if(push&&markers)mem[wp]<={s_sof,s_eol,s_last,s_pixel};if(fetch)q<=mem[rp];end
always @(posedge clk)begin
if(!rst_n)begin state<=IDLE;ha<=0;hf<=0;hs<=0;hb<=0;va<=0;vf<=0;vs<=0;vb<=0;hp<=0;vp<=0;ix<=0;iy<=0;wp<=0;rp<=0;count<=0;qvalid<=0;fatal<=0;frame_error<=0;error_code<=0;end
else begin
if(consume)qvalid<=0;
if(fetch)begin qvalid<=1;rp<=rp==FIFO_DEPTH-1?0:rp+1'b1;end
if(push&&markers)begin wp<=wp==FIFO_DEPTH-1?0:wp+1'b1;if(ix==ha-1)begin ix<=0;iy<=iy==va-1?0:iy+1'b1;end else ix<=ix+1'b1;end
case({push&&markers,fetch})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
case(state)
IDLE:if(ce&&start_valid)begin
ha<=cfg_h_active;hf<=cfg_h_front;hs<=cfg_h_sync;hb<=cfg_h_back;va<=cfg_v_active;vf<=cfg_v_front;vs<=cfg_v_sync;vb<=cfg_v_back;hp<=cfg_hsync_positive;vp<=cfg_vsync_positive;
ix<=0;iy<=0;wp<=0;rp<=0;count<=0;qvalid<=0;fatal<=0;frame_error<=0;error_code<=0;
if(FIFO_DEPTH<2||FIFO_DEPTH>4096||PREBUFFER<1||PREBUFFER>FIFO_DEPTH)begin state<=DONE;frame_error<=1;error_code<=1;end
else if(MAX_ACTIVE<1||MAX_ACTIVE>4096||MAX_TOTAL<1||MAX_TOTAL>65535||cfg_h_active==0||cfg_v_active==0||cfg_h_active>MAX_ACTIVE||cfg_v_active>MAX_ACTIVE||cfg_h_sync==0||cfg_v_sync==0||({2'b0,cfg_h_active}+cfg_h_front+cfg_h_sync+cfg_h_back)>MAX_TOTAL||({2'b0,cfg_v_active}+cfg_v_front+cfg_v_sync+cfg_v_back)>MAX_TOTAL)begin state<=DONE;frame_error<=1;error_code<=1;end
else state<=PREFILL;end
PREFILL:if(launch)state<=RUN;
RUN:if(td)begin state<=DONE;qvalid<=0;count<=0;end
FINISH:if(td)begin state<=DONE;qvalid<=0;count<=0;end
DONE:if(ce&&done_ready)state<=IDLE;
endcase
if(state==PREFILL||state==RUN||state==FINISH)begin
if(marker_fault)begin fatal<=1;frame_error<=1;if(!frame_error)error_code<=2;qvalid<=0;count<=0;state<=state==PREFILL?DONE:FINISH;end
if(underflow)begin fatal<=1;frame_error<=1;if(!frame_error)error_code<=4;qvalid<=0;count<=0;state<=FINISH;end
if(ce&&abort)begin fatal<=1;frame_error<=1;if(!frame_error)error_code<=3;qvalid<=0;count<=0;if(state==PREFILL)state<=DONE;else state<=FINISH;end
else if(ce&&stop)begin if(state==PREFILL)begin state<=DONE;qvalid<=0;count<=0;end else state<=FINISH;end
end
end end
endmodule
