// 24xx EEPROM transaction scheduler: 8/16-bit word address, external pull-ups.
// Supports 24C02-style and 24LC256/512-style addressing, not bank-select 24C04..16.
module i2c_eeprom #(
 parameter ADDR_BYTES=2,CAPACITY_BYTES=32768,PAGE_BYTES=64,
 HALF_PERIOD_CYCLES=68,STRETCH_TIMEOUT_CYCLES=270000,
 POLL_LIMIT=100,POLL_GAP_CYCLES=270,HOST_TIMEOUT_CYCLES=27000000
)(input wire clk,rst_n,ce,
 input wire start_valid,output wire start_ready,input wire write,
 input wire[6:0]device_address,input wire[15:0]word_address,length,
 input wire tx_valid,output wire tx_ready,input wire[7:0]tx_data,
 output wire rx_valid,input wire rx_ready,output reg[7:0]rx_data,output reg rx_last,
 output wire busy,done_valid,input wire done_ready,output reg[3:0]error_code,
 output reg[15:0]bytes_completed,
 input wire scl_in,sda_in,output wire scl_drive_low,sda_drive_low);
 localparam BAD=(ADDR_BYTES!=1&&ADDR_BYTES!=2)||CAPACITY_BYTES<1||CAPACITY_BYTES>65536||
 (ADDR_BYTES==1&&CAPACITY_BYTES>256)||PAGE_BYTES<1||PAGE_BYTES>256||
 (PAGE_BYTES&(PAGE_BYTES-1))!=0||PAGE_BYTES>CAPACITY_BYTES||HALF_PERIOD_CYCLES<4||
 STRETCH_TIMEOUT_CYCLES<4||POLL_LIMIT<1||POLL_LIMIT>65535||POLL_GAP_CYCLES<1||HOST_TIMEOUT_CYCLES<1;
 localparam IDLE=0,START=1,DEVW=2,AHI=3,ALO=4,TXHOLD=5,TXBYTE=6,RESTART=7,DEVR=8,
 RXBYTE=9,RXHOLD=10,WRITE_STOP=11,POLL_START=12,POLL_DEV=13,POLL_STOP=14,
 POLL_GAP=15,READ_STOP=16,FAIL_STOP=17,DONE=18;
 reg[4:0]state;reg waiting,writing;reg[6:0]dev;reg[15:0]address,remaining;
 reg[7:0]tx_latch;reg[15:0]poll_count;reg poll_ack;reg[31:0]host_age,gap;
 reg[3:0]pending_error;
 wire command_ready,response_valid,response_nack;wire[7:0]response_byte;wire[3:0]response_error;
 reg command_valid;reg[1:0]command_kind;reg[7:0]command_byte;reg command_nack;
 assign start_ready=state==IDLE;
 assign busy=state!=IDLE&&state!=DONE;
 assign done_valid=state==DONE;
 assign tx_ready=state==TXHOLD&&ce;
 assign rx_valid=state==RXHOLD;
 i2c_eeprom_phy #(.HALF_PERIOD_CYCLES(HALF_PERIOD_CYCLES),.STRETCH_TIMEOUT_CYCLES(STRETCH_TIMEOUT_CYCLES)) phy(
 .clk(clk),.rst_n(rst_n),.request_valid(command_valid),.request_ready(command_ready),
 .request_kind(command_kind),.request_byte(command_byte),.request_nack(command_nack),
 .response_valid(response_valid),.response_ready(waiting),.response_byte(response_byte),
 .response_nack(response_nack),.response_error(response_error),.scl_in(scl_in),.sda_in(sda_in),
 .scl_drive_low(scl_drive_low),.sda_drive_low(sda_drive_low));
 always @*begin
  command_valid=!waiting;command_kind=2;command_byte=0;command_nack=0;
  case(state)
   START,RESTART,POLL_START:command_kind=0;
   WRITE_STOP,POLL_STOP,READ_STOP,FAIL_STOP:command_kind=1;
   DEVW,POLL_DEV:command_byte={dev,1'b0};
   DEVR:command_byte={dev,1'b1};
   AHI:command_byte=address[15:8];ALO:command_byte=address[7:0];TXBYTE:command_byte=tx_latch;
   RXBYTE:begin command_kind=3;command_nack=remaining==1;end
   default:command_valid=0;
  endcase
 end
 task finish;input[3:0]code;begin state<=DONE;error_code<=code;waiting<=0;end endtask
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;waiting<=0;writing<=0;dev<=0;address<=0;remaining<=0;tx_latch<=0;
   poll_count<=0;poll_ack<=0;host_age<=0;gap<=0;pending_error<=0;
   rx_data<=0;rx_last<=0;error_code<=0;bytes_completed<=0;
  end else begin
   if(command_valid&&command_ready)waiting<=1;
   if(waiting&&response_valid)begin
    waiting<=0;
    if(response_error!=0)finish(response_error);
    else case(state)
     START:state<=DEVW;
     DEVW:if(response_nack)begin pending_error<=1;state<=FAIL_STOP;end else state<=ADDR_BYTES==2?AHI:ALO;
     AHI:if(response_nack)begin pending_error<=2;state<=FAIL_STOP;end else state<=ALO;
     ALO:if(response_nack)begin pending_error<=2;state<=FAIL_STOP;end else begin state<=writing?TXHOLD:RESTART;host_age<=0;end
     TXBYTE:if(response_nack)begin pending_error<=2;state<=FAIL_STOP;end else begin
      bytes_completed<=bytes_completed+1'b1;address<=address+1'b1;remaining<=remaining-1'b1;
      host_age<=0;
      if(remaining==1||((address+1'b1)&(PAGE_BYTES-1))==0)state<=WRITE_STOP;else state<=TXHOLD;
     end
     RESTART:state<=DEVR;
     DEVR:if(response_nack)begin pending_error<=1;state<=FAIL_STOP;end else state<=RXBYTE;
     RXBYTE:begin rx_data<=response_byte;rx_last<=remaining==1;state<=RXHOLD;end
     WRITE_STOP:begin poll_count<=0;gap<=0;state<=POLL_GAP;end
     POLL_START:state<=POLL_DEV;
     POLL_DEV:begin poll_ack<=!response_nack;state<=POLL_STOP;
      if(response_nack&&poll_count>=POLL_LIMIT-1)pending_error<=6;
     end
     POLL_STOP:if(pending_error!=0)finish(pending_error);
      else if(poll_ack)begin if(remaining==0)finish(0);else state<=START;end
      else begin poll_count<=poll_count+1'b1;gap<=0;state<=POLL_GAP;end
     READ_STOP:finish(0);
     FAIL_STOP:finish(pending_error);
     default:finish(8);
    endcase
   end
   case(state)
    IDLE:if(ce&&start_valid)begin
     dev<=device_address;writing<=write;address<=word_address;remaining<=length;
     bytes_completed<=0;error_code<=0;pending_error<=0;host_age<=0;waiting<=0;rx_data<=0;rx_last<=0;
     if(BAD||length==0||({1'b0,word_address}+{1'b0,length})>CAPACITY_BYTES)finish(8);
     else state<=START;
    end
    TXHOLD:if(ce&&tx_valid)begin tx_latch<=tx_data;state<=TXBYTE;host_age<=0;end
     else if(host_age>=HOST_TIMEOUT_CYCLES-1)begin pending_error<=7;state<=FAIL_STOP;end
     else host_age<=host_age+1'b1;
    RXHOLD:if(ce&&rx_ready)begin
     bytes_completed<=bytes_completed+1'b1;remaining<=remaining-1'b1;address<=address+1'b1;
     state<=remaining==1?READ_STOP:RXBYTE;
    end
    POLL_GAP:if(gap>=POLL_GAP_CYCLES-1)state<=POLL_START;else gap<=gap+1'b1;
    DONE:if(ce&&done_ready)state<=IDLE;
    default:begin end
   endcase
  end
 end
endmodule
