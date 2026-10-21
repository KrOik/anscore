// Fixed 8-byte command/reply, CRC8 poly 0x07, one outstanding command.
module uart_csr_transport #(parameter GAP_TIMEOUT=100000)(
 input wire clk,rst_n,input wire [7:0] rx_data,input wire rx_valid,rx_error,
 output wire [7:0] tx_data,output wire tx_valid,input wire tx_ready,
 output reg req_valid,output reg req_write,output reg [7:0] req_addr,
 output reg [31:0] req_data,input wire req_ready,
 input wire resp_valid,input wire [31:0] resp_data,input wire resp_error,
 output wire resp_ready
);
 reg [1:0] state;
 reg [2:0] count,tx_index;
 reg [7:0] op,crc;
 reg [63:0] reply;
 reg [31:0] gap;
 reg [55:0] reply_body;
 reg [7:0] reply_crc;
 integer i;
 function [7:0] crc_byte;
  input [7:0] old_crc,b;
  reg [7:0] x; integer j;
  begin
   x=old_crc^b;
   for(j=0;j<8;j=j+1) x=x[7]?(x<<1)^8'h07:(x<<1);
   crc_byte=x;
  end
 endfunction
 always @* begin
  reply_body={resp_data,req_addr,{7'd0,resp_error},8'h5a};
  reply_crc=0;
  for(i=0;i<7;i=i+1) reply_crc=crc_byte(reply_crc,reply_body[i*8+:8]);
 end
 assign resp_ready=(state==2);
 assign tx_valid=(state==3);
 assign tx_data=reply[tx_index*8+:8];
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=0; count<=0; tx_index<=0; op<=0; crc<=0; gap<=0; reply<=0;
   req_valid<=0; req_write<=0; req_addr<=0; req_data<=0;
  end else begin
   case(state)
    0: begin
     if(count!=0) begin
      gap<=gap+1'b1;
      if(gap>=GAP_TIMEOUT-1) begin count<=0; gap<=0; end
     end
     if(rx_error) begin count<=0; gap<=0; end
     else if(rx_valid) begin
      gap<=0;
      if(count==0) begin
       if(rx_data==8'ha5) begin count<=1; crc<=crc_byte(0,rx_data); end
      end else if(count==7) begin
       count<=0;
       if(rx_data==crc&&op<=1) begin req_write<=op[0]; req_valid<=1; state<=1; end
      end else begin
       crc<=crc_byte(crc,rx_data); count<=count+1'b1;
       case(count)
        1: op<=rx_data;
        2: req_addr<=rx_data;
        3: req_data[7:0]<=rx_data;
        4: req_data[15:8]<=rx_data;
        5: req_data[23:16]<=rx_data;
        6: req_data[31:24]<=rx_data;
       endcase
      end
     end
    end
    1: if(req_valid&&req_ready) begin req_valid<=0; state<=2; end
    2: if(resp_valid) begin reply<={reply_crc,reply_body}; tx_index<=0; state<=3; end
    3: if(tx_ready) begin
     if(tx_index==7) begin state<=0; count<=0; gap<=0; end
     else tx_index<=tx_index+1'b1;
    end
   endcase
  end
 end
endmodule
