module sys_auto_vectors_2(input wire clk,input wire [15:0] address,input wire [7:0] case_id,output reg [95:0] data,output reg [47:0] descriptor,output wire [7:0] cases);
assign cases=8'd16;
(* ram_style="block" *) reg [95:0] mem[0:2047];
initial $readmemh("vectors/auto_2.mem",mem);
always @(posedge clk) data<=mem[address[10:0]];
always @* begin descriptor=0; case(case_id)
8'd0: descriptor={16'd0,16'd128,16'd128};
8'd1: descriptor={16'd128,16'd128,16'd128};
8'd2: descriptor={16'd256,16'd128,16'd128};
8'd3: descriptor={16'd384,16'd128,16'd128};
8'd4: descriptor={16'd512,16'd128,16'd128};
8'd5: descriptor={16'd640,16'd128,16'd128};
8'd6: descriptor={16'd768,16'd128,16'd128};
8'd7: descriptor={16'd896,16'd128,16'd128};
8'd8: descriptor={16'd1024,16'd128,16'd128};
8'd9: descriptor={16'd1152,16'd128,16'd128};
8'd10: descriptor={16'd1280,16'd128,16'd128};
8'd11: descriptor={16'd1408,16'd128,16'd128};
8'd12: descriptor={16'd1536,16'd128,16'd128};
8'd13: descriptor={16'd1664,16'd128,16'd128};
8'd14: descriptor={16'd1792,16'd128,16'd128};
8'd15: descriptor={16'd1920,16'd128,16'd128};
default: descriptor=0; endcase end
endmodule
