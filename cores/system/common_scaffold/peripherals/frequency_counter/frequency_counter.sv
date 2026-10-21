// Continuous fixed-clock gates count qualified pin transitions, not periods.
module frequency_counter #(
 parameter COUNT_W=32,GATE_W=32,FILTER_W=8)(
 input wire clk,rst_n,ce,input_pin,start_valid,abort,
 output wire start_ready,input wire [GATE_W-1:0] cfg_gate_clocks,
 input wire [FILTER_W-1:0] cfg_filter,input wire [1:0] cfg_edge_mode,
 input wire cfg_range_enable,input wire [COUNT_W-1:0] cfg_min_edges,cfg_max_edges,
 output wire busy,output reg done_valid,input wire done_ready,output reg [7:0] error_code,
 output wire m_valid,input wire m_ready,output wire [COUNT_W-1:0] m_edges,
 output wire [GATE_W-1:0] m_gate_clocks,output wire [31:0] m_window_index,
 output wire [2:0] m_flags,output reg [31:0] drop_count,output reg drop_sticky);
 localparam IDLE=0,RUN=1,DRAIN=2,DONE=3,PACK_W=COUNT_W+GATE_W+35;
 localparam PARAM_OK=COUNT_W>=8&&COUNT_W<=48&&GATE_W>=8&&GATE_W<=48&&FILTER_W>=1&&FILTER_W<=16;
 reg [1:0] state,occupancy;
 (* ASYNC_REG="TRUE" *) reg sync_meta,sync_pin;
 reg level,overflow_seen,range_enabled;
 reg [1:0] edge_mode;
 reg [FILTER_W-1:0] filter_ticks,stable_count;
 reg [GATE_W-1:0] gate_clocks,gate_elapsed;
 reg [COUNT_W-1:0] edges,min_edges,max_edges;
 reg [31:0] window_index;
 reg event_valid;reg [PACK_W-1:0] event_data,q0,q1;
 wire qualified=(sync_pin!=level)&&(filter_ticks==0||stable_count>=filter_ticks-1'b1);
 wire selected=qualified&&(edge_mode==2||(edge_mode==0&&sync_pin)||(edge_mode==1&&!sync_pin));
 wire overflow_now=overflow_seen||(selected&&(&edges));
 wire [COUNT_W-1:0] counted=(selected&&!(&edges))?edges+1'b1:edges;
 wire range_bad=range_enabled&&(overflow_now||counted<min_edges||counted>max_edges);
 wire pop=ce&&m_ready&&occupancy!=0;
 assign start_ready=state==IDLE;assign busy=state==RUN||state==DRAIN;
 assign m_valid=occupancy!=0;
 assign {m_flags,m_window_index,m_edges,m_gate_clocks}=q0;
 always @(posedge clk)begin
 if(!rst_n)begin
  state<=IDLE;sync_meta<=0;sync_pin<=0;level<=0;stable_count<=0;filter_ticks<=0;
  gate_clocks<=0;gate_elapsed<=0;edges<=0;overflow_seen<=0;edge_mode<=0;
  range_enabled<=0;min_edges<=0;max_edges<=0;window_index<=0;
  event_valid<=0;event_data<=0;done_valid<=0;error_code<=0;
 end else begin
  sync_meta<=input_pin;sync_pin<=sync_meta;event_valid<=0;
  if(sync_pin==level)stable_count<=0;
  else if(qualified)begin level<=sync_pin;stable_count<=0;end
  else stable_count<=stable_count+1'b1;
  case(state)
   IDLE:if(ce&&start_valid)begin
    gate_clocks<=cfg_gate_clocks;filter_ticks<=cfg_filter;edge_mode<=cfg_edge_mode;
    range_enabled<=cfg_range_enable;min_edges<=cfg_min_edges;max_edges<=cfg_max_edges;
    level<=sync_pin;stable_count<=0;gate_elapsed<=0;edges<=0;overflow_seen<=0;window_index<=0;error_code<=0;
    if(!PARAM_OK||cfg_gate_clocks==0||cfg_edge_mode==3||(cfg_range_enable&&cfg_min_edges>cfg_max_edges))begin done_valid<=1;error_code<=1;state<=DONE;end
    else state<=RUN;
   end
   RUN:if(ce&&abort)begin state<=DRAIN;error_code<=3;end
   else if(gate_elapsed==gate_clocks-1'b1)begin
    event_valid<=1;event_data<={{range_bad,overflow_now,counted==0},window_index,counted,gate_clocks};
    gate_elapsed<=0;edges<=0;overflow_seen<=0;window_index<=window_index+1'b1;
   end else begin gate_elapsed<=gate_elapsed+1'b1;edges<=counted;overflow_seen<=overflow_now;end
   DRAIN:if(occupancy==0&&!event_valid)begin done_valid<=1;state<=DONE;end
   DONE:if(ce&&done_ready)begin done_valid<=0;state<=IDLE;end
   default:state<=IDLE;
  endcase
 end end
 // Two retained entries, plus a one-cycle event pipeline which cannot stall.
 always @(posedge clk)begin
 if(!rst_n)begin occupancy<=0;q0<=0;q1<=0;drop_count<=0;drop_sticky<=0;end
 else begin
  if(state==IDLE&&ce&&start_valid)begin drop_count<=0;drop_sticky<=0;end
  case({event_valid,pop})
   2'b01:begin if(occupancy==2)q0<=q1;occupancy<=occupancy-1'b1;end
   2'b10:begin
    if(occupancy==0)begin q0<=event_data;occupancy<=1;end
    else if(occupancy==1)begin q1<=event_data;occupancy<=2;end
    else begin drop_sticky<=1;if(drop_count!=32'hffffffff)drop_count<=drop_count+1'b1;end
   end
   2'b11:begin if(occupancy==2)begin q0<=q1;q1<=event_data;end else q0<=event_data;end
   default:begin end
  endcase
 end end
endmodule
