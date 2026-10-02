// Same port contract as board/dsp_chain_harness/chain_ram.v, without the
// ram_style="block" attribute: the 25K dock diverged on silicon only in the
// bits this store's read path carries, so the block-RAM mapping is the variable
// under test (measured 2026-10-08, artifacts/ds25k_board_20261008/dc_stats).
// Single synchronous read port, no storage reset.
module chain_ram #(parameter WIDTH=16)(input wire clk,we,re,
 input wire [5:0] waddr,raddr,input wire [WIDTH-1:0] wdata,
 output reg [WIDTH-1:0] q);
 reg [WIDTH-1:0] mem[0:63];
 always @(posedge clk) begin
 if(we) mem[waddr]<=wdata;
 if(re) q<=mem[raddr];
 end
endmodule
