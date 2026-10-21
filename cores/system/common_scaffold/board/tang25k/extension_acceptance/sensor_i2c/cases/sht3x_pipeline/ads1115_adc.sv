// ADS1115 single-shot transaction controller. Physical bus progresses independently of CE.
module ads1115_adc #(
 parameter HALF_PERIOD_CYCLES=68, STRETCH_TIMEOUT_CYCLES=270000, MAX_POLLS=1024
)(input wire clk,rst_n,ce,start_valid,output wire start_ready,
 input wire[6:0] device_address,input wire[2:0] mux,input wire[2:0] pga,data_rate,
 output wire result_valid,input wire result_ready,output reg signed[15:0] sample,
 output reg[15:0] config_readback,output reg[31:0] polls,
 output wire busy,done_valid,input wire done_ready,output reg[3:0] error_code,
 input wire scl_in,sda_in,output wire scl_drive_low,sda_drive_low);
 localparam BAD=HALF_PERIOD_CYCLES<4||STRETCH_TIMEOUT_CYCLES<4||MAX_POLLS<1||MAX_POLLS>2147483647;
 localparam IDLE=0,START=1,ADDRW=2,PTR=3,WRITE=4,RESTART=5,ADDRR=6,READ=7,STOP=8,CHECK=9,RESULT=10,DONE=11,FAILSTOP=12;
 reg[3:0] state;reg waiting;reg[1:0] phase;reg index;reg[6:0] address;reg[15:0] config_word,rx;
 reg[3:0] pending_error;reg request_valid;wire request_ready,response_valid,response_nack;
 reg[1:0] request_kind;reg[7:0]request_byte;reg request_nack;
 wire[7:0] response_byte;wire[3:0]response_error;
 assign start_ready=state==IDLE;assign busy=state!=IDLE&&state!=DONE;
 assign result_valid=state==RESULT;assign done_valid=state==DONE;
 i2c_eeprom_phy #(.HALF_PERIOD_CYCLES(HALF_PERIOD_CYCLES),.STRETCH_TIMEOUT_CYCLES(STRETCH_TIMEOUT_CYCLES)) phy(
 .clk(clk),.rst_n(rst_n),.request_valid(request_valid),.request_ready(request_ready),.request_kind(request_kind),.request_byte(request_byte),.request_nack(request_nack),
 .response_valid(response_valid),.response_ready(waiting),.response_byte(response_byte),.response_nack(response_nack),.response_error(response_error),
 .scl_in(scl_in),.sda_in(sda_in),.scl_drive_low(scl_drive_low),.sda_drive_low(sda_drive_low));
 always @*begin
 request_valid=!waiting;request_kind=2;request_byte=0;request_nack=0;
 case(state)
 START,RESTART:request_kind=0;STOP,FAILSTOP:request_kind=1;
 ADDRW:request_byte={address,1'b0};ADDRR:request_byte={address,1'b1};
 PTR:request_byte=phase==2?0:1;
 WRITE:request_byte=index?config_word[7:0]:config_word[15:8];
 READ:begin request_kind=3;request_nack=index;end
 default:request_valid=0;
 endcase
 end
 task finish;input[3:0]code;begin state<=DONE;waiting<=0;error_code<=code;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;waiting<=0;phase<=0;index<=0;address<=0;config_word<=0;rx<=0;sample<=0;config_readback<=0;polls<=0;error_code<=0;pending_error<=0;end
 else begin
 if(request_valid&&request_ready)waiting<=1;
 if(waiting&&response_valid)begin
 waiting<=0;
 if(response_error!=0)finish(response_error);
 else if(request_kind==2&&response_nack)begin pending_error<=1;state<=FAILSTOP;end
 else case(state)
 START:state<=ADDRW;ADDRW:state<=PTR;
 PTR:begin index<=0;state<=phase==0?WRITE:RESTART;end
 WRITE:if(index)state<=STOP;else index<=1;
 RESTART:state<=ADDRR;ADDRR:state<=READ;
 READ:begin if(index)rx[7:0]<=response_byte;else rx[15:8]<=response_byte;if(index)state<=STOP;else index<=1;end
 STOP:if(phase==0)begin phase<=1;state<=START;end else if(phase==1)state<=CHECK;else begin sample<=rx;state<=RESULT;end
 FAILSTOP:finish(pending_error);
 default:finish(8);
 endcase
 end
 case(state)
 IDLE:if(ce&&start_valid)begin
 polls<=0;error_code<=0;pending_error<=0;phase<=0;index<=0;address<=device_address;
 // OS=1 starts single shot; MODE=1; comparator disabled COMP_QUE=11.
 config_word<={1'b1,mux,pga,1'b1,data_rate,5'b00011};
 if(BAD||device_address<7'h48||device_address>7'h4b)finish(8);else state<=START;
 end
 CHECK:begin config_readback<=rx;polls<=polls+1;
 if(rx[15])begin phase<=2;state<=START;end
 else if(polls>=MAX_POLLS-1)finish(6);else state<=START;
 end
 RESULT:if(ce&&result_ready)finish(0);
 DONE:if(ce&&done_ready)state<=IDLE;
 default:begin end
 endcase
 end
 end
endmodule
