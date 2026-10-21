// External ROM/descriptor stream: WRITE=0 VERIFY=1 DELAY=2 END=3.
// SCCB two-wire profile is 8-bit subaddress, STOP-separated read, ninth DC bit.
module camera_register_sequencer #(
 parameter HALF_PERIOD_CYCLES=68,STRETCH_TIMEOUT_CYCLES=270000,MAX_DESCRIPTORS=1024,MAX_RETRIES=2
)(input wire clk,rst_n,ce,start_valid,output wire start_ready,
 input wire[6:0]device_address,input wire sccb_mode,register_address_16,
 output wire descriptor_ready,input wire descriptor_valid,input wire[1:0]descriptor_op,
 input wire[15:0]descriptor_register,input wire[7:0]descriptor_data,descriptor_mask,input wire[31:0]descriptor_delay,
 output reg[31:0]descriptor_index,output reg[31:0]completed,
 output reg[7:0]last_read,output reg[7:0]retries,
 output wire busy,done_valid,input wire done_ready,output reg[3:0]error_code,
 input wire scl_in,sda_in,output wire scl_drive_low,sda_drive_low);
 localparam BAD=HALF_PERIOD_CYCLES<4||STRETCH_TIMEOUT_CYCLES<4||MAX_DESCRIPTORS<1||MAX_DESCRIPTORS>2147483647||MAX_RETRIES<0||MAX_RETRIES>255;
 localparam IDLE=0,FETCH=1,START=2,ADDRW=3,REGHI=4,REGLO=5,WRITE=6,RESTART=7,ADDRR=8,READ=9,STOP=10,CHECK=11,DELAY=12,DONE=13,FAILSTOP=14,READSTOP=15;
 reg[3:0]state;reg waiting,reading,sccb,wide;reg[6:0]address;reg[15:0]subaddress;reg[7:0]data,mask;reg[31:0]delay_left;reg[3:0]pending_error;
 reg request_valid;wire request_ready,response_valid,response_nack;reg[1:0]request_kind;reg[7:0]request_byte;reg request_nack;
 wire[7:0]response_byte;wire[3:0]response_error;
 assign start_ready=state==IDLE;assign descriptor_ready=state==FETCH;assign busy=state!=IDLE&&state!=DONE;assign done_valid=state==DONE;
 i2c_eeprom_phy #(.HALF_PERIOD_CYCLES(HALF_PERIOD_CYCLES),.STRETCH_TIMEOUT_CYCLES(STRETCH_TIMEOUT_CYCLES))phy(
 .clk(clk),.rst_n(rst_n),.request_valid(request_valid),.request_ready(request_ready),.request_kind(request_kind),.request_byte(request_byte),.request_nack(request_nack),
 .response_valid(response_valid),.response_ready(waiting),.response_byte(response_byte),.response_nack(response_nack),.response_error(response_error),
 .scl_in(scl_in),.sda_in(sda_in),.scl_drive_low(scl_drive_low),.sda_drive_low(sda_drive_low));
 always @*begin request_valid=!waiting;request_kind=2;request_byte=0;request_nack=0;
 case(state)
 START,RESTART:request_kind=0;STOP,READSTOP,FAILSTOP:request_kind=1;
 ADDRW:request_byte={address,1'b0};ADDRR:request_byte={address,1'b1};REGHI:request_byte=subaddress[15:8];REGLO:request_byte=subaddress[7:0];WRITE:request_byte=data;
 READ:begin request_kind=3;request_nack=1;end
 default:request_valid=0;
 endcase end
 task finish;input[3:0]code;begin state<=DONE;waiting<=0;error_code<=code;end endtask
 task advance;begin completed<=completed+1;descriptor_index<=descriptor_index+1;state<=FETCH;end endtask
 task retry_or_fail;input[3:0]code;begin if(retries<MAX_RETRIES)begin retries<=retries+1'b1;state<=START;end else finish(code);end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;waiting<=0;reading<=0;sccb<=0;wide<=0;address<=0;subaddress<=0;data<=0;mask<=0;delay_left<=0;pending_error<=0;descriptor_index<=0;completed<=0;last_read<=0;retries<=0;error_code<=0;end
 else begin
 if(request_valid&&request_ready)waiting<=1;
 if(waiting&&response_valid)begin waiting<=0;
 if(response_error!=0)finish(response_error);
 else if(request_kind==2&&response_nack&&!sccb)begin pending_error<=1;state<=FAILSTOP;end
 else case(state)
 START:state<=ADDRW;ADDRW:state<=wide?REGHI:REGLO;REGHI:state<=REGLO;
 REGLO:state<=reading?(sccb?READSTOP:RESTART):WRITE;
 WRITE:state<=STOP;READSTOP:state<=RESTART;RESTART:state<=ADDRR;ADDRR:state<=READ;
 READ:begin last_read<=response_byte;state<=STOP;end
 STOP:if(reading)state<=CHECK;else advance;
 FAILSTOP:retry_or_fail(pending_error);
 default:finish(8);
 endcase end
 case(state)
 IDLE:if(ce&&start_valid)begin
 waiting<=0;address<=device_address;sccb<=sccb_mode;wide<=register_address_16;completed<=0;descriptor_index<=0;error_code<=0;retries<=0;
 if(BAD||device_address<7'h08||device_address>=7'h78||(sccb_mode&&register_address_16))finish(8);else state<=FETCH;
 end
 FETCH:if(ce&&descriptor_valid)begin
 retries<=0;subaddress<=descriptor_register;data<=descriptor_data;mask<=descriptor_mask;reading<=descriptor_op==1;
 if(descriptor_op==3)finish(0);
 else if(descriptor_index>=MAX_DESCRIPTORS||(!wide&&descriptor_register[15:8]!=0&&descriptor_op<2))finish(8);
 else if(descriptor_op==2)begin delay_left<=descriptor_delay;state<=DELAY;end else state<=START;
 end
 CHECK:if((last_read&mask)==(data&mask))advance;else retry_or_fail(2);
 DELAY:if(delay_left==0)advance;else delay_left<=delay_left-1;
 DONE:if(ce&&done_ready)state<=IDLE;
 default:begin end
 endcase
 end end
endmodule
