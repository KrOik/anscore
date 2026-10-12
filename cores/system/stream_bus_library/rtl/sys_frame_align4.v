// Per-lane epoch matching. Stale samples discarded; future samples held.
// Timeout age advances only when the output slot permits collection.
module sys_frame_align4(
 input wire clk,rst_n,input wire [127:0] s_data,s_epoch,
 input wire [3:0] s_valid,output reg [3:0] s_ready,input wire [15:0] timeout_cycles,
 output reg [127:0] m_data,output reg [31:0] m_epoch,output reg [3:0] m_missing,
 output reg m_valid,input wire m_ready,output reg [31:0] stale_samples
);
reg [127:0] collected,next_data;
reg [3:0] have,next_have;
reg [31:0] epoch;
reg [15:0] age;
reg [2:0] stale_count;
integer i;
wire available=!m_valid||m_ready;
wire timed=(timeout_cycles!=0)&&(age>=timeout_cycles-1'b1)&&((|next_have)||(|s_valid));
always @* begin
 s_ready=0; next_data=collected; next_have=have; stale_count=0;
 for(i=0;i<4;i=i+1) if(available) begin
  if($signed(s_epoch[i*32+:32]-epoch)<0) s_ready[i]=1;
  else if(!have[i]&&s_epoch[i*32+:32]==epoch) s_ready[i]=1;
  if(s_valid[i]&&s_ready[i]) begin
   if(s_epoch[i*32+:32]!=epoch) stale_count=stale_count+1'b1;
   else begin next_have[i]=1; next_data[i*32+:32]=s_data[i*32+:32]; end
  end
 end
end
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin collected<=0; have<=0; epoch<=0; age<=0; m_data<=0; m_epoch<=0; m_missing<=0; m_valid<=0; stale_samples<=0; end
 else begin
  if(m_valid&&m_ready) m_valid<=0;
  if(available) begin
   stale_samples<=stale_samples+stale_count;
   if((&next_have)||timed) begin
    m_data<=next_data; m_epoch<=epoch; m_missing<=~next_have; m_valid<=1;
    epoch<=epoch+1; have<=0; collected<=0; age<=0;
   end else begin
    have<=next_have; collected<=next_data;
    if((|next_have)||(|s_valid)) begin if(age!=65535) age<=age+1'b1; end
   end
  end
 end
end
endmodule
