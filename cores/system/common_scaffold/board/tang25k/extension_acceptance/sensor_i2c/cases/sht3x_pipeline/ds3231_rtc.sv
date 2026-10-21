// DS3231 time/status transaction controller. Fixed seven-bit address 0x68.
// READ_TIME snapshots registers00..06, reads status0F, then verifies seconds00.
// SET_TIME writes a validated binary calendar as24h BCD; no alarm/status writes.
module ds3231_rtc #(
 parameter HALF_PERIOD_CYCLES=68,STRETCH_TIMEOUT_CYCLES=270000,MAX_ROLLOVER_RETRIES=3
)(input wire clk,rst_n,ce,start_valid,output wire start_ready,input wire set_time,
 input wire[11:0]set_year,input wire[3:0]set_month,input wire[5:0]set_day,
 input wire[2:0]set_weekday,input wire[4:0]set_hour,input wire[5:0]set_minute,set_second,
 output wire result_valid,input wire result_ready,
 output reg[11:0]year,output reg[3:0]month,output reg[5:0]day,
 output reg[2:0]weekday,output reg[4:0]hour,output reg[5:0]minute,second,
 output reg[7:0]status_raw,output wire oscillator_stop,alarm1_flag,alarm2_flag,
 output reg source_12h,source_century,output reg[7:0]retries,
 output wire busy,done_valid,input wire done_ready,output reg[3:0]error_code,
 input wire scl_in,sda_in,output wire scl_drive_low,sda_drive_low);
 localparam BAD=HALF_PERIOD_CYCLES<4||STRETCH_TIMEOUT_CYCLES<4||MAX_ROLLOVER_RETRIES<0||MAX_ROLLOVER_RETRIES>255;
 localparam IDLE=0,START=1,DEVW=2,POINTER=3,RESTART=4,DEVR=5,READ=6,STOP=7,CHECK=8,WRITE=9,RESULT=10,DONE=11,FAIL_STOP=12;
 reg[3:0]state;reg waiting,writing;reg[1:0]phase;reg[2:0]index;reg[7:0]raw[0:6];reg[7:0]verify_second,pending_error;
 reg request_valid;wire request_ready,response_valid,response_nack;reg[1:0]request_kind;reg[7:0]request_byte;reg request_nack;
 wire[7:0]response_byte;wire[3:0]response_error;
 integer y,m,d,h,mi,s,wd;reg decoded_ok;
 function integer bcd;input[7:0]v;begin bcd=(v>>4)*10+(v&15);end endfunction
 function bcd_ok;input[7:0]v;begin bcd_ok=v[7:4]<=9&&v[3:0]<=9;end endfunction
 function[7:0]encode_bcd;input integer v;begin encode_bcd=((v/10)<<4)|(v%10);end endfunction
 function calendar_ok;input integer yy,mm,dd,ww,hh,mn,ss;integer days;reg leap;begin
  leap=(yy%4==0)&&(yy!=2100); // Equivalent Gregorian rule within supported2000..2199.
  case(mm)2:days=leap?29:28;4,6,9,11:days=30;default:days=31;endcase
  calendar_ok=yy>=2000&&yy<=2199&&mm>=1&&mm<=12&&dd>=1&&dd<=days&&ww>=1&&ww<=7&&hh>=0&&hh<=23&&mn>=0&&mn<=59&&ss>=0&&ss<=59;
 end endfunction
 always @*begin
  s=bcd(raw[0]&8'h7f);mi=bcd(raw[1]&8'h7f);h=bcd(raw[2]&8'h3f);
  if(raw[2][6])h=(bcd(raw[2]&8'h1f)%12)+(raw[2][5]?12:0);
  wd=raw[3][2:0];d=bcd(raw[4]&8'h3f);m=bcd(raw[5]&8'h1f);y=2000+bcd(raw[6])+(raw[5][7]?100:0);
  decoded_ok=!raw[0][7]&&!raw[1][7]&&!raw[2][7]&&raw[3][7:3]==0&&raw[4][7:6]==0&&raw[5][6:5]==0&&
   bcd_ok(raw[0]&8'h7f)&&bcd_ok(raw[1]&8'h7f)&&bcd_ok(raw[2]&(raw[2][6]?8'h1f:8'h3f))&&
   bcd_ok(raw[4]&8'h3f)&&bcd_ok(raw[5]&8'h1f)&&bcd_ok(raw[6])&&
   (!raw[2][6]||(bcd(raw[2]&8'h1f)>=1&&bcd(raw[2]&8'h1f)<=12))&&calendar_ok(y,m,d,wd,h,mi,s);
 end
 assign start_ready=state==IDLE;
 assign busy=state!=IDLE&&state!=DONE;
 assign result_valid=state==RESULT;assign done_valid=state==DONE;
 assign oscillator_stop=status_raw[7];assign alarm1_flag=status_raw[0];assign alarm2_flag=status_raw[1];
 i2c_eeprom_phy #(.HALF_PERIOD_CYCLES(HALF_PERIOD_CYCLES),.STRETCH_TIMEOUT_CYCLES(STRETCH_TIMEOUT_CYCLES))phy(
 .clk(clk),.rst_n(rst_n),.request_valid(request_valid),.request_ready(request_ready),.request_kind(request_kind),.request_byte(request_byte),.request_nack(request_nack),
 .response_valid(response_valid),.response_ready(waiting),.response_byte(response_byte),.response_nack(response_nack),.response_error(response_error),
 .scl_in(scl_in),.sda_in(sda_in),.scl_drive_low(scl_drive_low),.sda_drive_low(sda_drive_low));
 always @*begin
  request_valid=!waiting;request_kind=2;request_byte=0;request_nack=0;
  case(state)
   START,RESTART:request_kind=0;
   STOP,FAIL_STOP:request_kind=1;
   DEVW:request_byte=8'hd0;DEVR:request_byte=8'hd1;
   POINTER:request_byte=phase==1?8'h0f:0;
   WRITE:request_byte=raw[index];
   READ:begin request_kind=3;request_nack=phase!=0||index==6;end
   default:request_valid=0;
  endcase
 end
 task finish;input[3:0]code;begin state<=DONE;error_code<=code;waiting<=0;end endtask
 integer k;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;waiting<=0;writing<=0;phase<=0;index<=0;verify_second<=0;pending_error<=0;
   year<=0;month<=0;day<=0;weekday<=0;hour<=0;minute<=0;second<=0;status_raw<=0;source_12h<=0;source_century<=0;retries<=0;error_code<=0;
   for(k=0;k<7;k=k+1)raw[k]<=0;
  end else begin
   if(request_valid&&request_ready)waiting<=1;
   if(waiting&&response_valid)begin
    waiting<=0;
    if(response_error!=0)finish(response_error);
    else if(request_kind==2&&response_nack)begin pending_error<=1;state<=FAIL_STOP;end
    else case(state)
     START:state<=DEVW;DEVW:state<=POINTER;
     POINTER:begin index<=0;state<=writing?WRITE:RESTART;end
     RESTART:state<=DEVR;DEVR:state<=READ;
     WRITE:if(index==6)state<=STOP;else index<=index+1'b1;
     READ:begin
      if(phase==0)raw[index]<=response_byte;
      else if(phase==1)status_raw<=response_byte;else verify_second<=response_byte;
      if(phase!=0||index==6)state<=STOP;else index<=index+1'b1;
     end
     STOP:if(writing)finish(0);
      else if(phase<2)begin phase<=phase+1'b1;state<=START;end
      else state<=CHECK;
     FAIL_STOP:finish(pending_error[3:0]);
     default:finish(8);
    endcase
   end
   case(state)
    IDLE:if(ce&&start_valid)begin
     waiting<=0;writing<=set_time;phase<=0;index<=0;retries<=0;pending_error<=0;error_code<=0;
     if(BAD||(set_time&&!calendar_ok(set_year,set_month,set_day,set_weekday,set_hour,set_minute,set_second)))finish(8);
     else begin
      if(set_time)begin
       raw[0]<=encode_bcd(set_second);raw[1]<=encode_bcd(set_minute);raw[2]<=encode_bcd(set_hour);raw[3]<={5'b0,set_weekday};
       raw[4]<=encode_bcd(set_day);raw[5]<=encode_bcd(set_month)|(set_year>=2100?8'h80:0);raw[6]<=encode_bcd(set_year%100);
      end
      state<=START;
     end
    end
    CHECK:if(verify_second!=raw[0])begin
     if(retries>=MAX_ROLLOVER_RETRIES)finish(6);
     else begin retries<=retries+1'b1;phase<=0;state<=START;end
    end else if(!decoded_ok)finish(2);
    else begin
     year<=y;month<=m;day<=d;weekday<=wd;hour<=h;minute<=mi;second<=s;
     source_12h<=raw[2][6];source_century<=raw[5][7];state<=RESULT;
    end
    RESULT:if(ce&&result_ready)finish(0);
    DONE:if(ce&&done_ready)state<=IDLE;
    default:begin end
   endcase
  end
 end
endmodule
