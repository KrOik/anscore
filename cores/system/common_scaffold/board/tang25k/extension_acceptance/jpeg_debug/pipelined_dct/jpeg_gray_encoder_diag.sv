// Complete grayscale raster -> baseline sequential JFIF encoder integration.
// DCT/quantization/entropy/header/raster algorithms reuse existing library RTL.
module jpeg_gray_encoder_diag #(parameter WIDTH=16,HEIGHT=16)(
 input wire clk,rst_n,ce,
 input wire table_valid,output wire table_ready,input wire[5:0]table_index,input wire[7:0]table_value,
 input wire cfg_valid,output wire cfg_ready,input wire[15:0]cfg_restart_interval,
 output reg cfg_done,cfg_error,
 input wire start_valid,output wire start_ready,input wire abort,
 input wire[7:0]s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire[7:0]m_data,output wire m_valid,m_last,input wire m_ready,
 output wire[127:0]debug_state,output wire done_valid,input wire done_ready,output reg[7:0]error_code,output wire busy);
 localparam IDLE=0,CONFIG=1,HEADER_CMD=2,HEADER_DATA=3,APP0=4,
 START=5,RUN=6,EOI_CMD=7,EOI_DATA=8,DONE=9,FAILED=10,LOCKED=11;
 localparam BLOCKS=((WIDTH+7)/8)*((HEIGHT+7)/8),PIXELS=WIDTH*HEIGHT;
 reg[3:0]state;reg configured,h_seen,s_seen,cfg_fault;
 reg[15:0]interval_blocks,pending_interval;reg[16:0]captured;
 reg[15:0]capture_x;
 reg[1:0]soi_bytes;reg[4:0]app_index;
 wire config_window=state==IDLE;
 wire htr,str,hcr,scr,hcd,scd,hce,sce;
 wire hcmdready,hcmddone,hcmderror,hvalid,hlast;wire[7:0]hdata;
 wire hphase=state==HEADER_CMD||state==HEADER_DATA||state==EOI_CMD||state==EOI_DATA;
 wire scan_start_ready,scvalid,scdone;wire[7:0]scdata,scerror;
 wire rsv,rsr,rfirst,rlast,rframe,rerror,scan_pixel_ready;wire[7:0]rdata;
 assign cfg_ready=rst_n&&ce&&config_window&&hcr&&scr;
 assign table_ready=rst_n&&ce&&config_window&&!cfg_valid&&htr&&str;
 jpeg_gray_headers headers(.clk(clk),.rst_n(rst_n),.ce(ce),
 .table_valid(table_valid&&config_window&&!cfg_valid&&str),.table_ready(htr),.table_index(table_index),.table_value(table_value),
 .cfg_valid(cfg_valid&&config_window&&scr),.cfg_ready(hcr),.cfg_width(16'(WIDTH)),.cfg_height(16'(HEIGHT)),.cfg_restart_interval(cfg_restart_interval),
 .cfg_done(hcd),.cfg_error(hce),.cmd_valid(state==HEADER_CMD||state==EOI_CMD),.cmd_ready(hcmdready),.cmd(state==EOI_CMD?2'd1:2'd0),.rst_index(3'd0),
 .m_data(hdata),.m_valid(hvalid),.m_last(hlast),.m_ready(m_ready&&hphase),.cmd_done(hcmddone),.cmd_error(hcmderror),.busy());
 wire[23:0]rdebug;wire[63:0]scdebug;
 img_raster_blocks_diag #(.BITS(8),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TO_BLOCK(1)) raster(.debug_state(rdebug),
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(s_data),.s_valid(s_valid&&state==RUN&&captured<PIXELS),.s_ready(rsr),.s_sof(s_sof),.s_eol(s_eol),
 .s_block_first(1'b0),.s_block_last(1'b0),.m_data(rdata),.m_valid(rsv),.m_ready(state==RUN&&scan_pixel_ready),
 .m_sof(),.m_eol(),.m_block_first(rfirst),.m_block_last(rlast),.m_frame_last(rframe),.protocol_error(rerror),.error_pulse());
 jpeg_grayscale_scan_diag scan(.debug_state(scdebug),.clk(clk),.rst_n(rst_n),.ce(ce),
 .table_valid(table_valid&&config_window&&!cfg_valid&&htr),.table_ready(str),.table_index(table_index),.table_value(table_value),
 .cfg_valid(cfg_valid&&config_window&&hcr),.cfg_ready(scr),.cfg_done(scd),.cfg_error(sce),
 .start_valid(state==START),.start_ready(scan_start_ready),.cfg_total_blocks(32'(BLOCKS)),.cfg_restart_interval({16'b0,interval_blocks}),
 .abort(abort||state==FAILED||state==LOCKED),.s_data(rdata),.s_valid(rsv&&state==RUN),.s_ready(scan_pixel_ready),
 .s_block_first(rfirst),.s_block_last(rlast),.s_frame_last(rframe),
 .m_data(scdata),.m_valid(scvalid),.m_ready(m_ready&&state==RUN),.m_marker(),.m_scan_last(),
 .done_valid(scdone),.done_ready(state==RUN),.error_code(scerror),.busy());
 function[7:0]app_byte;input[4:0]i;begin case(i)
 0:app_byte=8'hff;1:app_byte=8'he0;2:app_byte=0;3:app_byte=16;
 4:app_byte="J";5:app_byte="F";6:app_byte="I";7:app_byte="F";
 8:app_byte=0;9:app_byte=1;10:app_byte=1;11:app_byte=0;
 12:app_byte=0;13:app_byte=1;14:app_byte=0;15:app_byte=1;16:app_byte=0;17:app_byte=0;
 default:app_byte=0;endcase end endfunction
 assign start_ready=rst_n&&ce&&state==IDLE&&configured&&!cfg_valid&&!table_valid&&scan_start_ready;
 assign s_ready=rst_n&&ce&&state==RUN&&captured<PIXELS&&rsr;
 assign m_valid=rst_n&&((state==APP0)||(hphase&&hvalid)||(state==RUN&&scvalid));
 assign m_data=state==APP0?app_byte(app_index):hphase?hdata:scdata;
 assign m_last=m_valid&&(state==EOI_CMD||state==EOI_DATA)&&hlast;
 assign done_valid=rst_n&&(state==DONE||state==FAILED);
 assign busy=state!=IDLE;
 assign debug_state={scdebug,rdebug,captured,state,scerror,rerror,scan_start_ready,rsr,rsv,scan_pixel_ready,6'b0};
 initial if(WIDTH<1||HEIGHT<1||WIDTH>256||HEIGHT>256||WIDTH*HEIGHT>16384)$fatal(1,"invalid grayscale JPEG geometry");
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;configured<=0;h_seen<=0;s_seen<=0;cfg_fault<=0;interval_blocks<=0;pending_interval<=0;captured<=0;capture_x<=0;soi_bytes<=0;app_index<=0;cfg_done<=0;cfg_error<=0;error_code<=0;
 end else if(ce)begin
 cfg_done<=0;cfg_error<=0;
 if(state>=HEADER_CMD&&state<=EOI_DATA&&(abort||hcmderror||rerror||scerror!=0))begin
 error_code<=abort?8'h93:hcmderror?8'h91:rerror?8'h92:scerror;configured<=0;state<=FAILED;
 end else case(state)
 IDLE:begin
 if(cfg_valid&&cfg_ready)begin pending_interval<=cfg_restart_interval;h_seen<=0;s_seen<=0;cfg_fault<=0;state<=CONFIG;end
 else if(start_valid&&start_ready)begin error_code<=0;captured<=0;capture_x<=0;soi_bytes<=0;app_index<=0;state<=HEADER_CMD;end
 end
 CONFIG:begin
 if(hcd||hce)h_seen<=1;if(scd||sce)s_seen<=1;if(hce||sce)cfg_fault<=1;
 if((h_seen||hcd||hce)&&(s_seen||scd||sce))begin
 cfg_done<=1;cfg_error<=cfg_fault||hce||sce;
 if(!(cfg_fault||hce||sce))begin configured<=1;interval_blocks<=pending_interval;end
 state<=IDLE;end end
 HEADER_CMD:if(hcmdready)state<=HEADER_DATA;
 HEADER_DATA:begin
 if(hvalid&&m_ready&&soi_bytes<2)begin soi_bytes<=soi_bytes+1'b1;if(soi_bytes==1)state<=APP0;end
 if(hcmddone)state<=START;
 end
 APP0:if(m_ready)begin if(app_index==17)state<=HEADER_DATA;else app_index<=app_index+1'b1;end
 START:if(scan_start_ready)state<=RUN;
 RUN:begin
 if(s_valid&&s_ready)begin
 captured<=captured+1'b1;capture_x<=capture_x==WIDTH-1?0:capture_x+1'b1;
 if(s_sof!=(captured==0)||s_eol!=(capture_x==WIDTH-1))begin error_code<=8'h92;configured<=0;state<=FAILED;end
 end
 if(scdone&&scerror==0)state<=EOI_CMD;
 end
 EOI_CMD:if(hcmdready)state<=EOI_DATA;
 EOI_DATA:if(hcmddone)state<=DONE;
 DONE:if(done_ready)state<=IDLE;
 FAILED:if(done_ready)state<=LOCKED;
 LOCKED:state<=LOCKED;
 default:begin error_code<=8'h94;configured<=0;state<=FAILED;end
 endcase
 end end
endmodule
