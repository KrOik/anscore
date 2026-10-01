// Single synchronous read port, no storage reset.
module chain_ram #(parameter WIDTH=16)(input wire clk,we,re,
 input wire [5:0] waddr,raddr,input wire [WIDTH-1:0] wdata,
 output reg [WIDTH-1:0] q);
 (* ram_style="block" *) reg [WIDTH-1:0] mem[0:63];
 always @(posedge clk) begin
 if(we) mem[waddr]<=wdata;
 if(re) q<=mem[raddr];
 end
endmodule
