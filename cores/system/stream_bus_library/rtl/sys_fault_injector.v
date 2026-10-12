// Controlled functional fault injection. No security/physical fault coverage claim.
module sys_fault_injector(
 input wire clk,rst_n,input wire [31:0] s_data,mask,
 input wire [1:0] mode,input wire enable,input wire [15:0] period,
 input wire s_valid,output wire s_ready,
 output reg [31:0] m_data,output reg m_injected,m_error,m_valid,input wire m_ready,
 output reg [31:0] injections
);
reg [15:0] phase;
wire inject=enable&&(phase==0);
assign s_ready=rst_n&&(!m_valid||m_ready);
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin phase<=0; m_data<=0; m_injected<=0; m_error<=0; m_valid<=0; injections<=0; end
 else if(s_ready) begin
  m_valid<=s_valid;
  if(s_valid) begin
   if(period==0||phase>=period-1'b1) phase<=0; else phase<=phase+1'b1;
   m_data<=s_data; m_injected<=inject&&(mode!=3); m_error<=inject&&(mode==3);
   if(inject) case(mode)
    0: m_data<=s_data^mask;
    1: m_data<=s_data&~mask;
    2: m_data<=s_data|mask;
    default: m_data<=s_data;
   endcase
   if(inject&&mode!=3) injections<=injections+1;
  end
 end
end
endmodule
