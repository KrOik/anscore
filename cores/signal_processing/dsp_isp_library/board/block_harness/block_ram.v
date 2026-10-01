// Same 64x32 interface, selectable original inference or measured DPX9B wiring.
module block_ram #(parameter MEM_IMPL=0)(input wire clk,we,re,
 input wire [5:0] waddr,raddr,input wire [31:0] wdata,output wire [31:0] q);
 generate if(MEM_IMPL==0) begin: inferred
 (* ram_style="block" *) reg [31:0] mem[0:63];
 reg [31:0] qr;
 always @(posedge clk) begin
 if(we) mem[waddr]<=wdata;
 if(re) qr<=mem[raddr];
 end
 assign q=qr;
 end else begin: explicit_banks
 genvar i;
 for(i=0;i<2;i=i+1) begin: bank
 wire [17:0] dob;
 DPX9B #(.BIT_WIDTH_0(18),.BIT_WIDTH_1(18),.BLK_SEL_0(3'b000),.BLK_SEL_1(3'b000),.RESET_MODE("ASYNC")) ram(
 .BLKSELA(3'b000),.BLKSELB(3'b000),
 .CLKA(clk),.CEA(1'b1),.WREA(we),.RESETA(1'b0),
 .ADA({4'b0000,waddr,2'b00,2'b11}),.DIA({2'b00,wdata[i*16+:16]}),.DOA(),
 .CLKB(clk),.CEB(re),.WREB(1'b0),.RESETB(1'b0),
 .ADB({4'b0000,raddr,4'b0000}),.DIB(18'b0),.DOB(dob),.OCEA(1'b0),.OCEB(1'b0));
 assign q[i*16+:16]=dob[15:0];
 end
 end endgenerate
endmodule
