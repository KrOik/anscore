// Binary-edge circular Hough: unique integer midpoint offsets, full center/radius
// accumulator, global score maxima and Euclidean-center / radius-bin NMS.
module hough_circles_frame #(parameter WIDTH=16,HEIGHT=16,MAX_RADIUS=15,MAX_CIRCLES=8,
 parameter OFFSET_FILE="offsets.mem",META_FILE="metadata.mem")(
 input wire clk,rst,ce,start_valid,output wire start_ready,
 input wire[5:0] cfg_min_radius,cfg_max_radius,cfg_max_circles,cfg_center_nms,cfg_radius_nms,
 input wire[7:0] cfg_vote_threshold,
 input wire s_edge,s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output wire[5:0] m_x,m_y,m_radius,m_index,
 output wire[7:0] m_votes,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[7:0] error_code,
 output reg[5:0] done_count,output wire busy
);
 localparam N=WIDTH*HEIGHT,DEPTH=N*MAX_RADIUS,AW=DEPTH<2?1:$clog2(DEPTH);
 localparam IDLE=0,CLEAR=1,INPUT_PIXEL=2,RADIUS_READ=3,RADIUS_CAPTURE=4,OFFSET_READ=5,OFFSET_CAPTURE=6,
 VOTE_READ=7,VOTE_CAPTURE=8,VOTE_WRITE=9,OFFSET_NEXT=10,PIXEL_NEXT=11,CAPTURE_FINISH=12,
 SCAN_BEGIN=13,SCAN_READ=14,SCAN_CAPTURE=15,SCAN_FINISH=16,HOLD=17,NMS_BEGIN=18,NMS_SCAN=19,DONE=20;
 reg[4:0] state;
 reg[7:0] accumulator[0:DEPTH-1],accumulator_q,vote_value;
 reg[11:0] offset_rom[0:4095],offset_q;
 reg[19:0] metadata_rom[0:31],metadata_q;
 reg[5:0] minimum_radius,maximum_radius,maximum_circles,center_nms,radius_nms;
 reg[7:0] threshold;
 reg[AW-1:0] clear_address,vote_address,scan_address;
 reg[5:0] pixel_x,pixel_y,current_radius,scan_x,scan_y,scan_radius;
 reg[11:0] offset_address;
 reg[7:0] offsets_left;
 reg[5:0] best_x,best_y,best_radius;
 reg[7:0] best_votes;
 reg[5:0] emitted;
 wire last_pixel=pixel_x==WIDTH-1&&pixel_y==HEIGHT-1;
 wire last_scan=scan_x==WIDTH-1&&scan_y==HEIGHT-1&&scan_radius==maximum_radius;
 wire signed[8:0] center_x=$signed({3'b0,pixel_x})-$signed({{3{offset_q[5]}},offset_q[5:0]});
 wire signed[8:0] center_y=$signed({3'b0,pixel_y})-$signed({{3{offset_q[11]}},offset_q[11:6]});
 function[AW-1:0] radius_base;input[5:0] radius;integer k;reg[AW-1:0] v;
 begin v=0;for(k=0;k<6;k=k+1)if(radius[k])v=v+(N<<k);radius_base=v;end endfunction
 function[AW-1:0] row_base;input[5:0] y;integer k;reg[AW-1:0] v;
 begin v=0;for(k=0;k<6;k=k+1)if(y[k])v=v+(WIDTH<<k);row_base=v;end endfunction
 function[11:0] square;input signed[6:0] value;integer k;reg[6:0] magnitude;reg[11:0] v;
 begin magnitude=value<0?-value:value;v=0;for(k=0;k<6;k=k+1)if(magnitude[k])v=v+({5'b0,magnitude}<<k);square=v;end endfunction
 wire signed[6:0] distance_x=$signed({1'b0,scan_x})-$signed({1'b0,best_x});
 wire signed[6:0] distance_y=$signed({1'b0,scan_y})-$signed({1'b0,best_y});
 wire[5:0] distance_radius=scan_radius>best_radius?scan_radius-best_radius:best_radius-scan_radius;
 wire suppress=distance_radius<=radius_nms&&({1'b0,square(distance_x)}+square(distance_y))<={1'b0,square($signed({1'b0,center_nms}))};
 wire[AW-1:0] ram_address=state==CLEAR?clear_address:((state==VOTE_READ||state==VOTE_CAPTURE||state==VOTE_WRITE)?vote_address:scan_address);
 wire valid_config=cfg_min_radius>=1&&cfg_max_radius>=cfg_min_radius&&cfg_max_radius<=MAX_RADIUS&&
 cfg_max_circles>=1&&cfg_max_circles<=MAX_CIRCLES&&cfg_vote_threshold>=1&&cfg_center_nms<=31&&cfg_radius_nms<=31;
 assign start_ready=!rst&&ce&&state==IDLE;assign s_ready=!rst&&ce&&state==INPUT_PIXEL;
 assign m_valid=!rst&&state==HOLD;assign m_x=best_x;assign m_y=best_y;assign m_radius=best_radius;assign m_votes=best_votes;assign m_index=emitted;
 assign done_valid=!rst&&state==DONE;assign busy=state!=IDLE;
 initial begin
 if(WIDTH<1||HEIGHT<1||WIDTH>32||HEIGHT>32||N>1024||MAX_RADIUS<1||MAX_RADIUS>31||MAX_CIRCLES<1||MAX_CIRCLES>32)$fatal(1,"invalid Hough-circle static parameters");
 $readmemh(OFFSET_FILE,offset_rom);$readmemh(META_FILE,metadata_rom);
 end
 // A single physical read/write address for the accumulator enables BRAM.
 always @(posedge clk)if(ce&&!rst)begin
 if(state==VOTE_READ||state==SCAN_READ)accumulator_q<=accumulator[ram_address];
 if(state==CLEAR||(state==NMS_SCAN&&suppress))accumulator[ram_address]<=0;
 else if(state==VOTE_WRITE)accumulator[ram_address]<=vote_value;
 if(state==RADIUS_READ)metadata_q<=metadata_rom[current_radius];
 if(state==OFFSET_READ)offset_q<=offset_rom[offset_address];
 end
 task advance_scan;
 begin scan_address<=scan_address+1'b1;
 if(scan_x==WIDTH-1)begin scan_x<=0;if(scan_y==HEIGHT-1)begin scan_y<=0;scan_radius<=scan_radius+1'b1;end else scan_y<=scan_y+1'b1;end
 else scan_x<=scan_x+1'b1;end endtask
 always @(posedge clk)begin
 if(rst)begin
 state<=IDLE;minimum_radius<=1;maximum_radius<=1;maximum_circles<=1;center_nms<=0;radius_nms<=0;threshold<=1;
 clear_address<=0;vote_address<=0;scan_address<=0;pixel_x<=0;pixel_y<=0;current_radius<=1;scan_x<=0;scan_y<=0;scan_radius<=1;
 offset_address<=0;offsets_left<=0;best_x<=0;best_y<=0;best_radius<=0;best_votes<=0;emitted<=0;vote_value<=0;
 done_error<=0;error_code<=0;done_count<=0;
 end else if(ce)case(state)
 IDLE:if(start_valid)begin
 done_error<=0;error_code<=0;done_count<=0;emitted<=0;
 if(!valid_config)begin done_error<=1;error_code<=8'h10;state<=DONE;end
 else begin minimum_radius<=cfg_min_radius;maximum_radius<=cfg_max_radius;maximum_circles<=cfg_max_circles;center_nms<=cfg_center_nms;radius_nms<=cfg_radius_nms;threshold<=cfg_vote_threshold;
 clear_address<=0;pixel_x<=0;pixel_y<=0;state<=CLEAR;end end
 CLEAR:if(clear_address==DEPTH-1)state<=INPUT_PIXEL;else clear_address<=clear_address+1'b1;
 INPUT_PIXEL:if(s_valid)begin
 if(s_sof!=(pixel_x==0&&pixel_y==0)||s_eol!=(pixel_x==WIDTH-1))begin done_error<=1;error_code<=error_code|{4'b0,(s_eol&&pixel_x!=WIDTH-1),(!s_eol&&pixel_x==WIDTH-1),(s_sof&&(pixel_x!=0||pixel_y!=0)),(!s_sof&&pixel_x==0&&pixel_y==0)};end
 if(s_edge)begin current_radius<=minimum_radius;state<=RADIUS_READ;end else state<=PIXEL_NEXT;end
 RADIUS_READ:state<=RADIUS_CAPTURE;
 RADIUS_CAPTURE:begin offset_address<=metadata_q[11:0];offsets_left<=metadata_q[19:12];state<=OFFSET_READ;end
 OFFSET_READ:state<=OFFSET_CAPTURE;
 OFFSET_CAPTURE:begin
 if(center_x>=0&&center_x<WIDTH&&center_y>=0&&center_y<HEIGHT)begin vote_address<=radius_base(current_radius-1'b1)+row_base(center_y[5:0])+center_x[5:0];state<=VOTE_READ;end
 else state<=OFFSET_NEXT;end
 VOTE_READ:state<=VOTE_CAPTURE;
 VOTE_CAPTURE:begin
 if(accumulator_q==255)begin vote_value<=255;done_error<=1;error_code<=error_code|8'h20;end else vote_value<=accumulator_q+1'b1;
 state<=VOTE_WRITE;end
 VOTE_WRITE:state<=OFFSET_NEXT;
 OFFSET_NEXT:begin
 if(offsets_left==1)begin if(current_radius==maximum_radius)state<=PIXEL_NEXT;else begin current_radius<=current_radius+1'b1;state<=RADIUS_READ;end end
 else begin offsets_left<=offsets_left-1'b1;offset_address<=offset_address+1'b1;state<=OFFSET_READ;end end
 PIXEL_NEXT:begin if(last_pixel)state<=CAPTURE_FINISH;else begin if(pixel_x==WIDTH-1)begin pixel_x<=0;pixel_y<=pixel_y+1'b1;end else pixel_x<=pixel_x+1'b1;state<=INPUT_PIXEL;end end
 CAPTURE_FINISH:if(done_error)state<=DONE;else state<=SCAN_BEGIN;
 SCAN_BEGIN:begin scan_x<=0;scan_y<=0;scan_radius<=minimum_radius;scan_address<=radius_base(minimum_radius-1'b1);best_votes<=0;state<=SCAN_READ;end
 SCAN_READ:state<=SCAN_CAPTURE;
 SCAN_CAPTURE:begin
 if(accumulator_q>best_votes)begin best_votes<=accumulator_q;best_x<=scan_x;best_y<=scan_y;best_radius<=scan_radius;end
 if(last_scan)state<=SCAN_FINISH;else begin advance_scan;state<=SCAN_READ;end end
 SCAN_FINISH:if(best_votes>=threshold)state<=HOLD;else state<=DONE;
 HOLD:if(m_ready)begin done_count<=emitted+1'b1;if(emitted+1'b1>=maximum_circles)state<=DONE;else begin emitted<=emitted+1'b1;state<=NMS_BEGIN;end end
 NMS_BEGIN:begin scan_x<=0;scan_y<=0;scan_radius<=minimum_radius;scan_address<=radius_base(minimum_radius-1'b1);state<=NMS_SCAN;end
 NMS_SCAN:if(last_scan)state<=SCAN_BEGIN;else advance_scan;
 DONE:if(done_ready)state<=IDLE;
 default:begin done_error<=1;error_code<=error_code|8'h40;state<=DONE;end
 endcase
 end
endmodule
