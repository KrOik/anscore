module sys_timestamp64(
 input wire clk,rst_n,load_valid,input wire [63:0] load_time,
 input wire [31:0] s_data,input wire [15:0] s_tag,input wire s_valid,output wire s_ready,
 output reg [31:0] m_data,output reg [15:0] m_tag,output reg [63:0] m_time,
 output reg m_valid,input wire m_ready,output reg [63:0] now
);
assign s_ready=rst_n&&(!m_valid||m_ready);
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin now<=0; m_data<=0; m_tag<=0; m_time<=0; m_valid<=0; end
 else begin
  now<=load_valid?load_time:now+1'b1;
  if(s_ready) begin
   m_valid<=s_valid;
   if(s_valid) begin m_data<=s_data; m_tag<=s_tag; m_time<=now; end
  end
 end
end
endmodule
