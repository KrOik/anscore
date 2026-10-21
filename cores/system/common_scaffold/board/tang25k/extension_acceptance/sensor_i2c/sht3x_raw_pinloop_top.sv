// Raw/CRC-only variant: converted numeric outputs are intentionally unconsumed.
// Board-internal scripted SCL/SDA loopback acceptance, not a real sensor test.
module sht3x_raw_pinloop_top #(parameter SENSOR=2,CORRUPT=0,CLK_HZ=50000000,BAUD=115200)(
 input wire clk,input wire uart_rx_pin,output wire uart_tx,output wire dbg_uart);
 reg[7:0]por=0;always @(posedge clk)if(por!=255)por<=por+1'b1;
 wire rst_n=por==255;reg[7:0]cycles;wire ce=cycles[2:0]!=0;
 reg sent;wire ready;wire request=rst_n&&!sent;
 wire scl_low,sda_low,slave_low;wire scl=!scl_low,sda=!(sda_low||slave_low);
 wire model_fault;wire[15:0]starts,stops,read_bytes,write_bytes;
 sensor_scripted_slave #(.SENSOR(SENSOR),.CORRUPT(CORRUPT))model(.clk(clk),.rst_n(rst_n),.scl(scl),.sda(sda),.drive_low(slave_low),.fault(model_fault),.starts(starts),.stops(stops),.read_bytes(read_bytes),.write_bytes(write_bytes));
 wire terminal,check_good;
 generate if(SENSOR==0)begin:ds
 wire valid,done,busy;wire[3:0]error_code;wire[11:0]year;wire[3:0]month;wire[5:0]day,minute,second;wire[2:0]weekday;wire[4:0]hour;wire[7:0]status_raw,retries;wire oscillator_stop,alarm1_flag,alarm2_flag,source_12h,source_century;
 reg seen,good;
 ds3231_rtc #(.HALF_PERIOD_CYCLES(8),.STRETCH_TIMEOUT_CYCLES(200),.MAX_ROLLOVER_RETRIES(0))dut(
 .clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(request),.start_ready(ready),.set_time(1'b0),.set_year(12'd0),.set_month(4'd0),.set_day(6'd0),.set_weekday(3'd0),.set_hour(5'd0),.set_minute(6'd0),.set_second(6'd0),
 .result_valid(valid),.result_ready(1'b1),.year(year),.month(month),.day(day),.weekday(weekday),.hour(hour),.minute(minute),.second(second),.status_raw(status_raw),.oscillator_stop(oscillator_stop),.alarm1_flag(alarm1_flag),.alarm2_flag(alarm2_flag),.source_12h(source_12h),.source_century(source_century),.retries(retries),.busy(busy),.done_valid(done),.done_ready(1'b0),.error_code(error_code),.scl_in(scl),.sda_in(sda),.scl_drive_low(scl_low),.sda_drive_low(sda_low));
 always @(posedge clk)if(!rst_n)begin seen<=0;good<=0;end else if(valid)begin seen<=1;good<=year==2199&&month==12&&day==31&&weekday==7&&hour==23&&minute==59&&second==58&&status_raw==8'h83&&oscillator_stop&&alarm1_flag&&alarm2_flag&&!source_12h&&source_century&&retries==0;end
 assign terminal=done;assign check_good=seen&&good&&error_code==0&&starts==6&&stops==3&&read_bytes==9&&write_bytes==0;
 end else if(SENSOR==1)begin:ads
 wire valid,done,busy;wire signed[15:0]sample;wire[15:0]config_readback;wire[31:0]polls;wire[3:0]error_code;reg seen,good;
 ads1115_adc #(.HALF_PERIOD_CYCLES(8),.STRETCH_TIMEOUT_CYCLES(200),.MAX_POLLS(3))dut(
 .clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(request),.start_ready(ready),.device_address(7'h48),.mux(3'd4),.pga(3'd2),.data_rate(3'd4),.result_valid(valid),.result_ready(1'b1),.sample(sample),.config_readback(config_readback),.polls(polls),.busy(busy),.done_valid(done),.done_ready(1'b0),.error_code(error_code),.scl_in(scl),.sda_in(sda),.scl_drive_low(scl_low),.sda_drive_low(sda_low));
 always @(posedge clk)if(!rst_n)begin seen<=0;good<=0;end else if(valid)begin seen<=1;good<=sample==16'h8001&&config_readback==16'hc583&&polls==2;end
 assign terminal=done;assign check_good=seen&&good&&error_code==0&&starts==7&&stops==4&&read_bytes==6&&write_bytes==2;
 end else begin:sht
 wire valid,busy;wire[3:0]error_code,phy_error;wire[1:0]crc_bad;wire[15:0]temp_raw,rh_raw,attempts;wire signed[18:0]temp_mc;wire[16:0]rh_mp;
 sht3x_sensor #(.CLOCK_HZ(CLK_HZ),.HALF_PERIOD_CYCLES(8),.STRETCH_TIMEOUT_CYCLES(200),.WAIT_LOW_US(1),.WAIT_MEDIUM_US(1),.WAIT_HIGH_US(1),.RETRY_GAP_US(1),.READ_ATTEMPTS(2))dut(
 .clk(clk),.rst_n(rst_n),.ce(ce),.abort(1'b0),.req_valid(request),.req_ready(ready),.req_address(7'h44),.req_repeatability(2'd2),.out_valid(valid),.out_ready(1'b0),.out_error(error_code),.out_phy_error(phy_error),.out_crc_bad(crc_bad),.out_temperature_raw(temp_raw),.out_humidity_raw(rh_raw),.out_temperature_mC(temp_mc),.out_humidity_mpercent(rh_mp),.out_read_attempts(attempts),.busy(busy),.scl_in(scl),.sda_in(sda),.scl_drive_low(scl_low),.sda_drive_low(sda_low));
 assign terminal=valid;assign check_good=error_code==0&&phy_error==0&&crc_bad==0&&temp_raw==16'hbeef&&rh_raw==16'h1234&&attempts==1&&starts==2&&stops==2&&read_bytes==6&&write_bytes==2;
 end endgenerate
 reg finished,passed;reg[23:0]watchdog;
 always @(posedge clk)begin
 if(!rst_n)begin cycles<=0;sent<=0;finished<=0;passed<=0;watchdog<=0;end
 else begin cycles<=cycles+1'b1;if(ce&&request&&ready)sent<=1;
 if(!finished)begin watchdog<=watchdog+1'b1;if(terminal)begin finished<=1;passed<=check_good&&!model_fault;end else if(watchdog==24'hffffff)begin finished<=1;passed<=0;end end
 end end
 assign dbg_uart=finished&&passed;
 // UART emits the same latched result every half second for host attachment.
 localparam UART_DIV=CLK_HZ/BAUD;
 reg[31:0]uart_timer,gap;reg[9:0]shift;reg[3:0]bits;reg[5:0]message_index;
 wire[7:0]message_byte;wire[5:0]message_length;
 sensor_raw_uart_message #(.SENSOR(SENSOR))message(.passed(passed),.index(message_index),.data(message_byte),.length(message_length));
 assign uart_tx=bits!=0?shift[0]:1'b1;
 always @(posedge clk)begin
 if(!rst_n)begin uart_timer<=0;gap<=0;shift<=10'h3ff;bits<=0;message_index<=0;end
 else if(bits!=0)begin
 if(uart_timer!=0)uart_timer<=uart_timer-1'b1;else begin shift<={1'b1,shift[9:1]};bits<=bits-1'b1;uart_timer<=UART_DIV-1;end
 end else if(finished)begin
 if(gap!=0)gap<=gap-1'b1;else begin shift<={1'b1,message_byte,1'b0};bits<=10;uart_timer<=UART_DIV-1;
 if(message_index==message_length-1)begin message_index<=0;gap<=CLK_HZ/2;end else message_index<=message_index+1'b1;
 end end
 end
endmodule
