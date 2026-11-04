`timescale 1ns/1ps
module weighted_interval_schedule #(
 parameter integer MAX_ITEMS=16, ENDPOINT_W=16, WEIGHT_W=16, TAG_W=8
)(
 input wire clk, rst,
 input wire s_valid, output wire s_ready,
 input wire signed [ENDPOINT_W-1:0] s_start, s_end,
 input wire [WEIGHT_W-1:0] s_weight,
 input wire s_keep, s_last, input wire [TAG_W-1:0] s_tag,
 output wire m_valid, input wire m_ready,
 output wire m_keep, m_first, m_last,
 output reg [((MAX_ITEMS<=1)?1:$clog2(MAX_ITEMS))-1:0] m_index,
 output reg signed [ENDPOINT_W-1:0] m_start, m_end,
 output reg [WEIGHT_W-1:0] m_weight,
 output wire m_selected,
 output wire [$clog2(MAX_ITEMS+1)-1:0] m_count,
 output wire [WEIGHT_W+$clog2(MAX_ITEMS)-1:0] m_total_weight,
 output wire [MAX_ITEMS-1:0] m_selection,
 output wire [TAG_W-1:0] m_tag, output wire [1:0] m_error
);
 localparam integer IW=(MAX_ITEMS<=1)?1:$clog2(MAX_ITEMS);
 localparam integer CW=$clog2(MAX_ITEMS+1);
 localparam integer SW=WEIGHT_W+$clog2(MAX_ITEMS);
 localparam integer RW=2*ENDPOINT_W+WEIGHT_W;
 localparam integer DW=SW+MAX_ITEMS;
 generate if(MAX_ITEMS<1 || MAX_ITEMS>64 || ENDPOINT_W<2 || ENDPOINT_W>32 ||
             WEIGHT_W<1 || WEIGHT_W>32 || TAG_W<1 || TAG_W>32) begin: bad
  weighted_interval_schedule_invalid_parameters__see_README invalid();
 end endgenerate
 localparam [3:0] COLLECT=0, SELECT_READ=1, SELECT_EVAL=2, PRED_SETUP=3,
  PRED_READ=4, PRED_EVAL=5, COMMIT=6, REPLAY_READ=7, REPLAY_LOAD=8, OUTPUT=9;
 reg [3:0] state;
 reg [RW-1:0] items[0:MAX_ITEMS-1];
 reg [DW-1:0] chains[0:MAX_ITEMS-1];
 reg [RW-1:0] item_q;
 reg [DW-1:0] chain_q;
 wire signed [ENDPOINT_W-1:0] q_start=item_q[RW-1:ENDPOINT_W+WEIGHT_W];
 wire signed [ENDPOINT_W-1:0] q_end=item_q[ENDPOINT_W+WEIGHT_W-1:WEIGHT_W];
 wire [WEIGHT_W-1:0] q_weight=item_q[WEIGHT_W-1:0];
 wire [SW-1:0] q_sum=chain_q[DW-1:MAX_ITEMS];
 wire [MAX_ITEMS-1:0] q_mask=chain_q[MAX_ITEMS-1:0];
 reg [CW-1:0] count, completed;
 reg [IW-1:0] scan, chosen_index;
 reg [MAX_ITEMS-1:0] processed, base_mask, best_mask;
 reg [SW-1:0] base_sum, best_sum;
 reg signed [ENDPOINT_W-1:0] chosen_start, chosen_end;
 reg [WEIGHT_W-1:0] chosen_weight;
 reg chosen_valid, frame_open;
 reg [1:0] errors;
 reg [TAG_W-1:0] tag;
 wire [MAX_ITEMS-1:0] chosen_bit={{(MAX_ITEMS-1){1'b0}},1'b1} << chosen_index;
 wire [MAX_ITEMS-1:0] candidate_mask=base_mask | chosen_bit;
 wire [SW-1:0] candidate_sum=base_sum+{{(SW-WEIGHT_W){1'b0}},chosen_weight};
 wire overflow_now=s_keep && count==MAX_ITEMS;
 wire geometry_now=s_keep && s_start>=s_end;
 wire [1:0] next_errors=errors | {geometry_now,overflow_now};
 assign s_ready=!rst && state==COLLECT;
 assign m_valid=!rst && state==OUTPUT;
 assign m_keep=(count!=0 && errors==0);
 assign m_first=(m_index==0);
 assign m_last=!m_keep || (m_index==count-1'b1);
 assign m_selected=m_keep && best_mask[m_index];
 assign m_count=(errors!=0)?{CW{1'b0}}:count;
 assign m_total_weight=best_sum;
 assign m_selection=best_mask;
 assign m_error=errors;
 assign m_tag=tag;

 // Neither array is reset. Ownership gates every read of a chain record.
 always @(posedge clk) begin
  if(rst) begin
   state<=COLLECT;count<=0;completed<=0;scan<=0;chosen_index<=0;
   processed<=0;base_mask<=0;best_mask<=0;base_sum<=0;best_sum<=0;
   chosen_start<=0;chosen_end<=0;chosen_weight<=0;chosen_valid<=0;
   frame_open<=0;errors<=0;tag<=0;item_q<=0;chain_q<=0;
   m_index<=0;m_start<=0;m_end<=0;m_weight<=0;
  end else begin
   if(state==SELECT_READ || state==PRED_READ) item_q<=items[scan];
   if(state==PRED_READ) chain_q<=chains[scan];
   if(state==REPLAY_READ) item_q<=items[m_index];
   case(state)
    COLLECT: if(s_valid) begin
     if(!frame_open) begin tag<=s_tag;frame_open<=1;end
     errors<=next_errors;
     if(s_keep && count<MAX_ITEMS) begin
      items[count[IW-1:0]]<={s_start,s_end,s_weight};count<=count+1'b1;
     end
     if(s_last) begin
      m_index<=0;m_start<=0;m_end<=0;m_weight<=0;
      if(next_errors!=0 || (count==0 && !s_keep)) state<=OUTPUT;
      else begin
       processed<=0;completed<=0;scan<=0;chosen_valid<=0;state<=SELECT_READ;
      end
     end
    end
    SELECT_READ: state<=SELECT_EVAL;
    SELECT_EVAL: begin
     if(!processed[scan] && (!chosen_valid || q_end<chosen_end ||
         (q_end==chosen_end && scan<chosen_index))) begin
      chosen_index<=scan;chosen_start<=q_start;chosen_end<=q_end;
      chosen_weight<=q_weight;chosen_valid<=1;
     end
     if(scan==count-1'b1) state<=PRED_SETUP;
     else begin scan<=scan+1'b1;state<=SELECT_READ;end
    end
    PRED_SETUP: begin scan<=0;base_sum<=0;base_mask<=0;state<=PRED_READ;end
    PRED_READ: state<=PRED_EVAL;
    PRED_EVAL: begin
     if(processed[scan] && q_end<=chosen_start &&
        (q_sum>base_sum || (q_sum==base_sum && q_mask<base_mask))) begin
      base_sum<=q_sum;base_mask<=q_mask;
     end
     if(scan==count-1'b1) state<=COMMIT;
     else begin scan<=scan+1'b1;state<=PRED_READ;end
    end
    COMMIT: begin
     chains[chosen_index]<={candidate_sum,candidate_mask};
     processed[chosen_index]<=1;completed<=completed+1'b1;
     if(candidate_sum>best_sum || (candidate_sum==best_sum && candidate_mask<best_mask)) begin
      best_sum<=candidate_sum;best_mask<=candidate_mask;
     end
     if(completed==count-1'b1) begin m_index<=0;state<=REPLAY_READ;end
     else begin scan<=0;chosen_valid<=0;state<=SELECT_READ;end
    end
    REPLAY_READ: state<=REPLAY_LOAD;
    REPLAY_LOAD: begin
     m_start<=q_start;m_end<=q_end;m_weight<=q_weight;state<=OUTPUT;
    end
    OUTPUT: if(m_ready) begin
     if(m_last) begin
      state<=COLLECT;count<=0;errors<=0;frame_open<=0;best_sum<=0;best_mask<=0;
     end else begin m_index<=m_index+1'b1;state<=REPLAY_READ;end
    end
    default: state<=COLLECT;
   endcase
  end
 end
endmodule
