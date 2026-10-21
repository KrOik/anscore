// Host-loaded rectification/remap. Original RTL; no automatic calibration.
module stereo_rectify #(
 parameter integer BITS=8,SRC_WIDTH=16,SRC_HEIGHT=12,DST_WIDTH=16,DST_HEIGHT=12,
 parameter integer CV_COMPAT=0
)(input wire clk,rst_n,ce,
 input wire map_begin_valid,output wire map_begin_ready,
 input wire signed[23:0] map_x,map_y,input wire map_valid,map_last,output wire map_ready,
 input wire map_commit_valid,output wire map_commit_ready,input wire map_abort,
 output wire map_done_valid,input wire map_done_ready,output reg map_done_error,output reg[7:0] map_error_code,
 output reg map_active_valid,
 input wire start_valid,output wire start_ready,input wire abort,input wire[BITS-1:0] cfg_fill,
 input wire[BITS-1:0] s_data,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output wire[BITS-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,m_in_bounds,input wire m_ready,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[7:0] error_code,output wire busy);
 localparam integer SN=(SRC_WIDTH>0&&SRC_HEIGHT>0)?SRC_WIDTH*SRC_HEIGHT:1;
 localparam integer DN=(DST_WIDTH>0&&DST_HEIGHT>0)?DST_WIDTH*DST_HEIGHT:1;
 localparam integer SW=$clog2(SN+1),DW=$clog2(DN+1),F=CV_COMPAT?5:8;
 localparam IDLE=0,CAP=1,MAP_ADDR=2,MAP_VALUE=3,PREP=4,TAP_ADDR=5,TAP_VALUE=6,CALC=7,HOLD=8,DONE=9;
 reg[3:0] state;reg[1:0] map_state; //0 idle,1 loading,2 complete,3 held terminal
 reg active_bank,write_bank,frame_bank;reg[DW-1:0] map_count;
 reg[47:0] maps[0:2*DN-1];reg[47:0] map_q;
 reg[BITS-1:0] frame[0:SN-1],fill_q,out_q,tap_q,taps[0:3];
 reg[SW-1:0] in_pos;reg[DW-1:0] out_pos;reg[15:0] in_x,in_y,out_x,out_y;
 reg signed[23:0] sx,sy;reg signed[23:0] base_x,base_y;
 reg[7:0] frac_x,frac_y;reg[1:0] tap;
 reg tap_inside,all_inside,out_inside;
 wire signed[24:0] tap_x=$signed(base_x)+$signed({24'b0,tap[0]});
 wire signed[24:0] tap_y=$signed(base_y)+$signed({24'b0,tap[1]});
 wire tap_in_range=(tap_x>=0&&tap_x<SRC_WIDTH&&tap_y>=0&&tap_y<SRC_HEIGHT);
 wire weight_nonzero=(!tap[0]||frac_x!=0)&&(!tap[1]||frac_y!=0);
 wire[8:0] wx0=(9'd1<<F)-frac_x,wy0=(9'd1<<F)-frac_y;
 wire[8:0] wx1=frac_x,wy1=frac_y;
 wire[BITS+17:0] sum=taps[0]*wx0*wy0+taps[1]*wx1*wy0+taps[2]*wx0*wy1+taps[3]*wx1*wy1;
 wire[BITS+17:0] interpolated=(sum+(1<<(2*F-1)))>>(2*F);
 assign map_begin_ready=rst_n&&ce&&!map_abort&&map_state==0;
 assign map_ready=rst_n&&ce&&!map_abort&&!map_commit_valid&&map_state==1;
 assign map_commit_ready=rst_n&&ce&&!map_abort&&state==IDLE&&(map_state==1||map_state==2);
 assign map_done_valid=map_state==3;
 assign start_ready=rst_n&&ce&&!abort&&state==IDLE&&!(map_commit_valid&&map_commit_ready);
 assign s_ready=rst_n&&ce&&!abort&&state==CAP;
 assign busy=state!=IDLE&&state!=DONE;
 assign done_valid=state==DONE;
 assign m_valid=state==HOLD&&!abort;assign m_data=out_q;assign m_in_bounds=out_inside;
 assign m_sof=out_pos==0;assign m_eol=out_x==DST_WIDTH-1;assign m_last=out_pos==DN-1;
 function signed[23:0] phase_coord;input signed[23:0] a;reg signed[23:0] q;begin
 if(CV_COMPAT)begin q=a>>>3;if(a[2:0]>4||(a[2:0]==4&&q[0]))q=q+1;phase_coord=q;end
 else phase_coord=a;
 end endfunction
 task fail;input[7:0] code;begin state<=DONE;done_error<=1;error_code<=code;end endtask
 task map_fail;input[7:0] code;begin map_state<=3;map_done_error<=1;map_error_code<=code;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;map_state<=0;active_bank<=0;write_bank<=1;frame_bank<=0;
 map_active_valid<=0;map_done_error<=0;map_error_code<=0;done_error<=0;error_code<=0;
 in_pos<=0;out_pos<=0;out_x<=0;out_y<=0;end
 else if(ce)begin
 // Independent inactive-map writer; active map is never modified during a frame.
 if(map_abort&&(map_state==1||map_state==2))map_fail(8'h93);
 else case(map_state)
 0:if(map_begin_valid&&!map_abort)begin write_bank<=!active_bank;map_count<=0;map_state<=1;map_done_error<=0;map_error_code<=0;end
 1:begin
 if(map_commit_valid&&map_commit_ready)map_fail(8'h82);
 else if(map_valid&&!map_abort&&!map_commit_valid)begin
 maps[write_bank*DN+map_count]<={map_x,map_y};
 if(map_last!=(map_count==DN-1))map_fail(8'h81);
 else if(map_count==DN-1)map_state<=2;
 else map_count<=map_count+1;
 end end
 2:if(map_commit_valid&&map_commit_ready)begin active_bank<=write_bank;map_active_valid<=1;map_state<=3;map_done_error<=0;map_error_code<=0;end
 3:if(map_done_ready)map_state<=0;
 endcase
 if(abort&&state!=IDLE&&state!=DONE)fail(8'h93);
 else case(state)
 IDLE:if(start_valid&&start_ready)begin
 done_error<=0;error_code<=0;fill_q<=cfg_fill;in_pos<=0;in_x<=0;in_y<=0;out_pos<=0;out_x<=0;out_y<=0;frame_bank<=active_bank;
 if((BITS!=8&&BITS!=10&&BITS!=12)||SRC_WIDTH<1||SRC_HEIGHT<1||DST_WIDTH<1||DST_HEIGHT<1||SRC_WIDTH>256||SRC_HEIGHT>256||DST_WIDTH>256||DST_HEIGHT>256||(CV_COMPAT!=0&&CV_COMPAT!=1))fail(8'h80);
 else if(!map_active_valid)fail(8'h82);else state<=CAP;
 end
 CAP:if(s_valid)begin
 if(s_sof!=(in_pos==0)||s_eol!=(in_x==SRC_WIDTH-1)||s_last!=(in_pos==SN-1))fail(8'h81);
 else begin frame[in_pos]<=s_data;if(in_pos==SN-1)state<=MAP_ADDR;
 else begin in_pos<=in_pos+1;if(in_x==SRC_WIDTH-1)begin in_x<=0;in_y<=in_y+1;end else in_x<=in_x+1;end end end
 MAP_ADDR:begin map_q<=maps[frame_bank*DN+out_pos];state<=MAP_VALUE;end
 MAP_VALUE:begin sx<=phase_coord($signed(map_q[47:24]));sy<=phase_coord($signed(map_q[23:0]));state<=PREP;end
 PREP:begin base_x<=sx>>>F;base_y<=sy>>>F;frac_x<=sx&((1<<F)-1);frac_y<=sy&((1<<F)-1);tap<=0;all_inside<=1;state<=TAP_ADDR;end
 TAP_ADDR:begin tap_inside<=tap_in_range;
 if(tap_in_range)tap_q<=frame[tap_y*SRC_WIDTH+tap_x];else tap_q<=fill_q;
 if(weight_nonzero&&!tap_in_range)all_inside<=0;
 state<=TAP_VALUE;end
 TAP_VALUE:begin taps[tap]<=tap_q;if(tap==3)state<=CALC;else begin tap<=tap+1;state<=TAP_ADDR;end end
 CALC:begin out_q<=interpolated[BITS-1:0];out_inside<=all_inside;state<=HOLD;end
 HOLD:if(m_ready)begin if(out_pos==DN-1)state<=DONE;
 else begin out_pos<=out_pos+1;if(out_x==DST_WIDTH-1)begin out_x<=0;out_y<=out_y+1;end else out_x<=out_x+1;state<=MAP_ADDR;end end
 DONE:if(done_ready)state<=IDLE;
 default:fail(8'h94);
 endcase
 end end
endmodule

