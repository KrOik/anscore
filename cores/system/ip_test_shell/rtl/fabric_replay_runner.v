// Runtime-configurable controlled-input reference runner. No transport assumed.
module fabric_replay_runner #(parameter TIMEOUT=200000)(
 input wire clk,rst_n,start,input wire [31:0] seed,stall_mask,
 input wire [15:0] length,
 output reg busy,done,error,output reg [31:0] cycles,frames,bytes,
 output wire [31:0] crc32,output reg [9:0] trace_count,
 input wire trace_read,input wire [8:0] trace_address,output reg [35:0] trace_data,
 output wire [7:0] stream_probe
);
 reg [31:0] run_seed,run_stall,crc;
 reg [15:0] run_length;
 reg [8:0] offset[0:3];
 reg [3:0] finished;
 reg [127:0] sd;
 reg [15:0] sk;
 reg [31:0] su;
 reg [3:0] sl;
 wire [3:0] sv={4{busy}}&~finished;
 wire [3:0] sr;
 wire [23:0] md;
 wire [2:0] mk;
 wire [7:0] mu;
 wire ml,mv;
 wire mr=busy&&!run_stall[cycles[4:0]];
 wire [31:0] fabric_frames,drops;
 wire fabric_rst=rst_n&&busy;
 (* ram_style="block" *) reg [35:0] trace_mem[0:511];
 integer source,lane,remaining;
 reg [31:0] next_crc;
 reg [2:0] byte_increment;
 function [31:0] crc_byte;
  input [31:0] c; input [7:0] b;
  reg [31:0] x; integer bit_index;
  begin
   x=c^{24'd0,b};
   for(bit_index=0;bit_index<8;bit_index=bit_index+1)
    x=x[0]?(x>>1)^32'hedb88320:(x>>1);
   crc_byte=x;
  end
 endfunction
 assign crc32=~crc;
 assign stream_probe={error,ml,mr,mv,|sr,|sv,start,cycles[0]};
 always @* begin
  sd=0; sk=0; su=0; sl=0;
  for(source=0;source<4;source=source+1) begin
   remaining=run_length-offset[source];
   su[source*8+:8]=source;
   for(lane=0;lane<4;lane=lane+1) if(lane<remaining) begin
    sd[source*32+lane*8+:8]=run_seed+source*73+offset[source]+lane;
    sk[source*4+lane]=1;
   end
   sl[source]=(remaining<=4);
  end
  next_crc=crc; byte_increment=0;
  for(lane=0;lane<3;lane=lane+1) if(mk[lane]) begin
   next_crc=crc_byte(next_crc,md[lane*8+:8]); byte_increment=byte_increment+1'b1;
  end
 end
 stream_fabric4 #(.FIFO_DEPTH(128)) fabric(clk,clk,fabric_rst,sd,sk,su,sl,sv,sr,
 md,mk,mu,ml,mv,mr,fabric_frames,drops);
 always @(posedge clk) begin
  if(busy&&mv&&mr) trace_mem[trace_count[8:0]]<={ml,mu,mk,md};
  if(trace_read&&!busy) trace_data<=trace_mem[trace_address];
 end
 integer k;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   busy<=0; done<=0; error<=0; cycles<=0; frames<=0; bytes<=0; crc<=32'hffffffff;
   trace_count<=0; finished<=0; run_seed<=0; run_stall<=0; run_length<=0;
   for(k=0;k<4;k=k+1) offset[k]<=0;
  end else begin
   if(start) begin
    if(busy) begin busy<=0; done<=1; error<=1; end
    else begin
     done<=0; error<=0; cycles<=0; frames<=0; bytes<=0; crc<=32'hffffffff;
     trace_count<=0; finished<=0;
     run_seed<=seed; run_stall<=stall_mask; run_length<=length;
     for(k=0;k<4;k=k+1) offset[k]<=0;
     if(length==0||length>256) begin done<=1; error<=1; end
     else busy<=1;
    end
   end else if(busy) begin
    cycles<=cycles+1'b1;
    for(k=0;k<4;k=k+1) if(sv[k]&&sr[k]) begin
     if(sl[k]) finished[k]<=1; else offset[k]<=offset[k]+4;
    end
    if(mv&&mr) begin
     trace_count<=trace_count+1'b1; bytes<=bytes+byte_increment; crc<=next_crc;
     if(ml) begin
      frames<=frames+1'b1;
      if(frames==3) begin busy<=0; done<=1; end
     end
    end
    if(cycles>=TIMEOUT-1||drops!=0) begin busy<=0; done<=1; error<=1; end
   end
  end
 end
endmodule
