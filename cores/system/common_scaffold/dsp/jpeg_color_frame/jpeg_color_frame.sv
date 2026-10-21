// RGB raster -> complete baseline YCbCr JPEG file, serialized shared datapath.
module jpeg_color_frame #(parameter WIDTH=16,HEIGHT=16)(
 input wire clk,rst_n,ce,
 input wire table_valid,output wire table_ready,input wire table_id,
 input wire[5:0] table_index,input wire[7:0] table_value,
 input wire cfg_valid,output wire cfg_ready,input wire cfg_sampling_420,
 input wire[15:0] cfg_restart_interval,output reg cfg_done,cfg_error,
 input wire start_valid,output wire start_ready,input wire abort,
 input wire[23:0] s_rgb,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire[7:0] m_data,output wire m_valid,m_last,input wire m_ready,
 output wire done_valid,input wire done_ready,output reg[7:0] error_code,
 output wire busy
);
 localparam IDLE=0,CONFIG=1,HEADER_CMD=2,HEADER_DATA=3,START=4,RUN=5,
            EOI_CMD=6,EOI_DATA=7,DONE=8,FAILED=9,LOCKED=10;
 localparam MCU444=((WIDTH+7)/8)*((HEIGHT+7)/8);
 localparam MCU420=((WIDTH+15)/16)*((HEIGHT+15)/16);
 reg[3:0] state;
 reg configured,mode420,pending_mode,h_seen,s_seen,cfg_fault;
 reg[15:0] interval_mcus,pending_interval;
 wire htr,str,hcr,scr,hcd,scd,hce,sce;
 wire hcmdready,hcmddone,hcmderror,hvalid,hlast;
 wire[7:0] hdata;
 wire hphase=state==HEADER_CMD||state==HEADER_DATA||state==EOI_CMD||state==EOI_DATA;
 wire config_window=state==IDLE;
 wire hcfgvalid=cfg_valid&&config_window&&scr;
 wire scfgvalid=cfg_valid&&config_window&&hcr;
 assign cfg_ready=rst_n&&ce&&config_window&&hcr&&scr;
 assign table_ready=rst_n&&ce&&config_window&&!cfg_valid&&htr&&str;
 jpeg_color_headers headers(
  .clk(clk),.rst_n(rst_n),.ce(ce),
  .table_valid(table_valid&&config_window&&!cfg_valid&&str),.table_ready(htr),
  .table_id(table_id),.table_index(table_index),.table_value(table_value),
  .cfg_valid(hcfgvalid),.cfg_ready(hcr),.cfg_width(16'(WIDTH)),.cfg_height(16'(HEIGHT)),
  .cfg_restart_interval(cfg_restart_interval),.cfg_sampling_420(cfg_sampling_420),
  .cfg_done(hcd),.cfg_error(hce),
  .cmd_valid(state==HEADER_CMD||state==EOI_CMD),.cmd_ready(hcmdready),
  .cmd(state==EOI_CMD?2'd1:2'd0),.rst_index(3'd0),
  .m_data(hdata),.m_valid(hvalid),.m_last(hlast),.m_ready(m_ready&&hphase),
  .cmd_done(hcmddone),.cmd_error(hcmderror),.busy());
 wire raster_start_ready,rsv,rsr,rbfirst,rblast,rframe,rmcu_last,r_done;
 wire[7:0] rdata;wire[1:0] rcomponent;wire[31:0] rmcu_index;wire[3:0] rerror;
 wire scan_start_ready,scvalid,scdone,scan_pixel_ready;
 wire[7:0] scdata,scerror;
 wire pair_done=state==RUN&&r_done&&scdone&&rerror==0&&scerror==0&&!abort;
 jpeg_color_mcu #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) raster(
  .clk(clk),.rst_n(rst_n),.ce(ce),
  .start_valid(state==START&&scan_start_ready),.start_ready(raster_start_ready),
  .cfg_sampling_420(mode420),.s_rgb(s_rgb),.s_valid(s_valid&&state==RUN),
  .s_ready(rsr),.s_sof(s_sof),.s_eol(s_eol),
  .m_data(rdata),.m_valid(rsv),.m_ready(state==RUN&&scan_pixel_ready),
  .m_component(rcomponent),.m_block_first(rbfirst),.m_block_last(rblast),
  .m_frame_last(rframe),.m_mcu_last(rmcu_last),.m_mcu_index(rmcu_index),
  .done_valid(r_done),.done_ready(pair_done),.error_code(rerror),.busy());
 jpeg_color_scan scan(
  .clk(clk),.rst_n(rst_n),.ce(ce),
  .table_valid(table_valid&&config_window&&!cfg_valid&&htr),.table_ready(str),
  .table_id(table_id),.table_index(table_index),.table_value(table_value),
  .cfg_valid(scfgvalid),.cfg_ready(scr),.cfg_done(scd),.cfg_error(sce),
  .start_valid(state==START&&raster_start_ready),.start_ready(scan_start_ready),
  .cfg_total_mcus(mode420?32'(MCU420):32'(MCU444)),
  .cfg_restart_interval(interval_mcus),.cfg_sampling_420(mode420),
  .abort(abort||state==FAILED||state==LOCKED),
  .s_data(rdata),.s_valid(rsv&&state==RUN),.s_ready(scan_pixel_ready),
  .s_component(rcomponent),.s_block_first(rbfirst),.s_block_last(rblast),.s_frame_last(rframe),
  .m_data(scdata),.m_valid(scvalid),.m_ready(m_ready&&state==RUN),.m_marker(),.m_scan_last(),
  .done_valid(scdone),.done_ready(pair_done),.error_code(scerror),.busy());
 assign start_ready=rst_n&&ce&&state==IDLE&&configured&&!cfg_valid&&!table_valid;
 assign s_ready=rst_n&&ce&&state==RUN&&rsr;
 assign m_valid=rst_n&&((hphase&&hvalid)||(state==RUN&&scvalid));
 assign m_data=hphase?hdata:scdata;
 assign m_last=m_valid&&(state==EOI_CMD||state==EOI_DATA)&&hlast;
 assign done_valid=rst_n&&(state==DONE||state==FAILED);
 assign busy=state!=IDLE;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||WIDTH*HEIGHT>65536)$fatal(1,"invalid color JPEG geometry");
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;configured<=0;mode420<=0;pending_mode<=0;interval_mcus<=0;
   pending_interval<=0;h_seen<=0;s_seen<=0;cfg_fault<=0;cfg_done<=0;cfg_error<=0;error_code<=0;
  end else if(ce)begin
   cfg_done<=0;cfg_error<=0;
   if(state>=HEADER_CMD&&state<=EOI_DATA&&
      (abort||hcmderror||rerror!=0||scerror!=0))begin
    error_code<=abort?8'h93:(hcmderror?8'h91:(rerror!=0?8'h92:scerror));
    configured<=0;state<=FAILED;
   end else case(state)
    IDLE:begin
     if(cfg_valid&&cfg_ready)begin
      pending_mode<=cfg_sampling_420;pending_interval<=cfg_restart_interval;
      h_seen<=0;s_seen<=0;cfg_fault<=0;state<=CONFIG;
     end else if(start_valid&&start_ready)begin error_code<=0;state<=HEADER_CMD;end
    end
    CONFIG:begin
     if(hcd||hce)h_seen<=1;if(scd||sce)s_seen<=1;
     if(hce||sce)cfg_fault<=1;
     if((h_seen||hcd||hce)&&(s_seen||scd||sce))begin
      cfg_done<=1;cfg_error<=cfg_fault||hce||sce;
      if(!(cfg_fault||hce||sce))begin configured<=1;mode420<=pending_mode;interval_mcus<=pending_interval;end
      state<=IDLE;
     end
    end
    HEADER_CMD:if(hcmdready)state<=HEADER_DATA;
    HEADER_DATA:if(hcmddone)state<=START;
    START:if(raster_start_ready&&scan_start_ready)state<=RUN;
    RUN:if(pair_done)state<=EOI_CMD;
    EOI_CMD:if(hcmdready)state<=EOI_DATA;
    EOI_DATA:if(hcmddone)state<=DONE;
    DONE:if(done_ready)state<=IDLE;
    FAILED:if(done_ready)state<=LOCKED;
    LOCKED:state<=LOCKED;
    default:begin error_code<=8'h94;configured<=0;state<=FAILED;end
   endcase
  end
 end
endmodule
