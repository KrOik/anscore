module stream_secded_encode #(
 parameter integer DATA_W=64,
 parameter integer TAG_W=16,
 localparam integer PARITY_W=(DATA_W<=1)?2:(DATA_W<=4)?3:(DATA_W<=11)?4:
                            (DATA_W<=26)?5:(DATA_W<=57)?6:(DATA_W<=120)?7:8,
 localparam integer CODE_W=DATA_W+PARITY_W+1
)(
 input wire clk,input wire rst,
 input wire s_valid,output wire s_ready,
 input wire [DATA_W-1:0] s_data,input wire s_last,input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output reg [CODE_W-1:0] m_code,output reg m_last,output reg [TAG_W-1:0] m_tag
);
 localparam integer N=CODE_W-1;
 function integer payload_index;
  input integer position;
  integer i,count;
  begin
   count=0;
   for(i=1;i<position;i=i+1)if((i&(i-1))!=0)count=count+1;
   payload_index=count;
  end
 endfunction
 function [DATA_W-1:0] parity_mask;
  input integer parity_position;
  integer i,index;
  begin
   parity_mask=0;index=0;
   for(i=1;i<=N;i=i+1)begin
    if((i&(i-1))!=0)begin
     if((i&parity_position)!=0)parity_mask[index]=1'b1;
     index=index+1;
    end
   end
  end
 endfunction
 wire [N-1:0] body;
 genvar position;
 generate for(position=1;position<=N;position=position+1)begin: code_positions
  if((position&(position-1))!=0)begin: payload
   assign body[position-1]=s_data[payload_index(position)];
  end else begin: check
   localparam [DATA_W-1:0] MASK=parity_mask(position);
   assign body[position-1]=^(s_data&MASK);
  end
 end endgenerate
 reg out_valid;
 assign s_ready=!rst&&(!out_valid||m_ready);
 assign m_valid=!rst&&out_valid;
 always @(posedge clk)begin
  if(rst)out_valid<=0;
  else if(s_ready)begin
   out_valid<=s_valid;
   if(s_valid)begin m_code<={^body,body};m_last<=s_last;m_tag<=s_tag;end
  end
 end
 initial begin
  if(DATA_W<1||DATA_W>128||TAG_W<1)$fatal(1,"illegal parameters");
 end
endmodule
