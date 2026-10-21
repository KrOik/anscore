`default_nettype none
// HX711 24-bit serial acquisition. req_mode selects NEXT conversion, not current data.
module hx711_adc #(
 parameter integer CLOCK_HZ=50000000,SCK_HIGH_NS=1000,SCK_LOW_NS=1000,
 parameter integer READY_GUARD_NS=200,READY_TIMEOUT_US=1000000,
 parameter integer POWERDOWN_US=80,WAKE_US=10,FIFO_DEPTH=4
)(
 input wire clk,rst_n,ce,abort,power_down,
 input wire req_valid,output wire req_ready,input wire[1:0]req_mode,
 input wire dout,output reg pd_sck,
 output wire out_valid,input wire out_ready,output wire signed[23:0]out_data,
 output wire[1:0]out_mode,out_next_mode,output wire[2:0]out_error,output wire[31:0]out_sequence,
 output wire busy,powered_down,
 output reg[31:0]accepted_count,completed_count,dropped_count,timeout_count
);
 localparam[63:0]HI=(64'd1*CLOCK_HZ*SCK_HIGH_NS+999999999)/1000000000;
 localparam[63:0]LO=(64'd1*CLOCK_HZ*SCK_LOW_NS+999999999)/1000000000;
 localparam[63:0]GUARD=(64'd1*CLOCK_HZ*READY_GUARD_NS+999999999)/1000000000;
 localparam[63:0]WAIT_LIMIT=(64'd1*CLOCK_HZ*READY_TIMEOUT_US+999999)/1000000;
 localparam[63:0]PD=(64'd1*CLOCK_HZ*POWERDOWN_US+999999)/1000000;
 localparam[63:0]WAKE=(64'd1*CLOCK_HZ*WAKE_US+999999)/1000000;
 localparam IDLE=0,WAIT_READY=1,GUARD_READY=2,HIGH=3,LOW=4,PD_HOLD=5,WAKING=6;
 localparam PW=$clog2(FIFO_DEPTH),CW=$clog2(FIFO_DEPTH+1);
 reg[2:0]state;
 reg[31:0]timer,wait_timer,sequence_counter,saved_sequence;
 reg[1:0]current_mode,saved_mode,next_mode;
 reg[5:0]pulse;
 reg[23:0]shift;
 (* ASYNC_REG="TRUE" *)reg dout_meta,dout_sync;
 reg[63:0]fifo[0:FIFO_DEPTH-1];
 reg[PW-1:0]write_ptr,read_ptr;
 reg[CW-1:0]count;
 wire pop=out_valid&&out_ready;
 wire active=state==WAIT_READY||state==GUARD_READY||state==HIGH||state==LOW;
 assign req_ready=ce&&!abort&&!power_down&&state==IDLE;
 assign busy=state!=IDLE;
 assign powered_down=state==PD_HOLD;
 assign out_valid=count!=0;
 assign out_data=out_valid?fifo[read_ptr][23:0]:24'b0;
 assign out_mode=out_valid?fifo[read_ptr][25:24]:2'b0;
 assign out_next_mode=out_valid?fifo[read_ptr][27:26]:2'b0;
 assign out_error=out_valid?fifo[read_ptr][30:28]:3'b0;
 assign out_sequence=out_valid?fifo[read_ptr][62:31]:32'b0;
 function[PW-1:0]advance;
 input[PW-1:0]p;begin advance=p==FIFO_DEPTH-1?0:p+1'b1;end endfunction
 function[31:0]inc_sat;
 input[31:0]v;begin inc_sat=&v?v:v+1'b1;end endfunction
 task publish;
 input[23:0]data;input[1:0]mode,nmode;input[2:0]error;input[31:0]seq;
 begin
 completed_count<=inc_sat(completed_count);
 if(count<FIFO_DEPTH||pop)begin
  fifo[write_ptr]<={1'b0,seq,error,nmode,mode,data};write_ptr<=advance(write_ptr);count<=count+(pop?0:1);
 end else dropped_count<=inc_sat(dropped_count);
 end endtask
 task recover;
 begin pd_sck<=1;state<=PD_HOLD;timer<=PD-1;current_mode<=0;end
 endtask
 always @(posedge clk)begin
 if(!rst_n)begin
 // Intentional startup power-down resets the physical ADC's mode to A128.
 state<=PD_HOLD;pd_sck<=1;timer<=PD-1;wait_timer<=0;sequence_counter<=0;saved_sequence<=0;
 current_mode<=0;saved_mode<=0;next_mode<=0;pulse<=0;shift<=0;dout_meta<=1;dout_sync<=1;
 write_ptr<=0;read_ptr<=0;count<=0;accepted_count<=0;completed_count<=0;dropped_count<=0;timeout_count<=0;
 end else begin
 dout_meta<=dout;dout_sync<=dout_meta;
 if(pop)begin read_ptr<=advance(read_ptr);count<=count-1'b1;end
 if((state==WAIT_READY||state==GUARD_READY)&&wait_timer<WAIT_LIMIT-1)wait_timer<=wait_timer+1'b1;
 if(power_down&&state!=PD_HOLD)begin
  if(active)publish(0,saved_mode,next_mode,4,saved_sequence);
  recover;
 end else if(abort&&active)begin publish(0,saved_mode,next_mode,3,saved_sequence);recover;end
 else case(state)
 PD_HOLD:begin
  pd_sck<=1;
  if(timer!=0)timer<=timer-1'b1;
  else if(!power_down)begin pd_sck<=0;state<=WAKING;timer<=WAKE-1;end
 end
 WAKING:if(timer!=0)timer<=timer-1'b1;else state<=IDLE;
 IDLE:if(req_valid&&req_ready)begin
  accepted_count<=inc_sat(accepted_count);sequence_counter<=sequence_counter+1'b1;
  if(req_mode==3)publish(0,current_mode,req_mode,1,sequence_counter);
  else begin
   saved_sequence<=sequence_counter;saved_mode<=current_mode;next_mode<=req_mode;
   wait_timer<=0;shift<=0;pulse<=0;state<=WAIT_READY;
  end
 end
 WAIT_READY:if(!dout_sync)begin timer<=GUARD-1;state<=GUARD_READY;end
 else if(wait_timer==WAIT_LIMIT-1)begin
  timeout_count<=inc_sat(timeout_count);publish(0,saved_mode,next_mode,2,saved_sequence);state<=IDLE;
 end
 GUARD_READY:if(dout_sync)begin
  if(wait_timer==WAIT_LIMIT-1)begin timeout_count<=inc_sat(timeout_count);publish(0,saved_mode,next_mode,2,saved_sequence);state<=IDLE;end
  else state<=WAIT_READY;
 end else if(timer!=0)timer<=timer-1'b1;
 else begin pd_sck<=1;timer<=HI-1;state<=HIGH;end
 HIGH:if(timer!=0)timer<=timer-1'b1;
 else begin
  // HX711 data is stable <=100ns after rising SCK. Sample at end of >=200ns high.
  if(pulse<24)shift<={shift[22:0],dout};
  pd_sck<=0;timer<=LO-1;state<=LOW;
 end
 LOW:if(timer!=0)timer<=timer-1'b1;
 else if(pulse==24+next_mode)begin
  publish(shift,saved_mode,next_mode,0,saved_sequence);current_mode<=next_mode;state<=IDLE;
 end else begin pulse<=pulse+1'b1;pd_sck<=1;timer<=HI-1;state<=HIGH;end
 default:recover;
 endcase
 end end
 initial if(CLOCK_HZ<1000000||CLOCK_HZ>250000000||SCK_HIGH_NS<200||SCK_HIGH_NS>49000||SCK_LOW_NS<200||SCK_LOW_NS>1000000||READY_GUARD_NS<100||READY_GUARD_NS>1000000||READY_TIMEOUT_US<1||POWERDOWN_US<61||POWERDOWN_US>1000||WAKE_US<1||WAKE_US>1000000||FIFO_DEPTH<2||FIFO_DEPTH>16||HI*1000000000>=64'd50000*CLOCK_HZ||WAIT_LIMIT>64'hffffffff)$fatal(1,"invalid HX711 parameters");
endmodule
`default_nettype wire
