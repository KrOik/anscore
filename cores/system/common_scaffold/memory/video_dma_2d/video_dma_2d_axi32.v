// AXI4 single-outstanding, bounded INCR bursts. AXI and exposed output
// handshakes are clock-active regardless of ce; ce gates new stream inputs.
module video_dma_2d_axi32 #(parameter MAX_BURST=16)(
 input wire clk,rst_n,ce,abort,
 input wire start_valid,output wire start_ready,input wire cfg_write,
 input wire [31:0] cfg_base,cfg_row_bytes,cfg_stride,input wire [15:0] cfg_rows,
 output wire done_valid,input wire done_ready,output reg [7:0] error_code,
 output reg [31:0] bytes_done,
 input wire [31:0] s_data,input wire [3:0] s_keep,input wire s_valid,
 output wire s_ready,input wire s_eol,s_last,
 output reg [31:0] m_data,output reg [3:0] m_keep,output reg m_valid,
 input wire m_ready,output reg m_eol,m_last,
 output wire [31:0] m_axi_awaddr,output wire [7:0] m_axi_awlen,
 output wire [2:0] m_axi_awsize,output wire [1:0] m_axi_awburst,
 output wire m_axi_awvalid,input wire m_axi_awready,
 output wire [31:0] m_axi_wdata,output wire [3:0] m_axi_wstrb,
 output wire m_axi_wlast,m_axi_wvalid,input wire m_axi_wready,
 input wire [1:0] m_axi_bresp,input wire m_axi_bvalid,output wire m_axi_bready,
 output wire [31:0] m_axi_araddr,output wire [7:0] m_axi_arlen,
 output wire [2:0] m_axi_arsize,output wire [1:0] m_axi_arburst,
 output wire m_axi_arvalid,input wire m_axi_arready,
 input wire [31:0] m_axi_rdata,input wire [1:0] m_axi_rresp,
 input wire m_axi_rlast,m_axi_rvalid,output wire m_axi_rready
);
 localparam IDLE=0,PLAN=1,ADDR=2,DATA=3,RESP=4,ADV=5,DONE=6;
 reg [2:0] state;
 reg wr,killed;
 reg [31:0] row_base,addr,row_bytes,stride,left;
 reg [15:0] rows_left;
 reg [8:0] burst,beat;
 reg [31:0] wb_data;
 reg [3:0] wb_keep;
 reg wb_valid;
 wire [2:0] nbytes=(left>=4)?3'd4:left[2:0];
 wire [3:0] keep=(4'b1111 >> (4-nbytes));
 wire endrow=(left<=4),endframe=endrow&&(rows_left==1);
 wire stop=killed||abort;
 wire [63:0] extent={32'b0,cfg_base}+({48'b0,cfg_rows}-1)*{32'b0,cfg_stride}+{32'b0,cfg_row_bytes};
 wire [63:0] total={32'b0,cfg_row_bytes}*cfg_rows;
 reg [32:0] plan_beats;
 reg [10:0] page_beats;
 always @* begin
  plan_beats=({1'b0,left}+3)>>2;
  page_beats=(13'd4096-{1'b0,addr[11:0]})>>2;
  if(plan_beats>MAX_BURST) plan_beats=MAX_BURST;
  if(plan_beats>page_beats) plan_beats=page_beats;
 end
 assign start_ready=(state==IDLE)&&ce;
 assign done_valid=(state==DONE);
 assign m_axi_awaddr=addr; assign m_axi_araddr=addr;
 assign m_axi_awlen=burst-1; assign m_axi_arlen=burst-1;
 assign m_axi_awsize=2; assign m_axi_arsize=2;
 assign m_axi_awburst=1; assign m_axi_arburst=1;
 assign m_axi_awvalid=(state==ADDR)&&wr;
 assign m_axi_arvalid=(state==ADDR)&&!wr;
 assign s_ready=(state==DATA)&&wr&&!wb_valid&&!stop&&ce;
 assign m_axi_wvalid=(state==DATA)&&wr&&(wb_valid||killed);
 assign m_axi_wdata=wb_data;
 assign m_axi_wstrb=wb_valid?wb_keep:4'b0;
 assign m_axi_wlast=(beat==burst-1);
 assign m_axi_bready=(state==RESP);
 assign m_axi_rready=(state==DATA)&&!wr&&(!m_valid||m_ready||killed);
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;wr<=0;killed<=0;error_code<=0;bytes_done<=0;
   row_base<=0;addr<=0;row_bytes<=0;stride<=0;left<=0;rows_left<=0;
   burst<=0;beat<=0;wb_data<=0;wb_keep<=0;wb_valid<=0;
   m_valid<=0;m_data<=0;m_keep<=0;m_eol<=0;m_last<=0;
  end else begin
   if(m_valid&&m_ready) m_valid<=0;
   if(abort && state!=IDLE && state!=DONE) begin
    killed<=1; if(error_code==0) error_code<=5;
   end
   case(state)
    IDLE: if(start_valid&&start_ready) begin
     wr<=cfg_write;row_base<=cfg_base;addr<=cfg_base;
     row_bytes<=cfg_row_bytes;stride<=cfg_stride;left<=cfg_row_bytes;
     rows_left<=cfg_rows;bytes_done<=0;error_code<=0;killed<=0;wb_valid<=0;
     if(MAX_BURST<1||MAX_BURST>256||cfg_base[1:0]!=0||cfg_stride[1:0]!=0||
        cfg_row_bytes==0||cfg_rows==0||cfg_stride<cfg_row_bytes||
        extent>64'h100000000||total>64'hffffffff) begin error_code<=2;state<=DONE;end
     else state<=PLAN;
    end
    PLAN: if(stop) state<=DONE; else begin burst<=plan_beats[8:0];beat<=0;state<=ADDR;end
    ADDR: if((wr&&m_axi_awready)||(!wr&&m_axi_arready)) state<=DATA;
    DATA: if(wr) begin
     if(s_valid&&s_ready) begin
      wb_data<=s_data;wb_keep<=s_keep;wb_valid<=1;
      if(s_keep!=keep||s_eol!=endrow||s_last!=endframe) begin
       wb_keep<=0;killed<=1;error_code<=3;
      end
     end
     if(m_axi_wvalid&&m_axi_wready) begin
      wb_valid<=0;
      if(!killed) bytes_done<=bytes_done+nbytes;
      left<=endrow?0:left-4;beat<=beat+1;
      if(beat==burst-1) state<=RESP;
     end
    end else if(m_axi_rvalid&&m_axi_rready) begin
     if(m_axi_rresp!=0 || m_axi_rlast!=(beat==burst-1)) begin
      killed<=1;if(error_code==0) error_code<=4;
     end
     if(!stop&&m_axi_rresp==0&&m_axi_rlast==(beat==burst-1)) begin
      m_data<=m_axi_rdata;m_keep<=keep;m_valid<=1;m_eol<=endrow;m_last<=endframe;
      bytes_done<=bytes_done+nbytes;
     end
     left<=endrow?0:left-4;beat<=beat+1;
     if(beat==burst-1) state<=ADV;
    end
    RESP: if(m_axi_bvalid) begin
     if(m_axi_bresp!=0) begin killed<=1;if(error_code==0) error_code<=4;end
     state<=ADV;
    end
    ADV: if(!m_valid||m_ready) begin
     if(stop) state<=DONE;
     else if(left==0) begin
      if(rows_left==1) state<=DONE;
      else begin rows_left<=rows_left-1;row_base<=row_base+stride;
       addr<=row_base+stride;left<=row_bytes;state<=PLAN;end
     end else begin addr<=addr+({23'b0,burst}<<2);state<=PLAN;end
    end
    DONE: if(done_ready) state<=IDLE;
    default: state<=IDLE;
   endcase
  end
 end
endmodule
