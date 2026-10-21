// Serial 4/8-connected flood fill with synchronous frame/label/queue RAM.
`timescale 1ns/1ps
module img_connected_components #(
 parameter integer WIDTH=8,HEIGHT=8,CONNECTIVITY=8,LABEL_BITS=8,MAX_LABELS=255
)(
 input wire clk,rst_n,clk_en,
 input wire s_data,s_valid,output wire s_ready,input wire s_sof,s_eol,
 output wire [LABEL_BITS-1:0] m_label,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,
 output wire stats_valid,input wire stats_ready,
 output wire [LABEL_BITS-1:0] stats_label,
 output wire [31:0] stats_area,
 output wire [15:0] stats_xmin,stats_xmax,stats_ymin,stats_ymax,
 output wire done_valid,input wire done_ready,
 output reg done_error,output reg [1:0] error_code
);
 function integer cw;
 input integer n;integer k;
 begin k=n-1;cw=0;while(k>0) begin cw=cw+1;k=k>>1;end if(cw==0) cw=1;end
 endfunction
 function [31:0] row_offset;
 input [31:0] row;integer k;reg [31:0] sum;
 begin sum=0;for(k=0;k<13;k=k+1) if((WIDTH>>k)&1) sum=sum+(row<<k);row_offset=sum;end
 endfunction
 localparam N=WIDTH*HEIGHT,XW=cw(WIDTH),YW=cw(HEIGHT),AW=cw(N),QW=cw(N+1);
 localparam SYNC=0,CAPTURE=1,SEED_READ=2,SEED_WAIT=3,NEXT=4,QTEST=5,QREAD=6,QWAIT=7,
            NADDR=8,NREAD=9,NWAIT=10,CFINISH=11,LADDR=12,LEMIT=13,SADDR=14,SEMIT=15,COMPLETE=16;
 reg [4:0] state;
 reg [XW-1:0] scan_x,current_x,min_x,max_x;
 reg [YW-1:0] scan_y,current_y,min_y,max_y;
 reg [AW-1:0] scan_address;
 reg [QW-1:0] head,tail;
 reg [2:0] neighbor;
 reg [LABEL_BITS-1:0] label_count,current_label,statistics_index;
 reg [31:0] area;
 reg frame_bits[0:N-1];
 reg [LABEL_BITS-1:0] labels[0:N-1];
 reg [XW+YW-1:0] queue[0:N-1];
 reg [95:0] statistics[0:MAX_LABELS-1];
 reg bit_q;
 reg [LABEL_BITS-1:0] label_q;
 reg [XW+YW-1:0] queue_q;
 reg [95:0] stats_q;
 reg [XW-1:0] neighbor_x;
 reg [YW-1:0] neighbor_y;
 reg neighbor_valid;
 always @* begin
  neighbor_x=current_x;neighbor_y=current_y;neighbor_valid=1;
  case(neighbor)
   0:begin neighbor_x=current_x-1'b1;neighbor_valid=current_x!=0;end
   1:begin neighbor_x=current_x+1'b1;neighbor_valid=current_x<WIDTH-1;end
   2:begin neighbor_y=current_y-1'b1;neighbor_valid=current_y!=0;end
   3:begin neighbor_y=current_y+1'b1;neighbor_valid=current_y<HEIGHT-1;end
   4:begin neighbor_x=current_x-1'b1;neighbor_y=current_y-1'b1;neighbor_valid=current_x!=0&&current_y!=0;end
   5:begin neighbor_x=current_x+1'b1;neighbor_y=current_y-1'b1;neighbor_valid=current_x<WIDTH-1&&current_y!=0;end
   6:begin neighbor_x=current_x-1'b1;neighbor_y=current_y+1'b1;neighbor_valid=current_x!=0&&current_y<HEIGHT-1;end
   7:begin neighbor_x=current_x+1'b1;neighbor_y=current_y+1'b1;neighbor_valid=current_x<WIDTH-1&&current_y<HEIGHT-1;end
  endcase
 end
 wire [31:0] neighbor_address=row_offset(neighbor_y)+neighbor_x;
 wire [31:0] read_address=state==NREAD?neighbor_address:scan_address;
 wire first_pixel=scan_address==0;
 wire input_ok=s_sof==first_pixel && s_eol==(scan_x==WIDTH-1);
 wire capture_transfer=s_valid&&s_ready&&input_ok&&(state==CAPTURE||s_sof);
 wire seed_new=state==SEED_WAIT&&bit_q&&label_q==0&&label_count<MAX_LABELS;
 wire neighbor_new=state==NWAIT&&bit_q&&label_q==0&&tail<N;
 wire [15:0] min_x16=min_x,max_x16=max_x,min_y16=min_y,max_y16=max_y;
 assign s_ready=rst_n&&clk_en&&(state==SYNC||state==CAPTURE);
 assign m_valid=state==LEMIT;
 assign m_label=label_q;
 assign m_sof=m_valid&&scan_address==0;
 assign m_eol=m_valid&&scan_x==WIDTH-1;
 assign stats_valid=state==SEMIT;
 assign stats_label=statistics_index;
 assign stats_area=stats_q[95:64];
 assign stats_xmin=stats_q[63:48];assign stats_xmax=stats_q[47:32];
 assign stats_ymin=stats_q[31:16];assign stats_ymax=stats_q[15:0];
 assign done_valid=state==COMPLETE;
 // All memories use clocked read ports and are deliberately not reset.
 always @(posedge clk) if(clk_en) begin
  if(capture_transfer) begin frame_bits[scan_address]<=s_data;labels[scan_address]<=0;end
  else if(seed_new) labels[scan_address]<=label_count+1'b1;
  else if(neighbor_new) labels[neighbor_address]<=current_label;
  if(state==SEED_READ||state==NREAD||state==LADDR) begin
   bit_q<=frame_bits[read_address];label_q<=labels[read_address];
  end
  if(seed_new) queue[0]<={scan_y,scan_x};
  else if(neighbor_new) queue[tail]<={neighbor_y,neighbor_x};
  if(state==QREAD) queue_q<=queue[head];
  if(state==CFINISH) statistics[current_label-1'b1]<={area,min_x16,max_x16,min_y16,max_y16};
  if(state==SADDR) stats_q<=statistics[statistics_index-1'b1];
 end
 task clear_scan;
 begin scan_x<=0;scan_y<=0;scan_address<=0;end
 endtask
 task abort_frame;
 input [1:0] code;
 begin state<=COMPLETE;done_error<=1;error_code<=code;end
 endtask
 task next_neighbor;
 begin
  if(neighbor==(CONNECTIVITY==8?7:3)) state<=QTEST;
  else begin neighbor<=neighbor+1'b1;state<=NADDR;end
 end
 endtask
 task advance_scan;
 begin
  scan_address<=scan_address+1'b1;
  if(scan_x==WIDTH-1) begin scan_x<=0;scan_y<=scan_y+1'b1;end else scan_x<=scan_x+1'b1;
 end
 endtask
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||(CONNECTIVITY!=4&&CONNECTIVITY!=8)||
    LABEL_BITS<1||LABEL_BITS>16||MAX_LABELS<1||MAX_LABELS>=(1<<LABEL_BITS)) $fatal(1,"invalid parameters");
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=SYNC;clear_scan();current_x<=0;current_y<=0;min_x<=0;max_x<=0;min_y<=0;max_y<=0;
   head<=0;tail<=0;neighbor<=0;label_count<=0;current_label<=0;statistics_index<=0;area<=0;
   done_error<=0;error_code<=0;
  end else if(clk_en) begin
   case(state)
    SYNC,CAPTURE:if(s_valid&&s_ready) begin
     if(state==SYNC&&!s_sof) begin end
     else if(!input_ok) abort_frame(1);
     else if(scan_address==N-1) begin clear_scan();label_count<=0;done_error<=0;error_code<=0;state<=SEED_READ;end
     else begin state<=CAPTURE;advance_scan();end
    end
    SEED_READ:state<=SEED_WAIT;
    SEED_WAIT:if(bit_q&&label_q==0) begin
     if(label_count==MAX_LABELS) abort_frame(2);
     else begin
      label_count<=label_count+1'b1;current_label<=label_count+1'b1;
      head<=0;tail<=1;area<=1;min_x<=scan_x;max_x<=scan_x;min_y<=scan_y;max_y<=scan_y;state<=QTEST;
     end
    end else state<=NEXT;
    NEXT:if(scan_address==N-1) begin clear_scan();state<=LADDR;end else begin advance_scan();state<=SEED_READ;end
    QTEST:state<=head<tail?QREAD:CFINISH;
    QREAD:begin head<=head+1'b1;state<=QWAIT;end
    QWAIT:begin current_x<=queue_q[XW-1:0];current_y<=queue_q[XW+YW-1:XW];neighbor<=0;state<=NADDR;end
    NADDR:if(neighbor_valid) state<=NREAD;else next_neighbor();
    NREAD:state<=NWAIT;
    NWAIT:begin
     if(bit_q&&label_q==0) begin
      if(tail==N) abort_frame(3);
      else begin
       tail<=tail+1'b1;area<=area+1'b1;
       if(neighbor_x<min_x) min_x<=neighbor_x;if(neighbor_x>max_x) max_x<=neighbor_x;
       if(neighbor_y<min_y) min_y<=neighbor_y;if(neighbor_y>max_y) max_y<=neighbor_y;
       next_neighbor();
      end
     end else next_neighbor();
    end
    CFINISH:state<=NEXT;
    LADDR:state<=LEMIT;
    LEMIT:if(m_ready) begin
     if(scan_address==N-1) begin statistics_index<=1;state<=label_count==0?COMPLETE:SADDR;end
     else begin advance_scan();state<=LADDR;end
    end
    SADDR:state<=SEMIT;
    SEMIT:if(stats_ready) begin
     if(statistics_index==label_count) state<=COMPLETE;
     else begin statistics_index<=statistics_index+1'b1;state<=SADDR;end
    end
    COMPLETE:if(done_ready) begin clear_scan();done_error<=0;error_code<=0;state<=SYNC;end
   endcase
  end
 end
endmodule
