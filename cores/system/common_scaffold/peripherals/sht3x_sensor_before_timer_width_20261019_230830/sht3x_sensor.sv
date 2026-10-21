`default_nettype none
// SHT30/31/35 single-shot, clock stretching DISABLED commands (0x24xx).
// Host CE gates request acceptance only; physical transaction and response flow
// never pause for CE, avoiding an accidentally extended I2C clock phase.
module sht3x_sensor #(
 parameter integer CLOCK_HZ=27000000,HALF_PERIOD_CYCLES=68,
 STRETCH_TIMEOUT_CYCLES=270000,WAIT_LOW_US=5000,WAIT_MEDIUM_US=7000,
 WAIT_HIGH_US=16000,RETRY_GAP_US=1000,READ_ATTEMPTS=20
)(input wire clk,rst_n,ce,abort,
 input wire req_valid,output wire req_ready,input wire[6:0]req_address,
 input wire[1:0]req_repeatability,
 output wire out_valid,input wire out_ready,output reg[3:0]out_error,
 output reg[3:0]out_phy_error,output reg[1:0]out_crc_bad,
 output reg[15:0]out_temperature_raw,out_humidity_raw,
 output reg signed[18:0]out_temperature_mC,output reg[16:0]out_humidity_mpercent,
 output reg[15:0]out_read_attempts,output wire busy,
 input wire scl_in,sda_in,output wire scl_drive_low,sda_drive_low);
 localparam[63:0]LWAIT=(64'd1*CLOCK_HZ*WAIT_LOW_US+999999)/1000000;
 localparam[63:0]MWAIT=(64'd1*CLOCK_HZ*WAIT_MEDIUM_US+999999)/1000000;
 localparam[63:0]HWAIT=(64'd1*CLOCK_HZ*WAIT_HIGH_US+999999)/1000000;
 localparam[63:0]GWAIT=(64'd1*CLOCK_HZ*RETRY_GAP_US+999999)/1000000;
 localparam BAD=CLOCK_HZ<1000000||CLOCK_HZ>100000000||HALF_PERIOD_CYCLES<4||
 STRETCH_TIMEOUT_CYCLES<4||WAIT_LOW_US<1||WAIT_LOW_US>1000000||
 WAIT_MEDIUM_US<1||WAIT_MEDIUM_US>1000000||WAIT_HIGH_US<1||WAIT_HIGH_US>1000000||
 RETRY_GAP_US<1||RETRY_GAP_US>1000000||READ_ATTEMPTS<1||READ_ATTEMPTS>65535||
 LWAIT>64'hffffffff||MWAIT>64'hffffffff||HWAIT>64'hffffffff||GWAIT>64'hffffffff;
 localparam IDLE=0,WSTART=1,WADDR=2,CMDHI=3,CMDLO=4,WSTOP=5,
 DELAY=6,RSTART=7,RADDR=8,RBYTE=9,RSTOP=10,BUSY_STOP=11,GAP=12,
 CONVERT=13,FAIL_STOP=14,DONE=15,MUL8=16,SUM=17,DIV_PRE=18,DIVIDE=19,OFFSET=20;
 reg[4:0]state;reg waiting,aborting;reg[6:0]address;reg[7:0]command_low;
 reg[31:0]timer,measurement_wait;reg[2:0]index;reg[7:0]temp_crc,humidity_crc;
 reg[3:0]pending_error;
 wire phy_ready,phy_valid,phy_nack;wire[7:0]phy_byte;wire[3:0]phy_error;
 reg command_valid;reg[1:0]command_kind;reg[7:0]command_byte;reg command_nack;
 assign req_ready=rst_n&&ce&&!abort&&state==IDLE;
 assign out_valid=state==DONE;
 assign busy=state!=IDLE&&state!=DONE;
 i2c_eeprom_phy #(.HALF_PERIOD_CYCLES(HALF_PERIOD_CYCLES),.STRETCH_TIMEOUT_CYCLES(STRETCH_TIMEOUT_CYCLES))phy(
 .clk(clk),.rst_n(rst_n),.request_valid(command_valid),.request_ready(phy_ready),
 .request_kind(command_kind),.request_byte(command_byte),.request_nack(command_nack),
 .response_valid(phy_valid),.response_ready(waiting),.response_byte(phy_byte),
 .response_nack(phy_nack),.response_error(phy_error),.scl_in(scl_in),.sda_in(sda_in),
 .scl_drive_low(scl_drive_low),.sda_drive_low(sda_drive_low));
 function[7:0]crc16;
 input[15:0]v;reg[7:0]c;integer j;begin
 c=8'hff;
 for(j=15;j>=0;j=j-1)begin
 if(c[7]^v[j])c=(c<<1)^8'h31;else c=c<<1;
 end crc16=c;end endfunction
 // Exact constant division: n=hi*65535+(hi+lo). The remainder correction is
 // at most3 for this34-bit product range. No general divider or DSP required.
 function[17:0]divide65535;
 input[33:0]n;reg[17:0]hi;reg[18:0]sum;begin
 hi=n[33:16];sum={1'b0,hi}+{3'b0,n[15:0]};
 divide65535=hi+(sum>=196605?3:sum>=131070?2:sum>=65535?1:0);
 end endfunction
 reg[25:0]temp_lo,temp_hi;reg[24:0]rh_lo,rh_hi;
 reg[33:0]temp_n,rh_n;reg[17:0]temp_base,rh_base,temp_quotient,rh_quotient;
 reg[18:0]temp_remainder,rh_remainder;
 task finish;input[3:0]error;begin state<=DONE;out_error<=error;waiting<=0;aborting<=0;end endtask
 always @*begin
 command_valid=!waiting;command_kind=2;command_byte=0;command_nack=0;
 case(state)
 WSTART,RSTART:command_kind=0;
 WSTOP,RSTOP,BUSY_STOP,FAIL_STOP:command_kind=1;
 WADDR:command_byte={address,1'b0};RADDR:command_byte={address,1'b1};
 CMDHI:command_byte=8'h24;CMDLO:command_byte=command_low;
 RBYTE:begin command_kind=3;command_nack=index==5;end
 default:command_valid=0;
 endcase
 end
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;waiting<=0;aborting<=0;address<=0;command_low<=0;timer<=0;measurement_wait<=0;index<=0;temp_crc<=0;humidity_crc<=0;pending_error<=0;
 temp_lo<=0;temp_hi<=0;rh_lo<=0;rh_hi<=0;temp_n<=0;rh_n<=0;temp_base<=0;rh_base<=0;temp_remainder<=0;rh_remainder<=0;temp_quotient<=0;rh_quotient<=0;
 out_error<=0;out_phy_error<=0;out_crc_bad<=0;out_temperature_raw<=0;out_humidity_raw<=0;out_temperature_mC<=0;out_humidity_mpercent<=0;out_read_attempts<=0;
 end else begin
 if(abort&&busy)aborting<=1;
 if(command_valid&&phy_ready)waiting<=1;
 if(waiting&&phy_valid)begin
 waiting<=0;
 if(phy_error!=0)begin out_phy_error<=phy_error;finish(8);end
 else if((abort||aborting)&&state!=FAIL_STOP)begin pending_error<=7;state<=FAIL_STOP;end
 else case(state)
 WSTART:state<=WADDR;
 WADDR:if(phy_nack)begin pending_error<=2;state<=FAIL_STOP;end else state<=CMDHI;
 CMDHI,CMDLO:if(phy_nack)begin pending_error<=3;state<=FAIL_STOP;end else state<=state==CMDHI?CMDLO:WSTOP;
 WSTOP:begin timer<=measurement_wait-1'b1;state<=DELAY;end
 RSTART:state<=RADDR;
 RADDR:begin out_read_attempts<=out_read_attempts+1'b1;
 if(phy_nack)state<=BUSY_STOP;else begin index<=0;state<=RBYTE;end
 end
 RBYTE:begin
 case(index)
 0:out_temperature_raw[15:8]<=phy_byte;1:out_temperature_raw[7:0]<=phy_byte;2:temp_crc<=phy_byte;
 3:out_humidity_raw[15:8]<=phy_byte;4:out_humidity_raw[7:0]<=phy_byte;5:humidity_crc<=phy_byte;
 endcase
 if(index==5)state<=RSTOP;else index<=index+1'b1;
 end
 RSTOP:state<=CONVERT;
 BUSY_STOP:if(out_read_attempts>=READ_ATTEMPTS)finish(4);else begin timer<=GWAIT-1;state<=GAP;end
 FAIL_STOP:finish(pending_error);
 default:finish(8);
 endcase
 end
 case(state)
 IDLE:if(req_valid&&req_ready)begin
 address<=req_address;command_low<=req_repeatability==0?8'h16:req_repeatability==1?8'h0b:8'h00;
 measurement_wait<=req_repeatability==0?LWAIT:req_repeatability==1?MWAIT:HWAIT;
 out_error<=0;out_phy_error<=0;out_crc_bad<=0;out_temperature_raw<=0;out_humidity_raw<=0;out_temperature_mC<=0;out_humidity_mpercent<=0;out_read_attempts<=0;pending_error<=0;aborting<=0;
 if(BAD||(req_address!=7'h44&&req_address!=7'h45)||req_repeatability==3)finish(1);else state<=WSTART;
 end
 DELAY,GAP:if(abort||aborting)begin pending_error<=7;state<=FAIL_STOP;end
 else if(timer!=0)timer<=timer-1'b1;else state<=RSTART;
 CONVERT:begin
 if(abort||aborting)finish(7);
 else begin
 out_crc_bad<={humidity_crc!=crc16(out_humidity_raw),temp_crc!=crc16(out_temperature_raw)};
 if(temp_crc!=crc16(out_temperature_raw))finish(5);
 else if(humidity_crc!=crc16(out_humidity_raw))finish(6);
 else state<=MUL8;
 end end
 MUL8:if(abort||aborting)finish(7);else begin
 temp_lo<=out_temperature_raw[7:0]*26'd175000;temp_hi<=out_temperature_raw[15:8]*26'd175000;
 rh_lo<=out_humidity_raw[7:0]*25'd100000;rh_hi<=out_humidity_raw[15:8]*25'd100000;state<=SUM;end
 SUM:if(abort||aborting)finish(7);else begin
 temp_n<={8'b0,temp_lo}+{temp_hi,8'b0}+34'd32767;
 rh_n<={9'b0,rh_lo}+{1'b0,rh_hi,8'b0}+34'd32767;state<=DIV_PRE;end
 DIV_PRE:if(abort||aborting)finish(7);else begin
 temp_base<=temp_n[33:16];rh_base<=rh_n[33:16];
 temp_remainder<={1'b0,temp_n[33:16]}+{3'b0,temp_n[15:0]};
 rh_remainder<={1'b0,rh_n[33:16]}+{3'b0,rh_n[15:0]};state<=DIVIDE;end
 DIVIDE:if(abort||aborting)finish(7);else begin
 temp_quotient<=temp_base+(temp_remainder>=196605?18'd3:temp_remainder>=131070?18'd2:temp_remainder>=65535?18'd1:18'd0);
 rh_quotient<=rh_base+(rh_remainder>=196605?18'd3:rh_remainder>=131070?18'd2:rh_remainder>=65535?18'd1:18'd0);state<=OFFSET;end
 OFFSET:if(abort||aborting)finish(7);else begin
 out_temperature_mC<=$signed({1'b0,temp_quotient})-19'sd45000;
 out_humidity_mpercent<=rh_quotient[16:0];finish(0);end
 DONE:if(out_ready)state<=IDLE;
 default:begin end
 endcase
 end end
endmodule
`default_nettype wire
