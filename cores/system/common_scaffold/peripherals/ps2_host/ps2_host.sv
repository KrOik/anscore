// PS/2 open-collector host. Timing/filter/RX continue independently of host CE.
module ps2_host #(parameter CLK_HZ=27000000,FILTER_CYCLES=8,RX_FIFO_DEPTH=16,
 parameter INHIBIT_CYCLES=(CLK_HZ+9999)/10000,REQUEST_CYCLES=(CLK_HZ+99999)/100000,
 parameter EDGE_TIMEOUT_CYCLES=CLK_HZ/100,IDLE_CYCLES=CLK_HZ/20000)(
 input wire clk,rst_n,ce,abort,ps2_clk_in,ps2_data_in,
 output reg ps2_clk_drive_low,ps2_data_drive_low,
 input wire[7:0]tx_data,input wire tx_valid,output wire tx_ready,
 output wire tx_done_valid,input wire tx_done_ready,output reg[7:0]tx_error_code,
 output wire[7:0]rx_data,output wire rx_valid,input wire rx_ready,
 output reg rx_error_valid,input wire rx_error_ready,output reg[7:0]rx_error_code,
 output reg[31:0]rx_error_count,rx_overflow_count,output wire busy);
 localparam AW=RX_FIFO_DEPTH<=1?1:$clog2(RX_FIFO_DEPTH);
 localparam FCW=FILTER_CYCLES<=1?1:$clog2(FILTER_CYCLES+1);
 localparam TI=0,INHIBIT=1,REQUEST=2,BITS=3,ACK=4,RELEASE=5,TDONE=6;
 wire param_bad=CLK_HZ<1000000||CLK_HZ>250000000||FILTER_CYCLES<1||FILTER_CYCLES>32||RX_FIFO_DEPTH<2||RX_FIFO_DEPTH>256||INHIBIT_CYCLES<4||INHIBIT_CYCLES>25000000||REQUEST_CYCLES<2||REQUEST_CYCLES>2500000||EDGE_TIMEOUT_CYCLES<16||EDGE_TIMEOUT_CYCLES>25000000||IDLE_CYCLES<2||IDLE_CYCLES>2500000;
 reg[1:0]cs,ds;reg cf,df,cp;reg[FCW-1:0]cc,dc;
 wire fall=cp&&!cf,rise=!cp&&cf;
 reg[2:0]ts;reg[3:0]tbit,rbit;reg[7:0]tbyte,rbyte;reg parity_bad,locked,rx_active,checked;
 reg[31:0]idle_count,twait,rwait,tcount;
 reg[7:0]fifo[0:RX_FIFO_DEPTH-1];reg[7:0]rq;reg qvalid;reg[AW-1:0]wp,rp;reg[AW:0]count;
 wire consume=ce&&rx_ready&&qvalid;
 // Full ring is never written on its read cycle: no cross-port same-address collision.
 wire fetch=(!qvalid||consume)&&count!=0;
 wire receive_enabled=ts==TI||ts==TDONE;
 wire complete=receive_enabled&&rx_active&&fall&&rbit==9&&!parity_bad&&df&&!param_bad&&!(ce&&abort);
 wire push=complete&&count<RX_FIFO_DEPTH;
 wire overflow=complete&&count==RX_FIFO_DEPTH;
 assign rx_data=rq;assign rx_valid=qvalid;
 assign tx_done_valid=ts==TDONE;
 assign tx_ready=ts==TI&&!rx_active&&(param_bad||(idle_count>=IDLE_CYCLES&&cf&&df&&!fall));
 assign busy=ts!=TI||rx_active;
 always @(posedge clk)begin if(push)fifo[wp]<=rbyte;if(fetch)rq<=fifo[rp];end
 task rx_error;input[7:0]code;begin rx_error_count<=rx_error_count+1'b1;
  if(!rx_error_valid||(ce&&rx_error_ready))begin rx_error_valid<=1;rx_error_code<=code;end
 end endtask
 task tx_finish;input[7:0]code;begin ts<=TDONE;tx_error_code<=code;ps2_clk_drive_low<=0;ps2_data_drive_low<=0;idle_count<=0;locked<=0;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin cs<=3;ds<=3;cf<=1;df<=1;cp<=1;cc<=0;dc<=0;ts<=TI;tbit<=0;rbit<=0;tbyte<=0;rbyte<=0;parity_bad<=0;locked<=0;rx_active<=0;checked<=0;idle_count<=0;twait<=0;rwait<=0;tcount<=0;wp<=0;rp<=0;count<=0;qvalid<=0;rx_error_valid<=0;rx_error_code<=0;rx_error_count<=0;rx_overflow_count<=0;tx_error_code<=0;ps2_clk_drive_low<=0;ps2_data_drive_low<=0;end
 else begin
  cs<={cs[0],ps2_clk_in};ds<={ds[0],ps2_data_in};cp<=cf;
  if(cs[1]==cf)cc<=0;else if(cc==FILTER_CYCLES-1)begin cf<=cs[1];cc<=0;end else cc<=cc+1'b1;
  if(ds[1]==df)dc<=0;else if(dc==FILTER_CYCLES-1)begin df<=ds[1];dc<=0;end else dc<=dc+1'b1;
  if(cf&&df&&receive_enabled&&!rx_active)begin if(idle_count<IDLE_CYCLES)idle_count<=idle_count+1'b1;if(idle_count>=IDLE_CYCLES-1)locked<=1;end else idle_count<=0;
  if(ce&&rx_error_ready)rx_error_valid<=0;
  if(consume)qvalid<=0;
  if(fetch)begin qvalid<=1;rp<=rp==RX_FIFO_DEPTH-1?0:rp+1'b1;end
  if(push)wp<=wp==RX_FIFO_DEPTH-1?0:wp+1'b1;
  case({push,fetch})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
  if(overflow)begin rx_error(4);rx_overflow_count<=rx_overflow_count+1'b1;end
  if(!checked)begin checked<=1;if(param_bad)rx_error(1);end
  if(!param_bad)begin
   if(receive_enabled)begin
    if(rx_active)begin
     if(fall)begin
      rwait<=0;
      if(rbit<8)begin rbyte[rbit]<=df;rbit<=rbit+1'b1;end
      else if(rbit==8)begin parity_bad<=((^rbyte)^df)!=1'b1;rbit<=9;end
      else begin rx_active<=0;rbit<=0;if(parity_bad)begin rx_error(2);locked<=0;end else if(!df)begin rx_error(3);locked<=0;end end
     end else if(rwait>=EDGE_TIMEOUT_CYCLES-1)begin rx_active<=0;locked<=0;rwait<=0;rx_error(6);end else rwait<=rwait+1'b1;
    end else if(fall&&!df&&locked)begin rx_active<=1;rbit<=0;rwait<=0;parity_bad<=0;end
   end
   if(ts==INHIBIT)begin
    if(tcount==INHIBIT_CYCLES-1)begin tcount<=0;ps2_data_drive_low<=1;ts<=REQUEST;end else tcount<=tcount+1'b1;
   end else if(ts==REQUEST)begin
    if(tcount==REQUEST_CYCLES-1)begin tcount<=0;ps2_clk_drive_low<=0;ts<=BITS;twait<=0;tbit<=0;end else tcount<=tcount+1'b1;
   end else if(ts==BITS)begin
    if(fall)begin
     twait<=0;
     if(tbit<8)ps2_data_drive_low<=!tbyte[tbit];
     else if(tbit==8)ps2_data_drive_low<=^tbyte;
     else begin ps2_data_drive_low<=0;ts<=ACK;end
     tbit<=tbit+1'b1;
    end else if(rise&&df==ps2_data_drive_low)tx_finish(7);
    else if(twait>=EDGE_TIMEOUT_CYCLES-1)tx_finish(6);else twait<=twait+1'b1;
   end else if(ts==ACK)begin
    if(rise&&!df)tx_finish(7);
    else if(fall)begin if(df)tx_finish(5);else begin ts<=RELEASE;twait<=0;end end
    else if(twait>=EDGE_TIMEOUT_CYCLES-1)tx_finish(6);else twait<=twait+1'b1;
   end else if(ts==RELEASE)begin
    if(cf&&df)tx_finish(0);else if(twait>=EDGE_TIMEOUT_CYCLES-1)tx_finish(6);else twait<=twait+1'b1;
   end
  end
  if(ts==TDONE&&ce&&tx_done_ready)ts<=TI;
  if(tx_valid&&tx_ready&&ce)begin
   tx_error_code<=0;tbyte<=tx_data;tcount<=0;twait<=0;locked<=0;rx_active<=0;
   if(param_bad)tx_finish(1);else begin ts<=INHIBIT;ps2_clk_drive_low<=1;ps2_data_drive_low<=0;end
  end
  if(ce&&abort)begin
   if(ts!=TI&&ts!=TDONE)tx_finish(9);
   if(rx_active)begin rx_active<=0;locked<=0;rwait<=0;rx_error(9);end
  end
 end end
endmodule
