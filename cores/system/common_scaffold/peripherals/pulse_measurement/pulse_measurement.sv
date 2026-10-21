// Physical input measurement runs every clk; host streams alone are CE-qualified.
module pulse_measurement #(
 parameter COUNTER_W=32, parameter FILTER_W=8
)(
 input wire clk,rst_n,ce,input wire input_pin,
 input wire start_valid,output wire start_ready,input wire cfg_active_high,
 input wire [FILTER_W-1:0] cfg_filter,
 input wire [COUNTER_W-1:0] cfg_timeout,cfg_min_high,cfg_max_high,cfg_min_low,cfg_max_low,
 input wire abort,output wire busy,output reg done_valid,input wire done_ready,
 output reg [7:0] error_code,
 output wire m_valid,input wire m_ready,
 output wire [COUNTER_W-1:0] m_high,m_low,m_period,
 output wire m_is_cycle,output wire [2:0] m_flags,
 output reg [31:0] drop_count,output reg drop_sticky
);
 localparam PARAM_OK=COUNTER_W>=16&&COUNTER_W<=48&&FILTER_W>=1&&FILTER_W<=16;
 localparam IDLE=0,RUN=1,DRAIN=2,DONE=3;
 localparam UNLOCKED=0,HIGH=1,LOW=2;
 localparam PACK_W=3*COUNTER_W+4;
 reg [1:0] state,phase,occupancy;
 (* ASYNC_REG="TRUE" *) reg sync_meta,sync_pin;
 reg level,polarity,fault_latched;
 reg [FILTER_W-1:0] filter_ticks,stable_count;
 reg [COUNTER_W-1:0] elapsed,high_saved,timeout_ticks,min_high,max_high,min_low,max_low;
 reg event_valid;reg [PACK_W-1:0] event_data,q0,q1;
 wire edge_qualified=(sync_pin!=level)&&(filter_ticks==0||stable_count>=filter_ticks-1'b1);
 wire active_edge=sync_pin==polarity;
 wire [COUNTER_W:0] interval={1'b0,elapsed}+1'b1;
 wire [COUNTER_W:0] sum_period={1'b0,high_saved}+interval;
 wire range_bad=high_saved<min_high||high_saved>max_high||interval<{1'b0,min_low}||interval>{1'b0,max_low};
 wire pop=ce&&m_ready&&occupancy!=0;
 assign start_ready=state==IDLE;
 assign busy=state==RUN||state==DRAIN;
 assign m_valid=occupancy!=0;
 assign {m_is_cycle,m_flags,m_high,m_low,m_period}=q0;
 always @(posedge clk) begin
  if(!rst_n)begin
   sync_meta<=0;sync_pin<=0;level<=0;stable_count<=0;
   state<=IDLE;phase<=UNLOCKED;polarity<=1;fault_latched<=0;
   filter_ticks<=0;elapsed<=0;high_saved<=0;timeout_ticks<=0;
   min_high<=0;max_high<=0;min_low<=0;max_low<=0;
   event_valid<=0;event_data<=0;done_valid<=0;error_code<=0;
  end else begin
   sync_meta<=input_pin;sync_pin<=sync_meta;
   event_valid<=0;
   if(sync_pin==level)stable_count<=0;
   else if(edge_qualified)begin level<=sync_pin;stable_count<=0;end
   else stable_count<=stable_count+1'b1;
   case(state)
    IDLE:if(ce&&start_valid)begin
     polarity<=cfg_active_high;filter_ticks<=cfg_filter;timeout_ticks<=cfg_timeout;
     min_high<=cfg_min_high;max_high<=cfg_max_high;min_low<=cfg_min_low;max_low<=cfg_max_low;
     level<=sync_pin;stable_count<=0;elapsed<=0;high_saved<=0;
     phase<=UNLOCKED;fault_latched<=0;error_code<=0;
     if(!PARAM_OK||cfg_min_high==0||cfg_min_low==0||cfg_max_high<cfg_min_high||cfg_max_low<cfg_min_low)begin
      done_valid<=1;error_code<=1;state<=DONE;
     end else state<=RUN;
    end
    RUN:if(ce&&abort)begin state<=DRAIN;error_code<=3;phase<=UNLOCKED;end
    else if(edge_qualified)begin
     elapsed<=0;fault_latched<=0;
     if(phase!=UNLOCKED&&interval[COUNTER_W])begin
      event_valid<=1;event_data<={1'b0,3'b010,{(3*COUNTER_W){1'b0}}};phase<=UNLOCKED;fault_latched<=1;
     end else if(active_edge)begin
      if(phase==LOW)begin
       event_valid<=1;
       event_data<={1'b1,{range_bad,sum_period[COUNTER_W],1'b0},high_saved,interval[COUNTER_W-1:0],sum_period[COUNTER_W]?{COUNTER_W{1'b1}}:sum_period[COUNTER_W-1:0]};
      end
      phase<=HIGH;
     end else if(phase==HIGH)begin high_saved<=interval[COUNTER_W-1:0];phase<=LOW;end
     else phase<=UNLOCKED;
    end else if(!fault_latched)begin
     if(timeout_ticks!=0&&elapsed>=timeout_ticks-1'b1)begin
      event_valid<=1;event_data<={1'b0,3'b001,{(3*COUNTER_W){1'b0}}};
      elapsed<=0;phase<=UNLOCKED;fault_latched<=1;
     end else if(&elapsed)begin
      event_valid<=1;event_data<={1'b0,3'b010,{(3*COUNTER_W){1'b0}}};
      elapsed<=0;phase<=UNLOCKED;fault_latched<=1;
     end else elapsed<=elapsed+1'b1;
    end
    DRAIN:if(occupancy==0&&!event_valid)begin state<=DONE;done_valid<=1;end
    DONE:if(ce&&done_ready)begin done_valid<=0;state<=IDLE;end
    default:state<=IDLE;
   endcase
  end
 end
 // Two-entry FIFO. Exposed q0 is never overwritten while it is stalled.
 // If both entries are occupied and no host transfer occurs, drop the NEW event.
 always @(posedge clk) begin
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
    2'b11:begin
     if(occupancy==2)begin q0<=q1;q1<=event_data;end else q0<=event_data;
    end
    default:begin end
   endcase
  end
 end
endmodule
