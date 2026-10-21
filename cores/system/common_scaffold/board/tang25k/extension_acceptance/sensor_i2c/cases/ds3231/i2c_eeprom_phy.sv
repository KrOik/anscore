// Narrow byte/START/STOP engine; physical timing is independent of host CE.
// Open-drain enables only: externally combine with pull-ups and other devices.
module i2c_eeprom_phy #(
 parameter HALF_PERIOD_CYCLES=68,STRETCH_TIMEOUT_CYCLES=270000
)(input wire clk,rst_n,
 input wire request_valid,output wire request_ready,input wire[1:0]request_kind,
 input wire[7:0]request_byte,input wire request_nack,
 output reg response_valid,input wire response_ready,output reg[7:0]response_byte,
 output reg response_nack,output reg[3:0]response_error,
 input wire scl_in,sda_in,output reg scl_drive_low,sda_drive_low);
 localparam IDLE=0,START_LOW=1,START_WAIT=2,START_HIGH=3,START_HOLD=4,
 BIT_LOW=5,BIT_WAIT=6,BIT_HIGH=7,ACK_LOW=8,ACK_WAIT=9,ACK_HIGH=10,
 STOP_LOW=11,STOP_WAIT=12,STOP_HIGH=13,STOP_FREE=14;
 reg[3:0]state;reg[31:0]timer,stretch;reg active,reading,nack;
 reg[7:0]tx,rx;reg[2:0]bit_index;
 (* ASYNC_REG="TRUE" *)reg[1:0]scl_sync,sda_sync;
 assign request_ready=state==IDLE&&!response_valid;
 task finish;input[3:0]err;begin
  state<=IDLE;response_valid<=1;response_error<=err;response_byte<=rx;
  if(err!=0)begin scl_drive_low<=0;sda_drive_low<=0;active<=0;end
 end endtask
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;timer<=0;stretch<=0;active<=0;reading<=0;nack<=0;tx<=0;rx<=0;bit_index<=0;
   scl_sync<=3;sda_sync<=3;scl_drive_low<=0;sda_drive_low<=0;
   response_valid<=0;response_byte<=0;response_nack<=0;response_error<=0;
  end else begin
   scl_sync<={scl_sync[0],scl_in};sda_sync<={sda_sync[0],sda_in};
   if(response_valid&&response_ready)response_valid<=0;
   case(state)
    IDLE:if(request_valid&&request_ready)begin
     response_nack<=0;response_error<=0;rx<=0;bit_index<=0;stretch<=0;timer<=HALF_PERIOD_CYCLES-1;
     tx<=request_byte;reading<=request_kind==3;nack<=request_nack;
     if(HALF_PERIOD_CYCLES<4||STRETCH_TIMEOUT_CYCLES<4)finish(8);
     else case(request_kind)
      0:begin sda_drive_low<=0;if(active)begin scl_drive_low<=1;state<=START_LOW;end else begin scl_drive_low<=0;state<=START_WAIT;end end
      1:begin scl_drive_low<=1;sda_drive_low<=1;state<=STOP_LOW;end
      default:if(!active)finish(8);else begin scl_drive_low<=1;sda_drive_low<=request_kind==3?0:~request_byte[7];state<=BIT_LOW;end
     endcase
    end
    START_LOW:if(timer!=0)timer<=timer-1;else begin scl_drive_low<=0;stretch<=0;state<=START_WAIT;end
    START_WAIT:if(scl_sync[1]&&sda_sync[1])begin timer<=HALF_PERIOD_CYCLES-1;state<=START_HIGH;end
     else if(stretch>=STRETCH_TIMEOUT_CYCLES-1)finish(5);else stretch<=stretch+1;
    START_HIGH:if(!scl_sync[1]||!sda_sync[1])finish(4);
     else if(timer!=0)timer<=timer-1;else begin sda_drive_low<=1;timer<=HALF_PERIOD_CYCLES-1;state<=START_HOLD;end
    START_HOLD:if(timer!=0)timer<=timer-1;else begin scl_drive_low<=1;active<=1;finish(0);end
    BIT_LOW:if(timer!=0)timer<=timer-1;else begin scl_drive_low<=0;stretch<=0;state<=BIT_WAIT;end
    BIT_WAIT:if(scl_sync[1])begin timer<=HALF_PERIOD_CYCLES-1;state<=BIT_HIGH;end
     else if(stretch>=STRETCH_TIMEOUT_CYCLES-1)finish(3);else stretch<=stretch+1;
    BIT_HIGH:if(timer!=0)timer<=timer-1;
     else if(!reading&&tx[7-bit_index]&&!sda_sync[1])finish(4);
     else begin
      if(reading)rx[7-bit_index]<=sda_sync[1];scl_drive_low<=1;timer<=HALF_PERIOD_CYCLES-1;
      if(bit_index==7)begin sda_drive_low<=reading?!nack:0;state<=ACK_LOW;end
      else begin bit_index<=bit_index+1;if(!reading)sda_drive_low<=~tx[6-bit_index];state<=BIT_LOW;end
     end
    ACK_LOW:if(timer!=0)timer<=timer-1;else begin scl_drive_low<=0;stretch<=0;state<=ACK_WAIT;end
    ACK_WAIT:if(scl_sync[1])begin timer<=HALF_PERIOD_CYCLES-1;state<=ACK_HIGH;end
     else if(stretch>=STRETCH_TIMEOUT_CYCLES-1)finish(3);else stretch<=stretch+1;
    ACK_HIGH:if(timer!=0)timer<=timer-1;else begin
     if(reading&&nack&&!sda_sync[1])finish(4);
     else begin response_nack<=!reading&&sda_sync[1];scl_drive_low<=1;sda_drive_low<=0;finish(0);end
    end
    STOP_LOW:if(timer!=0)timer<=timer-1;else begin scl_drive_low<=0;stretch<=0;state<=STOP_WAIT;end
    STOP_WAIT:if(scl_sync[1])begin timer<=HALF_PERIOD_CYCLES-1;state<=STOP_HIGH;end
     else if(stretch>=STRETCH_TIMEOUT_CYCLES-1)finish(3);else stretch<=stretch+1;
    STOP_HIGH:if(timer!=0)timer<=timer-1;else begin sda_drive_low<=0;timer<=HALF_PERIOD_CYCLES-1;state<=STOP_FREE;end
    STOP_FREE:if(timer!=0)timer<=timer-1;else if(!scl_sync[1]||!sda_sync[1])finish(5);else begin active<=0;finish(0);end
    default:finish(8);
   endcase
  end
 end
endmodule
