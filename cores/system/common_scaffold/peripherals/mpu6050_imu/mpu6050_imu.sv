// MPU6050 raw coherent 14-byte sensor acquisition; no DMP/fusion/calibration.
module mpu6050_imu #(
 parameter HALF_PERIOD_CYCLES=68,STRETCH_TIMEOUT_CYCLES=270000,MAX_READY_POLLS=1024,STARTUP_DELAY_CYCLES=2700000
)(input wire clk,rst_n,ce,start_valid,output wire start_ready,
 input wire address_ad0,configure,input wire[7:0]sample_rate_divider,input wire[2:0]dlpf,
 input wire[1:0]gyro_range,accel_range,
 output wire result_valid,input wire result_ready,
 output reg signed[15:0]accel_x,accel_y,accel_z,temperature,gyro_x,gyro_y,gyro_z,
 output reg[7:0]who_am_i,interrupt_status,output reg[31:0]polls,
 output wire busy,done_valid,input wire done_ready,output reg[3:0]error_code,
 input wire scl_in,sda_in,output wire scl_drive_low,sda_drive_low);
 localparam BAD=HALF_PERIOD_CYCLES<4||STRETCH_TIMEOUT_CYCLES<4||MAX_READY_POLLS<1||MAX_READY_POLLS>2147483647||STARTUP_DELAY_CYCLES<0||STARTUP_DELAY_CYCLES>2147483647;
 localparam IDLE=0,START=1,ADDRW=2,PTR=3,WRITE=4,RESTART=5,ADDRR=6,READ=7,STOP=8,CHECK=9,WAITSTART=10,COMMIT=11,RESULT=12,DONE=13,FAILSTOP=14;
 reg[3:0]state;reg waiting,do_config,ad0;reg[2:0]phase,config_index;reg[3:0]byte_index;
 reg[7:0]divider;reg[2:0]filter;reg[1:0]gfs,afs;reg[31:0]delay_left;reg[7:0]rx[0:13];reg[3:0]pending_error;
 reg request_valid;wire request_ready,response_valid,response_nack;reg[1:0]request_kind;reg[7:0]request_byte;reg request_nack;
 wire[7:0]response_byte;wire[3:0]response_error;
 assign start_ready=state==IDLE;assign busy=state!=IDLE&&state!=DONE;assign result_valid=state==RESULT;assign done_valid=state==DONE;
 function[7:0]config_register;input[2:0]n;begin case(n)0:config_register=8'h6b;1:config_register=8'h6c;2:config_register=8'h19;3:config_register=8'h1a;4:config_register=8'h1b;5:config_register=8'h1c;6:config_register=8'h37;default:config_register=8'h38;endcase end endfunction
 function[7:0]config_value;input[2:0]n;begin case(n)0:config_value=1;1:config_value=0;2:config_value=divider;3:config_value={5'b0,filter};4:config_value={3'b0,gfs,3'b0};5:config_value={3'b0,afs,3'b0};6:config_value=0;default:config_value=1;endcase end endfunction
 i2c_eeprom_phy #(.HALF_PERIOD_CYCLES(HALF_PERIOD_CYCLES),.STRETCH_TIMEOUT_CYCLES(STRETCH_TIMEOUT_CYCLES))phy(
 .clk(clk),.rst_n(rst_n),.request_valid(request_valid),.request_ready(request_ready),.request_kind(request_kind),.request_byte(request_byte),.request_nack(request_nack),
 .response_valid(response_valid),.response_ready(waiting),.response_byte(response_byte),.response_nack(response_nack),.response_error(response_error),
 .scl_in(scl_in),.sda_in(sda_in),.scl_drive_low(scl_drive_low),.sda_drive_low(sda_drive_low));
 always @*begin request_valid=!waiting;request_kind=2;request_byte=0;request_nack=0;
 case(state)
 START,RESTART:request_kind=0;STOP,FAILSTOP:request_kind=1;
 ADDRW:request_byte={6'b110100,ad0,1'b0};ADDRR:request_byte={6'b110100,ad0,1'b1};
 PTR:case(phase)0:request_byte=8'h75;1:request_byte=config_register(config_index);3:request_byte=8'h3b;default:request_byte=8'h3a;endcase
 WRITE:request_byte=config_value(config_index);
 READ:begin request_kind=3;request_nack=phase!=3||byte_index==13;end
 default:request_valid=0;
 endcase end
 task finish;input[3:0]code;begin state<=DONE;waiting<=0;error_code<=code;end endtask
 integer k;
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;waiting<=0;do_config<=0;ad0<=0;phase<=0;config_index<=0;byte_index<=0;divider<=0;filter<=0;gfs<=0;afs<=0;delay_left<=0;pending_error<=0;polls<=0;error_code<=0;who_am_i<=0;interrupt_status<=0;
 accel_x<=0;accel_y<=0;accel_z<=0;temperature<=0;gyro_x<=0;gyro_y<=0;gyro_z<=0;
 for(k=0;k<14;k=k+1)rx[k]<=0;
 end else begin
 if(request_valid&&request_ready)waiting<=1;
 if(waiting&&response_valid)begin waiting<=0;
 if(response_error!=0)finish(response_error);
 else if(request_kind==2&&response_nack)begin pending_error<=1;state<=FAILSTOP;end
 else case(state)
 START:state<=ADDRW;ADDRW:state<=PTR;PTR:begin byte_index<=0;state<=phase==1?WRITE:RESTART;end
 WRITE:state<=STOP;RESTART:state<=ADDRR;ADDRR:state<=READ;
 READ:begin rx[byte_index]<=response_byte;if(phase!=3||byte_index==13)state<=STOP;else byte_index<=byte_index+1'b1;end
 STOP:case(phase)
 0:state<=CHECK;
 1:if(config_index==7)begin delay_left<=STARTUP_DELAY_CYCLES;state<=WAITSTART;end else begin config_index<=config_index+1'b1;state<=START;end
 4:begin phase<=2;state<=START;end
 2:state<=CHECK;
 default:state<=COMMIT;
 endcase
 FAILSTOP:finish(pending_error);default:finish(8);
 endcase end
 case(state)
 IDLE:if(ce&&start_valid)begin
 do_config<=configure;ad0<=address_ad0;divider<=sample_rate_divider;filter<=dlpf;gfs<=gyro_range;afs<=accel_range;phase<=0;config_index<=0;polls<=0;error_code<=0;pending_error<=0;waiting<=0;
 if(BAD||(configure&&dlpf==7))finish(8);else state<=START;
 end
 CHECK:if(phase==0)begin
 who_am_i<=rx[0];if(rx[0]!=8'h68)finish(2);
 else begin phase<=do_config?1:4;state<=START;end
 end else begin
 interrupt_status<=rx[0];polls<=polls+1;
 if(rx[0][0])begin phase<=3;state<=START;end
 else if(polls>=MAX_READY_POLLS-1)finish(6);else state<=START;
 end
 WAITSTART:if(delay_left==0)begin phase<=4;state<=START;end else delay_left<=delay_left-1;
 COMMIT:begin
 accel_x<={rx[0],rx[1]};accel_y<={rx[2],rx[3]};accel_z<={rx[4],rx[5]};temperature<={rx[6],rx[7]};gyro_x<={rx[8],rx[9]};gyro_y<={rx[10],rx[11]};gyro_z<={rx[12],rx[13]};state<=RESULT;
 end
 RESULT:if(ce&&result_ready)finish(0);DONE:if(ce&&done_ready)state<=IDLE;
 default:begin end
 endcase
 end end
endmodule
