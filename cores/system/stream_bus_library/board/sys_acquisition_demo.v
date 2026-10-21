// Digital four-channel acquisition demo; no physical ADC interface is assumed.
// Align epochs -> serialize lanes -> calibrate -> timestamp -> pre/post capture.
module sys_acquisition_demo(input wire clk,rst_n,input wire [5:0] selected,
 input wire [95:0] q_data,input wire q_valid,output wire q_ready,
 output wire [191:0] r_data,output wire r_valid,input wire r_ready);
wire [31:0] a=q_data[31:0],epoch=q_data[63:32]; wire [1:0] channel=q_data[65:64];
wire [3:0] ar,missing; wire [127:0] frame; wire [31:0] frame_epoch,stale; wire fv,fr;
sys_frame_align4 align(clk,rst_n,{4{a}},{4{epoch}},(4'b1<<channel)&{4{q_valid}},ar,16'd0,frame,frame_epoch,missing,fv,fr,stale);
assign q_ready=ar[channel];
reg serial_busy; reg [127:0] samples; reg [31:0] tag; reg [1:0] lane;
wire cal_ready,cal_valid,cal_sat; wire [23:0] cal_data; wire [1:0] cal_channel; wire [31:0] cal_tag;
wire [15:0] gain=(lane==0)?16'd8192:(lane==1)?16'd16384:(lane==2)?16'he000:16'd32767;
wire [23:0] offset=(lane==0)?24'd100:(lane==1)?24'hffff9c:(lane==2)?24'd0:24'd500;
assign fr=!serial_busy;
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin serial_busy<=0; samples<=0; tag<=0; lane<=0; end
 else begin
  if(fv&&fr) begin serial_busy<=1; samples<=frame; tag<=frame_epoch; lane<=0; end
  if(serial_busy&&cal_ready) begin lane<=lane+1'b1; if(lane==3) serial_busy<=0; end
 end
end
wire ts_ready,ts_valid; wire [31:0] ts_data; wire [15:0] ts_tag; wire [63:0] ts_time,now;
sys_calibration24 cal(clk,rst_n,samples[lane*32+:24],offset,gain,lane,tag,serial_busy,cal_ready,
 cal_data,cal_channel,cal_tag,cal_sat,cal_valid,ts_ready);
wire window_ready,window_last,arm_ready,busy,triggered; wire [111:0] captured; wire [15:0] length;
sys_timestamp64 timestamp(clk,rst_n,1'b0,64'd0,{5'd0,cal_sat,cal_channel,cal_data},{cal_tag[13:0],cal_channel},
 cal_valid,ts_ready,ts_data,ts_tag,ts_time,ts_valid,window_ready,now);
reg armed;
always @(posedge clk or negedge rst_n) if(!rst_n) armed<=0; else if(arm_ready) armed<=1;
sys_trigger_window #(.WIDTH(112)) window(clk,rst_n,!armed,arm_ready,{ts_time,ts_tag,ts_data},ts_tag==16'd63,
 ts_valid,window_ready,captured,window_last,r_valid,r_ready,busy,triggered,length);
assign r_data={48'd0,length,15'd0,window_last,captured};
endmodule
