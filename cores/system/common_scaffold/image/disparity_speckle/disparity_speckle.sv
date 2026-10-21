// Whole-frame four-neighbor connected-component disparity speckle removal.
module disparity_speckle #(
 parameter WIDTH=32,HEIGHT=16,DISP_BITS=24,DISP_FRAC=4,
 parameter SIZE_BITS=$clog2(WIDTH*HEIGHT+1)
)(input wire clk,rst_n,ce,input wire start_valid,output wire start_ready,
 input wire[DISP_BITS-1:0]cfg_range,input wire[SIZE_BITS-1:0]cfg_max_size,
 input wire signed[DISP_BITS-1:0]s_disparity,input wire s_invalid,s_valid,
 output wire s_ready,input wire s_sof,s_eol,s_last,
 output reg signed[DISP_BITS-1:0]m_disparity,output reg m_invalid,m_removed,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[2:0]error_code
);
 localparam N=WIDTH*HEIGHT,AW=(N<=1?1:$clog2(N));
 localparam IDLE=0,CAP=1,SCAN_READ=2,SCAN_USE=3,POP_READ=4,POP_FRAME=5,POP_USE=6,NEIGH=7,NEIGH_USE=8,POP_NEXT=9,COMPLETE=10,REMOVE_READ=11,REMOVE_WRITE=12,SCAN_NEXT=13,OUT_READ=14,OUT_USE=15,HOLD=16,DONE=17;
 reg[4:0]state;
 reg[DISP_BITS:0]frame[0:N-1];reg visited[0:N-1],removed[0:N-1];
 reg[AW-1:0]queue[0:N-1],queue_q;
 reg[DISP_BITS:0]frame_q;reg visited_q,removed_q;
 reg[DISP_BITS-1:0]range_q;reg[SIZE_BITS-1:0]size_q;
 reg[SIZE_BITS-1:0]head,tail,clear_index;
 integer pixel,x,y,scan,current,cx,cy,neighbor,dir;
 reg signed[DISP_BITS-1:0]current_disp;
 reg signed[DISP_BITS:0]difference;
 reg[DISP_BITS:0]distance;
 reg neighbor_valid;
 always @*begin
  neighbor=current;neighbor_valid=0;
  case(dir)
   0:begin neighbor=current-1;neighbor_valid=cx>0;end
   1:begin neighbor=current+1;neighbor_valid=cx<WIDTH-1;end
   2:begin neighbor=current-WIDTH;neighbor_valid=cy>0;end
   3:begin neighbor=current+WIDTH;neighbor_valid=cy<HEIGHT-1;end
  endcase
  difference=$signed({frame_q[DISP_BITS-1],frame_q[DISP_BITS-1:0]})-$signed({current_disp[DISP_BITS-1],current_disp});
  distance=difference<0?-$signed(difference):difference;
 end
 wire capture_write=state==CAP&&s_valid&&s_sof==(pixel==0)&&s_eol==(x==WIDTH-1)&&s_last==(pixel==N-1);
 wire seed_write=state==SCAN_USE&&!visited_q;
 wire enqueue_write=state==NEIGH_USE&&!visited_q&&!frame_q[DISP_BITS]&&distance<={1'b0,range_q}&&tail<N;
 wire[AW-1:0]queue_write_addr=seed_write?{AW{1'b0}}:tail;
 wire[AW-1:0]queue_write_data=seed_write?scan:neighbor;
 wire[AW-1:0]visit_write_addr=capture_write?pixel:(seed_write?scan:neighbor);
 wire[AW-1:0]remove_write_addr=capture_write?pixel:queue_q;
 wire[AW-1:0]frame_read_addr=state==POP_FRAME?queue_q:(state==NEIGH?neighbor:pixel);
 // One write port and one registered read port per logical RAM.
 always @(posedge clk)if(rst_n&&ce)begin
  if(capture_write)frame[pixel]<={s_invalid,s_disparity};
  if(state==POP_FRAME||state==OUT_READ||(state==NEIGH&&neighbor_valid))frame_q<=frame[frame_read_addr];
  if(capture_write||seed_write||enqueue_write)visited[visit_write_addr]<=capture_write?s_invalid:1'b1;
  if(state==SCAN_READ||state==NEIGH&&neighbor_valid)visited_q<=visited[state==SCAN_READ?scan:neighbor];
  if(capture_write||state==REMOVE_WRITE)removed[remove_write_addr]<=!capture_write;
  if(state==OUT_READ)removed_q<=removed[pixel];
  if(seed_write||enqueue_write)queue[queue_write_addr]<=queue_write_data;
  if(state==POP_READ||state==REMOVE_READ)queue_q<=queue[state==POP_READ?head:clear_index];
 end
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign s_ready=rst_n&&ce&&state==CAP;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&pixel==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_valid&&pixel==N-1;
 assign done_valid=rst_n&&state==DONE;
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>65536||DISP_BITS<2||DISP_BITS>32||DISP_FRAC<0||DISP_FRAC>16||SIZE_BITS<$clog2(N+1)||SIZE_BITS>24)$fatal(1,"disparity_speckle invalid parameters");
 end
 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;pixel<=0;x<=0;y<=0;scan<=0;head<=0;tail<=0;clear_index<=0;current<=0;cx<=0;cy<=0;dir<=0;range_q<=0;size_q<=0;done_error<=0;error_code<=0;m_disparity<=0;m_invalid<=0;m_removed<=0;end
  else if(ce)case(state)
   IDLE:if(start_valid)begin
    range_q<=cfg_range;size_q<=cfg_max_size;pixel<=0;x<=0;y<=0;scan<=0;done_error<=0;error_code<=0;
    if(cfg_max_size>N)begin done_error<=1;error_code<=1;state<=DONE;end else state<=CAP;
   end
   CAP:if(s_valid)begin
    if(s_sof!=(pixel==0)||s_eol!=(x==WIDTH-1)||s_last!=(pixel==N-1))begin done_error<=1;error_code<=2;state<=DONE;end
    else begin

     if(pixel==N-1)begin scan<=0;state<=SCAN_READ;end
     else begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
    end
   end
   SCAN_READ:state<=SCAN_USE;
   SCAN_USE:begin
    if(visited_q)state<=SCAN_NEXT;
    else begin head<=0;tail<=1;state<=POP_READ;end
   end
   POP_READ:state<=POP_FRAME;
   POP_FRAME:begin current<=queue_q;cx<=queue_q%WIDTH;cy<=queue_q/WIDTH;state<=POP_USE;end
   POP_USE:begin current_disp<=frame_q[DISP_BITS-1:0];dir<=0;state<=NEIGH;end
   NEIGH:begin
    if(neighbor_valid)begin state<=NEIGH_USE;end
    else if(dir==3)state<=POP_NEXT;else dir<=dir+1;
   end
   NEIGH_USE:begin
    if(!visited_q&&!frame_q[DISP_BITS]&&distance<={1'b0,range_q})begin
     if(tail>=N)begin done_error<=1;error_code<=3;state<=DONE;end
     else begin tail<=tail+1;
      if(dir==3)state<=POP_NEXT;else begin dir<=dir+1;state<=NEIGH;end
     end
    end else if(dir==3)state<=POP_NEXT;else begin dir<=dir+1;state<=NEIGH;end
   end
   POP_NEXT:if(head+1<tail)begin head<=head+1;state<=POP_READ;end else state<=COMPLETE;
   COMPLETE:if(tail<=size_q)begin clear_index<=0;state<=REMOVE_READ;end else state<=SCAN_NEXT;
   REMOVE_READ:state<=REMOVE_WRITE;
   REMOVE_WRITE:begin if(clear_index+1==tail)state<=SCAN_NEXT;else begin clear_index<=clear_index+1;state<=REMOVE_READ;end end
   SCAN_NEXT:if(scan==N-1)begin pixel<=0;x<=0;y<=0;state<=OUT_READ;end else begin scan<=scan+1;state<=SCAN_READ;end
   OUT_READ:state<=OUT_USE;
   OUT_USE:begin m_disparity<=frame_q[DISP_BITS-1:0];m_invalid<=frame_q[DISP_BITS]||removed_q;m_removed<=removed_q;state<=HOLD;end
   HOLD:if(m_ready)begin
    if(pixel==N-1)state<=DONE;
    else begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=OUT_READ;end
   end
   DONE:if(done_ready)state<=IDLE;
   default:begin done_error<=1;error_code<=4;state<=DONE;end
  endcase
 end
endmodule
