module sys_auto_vectors_8(input wire clk,input wire [15:0] address,input wire [7:0] case_id,output reg [95:0] data,output reg [47:0] descriptor,output wire [7:0] cases);
assign cases=8'd2;
(* ram_style="block" *) reg [95:0] mem[0:255];
initial $readmemh("vectors/auto_8.mem",mem);
always @(posedge clk) data<=mem[address[7:0]];
always @* begin descriptor=0; case(case_id)
8'd0: descriptor={16'd0,16'd9,16'd68};
8'd1: descriptor={16'd68,16'd9,16'd68};
default: descriptor=0; endcase end
endmodule
