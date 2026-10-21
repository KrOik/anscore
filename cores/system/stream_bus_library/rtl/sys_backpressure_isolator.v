// Two-entry FIFO: s_ready has no combinational path from m_ready.
module sys_backpressure_isolator #(parameter WIDTH=45)(
 input wire clk,rst_n, input wire [WIDTH-1:0] s_data,
 input wire s_valid, output wire s_ready,
 output wire [WIDTH-1:0] m_data, output wire m_valid,input wire m_ready
);
reg [WIDTH-1:0] first,second;
reg [1:0] count;
wire push=s_valid&&s_ready, pop=m_valid&&m_ready;
assign s_ready=rst_n&&(count<2);
assign m_valid=(count!=0);
assign m_data=first;
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin first<=0; second<=0; count<=0; end
 else case({push,pop})
  2'b10: begin if(count==0) first<=s_data; else second<=s_data; count<=count+1'b1; end
  2'b01: begin first<=second; count<=count-1'b1; end
  2'b11: begin first<=s_data; end
 endcase
end
initial if(WIDTH<1) $fatal(1,"WIDTH must be positive");
endmodule
