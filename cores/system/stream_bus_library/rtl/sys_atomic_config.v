// Shadow writes; commit includes same-edge write, applies only at apply_safe.
module sys_atomic_config #(parameter WORDS=4)(
 input wire clk,rst_n,input wire write_valid,output wire write_ready,
 input wire [$clog2(WORDS)-1:0] write_index,input wire [31:0] write_data,
 input wire [3:0] write_strb,input wire commit_valid,output wire commit_ready,
 input wire apply_safe,output reg [WORDS*32-1:0] active,
 output reg [31:0] version,output reg pending
);
reg [WORDS*32-1:0] shadow,snapshot,next_shadow;
integer k;
assign write_ready=rst_n&&!pending;
assign commit_ready=rst_n&&!pending;
always @* begin
 next_shadow=shadow;
 if(write_valid&&write_ready&&write_index<WORDS)
  for(k=0;k<4;k=k+1) if(write_strb[k]) next_shadow[write_index*32+k*8+:8]=write_data[k*8+:8];
end
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin shadow<=0; snapshot<=0; active<=0; version<=0; pending<=0; end
 else begin
  shadow<=next_shadow;
  if(pending&&apply_safe) begin active<=snapshot; version<=version+1; pending<=0; end
  if(commit_valid&&commit_ready) begin
   if(apply_safe) begin active<=next_shadow; version<=version+1; end
   else begin snapshot<=next_shadow; pending<=1; end
  end
 end
end
initial if(WORDS<2||(WORDS&(WORDS-1))!=0) $fatal(1,"WORDS power-of-two>=2");
endmodule
