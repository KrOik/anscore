
`default_nettype none
// Synthesizable independent camera serial peer. No DUT state/commands inspected.
module camera_pin_peer(input wire clk,rst_n,scl,sda,output reg drive_low,output reg error,output wire complete);
reg pscl,psda;reg[5:0]pos;reg[2:0]state;reg[3:0]bitno;reg[7:0]shift;
reg[10:0]token;
always @*begin case(pos)
0:token=11'h000;
1:token=11'h560;
2:token=11'h512;
3:token=11'h534;
4:token=11'h55a;
5:token=11'h200;
6:token=11'h000;
7:token=11'h560;
8:token=11'h512;
9:token=11'h534;
10:token=11'h000;
11:token=11'h561;
12:token=11'h6a5;
13:token=11'h200;
14:token=11'h000;
15:token=11'h442;
16:token=11'h534;
17:token=11'h45a;
18:token=11'h200;
19:token=11'h000;
20:token=11'h442;
21:token=11'h534;
22:token=11'h200;
23:token=11'h000;
24:token=11'h443;
25:token=11'h6a5;
26:token=11'h200;
default:token=0;endcase end
wire rise=scl&&!pscl,fall=!scl&&pscl;
wire start_ev=scl&&psda&&!sda,stop_ev=scl&&!psda&&sda;
assign complete=pos==27;
always @(posedge clk)begin
 if(!rst_n)begin pscl<=1;psda<=1;pos<=0;state<=0;bitno<=0;shift<=0;drive_low<=0;error<=0;end
 else begin
 pscl<=scl;psda<=sda;
 if(!complete)begin
 case(state)
 0:case(token[10:9])
 0:if(start_ev)pos<=pos+1'b1;
 1:if(stop_ev)pos<=pos+1'b1;
 2:begin state<=1;bitno<=0;shift<=0;end
 3:begin state<=4;bitno<=0;drive_low<=!token[7];end
 endcase
 1:if(rise)begin shift<={shift[6:0],sda};if(bitno==7)begin if({shift[6:0],sda}!=token[7:0])error<=1;state<=2;end else bitno<=bitno+1'b1;end
 2:if(fall)begin drive_low<=token[8];state<=3;end
 3:if(fall)begin drive_low<=0;pos<=pos+1'b1;state<=0;end
 4:if(fall)begin if(bitno==7)begin drive_low<=0;state<=5;end else begin bitno<=bitno+1'b1;drive_low<=!token[6-bitno];end end
 5:if(rise)begin if(!sda)error<=1;state<=6;end
 6:if(fall)begin state<=0;pos<=pos+1'b1;end
 default:error<=1;
 endcase
 if(start_ev&&!(state==0&&token[10:9]==0))error<=1;
 if(stop_ev&&!(state==0&&token[10:9]==1))error<=1;
 end
 end
end
endmodule
// Serial HX711 source models independent conversion words and next-mode pulse counts.
module hx711_pin_peer(input wire clk,rst_n,sck,output reg dout,output reg error,output wire complete);
reg prev;reg enabled,waiting;reg[7:0]gap;reg[5:0]pulses;reg[1:0]sample;
wire[23:0]word=sample==0?24'hffffff:sample==1?24'h800000:24'h7fffff;
wire[5:0]expected=sample==0?26:sample==1?27:25;
assign complete=sample==3;
always @(posedge clk)begin
 if(!rst_n)begin prev<=1;enabled<=0;waiting<=0;gap<=0;pulses<=0;sample<=0;dout<=1;error<=0;end
 else begin
 prev<=sck;
 if(!enabled)begin if(prev&&!sck)begin enabled<=1;dout<=0;end end
 else if(waiting)begin if(gap==0)begin waiting<=0;dout<=complete?1:0;end else gap<=gap-1'b1;end
 else if(!complete)begin
 if(!prev&&sck)begin
 if(pulses<24)dout<=word[23-pulses];else dout<=1;
 pulses<=pulses+1'b1;
 end
 if(prev&&!sck&&pulses==expected)begin sample<=sample+1'b1;pulses<=0;waiting<=1;gap<=200;dout<=1;end
 if(pulses>expected)error<=1;
 end
 end
end
endmodule
// Fixed UART output repeats every ~0.5 s; all outputs reflect actual comparator state.
module hx_camera_uart(input wire clk,rst_n,valid,pass,output reg tx);
reg[31:0]pause;reg[4:0]idx;reg[3:0]bitno;reg[9:0]shift;reg[9:0]baud;reg active;reg[7:0]ch;
localparam[191:0]GOOD="PASS HX_CAMERA N=3 C=2\r\n",BAD="FAIL HX_CAMERA N=3 C=2\r\n";
always @*ch=pass?(GOOD>>(8*(23-idx))):(BAD>>(8*(23-idx)));
always @(posedge clk)begin
 if(!rst_n)begin tx<=1;pause<=0;idx<=0;bitno<=0;shift<=0;baud<=0;active<=0;end
 else if(!active)begin
 tx<=1;
 if(valid)begin
 if(pause!=0)pause<=pause-1'b1;
 else begin shift<={1'b1,ch,1'b0};tx<=0;bitno<=0;baud<=433;active<=1;end
 end
 end else if(baud!=0)baud<=baud-1'b1;
 else begin
 baud<=433;
 if(bitno==9)begin active<=0;tx<=1;if(idx==23)begin idx<=0;pause<=25000000;end else idx<=idx+1'b1;end
 else begin shift<={1'b1,shift[9:1]};tx<=shift[1];bitno<=bitno+1'b1;end
 end
end
endmodule
module hx_camera_acceptance(input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg[15:0]por=0;always @(posedge clk)if(!por[15])por<=por+1'b1;wire rst_n=por[15];
reg[3:0]stage;reg[1:0]hx_index;reg hx_req,hx_pop;reg[31:0]watchdog;
reg failed,finished;reg[7:0]hold_count;
wire hx_ready,hx_valid,hx_sck,hx_dout,hx_busy,hx_down,hx_error,hx_complete;
wire signed[23:0]hx_data;wire[1:0]hx_mode,hx_next;wire[2:0]hx_code;wire[31:0]hx_seq,accepted,completed,dropped,timeouts;
wire[1:0]request_mode=hx_index==0?1:hx_index==1?2:0;
hx711_adc #(.FIFO_DEPTH(2)) hx(.clk(clk),.rst_n(rst_n),.ce(1'b1),.abort(1'b0),.power_down(1'b0),.req_valid(hx_req),.req_ready(hx_ready),.req_mode(request_mode),.dout(hx_dout),.pd_sck(hx_sck),.out_valid(hx_valid),.out_ready(hx_pop),.out_data(hx_data),.out_mode(hx_mode),.out_next_mode(hx_next),.out_error(hx_code),.out_sequence(hx_seq),.busy(hx_busy),.powered_down(hx_down),.accepted_count(accepted),.completed_count(completed),.dropped_count(dropped),.timeout_count(timeouts));
hx711_pin_peer hp(.clk(clk),.rst_n(rst_n),.sck(hx_sck),.dout(hx_dout),.error(hx_error),.complete(hx_complete));
reg camera_run,camera_start,camera_desc,camera_done_ready;reg[1:0]camera_op;reg[15:0]camera_reg;reg[7:0]camera_data,camera_mask;
wire camera_start_ready,camera_desc_ready,camera_busy,camera_done;wire[31:0]camera_index,camera_completed;wire[7:0]camera_last,camera_retries;wire[3:0]camera_code;
wire scl_low,sda_low,peer_low,peer_error,peer_complete;wire scl=!scl_low,sda=!(sda_low||peer_low);
camera_register_sequencer #(.HALF_PERIOD_CYCLES(12),.STRETCH_TIMEOUT_CYCLES(200),.MAX_DESCRIPTORS(2),.MAX_RETRIES(0)) camera(
.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(camera_start),.start_ready(camera_start_ready),.device_address(camera_run?7'h21:7'h30),.sccb_mode(camera_run),.register_address_16(!camera_run),
.descriptor_ready(camera_desc_ready),.descriptor_valid(camera_desc),.descriptor_op(camera_op),.descriptor_register(camera_reg),.descriptor_data(camera_data),.descriptor_mask(camera_mask),.descriptor_delay(32'd0),.descriptor_index(camera_index),.completed(camera_completed),.last_read(camera_last),.retries(camera_retries),.busy(camera_busy),.done_valid(camera_done),.done_ready(camera_done_ready),.error_code(camera_code),.scl_in(scl),.sda_in(sda),.scl_drive_low(scl_low),.sda_drive_low(sda_low));
camera_pin_peer cp(.clk(clk),.rst_n(rst_n),.scl(scl),.sda(sda),.drive_low(peer_low),.error(peer_error),.complete(peer_complete));
wire[23:0]expected_hx=hx_index==0?24'hffffff:hx_index==1?24'h800000:24'h7fffff;
always @(posedge clk)begin
 if(!rst_n)begin stage<=0;hx_index<=0;hx_req<=0;hx_pop<=0;watchdog<=0;failed<=0;finished<=0;hold_count<=0;camera_run<=0;camera_start<=0;camera_desc<=0;camera_done_ready<=0;camera_op<=0;camera_reg<=0;camera_data<=0;camera_mask<=0;end
 else if(!finished)begin
 watchdog<=watchdog+1'b1;
 if(watchdog==5000000||hx_error||peer_error)begin failed<=1;finished<=1;end
 case(stage)
 0:if(hx_ready)begin hx_req<=1;stage<=1;end
 1:if(hx_ready&&hx_req)begin hx_req<=0;stage<=2;end
 2:if(hx_valid)begin
 if(hx_data!=expected_hx||hx_mode!=hx_index||hx_next!=request_mode||hx_seq!={30'd0,hx_index}||hx_code)begin failed<=1;finished<=1;end
 hold_count<=16;stage<=3;end
 3:if(hold_count!=0)begin hold_count<=hold_count-1'b1;if(!hx_valid||hx_data!=expected_hx)begin failed<=1;finished<=1;end end
 else begin hx_pop<=1;stage<=4;end
 4:begin hx_pop<=0;if(hx_index==2)begin if(!hx_complete||accepted!=3||completed!=3||dropped||timeouts)begin failed<=1;finished<=1;end stage<=5;end else begin hx_index<=hx_index+1'b1;stage<=0;end end
 5:if(camera_start_ready)begin camera_start<=1;stage<=6;end
 6:begin camera_start<=0;stage<=7;end
 7:if(camera_desc_ready)begin camera_desc<=1;camera_reg<=camera_run?16'h0034:16'h1234;camera_data<=camera_index==0?8'h5a:8'ha0;camera_mask<=8'hf0;camera_op<=camera_index==0?0:camera_index==1?1:3;stage<=8;end
 8:begin camera_desc<=0;if(camera_op==3)stage<=9;else stage<=7;end
 9:if(camera_done)begin
 if(camera_code||camera_completed!=2||camera_index!=2||camera_last!=8'ha5||camera_retries)begin failed<=1;finished<=1;end
 camera_done_ready<=1;stage<=10;end
 10:begin camera_done_ready<=0;if(!camera_run)begin camera_run<=1;stage<=5;end else begin if(!peer_complete)failed<=1;finished<=1;end end
 default:begin failed<=1;finished<=1;end
 endcase
 end
end
hx_camera_uart reporter(.clk(clk),.rst_n(rst_n),.valid(finished),.pass(!failed),.tx(uart_tx));
assign dbg_uart=uart_tx;
endmodule
`default_nettype wire
