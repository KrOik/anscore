// UART's legacy 8-bit CSR address window; FC selects bank0..3.
module video_uart_control #(parameter [63:0] BUILD_ID=0)(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,
 output wire req_ready,resp_valid,resp_error,output wire [31:0] resp_data,
 input wire resp_ready,output wire [7:0] probe
);
reg [1:0] bank;reg response,error;reg [31:0] response_data;
wire qr,rv,re;wire [31:0] rd;wire [2:0] pv,de,hs,vs;wire [71:0] rgb;
wire local_addr=req_addr==8'hfc;
assign req_ready=rst_n&&!response&&qr;
assign resp_valid=response||rv;assign resp_error=response?error:re;
assign resp_data=response?response_data:rd;
video_control #(.BUILD_ID(BUILD_ID)) control(clk,rst_n,
 req_valid&&!local_addr&&!response,req_write,{bank,req_addr},req_data,4'hf,
 qr,rv,re,rd,resp_ready&&!response,pv,de,hs,vs,rgb,probe);
always @(posedge clk)begin
 if(!rst_n)begin bank<=0;response<=0;error<=0;response_data<=0;end
 else begin
  if(response&&resp_ready)response<=0;
  if(req_valid&&req_ready&&local_addr)begin
   response<=1;error<=0;response_data<={30'd0,bank};
   if(req_write)begin
    response_data<=0;
    if(req_data>3)error<=1;else bank<=req_data[1:0];
   end
  end
 end
end
endmodule
