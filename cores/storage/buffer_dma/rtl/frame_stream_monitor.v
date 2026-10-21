// Passive per-stream accounting; valid/ready stalls never count as data loss.
// CRC32/ISO-HDLC, low byte first, keep lanes in ascending order.
module frame_stream_monitor(
 input wire clk,rst_n,valid,ready,input wire [31:0] data,
 input wire [3:0] keep,input wire last,
 output reg [31:0] bytes,frames,stall_cycles,last_frame_cycles,
 output wire [31:0] crc32,output reg [31:0] last_frame_crc32
);
 reg [31:0] crc,frame_crc,age;
 reg active;
 function [31:0] update_crc(input [31:0] initial_crc,input [31:0] word_data,input [3:0] mask);
  reg [31:0] x;integer lane,bitno;
  begin
   x=initial_crc;
   for(lane=0;lane<4;lane=lane+1)if(mask[lane])begin
    x=x^{24'd0,word_data[lane*8+:8]};
    for(bitno=0;bitno<8;bitno=bitno+1)x=x[0]?(x>>1)^32'hedb88320:(x>>1);
   end
   update_crc=x;
  end
 endfunction
 assign crc32=~crc;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   bytes<=0;frames<=0;stall_cycles<=0;last_frame_cycles<=0;
   crc<=32'hffffffff;frame_crc<=32'hffffffff;last_frame_crc32<=0;age<=0;active<=0;
  end else begin
   if(valid&&!ready)stall_cycles<=stall_cycles+1'b1;
   if(active)age<=age+1'b1;
   if(valid&&ready)begin
    bytes<=bytes+{31'd0,keep[0]}+{31'd0,keep[1]}+{31'd0,keep[2]}+{31'd0,keep[3]};
    crc<=update_crc(crc,data,keep);
    if(last)begin
     frames<=frames+1'b1;
     last_frame_crc32<=~update_crc(frame_crc,data,keep);
     last_frame_cycles<=active?age+1'b1:32'd1;
     active<=0;age<=0;frame_crc<=32'hffffffff;
    end else begin
     frame_crc<=update_crc(frame_crc,data,keep);
     if(!active)begin active<=1;age<=1;end
    end
   end
  end
 end
endmodule
