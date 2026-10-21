// 8080-style parallel LCD transaction engine. IO tristate belongs at pad boundary.
module lcd8080_engine #(
 parameter BUS_WIDTH=8, parameter COUNT_W=16
)(
 input wire clk,rst_n,ce,
 input wire start_valid, output wire start_ready,
 input wire read_mode,data_mode, input wire [COUNT_W-1:0] count,
 input wire [15:0] cfg_setup,cfg_pulse,cfg_hold,cfg_turnaround,
 input wire [31:0] cfg_timeout,
 input wire tx_valid, output wire tx_ready, input wire [BUS_WIDTH-1:0] tx_data,
 output reg rx_valid, input wire rx_ready, output reg [BUS_WIDTH-1:0] rx_data,
 output reg rx_last,
 input wire abort, output wire busy,
 output reg done_valid, input wire done_ready, output reg [7:0] error_code,
 output wire lcd_cs_n,lcd_rd_n,lcd_wr_n,lcd_rs,
 output wire [BUS_WIDTH-1:0] lcd_data_out, output wire lcd_data_oe,
 input wire [BUS_WIDTH-1:0] lcd_data_in
);
 localparam IDLE=0,WAIT_TX=1,TURN=2,SETUP=3,PULSE=4,HOLD=5,WAIT_RX=6,DONE=7;
 localparam PARAM_OK=(BUS_WIDTH==8||BUS_WIDTH==16)&&(COUNT_W>=1&&COUNT_W<=24);
 reg [2:0] state;
 reg rd,rs;
 reg [COUNT_W-1:0] remaining;
 reg [BUS_WIDTH-1:0] tx_latch;
 reg [15:0] setup_ticks,pulse_ticks,hold_ticks,turn_ticks,ticks;
 reg [31:0] limit,age;
 reg [7:0] pending_error;
 wire active=(state!=IDLE&&state!=DONE);
 wire timeout_hit=active&&limit!=0&&age>=limit-1;
 wire abort_hit=active&&ce&&abort;
 wire [7:0] fault_now=(pending_error!=0)?pending_error:abort_hit?8'd3:timeout_hit?8'd2:8'd0;
 assign busy=active;
 assign start_ready=(state==IDLE);
 assign tx_ready=(state==WAIT_TX)&&pending_error==0;
 assign lcd_cs_n=!(state==SETUP||state==PULSE||state==HOLD);
 assign lcd_rd_n=!(state==PULSE&&rd);
 assign lcd_wr_n=!(state==PULSE&&!rd);
 assign lcd_rs=rs;
 assign lcd_data_out=tx_latch;
 assign lcd_data_oe=!rd&&(state==SETUP||state==PULSE||state==HOLD);
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;rd<=0;rs<=0;remaining<=0;tx_latch<=0;
   setup_ticks<=0;pulse_ticks<=0;hold_ticks<=0;turn_ticks<=0;ticks<=0;
   limit<=0;age<=0;pending_error<=0;done_valid<=0;error_code<=0;
   rx_valid<=0;rx_data<=0;rx_last<=0;
  end else begin
   if(active) begin
    if(age!=32'hffffffff) age<=age+1'b1;
    if(pending_error==0) begin
     if(abort_hit) pending_error<=3;
     else if(timeout_hit) pending_error<=2;
    end
   end
   case(state)
    IDLE: if(ce&&start_valid) begin
     error_code<=0;pending_error<=0;age<=0;rx_valid<=0;rx_last<=0;
     rd<=read_mode;rs<=data_mode;remaining<=count;
     setup_ticks<=cfg_setup;pulse_ticks<=cfg_pulse;hold_ticks<=cfg_hold;
     turn_ticks<=cfg_turnaround;limit<=cfg_timeout;
     if(!PARAM_OK||count==0||cfg_setup==0||cfg_pulse==0||cfg_hold==0||cfg_turnaround==0) begin
      error_code<=1;done_valid<=1;state<=DONE;
     end else if(read_mode) begin state<=TURN;ticks<=cfg_turnaround;end
     else state<=WAIT_TX;
    end
    WAIT_TX: begin
     if(fault_now!=0) begin error_code<=fault_now;done_valid<=1;state<=DONE;end
     else if(ce&&tx_valid) begin tx_latch<=tx_data;state<=TURN;ticks<=turn_ticks;end
    end
    TURN: if(ticks==1) begin state<=SETUP;ticks<=setup_ticks;end else ticks<=ticks-1'b1;
    SETUP: if(ticks==1) begin state<=PULSE;ticks<=pulse_ticks;end else ticks<=ticks-1'b1;
    PULSE: if(ticks==1) begin
     if(rd) begin rx_data<=lcd_data_in;rx_last<=remaining==1;end
     state<=HOLD;ticks<=hold_ticks;
    end else ticks<=ticks-1'b1;
    HOLD: if(ticks==1) begin
     if(fault_now!=0) begin error_code<=fault_now;done_valid<=1;state<=DONE;rx_valid<=0;end
     else if(rd) begin rx_valid<=1;state<=WAIT_RX;end
     else if(remaining==1) begin done_valid<=1;state<=DONE;end
     else begin remaining<=remaining-1'b1;state<=WAIT_TX;end
    end else ticks<=ticks-1'b1;
    WAIT_RX: begin
     // Once exposed, an RX token is irrevocable until host acceptance, even
     // when abort/timeout has become pending. No further bus cycle is issued.
     if(ce&&rx_ready) begin
      rx_valid<=0;
      if(fault_now!=0) begin error_code<=fault_now;done_valid<=1;state<=DONE;end
      else if(remaining==1) begin done_valid<=1;state<=DONE;end
      else begin remaining<=remaining-1'b1;state<=TURN;ticks<=turn_ticks;end
     end
    end
    DONE: if(ce&&done_ready) begin done_valid<=0;state<=IDLE;end
    default: begin state<=IDLE;rx_valid<=0;done_valid<=0;end
   endcase
  end
 end
endmodule
