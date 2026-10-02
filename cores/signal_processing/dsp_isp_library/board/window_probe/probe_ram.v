// Single synchronous write port + single synchronous read-enable port.
// Storage is never reset; the registered output holds while re is low.
module probe_ram #(parameter WIDTH=8, DEPTH=64)(
    input wire clk,we,re,
    input wire [$clog2(DEPTH)-1:0] waddr,raddr,
    input wire [WIDTH-1:0] wdata,
    output reg [WIDTH-1:0] q);
    (* ram_style="block" *) reg [WIDTH-1:0] mem[0:DEPTH-1];
    always @(posedge clk) begin
        if(we) mem[waddr]<=wdata;
        if(re) q<=mem[raddr];
    end
endmodule
