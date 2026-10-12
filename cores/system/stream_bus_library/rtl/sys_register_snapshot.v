module sys_register_snapshot #(parameter WORDS=4)(
 input wire clk,rst_n,input wire [WORDS*32-1:0] live,
 input wire s_valid,output wire s_ready,input wire m_ready,
 output reg m_valid,output reg [WORDS*32-1:0] snapshot,
 output reg [63:0] timestamp,output reg [31:0] snapshot_id
);
reg [63:0] cycles;
assign s_ready=rst_n&&(!m_valid||m_ready);
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin cycles<=0; m_valid<=0; snapshot<=0; timestamp<=0; snapshot_id<=0; end
 else begin
  cycles<=cycles+1;
  if(s_ready) begin
   m_valid<=s_valid;
   if(s_valid) begin snapshot<=live; timestamp<=cycles; snapshot_id<=snapshot_id+1; end
  end
 end
end
initial if(WORDS<1) $fatal(1,"WORDS must be positive");
endmodule
