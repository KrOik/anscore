// MODE=0: compact enabled bytes 32->8. MODE=1: pack 8->32 until full/TLAST.
module sys_width_converter #(parameter MODE=0)(
 input wire clk,rst_n,input wire [31:0] s_data,input wire [3:0] s_keep,
 input wire [7:0] s_user,input wire s_last,s_valid,output wire s_ready,
 output wire [31:0] m_data,output wire [3:0] m_keep,output wire [7:0] m_user,
 output wire m_last,m_valid,input wire m_ready
);
generate if(MODE==0) begin:down
 reg busy,last;
 reg [31:0] word;
 reg [3:0] keep;
 reg [7:0] user;
 integer i,index;
 reg [3:0] rest;
 always @* begin
  index=0; for(i=3;i>=0;i=i-1) if(keep[i]) index=i;
  rest=keep&~(4'b1<<index);
 end
 wire final_beat=(rest==0);
 assign s_ready=rst_n&&(!busy||(m_ready&&final_beat));
 assign m_valid=busy;
 assign m_data={24'd0,word[index*8+:8]};
 assign m_keep={3'd0,(keep!=0)};
 assign m_last=last&&final_beat;
 assign m_user=user;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin busy<=0; word<=0; keep<=0; last<=0; user<=0; end
  else begin
   if(busy&&m_ready) begin if(final_beat) busy<=0; else keep<=rest; end
   if(s_valid&&s_ready) begin
    busy<=1; word<=(s_keep==0)?32'd0:s_data; keep<=s_keep; last<=s_last; user<=s_user;
   end
  end
 end
end else begin:up
 reg [31:0] partial,data;
 reg [3:0] keep;
 reg [2:0] filled;
 reg [7:0] first_user,user;
 reg valid,last;
 reg [31:0] assembled;
 reg [2:0] next_filled;
 always @* begin
  assembled=partial; next_filled=filled;
  if(s_keep[0]) begin assembled[filled*8+:8]=s_data[7:0]; next_filled=filled+1'b1; end
 end
 assign s_ready=rst_n&&(!valid||m_ready);
 assign m_data=data; assign m_keep=keep; assign m_user=user;
 assign m_last=last; assign m_valid=valid;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin partial<=0; data<=0; keep<=0; filled<=0; first_user<=0; user<=0; valid<=0; last<=0; end
  else begin
   if(valid&&m_ready) valid<=0;
   if(s_valid&&s_ready) begin
    if(filled==0) first_user<=s_user;
    if(next_filled==4||s_last) begin
     data<=assembled; keep<=(5'b1<<next_filled)-1'b1; last<=s_last;
     user<=(filled==0)?s_user:first_user; valid<=1; filled<=0; partial<=0;
    end else begin partial<=assembled; filled<=next_filled; end
   end
  end
 end
end endgenerate
initial if(MODE!=0&&MODE!=1) $fatal(1,"MODE must be0/1");
endmodule
