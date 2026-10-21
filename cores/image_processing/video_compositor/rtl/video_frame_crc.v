// Passive stream monitor. CRC-32/ISO-HDLC over RGB888 bytes B,G,R.
// Snapshot pulses on accepted LAST; owner must retain/snapshot for host reads.
module video_frame_crc(
 input wire clk,rst_n,valid,ready,sof,last,
 input wire [23:0] rgb,input wire [31:0] frame_id,expected_pixels,
 input wire [7:0] pixel_error,
 output reg result_valid,output reg [31:0] result_frame,result_crc,result_pixels,
 output reg [7:0] result_error
);
reg owned;reg [31:0] crc,count,id;reg [7:0] errors;
reg [31:0] next_crc,next_count;reg [7:0] next_error;
integer b,k;
always @* begin
 next_crc=(sof||!owned)?32'hffffffff:crc;
 next_count=(sof||!owned)?1:count+1;
 next_error=(sof||!owned)?0:errors;
 if((sof&&owned)||(!sof&&!owned)||(owned&&!sof&&frame_id!=id))next_error=next_error|1;
 if(pixel_error!=0)next_error=next_error|2;
 if(last&&next_count!=expected_pixels)next_error=next_error|4;
 for(b=0;b<3;b=b+1)begin
  next_crc=next_crc^((rgb>>(b*8))&32'hff);
  for(k=0;k<8;k=k+1)next_crc=(next_crc>>1)^(next_crc[0]?32'hedb88320:0);
 end
end
always @(posedge clk)begin
 if(!rst_n)begin owned<=0;crc<=32'hffffffff;count<=0;id<=0;errors<=0;
  result_valid<=0;result_frame<=0;result_crc<=0;result_pixels<=0;result_error<=0;end
 else begin
  result_valid<=0;
  if(valid&&ready)begin
   owned<=!last;crc<=next_crc;count<=next_count;errors<=next_error;
   if(sof||!owned)id<=frame_id;
   if(last)begin result_valid<=1;result_frame<=(sof||!owned)?frame_id:id;
    result_crc<=~next_crc;result_pixels<=next_count;result_error<=next_error;end
  end
 end
end
endmodule
