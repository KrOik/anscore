// 8-bit 4:2:0 macro stream <-> NV12/NV21 byte-addressed frame memory.
// One ordered request and response outstanding; no DDR/AXI controller included.
`timescale 1ns/1ps
module img_nv12_layout #(
 parameter integer WIDTH=8, HEIGHT=6
)(
 input wire clk,rst_n,clk_en,
 input wire cfg_valid,output wire cfg_ready,
 input wire cfg_nv21,
 input wire [31:0] cfg_y_base,cfg_uv_base,cfg_y_stride,cfg_uv_stride,
 input wire [31:0] cfg_address_min,cfg_address_max,
 output reg cfg_done,cfg_error,
 input wire start_valid,output wire start_ready,input wire start_read,
 input wire [16:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,
 output reg [16:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,
 output wire mem_req_valid,input wire mem_req_ready,
 output wire mem_req_write,output wire [31:0] mem_req_addr,
 output wire [7:0] mem_req_wdata,
 input wire mem_rsp_valid,output wire mem_rsp_ready,
 input wire [7:0] mem_rsp_rdata,input wire mem_rsp_error,
 output reg done_valid,input wire done_ready,
 output reg done_error,output reg [2:0] error_code
);
 localparam integer CW=(WIDTH+1)/2,CH=(HEIGHT+1)/2;
 localparam IDLE=0,CAPTURE=1,REQUEST=2,RESPONSE=3,OUTPUT=4,COMPLETE=5;
 reg [2:0] state;
 reg configured,nv21,read_mode,chroma,second;
 reg [31:0] ybase,uvbase,ystride,uvstride,yrow,uvrow,addrmin,addrmax;
 reg [15:0] payload;
 reg [7:0] first_byte;
 integer x,y;
 wire chroma_line=y[0] || y==HEIGHT-1;
 wire final_macro=x==CW-1 && (!chroma_line || chroma);
 wire first_macro=x==0 && y==0 && !chroma;
 wire one_byte=!chroma && WIDTH%2!=0 && x==CW-1;
 wire [63:0] yend={32'b0,cfg_y_base}+(HEIGHT-1)*{32'b0,cfg_y_stride}+WIDTH-1;
 wire [63:0] uvend={32'b0,cfg_uv_base}+(CH-1)*{32'b0,cfg_uv_stride}+2*CW-1;
 wire config_ok=cfg_y_stride>=WIDTH && cfg_uv_stride>=2*CW &&
  cfg_address_min<=cfg_address_max && cfg_y_base>=cfg_address_min &&
  cfg_uv_base>=cfg_address_min && yend<=cfg_address_max && uvend<=cfg_address_max &&
  (yend<cfg_uv_base || uvend<cfg_y_base);
 wire [32:0] request_address={1'b0,(chroma?uvrow:yrow)}+2*x+second;
 wire address_ok=request_address>={1'b0,addrmin} && request_address<={1'b0,addrmax};
 assign cfg_ready=rst_n && clk_en && state==IDLE;
 assign start_ready=cfg_ready && configured && !cfg_valid;
 assign s_ready=rst_n && clk_en && state==CAPTURE;
 assign m_valid=state==OUTPUT;
 assign m_sof=m_valid && first_macro;
 assign m_eol=m_valid && final_macro;
 assign mem_req_valid=rst_n && state==REQUEST && address_ok;
 assign mem_req_write=!read_mode;
 assign mem_req_addr=request_address[31:0];
 assign mem_req_wdata=(chroma && nv21) ? (second?payload[15:8]:payload[7:0]) :
                                                       (second?payload[7:0]:payload[15:8]);
 assign mem_rsp_ready=rst_n && clk_en && state==RESPONSE;
 task abort_frame;
 input [2:0] code;
 begin state<=COMPLETE;done_valid<=1;done_error<=1;error_code<=code;end
 endtask
 task advance_macro;
 begin
  second<=0;
  state<=read_mode ? REQUEST:CAPTURE;
  if(!chroma && chroma_line) chroma<=1;
  else begin
   chroma<=0;
   if(x==CW-1) begin
    x<=0;
    if(y==HEIGHT-1) begin state<=COMPLETE;done_valid<=1;done_error<=0;error_code<=0;end
    else begin
     y<=y+1;yrow<=yrow+ystride;
     if(chroma_line) uvrow<=uvrow+uvstride;
    end
   end else x<=x+1;
  end
 end
 endtask
 initial begin
  if(WIDTH<1 || HEIGHT<1 || WIDTH>65535 || HEIGHT>65535) $fatal(1,"invalid geometry");
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;configured<=0;cfg_done<=0;cfg_error<=0;
   nv21<=0;read_mode<=0;chroma<=0;second<=0;x<=0;y<=0;
   ybase<=0;uvbase<=0;ystride<=0;uvstride<=0;yrow<=0;uvrow<=0;addrmin<=0;addrmax<=0;
   payload<=0;first_byte<=0;m_data<=0;done_valid<=0;done_error<=0;error_code<=0;
  end else if(clk_en) begin
   cfg_done<=0;cfg_error<=0;
   if(cfg_valid && cfg_ready) begin
    if(!config_ok) cfg_error<=1;
    else begin
     configured<=1;cfg_done<=1;nv21<=cfg_nv21;
     ybase<=cfg_y_base;uvbase<=cfg_uv_base;ystride<=cfg_y_stride;uvstride<=cfg_uv_stride;
     addrmin<=cfg_address_min;addrmax<=cfg_address_max;
    end
   end
   case(state)
    IDLE:if(start_valid && start_ready) begin
     read_mode<=start_read;chroma<=0;second<=0;x<=0;y<=0;yrow<=ybase;uvrow<=uvbase;
     done_error<=0;error_code<=0;state<=start_read?REQUEST:CAPTURE;
    end
    CAPTURE:if(s_valid && s_ready) begin
     if(s_data[16]!=chroma || s_sof!=first_macro || s_eol!=final_macro) abort_frame(1);
     else begin payload<=s_data[15:0];second<=0;state<=REQUEST;end
    end
    REQUEST:if(!address_ok) abort_frame(3);
            else if(mem_req_valid && mem_req_ready) state<=RESPONSE;
    RESPONSE:if(mem_rsp_valid && mem_rsp_ready) begin
     if(mem_rsp_error) abort_frame(2);
     else if(!second && !one_byte) begin first_byte<=mem_rsp_rdata;second<=1;state<=REQUEST;end
     else if(read_mode) begin
      m_data<=one_byte ? {1'b0,mem_rsp_rdata,8'b0} :
              ((chroma && nv21) ? {chroma,mem_rsp_rdata,first_byte} : {chroma,first_byte,mem_rsp_rdata});
      state<=OUTPUT;
     end else advance_macro();
    end
    OUTPUT:if(m_ready) advance_macro();
    COMPLETE:if(done_valid && done_ready) begin done_valid<=0;state<=IDLE;end
   endcase
  end
 end
endmodule
